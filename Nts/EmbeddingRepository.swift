import CryptoKit
import Foundation

struct EmbeddingSpace: Equatable, Sendable {
    let fingerprint: String
    let configurationJSON: String
    let modelID: String
    let modelRevision: String
    let tokenizerRevision: String
    let dimensions: Int
    let vectorEncoding: String
    let pipelineVersion: String

    init(configurationJSON: String, modelID: String, modelRevision: String,
         tokenizerRevision: String, dimensions: Int, vectorEncoding: String = "float32-le-v1",
         pipelineVersion: String) {
        self.fingerprint = Self.fingerprint(configurationJSON: configurationJSON, modelID: modelID,
                                            modelRevision: modelRevision, tokenizerRevision: tokenizerRevision,
                                            dimensions: dimensions, vectorEncoding: vectorEncoding,
                                            pipelineVersion: pipelineVersion)
        self.configurationJSON = configurationJSON
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.tokenizerRevision = tokenizerRevision
        self.dimensions = dimensions
        self.vectorEncoding = vectorEncoding
        self.pipelineVersion = pipelineVersion
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func fingerprint(configurationJSON: String, modelID: String, modelRevision: String,
                                        tokenizerRevision: String, dimensions: Int, vectorEncoding: String,
                                        pipelineVersion: String) -> String {
        var material = Data()
        for value in [configurationJSON, modelID, modelRevision, tokenizerRevision,
                      String(dimensions), vectorEncoding, pipelineVersion] {
            var length = UInt64(value.utf8.count).littleEndian
            withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
            material.append(contentsOf: value.utf8)
        }
        return hash(material)
    }
}

struct EmbeddingJob: Equatable, Sendable {
    let noteID: String
    let spaceFingerprint: String
    let sourceHash: String
    let token: String
}

struct EmbeddingNote: Equatable, Sendable {
    let noteID: String
    let relativePath: String
    let sourceHash: String
}

struct PendingEmbeddingJob: Equatable, Sendable {
    let job: EmbeddingJob
    let url: URL
}

enum EmbeddingVectorCodec {
    static func encode(_ vector: [Float], dimensions: Int) throws -> Data {
        let (_, overflow) = dimensions.multipliedReportingOverflow(by: MemoryLayout<UInt32>.size)
        guard dimensions > 0, !overflow, vector.count == dimensions,
              vector.allSatisfy(\.isFinite) else {
            throw SQLiteFailure(message: "Embedding vector has an invalid dimension or non-finite value.")
        }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, abs(norm - 1) <= 0.001 else {
            throw SQLiteFailure(message: "Embedding vector must be finite and unit-normalized.")
        }
        var data = Data()
        data.reserveCapacity(dimensions * MemoryLayout<UInt32>.size)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data, dimensions: Int) throws -> [Float] {
        let (expectedLength, overflow) = dimensions.multipliedReportingOverflow(by: MemoryLayout<UInt32>.size)
        guard dimensions > 0, !overflow, data.count == expectedLength else {
            throw SQLiteFailure(message: "Stored embedding has an invalid binary length.")
        }
        let bytes = [UInt8](data)
        var vector: [Float] = []
        vector.reserveCapacity(dimensions)
        for index in stride(from: 0, to: bytes.count, by: MemoryLayout<UInt32>.size) {
            let bits = UInt32(bytes[index])
                | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16
                | UInt32(bytes[index + 3]) << 24
            vector.append(Float(bitPattern: bits))
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw SQLiteFailure(message: "Stored embedding contains a non-finite value.")
        }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, abs(norm - 1) <= 0.001 else {
            throw SQLiteFailure(message: "Stored embedding is not a valid unit-normalized vector.")
        }
        return vector
    }
}

extension SQLiteDatabase {
    func registerEmbeddingSpace(_ space: EmbeddingSpace) throws {
        guard space.fingerprint == EmbeddingSpace.fingerprint(
                  configurationJSON: space.configurationJSON, modelID: space.modelID,
                  modelRevision: space.modelRevision, tokenizerRevision: space.tokenizerRevision,
                  dimensions: space.dimensions, vectorEncoding: space.vectorEncoding,
                  pipelineVersion: space.pipelineVersion),
              space.dimensions > 0, space.vectorEncoding == "float32-le-v1",
              !space.modelID.isEmpty, !space.modelRevision.isEmpty,
              !space.tokenizerRevision.isEmpty, !space.pipelineVersion.isEmpty,
              (try? JSONSerialization.jsonObject(with: Data(space.configurationJSON.utf8),
                                                  options: [.fragmentsAllowed])) != nil else {
            throw SQLiteFailure(message: "Embedding space configuration is invalid.")
        }
        try transaction { transaction in
            try transaction.execute(SQLiteStatement("""
                INSERT INTO embedding_spaces
                    (fingerprint, configuration_json, model_id, model_revision, tokenizer_revision,
                     dimensions, vector_encoding, pipeline_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(fingerprint) DO NOTHING
                """, [.text(space.fingerprint), .text(space.configurationJSON), .text(space.modelID),
                      .text(space.modelRevision), .text(space.tokenizerRevision), .integer(Int64(space.dimensions)),
                      .text(space.vectorEncoding), .text(space.pipelineVersion)]))
            let rows = try transaction.query(SQLiteStatement("""
                SELECT configuration_json, model_id, model_revision, tokenizer_revision,
                       dimensions, vector_encoding, pipeline_version
                FROM embedding_spaces WHERE fingerprint = ?
                """, [.text(space.fingerprint)]))
            let expected: [SQLiteValue] = [
                .text(space.configurationJSON), .text(space.modelID), .text(space.modelRevision),
                .text(space.tokenizerRevision), .integer(Int64(space.dimensions)),
                .text(space.vectorEncoding), .text(space.pipelineVersion)
            ]
            guard rows.first == expected else {
                throw SQLiteFailure(message: "Embedding-space fingerprint conflicts with stored configuration.")
            }
        }
    }

    func enqueueEmbedding(noteID: String, spaceFingerprint: String, sourceHash: String) throws -> EmbeddingJob {
        try transaction { transaction in
            let note = try transaction.query(SQLiteStatement(
                "SELECT sync_state, content_hash FROM notes WHERE id = ?", [.text(noteID)]))
            guard note.first == [.text("indexed"), .text(sourceHash)] else {
                throw SQLiteFailure(message: "Cannot queue an embedding for a note whose indexed source is not current.")
            }
            guard !(try transaction.query(SQLiteStatement(
                "SELECT 1 FROM embedding_spaces WHERE fingerprint = ?", [.text(spaceFingerprint)])).isEmpty) else {
                throw SQLiteFailure(message: "Cannot queue an embedding for an unknown model space.")
            }

            let existing = try transaction.query(SQLiteStatement("""
                SELECT source_hash, job_token, state FROM note_embeddings
                WHERE note_id = ? AND space_id = ?
                """, [.text(noteID), .text(spaceFingerprint)])).first
            if let existing,
               existing[0] == .text(sourceHash),
               let token = existing[1].textValue,
               let state = existing[2].textValue,
               ["queued", "processing", "ready", "error", "skipped-empty"].contains(state) {
                return EmbeddingJob(noteID: noteID, spaceFingerprint: spaceFingerprint,
                                    sourceHash: sourceHash, token: token)
            }

            let token = UUID().uuidString
            try transaction.execute(SQLiteStatement("""
                INSERT INTO note_embeddings
                    (note_id, space_id, source_hash, job_token, state, vector, vector_hash,
                     attempts, error, updated_at)
                VALUES (?, ?, ?, ?, 'queued', NULL, NULL, 0, NULL, ?)
                ON CONFLICT(note_id, space_id) DO UPDATE SET
                    source_hash = excluded.source_hash, job_token = excluded.job_token,
                    state = 'queued', vector = NULL, vector_hash = NULL, attempts = 0,
                    error = NULL, updated_at = excluded.updated_at
                """, [.text(noteID), .text(spaceFingerprint), .text(sourceHash), .text(token),
                      .real(Date().timeIntervalSince1970)]))
            return EmbeddingJob(noteID: noteID, spaceFingerprint: spaceFingerprint,
                                sourceHash: sourceHash, token: token)
        }
    }

    func indexedEmbeddingNotes(folder: URL) throws -> [EmbeddingNote] {
                let canonical = folder.resolvingSymlinksInPath().standardizedFileURL.path
                return try query(SQLiteStatement("""
                    SELECT n.id, n.relative_path, n.content_hash FROM notes n
                    JOIN folders f ON f.id = n.folder_id
                    WHERE f.root_path = ? AND n.sync_state = 'indexed' AND n.content_hash IS NOT NULL
                    ORDER BY n.id
                    """, [.text(canonical)])).compactMap { row in
                        guard row.count == 3, case let .text(noteID) = row[0],
                              case let .text(path) = row[1], case let .text(hash) = row[2] else { return nil }
                        return EmbeddingNote(noteID: noteID, relativePath: path, sourceHash: hash)
                    }
    }

    func enqueueEmbedding(url: URL, spaceFingerprint: String) throws -> EmbeddingJob? {
                let contents = try NoteFileService().read(url)
                let hash = EmbeddingSpace.hash(contents.data)
                let root = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                let rows = try query(SQLiteStatement("""
                    SELECT n.id FROM notes n JOIN folders f ON f.id = n.folder_id
                    WHERE f.root_path = ? AND n.relative_path = ? AND n.content_hash = ? AND n.sync_state = 'indexed'
                    """, [.text(root), .text(url.lastPathComponent), .text(hash)]))
                guard case let .text(noteID) = rows.first?.first else { return nil }
                return try enqueueEmbedding(noteID: noteID, spaceFingerprint: spaceFingerprint, sourceHash: hash)
    }

    func pendingEmbeddings(folder: URL, spaceFingerprint: String) throws -> [PendingEmbeddingJob] {
                let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
                return try query(SQLiteStatement("""
                    SELECT ne.note_id, n.relative_path, ne.source_hash, ne.job_token
                    FROM note_embeddings ne
                    JOIN notes n ON n.id = ne.note_id
                    JOIN folders f ON f.id = n.folder_id
                    WHERE f.root_path = ? AND ne.space_id = ? AND ne.state = 'queued'
                      AND n.sync_state = 'indexed' AND n.content_hash = ne.source_hash
                    ORDER BY ne.note_id
                    """, [.text(canonical.path), .text(spaceFingerprint)])).compactMap { row in
                        guard row.count == 4, case let .text(noteID) = row[0],
                              case let .text(path) = row[1], case let .text(hash) = row[2],
                              case let .text(token) = row[3] else { return nil }
                        return PendingEmbeddingJob(
                            job: EmbeddingJob(noteID: noteID, spaceFingerprint: spaceFingerprint,
                                              sourceHash: hash, token: token),
                            url: canonical.appendingPathComponent(path))
                    }
    }

    func embeddingInput(_ job: EmbeddingJob, url: URL) throws -> String? {
                let contents = try NoteFileService().read(url)
                guard EmbeddingSpace.hash(contents.data) == job.sourceHash else { return nil }
                let rows = try query(SQLiteStatement("""
                    SELECT 1 FROM note_embeddings ne
                    JOIN notes n ON n.id = ne.note_id
                    JOIN folders f ON f.id = n.folder_id
                    WHERE ne.note_id = ? AND ne.space_id = ? AND ne.source_hash = ? AND ne.job_token = ?
                      AND ne.state = 'processing' AND n.sync_state = 'indexed'
                      AND n.content_hash = ne.source_hash AND f.root_path = ?
                    """, [.text(job.noteID), .text(job.spaceFingerprint), .text(job.sourceHash),
                          .text(job.token), .text(url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path)]))
                return rows.isEmpty ? nil : contents.text
    }

    @discardableResult
    func retryFailedEmbedding(_ job: EmbeddingJob, maximumAttempts: Int = 2) throws -> EmbeddingJob? {
                try transaction { transaction in
                    let token = UUID().uuidString
                    let changed = try transaction.execute(SQLiteStatement("""
                        UPDATE note_embeddings SET state = 'queued', job_token = ?, error = NULL, updated_at = ?
                        WHERE note_id = ? AND space_id = ? AND source_hash = ? AND job_token = ?
                          AND state = 'error' AND attempts < ?
                          AND EXISTS (
                              SELECT 1 FROM notes n WHERE n.id = note_embeddings.note_id
                                AND n.sync_state = 'indexed' AND n.content_hash = note_embeddings.source_hash
                          )
                        """, [.text(token), .real(Date().timeIntervalSince1970), .text(job.noteID),
                              .text(job.spaceFingerprint), .text(job.sourceHash), .text(job.token),
                              .integer(Int64(maximumAttempts))]))
                    return changed == 1
                        ? EmbeddingJob(noteID: job.noteID, spaceFingerprint: job.spaceFingerprint,
                                       sourceHash: job.sourceHash, token: token)
                        : nil
                }
    }

    func retryFailedEmbeddings(folder: URL, spaceFingerprint: String) throws -> Int {
                let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
                return try transaction { transaction in
                    let errors = try transaction.query(SQLiteStatement("""
                        SELECT ne.note_id, ne.source_hash, ne.job_token FROM note_embeddings ne
                        JOIN notes n ON n.id = ne.note_id JOIN folders f ON f.id = n.folder_id
                        WHERE f.root_path = ? AND ne.space_id = ? AND ne.state = 'error'
                          AND n.sync_state = 'indexed' AND n.content_hash = ne.source_hash
                        """, [.text(canonical.path), .text(spaceFingerprint)]))
                    var retried = 0
                    for row in errors {
                        guard case let .text(noteID) = row[0], case let .text(hash) = row[1],
                              case let .text(token) = row[2] else { continue }
                        retried += try transaction.execute(SQLiteStatement("""
                            UPDATE note_embeddings SET state = 'queued', job_token = ?,
                                attempts = 0, error = NULL, updated_at = ?
                            WHERE note_id = ? AND space_id = ? AND source_hash = ? AND job_token = ? AND state = 'error'
                            """, [.text(UUID().uuidString), .real(Date().timeIntervalSince1970), .text(noteID),
                                  .text(spaceFingerprint), .text(hash), .text(token)]))
                    }
                    return retried
                }
    }

    @discardableResult
    func beginEmbedding(_ job: EmbeddingJob) throws -> Bool {
        try transaction { transaction in
            try transaction.execute(SQLiteStatement("""
                UPDATE note_embeddings SET state = 'processing', attempts = attempts + 1,
                    error = NULL, updated_at = ?
                WHERE note_id = ? AND space_id = ? AND source_hash = ? AND job_token = ?
                  AND state = 'queued'
                  AND EXISTS (
                      SELECT 1 FROM notes n WHERE n.id = note_embeddings.note_id
                        AND n.sync_state = 'indexed' AND n.content_hash = note_embeddings.source_hash
                  )
                """, [.real(Date().timeIntervalSince1970), .text(job.noteID), .text(job.spaceFingerprint),
                      .text(job.sourceHash), .text(job.token)])) == 1
        }
    }

    @discardableResult
    func completeEmbedding(_ job: EmbeddingJob, vector: [Float], url: URL? = nil) throws -> Bool {
        try transaction { transaction in
            if let url {
                let contents = try NoteFileService().read(url)
                guard EmbeddingSpace.hash(contents.data) == job.sourceHash else { return false }
            }
            guard let dimensionValue = try transaction.query(SQLiteStatement(
                "SELECT dimensions FROM embedding_spaces WHERE fingerprint = ?",
                [.text(job.spaceFingerprint)])).first?.first,
                  case let .integer(dimensions) = dimensionValue,
                  let dimension = Int(exactly: dimensions) else {
                throw SQLiteFailure(message: "The embedding model space no longer exists.")
            }
            let data = try EmbeddingVectorCodec.encode(vector, dimensions: dimension)
            let vectorHash = EmbeddingSpace.hash(data)
            return try transaction.execute(SQLiteStatement("""
                UPDATE note_embeddings SET state = 'ready', vector = ?, vector_hash = ?,
                    error = NULL, updated_at = ?
                WHERE note_id = ? AND space_id = ? AND source_hash = ? AND job_token = ?
                  AND state = 'processing'
                  AND EXISTS (
                      SELECT 1 FROM notes n WHERE n.id = note_embeddings.note_id
                        AND n.sync_state = 'indexed' AND n.content_hash = note_embeddings.source_hash
                  )
                """, [.blob(data), .text(vectorHash), .real(Date().timeIntervalSince1970),
                      .text(job.noteID), .text(job.spaceFingerprint), .text(job.sourceHash), .text(job.token)])) == 1
        }
    }

    @discardableResult
    func failEmbedding(_ job: EmbeddingJob, message: String) throws -> Bool {
        try transaction { transaction in
            try transaction.execute(SQLiteStatement("""
                UPDATE note_embeddings SET state = 'error', vector = NULL, vector_hash = NULL,
                    error = ?, updated_at = ?
                WHERE note_id = ? AND space_id = ? AND source_hash = ? AND job_token = ?
                  AND state = 'processing'
                  AND EXISTS (
                      SELECT 1 FROM notes n WHERE n.id = note_embeddings.note_id
                        AND n.sync_state = 'indexed' AND n.content_hash = note_embeddings.source_hash
                  )
                """, [.text(message), .real(Date().timeIntervalSince1970), .text(job.noteID),
                      .text(job.spaceFingerprint), .text(job.sourceHash), .text(job.token)])) == 1
        }
    }

    @discardableResult
    func skipEmptyEmbedding(_ job: EmbeddingJob) throws -> Bool {
        try transaction { transaction in
            try transaction.execute(SQLiteStatement("""
                UPDATE note_embeddings SET state = 'skipped-empty', vector = NULL, vector_hash = NULL,
                    error = NULL, updated_at = ?
                WHERE note_id = ? AND space_id = ? AND source_hash = ? AND job_token = ?
                  AND state IN ('queued', 'processing')
                  AND EXISTS (
                      SELECT 1 FROM notes n WHERE n.id = note_embeddings.note_id
                        AND n.sync_state = 'indexed' AND n.content_hash = note_embeddings.source_hash
                  )
                """, [.real(Date().timeIntervalSince1970), .text(job.noteID), .text(job.spaceFingerprint),
                      .text(job.sourceHash), .text(job.token)])) == 1
        }
    }

    func recoverInterruptedEmbeddings() throws -> Int {
        try transaction { transaction in
            let interrupted = try transaction.query(SQLiteStatement(
                "SELECT note_id, space_id, source_hash, job_token FROM note_embeddings WHERE state = 'processing'"))
            var recovered = 0
            for row in interrupted {
                guard row.count == 4,
                      let noteID = row[0].textValue,
                      let spaceID = row[1].textValue,
                      let sourceHash = row[2].textValue,
                      let oldToken = row[3].textValue else {
                    throw SQLiteFailure(message: "An interrupted embedding job record is malformed.")
                }
                recovered += try transaction.execute(SQLiteStatement("""
                    UPDATE note_embeddings SET
                        state = CASE WHEN EXISTS (
                            SELECT 1 FROM notes n WHERE n.id = note_embeddings.note_id
                              AND n.sync_state = 'indexed' AND n.content_hash = note_embeddings.source_hash
                        ) AND attempts < 2 THEN 'queued' ELSE 'error' END,
                        job_token = ?, vector = NULL, vector_hash = NULL,
                        error = CASE WHEN EXISTS (
                            SELECT 1 FROM notes n WHERE n.id = note_embeddings.note_id
                              AND n.sync_state = 'indexed' AND n.content_hash = note_embeddings.source_hash
                        ) AND attempts < 2 THEN NULL ELSE 'Embedding job interrupted or its source changed.' END,
                        updated_at = ?
                    WHERE note_id = ? AND space_id = ? AND source_hash = ? AND job_token = ?
                      AND state = 'processing'
                    """, [.text(UUID().uuidString), .real(Date().timeIntervalSince1970),
                          .text(noteID), .text(spaceID), .text(sourceHash), .text(oldToken)]))
            }
            return recovered
        }
    }

    func currentEmbedding(noteID: String, spaceFingerprint: String) throws -> [Float]? {
        let rows = try query(SQLiteStatement("""
            SELECT ne.vector, ne.vector_hash, es.dimensions
            FROM note_embeddings ne
            JOIN embedding_spaces es ON es.fingerprint = ne.space_id
            JOIN notes n ON n.id = ne.note_id
            WHERE ne.note_id = ? AND ne.space_id = ? AND ne.state = 'ready'
              AND n.sync_state = 'indexed' AND n.content_hash = ne.source_hash
            """, [.text(noteID), .text(spaceFingerprint)]))
        guard let row = rows.first else { return nil }
        guard row.count == 3,
              case let .blob(data) = row[0],
              case let .text(expectedHash) = row[1],
              case let .integer(rawDimensions) = row[2],
              let dimensions = Int(exactly: rawDimensions),
              EmbeddingSpace.hash(data) == expectedHash else {
            throw SQLiteFailure(message: "Stored embedding data failed its integrity check.")
        }
        return try EmbeddingVectorCodec.decode(data, dimensions: dimensions)
    }
}

private extension SQLiteValue {
    var textValue: String? {
        guard case let .text(value) = self else { return nil }
        return value
    }
}
