import SwiftUI

@main
struct NtsApp: App {
    @NSApplicationDelegateAdaptor(NotesAppDelegate.self) private var appDelegate
    @StateObject private var store = NoteStore.shared
    @StateObject private var appearance = AppearanceSettings()

    @StateObject private var databaseStatus: DatabaseStatus
    @StateObject private var filenames: FilenameSuggestionController
    @StateObject private var embeddings: NoteEmbeddingController
    @StateObject private var mapController: NoteMapController
    private let filenameGenerator: MLXFilenameGenerator
    private let embeddingBackend: MLXNoteEmbedder

    init() {
        let database = SQLiteDatabase()
        let metadata = DatabaseStatus(database: database)
        let filenameGenerator = MLXFilenameGenerator()
        let embeddingBackend = MLXNoteEmbedder()
        _databaseStatus = StateObject(wrappedValue: metadata)
        _filenames = StateObject(wrappedValue: FilenameSuggestionController(
            database: database, metadata: metadata, generator: filenameGenerator))
        _embeddings = StateObject(wrappedValue: NoteEmbeddingController(
            database: database, metadata: metadata, backend: embeddingBackend))
        _mapController = StateObject(wrappedValue: NoteMapController(database: database, metadata: metadata))
        self.filenameGenerator = filenameGenerator
        self.embeddingBackend = embeddingBackend
    }

    private func generateFilename() {
        Task {
            do { try await filenames.regenerate(in: store) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    var body: some Scene {
        Window("Nts", id: "main") {
            ContentView(store: store, databaseStatus: databaseStatus, filenames: filenames,
                        embeddings: embeddings, mapController: mapController)
                .environmentObject(appearance)
                .task {
                    await LocalMLXResourceGate.shared.register(.filenames) { [weak filenameGenerator] in
                        await filenameGenerator?.unloadForSwitch()
                    }
                    await LocalMLXResourceGate.shared.register(.embeddings) { [weak embeddingBackend] in
                        await embeddingBackend?.unload()
                    }
                    store.onFolderChanged = { [weak filenames, weak embeddings] folder in
                        filenames?.activate(folder: folder)
                        embeddings?.activate(folder: folder)
                    }
                    store.onSaved = { [weak embeddings] url in
                        Task { await embeddings?.saved(url) }
                    }
                    databaseStatus.onReconciled = { [weak filenames, weak embeddings] folder in
                        filenames?.refresh(folder: folder)
                        embeddings?.refresh(folder: folder)
                    }
                    filenames.activate(folder: store.folder)
                    embeddings.activate(folder: store.folder)
                    store.connectIndex(databaseStatus)
                    await databaseStatus.initialize()
                }
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1080, height: 720)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { store.create() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Note…") { store.chooseNote() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(store.folder == nil)
                Button("Choose Notes Folder…") { store.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    Task {
                        do { try await filenames.save(in: store) }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Regenerate Filename", action: generateFilename)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Move Note to Trash") { store.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(store.selected == nil)
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find in Note…") { store.find() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { store.find(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { store.find(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandMenu("Navigate") {
                Button("Previous Note") { store.navigate(.previous) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(store.navigationTarget(.previous) == nil)
                Button("Next Note") { store.navigate(.next) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(store.navigationTarget(.next) == nil)
                Divider()
                Button("Focus Notes List") { store.focusSidebar() }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Focus Editor") { store.focusEditor() }
                    .keyboardShortcut("2", modifiers: .command)
            }
            CommandMenu("Local AI") {
                Button("Download Model and Enable Suggestions…") {
                    Task { await filenames.downloadAndEnable() }
                }
                .disabled(filenames.isDownloading || filenames.isWorking)
                if filenames.isDownloading {
                    ProgressView("Downloading filename model…", value: filenames.downloadProgress, total: 1)
                }
                Button("Generate Filename Suggestion", action: generateFilename)
                    .disabled(store.selected == nil || filenames.isGeneratingName)
                Divider()
                Button("Disable Filename Suggestions") { filenames.disable() }
                    .disabled(!filenames.enabled && !filenames.isDownloading)
                Divider()
                Button("Download Embedding Model and Enable Map Indexing…") {
                    Task { await embeddings.downloadAndEnable() }
                }
                .disabled(embeddings.isDownloading || embeddings.isWorking)
                if embeddings.isDownloading {
                    ProgressView("Downloading embedding model", value: embeddings.downloadProgress, total: 1)
                }
                if embeddings.enabled {
                    Button("Retry / Update Map Index") { embeddings.retry() }
                        .disabled(embeddings.isWorking)
                    Button("Disable Map Indexing") { embeddings.disable() }
                        .disabled(embeddings.isDownloading)
                }
                if let message = embeddings.message {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            CommandMenu("View") {
                Button(store.isLivePreview ? "Show Markdown Source" : "Show Live Preview") {
                    store.toggleEditingMode()
                }
                .keyboardShortcut("e", modifiers: .command)
            }
        }
        Settings {
            TabView {
                GeneralSettingsView(store: store)
                    .tabItem { Label("General", systemImage: "gearshape") }
                AppearanceSettingsView()
                    .tabItem { Label("Appearance", systemImage: "paintpalette") }
            }
            .environmentObject(appearance)
            .preferredColorScheme(.dark)
            .frame(width: 480, height: 480)
        }
    }
}
