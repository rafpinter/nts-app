import Foundation
import XCTest

final class NoteProjectionTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var database: SQLiteDatabase!
    private let space = EmbeddingSpace(configurationJSON: #"{"dimensions":3,"pipeline":"projection-test-v1"}"#,
                                       modelID: "fixture/model", modelRevision: "model-r1",
                                       tokenizerRevision: "tokenizer-r1", dimensions: 3,
                                       pipelineVersion: "projection-test-v1")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        database = SQLiteDatabase(url: root.appendingPathComponent("metadata.sqlite"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func runAsync(_ body: @escaping () async throws -> Void) {
        let finished = expectation(description: "Projection work completed")
        Task.detached {
            do { try await body() } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
    }

    private func snapshot(_ vectors: [[Float]]) throws -> ProjectionInputSnapshot {
        let inputs = try vectors.enumerated().map { index, vector -> ProjectionInput in
            let bytes = try EmbeddingVectorCodec.encode(vector, dimensions: vector.count)
            return ProjectionInput(noteID: "note-\(index)", sourceHash: "source-\(index)",
                                   vectorHash: EmbeddingSpace.hash(bytes), vector: vector)
        }
        return try ProjectionInputSnapshot(folder: folder, spaceFingerprint: space.fingerprint,
                                           dimensions: vectors.first?.count ?? 3, inputs: inputs)
    }

    @objc func testPCAProducesCenteredCanonicalCoordinatesForKnownGeometry() {
        runAsync {
            let snapshot = try self.snapshot([[1, 0, 0], [-1, 0, 0], [0, 1, 0]])
            let result = try await NoteProjectionReducer.project(snapshot)
            XCTAssertEqual(result.mean[0], 0, accuracy: 1e-12)
            XCTAssertEqual(result.mean[1], 1.0 / 3.0, accuracy: 1e-12)
            XCTAssertEqual(result.mean[2], 0, accuracy: 1e-12)
            let positions = Dictionary(uniqueKeysWithValues: result.positions.map { ($0.noteID, $0) })
            XCTAssertEqual(positions["note-0"]?.x ?? .nan, 1, accuracy: 1e-6)
            XCTAssertEqual(positions["note-1"]?.x ?? .nan, -1, accuracy: 1e-6)
            XCTAssertEqual(positions["note-2"]?.x ?? .nan, 0, accuracy: 1e-6)
            XCTAssertEqual(positions["note-0"]?.y ?? .nan, -1.0 / 3.0, accuracy: 1e-6)
            XCTAssertEqual(positions["note-1"]?.y ?? .nan, -1.0 / 3.0, accuracy: 1e-6)
            XCTAssertEqual(positions["note-2"]?.y ?? .nan, 2.0 / 3.0, accuracy: 1e-6)

            let reordered = try ProjectionInputSnapshot(folder: self.folder,
                                                        spaceFingerprint: self.space.fingerprint,
                                                        dimensions: snapshot.dimensions,
                                                        inputs: Array(snapshot.inputs.reversed()))
            let repeated = try await NoteProjectionReducer.project(reordered)
            XCTAssertEqual(snapshot.inputFingerprint, reordered.inputFingerprint,
                           "Input ordering must not affect the canonical fingerprint.")
            XCTAssertEqual(result, repeated, "Unchanged inputs must reduce deterministically.")
        }
    }

    @objc func testProjectionAlignmentMatchesPreviousLayoutIncludingReflection() {
        runAsync {
            let snapshot = try self.snapshot([[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0]])
            let result = try await NoteProjectionReducer.project(snapshot)
            let cosine = cos(0.73)
            let sine = sin(0.73)
            let reference = result.positions.prefix(3).map { point in
                NoteProjectionPosition(noteID: point.noteID, sourceHash: point.sourceHash,
                                       vectorHash: point.vectorHash,
                                       x: cosine * point.x + sine * point.y,
                                       y: sine * point.x - cosine * point.y)
            }

            let aligned = NoteProjectionReducer.align(result, to: reference)
            let alignedByID = Dictionary(uniqueKeysWithValues: aligned.positions.map { ($0.noteID, $0) })
            for point in reference {
                let actual = try XCTUnwrap(alignedByID[point.noteID])
                XCTAssertEqual(actual.x, point.x, accuracy: 1e-10)
                XCTAssertEqual(actual.y, point.y, accuracy: 1e-10)
            }
            let insufficientReference = Array(reference.prefix(1))
            XCTAssertEqual(NoteProjectionReducer.align(result, to: insufficientReference), result,
                           "A single shared note cannot determine the layout orientation.")

            let dimensions = snapshot.dimensions
            for (input, point) in zip(snapshot.inputs, aligned.positions) {
                var x = 0.0
                var y = 0.0
                for index in 0..<dimensions {
                    let centered = Double(input.vector[index]) - aligned.mean[index]
                    x += centered * aligned.basis[index]
                    y += centered * aligned.basis[dimensions + index]
                }
                XCTAssertEqual(x, point.x, accuracy: 1e-6)
                XCTAssertEqual(y, point.y, accuracy: 1e-6)
            }
        }
    }

    @objc func testDegenerateInputsHaveFiniteCenteredCoincidentOrLineCoordinates() {
        runAsync {
            let empty = try self.snapshot([])
            let emptyResult = try await NoteProjectionReducer.project(empty)
            XCTAssertEqual(emptyResult.mean, [0, 0, 0])
            XCTAssertTrue(emptyResult.positions.isEmpty)
            XCTAssertEqual(emptyResult.basis, Array(repeating: 0, count: 6))

            let single = try self.snapshot([[0, 1, 0]])
            let singleResult = try await NoteProjectionReducer.project(single)
            XCTAssertEqual(singleResult.positions.map(\.x), [0])
            XCTAssertEqual(singleResult.positions.map(\.y), [0])

            let twoNotes = try self.snapshot([[1, 0, 0], [-1, 0, 0]])
            let twoNoteResult = try await NoteProjectionReducer.project(twoNotes)
            XCTAssertEqual(twoNoteResult.positions.map(\.x), [1, -1])
            XCTAssertEqual(twoNoteResult.positions.map(\.y), [0, 0])

            let duplicated = try self.snapshot([[1, 0, 0], [1, 0, 0], [-1, 0, 0], [-1, 0, 0]])
            let duplicateResult = try await NoteProjectionReducer.project(duplicated)
            let positions = Dictionary(uniqueKeysWithValues: duplicateResult.positions.map { ($0.noteID, $0) })
            XCTAssertEqual(positions["note-0"]?.x ?? .nan, positions["note-1"]?.x ?? .nan, accuracy: 1e-12)
            XCTAssertEqual(positions["note-2"]?.x ?? .nan, positions["note-3"]?.x ?? .nan, accuracy: 1e-12)
            XCTAssertTrue(duplicateResult.positions.allSatisfy { $0.y == 0 && $0.x.isFinite && $0.y.isFinite })

            let coincident = try self.snapshot([[0, 1, 0], [0, 1, 0], [0, 1, 0]])
            let coincidentResult = try await NoteProjectionReducer.project(coincident)
            XCTAssertTrue(coincidentResult.positions.allSatisfy { $0.x == 0 && $0.y == 0 })
        }
    }

    @objc func testFloat64CodecValidatesEndianPayloadAndMemoryEstimateIsLinear() throws {
        let values = [1.0, -2.5, Double.leastNormalMagnitude]
        let bytes = try ProjectionFloat64Codec.encode(values)
        XCTAssertEqual(Array(bytes.prefix(8)), [0, 0, 0, 0, 0, 0, 240, 63])
        XCTAssertEqual(try ProjectionFloat64Codec.decode(bytes, count: values.count), values)
        XCTAssertThrowsError(try ProjectionFloat64Codec.encode([.infinity]))
        XCTAssertThrowsError(try ProjectionFloat64Codec.decode(Data([0]), count: 1))
        XCTAssertNil(NoteProjectionReducer.estimatedWorkingMemoryBytes(noteCount: Int.max, dimensions: 384))
        let one = try XCTUnwrap(NoteProjectionReducer.estimatedWorkingMemoryBytes(noteCount: 1_000, dimensions: 384))
        let two = try XCTUnwrap(NoteProjectionReducer.estimatedWorkingMemoryBytes(noteCount: 2_000, dimensions: 384))
        XCTAssertEqual(two - one, 1_000 * 384 * MemoryLayout<Double>.size)
        XCTAssertLessThan(try XCTUnwrap(NoteProjectionReducer.estimatedWorkingMemoryBytes(
            noteCount: 10_000, dimensions: 384)), 32_000_000)
    }

    @objc func testProjectionPerformanceAt1001000And10000Notes() {
        runAsync {
            let dimensions = 384
            for noteCount in [100, 1_000, 10_000] {
                let started = Date.timeIntervalSinceReferenceDate
                let inputs = try (0..<noteCount).map { noteIndex -> ProjectionInput in
                    var state = UInt64(noteIndex + 1)
                    var vector = Array(repeating: Float.zero, count: dimensions)
                    var squaredNorm: Double = 0
                    for dimension in 0..<dimensions {
                        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                        let sample = Double(Int32(bitPattern: UInt32(truncatingIfNeeded: state)))
                            / Double(Int32.max)
                        vector[dimension] = Float(sample)
                        squaredNorm += sample * sample
                    }
                    let norm = Float(sqrt(squaredNorm))
                    for dimension in vector.indices { vector[dimension] /= norm }
                    let encoded = try EmbeddingVectorCodec.encode(vector, dimensions: dimensions)
                    return ProjectionInput(noteID: "performance-\(noteIndex)",
                                           sourceHash: "source-\(noteIndex)",
                                           vectorHash: EmbeddingSpace.hash(encoded), vector: vector)
                }
                let snapshot = try ProjectionInputSnapshot(
                    folder: self.folder, spaceFingerprint: "projection-performance-fixture",
                    dimensions: dimensions, inputs: inputs)
                let preparedAt = Date.timeIntervalSinceReferenceDate
                let result = try await NoteProjectionReducer.project(snapshot)
                let completedAt = Date.timeIntervalSinceReferenceDate
                let estimate = try XCTUnwrap(NoteProjectionReducer.estimatedWorkingMemoryBytes(
                    noteCount: noteCount, dimensions: dimensions))
                XCTAssertEqual(result.positions.count, noteCount)
                print(String(format: "E6 projection benchmark: notes=%d dimensions=%d prepare=%.3fs "
                             + "reduce=%.3fs reducer-working-memory-estimate=%d bytes",
                             noteCount, dimensions, preparedAt - started, completedAt - preparedAt, estimate))
            }
        }
    }

    @objc func testProjectionPersistenceReusesRunsAndRejectsObsoleteOrForeignSnapshots() {
        runAsync {
            try await self.database.initialize()
            let vectors: [[Float]] = [[1, 0, 0], [-1, 0, 0], [0, 1, 0]]
            let indexed = try await self.index(vectors, in: self.folder, prefix: "note")
            try await self.database.registerEmbeddingSpace(self.space)
            try await self.completeEmbeddings(indexed, vectors: vectors, space: self.space)

            let input = try await self.database.currentProjectionInputs(
                folder: self.folder, spaceFingerprint: self.space.fingerprint)
            let result = try await NoteProjectionReducer.project(input)
            let published = try await self.database.persistProjection(snapshot: input, result: result)
            XCTAssertEqual(published.positions.count, 3)
            XCTAssertEqual(published.positions.map(\.noteID), published.positions.map(\.noteID).sorted())
            let reopened = try await self.database.currentProjection(
                folder: self.folder, spaceFingerprint: self.space.fingerprint)
            XCTAssertEqual(reopened, published)
            let reused = try await self.database.persistProjection(snapshot: input, result: result)
            XCTAssertEqual(reused.runID, published.runID)
            let runCount = try await self.database.query(SQLiteStatement("SELECT count(*) FROM projection_runs"))
            XCTAssertEqual(runCount, [[.integer(1)]])

            for item in indexed {
                let vector = try await self.database.currentEmbedding(
                    noteID: item.noteID, spaceFingerprint: self.space.fingerprint)
                XCTAssertEqual(vector, item.vector, "Projection persistence must preserve original embeddings.")
            }

            let otherSpace = EmbeddingSpace(configurationJSON: #"{"dimensions":3,"pipeline":"other-projection"}"#,
                                            modelID: "fixture/other", modelRevision: "other-r1",
                                            tokenizerRevision: "other-tokenizer", dimensions: 3,
                                            pipelineVersion: "other-projection")
            try await self.database.registerEmbeddingSpace(otherSpace)
            try await self.completeEmbeddings(indexed, vectors: vectors, space: otherSpace)
            let otherSpaceRun = try await self.database.currentProjection(
                folder: self.folder, spaceFingerprint: otherSpace.fingerprint)
            XCTAssertNil(otherSpaceRun, "A layout must never leak across embedding spaces.")

            let otherFolder = self.root.appendingPathComponent("other-notes")
            try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
            let otherNotes = try await self.index(vectors, in: otherFolder, prefix: "copy")
            try await self.completeEmbeddings(otherNotes, vectors: vectors, space: self.space)
            let foreignRun = try await self.database.currentProjection(
                folder: otherFolder, spaceFingerprint: self.space.fingerprint)
            XCTAssertNil(foreignRun, "A layout must never leak across folders.")

            let staleInput = try await self.database.currentProjectionInputs(
                folder: self.folder, spaceFingerprint: self.space.fingerprint)
            let staleResult = try await NoteProjectionReducer.project(staleInput)
            try await self.database.execute(SQLiteStatement(
                "UPDATE notes SET content_hash = 'changed-after-snapshot' WHERE id = ?",
                [.text(indexed[0].noteID)]))
            do {
                _ = try await self.database.persistProjection(snapshot: staleInput, result: staleResult)
                XCTFail("A changed dataset must reject stale projection publication.")
            } catch let error as SQLiteFailure {
                XCTAssertTrue(error.message.contains("changed before the layout"))
            }
            let latest = try await self.database.currentProjection(
                folder: self.folder, spaceFingerprint: self.space.fingerprint)
            XCTAssertNil(latest, "The old run must not be exposed as current after a source change.")
            let lastComplete = try await self.database.latestProjection(
                folder: self.folder, spaceFingerprint: self.space.fingerprint)
            XCTAssertEqual(lastComplete?.positions.count, 2,
                           "Stale note positions must be hidden while still retaining valid prior positions.")
            XCTAssertFalse(lastComplete?.positions.contains { $0.noteID == indexed[0].noteID } ?? true)

            await self.database.close()
        }
    }

    @objc func testConfirmedDeletionCascadesNoteAndProjectionMetadata() {
        runAsync {
            try await self.database.initialize()
            let vectors: [[Float]] = [[1, 0, 0], [-1, 0, 0]]
            let indexed = try await self.index(vectors, in: self.folder, prefix: "delete")
            try await self.database.registerEmbeddingSpace(self.space)
            try await self.completeEmbeddings(indexed, vectors: vectors, space: self.space)

            let snapshot = try await self.database.currentProjectionInputs(
                folder: self.folder, spaceFingerprint: self.space.fingerprint)
            let result = try await NoteProjectionReducer.project(snapshot)
            _ = try await self.database.persistProjection(snapshot: snapshot, result: result)
            try await self.database.execute(SQLiteStatement("""
                INSERT INTO filename_suggestions
                    (note_id, source_hash, configuration_hash, model_id, model_revision,
                     prompt_version, configuration_json, state)
                VALUES (?, ?, 'config', 'model', 'revision', 'prompt', '{}', 'ready')
                """, [.text(indexed[0].noteID), .text(indexed[0].sourceHash)]))

            try FileManager.default.removeItem(at: self.folder.appendingPathComponent(indexed[0].path))
            try await self.database.reconcile(folder: self.folder)
            let noteCount = try await self.database.query(SQLiteStatement(
                "SELECT count(*) FROM notes WHERE id = ?", [.text(indexed[0].noteID)]))
            let embeddingCount = try await self.database.query(SQLiteStatement(
                "SELECT count(*) FROM note_embeddings WHERE note_id = ?", [.text(indexed[0].noteID)]))
            let suggestionCount = try await self.database.query(SQLiteStatement(
                "SELECT count(*) FROM filename_suggestions WHERE note_id = ?", [.text(indexed[0].noteID)]))
            let runCount = try await self.database.query(SQLiteStatement("SELECT count(*) FROM projection_runs"))
            let positionCount = try await self.database.query(SQLiteStatement("SELECT count(*) FROM note_positions"))
            XCTAssertEqual(noteCount, [[.integer(0)]])
            XCTAssertEqual(embeddingCount, [[.integer(0)]])
            XCTAssertEqual(suggestionCount, [[.integer(0)]])
            XCTAssertEqual(runCount, [[.integer(0)]])
            XCTAssertEqual(positionCount, [[.integer(0)]])
            await self.database.close()
        }
    }

    @objc func testVersionFiveDatabaseMigratesProjectionTablesAndV6RollbackIsAtomic() {
        runAsync {
            let url = self.root.appendingPathComponent("v5.sqlite")
            let versionFive = SQLiteDatabase(url: url, migrations: Array(SQLiteMigration.current.prefix(5)))
            try await versionFive.initialize()
            await versionFive.close()

            let upgraded = SQLiteDatabase(url: url)
            try await upgraded.initialize()
            let upgradedVersion = try await upgraded.query(SQLiteStatement("PRAGMA user_version"))
            XCTAssertEqual(upgradedVersion, [[.integer(7)]])
            let tables = try await upgraded.query(SQLiteStatement("""
                SELECT name FROM sqlite_master WHERE type = 'table'
                  AND name IN ('projection_runs', 'note_positions') ORDER BY name
                """))
            XCTAssertEqual(tables, [[.text("note_positions")], [.text("projection_runs")]])
            await upgraded.close()

            let rollbackURL = self.root.appendingPathComponent("v6-rollback.sqlite")
            let beforeFailure = SQLiteDatabase(url: rollbackURL, migrations: Array(SQLiteMigration.current.prefix(5)))
            try await beforeFailure.initialize()
            await beforeFailure.close()
            var migrations = Array(SQLiteMigration.current.prefix(5))
            migrations.append(SQLiteMigration(version: 6, statements: [
                "CREATE TABLE partial_projection_migration (value TEXT)", "INVALID SQL"
            ]))
            let broken = SQLiteDatabase(url: rollbackURL, migrations: migrations)
            do {
                try await broken.initialize()
                XCTFail("Expected v6 migration failure")
            } catch { }
            let preserved = SQLiteDatabase(url: rollbackURL, migrations: Array(SQLiteMigration.current.prefix(5)))
            try await preserved.initialize()
            let preservedVersion = try await preserved.query(SQLiteStatement("PRAGMA user_version"))
            XCTAssertEqual(preservedVersion, [[.integer(5)]])
            let partialTable = try await preserved.query(SQLiteStatement("""
                SELECT name FROM sqlite_master WHERE name = 'partial_projection_migration'
                """))
            XCTAssertTrue(partialTable.isEmpty)
            await preserved.close()
        }
    }

    private func index(_ vectors: [[Float]], in folder: URL, prefix: String) async throws -> [IndexedVector] {
        for (index, _) in vectors.enumerated() {
            try Data("\(prefix) content \(index)".utf8).write(
                to: folder.appendingPathComponent("\(prefix)-\(index).md"))
        }
        _ = try await database.reconcile(folder: folder)
        let rows = try await database.query(SQLiteStatement("""
            SELECT id, relative_path, content_hash FROM notes
            WHERE sync_state = 'indexed'
              AND folder_id = (SELECT id FROM folders WHERE root_path = ?)
            ORDER BY relative_path
            """, [.text(folder.resolvingSymlinksInPath().standardizedFileURL.path)]))
        return try rows.enumerated().map { index, row in
            guard row.count == 3, case let .text(noteID) = row[0],
                  case let .text(path) = row[1], case let .text(sourceHash) = row[2] else {
                throw SQLiteFailure(message: "Test note was not indexed.")
            }
            return IndexedVector(noteID: noteID, path: path, sourceHash: sourceHash, vector: vectors[index])
        }
    }

    private func completeEmbeddings(_ indexed: [IndexedVector], vectors: [[Float]],
                                    space: EmbeddingSpace) async throws {
        let registered = try await database.query(SQLiteStatement(
            "SELECT 1 FROM embedding_spaces WHERE fingerprint = ?", [.text(space.fingerprint)]))
        if registered.isEmpty { try await database.registerEmbeddingSpace(space) }
        for (index, item) in indexed.enumerated() {
            let job = try await database.enqueueEmbedding(noteID: item.noteID,
                                                          spaceFingerprint: space.fingerprint,
                                                          sourceHash: item.sourceHash)
            guard try await database.beginEmbedding(job) else {
                throw SQLiteFailure(message: "Projection fixture embedding did not start.")
            }
            guard try await database.completeEmbedding(job, vector: vectors[index]) else {
                throw SQLiteFailure(message: "Projection fixture embedding did not complete.")
            }
        }
    }
}

private struct IndexedVector {
    let noteID: String
    let path: String
    let sourceHash: String
    let vector: [Float]
}
