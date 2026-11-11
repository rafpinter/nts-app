import Foundation
import XCTest

final class NoteMapTests: XCTestCase {
    private var root: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func runAsync(_ body: @escaping () async throws -> Void) {
        let finished = expectation(description: "Map workflow completed")
        Task.detached {
            do { try await body() } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 90)
    }

    @objc func testCoordinateTransformPreservesAspectAndCentersDegenerateLayouts() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5)]
        let size = CGSize(width: 800, height: 400)
        let transform = MapCoordinateTransform(points: points, size: size)
        let first = transform.map(points[0], into: size)
        let second = transform.map(points[1], into: size)
        XCTAssertEqual(abs(second.x - first.x) / abs(second.y - first.y), 2, accuracy: 1e-10)
        XCTAssertGreaterThanOrEqual(first.x, 28)
        XCTAssertLessThanOrEqual(second.x, size.width - 28)
        XCTAssertGreaterThanOrEqual(second.y, 28)
        XCTAssertLessThanOrEqual(first.y, size.height - 28)

        let singleTransform = MapCoordinateTransform(points: [CGPoint(x: 7, y: -4)], size: size)
        XCTAssertEqual(singleTransform.map(CGPoint(x: 7, y: -4), into: size), CGPoint(x: 400, y: 200))
    }

    @objc func testMapReadinessRequiresIndexedSourceAndMatchingReadyEmbedding() {
        let ready = MapIndexedNote(noteID: "a", relativePath: "a.md", syncState: "indexed",
                                   sourceHash: "source", embeddingState: "ready",
                                   embeddingSourceHash: "source")
        XCTAssertTrue(ready.hasCurrentEmbedding)

        let stale = MapIndexedNote(noteID: "a", relativePath: "a.md", syncState: "indexed",
                                   sourceHash: "new-source", embeddingState: "ready",
                                   embeddingSourceHash: "old-source")
        XCTAssertFalse(stale.hasCurrentEmbedding)

        let indexingError = MapIndexedNote(noteID: "a", relativePath: "a.md", syncState: "error",
                                           sourceHash: "source", embeddingState: "ready",
                                           embeddingSourceHash: "source")
        XCTAssertFalse(indexingError.hasCurrentEmbedding)

        let staleEmpty = MapIndexedNote(noteID: "a", relativePath: "a.md", syncState: "indexed",
                                        sourceHash: "new-source", embeddingState: "skipped-empty",
                                        embeddingSourceHash: "old-source")
        XCTAssertFalse(staleEmpty.hasCurrentEmptyEmbedding)

        let staleError = MapIndexedNote(noteID: "a", relativePath: "a.md", syncState: "indexed",
                                        sourceHash: "new-source", embeddingState: "error",
                                        embeddingSourceHash: "old-source")
        XCTAssertFalse(staleError.hasCurrentEmbeddingError)

        let currentEmpty = MapIndexedNote(noteID: "a", relativePath: "a.md", syncState: "indexed",
                                          sourceHash: "source", embeddingState: "skipped-empty",
                                          embeddingSourceHash: "source")
        XCTAssertTrue(currentEmpty.hasCurrentEmptyEmbedding)
    }

    @objc func testEditorAndFindCommandsReturnToNotesWithoutDiscardingDraft() {
        MainActor.assumeIsolated {
            let store = NoteStore()
            store.text = "Unsaved draft"

            store.showMap()
            XCTAssertTrue(store.isShowingMap)
            store.focusEditor()
            XCTAssertFalse(store.isShowingMap)
            XCTAssertEqual(store.text, "Unsaved draft")

            store.showMap()
            store.find()
            XCTAssertFalse(store.isShowingMap)
            XCTAssertEqual(store.text, "Unsaved draft")

            store.showMap()
            store.focusSidebar()
            XCTAssertFalse(store.isShowingMap)
            XCTAssertEqual(store.text, "Unsaved draft")
        }
    }

    @objc func testSavedNoteMapLifecycleRestartRebuildRenameEditDeleteRestoreAndOffline() {
        runAsync {
                let databaseURL = self.root.appendingPathComponent("metadata.sqlite")
                let database = SQLiteDatabase(url: databaseURL)
                let metadata = await MainActor.run { DatabaseStatus(database: database) }
                let defaultsName = "NoteMapWorkflow.\(UUID().uuidString)"
                defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
                let backend = MapWorkflowEmbeddingBackend()
                let trashFolder = self.root.appendingPathComponent("test-trash")
                try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)

                let alpha = try NoteFileService().create(in: self.folder, text: "alpha topic")
                let beta = try NoteFileService().create(in: self.folder, text: "beta topic")
                _ = try NoteFileService().create(in: self.folder, text: "gamma topic")

                let embeddings = await MainActor.run {
                    NoteEmbeddingController(database: database, metadata: metadata,
                                            backend: backend,
                                            defaults: UserDefaults(suiteName: defaultsName)!)
                }
                await MainActor.run {
                    metadata.onReconciled = { folder in embeddings.refresh(folder: folder) }
                }
                let store = try await MainActor.run {
                    let store = NoteStore(index: metadata, defaults: UserDefaults(suiteName: defaultsName)!, trashNote: { url, _ in
                        try FileManager.default.moveItem(
                            at: url, to: trashFolder.appendingPathComponent(url.lastPathComponent))
                    })
                    store.onFolderChanged = { embeddings.activate(folder: $0) }
                    store.onSaved = { url in Task { await embeddings.saved(url) } }
                    try store.activateFolder(self.folder)
                    return store
                }
                await metadata.waitForPendingWork()
                await embeddings.downloadAndEnable()
                await embeddings.waitForWork()

                let map = await MainActor.run { NoteMapController(database: database, metadata: metadata) }
                await MainActor.run { map.refresh(folder: self.folder, indexingEnabled: true) }
                await map.waitForWork()
                let initialProjection = await MainActor.run { map.projection }
                XCTAssertEqual(initialProjection?.positions.count, 3)
                let initialReadyCount = await MainActor.run { map.readyCount }
                XCTAssertEqual(initialReadyCount, 3)
                let betaIndexedNoteValue = await MainActor.run {
                    map.notes.first { $0.relativePath == beta.lastPathComponent }
                }
                let betaIndexedNote = try XCTUnwrap(betaIndexedNoteValue)
                XCTAssertTrue(initialProjection?.positions.contains { $0.noteID == betaIndexedNote.noteID } ?? false,
                              "The Map point resolves through its persisted embedding identity.")
                let originalIDs = try await database.indexedEmbeddingNotes(folder: self.folder)

                try await MainActor.run {
                    store.showMap()
                    store.open(self.folder.appendingPathComponent(betaIndexedNote.relativePath))
                    XCTAssertEqual(store.selected, beta)
                    XCTAssertFalse(store.isShowingMap, "Successful point open returns to Notes.")

                    store.text = "a draft blocked by an external conflict"
                    try Data("external edit".utf8).write(to: beta)
                    store.showMap()
                    store.open(alpha)
                    XCTAssertEqual(store.selected, beta)
                    XCTAssertTrue(store.isShowingMap)
                    XCTAssertEqual(store.text, "a draft blocked by an external conflict")

                    try Data("beta topic".utf8).write(to: beta)
                    store.text = "beta topic"
                    store.open(alpha)
                    XCTAssertEqual(store.selected, alpha)
                    XCTAssertFalse(store.isShowingMap)
                }

                await MainActor.run {
                    store.create()
                    store.text = "alpha newly saved note"
                    XCTAssertTrue(store.save())
                }
                try await self.waitForEmbeddings(embeddings, metadata: metadata, backend: backend, requestCount: 4)
                await MainActor.run { map.refresh(folder: self.folder, indexingEnabled: true) }
                await map.waitForWork()
                let savedProjection = await MainActor.run { map.projection }
                XCTAssertEqual(savedProjection?.positions.count, 3,
                               "Existing layouts stay intact until the user explicitly updates them.")
                let isSavedProjectionOutOfDate = await MainActor.run { map.isProjectionOutOfDate }
                XCTAssertTrue(isSavedProjectionOutOfDate)

                let savedLayout = try XCTUnwrap(savedProjection)
                try await database.execute(SQLiteStatement("""
                    UPDATE projection_runs SET reducer_version = ?, parameters_json = ? WHERE run_id = ?
                    """, [.text(NoteProjectionReducer.legacyVersion),
                          .text(NoteProjectionReducer.legacyParametersJSON), .text(savedLayout.runID)]))
                await MainActor.run { map.updateLayout(folder: self.folder) }
                await map.waitForWork()
                let updatedProjection = await MainActor.run { map.projection }
                XCTAssertEqual(updatedProjection?.positions.count, 4)
                let updatedInputs = try await database.currentProjectionInputs(
                    folder: self.folder,
                    spaceFingerprint: EmbeddingModelConfiguration.current.space.fingerprint)
                let canonicalResult = try await NoteProjectionReducer.project(updatedInputs)
                let expectedAlignedResult = NoteProjectionReducer.align(
                    canonicalResult, to: savedLayout.positions)
                let expectedByID = Dictionary(uniqueKeysWithValues: expectedAlignedResult.positions.map { ($0.noteID, $0) })
                for position in try XCTUnwrap(updatedProjection).positions {
                    let expected = try XCTUnwrap(expectedByID[position.noteID])
                    XCTAssertEqual(position.x, expected.x, accuracy: 1e-8)
                    XCTAssertEqual(position.y, expected.y, accuracy: 1e-8)
                }
                let isUpdatedProjectionOutOfDate = await MainActor.run { map.isProjectionOutOfDate }
                XCTAssertFalse(isUpdatedProjectionOutOfDate)
                let selectedCreatedURL = await MainActor.run { store.selected }
                let createdURL = try XCTUnwrap(selectedCreatedURL)
                let createdRows = try await database.indexedEmbeddingNotes(folder: self.folder)
                let createdNoteID = try XCTUnwrap(createdRows
                    .first(where: { $0.relativePath == createdURL.lastPathComponent })?.noteID)

                try await MainActor.run {
                    try store.rename(createdURL, to: "renamed")
                }
                await metadata.waitForPendingWork()
                await embeddings.waitForWork()
                let selectedRenamedURL = await MainActor.run { store.selected }
                let renamedURL = try XCTUnwrap(selectedRenamedURL)
                XCTAssertEqual(renamedURL.lastPathComponent, "renamed.md")
                let renamedRows = try await database.indexedEmbeddingNotes(folder: self.folder)
                let renamedID = try XCTUnwrap(renamedRows
                    .first(where: { $0.relativePath == renamedURL.lastPathComponent })?.noteID)
                XCTAssertEqual(renamedID, createdNoteID, "App renames preserve identity and embedding.")
                let renamedEmbedding = try await database.currentEmbedding(
                    noteID: renamedID, spaceFingerprint: EmbeddingModelConfiguration.current.space.fingerprint)
                XCTAssertEqual(renamedEmbedding?.count, 384)

                await MainActor.run {
                    store.text = "beta edited and saved"
                    XCTAssertTrue(store.save())
                }
                try await self.waitForEmbeddings(embeddings, metadata: metadata, backend: backend, requestCount: 5)
                await MainActor.run { map.refresh(folder: self.folder, indexingEnabled: true) }
                await map.waitForWork()
                let isEditedProjectionOutOfDate = await MainActor.run { map.isProjectionOutOfDate }
                let readyAfterEdit = await MainActor.run { map.readyCount }
                XCTAssertTrue(isEditedProjectionOutOfDate)
                XCTAssertEqual(readyAfterEdit, 4)

                await MainActor.run { store.delete(renamedURL, confirming: false) }
                await metadata.waitForPendingWork()
                await embeddings.waitForWork()
                let afterDelete = try await database.indexedEmbeddingNotes(folder: self.folder)
                XCTAssertFalse(afterDelete.contains { $0.noteID == createdNoteID })
                let postDeleteMetadata = try await database.query(SQLiteStatement(
                    "SELECT count(*) FROM notes WHERE id = ?", [.text(createdNoteID)]))
                XCTAssertEqual(postDeleteMetadata.count, 1)
                XCTAssertEqual(postDeleteMetadata.first?.first, .integer(0))

                await MainActor.run { store.restoreDeletedNote() }
                await metadata.waitForPendingWork()
                let restoredRows = try await database.indexedEmbeddingNotes(folder: self.folder)
                let restored = try XCTUnwrap(restoredRows.first { $0.relativePath == renamedURL.lastPathComponent })
                XCTAssertNotEqual(restored.noteID, createdNoteID)
                try await self.waitForEmbeddings(embeddings, metadata: metadata, backend: backend, requestCount: 6)
                await MainActor.run { map.refresh(folder: self.folder, indexingEnabled: true) }
                await map.waitForWork()
                let readyAfterRestore = await MainActor.run { map.readyCount }
                XCTAssertEqual(readyAfterRestore, 4)
                let restoredProjection = await MainActor.run { map.projection }
                XCTAssertEqual(restoredProjection?.positions.count, 4)

                await database.close()
                let restartedDatabase = SQLiteDatabase(url: databaseURL)
                let restartedMetadata = await MainActor.run { DatabaseStatus(database: restartedDatabase) }
                try await restartedDatabase.initialize()
                try await restartedDatabase.reconcile(folder: self.folder)
                let restartedMap = await MainActor.run {
                    NoteMapController(database: restartedDatabase, metadata: restartedMetadata)
                }
                await MainActor.run { restartedMap.refresh(folder: self.folder, indexingEnabled: false) }
                await restartedMap.waitForWork()
                let restartedRunID = await MainActor.run { restartedMap.projection?.runID }
                XCTAssertEqual(restartedRunID, restoredProjection?.runID,
                               "Restart should reuse the persisted layout.")
                let restartedReadyCount = await MainActor.run { restartedMap.readyCount }
                XCTAssertEqual(restartedReadyCount, 4,
                               "Cached embeddings remain useful without running inference.")
                await restartedDatabase.close()

                let rebuiltDatabase = SQLiteDatabase(url: self.root.appendingPathComponent("rebuilt.sqlite"))
                let rebuiltMetadata = await MainActor.run { DatabaseStatus(database: rebuiltDatabase) }
                try await rebuiltDatabase.initialize()
                try await rebuiltDatabase.reconcile(folder: self.folder)
                let rebuiltEmbeddings = await MainActor.run {
                    NoteEmbeddingController(database: rebuiltDatabase, metadata: rebuiltMetadata,
                                            backend: backend,
                                            defaults: UserDefaults(suiteName: defaultsName)!)
                }
                await MainActor.run { rebuiltEmbeddings.activate(folder: self.folder) }
                await rebuiltEmbeddings.waitForWork()
                let rebuiltRows = try await rebuiltDatabase.indexedEmbeddingNotes(folder: self.folder)
                XCTAssertEqual(rebuiltRows.count, 4)
                XCTAssertTrue(rebuiltRows.allSatisfy { !originalIDs.map(\.noteID).contains($0.noteID) })
                let rebuiltMap = await MainActor.run {
                    NoteMapController(database: rebuiltDatabase, metadata: rebuiltMetadata)
                }
                await MainActor.run { rebuiltMap.refresh(folder: self.folder, indexingEnabled: true) }
                await rebuiltMap.waitForWork()
                let rebuiltReadyCount = await MainActor.run { rebuiltMap.readyCount }
                let rebuiltPositionCount = await MainActor.run { rebuiltMap.projection?.positions.count }
                let rebuiltRunID = await MainActor.run { rebuiltMap.projection?.runID }
                XCTAssertEqual(rebuiltReadyCount, 4)
                XCTAssertEqual(rebuiltPositionCount, 4)
                XCTAssertNotEqual(rebuiltRunID, restoredProjection?.runID)

                await MainActor.run { rebuiltEmbeddings.disable() }
                await rebuiltEmbeddings.waitForWork()
                await rebuiltDatabase.close()
        }
    }

    private func waitForEmbeddings(
        _ controller: NoteEmbeddingController, metadata: DatabaseStatus,
        backend: MapWorkflowEmbeddingBackend, requestCount: Int
    ) async throws {
        for _ in 0..<100 {
            await metadata.waitForPendingWork()
            await controller.waitForWork()
            if await backend.requestCount >= requestCount { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(requestCount) embedding requests.")
    }

}

private actor MapWorkflowEmbeddingBackend: NoteEmbeddingBackend {
    private(set) var available = false
    private(set) var requestCount = 0

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        available = true
        progress(1)
    }

    func isAvailable() -> Bool { available }

    func embed(_ text: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [Float] {
        requestCount += 1
        var vector = Array(repeating: Float.zero, count: 384)
        let component: Int
        if text.contains("beta edited") { component = 3 }
        else if text.contains("alpha") { component = 0 }
        else if text.contains("beta") { component = 1 }
        else { component = 2 }
        vector[component] = 1
        progress(1)
        return vector
    }

    func unload() async {}
}
