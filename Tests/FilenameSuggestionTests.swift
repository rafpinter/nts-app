import Foundation
import XCTest

private actor StubFilenameGenerator: FilenameGenerating {
    var calls = 0
    var fail = false
    var output = "saved-note"
    var queuedOutputs: [String] = []
    var transientFailures = 0
    func download(configuration: FilenameModelConfiguration, progress: @escaping @Sendable (Double) -> Void) async throws { }
    func generate(text: String, configuration: FilenameModelConfiguration) async throws -> String {
        calls += 1
        if transientFailures > 0 {
            transientFailures -= 1
            throw FilenameSuggestionFailure(message: "fixture transient failure")
        }
        if fail { throw FilenameSuggestionFailure(message: "fixture inference failure") }
        if !queuedOutputs.isEmpty { return queuedOutputs.removeFirst() }
        return output
    }
    func unload() { }
    func setFailure(_ value: Bool) { fail = value }
    func setOutput(_ value: String) { output = value }
    func setOutputs(_ values: [String]) { queuedOutputs = values }
    func setTransientFailures(_ count: Int) { transientFailures = count }
}

private actor SuspendedFilenameGenerator: FilenameGenerating {
    private var started = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private var calls = 0
    func download(configuration: FilenameModelConfiguration, progress: @escaping @Sendable (Double) -> Void) async throws { }
    func generate(text: String, configuration: FilenameModelConfiguration) async throws -> String {
        calls += 1
        if calls == 1 {
            started = true
            waiting?.resume()
            waiting = nil
            await withCheckedContinuation { gate = $0 }
        }
        return "saved-note"
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { gate?.resume(); gate = nil }
    func unload() { }
}

private actor LazyDownloadFilenameGenerator: FilenameGenerating {
    private var available = false
    private var downloadCount = 0
    private var generationCount = 0
    private var failFirstDownload: Bool

    init(failFirstDownload: Bool = false) {
        self.failFirstDownload = failFirstDownload
    }

    func download(configuration: FilenameModelConfiguration, progress: @escaping @Sendable (Double) -> Void) async throws {
        downloadCount += 1
        if failFirstDownload {
            failFirstDownload = false
            throw FilenameSuggestionFailure(message: "fixture download failure")
        }
        progress(0.5)
        available = true
    }

    func isAvailable(configuration: FilenameModelConfiguration) async -> Bool { available }

    func generate(text: String, configuration: FilenameModelConfiguration) async throws -> String {
        generationCount += 1
        return "lazy-title"
    }

    func unload() { }
    func counts() -> (downloads: Int, generations: Int) { (downloadCount, generationCount) }
}

private actor ProgressFilenameGenerator: FilenameGenerating {
    private var started = false
    private var available = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var downloadContinuation: CheckedContinuation<Void, Never>?

    func download(configuration: FilenameModelConfiguration, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(-0.5)
        progress(0.4)
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { downloadContinuation = $0 }
        progress(1.5)
        available = true
    }

    func isAvailable(configuration: FilenameModelConfiguration) async -> Bool { available }
    func generate(text: String, configuration: FilenameModelConfiguration) async throws -> String { "saved-note" }
    func unload() { }

    func waitUntilStarted() async {
        if !started {
            await withCheckedContinuation { startedContinuation = $0 }
        }
    }

    func finishDownload() {
        downloadContinuation?.resume()
        downloadContinuation = nil
    }
}

final class FilenameSuggestionTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var databaseURL: URL!
    private var applicationDefaultsName: String!
    private let config = FilenameModelConfiguration.filename

    override func setUpWithError() throws {
        applicationDefaultsName = "FilenameApplyTests.\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = root.appendingPathComponent("notes")
        databaseURL = root.appendingPathComponent("metadata.sqlite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: applicationDefaultsName)
        try FileManager.default.removeItem(at: root)
    }
    private func runAsync(_ body: @escaping () async throws -> Void) {
        let finished = expectation(description: "Filename work completed")
        Task.detached {
            do { try await body() } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 25)
    }
    private func note(_ text: String = "Saved text") throws -> URL {
        let url = folder.appendingPathComponent("note.md")
        try Data(text.utf8).write(to: url)
        return url
    }
    private func database() async throws -> SQLiteDatabase {
        let db = SQLiteDatabase(url: databaseURL)
        try await db.initialize()
        try await db.reconcile(folder: folder)
        return db
    }
    @objc func testRenameDiscardsRetainedFilenamePreview() {
        runAsync {
            let url = try self.note()
            let db = try await self.database()
            let job = try await self.job(db, url: url)
            _ = try await db.filenameInput(job)
            try await db.finishFilename(job, filename: "saved-note.md", error: nil)
            let renamed = try NoteFileService().rename(url, to: "chosen-title.md")
            try await db.reconcile(folder: self.folder, rename: NoteRename(source: url, destination: renamed))
            let suggestions = try await db.filenameSuggestions(folder: self.folder, configuration: self.config)
            XCTAssertTrue(suggestions.isEmpty)
            await db.close()
            let reopened = SQLiteDatabase(url: self.databaseURL)
            try await reopened.initialize()
            let persisted = try await reopened.filenameSuggestions(folder: self.folder, configuration: self.config)
            XCTAssertTrue(persisted.isEmpty)
            await reopened.close()
        }
    }

    private func job(_ db: SQLiteDatabase, url: URL) async throws -> FilenameJob {
        try await db.queueFilename(url: url, configuration: config)
        let jobs = try await db.pendingFilenames(folder: folder, configuration: config)
        return try XCTUnwrap(jobs.first)
    }

    private func applicationFixture(text: String = "Saved text", generator: any FilenameGenerating = StubFilenameGenerator()) async throws
        -> (URL, SQLiteDatabase, DatabaseStatus, NoteStore, FilenameSuggestionController) {
        let url = try note(text)
        let db = try await database()
        let job = try await job(db, url: url)
        _ = try await db.filenameInput(job)
        try await db.finishFilename(job, filename: "saved-note.md", error: nil)
        let defaults = UserDefaults(suiteName: applicationDefaultsName)!
        defaults.set(true, forKey: "filenameSuggestionsEnabled")
        let (metadata, store, service) = try await MainActor.run {
            let metadata = DatabaseStatus(database: db)
            let service = FilenameSuggestionController(database: db, metadata: metadata,
                generator: generator, defaults: defaults)
            let store = NoteStore(index: metadata, defaults: defaults)
            store.onFolderChanged = { [weak service] folder in service?.activate(folder: folder) }
            metadata.onReconciled = { [weak service] folder in service?.refresh(folder: folder) }
            try store.activateFolder(self.folder)
            store.open(url)
            return (metadata, store, service)
        }
        await metadata.waitForPendingWork()
        await service.waitForWork()
        return (url, db, metadata, store, service)
    }

    @objc func testEscapeDismissesPreviewWithoutRenamingAndAllowsRegeneration() {
        runAsync {
            let (url, db, _, store, service) = try await self.applicationFixture()
            let dismissed = await service.dismissFilename(for: url)
            XCTAssertTrue(dismissed)
            await service.refresh(folder: self.folder)
            await service.waitForWork()
            try await service.save(in: store)
            let selected = await store.selected
            XCTAssertEqual(selected, url)
            let preview = await service.suggestions[url.lastPathComponent]
            XCTAssertNil(preview)
            let persisted = try await db.filenameSuggestions(folder: self.folder, configuration: self.config)
            XCTAssertNil(persisted[url.lastPathComponent])
            try await service.regenerate(in: store)
            let regenerated = await service.suggestions[url.lastPathComponent]
            XCTAssertEqual(regenerated?.state, "ready")
        }
    }

    @objc func testEscapeDuringInferenceDiscardsLateOutputWithoutError() {
        runAsync {
            let generator = SuspendedFilenameGenerator()
            let (url, _, _, store, service) = try await self.applicationFixture(generator: generator)
            let operation = Task { try await service.regenerate(in: store) }
            await generator.waitUntilStarted()
            let dismissed = await service.dismissFilename(for: url)
            XCTAssertTrue(dismissed)
            await generator.release()
            try await operation.value
            await service.waitForWork()
            let preview = await service.suggestions[url.lastPathComponent]
            let selected = await store.selected
            let message = await service.message
            XCTAssertNil(preview)
            XCTAssertNil(message)
            XCTAssertEqual(selected, url)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Saved text")
            try await service.regenerate(in: store)
            let regenerated = await service.suggestions[url.lastPathComponent]
            XCTAssertEqual(regenerated?.state, "ready")
        }
    }

    @objc func testApplyPreservesEditorIdentityDatesContentsAndLinks() {
        runAsync {
            let text = "# Portable\n![image](imgs/photo.png)\n"
            let link = self.folder.appendingPathComponent("reference.md")
            try Data("[note](note.md) [[note|alias]]".utf8).write(to: link)
            let (url, db, metadata, store, service) = try await self.applicationFixture(text: text)
            let before = try await db.query(SQLiteStatement("SELECT id, preserved_created_at, content_hash FROM notes WHERE relative_path = 'note.md'"))
            let editorID = await MainActor.run { store.editorID }
            try await service.apply("saved-note.md", to: url, in: store)
            await metadata.waitForPendingWork()
            await service.waitForWork()
            let renamed = self.folder.appendingPathComponent("saved-note.md")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), text)
            XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "[note](note.md) [[saved-note|alias]]")
            let after = try await db.query(SQLiteStatement("SELECT id, preserved_created_at, content_hash FROM notes WHERE relative_path = 'saved-note.md'"))
            XCTAssertEqual(before, after)
            await MainActor.run {
                XCTAssertEqual(store.selected, renamed)
                XCTAssertEqual(store.editorID, editorID)
                XCTAssertEqual(store.text, text)
                XCTAssertFalse(store.isDirty)
            }
            // Applying a filename that is already current is harmless.
            try await service.apply("saved-note.md", to: renamed, in: store)
            await db.close()
        }
    }

    @objc func testApplyRefusesExternalEditsAndChangedModelConfiguration() {
        runAsync {
            let (url, db, _, store, service) = try await self.applicationFixture()
            try Data("external edit".utf8).write(to: url)
            do {
                try await service.apply("saved-note.md", to: url, in: store)
                XCTFail("External edits must invalidate Apply even before Refresh")
            } catch { }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external edit")
            XCTAssertFalse(FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("saved-note.md").path))
            try Data("Saved text".utf8).write(to: url)
            var changed = self.config
            changed.temperature = 0.4
            try await db.queueFilename(url: url, configuration: changed)
            let jobs = try await db.pendingFilenames(folder: self.folder, configuration: changed)
            let job = try XCTUnwrap(jobs.first)
            _ = try await db.filenameInput(job)
            try await db.finishFilename(job, filename: "saved-note.md", error: nil)
            do {
                try await service.apply("saved-note.md", to: url, in: store)
                XCTFail("A suggestion from another model configuration must not apply")
            } catch { }
            await MainActor.run { XCTAssertEqual(store.selected, url) }
            await db.close()
        }
    }

    @objc func testApplyCollisionKeepsBothFilesAndCanRetry() {
        runAsync {
            let (url, db, metadata, store, service) = try await self.applicationFixture()
            let destination = self.folder.appendingPathComponent("saved-note.md")
            try Data("other note".utf8).write(to: destination)
            do {
                try await service.apply("saved-note.md", to: url, in: store)
                XCTFail("Apply must never replace an existing file")
            } catch { }
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "other note")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Saved text")
            await MainActor.run { XCTAssertEqual(store.selected, url) }
            try FileManager.default.removeItem(at: destination)
            try await service.apply("saved-note.md", to: url, in: store)
            await metadata.waitForPendingWork()
            await service.waitForWork()
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Saved text")
            await db.close()
        }
    }

    @objc func testApplyRefusesDirtyDraftAndMissingSource() {
        runAsync {
            let (url, db, _, store, service) = try await self.applicationFixture()
            await MainActor.run { store.text = "keep this unsaved draft" }
            do {
                try await service.apply("saved-note.md", to: url, in: store)
                XCTFail("A suggestion based on saved text must not apply to a dirty draft")
            } catch { }
            await MainActor.run {
                XCTAssertEqual(store.text, "keep this unsaved draft")
                XCTAssertTrue(store.isDirty)
            }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Saved text")
            await MainActor.run { store.text = "Saved text" }
            try FileManager.default.removeItem(at: url)
            do {
                try await service.apply("saved-note.md", to: url, in: store)
                XCTFail("A missing source must not be recreated or renamed")
            } catch { }
            await MainActor.run { XCTAssertEqual(store.text, "Saved text") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("saved-note.md").path))
            await db.close()
        }
    }

    @objc func testCoordinatedRenameRechecksBytesAfterApplicationValidation() throws {
        let url = try note()
        let original = try Data(contentsOf: url)
        try Data("changed after validation".utf8).write(to: url)
        XCTAssertThrowsError(try NoteFileService().rename(url, to: "saved-note.md", expected: original))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "changed after validation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("saved-note.md").path))
    }

    @objc func testApplyFilesystemSuccessSurvivesIndexFailureAndRetry() {
        runAsync {
            let (url, db, metadata, store, service) = try await self.applicationFixture()
            try await db.execute(SQLiteStatement("""
                CREATE TRIGGER reject_app_rename BEFORE UPDATE OF relative_path ON notes
                BEGIN SELECT RAISE(ABORT, 'fixture index failure'); END
                """))
            try await service.apply("saved-note.md", to: url, in: store)
            await metadata.waitForPendingWork()
            await service.waitForWork()
            let renamed = self.folder.appendingPathComponent("saved-note.md")
            XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "Saved text")
            await MainActor.run {
                XCTAssertEqual(store.selected, renamed)
                XCTAssertNil(store.errorMessage)
                XCTAssertNotNil(metadata.failureMessage)
            }
            try await db.execute(SQLiteStatement("DROP TRIGGER reject_app_rename"))
            await metadata.initialize()
            await service.waitForWork()
            await MainActor.run {
                XCTAssertNil(metadata.failureMessage)
                store.text = "save after recovery"
                XCTAssertTrue(store.save())
            }
            await metadata.waitForPendingWork()
            await service.waitForWork()
            XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "save after recovery")
            await db.close()
        }
    }

    @objc func testInvalidModelResponseKeepsAppErrorConciseAcrossDatabaseReopen() {
        runAsync {
            let url = try self.note()
            let raw = "  <think>choose a name</think>\n```markdown\nMy Note.md\n```  "
            let db = try await self.database()
            let generator = StubFilenameGenerator()
            await generator.setOutput(raw)
            let defaults = UserDefaults(suiteName: self.applicationDefaultsName)!
            defaults.set(true, forKey: "filenameSuggestionsEnabled")
            let service = await MainActor.run {
                let service = FilenameSuggestionController(database: db, metadata: DatabaseStatus(database: db),
                    generator: generator, defaults: defaults)
                service.activate(folder: self.folder)
                service.saved(url)
                return service
            }
            await service.waitForWork()
            await MainActor.run {
                let error = service.suggestions["note.md"]?.error
                XCTAssertEqual(error, "Could not generate a filename after \(self.config.maxGenerationAttempts) attempts. The model did not return a valid filename. Try generating again.")
                XCTAssertFalse(error?.contains(raw) == true)
                XCTAssertEqual(service.suggestions["note.md"]?.state, "error")
                XCTAssertNil(service.suggestions["note.md"]?.filename)
            }
            await db.close()
            let reopened = SQLiteDatabase(url: self.databaseURL)
            try await reopened.initialize()
            let persisted = try await reopened.filenameSuggestions(folder: self.folder, configuration: self.config)
            XCTAssertEqual(persisted["note.md"]?.error, "Could not generate a filename after \(self.config.maxGenerationAttempts) attempts. The model did not return a valid filename. Try generating again.")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Saved text")
            await reopened.close()
        }
    }

    @objc func testEmptyModelResponseKeepsAppErrorConcise() throws {
        let url = try note()
        XCTAssertThrowsError(try FilenameOutput.filename(from: "", in: folder, current: url)) { error in
            XCTAssertEqual(error.localizedDescription, "The model did not return a valid filename. Try generating again.")
        }
    }

    @objc func testFirstSavePreviewCleanSaveAcceptsThenEditedSavesOnlyText() {
        runAsync {
            let generator = StubFilenameGenerator()
            let (_, db, metadata, store, service) = try await self.applicationFixture(generator: generator)
            await MainActor.run { store.create(); store.text = "new note content" }
            try await service.save(in: store)
            let temporary = await MainActor.run { store.selected! }
            XCTAssertEqual(try String(contentsOf: temporary, encoding: .utf8), "new note content")
            XCTAssertNotEqual(temporary.lastPathComponent, "saved-note.md")
            await MainActor.run { XCTAssertEqual(service.suggestions[temporary.lastPathComponent]?.filename, "saved-note.md") }
            await generator.setOutput("second-name")
            try await service.regenerate(in: store)
            await generator.setOutput("preferred-name")
            try await service.regenerate(in: store)
            await MainActor.run {
                XCTAssertEqual(store.selected, temporary, "Regeneration must never rename the saved file")
                XCTAssertEqual(service.suggestions[temporary.lastPathComponent]?.filename, "preferred-name.md")
            }
            try await service.save(in: store)
            await metadata.waitForPendingWork()
            await service.waitForWork()
            let accepted = self.folder.appendingPathComponent("preferred-name.md")
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
            XCTAssertEqual(try String(contentsOf: accepted, encoding: .utf8), "new note content")
            let calls = await generator.calls
            XCTAssertEqual(calls, 3, "Accepting a preview must not rerun the model")
            await generator.setOutput("edited-name")
            await MainActor.run { store.text = "later edit" }
            try await service.save(in: store)
            XCTAssertEqual(try String(contentsOf: accepted, encoding: .utf8), "later edit")
            await MainActor.run {
                XCTAssertEqual(store.selected, accepted, "Saving an existing note must preserve its filename")
                XCTAssertNil(service.suggestions[accepted.lastPathComponent])
            }
            await metadata.waitForPendingWork()
            await service.waitForWork()
            let callsAfterEdit = await generator.calls
            XCTAssertEqual(callsAfterEdit, calls, "Existing edited saves must not run inference")
            await db.close()
        }
    }

    @objc func testCleanSaveAcceptsExistingReadyPreviewWithoutInferenceOrTextSave() {
        runAsync {
            let generator = StubFilenameGenerator()
            let (url, _, metadata, store, service) = try await self.applicationFixture(generator: generator)
            let callsBefore = await generator.calls
            let editorID = await store.editorID
            await MainActor.run { store.onSaved = { _ in XCTFail("Accepting a name must not save text") } }
            try await service.save(in: store)
            await metadata.waitForPendingWork()
            await service.waitForWork()
            let selected = await store.selected
            XCTAssertEqual(selected?.lastPathComponent, "saved-note.md")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try String(contentsOf: XCTUnwrap(selected), encoding: .utf8), "Saved text")
            let callsAfter = await generator.calls
            XCTAssertEqual(callsAfter, callsBefore)
            let afterID = await store.editorID
            XCTAssertEqual(afterID, editorID)
            try await service.save(in: store) // Already accepted: silent no-op.
        }
    }

    @objc func testExistingEditedSaveDoesNotRunModelOrApplyReadySuggestion() {
        runAsync {
            let generator = StubFilenameGenerator()
            let (url, _, metadata, store, service) = try await self.applicationFixture(generator: generator)
            let callsBefore = await generator.calls
            await MainActor.run { store.text = "edited existing note" }
            try await service.save(in: store)
            await metadata.waitForPendingWork()
            await service.waitForWork()
            try await service.save(in: store)
            let callsAfter = await generator.calls
            XCTAssertEqual(callsBefore, callsAfter)
            let selected = await store.selected
            XCTAssertEqual(selected, url)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "edited existing note")
            XCTAssertFalse(FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("saved-note.md").path))
            let preview = await service.suggestions[url.lastPathComponent]
            XCTAssertNotEqual(preview?.state, "ready")
        }
    }

    @objc func testFirstExplicitSaveKeepsSavedFileWhenNamingFails() {
        runAsync {
            let generator = StubFilenameGenerator()
            await generator.setFailure(true)
            let (_, db, metadata, store, service) = try await self.applicationFixture(generator: generator)
            await MainActor.run { store.create(); store.text = "keep new note safe" }
            try await service.save(in: store)
            await MainActor.run {
                XCTAssertTrue(service.suggestions[store.selected!.lastPathComponent]?.error?.contains("fixture inference failure") == true)
                XCTAssertNil(store.errorMessage, "Model exhaustion is inline, not a failed-save alert")
            }
            await metadata.waitForPendingWork()
            await service.waitForWork()
            let savedURL = await MainActor.run { store.selected! }
            XCTAssertEqual(try String(contentsOf: savedURL, encoding: .utf8), "keep new note safe")
            await MainActor.run { XCTAssertFalse(store.isDirty) }
            await db.close()
        }
    }

    @objc func testFirstExplicitSaveOfEmptyDraftDoesNothing() {
        runAsync {
            let generator = StubFilenameGenerator()
            let (_, db, _, store, service) = try await self.applicationFixture(generator: generator)
            await MainActor.run { store.create() }
            let before = try FileManager.default.contentsOfDirectory(atPath: self.folder.path)
            try await service.save(in: store)
            let after = try FileManager.default.contentsOfDirectory(atPath: self.folder.path)
            XCTAssertEqual(before, after)
            let calls = await generator.calls
            XCTAssertEqual(calls, 0)
            await MainActor.run { XCTAssertNil(store.selected); XCTAssertNil(store.errorMessage) }
            await db.close()
        }
    }

    @objc func testPlainSaveIsNoOpWithoutChangesAndEmitsOnlyChangedSaveEvents() {
        runAsync {
            let (url, db, metadata, store, service) = try await self.applicationFixture()
            let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
            await MainActor.run {
                var changedSaves = 0
                store.onSaved = { _ in changedSaves += 1 }
                XCTAssertTrue(store.save())
                XCTAssertEqual(changedSaves, 0)
                store.text = "changed content"
                XCTAssertTrue(store.save())
                XCTAssertEqual(changedSaves, 1)
                XCTAssertTrue(store.save())
                XCTAssertEqual(changedSaves, 1, "Future embedding hooks must receive only changed successful saves")
            }
            await metadata.waitForPendingWork()
            await service.waitForWork()
            let rows = try await db.query(SQLiteStatement("SELECT state, attempts FROM filename_suggestions"))
            XCTAssertEqual(rows, [[.text("stale"), .integer(1)]], "Ordinary saves must not queue filename generation")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            await db.close()
        }
    }

    @objc func testCleanSaveLeavesModificationDateAndDraftUntouched() {
        runAsync {
            let (url, db, _, store, _) = try await self.applicationFixture()
            let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
            await MainActor.run { XCTAssertTrue(store.save()) }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.modificationDate] as? Date, oldDate)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Saved text")
            await db.close()
        }
    }

    @objc func testRegenerateSavesChangedTextButDoesNotRename() {
        runAsync {
            let (url, db, metadata, store, service) = try await self.applicationFixture()
            await MainActor.run { store.text = "changed for naming" }
            try await service.regenerate(in: store)
            await metadata.waitForPendingWork()
            await service.waitForWork()
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "changed for naming")
            XCTAssertFalse(FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("saved-note.md").path))
            await MainActor.run {
                XCTAssertEqual(store.selected, url)
                XCTAssertFalse(store.isDirty)
                XCTAssertEqual(service.suggestions[url.lastPathComponent]?.filename, "saved-note.md")
            }
            await db.close()
        }
    }

    @objc func testRegenerateRunsAgainForUnchangedNoteWithoutWritingIt() {
        runAsync {
            let generator = StubFilenameGenerator()
            let (url, db, _, store, service) = try await self.applicationFixture(generator: generator)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try await service.regenerate(in: store)
            try await service.regenerate(in: store)
            let after = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.modificationDate] as? Date, after[.modificationDate] as? Date)
            let calls = await generator.calls
            XCTAssertEqual(calls, 2)
            await MainActor.run { XCTAssertEqual(store.selected, url) }
            await db.close()
        }
    }

    @objc func testCleanSaveWithoutPendingCandidateIsNoOp() {
        runAsync {
            let (url, db, _, store, service) = try await self.applicationFixture()
            try await db.execute(SQLiteStatement("UPDATE filename_suggestions SET state = 'stale', suggested_filename = NULL"))
            await MainActor.run { service.refresh(folder: self.folder) }
            await service.waitForWork()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try await service.save(in: store)
            let after = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.modificationDate] as? Date, after[.modificationDate] as? Date)
            await MainActor.run { XCTAssertEqual(store.selected, url) }
            await db.close()
        }
    }

    @objc func testRegenerateKeepsSuccessfulSaveWhenModelDisabled() {
        runAsync {
            let (url, db, metadata, store, service) = try await self.applicationFixture()
            await MainActor.run { service.disable(); store.text = "save without AI" }
            do {
                try await service.regenerate(in: store)
                XCTFail("Disabled model should explain that only saving succeeded")
            } catch { XCTAssertTrue(error.localizedDescription.contains("note was saved")) }
            await metadata.waitForPendingWork()
            await service.waitForWork()
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "save without AI")
            await MainActor.run { XCTAssertFalse(store.isDirty) }
            await db.close()
        }
    }

    @objc func testRegenerateStopsIfUserTypesDuringGeneration() {
        runAsync {
            let generator = SuspendedFilenameGenerator()
            let (url, db, metadata, store, service) = try await self.applicationFixture(generator: generator)
            await MainActor.run { store.text = "saved before generation" }
            let operation = Task { try await service.regenerate(in: store) }
            await generator.waitUntilStarted()
            await MainActor.run { store.text = "new unsaved draft" }
            await generator.release()
            do {
                try await operation.value
                XCTFail("Typing during generation must prevent renaming")
            } catch { XCTAssertTrue(error.localizedDescription.contains("note changed")) }
            await metadata.waitForPendingWork()
            await service.waitForWork()
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved before generation")
            XCTAssertFalse(FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("saved-note.md").path))
            await MainActor.run {
                XCTAssertEqual(store.text, "new unsaved draft")
                XCTAssertTrue(store.isDirty)
                XCTAssertEqual(store.selected, url)
            }
            await db.close()
        }
    }

    @objc func testFailedRegenerationSaveRetainsDraftAndOriginalFile() {
        runAsync {
            let (url, db, _, store, service) = try await self.applicationFixture()
            try Data("external text".utf8).write(to: url)
            await MainActor.run { store.text = "unsaved changes" }
            try await service.regenerate(in: store)
            let rows = try await db.query(SQLiteStatement("SELECT attempts FROM filename_suggestions"))
            XCTAssertEqual(rows, [[.integer(1)]], "No generation after save conflict")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external text")
            await MainActor.run {
                XCTAssertTrue(store.isDirty)
                XCTAssertEqual(store.text, "unsaved changes")
                XCTAssertNotNil(store.errorMessage)
            }
            await db.close()
        }
    }

    @objc func testInvalidResponsesAutomaticallyRetryUntilValidPreview() {
        runAsync {
            let generator = StubFilenameGenerator()
            let (url, db, _, store, service) = try await self.applicationFixture(generator: generator)
            await generator.setOutputs(["", "```\nwrong output\n```", "Recovered Title.md"])
            try await service.regenerate(in: store)
            let calls = await generator.calls
            XCTAssertEqual(calls, 3)
            await MainActor.run {
                XCTAssertEqual(service.suggestions[url.lastPathComponent]?.filename, "recovered-title.md")
                XCTAssertEqual(service.suggestions[url.lastPathComponent]?.state, "ready")
                XCTAssertEqual(store.selected, url, "Retries only produce previews")
                XCTAssertNil(store.errorMessage)
            }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Saved text")
            await db.close()
        }
    }

    @objc func testTransientModelFailureAutomaticallyRecovers() {
        runAsync {
            let generator = StubFilenameGenerator()
            let (url, db, _, store, service) = try await self.applicationFixture(generator: generator)
            await generator.setTransientFailures(1)
            try await service.regenerate(in: store)
            let calls = await generator.calls
            XCTAssertEqual(calls, 2)
            await MainActor.run {
                XCTAssertEqual(service.suggestions[url.lastPathComponent]?.filename, "saved-note.md")
                XCTAssertNil(store.errorMessage)
            }
            await db.close()
        }
    }

    @objc func testRetryBudgetStopsInvalidModelWithoutLosingSaveAndCanRecoverLater() {
        runAsync {
            let generator = StubFilenameGenerator()
            let (_, db, metadata, store, service) = try await self.applicationFixture(generator: generator)
            await generator.setOutput("../../invalid")
            await MainActor.run { store.create(); store.text = "durably saved before inference" }
            try await service.save(in: store)
            let url = await MainActor.run { store.selected! }
            let calls = await generator.calls
            XCTAssertEqual(calls, self.config.maxGenerationAttempts)
            let records = try await db.query(SQLiteStatement("SELECT attempts FROM filename_suggestions WHERE state = 'error'"))
            XCTAssertEqual(records, [[.integer(Int64(self.config.maxGenerationAttempts))]])
            await MainActor.run {
                XCTAssertEqual(service.suggestions[url.lastPathComponent]?.state, "error")
                XCTAssertNil(service.suggestions[url.lastPathComponent]?.filename)
                XCTAssertFalse(store.isDirty)
                XCTAssertNil(store.errorMessage)
            }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "durably saved before inference")
            await generator.setOutput("Recovered Note.md")
            try await service.regenerate(in: store)
            try await service.apply("recovered-note.md", to: url, in: store)
            await metadata.waitForPendingWork()
            await service.waitForWork()
            XCTAssertEqual(try String(contentsOf: self.folder.appendingPathComponent("recovered-note.md"), encoding: .utf8), "durably saved before inference")
            await db.close()
        }
    }

    @objc func testCollidingModelFilenameAutomaticallyRegeneratesWithoutOverwriting() {
        runAsync {
            let generator = StubFilenameGenerator()
            let (url, db, _, store, service) = try await self.applicationFixture(generator: generator)
            let collision = self.folder.appendingPathComponent("saved-note.md")
            try Data("another note".utf8).write(to: collision)
            await generator.setOutputs(["saved-note", "Different Note.md"])
            try await service.regenerate(in: store)
            let calls = await generator.calls
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(try String(contentsOf: collision, encoding: .utf8), "another note")
            await MainActor.run {
                XCTAssertEqual(service.suggestions[url.lastPathComponent]?.filename, "different-note.md")
                XCTAssertEqual(store.selected, url)
            }
            await db.close()
        }
    }

    @objc func testInvalidModelSettingsThrowInsteadOfTrapping() throws {
        try config.validateGenerationSettings()
        var invalid = config
        invalid.temperature = .nan
        XCTAssertFalse(invalid.json.isEmpty, "Fingerprinting must not trap before settings validation")
        XCTAssertFalse(invalid.fingerprint.isEmpty)
        XCTAssertThrowsError(try invalid.validateGenerationSettings())
        invalid = config
        invalid.maxInputCharacters = -1
        XCTAssertThrowsError(try invalid.validateGenerationSettings())
        invalid = config
        invalid.maxOutputTokens = 0
        XCTAssertThrowsError(try invalid.validateGenerationSettings())
    }

    @objc func testConfigurationFingerprintTracksPromptAndParametersWithoutRedownloadingWeights() {
        var changed = config
        changed.systemPrompt += " Do not invent dates."
        XCTAssertNotEqual(config.fingerprint, changed.fingerprint)
        XCTAssertEqual(config.modelCacheKey, changed.modelCacheKey)
        changed.temperature = 0.5
        XCTAssertNotEqual(config.fingerprint, changed.fingerprint)
        changed.modelID = "owner/another-model"
        XCTAssertNotEqual(config.modelCacheKey, changed.modelCacheKey)
    }

    @objc func testPromptTitlesNormalizeToSafeFilenames() throws {
        let current = try note()
        for (raw, expected) in [
            ("Grocery Shopping List.md", "grocery-shopping-list.md"),
            ("Tarefas Pendentes.md", "tarefas-pendentes.md"),
            ("LoRA Hyperparameter Optimization.md", "lora-hyperparameter-optimization.md"),
            ("Renovação do Passaporte Brasileiro.md", "renovação-do-passaporte-brasileiro.md"),
            ("Réunion sur le déploiement API.md", "réunion-sur-le-déploiement-api.md"),
            ("Title: \"Grocery Shopping List.md\"", "grocery-shopping-list.md"),
            ("`Grocery Shopping List`", "grocery-shopping-list.md"),
            ("  grocery-shopping-list\n", "grocery-shopping-list.md")
        ] {
            XCTAssertEqual(try FilenameOutput.filename(from: raw, in: folder, current: current), expected)
        }
        for raw in ["First Title\nSecond Title", "```\nMy Title.md\n```", "../My Title.md", "My\\Title.md", "<think>reason</think>My Title.md"] {
            XCTAssertThrowsError(try FilenameOutput.filename(from: raw, in: folder, current: current))
        }
        try Data("keep".utf8).write(to: folder.appendingPathComponent("grocery-shopping-list.md"))
        XCTAssertThrowsError(try FilenameOutput.filename(from: "Grocery Shopping List.md", in: folder, current: current))
    }

    @objc func testEditedPromptIsIncludedInRuntimeInputAndSavedConfiguration() throws {
        var configuration = config
        configuration.systemPrompt = "Identify the overall purpose. Return a natural title."
        configuration.maxInputCharacters = 5
        XCTAssertEqual(configuration.combinedPrompt(for: "abcdefghi"),
                       configuration.systemPrompt + "\nGenerate a title for this note:\n\n<note>\nabcde\n</note>")
        let decoded = try JSONDecoder().decode(FilenameModelConfiguration.self, from: Data(configuration.json.utf8))
        XCTAssertEqual(decoded.systemPrompt, configuration.systemPrompt)
        XCTAssertEqual(decoded.combinedPrompt(for: "abcdefghi"), configuration.combinedPrompt(for: "abcdefghi"))
        XCTAssertNotEqual(configuration.fingerprint, config.fingerprint)
        XCTAssertEqual(configuration.modelCacheKey, config.modelCacheKey)
    }

    @objc func testOutputRejectsPathsProseAndCollisionsWithoutWritingFiles() throws {
        let current = try note()
        for output in ["../../secret", "a/b", "name.txt", "Here is a filename: my-note", "<think>name</think>", "", "-name", "one-two-three-four-five-six-seven"] {
            XCTAssertThrowsError(try FilenameOutput.filename(from: output, in: folder, current: current))
        }
        XCTAssertEqual(try FilenameOutput.filename(from: "reunião-da-loja", in: folder, current: current), "reunião-da-loja.md")
        try Data().write(to: folder.appendingPathComponent("existing.md"))
        XCTAssertThrowsError(try FilenameOutput.filename(from: "existing", in: folder, current: current))
        XCTAssertEqual(try String(contentsOf: current, encoding: .utf8), "Saved text")
    }

    @objc func testRepeatedSavesAreIdempotentAndConfigurationChangeQueuesFreshWork() {
        runAsync {
            let url = try self.note()
            let db = try await self.database()
            let job = try await self.job(db, url: url)
            let input = try await db.filenameInput(job)
            XCTAssertEqual(input, "Saved text")
            try await db.finishFilename(job, filename: "saved-note.md", error: nil)
            try await db.queueFilename(url: url, configuration: self.config)
            let pending = try await db.pendingFilenames(folder: self.folder, configuration: self.config)
            XCTAssertTrue(pending.isEmpty)
            var changed = self.config
            changed.temperature = 0.3
            try await db.queueFilename(url: url, configuration: changed)
            let fresh = try await db.pendingFilenames(folder: self.folder, configuration: changed)
            XCTAssertEqual(fresh.count, 1)
            // A completion from the previous configuration must not replace the new job.
            try await db.finishFilename(job, filename: "old.md", error: nil)
            let suggestions = try await db.filenameSuggestions(folder: self.folder, configuration: changed)
            XCTAssertEqual(suggestions["note.md"]?.state, "queued")
            await db.close()
        }
    }

    @objc func testExternalEditRejectsCompletionBeforeRefreshAndReconciliationInvalidatesIt() {
        runAsync {
            let url = try self.note()
            let db = try await self.database()
            let job = try await self.job(db, url: url)
            _ = try await db.filenameInput(job)
            try Data("external edit".utf8).write(to: url)
            try await db.finishFilename(job, filename: "wrong.md", error: nil)
            let before = try await db.filenameSuggestions(folder: self.folder, configuration: self.config)
            XCTAssertEqual(before["note.md"]?.state, "stale")
            XCTAssertNil(before["note.md"]?.filename)
            try await db.reconcile(folder: self.folder)
            let after = try await db.filenameSuggestions(folder: self.folder, configuration: self.config)
            XCTAssertTrue(after.isEmpty)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external edit")
            await db.close()
        }
    }

    @objc func testSaveDuringGenerationCannotBeReplacedByOldCompletion() {
        runAsync {
            let url = try self.note()
            let db = try await self.database()
            let old = try await self.job(db, url: url)
            _ = try await db.filenameInput(old)
            try Data("latest save".utf8).write(to: url)
            try await db.reconcile(folder: self.folder)
            let latest = try await self.job(db, url: url)
            _ = try await db.filenameInput(latest)
            try await db.finishFilename(old, filename: "old.md", error: nil)
            try await db.finishFilename(latest, filename: "latest.md", error: nil)
            let suggestions = try await db.filenameSuggestions(folder: self.folder, configuration: self.config)
            XCTAssertEqual(suggestions["note.md"]?.filename, "latest.md")
            await db.close()
        }
    }

    @objc func testRestartResumesProcessingAndMissingFileCannotReceiveResult() {
        runAsync {
            let url = try self.note()
            let db = try await self.database()
            let job = try await self.job(db, url: url)
            _ = try await db.filenameInput(job)
            await db.close()
            let reopened = SQLiteDatabase(url: self.databaseURL)
            try await reopened.initialize()
            let recovered = try await reopened.pendingFilenames(folder: self.folder, configuration: self.config)
            XCTAssertEqual(recovered.count, 1)
            try FileManager.default.removeItem(at: url)
            try await reopened.finishFilename(job, filename: "missing.md", error: nil)
            try await reopened.reconcile(folder: self.folder)
            let visible = try await reopened.filenameSuggestions(folder: self.folder, configuration: self.config)
            XCTAssertTrue(visible.isEmpty)
            await reopened.close()
        }
    }

    @objc func testInferenceFailureDoesNotChangeFileAndExplicitRetryRecovers() {
        runAsync {
            let url = try self.note()
            let db = SQLiteDatabase(url: self.databaseURL)
            let generator = StubFilenameGenerator()
            await generator.setFailure(true)
            let name = "FilenameTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let (metadata, service) = await MainActor.run {
                let metadata = DatabaseStatus(database: db)
                let service = FilenameSuggestionController(database: db, metadata: metadata, generator: generator, defaults: defaults)
                metadata.reconcile(folder: self.folder)
                service.activate(folder: self.folder)
                return (metadata, service)
            }
            await metadata.waitForPendingWork()
            await service.waitForWork()
            await service.downloadAndEnable()
            await MainActor.run { service.saved(url) }
            await service.waitForWork()
            await MainActor.run { XCTAssertEqual(service.suggestions["note.md"]?.state, "error") }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Saved text")
            await generator.setFailure(false)
            await MainActor.run { service.saved(url, force: true) }
            await service.waitForWork()
            await MainActor.run { XCTAssertEqual(service.suggestions["note.md"]?.filename, "saved-note.md") }
            let calls = await generator.calls
            XCTAssertEqual(calls, self.config.maxGenerationAttempts + 1)
            await db.close()
        }
    }

    @objc func testSuccessfulSavesCoalesceAndPreserveNewUnsavedDraft() {
        runAsync {
            let db = SQLiteDatabase(url: self.databaseURL)
            let generator = StubFilenameGenerator()
            let name = "FilenameTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let (store, service) = try await MainActor.run {
                let metadata = DatabaseStatus(database: db)
                let service = FilenameSuggestionController(database: db, metadata: metadata, generator: generator, defaults: defaults)
                let store = NoteStore(index: metadata, defaults: defaults)
                store.onSaved = { [weak service] url in service?.saved(url) }
                store.onFolderChanged = { [weak service] folder in service?.activate(folder: folder) }
                try store.activateFolder(self.folder)
                return (store, service)
            }
            await service.downloadAndEnable()
            let url = await MainActor.run {
                store.text = "first"
                XCTAssertTrue(store.save())
                store.text = "second"
                XCTAssertTrue(store.save())
                store.text = "new unsaved draft"
                return store.selected!
            }
            await service.waitForWork()
            let calls = await generator.calls
            XCTAssertEqual(calls, 1)
            await MainActor.run {
                XCTAssertEqual(store.text, "new unsaved draft")
                XCTAssertTrue(store.isDirty)
                XCTAssertEqual(service.suggestions[url.lastPathComponent]?.filename, "saved-note.md")
            }
            try Data("external edit".utf8).write(to: url)
            await MainActor.run { XCTAssertFalse(store.save()) }
            await service.waitForWork()
            let afterConflict = await generator.calls
            XCTAssertEqual(afterConflict, 1, "A failed save must not schedule inference")
            await db.close()
        }
    }

    @objc func testVersionThreeMigrationPreservesRegistryAndAddsFilenameStorage() {
        runAsync {
            let old = SQLiteDatabase(url: self.databaseURL, migrations: Array(SQLiteMigration.current.prefix(3)))
            try await old.initialize()
            try await old.execute(SQLiteStatement("INSERT INTO folders VALUES ('folder', '/fixture')"))
            try await old.execute(SQLiteStatement("INSERT INTO notes (id, folder_id, relative_path, sync_state) VALUES ('keep', 'folder', 'note.md', 'indexed')"))
            await old.close()
            let db = SQLiteDatabase(url: self.databaseURL)
            try await db.initialize()
            let ids = try await db.query(SQLiteStatement("SELECT id FROM notes"))
            let outputs = try await db.query(SQLiteStatement("SELECT note_id FROM filename_suggestions"))
            XCTAssertEqual(ids, [[.text("keep")]])
            XCTAssertTrue(outputs.isEmpty)
            await db.close()
        }
    }

    @objc func testDisablingInFlightGenerationPreventsCommitAndEnableResumes() {
        runAsync {
            let url = try self.note()
            let db = try await self.database()
            let generator = SuspendedFilenameGenerator()
            let name = "FilenameTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let service = await MainActor.run {
                let service = FilenameSuggestionController(database: db, metadata: DatabaseStatus(database: db),
                                                           generator: generator, defaults: defaults)
                service.activate(folder: self.folder)
                return service
            }
            await service.downloadAndEnable()
            await MainActor.run { service.saved(url) }
            await generator.waitUntilStarted()
            await MainActor.run { service.disable() }
            await generator.release()
            await service.waitForWork()
            let paused = try await db.filenameSuggestions(folder: self.folder, configuration: self.config)
            XCTAssertEqual(paused["note.md"]?.state, "processing")
            XCTAssertNil(paused["note.md"]?.filename)
            await service.downloadAndEnable()
            await service.waitForWork()
            let resumed = try await db.filenameSuggestions(folder: self.folder, configuration: self.config)
            XCTAssertEqual(resumed["note.md"]?.filename, "saved-note.md")
            await db.close()
        }
    }

    @objc func testDisabledControllerNeverRunsInference() {
        runAsync {
            let url = try self.note()
            let db = try await self.database()
            let generator = StubFilenameGenerator()
            let name = "FilenameTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let service = await MainActor.run {
                FilenameSuggestionController(database: db, metadata: DatabaseStatus(database: db), generator: generator, defaults: defaults)
            }
            await MainActor.run { service.saved(url) }
            await service.waitForWork()
            let calls = await generator.calls
            XCTAssertEqual(calls, 0)
            await db.close()
        }
    }

    @objc func testFirstFilenameRequestDownloadsMissingModelOnlyOnce() {
        runAsync {
            let generator = LazyDownloadFilenameGenerator()
            let (_, db, _, store, service) = try await self.applicationFixture(generator: generator)

            try await service.regenerate(in: store)
            try await service.regenerate(in: store)

            let counts = await generator.counts()
            XCTAssertEqual(counts.downloads, 1)
            XCTAssertEqual(counts.generations, 2)
            await db.close()
        }
    }

    @objc func testFailedFilenameModelDownloadSurfacesAndCanBeRetried() {
        runAsync {
            let generator = LazyDownloadFilenameGenerator(failFirstDownload: true)
            let (_, db, _, store, service) = try await self.applicationFixture(generator: generator)

            do {
                try await service.regenerate(in: store)
                XCTFail("The first model download should fail.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("fixture download failure"))
            }
            try await service.regenerate(in: store)

            let counts = await generator.counts()
            XCTAssertEqual(counts.downloads, 2)
            XCTAssertEqual(counts.generations, 1)
            await db.close()
        }
    }

    @objc func testFilenameDownloadProgressReachesControllerAndIsBounded() {
        runAsync {
            let generator = ProgressFilenameGenerator()
            let (_, db, _, _, service) = try await self.applicationFixture(generator: generator)
            let downloadTask = Task { await service.downloadAndEnable() }
            await generator.waitUntilStarted()

            var observedProgress: Double?
            for _ in 0..<100 {
                let progress = await MainActor.run { service.downloadProgress }
                if progress >= 0.4 {
                    observedProgress = progress
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(observedProgress, 0.4)
            XCTAssertTrue((0...1).contains(observedProgress ?? -1))

            await generator.finishDownload()
            await downloadTask.value
            await MainActor.run {
                XCTAssertEqual(service.downloadProgress, 1)
                XCTAssertFalse(service.isDownloading)
            }
            await db.close()
        }
    }
}
