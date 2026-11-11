import Foundation
import XCTest

final class NoteIndexTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var databaseURL: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = root.appendingPathComponent("notes")
        databaseURL = root.appendingPathComponent("database/metadata.sqlite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaultsName = "NtsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsName)
        try FileManager.default.removeItem(at: root)
    }

    private func runAsync(_ body: @escaping () async throws -> Void) {
        let finished = expectation(description: "Index work completed")
        Task.detached {
            do { try await body() } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 25)
    }

    private func write(_ name: String, _ text: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? self.folder).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func rows(_ database: SQLiteDatabase, folder: URL? = nil) async throws -> [[SQLiteValue]] {
        try await database.query(SQLiteStatement("""
            SELECT n.id, n.relative_path, n.content_hash, n.sync_state, n.index_error, n.indexed_at
            FROM notes n JOIN folders f ON n.folder_id = f.id WHERE f.root_path = ? ORDER BY n.relative_path
            """, [.text((folder ?? self.folder).resolvingSymlinksInPath().standardizedFileURL.path)]))
    }

    @objc func testDatesSurviveTimestampChangesRenameAndRestartButRebuildUsesDisk() {
        runAsync {
            let note = try self.write("note.md", "saved")
            let database = SQLiteDatabase(url: self.databaseURL)
            try await database.initialize()
            let first = try await database.reconcile(folder: self.folder)
            let original = try XCTUnwrap(first.dates["note.md"])
            let changed = Date(timeIntervalSince1970: 1_000_000)
            try FileManager.default.setAttributes([.creationDate: changed, .modificationDate: changed],
                                                  ofItemAtPath: note.path)
            let refreshed = try await database.reconcile(folder: self.folder)
            XCTAssertEqual(refreshed.dates["note.md"], original)
            let observed = try await database.query(SQLiteStatement("SELECT observed_created_at, observed_modified_at FROM notes"))
            XCTAssertEqual(observed, [[.real(changed.timeIntervalSince1970), .real(changed.timeIntervalSince1970)]])
            let renamed = try NoteFileService().rename(note, to: "renamed")
            let moved = try await database.reconcile(folder: self.folder, rename: NoteRename(source: note, destination: renamed))
            XCTAssertEqual(moved.dates["renamed.md"], original)
            await database.close()
            let restarted = SQLiteDatabase(url: self.databaseURL)
            try await restarted.initialize()
            let afterRestart = try await restarted.reconcile(folder: self.folder)
            XCTAssertEqual(afterRestart.dates["renamed.md"], original)
            await restarted.close()
            let rebuilt = SQLiteDatabase(url: self.root.appendingPathComponent("rebuilt.sqlite"))
            try await rebuilt.initialize()
            let recovered = try await rebuilt.reconcile(folder: self.folder)
            XCTAssertEqual(recovered.dates["renamed.md"], changed)
            XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "saved")
            await rebuilt.close()
        }
    }

    @objc func testVersionTwoMigrationBackfillsDatesOnScan() {
        runAsync {
            _ = try self.write("import.md", "imported")
            let old = SQLiteDatabase(url: self.databaseURL, migrations: Array(SQLiteMigration.current.prefix(2)))
            try await old.initialize()
            // Version two has no date columns; existing records must survive the migration.
            try await old.execute(SQLiteStatement("INSERT INTO folders VALUES ('folder', ?)", [.text(self.folder.path)]))
            try await old.execute(SQLiteStatement("INSERT INTO notes (id, folder_id, relative_path, sync_state) VALUES ('keep', 'folder', 'import.md', 'indexed')"))
            await old.close()
            let database = SQLiteDatabase(url: self.databaseURL)
            try await database.initialize()
            let result = try await database.reconcile(folder: self.folder)
            XCTAssertNotNil(result.dates["import.md"])
            let records = try await self.rows(database)
            XCTAssertEqual(records[0][0], .text("keep"))
            await database.close()
        }
    }

    @objc func testSidebarUsesPreservedDatesWithoutReplacingDraft() {
        runAsync {
            let a = try self.write("a.md", "a")
            let b = try self.write("b.md", "b")
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: a.path)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: b.path)
            let database = SQLiteDatabase(url: self.databaseURL)
            let status = await MainActor.run { DatabaseStatus(database: database) }
            let store = try await MainActor.run {
                let store = NoteStore(index: status, defaults: self.defaults)
                try store.activateFolder(self.folder)
                store.open(a)
                store.text = "unsaved"
                return store
            }
            await status.waitForPendingWork()
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: a.path)
            await MainActor.run { store.refresh() }
            await status.waitForPendingWork()
            await MainActor.run {
                XCTAssertEqual(store.notes.map(\.name), ["b.md", "a.md"])
                XCTAssertEqual(store.notes.last?.date, Date(timeIntervalSince1970: 100))
                XCTAssertEqual(store.selected, a)
                XCTAssertEqual(store.text, "unsaved")
                XCTAssertTrue(store.isDirty)
            }
            await database.close()
        }
    }

    @objc func testVersionOneUpgradesWithoutLosingExistingRecords() {
        runAsync {
            let original = SQLiteDatabase(url: self.databaseURL, migrations: SQLiteMigration.foundation)
            try await original.initialize()
            try await original.execute(SQLiteStatement("CREATE TABLE existing_data (value TEXT)"))
            try await original.execute(SQLiteStatement("INSERT INTO existing_data VALUES ('keep')"))
            await original.close()
            let database = SQLiteDatabase(url: self.databaseURL)
            try await database.initialize()
            let version = try await database.query(SQLiteStatement("PRAGMA user_version"))
            let preserved = try await database.query(SQLiteStatement("SELECT value FROM existing_data"))
            XCTAssertEqual(version, [[.integer(7)]])
            XCTAssertEqual(preserved, [[.text("keep")]])
            try await database.execute(SQLiteStatement("INSERT INTO folders VALUES ('folder', '/fixture')"))
            do {
                try await database.execute(SQLiteStatement("INSERT INTO notes (id, folder_id, relative_path, sync_state) VALUES ('orphan', 'missing', 'note.md', 'indexed')"))
                XCTFail("Registry foreign key must be enforced")
            } catch { }
            await database.close()
        }
    }

    @objc func testRepeatedScanIsIdempotentAndHashesSavedBytes() {
        runAsync {
            let url = try self.write("hello.md", "hello")
            let database = SQLiteDatabase(url: self.databaseURL)
            try await database.initialize()
            let result = try await database.reconcile(folder: self.folder)
            XCTAssertEqual(result.fileErrors, 0)
            let first = try await self.rows(database)
            XCTAssertEqual(first.count, 1)
            XCTAssertEqual(first.first?[2], .text("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"))
            try await database.reconcile(folder: self.folder)
            let second = try await self.rows(database)
            XCTAssertEqual(first, second, "Unchanged scans retain IDs and indexing timestamps")
            XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
            await database.close()
        }
    }

    @objc func testExternalChangesDeletionAndReappearance() {
        runAsync {
            let url = try self.write("note.md", "first")
            let database = SQLiteDatabase(url: self.databaseURL)
            try await database.initialize()
            try await database.reconcile(folder: self.folder)
            let first = try await self.rows(database)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try Data("second".utf8).write(to: url)
            // Hashes detect changes even when an external tool preserves modification time.
            try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: url.path)
            try await database.reconcile(folder: self.folder)
            let changed = try await self.rows(database)
            XCTAssertEqual(changed.first?[0], first.first?[0])
            XCTAssertNotEqual(changed.first?[2], first.first?[2])
            try FileManager.default.removeItem(at: url)
            try await database.reconcile(folder: self.folder)
            let missing = try await self.rows(database)
            XCTAssertTrue(missing.isEmpty, "Confirmed deletions should remove the note record immediately.")
            _ = try self.write("note.md", "restored")
            try await database.reconcile(folder: self.folder)
            let restored = try await self.rows(database)
            XCTAssertEqual(restored.first?[3], .text("indexed"))
            XCTAssertNotEqual(restored.first?[0], first.first?[0],
                              "Restored files receive new metadata after prior metadata was deleted.")
            await database.close()
        }
    }

    @objc func testExternalRenamesDoNotGuessFromDuplicateContents() {
        runAsync {
            let original = try self.write("a.md", "identical")
            _ = try self.write("b.md", "identical")
            let database = SQLiteDatabase(url: self.databaseURL)
            try await database.initialize()
            try await database.reconcile(folder: self.folder)
            let before = try await self.rows(database)
            try FileManager.default.moveItem(at: original, to: self.folder.appendingPathComponent("c.md"))
            try await database.reconcile(folder: self.folder)
            let after = try await self.rows(database)
            XCTAssertEqual(after.count, 2)
            XCTAssertEqual(after.first?[1], .text("b.md"))
            XCTAssertEqual(after.first?[0], before[1][0])
            XCTAssertNotEqual(after.last?[0], before[0][0])
            XCTAssertNotEqual(after.last?[0], before[1][0])
            await database.close()
        }
    }

    @objc func testExplicitRenamePreservesIdentityWhenHashMatches() {
        runAsync {
            let original = try self.write("a.md", "saved")
            let renamed = self.folder.appendingPathComponent("Renamed.md")
            let database = SQLiteDatabase(url: self.databaseURL)
            try await database.initialize()
            try await database.reconcile(folder: self.folder)
            let before = try await self.rows(database)
            try FileManager.default.moveItem(at: original, to: renamed)
            try await database.reconcile(folder: self.folder, rename: NoteRename(source: original, destination: renamed))
            let after = try await self.rows(database)
            XCTAssertEqual(after.count, 1)
            XCTAssertEqual(after.first?[0], before.first?[0])
            XCTAssertEqual(after.first?[1], .text("Renamed.md"))
            XCTAssertEqual(after.first?[2], before.first?[2])
            await database.close()
        }
    }

    @objc func testRenameWithChangedBytesDoesNotReuseOldIdentity() {
        runAsync {
            let original = try self.write("a.md", "before")
            let renamed = self.folder.appendingPathComponent("b.md")
            let database = SQLiteDatabase(url: self.databaseURL)
            try await database.initialize()
            try await database.reconcile(folder: self.folder)
            let before = try await self.rows(database)
            try Data("changed externally".utf8).write(to: original)
            try FileManager.default.moveItem(at: original, to: renamed)
            try await database.reconcile(folder: self.folder, rename: NoteRename(source: original, destination: renamed))
            let after = try await self.rows(database)
            XCTAssertEqual(after.count, 1)
            XCTAssertNotEqual(after[0][0], before[0][0])
            await database.close()
        }
    }

    @objc func testFoldersAndMovedCopiesHaveIndependentNamespaces() {
        runAsync {
            _ = try self.write("same.md", "identical")
            let other = self.root.appendingPathComponent("other")
            try FileManager.default.copyItem(at: self.folder, to: other)
            let database = SQLiteDatabase(url: self.databaseURL)
            try await database.initialize()
            try await database.reconcile(folder: self.folder)
            try await database.reconcile(folder: other)
            let first = try await self.rows(database)
            let second = try await self.rows(database, folder: other)
            XCTAssertNotEqual(first[0][0], second[0][0])
            let moved = self.root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: other, to: moved)
            try await database.reconcile(folder: moved)
            let third = try await self.rows(database, folder: moved)
            XCTAssertNotEqual(second[0][0], third[0][0])
            XCTAssertEqual(first[0][2], third[0][2])
            try await database.reconcile(folder: self.folder)
            let firstAgain = try await self.rows(database)
            XCTAssertEqual(first, firstAgain)
            await database.close()
        }
    }

    @objc func testReadErrorsAreRecordedAndRecoverWithoutInventingHashes() {
        runAsync {
            let url = try self.write("note.md", "valid")
            let database = SQLiteDatabase(url: self.databaseURL)
            try await database.initialize()
            try await database.reconcile(folder: self.folder)
            let before = try await self.rows(database)
            try Data([0xff, 0xfe]).write(to: url)
            let result = try await database.reconcile(folder: self.folder)
            let failed = try await self.rows(database)
            XCTAssertEqual(result.fileErrors, 1)
            XCTAssertEqual(failed[0][2], before[0][2])
            XCTAssertEqual(failed[0][3], .text("error"))
            XCTAssertNotEqual(failed[0][4], .null)
            XCTAssertEqual(failed[0][5], before[0][5])
            _ = try self.write("note.md", "valid again")
            try await database.reconcile(folder: self.folder)
            let recovered = try await self.rows(database)
            XCTAssertEqual(recovered[0][3], .text("indexed"))
            XCTAssertEqual(recovered[0][4], .null)
            XCTAssertNotEqual(recovered[0][2], before[0][2])
            await database.close()
        }
    }

    @objc func testUnsupportedEntriesAreSkippedAndFailedFolderScanKeepsRegistry() {
        runAsync {
            let regular = try self.write("note.md", "valid")
            _ = try self.write("ignored.txt", "text")
            _ = try self.write(".hidden.md", "hidden")
            try FileManager.default.createDirectory(at: self.folder.appendingPathComponent("nested.md"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: self.folder.appendingPathComponent("link.md"), withDestinationURL: regular)
            let database = SQLiteDatabase(url: self.databaseURL)
            try await database.initialize()
            try await database.reconcile(folder: self.folder)
            let before = try await self.rows(database)
            XCTAssertEqual(before.count, 1)
            let moved = self.root.appendingPathComponent("unavailable")
            try FileManager.default.moveItem(at: self.folder, to: moved)
            do {
                try await database.reconcile(folder: self.folder)
                XCTFail("Missing folder must fail")
            } catch { }
            let after = try await self.rows(database)
            XCTAssertEqual(before, after, "Directory failure must not mark existing records missing")
            await database.close()
        }
    }

    @objc func testRegistryWritesRollbackAsOneBatch() {
        runAsync {
            _ = try self.write("original.md", "keep")
            let database = SQLiteDatabase(url: self.databaseURL)
            try await database.initialize()
            try await database.reconcile(folder: self.folder)
            let before = try await self.rows(database)
            try await database.execute(SQLiteStatement("""
                CREATE TRIGGER reject_file BEFORE INSERT ON notes WHEN NEW.relative_path = 'fail.md'
                BEGIN SELECT RAISE(ABORT, 'fixture failure'); END
                """))
            _ = try self.write("good.md", "good")
            _ = try self.write("fail.md", "fail")
            do {
                try await database.reconcile(folder: self.folder)
                XCTFail("Fixture trigger must fail")
            } catch { }
            let after = try await self.rows(database)
            XCTAssertEqual(before, after)
            try await database.execute(SQLiteStatement("DROP TRIGGER reject_file"))
            try await database.reconcile(folder: self.folder)
            let recovered = try await self.rows(database)
            XCTAssertEqual(recovered.count, 3)
            await database.close()
        }
    }

    @objc func testLostDatabaseRebuildsWithFreshIDsAndUnchangedFiles() {
        runAsync {
            let note = try self.write("note.md", "# Portable\n#tag\n")
            let original = try Data(contentsOf: note)
            let first = SQLiteDatabase(url: self.databaseURL)
            try await first.initialize()
            try await first.reconcile(folder: self.folder)
            let before = try await self.rows(first)
            await first.close()
            try FileManager.default.removeItem(at: self.databaseURL)
            let rebuilt = SQLiteDatabase(url: self.databaseURL)
            try await rebuilt.initialize()
            try await rebuilt.reconcile(folder: self.folder)
            let after = try await self.rows(rebuilt)
            XCTAssertNotEqual(before[0][0], after[0][0])
            XCTAssertEqual(before[0][2], after[0][2])
            XCTAssertEqual(try Data(contentsOf: note), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: self.folder.path), ["note.md"])
            await rebuilt.close()
        }
    }

    @objc func testStoreIndexesSaveRenameAndRefreshWithoutChangingDraft() {
        runAsync {
            let database = SQLiteDatabase(url: self.databaseURL)
            let status = await MainActor.run { DatabaseStatus(database: database) }
            let store = try await MainActor.run {
                let store = NoteStore(index: status, defaults: self.defaults)
                try store.activateFolder(self.folder)
                store.text = "saved"
                XCTAssertTrue(store.save())
                return store
            }
            await status.waitForPendingWork()
            let saved = try await self.rows(database)
            XCTAssertEqual(saved.count, 1)
            let selection = await MainActor.run { store.selected! }
            try await MainActor.run {
                store.text = "unsaved edits"
                let editorID = store.editorID
                try store.rename(selection, to: "Renamed")
                XCTAssertEqual(store.text, "unsaved edits")
                XCTAssertEqual(store.editorID, editorID)
                XCTAssertTrue(store.isDirty)
                store.refresh()
                XCTAssertEqual(store.text, "unsaved edits")
            }
            await status.waitForPendingWork()
            let renamed = try await self.rows(database)
            XCTAssertEqual(renamed.count, 1)
            XCTAssertEqual(renamed[0][0], saved[0][0])
            XCTAssertEqual(renamed[0][1], .text("Renamed.md"))
            XCTAssertEqual(renamed[0][2], saved[0][2], "Index reflects saved file, not open unsaved edits")
            let url = self.folder.appendingPathComponent("Renamed.md")
            try Data("external change".utf8).write(to: url)
            await MainActor.run { store.refresh() }
            await status.waitForPendingWork()
            let external = try await self.rows(database)
            XCTAssertNotEqual(external[0][2], saved[0][2])
            await MainActor.run {
                XCTAssertEqual(store.text, "unsaved edits")
                XCTAssertFalse(store.save(), "Existing conflict detection must still protect external edits")
                XCTAssertEqual(store.text, "unsaved edits")
            }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external change")
            await database.close()
        }
    }

    @objc func testDatabaseDowntimeDoesNotBlockFilesAndRetryCatchesUp() {
        runAsync {
            let blocker = self.root.appendingPathComponent("blocked")
            try Data("not a directory".utf8).write(to: blocker)
            let database = SQLiteDatabase(url: blocker.appendingPathComponent("metadata.sqlite"))
            let status = await MainActor.run { DatabaseStatus(database: database) }
            let store = try await MainActor.run {
                let store = NoteStore(index: status, defaults: self.defaults)
                try store.activateFolder(self.folder)
                store.text = "First save"
                XCTAssertTrue(store.save())
                return store
            }
            await status.waitForPendingWork()
            await MainActor.run {
                XCTAssertNotNil(status.failureMessage)
                XCTAssertNil(store.errorMessage)
                store.text = "Saved during downtime"
                XCTAssertTrue(store.save())
                XCTAssertFalse(store.isDirty)
            }
            await status.waitForPendingWork()
            try FileManager.default.removeItem(at: blocker)
            await status.initialize()
            let recovered = try await self.rows(database)
            XCTAssertEqual(recovered.count, 1)
            await MainActor.run { XCTAssertNil(status.failureMessage) }
            await database.close()
        }
    }

    @objc func testQueuedFolderSwitchesAndRestorationIndexBothFolders() {
        runAsync {
            _ = try self.write("note.md", "first folder")
            let other = self.root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            _ = try self.write("note.md", "other folder", in: other)
            let database = SQLiteDatabase(url: self.databaseURL)
            let status = await MainActor.run { DatabaseStatus(database: database) }
            try await MainActor.run {
                let store = NoteStore(index: status, defaults: self.defaults)
                try store.activateFolder(self.folder)
                try store.activateFolder(other)
                store.refresh()
            }
            await status.waitForPendingWork()
            let first = try await self.rows(database)
            let second = try await self.rows(database, folder: other)
            XCTAssertEqual(first.count, 1)
            XCTAssertEqual(second.count, 1)
            XCTAssertNotEqual(first[0][0], second[0][0])
            let restored = await MainActor.run {
                let store = NoteStore(index: status, defaults: self.defaults)
                store.restoreFolder()
                return store
            }
            await status.waitForPendingWork()
            await MainActor.run {
                XCTAssertEqual(restored.folder?.resolvingSymlinksInPath().standardizedFileURL.path,
                               other.resolvingSymlinksInPath().standardizedFileURL.path)
            }
            await database.close()
        }
    }
}
