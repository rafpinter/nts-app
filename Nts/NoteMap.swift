import SwiftUI

struct MapIndexedNote: Equatable, Sendable {
    let noteID: String
    let relativePath: String
    let syncState: String
    let sourceHash: String?
    let embeddingState: String?
    let embeddingSourceHash: String?

    var hasCurrentEmbedding: Bool {
        hasCurrentEmbeddingRecord && embeddingState == "ready"
    }

    var hasCurrentEmbeddingRecord: Bool {
        syncState == "indexed" && sourceHash != nil
            && sourceHash == embeddingSourceHash
    }

    var hasCurrentEmptyEmbedding: Bool { hasCurrentEmbeddingRecord && embeddingState == "skipped-empty" }
    var hasCurrentEmbeddingError: Bool { hasCurrentEmbeddingRecord && embeddingState == "error" }
}

@MainActor
final class NoteMapController: ObservableObject {
    @Published private(set) var notes: [MapIndexedNote] = []
    @Published private(set) var projection: StoredNoteProjection?
    @Published private(set) var isProjectionOutOfDate = false
    @Published private(set) var isLoading = false
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    private let database: SQLiteDatabase
    private let metadata: DatabaseStatus
    private let configuration: EmbeddingModelConfiguration
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    init(database: SQLiteDatabase, metadata: DatabaseStatus,
         configuration: EmbeddingModelConfiguration = .current) {
        self.database = database
        self.metadata = metadata
        self.configuration = configuration
    }

    var readyCount: Int { notes.filter(\.hasCurrentEmbedding).count }
    var pendingCount: Int {
        notes.filter {
            $0.syncState == "indexed" && $0.sourceHash != nil
                && !$0.hasCurrentEmbedding && !$0.hasCurrentEmptyEmbedding && !$0.hasCurrentEmbeddingError
        }.count
    }
    var emptyCount: Int { notes.filter(\.hasCurrentEmptyEmbedding).count }
    var errorCount: Int {
        notes.filter { $0.syncState == "error" || $0.hasCurrentEmbeddingError }.count
    }

    func refresh(folder: URL?, indexingEnabled: Bool) {
        generation = UUID()
        operation?.cancel()
        isLoading = folder != nil
        isUpdating = false
        errorMessage = nil
        guard let folder else {
            notes = []
            projection = nil
            isProjectionOutOfDate = false
            isLoading = false
            return
        }
        let token = generation
        operation = Task { await load(folder: folder, indexingEnabled: indexingEnabled, token: token) }
    }

    func updateLayout(folder: URL?) {
        guard let folder else { return }
        generation = UUID()
        operation?.cancel()
        isLoading = false
        isUpdating = true
        errorMessage = nil
        let token = generation
        operation = Task { await buildLayout(folder: folder, token: token) }
    }

    func waitForWork() async {
        await operation?.value
    }

    private func load(folder: URL, indexingEnabled: Bool, token: UUID) async {
        defer {
            if generation == token { isLoading = false }
        }
        do {
            await metadata.waitForPendingWork()
            try Task.checkCancellation()
            try await database.initialize()
            let space = try configuration.space
            try await database.registerEmbeddingSpace(space)
            let notes = try await database.mapIndexedNotes(folder: folder, spaceFingerprint: space.fingerprint)
            let inputs = try await database.currentProjectionInputs(
                folder: folder, spaceFingerprint: space.fingerprint)
            let latest = try await database.latestProjection(
                folder: folder, spaceFingerprint: space.fingerprint)
            guard generation == token, !Task.isCancelled else { return }
            self.notes = notes
            projection = latest
            isProjectionOutOfDate = latest.map { $0.inputFingerprint != inputs.inputFingerprint } ?? false
            if indexingEnabled, latest == nil, !inputs.inputs.isEmpty {
                isUpdating = true
                try await calculateAndPublish(inputs, folder: folder, token: token)
                guard generation == token, !Task.isCancelled else { return }
                projection = try await database.latestProjection(
                    folder: folder, spaceFingerprint: space.fingerprint)
                isProjectionOutOfDate = false
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == token else { return }
            errorMessage = "Could not load the Map: \(error.localizedDescription)"
        }
        if generation == token { isUpdating = false }
    }

    private func buildLayout(folder: URL, token: UUID) async {
        defer {
            if generation == token { isUpdating = false }
        }
        do {
            await metadata.waitForPendingWork()
            try Task.checkCancellation()
            try await database.initialize()
            let space = try configuration.space
            try await database.registerEmbeddingSpace(space)
            let notes = try await database.mapIndexedNotes(folder: folder, spaceFingerprint: space.fingerprint)
            self.notes = notes
            let previousProjection = try await database.latestProjection(
                folder: folder, spaceFingerprint: space.fingerprint)
            let inputs = try await database.currentProjectionInputs(
                folder: folder, spaceFingerprint: space.fingerprint)
            guard !inputs.inputs.isEmpty else {
                projection = previousProjection
                isProjectionOutOfDate = projection != nil
                return
            }
            try await calculateAndPublish(inputs, folder: folder, token: token,
                                          aligningTo: previousProjection?.positions)
            guard generation == token, !Task.isCancelled else { return }
            projection = try await database.currentProjection(
                folder: folder, spaceFingerprint: space.fingerprint)
            isProjectionOutOfDate = false
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == token else { return }
            errorMessage = "Could not update the Map layout: \(error.localizedDescription)"
            if let space = try? configuration.space {
                projection = try? await database.latestProjection(
                    folder: folder, spaceFingerprint: space.fingerprint)
                if let projection,
                   let inputs = try? await database.currentProjectionInputs(
                    folder: folder, spaceFingerprint: space.fingerprint) {
                    isProjectionOutOfDate = projection.inputFingerprint != inputs.inputFingerprint
                }
            }
        }
    }

    private func calculateAndPublish(
        _ inputs: ProjectionInputSnapshot, folder: URL, token: UUID,
        aligningTo previousPositions: [NoteProjectionPosition]? = nil
    ) async throws {
        var result = try await NoteProjectionReducer.project(inputs)
        if let previousPositions {
            result = NoteProjectionReducer.align(result, to: previousPositions)
        }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        _ = try await database.persistProjection(snapshot: inputs, result: result)
        try Task.checkCancellation()
    }
}

extension SQLiteDatabase {
    func mapIndexedNotes(folder: URL, spaceFingerprint: String) throws -> [MapIndexedNote] {
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let rows = try query(SQLiteStatement("""
            SELECT n.id, n.relative_path, n.sync_state, n.content_hash,
                   ne.state, ne.source_hash
            FROM notes n
            JOIN folders f ON f.id = n.folder_id
            LEFT JOIN note_embeddings ne ON ne.note_id = n.id AND ne.space_id = ?
            WHERE f.root_path = ?
            ORDER BY n.relative_path
            """, [.text(spaceFingerprint), .text(folderPath)]))
        return try rows.map { row in
            guard row.count == 6, case let .text(noteID) = row[0],
                  case let .text(relativePath) = row[1], case let .text(syncState) = row[2] else {
                throw SQLiteFailure(message: "A note status row is malformed.")
            }
            return MapIndexedNote(noteID: noteID, relativePath: relativePath, syncState: syncState,
                                  sourceHash: Self.optionalText(row[3]),
                                  embeddingState: Self.optionalText(row[4]),
                                  embeddingSourceHash: Self.optionalText(row[5]))
        }
    }

    private static func optionalText(_ value: SQLiteValue) -> String? {
        guard case let .text(text) = value else { return nil }
        return text
    }
}

struct MapCoordinateTransform {
    private let centerX: Double
    private let centerY: Double
    private let scale: Double

    init(points: [CGPoint], size: CGSize, padding: CGFloat = 28) {
        guard !points.isEmpty else {
            centerX = 0
            centerY = 0
            scale = 1
            return
        }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        centerX = Double((minX + maxX) / 2)
        centerY = Double((minY + maxY) / 2)
        let rangeX = max(Double(maxX - minX), 1e-12)
        let rangeY = max(Double(maxY - minY), 1e-12)
        let availableWidth = max(Double(size.width - 2 * padding), 1)
        let availableHeight = max(Double(size.height - 2 * padding), 1)
        scale = min(availableWidth / rangeX, availableHeight / rangeY)
    }

    func map(_ point: CGPoint, into size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + (point.x - centerX) * scale,
                y: size.height / 2 - (point.y - centerY) * scale)
    }
}

private struct MapDisplayNote: Identifiable {
    let id: String
    let filename: String
    let url: URL
    let x: Double?
    let y: Double?
}

private struct MapCoordinateKey: Hashable {
    let x: UInt64
    let y: UInt64

    init(x: Double, y: Double) {
        self.x = (x == 0 ? 0.0 : x).bitPattern
        self.y = (y == 0 ? 0.0 : y).bitPattern
    }
}

private struct MapPointGroup: Identifiable {
    let id: String
    let x: Double
    let y: Double
    let notes: [MapDisplayNote]
}

struct NoteMapView: View {
    private let pointDiameter: CGFloat = 10
    @ObservedObject var store: NoteStore
    @ObservedObject var controller: NoteMapController
    @ObservedObject var embeddings: NoteEmbeddingController
    @State private var hoveredGroupID: String?

    private var displayNotes: [MapDisplayNote] {
        guard let folder = store.folder else { return [] }
        let positions = Dictionary(uniqueKeysWithValues: (controller.projection?.positions ?? []).map {
            ($0.noteID, $0)
        })
        return controller.notes.map { status in
            let path = status.relativePath
            let currentFile = store.notes.first { $0.name == path }
            let position = status.hasCurrentEmbedding ? positions[status.noteID] : nil
            return MapDisplayNote(
                id: status.noteID,
                filename: currentFile?.name ?? URL(fileURLWithPath: path).lastPathComponent,
                url: currentFile?.url ?? folder.appendingPathComponent(path),
                x: position?.x, y: position?.y)
        }
    }

    private var pointGroups: [MapPointGroup] {
        var groups: [MapCoordinateKey: [MapDisplayNote]] = [:]
        for note in displayNotes {
            guard let x = note.x, let y = note.y else { continue }
            groups[MapCoordinateKey(x: x, y: y), default: []].append(note)
        }
        return groups.map { key, notes in
            let first = notes[0]
            return MapPointGroup(id: first.id, x: first.x ?? 0, y: first.y ?? 0,
                                 notes: notes.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending })
        }.sorted { $0.id < $1.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if store.isDirty {
                notice("Map reflects saved note contents only; the active unsaved draft may not be shown.",
                       symbol: "pencil.line")
            }
            if let error = controller.errorMessage {
                notice(error, symbol: "exclamationmark.triangle")
                    .foregroundStyle(NordTheme.secondary)
            }
            if store.folder == nil {
                ContentUnavailableView("Choose a notes folder",
                                       systemImage: "folder",
                                       description: Text("Choose a folder to build a map of your saved notes."))
            } else {
                mapCanvas
                    .padding(NordTheme.Space.medium)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Map of notes")
            }
        }
        .background(NordTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notes map")
    }

    private var statusBar: some View {
        HStack(spacing: NordTheme.Space.small) {
            Text(mapStatus)
                .lineLimit(2)
                .help(mapStatus)
            Spacer()
            if embeddings.isDownloading {
                ProgressView(value: embeddings.downloadProgress, total: 1)
                    .frame(width: 80)
            } else if !embeddings.enabled {
                Button("Enable Map…") {
                    Task { await embeddings.downloadAndEnable() }
                }
                .buttonStyle(.bordered)
            }
            if indexingNeedsRetry {
                Button("Retry") { embeddings.retry() }
                    .help("Retry failed embeddings and update the index")
            }
            if layoutNeedsUpdate {
                Button("Update map") { controller.updateLayout(folder: store.folder) }
                    .disabled(controller.isUpdating)
                    .help("Place currently indexed notes on the map")
            }
        }
        .font(NordTheme.caption)
        .foregroundStyle(NordTheme.muted)
        .padding(.horizontal, NordTheme.Space.large)
        .frame(minHeight: 42)
        .overlay(alignment: .bottom) { Rectangle().fill(NordTheme.border).frame(height: 1) }
    }

    private var indexingMessage: String? {
        guard let message = embeddings.message, !message.isEmpty,
              message != "Map index is up to date.", message != "Map index updated.",
              message != "Map indexing is disabled." else { return nil }
        return message
    }

    private var indexingNeedsRetry: Bool {
        embeddings.enabled && !embeddings.isWorking && !embeddings.isDownloading && store.folder != nil
            && (controller.notes.contains(where: \.hasCurrentEmbeddingError)
                || controller.pendingCount > 0 || indexingMessage != nil)
    }

    private var layoutNeedsUpdate: Bool {
        store.folder != nil && controller.readyCount > 0
            && (controller.isProjectionOutOfDate || controller.projection == nil)
    }

    private var mapStatus: String {
        if store.folder == nil { return "Choose a notes folder" }
        if embeddings.isDownloading { return "Downloading model…" }
        if controller.isUpdating { return "Updating map…" }
        if controller.isLoading { return "Loading map…" }
        if embeddings.isWorking { return "Indexing notes…" }
        if let message = indexingMessage { return message }
        if controller.notes.contains(where: \.hasCurrentEmbeddingError) { return "Some notes couldn't be indexed." }
        if controller.errorCount > 0 { return "Some notes couldn't be read. Refresh notes." }
        if !embeddings.enabled { return "Map indexing is off." }
        if controller.pendingCount > 0 { return "Some notes are waiting to be indexed." }
        if layoutNeedsUpdate { return "Map update available." }
        let count = pointGroups.reduce(0) { $0 + $1.notes.count }
        return count == 1 ? "1 note on map" : "\(count) notes on map"
    }

    private var mapCanvas: some View {
        GeometryReader { geometry in
            let groups = pointGroups
            let transform = MapCoordinateTransform(
                points: groups.map { CGPoint(x: $0.x, y: $0.y) }, size: geometry.size)
            ZStack {
                mapGrid
                Canvas { context, size in
                    for group in groups {
                        let point = transform.map(CGPoint(x: group.x, y: group.y), into: size)
                        let rect = CGRect(x: point.x - pointDiameter / 2, y: point.y - pointDiameter / 2,
                                          width: pointDiameter, height: pointDiameter)
                        context.fill(Path(ellipseIn: rect),
                                     with: .color(group.id == hoveredGroupID ? NordTheme.text : NordTheme.accent))
                        let center = rect.insetBy(dx: pointDiameter * 0.28, dy: pointDiameter * 0.28)
                        context.fill(Path(ellipseIn: center), with: .color(NordTheme.text.opacity(0.65)))
                    }
                }
                ForEach(groups) { group in
                    let point = transform.map(CGPoint(x: group.x, y: group.y), into: geometry.size)
                    pointControl(group)
                    .frame(width: pointDiameter, height: pointDiameter)
                    .contentShape(Circle())
                    .onHover { hovering in hoveredGroupID = hovering ? group.id : nil }
                    .position(point)
                }
                if let hoveredGroup = groups.first(where: { $0.id == hoveredGroupID }) {
                    let point = transform.map(
                    CGPoint(x: hoveredGroup.x, y: hoveredGroup.y), into: geometry.size)
                    let tooltipWidth = min(320, max(1, geometry.size.width - 24))
                    Text(hoveredGroup.notes.map(\.filename).joined(separator: ", "))
                    .font(NordTheme.caption)
                    .foregroundStyle(NordTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: tooltipWidth)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(NordTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(NordTheme.accent.opacity(0.35), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                    .position(x: min(max(point.x, tooltipWidth / 2 + 8),
                                     geometry.size.width - tooltipWidth / 2 - 8),
                              y: max(22, point.y - 30))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(2)
                }
                if groups.isEmpty {
                    VStack(spacing: NordTheme.Space.small) {
                        Image(systemName: controller.isLoading ? "arrow.triangle.2.circlepath" : "circle.dashed")
                            .font(.system(size: 30, weight: .light, design: .monospaced))
                            .foregroundStyle(NordTheme.accent)
                            .accessibilityHidden(true)
                        Text("NOTE MAP")
                            .font(NordTheme.sectionTitle)
                            .tracking(2)
                            .foregroundStyle(NordTheme.secondary)
                        Text(emptyMapMessage)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }
                    .font(NordTheme.body)
                    .foregroundStyle(NordTheme.muted)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [NordTheme.surface.opacity(0.72), NordTheme.sidebar],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(NordTheme.border.opacity(0.85), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityElement(children: .contain)
    }

    private var mapGrid: some View {
        Canvas { context, size in
            var grid = Path()
            let spacing: CGFloat = 48
            for x in stride(from: spacing, to: size.width, by: spacing) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: spacing, to: size.height, by: spacing) {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(NordTheme.secondary.opacity(0.045)), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func pointControl(_ group: MapPointGroup) -> some View {
        if group.notes.count == 1, let note = group.notes.first {
            Button { open(note) } label: {
                Circle().fill(Color.clear).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(note.filename)
            .accessibilityLabel(note.filename)
        } else {
            Menu {
                ForEach(group.notes) { note in
                    Button(note.filename) { open(note) }
                }
            } label: {
                Circle().fill(Color.clear).contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .help(group.notes.map(\.filename).joined(separator: ", "))
            .accessibilityLabel("Overlapping notes: \(group.notes.map(\.filename).joined(separator: ", "))")
        }
    }

    private func notice(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(NordTheme.caption)
            .foregroundStyle(NordTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NordTheme.Space.large)
            .padding(.vertical, NordTheme.Space.small)
            .background(NordTheme.sidebar)
    }

    private var emptyMapMessage: String {
        if controller.isLoading { return "Loading current note and embedding status…" }
        if store.folder == nil { return "Choose a notes folder to see the map." }
        if controller.readyCount == 0 {
            if !embeddings.enabled { return "Enable Map indexing to create local embeddings for saved notes." }
            if controller.notes.contains(where: \.hasCurrentEmbeddingError) {
                return "Some notes could not be indexed. Try again using Retry."
            }
            if controller.errorCount > 0 { return "Some notes could not be read. Refresh the notes list." }
            if controller.pendingCount > 0 { return "Waiting for current note embeddings before placing notes." }
            if controller.emptyCount > 0 { return "No non-empty notes have a usable embedding yet." }
            return "No current note embeddings are available yet."
        }
        if controller.isProjectionOutOfDate {
            return "The previous layout is out of date. Update the map to include current notes."
        }
        return "Update the map to place the ready notes."
    }

    private func open(_ note: MapDisplayNote) {
        store.open(note.url)
    }
}
