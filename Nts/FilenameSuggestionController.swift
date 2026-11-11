import Foundation
import Combine

/// Explicit naming requests enqueue work. Model failures never roll back a successful save.
@MainActor
final class FilenameSuggestionController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var isWorking = false
    @Published private(set) var isApplying = false
    @Published private(set) var isGeneratingName = false
    @Published private(set) var message: String?
    @Published private(set) var suggestions: [String: FilenameSuggestion] = [:]
    private let database: SQLiteDatabase
    private let metadata: DatabaseStatus
    private let generator: any FilenameGenerating
    private let configuration: FilenameModelConfiguration
    private let defaults: UserDefaults
    private let enabledKey = "filenameSuggestionsEnabled"
    private let manuallyDisabledKey = "filenameSuggestionsManuallyDisabled"
    private var folder: URL?
    private var events: [Event] = []
    private var worker: Task<Void, Never>?
    private var session = UUID()
    private var namingRequest = UUID()
    private var dismissedPaths: Set<String> = []
    private var dismissal: Task<Void, Never>?

    private func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    private func downloadModelWithProgress() async throws {
        try await generator.download(configuration: configuration) { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadProgress = max(self.downloadProgress, min(1, max(0, value)))
            }
        }
        downloadProgress = 1
    }

    @discardableResult
    func dismissFilename(for url: URL?) -> Bool {
        guard let url, isGeneratingName || suggestions[url.lastPathComponent] != nil else { return false }
        namingRequest = UUID()
        dismissedPaths.insert(path(url))
        suggestions.removeValue(forKey: url.lastPathComponent)
        events.removeAll { $0.savedURL == url }
        if isGeneratingName { worker?.cancel() }
        let previous = dismissal
        dismissal = Task {
            await previous?.value
            do { try await database.dismissFilename(url: url) }
            catch { message = "Could not dismiss the filename suggestion: \(error.localizedDescription)" }
        }
        return true
    }

    private struct Event {
        let folder: URL
        let savedURL: URL?
        let force: Bool
        let allowModelDownload: Bool
        let access: FilenameFolderAccess
    }

    init(database: SQLiteDatabase, metadata: DatabaseStatus, generator: any FilenameGenerating,
         configuration: FilenameModelConfiguration = .filename, defaults: UserDefaults = .standard) {
        self.database = database
        self.metadata = metadata
        self.generator = generator
        self.configuration = configuration
        self.defaults = defaults
        if defaults.object(forKey: manuallyDisabledKey) == nil {
            defaults.set(defaults.object(forKey: enabledKey) != nil && !defaults.bool(forKey: enabledKey),
                         forKey: manuallyDisabledKey)
        }
        enabled = defaults.bool(forKey: enabledKey)
    }

    func activate(folder: URL?) {
        self.folder = folder
        suggestions = [:]
        if let folder { refresh(folder: folder) }
    }

    func refresh(folder: URL) {
        if self.folder?.standardizedFileURL.path == folder.standardizedFileURL.path { suggestions = [:] }
        enqueue(folder: folder, savedURL: nil, force: false)
    }

    func saved(_ url: URL, force: Bool = false) {
        guard enabled else { return }
        if folder?.standardizedFileURL.path == url.deletingLastPathComponent().standardizedFileURL.path {
            suggestions.removeValue(forKey: url.lastPathComponent)
        }
        enqueue(folder: url.deletingLastPathComponent(), savedURL: url, force: force)
    }

    func downloadAndEnable() async {
        guard !isDownloading else { return }
        let setupSession = session
        isDownloading = true
        downloadProgress = 0
        message = "Downloading the local filename model…"
        do {
            if !(await generator.isAvailable(configuration: configuration)) {
                try await downloadModelWithProgress()
            } else {
                downloadProgress = 1
            }
            guard setupSession == session else { isDownloading = false; return }
            enabled = true
            defaults.set(true, forKey: enabledKey)
            defaults.set(false, forKey: manuallyDisabledKey)
            message = nil
            if let folder { refresh(folder: folder) }
        } catch { message = "Model setup failed: \(error.localizedDescription)" }
        isDownloading = false
    }

    func disable() {
        enabled = false
        defaults.set(false, forKey: enabledKey)
        defaults.set(true, forKey: manuallyDisabledKey)
        session = UUID()
        events.removeAll()
        worker?.cancel()
        message = nil
        // The worker unloads after its current operation has unwound.
        if worker == nil { Task { await generator.unload() } }
    }

    /// Changed existing notes only save text; clean notes accept a ready preview.
    func save(in store: NoteStore) async throws {
        let firstSave = store.selected == nil && store.isDirty && !store.text.isEmpty
        let changed = store.isDirty
        guard store.save() else { return }
        if firstSave {
            try await regenerate(in: store)
        } else if changed, let url = store.selected {
            suggestions.removeValue(forKey: url.lastPathComponent)
        } else if !isGeneratingName, enabled, let url = store.selected,
                  let suggestion = suggestions[url.lastPathComponent], suggestion.state == "ready",
                  let filename = suggestion.filename, filename != url.lastPathComponent {
            try await apply(filename, to: url, in: store)
        }
    }

    /// Regeneration never applies a filename, even when the note is unchanged.
    func regenerate(in store: NoteStore) async throws {
        // A save during inference still saves text; a repeated generation request is ignored.
        guard !isGeneratingName else { _ = store.save(); return }
        guard store.selected != nil || store.isDirty else { return }
        isGeneratingName = true
        defer { isGeneratingName = false }
        guard store.save(), let url = store.selected else { return }
        let request = namingRequest
        let editorID = store.editorID
        let savedText = store.text
        if !enabled {
            guard !defaults.bool(forKey: manuallyDisabledKey) else {
                throw FilenameSuggestionFailure(message: "The note was saved. Enable filename suggestions in the Local AI menu to generate its filename.")
            }
            enabled = true
            defaults.set(true, forKey: enabledKey)
        }
        await dismissal?.value
        await metadata.waitForPendingWork()
        guard request == namingRequest else { return }
        dismissedPaths.remove(path(url))
        saved(url, force: true)
        await waitForWork()
        guard request == namingRequest else { return }
        guard store.selected == url, store.editorID == editorID, !store.isDirty, store.text == savedText else {
            throw FilenameSuggestionFailure(message: "The note changed while generating its filename. Save or regenerate again when ready.")
        }
        if let suggestion = suggestions[url.lastPathComponent], suggestion.state == "error" {
            return // Exhausted retries are shown inline; never present a file-save failure for model output.
        }
        guard suggestions[url.lastPathComponent]?.state == "ready" else {
            throw FilenameSuggestionFailure(message: message
                ?? "The saved note changed or its filename could not be generated. Try Regenerate Filename again.")
        }
        // Leave the preview for clean Cmd-S or explicit Apply.
    }

    func apply(_ filename: String, to url: URL, in store: NoteStore) async throws {
        guard !isApplying, enabled, store.selected == url, !store.isDirty else {
            throw FilenameSuggestionFailure(message: "Select the saved note before applying its filename suggestion.")
        }
        guard filename != url.lastPathComponent else { return }
        isApplying = true
        defer { isApplying = false }
        let editorID = store.editorID
        let applicationSession = session
        let access = FilenameFolderAccess(url.deletingLastPathComponent())
        defer { withExtendedLifetime(access) { } }
        let data = try await database.filenameApplicationData(url: url, filename: filename, configuration: configuration)
        try Task.checkCancellation()
        // Navigation, typing or disabling AI may have happened across the actor await.
        guard enabled, applicationSession == session, store.selected == url,
              store.editorID == editorID, !store.isDirty, !dismissedPaths.contains(path(url)) else {
            throw FilenameSuggestionFailure(message: "The active note changed. Review its suggestion before applying it.")
        }
        try await store.renameWithLinks(url, to: filename, expected: data) {
            guard self.enabled, applicationSession == self.session, store.selected == url,
                  store.editorID == editorID, !store.isDirty, !self.dismissedPaths.contains(self.path(url)) else {
                throw FilenameSuggestionFailure(message: "The active note changed. Review its suggestion before applying it.")
            }
        }
        suggestions.removeValue(forKey: url.lastPathComponent)
    }

    func waitForWork() async {
        while let worker { await worker.value }
    }

    private func enqueue(folder: URL, savedURL: URL?, force: Bool) {
        // A later save supersedes a queued save for the same path.
        events.removeAll { $0.folder.standardizedFileURL.path == folder.standardizedFileURL.path && $0.savedURL == savedURL }
        events.append(Event(folder: folder, savedURL: savedURL, force: force,
                            allowModelDownload: force, access: FilenameFolderAccess(folder)))
        guard worker == nil else { return }
        worker = Task { await process() }
    }

    private func process() async {
        isWorking = true
        while !events.isEmpty, !Task.isCancelled {
            let event = events.removeFirst()
            do {
                await metadata.waitForPendingWork()
                try await database.initialize()
                try Task.checkCancellation()
                if enabled, let url = event.savedURL {
                    try await database.queueFilename(url: url, configuration: configuration, force: event.force)
                }
                try await publish(folder: event.folder)
                if enabled {
                    let jobs = try await database.pendingFilenames(folder: event.folder, configuration: configuration)
                    if !jobs.isEmpty, !(await generator.isAvailable(configuration: configuration)) {
                        guard event.force, !defaults.bool(forKey: manuallyDisabledKey) else {
                            message = "The filename model is not downloaded. Generate a filename to download it automatically."
                            continue
                        }
                        isDownloading = true
                        downloadProgress = 0
                        message = "Downloading the local filename model…"
                        do {
                            try await downloadModelWithProgress()
                            isDownloading = false
                        } catch {
                            isDownloading = false
                            throw error
                        }
                    }
                    for job in jobs {
                        guard enabled, !Task.isCancelled else { break }
                        let generationSession = session
                        let limit = max(1, min(configuration.maxGenerationAttempts, 5))
                        attempts: for attempt in 1...limit {
                            guard enabled, generationSession == session, !Task.isCancelled else { break }
                            do {
                                guard let text = try await database.filenameInput(job) else {
                                    try await database.reconcile(folder: event.folder)
                                    break attempts // Changed/deleted content is not a retryable model failure.
                                }
                                try await publish(folder: event.folder)
                                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                    try await database.finishFilename(job, filename: nil, error: "This saved note is empty.")
                                    break attempts
                                }
                                try Task.checkCancellation()
                                let raw = try await generator.generate(text: text, configuration: configuration)
                                #if DEBUG
                                print("[Filename Model] Attempt \(attempt)/\(limit)")
                                print("[Filename Model] Raw output BEGIN\n\(raw)\n[Filename Model] Raw output END")
                                #endif
                                try Task.checkCancellation()
                                guard enabled, generationSession == session else { break attempts }
                                let filename = try FilenameOutput.filename(from: raw, in: event.folder, current: job.url)
                                #if DEBUG
                                print("[Filename Model] Normalized filename: \(filename)")
                                #endif
                                try await database.finishFilename(job, filename: filename, error: nil)
                                break attempts
                            } catch is CancellationError {
                                break attempts // Interrupted work remains resumable.
                            } catch {
                                guard enabled, generationSession == session, !Task.isCancelled else { break attempts }
                                #if DEBUG
                                print("[Filename Model] Attempt \(attempt)/\(limit) failed: \(error.localizedDescription)")
                                #endif
                                if attempt < limit {
                                    await generator.unload()
                                    continue attempts
                                }
                                try await database.finishFilename(job, filename: nil,
                                    error: "Could not generate a filename after \(limit) attempts. \(error.localizedDescription)")
                            }
                        }
                        try await publish(folder: event.folder)
                    }
                }
                message = nil
            } catch is CancellationError {
                // Escape/disable interrupts work without presenting an error.
            } catch {
                message = "Filename suggestions unavailable: \(error.localizedDescription)"
            }
            withExtendedLifetime(event.access) { }
        }
        await generator.unload()
        isWorking = false
        worker = nil
        // A new enable/refresh may have arrived while a canceled worker unwound.
        if !events.isEmpty { worker = Task { await process() } }
    }

    private func publish(folder: URL) async throws {
        let values = try await database.filenameSuggestions(folder: folder, configuration: configuration)
        if self.folder?.standardizedFileURL.path == folder.standardizedFileURL.path {
            suggestions = values.filter { !dismissedPaths.contains(path(folder.appendingPathComponent($0.key))) }
        }
    }
}

private final class FilenameFolderAccess {
    private let url: URL
    private let active: Bool
    init(_ url: URL) { self.url = url; active = url.startAccessingSecurityScopedResource() }
    deinit { if active { url.stopAccessingSecurityScopedResource() } }
}
