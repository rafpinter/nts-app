import Foundation
import XCTest

final class EmbeddingRepositoryTests: XCTestCase {
    private var folder: URL!
    private var database: SQLiteDatabase!
    private let space = EmbeddingSpace(configurationJSON: #"{"dimensions":3,"pipeline":"test-v1"}"#,
                                       modelID: "fake/model", modelRevision: "model-revision",
                                       tokenizerRevision: "tokenizer-revision", dimensions: 3,
                                       pipelineVersion: "test-v1")
    private let noteID = "note-1"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        database = SQLiteDatabase(url: folder.appendingPathComponent("metadata.sqlite"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func runAsync(_ body: @escaping () async throws -> Void) {
        let finished = expectation(description: "Embedding database work completed")
        Task.detached {
            do { try await body() } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
    }

    private func seedNote(_ hash: String = "hash-1", database: SQLiteDatabase) async throws {
        try await database.initialize()
        try await database.execute(SQLiteStatement("INSERT INTO folders VALUES ('folder-1', '/fixture')"))
        try await database.execute(SQLiteStatement("""
            INSERT INTO notes (id, folder_id, relative_path, content_hash, sync_state)
            VALUES (?, 'folder-1', 'note.md', ?, 'indexed')
            """, [.text(noteID), .text(hash)]))
        try await database.registerEmbeddingSpace(space)
    }

    @objc func testSQLiteBlobBindingsPreserveEmptyBytesNullAndUnicode() {
        runAsync {
            try await self.database.initialize()
            try await self.database.execute(SQLiteStatement(
                "CREATE TABLE fixture (bytes BLOB, optional_bytes BLOB, text TEXT)"))
            let text = "Café 日本語 ☕️\u{0}value"
            try await self.database.execute(SQLiteStatement(
                "INSERT INTO fixture VALUES (?, ?, ?)", [.blob(Data()), .null, .text(text)]))
            let rows = try await self.database.query(SQLiteStatement("SELECT bytes, optional_bytes, text FROM fixture"))
            XCTAssertEqual(rows, [[.blob(Data()), .null, .text(text)]])
            await self.database.close()
        }
    }

    @objc func testVersionFourDatabaseUpgradesToEmbeddingSchemaAndRollbackIsAtomic() {
        runAsync {
            let v4 = SQLiteDatabase(url: self.folder.appendingPathComponent("v4.sqlite"),
                                    migrations: Array(SQLiteMigration.current.prefix(4)))
            try await v4.initialize()
            try await v4.execute(SQLiteStatement("INSERT INTO folders VALUES ('folder-1', '/fixture')"))
            try await v4.execute(SQLiteStatement("""
                INSERT INTO notes (id, folder_id, relative_path, content_hash, sync_state)
                VALUES ('note-1', 'folder-1', 'note.md', 'hash-1', 'indexed')
                """))
            await v4.close()

            let upgraded = SQLiteDatabase(url: self.folder.appendingPathComponent("v4.sqlite"))
            try await upgraded.initialize()
            let upgradedVersion = try await upgraded.query(SQLiteStatement("PRAGMA user_version"))
            XCTAssertEqual(upgradedVersion, [[.integer(7)]])
            let tables = try await upgraded.query(SQLiteStatement("""
                SELECT name FROM sqlite_master WHERE type = 'table'
                  AND name IN ('embedding_spaces', 'note_embeddings', 'projection_runs', 'note_positions')
                ORDER BY name
                """))
            XCTAssertEqual(tables, [[.text("embedding_spaces")], [.text("note_embeddings")],
                                    [.text("note_positions")], [.text("projection_runs")]])
            let preservedNote = try await upgraded.query(SQLiteStatement("SELECT id, content_hash FROM notes"))
            XCTAssertEqual(preservedNote, [[.text("note-1"), .text("hash-1")]])
            try await upgraded.registerEmbeddingSpace(self.space)
            do {
                try await upgraded.execute(SQLiteStatement("""
                    INSERT INTO note_embeddings
                        (note_id, space_id, source_hash, job_token, state, updated_at)
                    VALUES ('missing-note', ?, 'hash', 'token', 'queued', 0)
                    """, [.text(self.space.fingerprint)]))
                XCTFail("Embedding records must enforce note foreign keys")
            } catch { }
            await upgraded.close()

            let rollbackURL = self.folder.appendingPathComponent("rollback.sqlite")
            let beforeFailure = SQLiteDatabase(url: rollbackURL, migrations: Array(SQLiteMigration.current.prefix(4)))
            try await beforeFailure.initialize()
            await beforeFailure.close()
            var migrations = Array(SQLiteMigration.current.prefix(4))
            migrations.append(SQLiteMigration(version: 5, statements: [
                "CREATE TABLE partial_embedding_migration (value TEXT)", "INVALID SQL"
            ]))
            let broken = SQLiteDatabase(url: rollbackURL, migrations: migrations)
            do {
                try await broken.initialize()
                XCTFail("Expected v5 migration failure")
            } catch { }
            let preserved = SQLiteDatabase(url: rollbackURL, migrations: Array(SQLiteMigration.current.prefix(4)))
            try await preserved.initialize()
            let preservedVersion = try await preserved.query(SQLiteStatement("PRAGMA user_version"))
            XCTAssertEqual(preservedVersion, [[.integer(4)]])
            let partialMigration = try await preserved.query(SQLiteStatement("""
                SELECT name FROM sqlite_master WHERE name = 'partial_embedding_migration'
                """))
            XCTAssertTrue(partialMigration.isEmpty)
            await preserved.close()
        }
    }

    @objc func testFakeEncoderVectorIsStoredInLittleEndianAndReadAsCurrent() {
        runAsync {
            try await self.seedNote(database: self.database)
            let fakeEncoder = FakeEmbeddingEncoder()
            let job = try await self.database.enqueueEmbedding(noteID: self.noteID,
                                                               spaceFingerprint: self.space.fingerprint,
                                                               sourceHash: "hash-1")
            let began = try await self.database.beginEmbedding(job)
            XCTAssertTrue(began)
            let vector = fakeEncoder.encode("alpha note")
            let completed = try await self.database.completeEmbedding(job, vector: vector)
            XCTAssertTrue(completed)
            let current = try await self.database.currentEmbedding(noteID: self.noteID,
                                                                  spaceFingerprint: self.space.fingerprint)
            XCTAssertEqual(current, vector)

            let stored = try await self.database.query(SQLiteStatement(
                "SELECT vector, vector_hash, state FROM note_embeddings WHERE note_id = ?",
                [.text(self.noteID)]))
            guard case let .blob(bytes) = stored[0][0] else {
                XCTFail("Expected a BLOB vector")
                return
            }
            XCTAssertEqual(bytes, Data([0, 0, 128, 63, 0, 0, 0, 0, 0, 0, 0, 0]))
            XCTAssertEqual(stored[0][1], .text(EmbeddingSpace.hash(bytes)))
            XCTAssertEqual(stored[0][2], .text("ready"))
            await self.database.close()
        }
    }

    @objc func testJobsCoalesceRejectStaleCompletionsAndHideMissingSources() {
        runAsync {
            try await self.seedNote(database: self.database)
            let old = try await self.database.enqueueEmbedding(noteID: self.noteID,
                                                               spaceFingerprint: self.space.fingerprint,
                                                               sourceHash: "hash-1")
            let duplicate = try await self.database.enqueueEmbedding(noteID: self.noteID,
                                                                     spaceFingerprint: self.space.fingerprint,
                                                                     sourceHash: "hash-1")
            XCTAssertEqual(old, duplicate)
            let oldBegan = try await self.database.beginEmbedding(old)
            XCTAssertTrue(oldBegan)
            try await self.database.execute(SQLiteStatement(
                "UPDATE notes SET content_hash = ? WHERE id = ?", [.text("hash-2"), .text(self.noteID)]))
            let fresh = try await self.database.enqueueEmbedding(noteID: self.noteID,
                                                                 spaceFingerprint: self.space.fingerprint,
                                                                 sourceHash: "hash-2")
            XCTAssertNotEqual(old.token, fresh.token)
            let oldCompleted = try await self.database.completeEmbedding(old, vector: [1, 0, 0])
            XCTAssertFalse(oldCompleted)
            let missingBeforeCompletion = try await self.database.currentEmbedding(
                noteID: self.noteID, spaceFingerprint: self.space.fingerprint)
            XCTAssertNil(missingBeforeCompletion)
            let freshBegan = try await self.database.beginEmbedding(fresh)
            XCTAssertTrue(freshBegan)
            let freshCompleted = try await self.database.completeEmbedding(fresh, vector: [0, 1, 0])
            XCTAssertTrue(freshCompleted)
            let current = try await self.database.currentEmbedding(noteID: self.noteID,
                                                                  spaceFingerprint: self.space.fingerprint)
            XCTAssertEqual(current, [0, 1, 0])
            try await self.database.execute(SQLiteStatement(
                "UPDATE notes SET sync_state = 'missing' WHERE id = ?", [.text(self.noteID)]))
            let missingAfterDelete = try await self.database.currentEmbedding(
                noteID: self.noteID, spaceFingerprint: self.space.fingerprint)
            XCTAssertNil(missingAfterDelete)
            await self.database.close()
        }
    }

    @objc func testSeparateModelSpacesKeepIndependentVectorsAndEnforceUniqueJobs() {
        runAsync {
            try await self.seedNote(database: self.database)
            let secondSpace = EmbeddingSpace(configurationJSON: #"{"dimensions":3,"pipeline":"other-v1"}"#,
                                             modelID: "fake/other-model", modelRevision: "other-revision",
                                             tokenizerRevision: "other-tokenizer", dimensions: 3,
                                             pipelineVersion: "other-v1")
            try await self.database.registerEmbeddingSpace(secondSpace)
            let firstJob = try await self.database.enqueueEmbedding(noteID: self.noteID,
                                                                    spaceFingerprint: self.space.fingerprint,
                                                                    sourceHash: "hash-1")
            let secondJob = try await self.database.enqueueEmbedding(noteID: self.noteID,
                                                                     spaceFingerprint: secondSpace.fingerprint,
                                                                     sourceHash: "hash-1")
            XCTAssertNotEqual(firstJob.token, secondJob.token)
            let firstBegan = try await self.database.beginEmbedding(firstJob)
            let secondBegan = try await self.database.beginEmbedding(secondJob)
            XCTAssertTrue(firstBegan)
            XCTAssertTrue(secondBegan)
            let firstComplete = try await self.database.completeEmbedding(firstJob, vector: [1, 0, 0])
            let secondComplete = try await self.database.completeEmbedding(secondJob, vector: [0, 1, 0])
            XCTAssertTrue(firstComplete)
            XCTAssertTrue(secondComplete)
            let firstVector = try await self.database.currentEmbedding(noteID: self.noteID,
                                                                       spaceFingerprint: self.space.fingerprint)
            let secondVector = try await self.database.currentEmbedding(noteID: self.noteID,
                                                                        spaceFingerprint: secondSpace.fingerprint)
            XCTAssertEqual(firstVector, [1, 0, 0])
            XCTAssertEqual(secondVector, [0, 1, 0])
            do {
                try await self.database.execute(SQLiteStatement("""
                    INSERT INTO note_embeddings
                        (note_id, space_id, source_hash, job_token, state, updated_at)
                    VALUES (?, ?, 'hash-1', 'duplicate-token', 'queued', 0)
                    """, [.text(self.noteID), .text(self.space.fingerprint)]))
                XCTFail("The note/model-space pair must be unique")
            } catch { }
            await self.database.close()
        }
    }

    @objc func testRestartRecoveryRotatesTokensAndErrorsCanBeRetried() {
        runAsync {
            try await self.seedNote(database: self.database)
            let interrupted = try await self.database.enqueueEmbedding(noteID: self.noteID,
                                                                       spaceFingerprint: self.space.fingerprint,
                                                                       sourceHash: "hash-1")
            let began = try await self.database.beginEmbedding(interrupted)
            XCTAssertTrue(began)
            let recoveredCount = try await self.database.recoverInterruptedEmbeddings()
            XCTAssertEqual(recoveredCount, 1)
            let recovered = try await self.database.query(SQLiteStatement(
                "SELECT state, job_token, attempts FROM note_embeddings WHERE note_id = ?",
                [.text(self.noteID)]))
            XCTAssertEqual(recovered[0][0], .text("queued"))
            XCTAssertNotEqual(recovered[0][1], .text(interrupted.token))
            XCTAssertEqual(recovered[0][2], .integer(1))
            let staleCompletion = try await self.database.completeEmbedding(interrupted, vector: [1, 0, 0])
            XCTAssertFalse(staleCompletion)

            guard case let .text(retryToken) = recovered[0][1] else {
                XCTFail("Expected a replacement job token")
                return
            }
            let recoveredJob = EmbeddingJob(noteID: self.noteID, spaceFingerprint: self.space.fingerprint,
                                            sourceHash: "hash-1", token: retryToken)
            let recoveredBegan = try await self.database.beginEmbedding(recoveredJob)
            XCTAssertTrue(recoveredBegan)
            let failed = try await self.database.failEmbedding(recoveredJob, message: "fixture failure")
            XCTAssertTrue(failed)
            guard let retried = try await self.database.retryFailedEmbedding(recoveredJob, maximumAttempts: 3) else {
                XCTFail("Expected a bounded retry to be queued")
                return
            }
            XCTAssertNotEqual(recoveredJob.token, retried.token)
            let retryBegan = try await self.database.beginEmbedding(retried)
            XCTAssertTrue(retryBegan)
            let failedAgain = try await self.database.failEmbedding(retried, message: "second failure")
            XCTAssertTrue(failedAgain)
            let exhaustedRetry = try await self.database.retryFailedEmbedding(retried)
            XCTAssertNil(exhaustedRetry)
            await self.database.close()
        }
    }

    @objc func testVectorCodecRejectsWrongDimensionsNonfiniteZeroAndMalformedBytes() {
        XCTAssertThrowsError(try EmbeddingVectorCodec.encode([1, 0], dimensions: 3))
        XCTAssertThrowsError(try EmbeddingVectorCodec.encode([.nan, 0, 0], dimensions: 3))
        XCTAssertThrowsError(try EmbeddingVectorCodec.encode([0, 0, 0], dimensions: 3))
        XCTAssertThrowsError(try EmbeddingVectorCodec.decode(Data([0, 0, 0]), dimensions: 3))
        XCTAssertThrowsError(try EmbeddingVectorCodec.decode(
            Data([0, 0, 192, 127, 0, 0, 0, 0, 0, 0, 0, 0]), dimensions: 3))
    }
}

private struct FakeEmbeddingEncoder {
    func encode(_ text: String) -> [Float] {
        text.contains("alpha") ? [1, 0, 0] : [0, 1, 0]
    }
}
