import Foundation
import XCTest

final class NoteEmbeddingControllerTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var databaseURL: URL { root.appendingPathComponent("metadata.sqlite") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func runAsync(_ body: @escaping () async throws -> Void) {
        let finished = expectation(description: "Embedding controller work completed")
        Task.detached {
            do { try await body() } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
    }

    @objc func testDownloadBackfillsSavedNotesSkipsEmptyRetriesAndTracksProgress() {
        runAsync {
            let note = self.folder.appendingPathComponent("saved.md")
            let empty = self.folder.appendingPathComponent("empty.md")
            try Data("alpha topic".utf8).write(to: note)
            try Data(" \n\t".utf8).write(to: empty)
            let database = SQLiteDatabase(url: self.databaseURL)
            let metadata = await MainActor.run { DatabaseStatus(database: database) }
            await metadata.reconcile(folder: self.folder)
            await metadata.waitForPendingWork()

            let backend = FakeNoteEmbeddingBackend(failFirstRequest: true)
            let defaults = UserDefaults(suiteName: "EmbeddingControllerTests.\(UUID().uuidString)")!
            let controller = await MainActor.run {
                NoteEmbeddingController(database: database, metadata: metadata, backend: backend,
                                        defaults: defaults)
            }
            await MainActor.run { controller.activate(folder: self.folder) }
            await controller.downloadAndEnable()
            await controller.waitForWork()

            let enabled = await MainActor.run { controller.enabled }
            let progress = await MainActor.run { controller.downloadProgress }
            XCTAssertTrue(enabled)
            XCTAssertEqual(progress, 1)
            let notes = try await database.indexedEmbeddingNotes(folder: self.folder)
            let ids = Dictionary(uniqueKeysWithValues: notes.map { ($0.relativePath, $0.noteID) })
            let space = try EmbeddingModelConfiguration.current.space
            let vector = try await database.currentEmbedding(noteID: ids["saved.md"]!,
                                                             spaceFingerprint: space.fingerprint)
            XCTAssertEqual(vector?.count, 384)
            let emptyState = try await database.query(SQLiteStatement(
                "SELECT state FROM note_embeddings WHERE note_id = ?", [.text(ids["empty.md"]!)]))
            XCTAssertEqual(emptyState, [[.text("skipped-empty")]])
            let requests = await backend.requestCount
            XCTAssertEqual(requests, 2, "A transient failure retries once; empty notes skip inference.")
            let attempts = try await database.query(SQLiteStatement(
                "SELECT attempts FROM note_embeddings WHERE note_id = ?", [.text(ids["saved.md"]!)]))
            XCTAssertEqual(attempts, [[.integer(2)]])

            await MainActor.run { controller.disable() }
            await controller.waitForWork()
            await database.close()
        }
    }

    @objc func testChangedSaveRefreshAndDisableUseOnlyCurrentSavedBytes() {
        runAsync {
            let url = self.folder.appendingPathComponent("note.md")
            try Data("alpha saved content".utf8).write(to: url)
            let database = SQLiteDatabase(url: self.databaseURL)
            let metadata = await MainActor.run { DatabaseStatus(database: database) }
            let backend = FakeNoteEmbeddingBackend()
            let defaults = UserDefaults(suiteName: "EmbeddingControllerTests.\(UUID().uuidString)")!
            let controller = await MainActor.run {
                NoteEmbeddingController(database: database, metadata: metadata, backend: backend,
                                        defaults: defaults)
            }
            await MainActor.run { controller.activate(folder: self.folder) }
            await controller.downloadAndEnable()
            await metadata.reconcile(folder: self.folder)
            await metadata.waitForPendingWork()
            await MainActor.run { controller.refresh(folder: self.folder) }
            await controller.waitForWork()

            try Data("beta changed by a successful save".utf8).write(to: url)
            await metadata.reconcile(folder: self.folder)
            await metadata.waitForPendingWork()
            await MainActor.run { controller.refresh(folder: self.folder) }
            await controller.waitForWork()

            let notes = try await database.indexedEmbeddingNotes(folder: self.folder)
            let noteID = try XCTUnwrap(notes.first?.noteID)
            let space = try EmbeddingModelConfiguration.current.space
            var vector = try await database.currentEmbedding(noteID: noteID, spaceFingerprint: space.fingerprint)
            XCTAssertEqual(vector?[1], 1)

            try Data("gamma saved content".utf8).write(to: url)
            await metadata.reconcile(folder: self.folder)
            await metadata.waitForPendingWork()
            await controller.saved(url)
            await controller.waitForWork()

            vector = try await database.currentEmbedding(noteID: noteID, spaceFingerprint: space.fingerprint)
            XCTAssertEqual(vector?[0], 1)
            let requestCount = await backend.requestCount
            XCTAssertEqual(requestCount, 3)

            await MainActor.run { controller.disable() }
            try Data("gamma after disable".utf8).write(to: url)
            await metadata.reconcile(folder: self.folder)
            await metadata.waitForPendingWork()
            await controller.saved(url)
            await MainActor.run {
                controller.refresh(folder: self.folder)
            }
            await controller.waitForWork()
            let afterDisable = await backend.requestCount
            XCTAssertEqual(afterDisable, requestCount)
            await database.close()
        }
    }

    @objc func testRapidSavedEventsCoalesceWhileAnEmbeddingIsInFlight() {
        runAsync {
            let url = self.folder.appendingPathComponent("note.md")
            try Data("first saved contents".utf8).write(to: url)
            let database = SQLiteDatabase(url: self.databaseURL)
            let metadata = await MainActor.run { DatabaseStatus(database: database) }
            await metadata.reconcile(folder: self.folder)
            await metadata.waitForPendingWork()
            let backend = BlockingNoteEmbeddingBackend()
            let defaults = UserDefaults(suiteName: "EmbeddingControllerTests.\(UUID().uuidString)")!
            let controller = await MainActor.run {
                NoteEmbeddingController(database: database, metadata: metadata, backend: backend,
                                        defaults: defaults)
            }
            await MainActor.run { controller.activate(folder: self.folder) }
            await controller.downloadAndEnable()
            await backend.waitForFirstRequest()

            try Data("latest saved contents".utf8).write(to: url)
            await metadata.reconcile(folder: self.folder)
            await metadata.waitForPendingWork()
            await controller.saved(url)
            await controller.saved(url)
            await backend.releaseFirstRequest()
            await controller.waitForWork()

            let requests = await backend.requestCount
            XCTAssertEqual(requests, 2, "The active job and one coalesced latest save should run.")
            let notes = try await database.indexedEmbeddingNotes(folder: self.folder)
            let noteID = try XCTUnwrap(notes.first?.noteID)
            let space = try EmbeddingModelConfiguration.current.space
            let vector = try await database.currentEmbedding(noteID: noteID, spaceFingerprint: space.fingerprint)
            XCTAssertEqual(vector?[1], 1)
            await MainActor.run { controller.disable() }
            await controller.waitForWork()
            await database.close()
        }
    }

    @objc func testDisableCancelsActiveWorkAndReenableRecoversIt() {
        runAsync {
            let url = self.folder.appendingPathComponent("note.md")
            try Data("saved before cancellation".utf8).write(to: url)
            let database = SQLiteDatabase(url: self.databaseURL)
            let metadata = await MainActor.run { DatabaseStatus(database: database) }
            await metadata.reconcile(folder: self.folder)
            await metadata.waitForPendingWork()
            let backend = BlockingNoteEmbeddingBackend()
            let defaults = UserDefaults(suiteName: "EmbeddingControllerTests.\(UUID().uuidString)")!
            let controller = await MainActor.run {
                NoteEmbeddingController(database: database, metadata: metadata, backend: backend,
                                        defaults: defaults)
            }
            await MainActor.run { controller.activate(folder: self.folder) }
            await controller.downloadAndEnable()
            await backend.waitForFirstRequest()

            await MainActor.run { controller.disable() }
            await backend.releaseFirstRequest()
            await controller.waitForWork()
            await controller.downloadAndEnable()
            await controller.waitForWork()

            let requests = await backend.requestCount
            XCTAssertEqual(requests, 2, "Re-enabling must recover the interrupted persisted job.")
            let notes = try await database.indexedEmbeddingNotes(folder: self.folder)
            let noteID = try XCTUnwrap(notes.first?.noteID)
            let space = try EmbeddingModelConfiguration.current.space
            let vector = try await database.currentEmbedding(noteID: noteID, spaceFingerprint: space.fingerprint)
            XCTAssertEqual(vector?[0], 1)
            await MainActor.run { controller.disable() }
            await controller.waitForWork()
            await database.close()
        }
    }

    @objc func testMapFirstUseDownloadsMissingModelButStartupRefreshDoesNot() {
        runAsync {
            let url = self.folder.appendingPathComponent("note.md")
            try Data("first map use".utf8).write(to: url)
            let database = SQLiteDatabase(url: self.databaseURL)
            let metadata = await MainActor.run { DatabaseStatus(database: database) }
            await metadata.reconcile(folder: self.folder)
            await metadata.waitForPendingWork()
            let backend = FakeNoteEmbeddingBackend()
            let defaults = UserDefaults(suiteName: "EmbeddingControllerTests.\(UUID().uuidString)")!
            defaults.set(true, forKey: "noteEmbeddingsEnabled")
            let controller = await MainActor.run {
                NoteEmbeddingController(database: database, metadata: metadata, backend: backend,
                                        defaults: defaults)
            }

            await MainActor.run { controller.activate(folder: self.folder) }
            await controller.waitForWork()
            let startupDownloads = await backend.downloadCount
            XCTAssertEqual(startupDownloads, 0)

            await MainActor.run { controller.enableForFirstUse(folder: self.folder) }
            await controller.waitForWork()
            await MainActor.run { controller.enableForFirstUse(folder: self.folder) }
            await controller.waitForWork()

            let enabled = await MainActor.run { controller.enabled }
            let downloads = await backend.downloadCount
            XCTAssertTrue(enabled)
            XCTAssertEqual(downloads, 1)
            await MainActor.run { controller.disable() }
            await MainActor.run { controller.enableForFirstUse(folder: self.folder) }
            let remainedDisabled = await MainActor.run { !controller.enabled }
            let disabledDownloads = await backend.downloadCount
            XCTAssertTrue(remainedDisabled, "A prior explicit disable must suppress first-use auto-enabling.")
            XCTAssertEqual(disabledDownloads, 1)
            await database.close()
        }
    }
}

private actor FakeNoteEmbeddingBackend: NoteEmbeddingBackend {
    private(set) var available = false
    private(set) var downloadCount = 0
    private(set) var requestCount = 0
    private var failFirstRequest: Bool

    init(failFirstRequest: Bool = false) {
        self.failFirstRequest = failFirstRequest
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        downloadCount += 1
        available = true
        progress(0.5)
        progress(1)
    }

    func isAvailable() -> Bool { available }

    func embed(_ text: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [Float] {
        requestCount += 1
        if failFirstRequest {
            failFirstRequest = false
            throw TestEmbeddingFailure.transient
        }
        var vector = Array(repeating: Float.zero, count: 384)
        vector[text.contains("beta") ? 1 : 0] = 1
        progress(1)
        return vector
    }

    func unload() async {}
}

private enum TestEmbeddingFailure: Error {
    case transient
}

private actor BlockingNoteEmbeddingBackend: NoteEmbeddingBackend {
    private(set) var available = false
    private(set) var requestCount = 0
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        available = true
        progress(1)
    }

    func isAvailable() -> Bool { available }

    func waitForFirstRequest() async {
        if requestCount > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func releaseFirstRequest() {
        release?.resume()
        release = nil
    }

    func embed(_ text: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [Float] {
        requestCount += 1
        if requestCount == 1 {
            await withCheckedContinuation {
                release = $0
                started?.resume()
                started = nil
            }
        }
        var vector = Array(repeating: Float.zero, count: 384)
        vector[text.contains("latest") ? 1 : 0] = 1
        progress(1)
        return vector
    }

    func unload() async {}
}
