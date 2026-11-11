import Foundation
import XCTest

final class SQLiteDatabaseTests: XCTestCase {
    private var folder: URL!
    private var url: URL { folder.appendingPathComponent("metadata.sqlite") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func runAsync(_ body: @escaping () async throws -> Void) {
        let finished = expectation(description: "Database work completed")
        Task.detached {
            do { try await body() } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
    }

    private func expectFailure(_ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("Expected database operation to fail")
        } catch { }
    }

    @objc func testFirstLaunchCreatesOnlyVersionedFoundation() {
        runAsync {
            let database = SQLiteDatabase(url: self.url, migrations: SQLiteMigration.foundation)
            let resolved = try await database.initialize()
            XCTAssertEqual(resolved, self.url)
            let version = try await database.query(SQLiteStatement("PRAGMA user_version"))
            let tables = try await database.query(SQLiteStatement("SELECT name FROM sqlite_master WHERE type = 'table'"))
            let foreignKeys = try await database.query(SQLiteStatement("PRAGMA foreign_keys"))
            let journal = try await database.query(SQLiteStatement("PRAGMA journal_mode"))
            let synchronous = try await database.query(SQLiteStatement("PRAGMA synchronous"))
            let timeout = try await database.query(SQLiteStatement("PRAGMA busy_timeout"))
            XCTAssertEqual(version, [[.integer(1)]])
            XCTAssertTrue(tables.isEmpty)
            XCTAssertEqual(foreignKeys, [[.integer(1)]])
            XCTAssertEqual(journal, [[.text("delete")]])
            XCTAssertEqual(synchronous, [[.integer(2)]])
            XCTAssertEqual(timeout, [[.integer(1_500)]])
            await database.close()
        }
    }

    @objc func testReopeningPreservesDataAndDoesNotRepeatMigrations() {
        runAsync {
            let migrations = [SQLiteMigration(version: 1, statements: [
                "CREATE TABLE fixture (value TEXT NOT NULL)",
                "INSERT INTO fixture VALUES ('initial')"
            ])]
            let first = SQLiteDatabase(url: self.url, migrations: migrations)
            try await first.initialize()
            try await first.execute(SQLiteStatement("UPDATE fixture SET value = ?", [.text("saved")]))
            await first.close()
            let reopened = SQLiteDatabase(url: self.url, migrations: migrations)
            try await reopened.initialize()
            let rows = try await reopened.query(SQLiteStatement("SELECT value FROM fixture"))
            XCTAssertEqual(rows, [[.text("saved")]])
            // initialize is idempotent even while a connection is already open.
            try await reopened.initialize()
            await reopened.close()
        }
    }

    @objc func testOrderedMigrationsUpgradeAnExistingDatabase() {
        runAsync {
            let firstMigration = SQLiteMigration(version: 1, statements: ["CREATE TABLE fixture (value INTEGER)"])
            let first = SQLiteDatabase(url: self.url, migrations: [firstMigration])
            try await first.initialize()
            await first.close()
            let upgraded = SQLiteDatabase(url: self.url, migrations: [firstMigration,
                SQLiteMigration(version: 2, statements: ["ALTER TABLE fixture ADD COLUMN label TEXT"]),
                SQLiteMigration(version: 3, statements: ["INSERT INTO fixture VALUES (7, 'upgraded')"])
            ])
            try await upgraded.initialize()
            let rows = try await upgraded.query(SQLiteStatement("SELECT * FROM fixture"))
            let version = try await upgraded.query(SQLiteStatement("PRAGMA user_version"))
            XCTAssertEqual(rows, [[.integer(7), .text("upgraded")]])
            XCTAssertEqual(version, [[.integer(3)]])
            await upgraded.close()
        }
    }

    @objc func testFailedMigrationRollsBackSchemaDataAndVersion() {
        runAsync {
            let base = SQLiteMigration(version: 1, statements: [
                "CREATE TABLE fixture (value TEXT)", "INSERT INTO fixture VALUES ('keep')"
            ])
            let original = SQLiteDatabase(url: self.url, migrations: [base])
            try await original.initialize()
            await original.close()
            let broken = SQLiteDatabase(url: self.url, migrations: [base,
                SQLiteMigration(version: 2, statements: [
                    "CREATE TABLE partial (value TEXT)", "DELETE FROM fixture", "INVALID SQL"
                ])
            ])
            await self.expectFailure { try await broken.initialize() }
            let reopened = SQLiteDatabase(url: self.url, migrations: [base])
            try await reopened.initialize()
            let rows = try await reopened.query(SQLiteStatement("SELECT value FROM fixture"))
            let partial = try await reopened.query(SQLiteStatement("SELECT name FROM sqlite_master WHERE name = 'partial'"))
            let version = try await reopened.query(SQLiteStatement("PRAGMA user_version"))
            XCTAssertEqual(rows, [[.text("keep")]])
            XCTAssertTrue(partial.isEmpty)
            XCTAssertEqual(version, [[.integer(1)]])
            await reopened.close()
            // A corrected migration can subsequently run; failure did not retain locks.
            let fixed = SQLiteDatabase(url: self.url, migrations: [base,
                SQLiteMigration(version: 2, statements: ["CREATE TABLE partial (value TEXT)"])
            ])
            try await fixed.initialize()
            await fixed.close()
        }
    }

    @objc func testTransactionRollbackLeavesConnectionUsable() {
        runAsync {
            let database = SQLiteDatabase(url: self.url)
            try await database.initialize()
            try await database.execute(SQLiteStatement("CREATE TABLE fixture (id INTEGER PRIMARY KEY)"))
            await self.expectFailure {
                try await database.transaction([
                    SQLiteStatement("INSERT INTO fixture VALUES (1)"),
                    SQLiteStatement("INSERT INTO fixture VALUES (1)")
                ])
            }
            let empty = try await database.query(SQLiteStatement("SELECT * FROM fixture"))
            XCTAssertTrue(empty.isEmpty)
            try await database.transaction([SQLiteStatement("INSERT INTO fixture VALUES (2)")])
            let rows = try await database.query(SQLiteStatement("SELECT * FROM fixture"))
            XCTAssertEqual(rows, [[.integer(2)]])
            await database.close()
        }
    }

    @objc func testForeignKeysRejectOrphans() {
        runAsync {
            let database = SQLiteDatabase(url: self.url)
            try await database.initialize()
            try await database.execute(SQLiteStatement("CREATE TABLE parent (id INTEGER PRIMARY KEY)"))
            try await database.execute(SQLiteStatement("CREATE TABLE child (parent_id INTEGER REFERENCES parent(id))"))
            await self.expectFailure { try await database.execute(SQLiteStatement("INSERT INTO child VALUES (9)")) }
            try await database.transaction([
                SQLiteStatement("INSERT INTO parent VALUES (9)"), SQLiteStatement("INSERT INTO child VALUES (9)")
            ])
            let rows = try await database.query(SQLiteStatement("SELECT * FROM child"))
            XCTAssertEqual(rows, [[.integer(9)]])
            await database.close()
        }
    }

    @objc func testUnavailableDirectoryPreservesBlockingFile() {
        runAsync {
            let blocker = self.folder.appendingPathComponent("blocked")
            let original = Data("Keep this file".utf8)
            try original.write(to: blocker)
            let database = SQLiteDatabase(url: blocker.appendingPathComponent("metadata.sqlite"))
            await self.expectFailure { try await database.initialize() }
            XCTAssertEqual(try Data(contentsOf: blocker), original)
        }
    }

    @objc func testCorruptDatabaseIsNotReplaced() {
        runAsync {
            let original = Data("This is not a SQLite database".utf8)
            try original.write(to: self.url)
            let database = SQLiteDatabase(url: self.url)
            await self.expectFailure { try await database.initialize() }
            XCTAssertEqual(try Data(contentsOf: self.url), original)
        }
    }

    @objc func testNewerSchemaIsRefusedWithoutModification() {
        runAsync {
            let newer = SQLiteDatabase(url: self.url, migrations: [
                SQLiteMigration(version: 1, statements: []),
                SQLiteMigration(version: 2, statements: ["CREATE TABLE future_data (value TEXT)",
                                                       "INSERT INTO future_data VALUES ('keep')"])
            ])
            try await newer.initialize()
            await newer.close()
            let original = try Data(contentsOf: self.url)
            let older = SQLiteDatabase(url: self.url, migrations: SQLiteMigration.foundation)
            do {
                try await older.initialize()
                XCTFail("A newer schema must be refused")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("newer app version"))
            }
            XCTAssertEqual(try Data(contentsOf: self.url), original)
        }
    }

    @objc func testBoundValuesAndStatementValidation() {
        runAsync {
            let database = SQLiteDatabase(url: self.url)
            try await database.initialize()
            try await database.execute(SQLiteStatement("CREATE TABLE fixture (text_value TEXT, number INTEGER, real_value REAL, optional TEXT)"))
            let text = "Café 日本語 ☕️\u{0}'); DROP TABLE fixture; --"
            try await database.execute(SQLiteStatement("INSERT INTO fixture VALUES (?, ?, ?, ?)",
                                                       [.text(text), .integer(42), .real(1.5), .null]))
            let rows = try await database.query(SQLiteStatement("SELECT * FROM fixture"))
            XCTAssertEqual(rows, [[.text(text), .integer(42), .real(1.5), .null]])
            await self.expectFailure { try await database.execute(SQLiteStatement("INSERT INTO fixture VALUES (?, ?, ?, ?)")) }
            await self.expectFailure { try await database.execute(SQLiteStatement("DELETE FROM fixture; DROP TABLE fixture")) }
            await self.expectFailure { try await database.execute(SQLiteStatement("DELETE FROM fixture\u{0}")) }
            let stillPresent = try await database.query(SQLiteStatement("SELECT count(*) FROM fixture"))
            XCTAssertEqual(stillPresent, [[.integer(1)]])
            await database.close()
        }
    }

    @objc func testConcurrentBatchesAreSerialized() {
        runAsync {
            let database = SQLiteDatabase(url: self.url)
            try await database.initialize()
            try await database.execute(SQLiteStatement("CREATE TABLE counter (value INTEGER)"))
            try await database.execute(SQLiteStatement("INSERT INTO counter VALUES (0)"))
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<40 {
                    group.addTask {
                        try await database.transaction([
                            SQLiteStatement("UPDATE counter SET value = value + 1"),
                            SQLiteStatement("UPDATE counter SET value = value + 1")
                        ])
                    }
                }
                try await group.waitForAll()
            }
            let rows = try await database.query(SQLiteStatement("SELECT value FROM counter"))
            XCTAssertEqual(rows, [[.integer(80)]])
            await database.close()
        }
    }

    @objc func testBusyDatabaseTimesOutAndCanRetryAfterUnlock() {
        runAsync {
            let owner = SQLiteDatabase(url: self.url)
            try await owner.initialize()
            try await owner.execute(SQLiteStatement("BEGIN IMMEDIATE"))
            let contender = SQLiteDatabase(url: self.url)
            let started = Date()
            await self.expectFailure { try await contender.initialize() }
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
            try await owner.execute(SQLiteStatement("ROLLBACK"))
            try await contender.initialize()
            await contender.close()
            await owner.close()
        }
    }

    @objc func testInvalidMigrationSequenceIsRejectedBeforeCreatingDatabase() {
        runAsync {
            let database = SQLiteDatabase(url: self.url, migrations: [SQLiteMigration(version: 2, statements: [])])
            await self.expectFailure { try await database.initialize() }
            XCTAssertFalse(FileManager.default.fileExists(atPath: self.url.path))
        }
    }

    @objc func testFailureStatusAllowsMarkdownUseAndRetry() {
        runAsync {
            let blocker = self.folder.appendingPathComponent("blocked")
            try Data("blocker".utf8).write(to: blocker)
            let database = SQLiteDatabase(url: blocker.appendingPathComponent("metadata.sqlite"))
            let status = await MainActor.run { DatabaseStatus(database: database) }
            await status.initialize()
            await MainActor.run {
                XCTAssertNotNil(status.failureMessage)
                XCTAssertFalse(status.isInitializing)
                XCTAssertNil(status.databaseURL)
                let notes = NoteStore()
                notes.text = "I can still type"
                XCTAssertTrue(notes.isDirty)
                XCTAssertNil(notes.errorMessage)
            }
            // Markdown I/O is independent of database availability.
            let files = NoteFileService()
            let note = try files.create(in: self.folder, text: "Existing note")
            let saved = try files.save("Edited without database", to: note, expected: Data("Existing note".utf8))
            XCTAssertEqual(try files.read(note).data, saved)
            try FileManager.default.removeItem(at: blocker)
            await status.initialize()
            await MainActor.run {
                XCTAssertNil(status.failureMessage)
                XCTAssertNotNil(status.databaseURL)
                XCTAssertFalse(status.isInitializing)
            }
            await database.close()
        }
    }
}
