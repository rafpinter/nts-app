import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appearance: AppearanceSettings
    @ObservedObject var store: NoteStore
    @ObservedObject var databaseStatus: DatabaseStatus
    @ObservedObject var filenames: FilenameSuggestionController
    @ObservedObject var embeddings: NoteEmbeddingController
    @ObservedObject var mapController: NoteMapController
    @State private var shortcutsVisible = false
    @State private var sidebarVisible = true
    @State private var sidebarWidth: CGFloat = 220
    @State private var sidebarDragStart: CGFloat?
    @State private var renamingURL: URL?
    @State private var renameInHeader = false
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var renameFocusActivationPending = false
    @FocusState private var renameFocused: Bool
    @FocusState private var draftTitleFocused: Bool
    // The AppKit bridge owns first-responder focus; this is its request/state,
    // not a SwiftUI focus binding (there is no .focused editor target).
    @State private var editorFocused = false
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(NordTheme.border).frame(height: 1)
            GeometryReader { geometry in
                let maximumSidebarWidth = max(220, min(340, geometry.size.width - 401))
                HStack(spacing: 0) {
                    if sidebarVisible {
                        sidebar.frame(width: sidebarWidth)
                        sidebarDivider(maximumWidth: maximumSidebarWidth)
                    }
                    Group {
                        if store.isShowingMap {
                            NoteMapView(store: store, controller: mapController, embeddings: embeddings)
                        } else {
                            editor
                        }
                    }
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                }
                .onChange(of: maximumSidebarWidth) { _, maximum in
                    sidebarWidth = min(sidebarWidth, maximum)
                }
            }
            if let message = databaseStatus.failureMessage {
                HStack(alignment: .top, spacing: NordTheme.Space.medium) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Metadata storage or indexing unavailable. You can still open and save notes.")
                        Text(message).foregroundStyle(NordTheme.muted).textSelection(.enabled)
                        Text("Check storage access and free space, then retry. Existing data is kept.")
                            .foregroundStyle(NordTheme.muted)
                    }
                    Spacer()
                    Button("Retry") { Task { await databaseStatus.initialize() } }
                        .disabled(databaseStatus.isInitializing)
                }
                .font(NordTheme.caption)
                .padding(NordTheme.Space.medium)
                .background(NordTheme.sidebar.opacity(appearance.opacity(appearance.sidebarOpacity)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Metadata storage error")
            }
            if let message = filenames.message {
                HStack(spacing: NordTheme.Space.medium) {
                    if filenames.isDownloading {
                        ProgressView(value: filenames.downloadProgress, total: 1)
                            .frame(width: 120)
                    }
                    Text(message)
                        .font(NordTheme.caption)
                        .foregroundStyle(NordTheme.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(NordTheme.Space.medium)
                .background(NordTheme.sidebar.opacity(appearance.opacity(appearance.sidebarOpacity)))
            }
            footer
        }
        .font(NordTheme.body)
        .toolbar { noteToolbar }
        .toolbarBackground(NordTheme.background.opacity(appearance.opacity(appearance.headerOpacity)), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background { NoteWindowBackground() }
        .frame(minWidth: 680, minHeight: 480)
        .background(WindowCloseGuard(store: store, translucent: appearance.translucencyEnabled))
        .background(SidebarKeyboardShortcuts(active: sidebarFocused && !renameFocused && renamingURL == nil,
                                             store: store,
                                             onHelpVisibilityChanged: { shortcutsVisible = $0 },
                                             onEscape: {
            guard !renameFocused, renamingURL == nil else { return false }
            return filenames.dismissFilename(for: store.selected)
        }))
        .overlay {
            if shortcutsVisible {
                KeyboardShortcutCard()
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { store.restoreFolder() }
        .onChange(of: store.findRequest) { _, _ in
            cancelRename()
            sidebarFocused = false
            editorFocused = false // The finder owns focus while entering a query.
        }
        .onChange(of: store.editorFocusRequest) { _, _ in
            cancelRename()
            sidebarFocused = false
            editorFocused = true
        }
        .onChange(of: store.sidebarFocusRequest) { _, _ in
            cancelRename()
            sidebarVisible = true
            editorFocused = false
            sidebarFocused = true
        }
        .onChange(of: store.isLivePreview) { _, _ in
            cancelRename()
            sidebarFocused = false
            editorFocused = true
        }
        .onChange(of: renameFocused) { _, focused in
            if !focused, !renameFocusActivationPending { cancelRename() }
        }
        .onChange(of: store.folder) { _, _ in cancelRename() }
        .onChange(of: store.folder) { _, folder in
            guard store.isShowingMap else { return }
            embeddings.enableForFirstUse(folder: folder)
            mapController.refresh(folder: folder, indexingEnabled: embeddings.enabled)
        }
        .onChange(of: store.notes) { _, _ in
            guard store.isShowingMap else { return }
            mapController.refresh(folder: store.folder, indexingEnabled: embeddings.enabled)
        }
        .onChange(of: store.isShowingMap) { _, showingMap in
            if showingMap {
                sidebarFocused = false
                editorFocused = false
                embeddings.enableForFirstUse(folder: store.folder)
                mapController.refresh(folder: store.folder, indexingEnabled: embeddings.enabled)
            }
        }
        .onChange(of: embeddings.enabled) { _, _ in
            guard store.isShowingMap else { return }
            mapController.refresh(folder: store.folder, indexingEnabled: embeddings.enabled)
        }
        .onChange(of: embeddings.isWorking) { wasWorking, isWorking in
            guard store.isShowingMap, wasWorking, !isWorking else { return }
            mapController.refresh(folder: store.folder, indexingEnabled: embeddings.enabled)
        }
        .onChange(of: sidebarVisible) { _, visible in
            if !visible, !renameInHeader { cancelRename() }
        }
        .alert("File operation failed", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func sidebarDivider(maximumWidth: CGFloat) -> some View {
        Rectangle()
            .fill(NordTheme.border)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if sidebarDragStart == nil { sidebarDragStart = sidebarWidth }
                                sidebarWidth = max(220, min(maximumWidth,
                                    (sidebarDragStart ?? sidebarWidth) + value.translation.width))
                            }
                            .onEnded { _ in sidebarDragStart = nil }
                    )
            }
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(sidebarWidth)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: sidebarWidth = min(maximumWidth, sidebarWidth + 10)
                case .decrement: sidebarWidth = max(220, sidebarWidth - 10)
                @unknown default: break
                }
            }
    }

    @ToolbarContentBuilder
    private var noteToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Workspace", selection: Binding(
                get: { store.isShowingMap ? 1 : 0 },
                set: { if $0 == 1 { store.showMap() } else { store.showNotes() } }
            )) {
                Text("Notes").tag(0)
                Text("Map").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .accessibilityLabel("Workspace")
        }
        .withoutSharedBackground()
        ToolbarItemGroup(placement: .navigation) {
            Button {
                sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(NordTheme.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Toggle sidebar (⌘3)")
            .accessibilityLabel("Toggle sidebar")
            .keyboardShortcut("3", modifiers: .command)
            //     .tracking(2)
            //     .foregroundStyle(NordTheme.secondary)
            //     .fixedSize()
        }
        .withoutSharedBackground()
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: store.toggleEditingMode) {
                Image(systemName: "eye")
                    .foregroundStyle(store.isLivePreview ? NordTheme.accent : NordTheme.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.isLivePreview ? "Show Markdown source (⌘E)" : "Show Live Preview (⌘E)")
            .accessibilityLabel("Toggle Live Preview")
            .accessibilityValue(store.isLivePreview ? "On" : "Off")
            iconButton("folder", label: "Choose notes folder (⌘⇧O)", action: store.chooseFolder)
            iconButton("arrow.clockwise", label: "Refresh notes list", action: store.refresh)
                .disabled(store.folder == nil)
            iconButton("plus", label: "New note (⌘N)", action: store.create)
        }
        .withoutSharedBackground()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("NOTES").tracking(1.5)
                Spacer()
                Text("\(store.notes.count)")
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(NordTheme.surface, in: Capsule())
            }
            .font(NordTheme.caption)
            .foregroundStyle(NordTheme.muted)
            .padding(NordTheme.Space.large)

            if store.folder == nil {
                Spacer()
                Button("Choose notes folder", action: store.chooseFolder)
                    .buttonStyle(.bordered)
                    .padding(.horizontal, NordTheme.Space.medium)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if store.notes.isEmpty {
                Spacer()
                EmptyState(symbol: "tray", compact: true)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(store.notes) { note in
                                if renamingURL == note.url && !renameInHeader {
                                    inlineRename(note)
                                } else {
                                    Button {
                                        cancelRename()
                                        store.open(note.url)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(note.displayName)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Text(note.date, format: .dateTime.month(.abbreviated).day().year())
                                                .font(NordTheme.caption)
                                                .foregroundStyle(NordTheme.muted)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(store.selected == note.url ? NordTheme.surface : .clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(NordTheme.text)
                                    .help(note.displayName)
                                    .contextMenu {
                                        Button {
                                            filenames.dismissFilename(for: note.url)
                                            beginRename(note)
                                        } label: {
                                            Label("Rename…", systemImage: "pencil")
                                        }
                                        Button(role: .destructive) {
                                            store.delete(note.url)
                                        } label: {
                                            Label("Move to Trash", systemImage: "trash")
                                        }
                                    }
                                    .accessibilityAddTraits(store.selected == note.url ? .isSelected : [])
                                }
                            }
                        }
                        .padding(.horizontal, NordTheme.Space.small)
                    }
                    .onChange(of: store.selected) { _, selected in
                        if let selected { proxy.scrollTo(selected, anchor: .center) }
                    }
                }
            }


        }
        .frame(maxHeight: .infinity)
        .background(NordTheme.sidebar.opacity(appearance.opacity(appearance.sidebarOpacity)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notes sidebar")
        .focusable()
        .focusEffectDisabled()
        .focused($sidebarFocused)
        .onKeyPress(.upArrow) {
            guard sidebarFocused, !renameFocused, renamingURL == nil else { return .ignored }
            store.navigate(.previous, focusEditor: false)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard sidebarFocused, !renameFocused, renamingURL == nil else { return .ignored }
            store.navigate(.next, focusEditor: false)
            return .handled
        }
        .onKeyPress(.return) {
            guard sidebarFocused, !renameFocused, renamingURL == nil else { return .ignored }
            store.focusEditor()
            return .handled
        }

    }

    private func inlineRename(_ note: NoteFile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("Filename", text: $renameText)
                .textFieldStyle(.plain)
                .padding(4)
                .background(NordTheme.background, in: RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4).stroke(NordTheme.accent, lineWidth: 1)
                }
                .focused($renameFocused)
                .onAppear {
                    DispatchQueue.main.async {
                        guard renamingURL == note.url else { return }
                        renameFocused = true
                        renameFocusActivationPending = false
                    }
                }
                .onSubmit {
                    let name = renameText
                    Task {
                        do {
                            try await store.renameWithLinks(note.url, to: name)
                            cancelRename()
                        } catch { renameError = error.localizedDescription }
                    }
                }
                .onExitCommand { cancelRename() }
                .onChange(of: renameText) { _, _ in renameError = nil }
                .help("Return to rename; Escape or click away to cancel. .md is added automatically. Matching wiki links are updated.")
                .accessibilityLabel("Note filename")
            if let renameError {
                Text(renameError)
                    .font(NordTheme.caption)
                    .foregroundStyle(NordTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(note.date, format: .dateTime.month(.abbreviated).day().year())
                .font(NordTheme.caption)
                .foregroundStyle(NordTheme.muted)
        }
        .foregroundStyle(NordTheme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(NordTheme.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    private func cancelRename() {
        renamingURL = nil
        renameInHeader = false
        renameError = nil
        renameFocusActivationPending = false
        renameFocused = false
    }

    private func beginRename(_ note: NoteFile) {
        beginRename(note.url, inHeader: false)
    }

    private func beginRename(_ url: URL, inHeader: Bool) {
        editorFocused = false
        sidebarFocused = false
        renameFocusActivationPending = true
        renamingURL = url
        renameInHeader = inHeader
        renameText = url.deletingPathExtension().lastPathComponent
        renameError = nil
    }

    private var editorHeader: some View {
            HStack {
                if store.selected == nil {
                    TextField("Title", text: $store.title)
                        .textFieldStyle(.plain)
                        .focused($draftTitleFocused)
                        .onChange(of: draftTitleFocused) { _, focused in
                            if focused { editorFocused = false; sidebarFocused = false }
                        }
                        .accessibilityLabel("Note title; used as the filename when first saved")
                } else if let selected = store.selected {
                    if renameInHeader && renamingURL == selected {
                        TextField("Filename", text: $renameText)
                            .textFieldStyle(.plain)
                            .focused($renameFocused)
                            .onAppear {
                                DispatchQueue.main.async {
                                    guard renameInHeader, renamingURL == selected else { return }
                                    renameFocused = true
                                    renameFocusActivationPending = false
                                }
                            }
                            .onSubmit {
                                let name = renameText
                                Task {
                                    do {
                                        try await store.renameWithLinks(selected, to: name)
                                        cancelRename()
                                    } catch { renameError = error.localizedDescription }
                                }
                            }
                            .onExitCommand { cancelRename() }
                            .onChange(of: renameText) { _, _ in renameError = nil }
                            .accessibilityLabel("Note filename")
                            .help("Return to rename; Escape or click away to cancel. .md is added automatically. Matching wiki links are updated.")
                    } else {
                        Button {
                            filenames.dismissFilename(for: selected)
                            beginRename(selected, inHeader: true)
                        } label: {
                            Text(selected.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help("Click to rename note")
                        .accessibilityLabel("Rename note")
                    }
                }
                if store.isDirty {
                    Circle().fill(NordTheme.accent).frame(width: 6, height: 6)
                        .accessibilityLabel("Unsaved changes")
                }
                Spacer()
                iconButton("trash", label: "Move note to Trash", action: store.deleteSelected)
                    .disabled(store.selected == nil)
                    .opacity(store.selected == nil ? 0 : 1)
                    .accessibilityHidden(store.selected == nil)
            }
            .frame(height: 28)
            .foregroundStyle(NordTheme.muted)
            .padding(NordTheme.Space.large)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            editorHeader
            if renameInHeader, let renameError {
                Text(renameError)
                    .font(NordTheme.caption)
                    .foregroundStyle(NordTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NordTheme.Space.large)
            }
            if filenames.enabled, let selected = store.selected,
               let suggestion = filenames.suggestions[selected.lastPathComponent],
               suggestion.filename != selected.lastPathComponent {
                HStack(spacing: 8) {
                    if store.isDirty {
                        Text("Save to update the filename suggestion. Press ESC to dismiss.")
                    } else if suggestion.state == "ready", let filename = suggestion.filename {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Suggested: \(filename)").textSelection(.enabled)
                        }
                        Button(filenames.isApplying ? "Applying…" : "Apply") {
                            Task {
                                do { try await filenames.apply(filename, to: selected, in: store) }
                                catch { store.errorMessage = error.localizedDescription }
                            }
                        }
                        .disabled(filenames.isApplying)
                        .help("Apply this filename with ⌘S when the text is saved. Generate another with ⌘⇧S. Matching wiki links are updated.")
                        .accessibilityLabel("Apply suggested filename")
                    } else if let error = suggestion.error {
                        Text(error).textSelection(.enabled)
                    } else if suggestion.state == "queued" || suggestion.state == "processing" {
                        Text("Generating filename…")
                    }
                    Spacer()
                }
                .font(NordTheme.caption)
                .foregroundStyle(NordTheme.muted)
                .padding(.horizontal, NordTheme.Space.large)
                .padding(.bottom, 8)
            }
            Group {
                MarkdownEditor(text: $store.text, focusRequested: editorFocused && renamingURL == nil && !draftTitleFocused,
                               session: store.editorSession,
                               findRequest: store.findEditorID == store.editorID ? store.findRequest : nil,
                               findAction: store.findAction,
                               livePreview: store.isLivePreview, notesFolder: store.folder,
                               openNoteLink: store.openWikiLink,
                               onFocusChange: { focused in
                                   editorFocused = focused
                                   if focused { sidebarFocused = false }
                               },
                               importImages: store.importImages,
                               onError: store.reportImageError)
                    .id(store.editorID)
                    .font(NordTheme.editor)
                    .foregroundStyle(NordTheme.text)
                    .onAppear {
                        if !sidebarFocused, !renameFocused, !draftTitleFocused, renamingURL == nil { editorFocused = true }
                    }
                    .padding(.horizontal, NordTheme.Space.large)
                    .padding(.bottom, NordTheme.Space.large)
                    .accessibilityLabel(store.isLivePreview ? "Markdown live preview editor" : "Markdown source editor")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NordTheme.background.opacity(appearance.opacity(appearance.editorOpacity)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note editor")
        .onChange(of: store.selected) { _, selected in
            if renameInHeader, selected != renamingURL { cancelRename() }
        }
    }

    private var footer: some View {
        HStack {
            Circle().fill(NordTheme.accent).frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(store.folder == nil ? "No notes folder" : "\(store.notes.count) notes")
            Spacer()
            Text(store.selected == nil ? "Unsaved note" : (store.isDirty ? "Unsaved changes" : "Saved"))
        }
        .font(NordTheme.caption)
        .foregroundStyle(NordTheme.muted)
        .padding(.horizontal, NordTheme.Space.large)
        .frame(height: 30)
        .background(NordTheme.sidebar.opacity(appearance.opacity(appearance.sidebarOpacity)))
        .overlay(alignment: .top) {
            Rectangle().fill(NordTheme.border).frame(height: 1)
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(NordTheme.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

#Preview {
    let database = SQLiteDatabase()
    let metadata = DatabaseStatus(database: database)
    let embeddings = NoteEmbeddingController(database: database, metadata: metadata, backend: MLXNoteEmbedder())
    ContentView(store: NoteStore(), databaseStatus: metadata,
                filenames: FilenameSuggestionController(database: database, metadata: metadata, generator: MLXFilenameGenerator()),
                embeddings: embeddings, mapController: NoteMapController(database: database, metadata: metadata))
        .environmentObject(AppearanceSettings())
        .preferredColorScheme(.dark)
        .frame(width: 1080, height: 720)
}

// Intercept sidebar commands before the menu's text undo handling.
private struct SidebarKeyboardShortcuts: NSViewRepresentable {
    let active: Bool
    let store: NoteStore
    let onHelpVisibilityChanged: (Bool) -> Void
    let onEscape: () -> Bool

    func makeNSView(context: Context) -> KeyboardView { KeyboardView() }
    func updateNSView(_ view: KeyboardView, context: Context) {
        if view.active != active || view.armedNote != store.selected { view.firstDeletePress = nil }
        view.active = active
        view.store = store
        view.onEscape = onEscape
        view.onHelpVisibilityChanged = onHelpVisibilityChanged
    }

    final class KeyboardView: NSView {
        var onHelpVisibilityChanged: ((Bool) -> Void)?
        var onEscape: (() -> Bool)?
        var active = false
        weak var store: NoteStore?
        var armedNote: URL?
        var firstDeletePress: TimeInterval?
        private var monitor: Any?
        private var focusObservers: [NSObjectProtocol] = []
        private var helpKeyCode: UInt16?
        private var helpVisible = false

        private func hideHelp(clearKey: Bool = true) {
            if clearKey { helpKeyCode = nil }
            guard helpVisible else { return }
            helpVisible = false
            onHelpVisibilityChanged?(false)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
            focusObservers.removeAll()
            helpKeyCode = nil
            if helpVisible {
                helpVisible = false
                let callback = onHelpVisibilityChanged
                DispatchQueue.main.async { callback?(false) }
            }
            guard let window else { return }
            for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject?),
                                   (NSApplication.didResignActiveNotification, nil)] {
                focusObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: object, queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async { self?.hideHelp() }
                })
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true,
                      event.window === self.window || event.type == .flagsChanged else { return event }
                if event.type == .flagsChanged {
                    if !event.modifierFlags.contains(.command) { self.hideHelp(clearKey: false) }
                    return event
                }
                if event.type == .keyUp {
                    if event.keyCode == self.helpKeyCode {
                        self.hideHelp()
                        return nil
                    }
                    return event
                }
                // A held K keeps repeating after Command is released. Consume
                // those repeats until K-up, without showing the panel again.
                if event.isARepeat, event.keyCode == self.helpKeyCode { return nil }
                if event.charactersIgnoringModifiers?.lowercased() == "k",
                   event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
                    self.firstDeletePress = nil
                    if !event.isARepeat, self.helpKeyCode == nil {
                        self.helpKeyCode = event.keyCode
                        self.helpVisible = true
                        self.onHelpVisibilityChanged?(true)
                    }
                    return nil
                }
                // Let native search fields/visible find bars handle Escape first.
                if event.keyCode == 53, let text = self.window?.firstResponder as? NSTextView,
                   text.isFieldEditor || text.enclosingScrollView?.isFindBarVisible == true { return event }
                if event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                   self.onEscape?() == true { return nil }
                // AppKit's actual responder wins over delayed SwiftUI focus state.
                // This includes the native editor and inline filename text fields.
                guard !(self.window?.firstResponder is NSTextView), self.active else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                guard modifiers == .command else {
                    self.firstDeletePress = nil
                    return event
                }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "d":
                    guard !event.isARepeat else { return nil }
                    if let first = self.firstDeletePress, event.timestamp - first <= 1 {
                        self.firstDeletePress = nil
                        self.store?.deleteFromSidebar()
                    } else {
                        self.armedNote = self.store?.selected
                        self.firstDeletePress = event.timestamp
                    }
                    return nil
                case "z":
                    self.firstDeletePress = nil
                    if !event.isARepeat { self.store?.restoreDeletedNote() }
                    return nil
                default:
                    self.firstDeletePress = nil
                    return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}


private struct KeyboardShortcutCard: View {
    private let shortcuts: [(String, String)] = [
        ("New note", "⌘N"),
        ("Open note / choose folder", "⌘O / ⌘⇧O"),
        ("Save edits / accept ready name", "⌘S"),
        ("Regenerate filename", "⌘⇧S"),
        ("Cancel filename / close Find", "Esc"),
        ("Focus sidebar / editor", "⌘1 / ⌘2"),
        ("Toggle sidebar", "⌘3"),
        ("Previous / next note", "⌘⌥↑ / ⌘⌥↓"),
        ("Browse sidebar / enter editor", "↑ ↓ / Return"),
        ("Delete in sidebar", "⌘D, ⌘D"),
        ("Restore deletion in sidebar", "⌘Z"),
        ("Move to Trash (confirm)", "⌘⇧⌫"),
        ("Undo / redo text", "⌘Z / ⌘⇧Z"),
        ("Find in note", "⌘F"),
        ("Next / previous match", "⌘G / ⌘⇧G"),
        ("Source / live preview", "⌘E"),
        ("Settings / hold for shortcuts", "⌘, / ⌘K")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Keyboard shortcuts")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                Spacer()
                Image(systemName: "keyboard")
                    .foregroundStyle(NordTheme.accent)
            }
            VStack(spacing: 5) {
                ForEach(shortcuts, id: \.0) { action, keys in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(action)
                            .foregroundStyle(NordTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 20)
                        Text(keys)
                            .foregroundStyle(NordTheme.text)
                            .fixedSize()
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            Text("Release K or ⌘ to close")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NordTheme.muted)
        }
        .padding(20)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(NordTheme.text)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(NordTheme.secondary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard shortcuts. Release K or Command to close.")
    }
}


private extension ToolbarContent {
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
