import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NoteStore: ObservableObject {
    static let shared = NoteStore()
    @Published private(set) var folder: URL?
    @Published private(set) var notes: [NoteFile] = []
    @Published private(set) var selected: URL?
    @Published private(set) var editorID = UUID()
    @Published private(set) var isShowingMap = false
    private(set) var editorSession = NoteEditorSession()
    private var editorSessions: [String: NoteEditorSession] = [:]
    private func editorKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    @Published private(set) var editorFocusRequest = UUID()
    @Published private(set) var sidebarFocusRequest = UUID()
    @Published private(set) var findRequest: UUID?
    private(set) var findEditorID: UUID?
    private(set) var findAction: NSTextFinder.Action = .showFindInterface

    func find(_ action: NSTextFinder.Action = .showFindInterface) {
        showNotes()
        findAction = action
        findEditorID = editorID
        findRequest = UUID()
    }

    @Published var isLivePreview = true
    @Published var title = ""
    @Published var text = "" {
        didSet { if text != oldValue { scheduleAutosave() } }
    }
    @Published var autosaveEnabled: Bool {
        didSet {
            defaults.set(autosaveEnabled, forKey: "notes.autosaveEnabled")
            scheduleAutosave()
        }
    }
    private var renameInProgress = false
    @Published var errorMessage: String?
    // Fired only after a successful changed save; future embeddings belong here.
    var onSaved: ((URL) -> Void)?
    var onFolderChanged: ((URL) -> Void)?
    private struct DeletedNote {
        let url: URL
        let data: Data
        let draft: String?
        let session: NoteEditorSession?
        let created: Date?
        let modified: Date?
    }
    private var deletedNotes: [DeletedNote] = []
    private let trashNote: (URL, Data) throws -> Void
    private var savedText = ""
    private var savedTitle = ""
    private var savedData = Data()
    private var scopedURL: URL?
    private let files = NoteFileService()
    private let images = ImageAssetService()
    private var index: DatabaseStatus?
    private var dateSubscription: AnyCancellable?
    private let defaults: UserDefaults
    private let autosaveDelayNanoseconds: UInt64
    private var autosaveTask: Task<Void, Never>?

    init(index: DatabaseStatus? = nil, defaults: UserDefaults = .standard,
         autosaveDelayNanoseconds: UInt64 = 1_000_000_000,
         trashNote: @escaping (URL, Data) throws -> Void = { try NoteFileService().trash($0, expected: $1) }) {
        editorID = editorSession.id
        self.trashNote = trashNote
        self.index = index
        self.defaults = defaults
        self.autosaveDelayNanoseconds = autosaveDelayNanoseconds
        autosaveEnabled = defaults.object(forKey: "notes.autosaveEnabled") as? Bool ?? true
        if let index { connectIndex(index) }
    }

    deinit {
        autosaveTask?.cancel()
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard autosaveEnabled, folder != nil, isDirty, selected != nil || !text.isEmpty else { return }
        let delay = autosaveDelayNanoseconds
        let editorID = self.editorID
        let folder = self.folder
        let snapshot = text
        let titleSnapshot = title
        autosaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard let self, !Task.isCancelled, self.autosaveEnabled,
                  self.editorID == editorID, self.folder == folder,
                  self.text == snapshot, self.title == titleSnapshot, self.isDirty else { return }
            self.autosaveTask = nil
            if self.editorSession.hasMarkedText {
                self.scheduleAutosave() // Wait for input-method composition to finish.
                return
            }
            // Background saves never open a folder picker or generate/apply names.
            _ = self.save()
        }
    }

    func connectIndex(_ index: DatabaseStatus) {
        self.index = index
        dateSubscription = index.$noteDates.sink { [weak self] snapshot in
            guard let self else { return }
            if let snapshot, snapshot.folder == self.folder {
                self.notes = self.notes.map { note in
                    NoteFile(url: note.url, date: snapshot.dates[note.name] ?? note.date,
                             observedCreated: note.observedCreated, observedModified: note.observedModified)
                }.sorted { $0.date == $1.date ? $0.name < $1.name : $0.date > $1.date }
            } else if snapshot == nil, let folder = self.folder {
                // Restore filesystem browsing when the index is unavailable.
                if let notes = try? self.files.list(in: folder) { self.notes = notes }
            }
        }
        if let folder { index.reconcile(folder: folder) }
    }

    private let bookmarkKey = "notesFolderBookmark"
    private var restored = false

    var isDirty: Bool { text != savedText || (selected == nil && title != savedTitle) }

    func navigationTarget(_ direction: NoteNavigation.Direction) -> URL? {
        NoteNavigation.target(in: notes.map(\.url), selected: selected, direction: direction)
    }

    func navigate(_ direction: NoteNavigation.Direction, focusEditor: Bool = true) {
        guard let target = navigationTarget(direction) else { return }
        open(target, focusEditor: focusEditor)
    }

    func focusEditor() {
        showNotes()
        editorFocusRequest = UUID()
    }

    func toggleEditingMode() {
        isLivePreview.toggle()
        focusEditor()
    }

    func focusSidebar() {
        showNotes()
        sidebarFocusRequest = UUID()
    }

    func showNotes() { isShowingMap = false }

    func showMap() { isShowingMap = true }

    func chooseNote() {
        guard let folder else { return }
        let panel = NSOpenPanel()
        panel.title = "Open a Markdown note"
        panel.prompt = "Open Note"
        panel.directoryURL = folder
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                == folder.resolvingSymlinksInPath().standardizedFileURL else {
            errorMessage = "Choose this note's containing folder using Choose Notes Folder first."
            return
        }
        open(url)
        refresh()
    }

    func restoreFolder() {
        guard !restored else { return }
        restored = true
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                              bookmarkDataIsStale: &stale)
            try activateFolder(url)
        } catch { report(error) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose your notes folder"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A first folder gives the current draft a destination without discarding it.
        if folder != nil, !canLeaveNote() { return }
        do { try activateFolder(url) } catch { report(error) }
    }

    func activateFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            do { try WikiRenameCoordinator().recover(folder: url) }
            catch { report(error) } // Keep notes accessible; another rename still requires recovery.
            try images.ensureDirectory(in: url)
            let newNotes = try files.list(in: url)
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
            scopedURL = scoped ? url : nil
            folder = url
            notes = newNotes
            if selected != nil { clearSelection() }
            defaults.set(bookmark, forKey: bookmarkKey)
            index?.reconcile(folder: url)
            onFolderChanged?(url)
            scheduleAutosave()
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func refresh() { refresh(rename: nil) }

    private func refresh(rename: NoteRename?) {
        guard let folder else { return }
        do { notes = try files.list(in: folder) } catch { report(error) }
        index?.reconcile(folder: folder, rename: rename)
    }

    func openWikiLink(_ title: String) {
        guard let folder else { errorMessage = "Choose a notes folder to open note links."; return }
        let target = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let available = try files.list(in: folder)
            let names = WikiLinks.matches(target, names: available.map(\.name))
            let matches = available.filter { names.contains($0.name) }
            guard matches.count == 1, let note = matches.first else {
                errorMessage = matches.isEmpty ? "Note ‘\(target)’ was not found in this folder."
                    : "More than one note matches ‘\(target)’. Use its exact filename in the link."
                return
            }
            notes = available
            open(note.url)
        } catch { report(error) }
    }

    func open(_ url: URL, focusEditor: Bool = true) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = NoteFileError.invalidFile.localizedDescription
            return
        }
        if selected == url {
            showNotes()
            if focusEditor { self.focusEditor() }
            return
        }
        guard canLeaveNote() else { return }
        do {
            let contents = try files.read(url)
            selected = url
            showNotes()
            findRequest = nil
            let key = editorKey(url)
            editorSession = editorSessions[key] ?? NoteEditorSession()
            editorSessions[key] = editorSession
            editorID = editorSession.id
            text = contents.text
            savedText = contents.text
            title = ""
            savedTitle = ""
            savedData = contents.data
            if focusEditor { self.focusEditor() }
        } catch { report(error) }
    }

    func create() {
        guard canLeaveNote() else { return }
        showNotes()
        clearSelection()
        focusEditor()
    }

    @discardableResult
    func save() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard isDirty else { return true }
        // Empty drafts never create files, even for an explicit save.
        guard selected != nil || !text.isEmpty || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        if folder == nil { chooseFolder() }
        guard let folder else { return false }
        do {
            if let selected {
                savedData = try files.save(text, to: selected, expected: savedData)
            } else {
                let url = try files.create(in: folder, title: title, text: text)
                selected = url
                editorSessions[editorKey(url)] = editorSession
                savedData = Data(text.utf8)
            }
            savedText = text
            savedTitle = title
            refresh()
            if let selected { onSaved?(selected) }
            return true
        } catch {
            report(error)
            return false
        }
    }

    func deleteSelected() {
        guard let selected else { return }
        delete(selected)
    }

    func importImages(_ inputs: [ImageInput], into editor: NSTextView, at range: NSRange) -> Bool {
        guard let folder, editor.string == text, !editor.hasMarkedText(),
              range.location <= editor.string.utf16.count,
              range.length <= editor.string.utf16.count - range.location else {
            report(ImageAssetError.noActiveNote)
            return false
        }
        do {
            let imported = try images.importImages(inputs, into: folder)
            guard !imported.isEmpty else { return false }
            let markdown = imported.map(\.markdown).joined(separator: "\n")
            editor.insertText(markdown, replacementRange: range)
            text = editor.string
            focusEditor()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func reportImageError(_ error: Error) { report(error) }

    func rename(_ url: URL, to name: String, expected: Data? = nil) throws {
        let coordinator = WikiRenameCoordinator()
        try coordinator.recover(folder: url.deletingLastPathComponent())
        let plan = try WikiRenamePlan.prepare(url, name: name, expected: expected ?? (selected == url ? savedData : nil))
        try commitRename(plan, coordinator: coordinator)
    }

    func renameWithLinks(_ url: URL, to name: String, expected: Data? = nil, validate: () throws -> Void = {}) async throws {
        guard !renameInProgress else { throw WikiRenameError.message("A rename is already running.") }
        renameInProgress = true
        defer { renameInProgress = false }
        let baseline = expected ?? (selected == url ? savedData : nil)
        let plan = try await Task.detached {
            let coordinator = WikiRenameCoordinator()
            try coordinator.recover(folder: url.deletingLastPathComponent())
            return try WikiRenamePlan.prepare(url, name: name, expected: baseline)
        }.value
        guard folder?.resolvingSymlinksInPath().standardizedFileURL.path == plan.folder.resolvingSymlinksInPath().standardizedFileURL.path else { throw WikiRenameError.message("The notes folder changed. Retry the rename.") }
        try validate()
        try commitRename(plan, coordinator: WikiRenameCoordinator())
    }

    private func commitRename(_ plan: WikiRenamePlan, coordinator: WikiRenameCoordinator) throws {
        let url = plan.folder.appendingPathComponent(plan.old)
        let files = NoteFileService()
        let notes = try files.list(in: plan.folder)
        let names = notes.map(\.name)
        let selectedKey = selected.map(editorKey)
        var liveEdits: [(name: String, session: NoteEditorSession?, edits: [WikiLinkEdit], after: String)] = []
        for note in notes {
            let key = editorKey(note.url)
            let session = editorSessions[key]
            let isSelected = selectedKey == key
            guard let liveText = session?.currentText ?? (isSelected ? text : nil) else { continue }
            let edits = try WikiLinks.edits(in: liveText, old: plan.old, new: plan.new, names: names)
            guard !edits.isEmpty else { continue }
            guard session?.hasMarkedText != true else {
                throw WikiRenameError.message("Finish composing text before renaming this note.")
            }
            liveEdits.append((note.name, session, edits, WikiLinkEdit.applying(edits, to: liveText)))
        }
        try coordinator.execute(plan)
        for update in liveEdits {
            update.session?.applyWikiEdits(update.edits)
            if selectedKey == editorKey(plan.folder.appendingPathComponent(update.name)) {
                text = update.after
            }
        }
        if let selected, let selectedKey {
            let selectedName = selectedKey == editorKey(url) ? plan.old : selected.lastPathComponent
            let committedData = selectedKey == editorKey(url)
                ? (plan.changes.first(where: { $0.name == plan.old })?.after ?? plan.source)
                : plan.changes.first(where: { $0.name == selectedName })?.after
            if let committedData {
                savedData = committedData
                savedText = String(decoding: committedData, as: UTF8.self)
            }
        }
        let renamed = plan.destination
        if let session = editorSessions.removeValue(forKey: editorKey(url)) {
            editorSessions[editorKey(renamed)] = session
        }
        if selected == url { selected = renamed }
        refresh(rename: NoteRename(source: url, destination: renamed,
            originalHash: WikiLinks.hash(plan.source),
            rewrittenHash: WikiLinks.hash(plan.changes.first(where: { $0.name == plan.old })?.after ?? plan.source)))
        for change in plan.changes {
            onSaved?(plan.folder.appendingPathComponent(change.name == plan.old ? plan.new : change.name))
        }
    }

    func delete(_ url: URL, confirming: Bool = true) {
        let expected: Data
        do {
            expected = url == selected ? savedData : try Data(contentsOf: url)
        } catch {
            report(error)
            return
        }
        if confirming {
            let alert = NSAlert()
            alert.messageText = "Move \(url.lastPathComponent) to Trash?"
            alert.informativeText = url == selected && isDirty
                ? "Unsaved edits will be discarded. The saved file can be restored from Trash."
                : "You can restore the saved file from Trash."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Move to Trash")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do {
            let dates = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let deleted = DeletedNote(url: url, data: expected,
                                      draft: url == selected && isDirty ? text : nil,
                                      session: editorSessions[editorKey(url)],
                                      created: dates.creationDate, modified: dates.contentModificationDate)
            try trashNote(url, expected)
            deletedNotes.append(deleted)
            editorSessions.removeValue(forKey: editorKey(url))
            if url == selected { clearSelection() }
            refresh()
        } catch { report(error) }
    }

    func deleteFromSidebar() {
        guard let selected else { return }
        let neighbor = navigationTarget(.next) ?? navigationTarget(.previous)
        delete(selected, confirming: false)
        guard self.selected == nil else { return }
        if let neighbor { open(neighbor, focusEditor: false) }
        focusSidebar()
    }

    func restoreDeletedNote() {
        guard let folder,
              let position = deletedNotes.lastIndex(where: {
                  $0.url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                    == folder.resolvingSymlinksInPath().standardizedFileURL.path
              }),
              canLeaveNote() else { return }
        let deleted = deletedNotes[position]
        do {
            // Exclusive creation also rejects a file that appears during restoration.
            try files.restore(deleted.data, to: deleted.url)
            deletedNotes.remove(at: position)
            var attributes: [FileAttributeKey: Any] = [:]
            if let created = deleted.created { attributes[.creationDate] = created }
            if let modified = deleted.modified { attributes[.modificationDate] = modified }
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: deleted.url.path)
            if let session = deleted.session { editorSessions[editorKey(deleted.url)] = session }
            refresh()
            open(deleted.url, focusEditor: false)
            if selected == deleted.url, let draft = deleted.draft { text = draft }
            focusSidebar()
        } catch { report(error) }
    }

    func canLeaveNote() -> Bool {
        guard isDirty else { return true }
        return save()
    }

    func windowCanClose() -> Bool {
        canLeaveNote()
    }

    private func clearSelection() {
        selected = nil
        findRequest = nil
        editorSession = NoteEditorSession()
        editorID = editorSession.id
        text = ""
        savedText = ""
        title = ""
        savedTitle = ""
        savedData = Data()
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}

@MainActor
final class NotesAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApplication.shared.applicationIconImage = icon
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = NoteStore.shared
        guard store.canLeaveNote() else { return .terminateCancel }
        return .terminateNow
    }
}

// Forward native delegate behavior while guarding the window's close button.
struct WindowCloseGuard: NSViewRepresentable {
    let store: NoteStore
    var translucent = AppearanceConfiguration.translucencyEnabled

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.coordinator = context.coordinator
        view.translucent = translucent
        return view
    }

    func updateNSView(_ nsView: GuardView, context: Context) {
        nsView.translucent = translucent
        nsView.applyAppearance()
        nsView.window?.isDocumentEdited = store.isDirty
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        let store: NoteStore
        weak var original: NSWindowDelegate?
        init(store: NoteStore) { self.store = store }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            (original?.windowShouldClose?(sender) ?? true) && store.windowCanClose()
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original
        }
    }

    final class GuardView: NSView {
        weak var coordinator: Coordinator?
        var translucent = true

        func applyAppearance() {
            guard let window else { return }
            if window.isOpaque != !translucent { window.isOpaque = !translucent }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = false
            window.backgroundColor = NSColor(NordTheme.background)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let coordinator else { return }
            if window.delegate !== coordinator {
                coordinator.original = window.delegate
                window.delegate = coordinator
            }
            applyAppearance()
            window.isDocumentEdited = coordinator.store.isDirty
        }
    }
}
