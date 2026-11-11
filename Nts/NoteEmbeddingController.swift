import Combine
import Foundation

@MainActor
final class NoteEmbeddingController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var isDownloading = false
    @Published private(set) var isWorking = false
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var completedNotes = 0
    @Published private(set) var totalNotes = 0
    @Published private(set) var message: String?

    private let database: SQLiteDatabase
    private let metadata: DatabaseStatus
    private let backend: any NoteEmbeddingBackend
    private let configuration: EmbeddingModelConfiguration
    private let defaults: UserDefaults
    private let enabledKey = "noteEmbeddingsEnabled"
    private let manuallyDisabledKey = "noteEmbeddingsManuallyDisabled"
    private var folder: URL?
    private var events: [Event] = []
    private var worker: Task<Void, Never>?
    private var session = UUID()

    private struct Event {
        let folder: URL
        let savedURL: URL?
        let retryErrors: Bool
        var allowModelDownload: Bool
        let access: EmbeddingFolderAccess
    }

    init(database: SQLiteDatabase, metadata: DatabaseStatus,
         backend: any NoteEmbeddingBackend, configuration: EmbeddingModelConfiguration = .current,
         defaults: UserDefaults = .standard) {
        self.database = database
        self.metadata = metadata
        self.backend = backend
        self.configuration = configuration
        self.defaults = defaults
        if defaults.object(forKey: manuallyDisabledKey) == nil {
            defaults.set(defaults.object(forKey: enabledKey) != nil && !defaults.bool(forKey: enabledKey),
                         forKey: manuallyDisabledKey)
        }
        enabled = defaults.bool(forKey: enabledKey)
    }

    func activate(folder: URL?) {
        let changed = self.folder?.resolvingSymlinksInPath().standardizedFileURL.path
            != folder?.resolvingSymlinksInPath().standardizedFileURL.path
        self.folder = folder
        if changed {
            session = UUID()
            events.removeAll()
            worker?.cancel()
            completedNotes = 0
            totalNotes = 0
        }
        if enabled, let folder { refresh(folder: folder) }
    }

    func refresh(folder: URL) {
        guard enabled else { return }
        enqueue(folder: folder, savedURL: nil, retryErrors: false)
    }

    func saved(_ url: URL) async {
        guard enabled, folder?.resolvingSymlinksInPath().standardizedFileURL.path
                == url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path else { return }
        let folder = url.deletingLastPathComponent()
        let expectedSession = session
        await metadata.waitForPendingWork()
        guard enabled, session == expectedSession else { return }
        enqueue(folder: folder, savedURL: url, retryErrors: false, allowModelDownload: true)
    }

    func downloadAndEnable() async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        message = "Downloading the embedding model…"
        do {
            if await backend.isAvailable() {
                downloadProgress = 1
            } else {
                try await backend.download { [weak self] value in
                    Task { @MainActor in self?.downloadProgress = min(1, max(0, value)) }
                }
            }
            enabled = true
            defaults.set(true, forKey: enabledKey)
            defaults.set(false, forKey: manuallyDisabledKey)
            message = nil
            if let folder { refresh(folder: folder) }
        } catch {
            message = "Embedding model setup failed: \(error.localizedDescription)"
        }
        isDownloading = false
    }

    func enableForFirstUse(folder: URL?) {
        guard let folder, !defaults.bool(forKey: manuallyDisabledKey) else { return }
        enabled = true
        defaults.set(true, forKey: enabledKey)
        enqueue(folder: folder, savedURL: nil, retryErrors: false, allowModelDownload: true)
    }

    func disable() {
        enabled = false
        defaults.set(false, forKey: enabledKey)
        defaults.set(true, forKey: manuallyDisabledKey)
        session = UUID()
        events.removeAll()
        worker?.cancel()
        message = "Map indexing is disabled."
        guard worker == nil else { return }
        Task { await unloadBackend() }
    }

    func retry() {
        guard enabled, let folder else { return }
        enqueue(folder: folder, savedURL: nil, retryErrors: true, allowModelDownload: true)
    }

    func waitForWork() async {
        while let worker { await worker.value }
    }

    private func enqueue(folder: URL, savedURL: URL?, retryErrors: Bool, allowModelDownload: Bool = false) {
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        if savedURL == nil, retryErrors == false,
           let lastIndex = events.indices.last,
           events[lastIndex].savedURL == nil, events[lastIndex].folder.standardizedFileURL == canonical {
            if allowModelDownload { events[lastIndex].allowModelDownload = true }
            return
        }
        events.removeAll {
            $0.folder.resolvingSymlinksInPath().standardizedFileURL == canonical
                && (savedURL == nil || $0.savedURL == savedURL)
        }
        events.append(Event(folder: canonical, savedURL: savedURL, retryErrors: retryErrors,
                            allowModelDownload: allowModelDownload,
                            access: EmbeddingFolderAccess(canonical)))
        guard worker == nil else { return }
        worker = Task { await processEvents() }
    }

    private func processEvents() async {
        isWorking = true
        while !events.isEmpty, !Task.isCancelled, enabled {
            let event = events.removeFirst()
            let eventSession = session
            do {
                await metadata.waitForPendingWork()
                try await database.initialize()
                let space = try configuration.space
                try await database.registerEmbeddingSpace(space)
                if event.retryErrors {
                    _ = try await database.retryFailedEmbeddings(folder: event.folder,
                                                                 spaceFingerprint: space.fingerprint)
                }
                if event.savedURL == nil {
                    _ = try await database.recoverInterruptedEmbeddings()
                    for note in try await database.indexedEmbeddingNotes(folder: event.folder) {
                        guard enabled, session == eventSession, !Task.isCancelled else { break }
                        _ = try await database.enqueueEmbedding(noteID: note.noteID,
                                                                spaceFingerprint: space.fingerprint,
                                                                sourceHash: note.sourceHash)
                    }
                } else if let url = event.savedURL {
                    _ = try await database.enqueueEmbedding(url: url, spaceFingerprint: space.fingerprint)
                }
                if !(await backend.isAvailable()) {
                    guard event.allowModelDownload else {
                        message = "The embedding model is not downloaded. Open Map to download it automatically."
                        continue
                    }
                    isDownloading = true
                    downloadProgress = 0
                    message = "Downloading the embedding model…"
                    do {
                        try await backend.download { [weak self] value in
                            Task { @MainActor in
                                guard let self, self.session == eventSession else { return }
                                self.downloadProgress = min(1, max(0, value))
                            }
                        }
                        isDownloading = false
                    } catch {
                        isDownloading = false
                        throw error
                    }
                    guard enabled, session == eventSession, !Task.isCancelled else { continue }
                }
                let jobs = try await database.pendingEmbeddings(folder: event.folder,
                                                                spaceFingerprint: space.fingerprint)
                totalNotes = jobs.count
                completedNotes = 0
                for pending in jobs {
                    guard enabled, session == eventSession, !Task.isCancelled else { break }
                    var job = pending.job
                    var done = false
                    for attempt in 1...2 {
                        guard try await database.beginEmbedding(job) else { break }
                        do {
                            guard let text = try await database.embeddingInput(job, url: pending.url) else {
                                _ = try await database.failEmbedding(job, message: "Saved note bytes changed; refresh to reindex.")
                                break
                            }
                            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                done = try await database.skipEmptyEmbedding(job)
                                break
                            }
                            let vector = try await LocalMLXResourceGate.shared.withResource(.embeddings) {
                                try await self.backend.embed(text) { [weak self] value in
                                    Task { @MainActor in
                                        guard let self, self.session == eventSession else { return }
                                        self.message = "Embedding note \(self.completedNotes + 1) of \(self.totalNotes) · \(Int(value * 100))%"
                                    }
                                }
                            }
                            guard enabled, session == eventSession, !Task.isCancelled else { break }
                            done = try await database.completeEmbedding(job, vector: vector, url: pending.url)
                            break
                        } catch is CancellationError {
                            break
                        } catch {
                            let failed = try await database.failEmbedding(job, message: error.localizedDescription)
                            guard failed else { break }
                            if attempt < 2, let retry = try await database.retryFailedEmbedding(job) {
                                job = retry
                                continue
                            }
                            message = "Could not index a note: \(error.localizedDescription)"
                            break
                        }
                    }
                    if done { completedNotes += 1 }
                }
                if enabled, session == eventSession, !Task.isCancelled {
                    message = jobs.isEmpty ? "Map index is up to date." : "Map index updated."
                }
            } catch is CancellationError {
                // Disabling or switching folders cancels inference without affecting saved notes.
            } catch {
                message = "Map indexing failed: \(error.localizedDescription)"
            }
            withExtendedLifetime(event.access) { }
        }
        isWorking = false
        worker = nil
        if !enabled || events.isEmpty { await unloadBackend() }
        if !events.isEmpty { worker = Task { await processEvents() } }
    }

    private func unloadBackend() async {
        let backend = self.backend
        let unloading = Task {
            try? await LocalMLXResourceGate.shared.withResource(.embeddings) {
                await backend.unload()
                return true
            }
        }
        _ = await unloading.value
    }
}

private final class EmbeddingFolderAccess {
    private let folder: URL
    let active: Bool

    init(_ folder: URL) {
        self.folder = folder
        active = folder.startAccessingSecurityScopedResource()
    }

    deinit {
        if active { folder.stopAccessingSecurityScopedResource() }
    }
}
