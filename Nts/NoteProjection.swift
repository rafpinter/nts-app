import Accelerate
import CryptoKit
import Foundation

struct ProjectionInput: Equatable, Sendable {
    let noteID: String
    let sourceHash: String
    let vectorHash: String
    let vector: [Float]
}

struct ProjectionInputSnapshot: Equatable, Sendable {
    let folderPath: String
    let spaceFingerprint: String
    let dimensions: Int
    let inputs: [ProjectionInput]
    let inputFingerprint: String

    init(folder: URL, spaceFingerprint: String, dimensions: Int,
         inputs: [ProjectionInput], reducerVersion: String = NoteProjectionReducer.version,
         parametersJSON: String = NoteProjectionReducer.parametersJSON) throws {
        guard dimensions > 0, !spaceFingerprint.isEmpty,
              inputs.allSatisfy({ $0.vector.count == dimensions }),
              Set(inputs.map(\.noteID)).count == inputs.count else {
            throw SQLiteFailure(message: "Projection input snapshot has inconsistent dimensions or duplicate notes.")
        }
        for input in inputs {
            let encoded = try EmbeddingVectorCodec.encode(input.vector, dimensions: dimensions)
            guard EmbeddingSpace.hash(encoded) == input.vectorHash else {
                throw SQLiteFailure(message: "Projection input vector hash does not match its values.")
            }
        }
        folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        self.spaceFingerprint = spaceFingerprint
        self.dimensions = dimensions
        self.inputs = inputs.sorted { $0.noteID < $1.noteID }
        inputFingerprint = Self.fingerprint(folderPath: folderPath, spaceFingerprint: spaceFingerprint,
                                            inputs: self.inputs, reducerVersion: reducerVersion,
                                            parametersJSON: parametersJSON)
    }

    static func fingerprint(folderPath: String, spaceFingerprint: String, inputs: [ProjectionInput],
                            reducerVersion: String, parametersJSON: String) -> String {
        var material = Data()
        for value in [folderPath, spaceFingerprint, reducerVersion, parametersJSON] {
            append(value, to: &material)
        }
        for input in inputs.sorted(by: { $0.noteID < $1.noteID }) {
            append(input.noteID, to: &material)
            append(input.sourceHash, to: &material)
            append(input.vectorHash, to: &material)
        }
        return EmbeddingSpace.hash(material)
    }

    private static func append(_ value: String, to data: inout Data) {
        var length = UInt64(value.utf8.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: value.utf8)
    }
}

struct NoteProjectionPosition: Equatable, Sendable {
    let noteID: String
    let sourceHash: String
    let vectorHash: String
    let x: Double
    let y: Double
}

struct NoteProjectionResult: Equatable, Sendable {
    let mean: [Double]
    /// Row-major component vectors: all coefficients for x, then all for y.
    let basis: [Double]
    let positions: [NoteProjectionPosition]
}

struct StoredNoteProjection: Equatable, Sendable {
    let runID: String
    let folderPath: String
    let spaceFingerprint: String
    let inputFingerprint: String
    let reducerVersion: String
    let parametersJSON: String
    let dimensions: Int
    let mean: [Double]
    let basis: [Double]
    let createdAt: Double
    let positions: [NoteProjectionPosition]
}

enum ProjectionFloat64Codec {
    static let encoding = "float64-le-v1"

    static func encode(_ values: [Double]) throws -> Data {
        guard values.allSatisfy(\.isFinite) else {
            throw SQLiteFailure(message: "Projection data contains a non-finite value.")
        }
        var data = Data()
        data.reserveCapacity(values.count * MemoryLayout<UInt64>.size)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data, count: Int) throws -> [Double] {
        let (expectedLength, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<UInt64>.size)
        guard count >= 0, !overflow, data.count == expectedLength else {
            throw SQLiteFailure(message: "Stored projection data has an invalid binary length.")
        }
        let bytes = [UInt8](data)
        var result: [Double] = []
        result.reserveCapacity(count)
        for index in stride(from: 0, to: bytes.count, by: MemoryLayout<UInt64>.size) {
            let bits = UInt64(bytes[index])
                | UInt64(bytes[index + 1]) << 8
                | UInt64(bytes[index + 2]) << 16
                | UInt64(bytes[index + 3]) << 24
                | UInt64(bytes[index + 4]) << 32
                | UInt64(bytes[index + 5]) << 40
                | UInt64(bytes[index + 6]) << 48
                | UInt64(bytes[index + 7]) << 56
            let value = Double(bitPattern: bits)
            guard value.isFinite else {
                throw SQLiteFailure(message: "Stored projection data contains a non-finite value.")
            }
            result.append(value)
        }
        return result
    }
}

enum NoteProjectionReducer {
    static let version = "centered-pca-accelerate-v2"
    static let legacyVersion = "centered-pca-accelerate-v1"
    static let legacyParametersJSON =
        #"{"covariance":"population","componentSign":"largest-absolute-coefficient-positive","rankTolerance":"1e-10-relative","version":1}"#
    static let parametersJSON =
        #"{"covariance":"population","componentSign":"largest-absolute-coefficient-positive","layoutAlignment":"previous-layout-overlap-orthogonal-v1","rankTolerance":"1e-10-relative","version":2}"#

    static func estimatedWorkingMemoryBytes(noteCount: Int, dimensions: Int) -> Int? {
        guard noteCount >= 0, dimensions > 0 else { return nil }
        let (matrixElements, matrixOverflow) = noteCount.multipliedReportingOverflow(by: dimensions)
        let (covarianceElements, covarianceOverflow) = dimensions.multipliedReportingOverflow(by: dimensions)
        let (elementCount, sumOverflow) = matrixElements.addingReportingOverflow(covarianceElements)
        let (bytes, byteOverflow) = elementCount.multipliedReportingOverflow(by: MemoryLayout<Double>.size)
        return matrixOverflow || covarianceOverflow || sumOverflow || byteOverflow ? nil : bytes
    }

    static func align(_ result: NoteProjectionResult,
                      to referencePositions: [NoteProjectionPosition]) -> NoteProjectionResult {
        let referenceByID = Dictionary(referencePositions.map { ($0.noteID, $0) },
                                       uniquingKeysWith: { first, _ in first })
        let shared = result.positions.compactMap { position -> (NoteProjectionPosition, NoteProjectionPosition)? in
            guard let reference = referenceByID[position.noteID] else { return nil }
            return (position, reference)
        }
        guard shared.count >= 2 else { return result }

        let count = Double(shared.count)
        let currentMeanX = shared.reduce(0.0) { $0 + $1.0.x } / count
        let currentMeanY = shared.reduce(0.0) { $0 + $1.0.y } / count
        let referenceMeanX = shared.reduce(0.0) { $0 + $1.1.x } / count
        let referenceMeanY = shared.reduce(0.0) { $0 + $1.1.y } / count
        var currentEnergy = 0.0
        var referenceEnergy = 0.0
        var rotationCosine = 0.0
        var rotationSine = 0.0
        var reflectionCosine = 0.0
        var reflectionSine = 0.0
        for (current, reference) in shared {
            let x = current.x - currentMeanX
            let y = current.y - currentMeanY
            let targetX = reference.x - referenceMeanX
            let targetY = reference.y - referenceMeanY
            currentEnergy += x * x + y * y
            referenceEnergy += targetX * targetX + targetY * targetY
            rotationCosine += x * targetX + y * targetY
            rotationSine += x * targetY - y * targetX
            reflectionCosine += x * targetX - y * targetY
            reflectionSine += y * targetX + x * targetY
        }
        let rotationStrength = hypot(rotationCosine, rotationSine)
        let reflectionStrength = hypot(reflectionCosine, reflectionSine)
        let maximumStrength = max(rotationStrength, reflectionStrength)
        guard currentEnergy > 0, referenceEnergy > 0,
              maximumStrength > sqrt(currentEnergy * referenceEnergy) * 1e-10 else {
            return result
        }

        let reflected = reflectionStrength > rotationStrength
        let cosine = reflected ? reflectionCosine / reflectionStrength : rotationCosine / rotationStrength
        let sine = reflected ? reflectionSine / reflectionStrength : rotationSine / rotationStrength
        let positions = result.positions.map { position -> NoteProjectionPosition in
            let x = reflected ? cosine * position.x + sine * position.y
                              : cosine * position.x - sine * position.y
            let y = reflected ? sine * position.x - cosine * position.y
                              : sine * position.x + cosine * position.y
            return NoteProjectionPosition(noteID: position.noteID, sourceHash: position.sourceHash,
                                          vectorHash: position.vectorHash, x: x, y: y)
        }
        let dimensions = result.mean.count
        var basis = Array(repeating: 0.0, count: dimensions * 2)
        for index in 0..<dimensions {
            let x = result.basis[index]
            let y = result.basis[dimensions + index]
            basis[index] = reflected ? cosine * x + sine * y : cosine * x - sine * y
            basis[dimensions + index] = reflected ? sine * x - cosine * y : sine * x + cosine * y
        }
        return NoteProjectionResult(mean: result.mean, basis: basis, positions: positions)
    }

    static func project(_ snapshot: ProjectionInputSnapshot) async throws -> NoteProjectionResult {
        let count = snapshot.inputs.count
        let dimensions = snapshot.dimensions
        guard dimensions > 0, count <= Int32.max, dimensions <= Int32.max else {
            throw SQLiteFailure(message: "Projection input exceeds the supported numeric limits.")
        }
        try Task.checkCancellation()

        var mean = Array(repeating: 0.0, count: dimensions)
        for (noteIndex, input) in snapshot.inputs.enumerated() {
            if noteIndex.isMultiple(of: 64) { try Task.checkCancellation() }
            guard input.vector.count == dimensions, input.vector.allSatisfy(\.isFinite) else {
                throw SQLiteFailure(message: "Projection input contains an invalid embedding vector.")
            }
            for index in 0..<dimensions { mean[index] += Double(input.vector[index]) }
        }
        if count > 0 {
            for index in 0..<dimensions { mean[index] /= Double(count) }
        }

        let (matrixCount, matrixOverflow) = count.multipliedReportingOverflow(by: dimensions)
        let (covarianceCount, covarianceOverflow) = dimensions.multipliedReportingOverflow(by: dimensions)
        guard !matrixOverflow, !covarianceOverflow else {
            throw SQLiteFailure(message: "Projection input is too large to process safely.")
        }
        var centered = Array(repeating: 0.0, count: matrixCount)
        for noteIndex in snapshot.inputs.indices {
            if noteIndex.isMultiple(of: 64) { try Task.checkCancellation() }
            let offset = noteIndex * dimensions
            for component in 0..<dimensions {
                centered[offset + component] = Double(snapshot.inputs[noteIndex].vector[component]) - mean[component]
            }
        }

        var basis = Array(repeating: 0.0, count: dimensions * 2)
        if count >= 2, dimensions >= 1 {
            var covariance = Array(repeating: 0.0, count: covarianceCount)
            centered.withUnsafeBufferPointer { matrix in
                covariance.withUnsafeMutableBufferPointer { output in
                    cblas_dgemm(CblasRowMajor, CblasTrans, CblasNoTrans,
                                Int32(dimensions), Int32(dimensions), Int32(count),
                                1.0 / Double(count), matrix.baseAddress, Int32(dimensions),
                                matrix.baseAddress, Int32(dimensions), 0,
                                output.baseAddress, Int32(dimensions))
                }
            }

            var jobz: Int8 = 86
            var uplo: Int8 = 85
            var matrixDimension = __CLPK_integer(dimensions)
            var leadingDimension = matrixDimension
            var eigenvalues = Array(repeating: 0.0, count: dimensions)
            var workspaceQuery = 0.0
            var workspaceCount: __CLPK_integer = -1
            var info: __CLPK_integer = 0
            info = dsyev_(&jobz, &uplo, &matrixDimension, &covariance, &leadingDimension,
                          &eigenvalues, &workspaceQuery, &workspaceCount, &info)
            guard info == 0, workspaceQuery.isFinite, workspaceQuery >= 1,
                  workspaceQuery <= Double(Int32.max) else {
                throw SQLiteFailure(message: "Accelerate could not size the PCA eigensolver workspace.")
            }
            workspaceCount = __CLPK_integer(workspaceQuery.rounded(.up))
            var workspace = Array(repeating: 0.0, count: Int(workspaceCount))
            info = dsyev_(&jobz, &uplo, &matrixDimension, &covariance, &leadingDimension,
                          &eigenvalues, &workspace, &workspaceCount, &info)
            guard info == 0, eigenvalues.allSatisfy(\.isFinite) else {
                throw SQLiteFailure(message: "Accelerate failed to compute PCA components.")
            }
            try Task.checkCancellation()

            let maximumEigenvalue = max(0, eigenvalues[dimensions - 1])
            let rankThreshold = maximumEigenvalue * 1e-10
            for component in 0..<min(2, dimensions) {
                let eigenvalueIndex = dimensions - 1 - component
                guard eigenvalues[eigenvalueIndex] > rankThreshold,
                      maximumEigenvalue > 0 else { continue }
                var signPivot = 0
                for index in 1..<dimensions
                    where abs(covariance[index + eigenvalueIndex * dimensions])
                        > abs(covariance[signPivot + eigenvalueIndex * dimensions]) {
                    signPivot = index
                }
                let sign = covariance[signPivot + eigenvalueIndex * dimensions] < 0 ? -1.0 : 1.0
                let componentOffset = component * dimensions
                for index in 0..<dimensions {
                    basis[componentOffset + index] =
                        covariance[index + eigenvalueIndex * dimensions] * sign
                }
            }
        }

        var positions: [NoteProjectionPosition] = []
        positions.reserveCapacity(count)
        for (noteIndex, input) in snapshot.inputs.enumerated() {
            if noteIndex.isMultiple(of: 64) { try Task.checkCancellation() }
            var coordinates = [0.0, 0.0]
            for component in 0..<2 {
                let basisOffset = component * dimensions
                for index in 0..<dimensions {
                    coordinates[component] +=
                        (Double(input.vector[index]) - mean[index]) * basis[basisOffset + index]
                }
            }
            guard coordinates.allSatisfy(\.isFinite) else {
                throw SQLiteFailure(message: "PCA produced non-finite note coordinates.")
            }
            positions.append(NoteProjectionPosition(noteID: input.noteID, sourceHash: input.sourceHash,
                                                     vectorHash: input.vectorHash,
                                                     x: coordinates[0], y: coordinates[1]))
        }
        return NoteProjectionResult(mean: mean, basis: basis, positions: positions)
    }
}

extension SQLiteDatabase {
    func latestProjection(folder: URL, spaceFingerprint: String) throws -> StoredNoteProjection? {
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return try transaction { transaction in
            let runRows = try transaction.query(SQLiteStatement("""
                SELECT pr.run_id, pr.input_fingerprint, pr.reducer_version, pr.parameters_json,
                       pr.dimensions, pr.numeric_encoding, pr.note_count, pr.mean, pr.basis, pr.created_at
                FROM projection_runs pr
                JOIN folders f ON f.id = pr.folder_id
                WHERE f.root_path = ? AND pr.space_id = ?
                ORDER BY pr.created_at DESC, pr.rowid DESC
                LIMIT 1
                """, [.text(folderPath), .text(spaceFingerprint)]))
            guard let row = runRows.first else { return nil }
            guard row.count == 10, case let .text(runID) = row[0],
                  case let .text(inputFingerprint) = row[1],
                  case let .text(reducerVersion) = row[2],
                  case let .text(parametersJSON) = row[3],
                  case let .integer(rawDimensions) = row[4],
                  let dimensions = Int(exactly: rawDimensions), dimensions > 0,
                  row[5] == .text(ProjectionFloat64Codec.encoding),
                  case let .integer(rawNoteCount) = row[6],
                  let noteCount = Int(exactly: rawNoteCount), noteCount >= 0,
                  case let .blob(meanData) = row[7], case let .blob(basisData) = row[8],
                  case let .real(createdAt) = row[9],
                  (reducerVersion == NoteProjectionReducer.version
                    && parametersJSON == NoteProjectionReducer.parametersJSON
                    || reducerVersion == NoteProjectionReducer.legacyVersion
                    && parametersJSON == NoteProjectionReducer.legacyParametersJSON) else {
                throw SQLiteFailure(message: "Stored projection metadata is incompatible or malformed.")
            }
            let mean = try ProjectionFloat64Codec.decode(meanData, count: dimensions)
            let basis = try ProjectionFloat64Codec.decode(basisData, count: dimensions * 2)
            let positionRows = try transaction.query(SQLiteStatement("""
                SELECT p.note_id, p.source_hash, p.vector_hash, p.x, p.y
                FROM note_positions p
                JOIN projection_runs pr ON pr.run_id = p.run_id
                JOIN notes n ON n.id = p.note_id AND n.folder_id = pr.folder_id
                JOIN note_embeddings ne ON ne.note_id = p.note_id AND ne.space_id = pr.space_id
                WHERE p.run_id = ? AND n.sync_state = 'indexed'
                  AND n.content_hash = p.source_hash
                  AND ne.state = 'ready' AND ne.source_hash = p.source_hash
                  AND ne.vector_hash = p.vector_hash
                ORDER BY p.note_id
                """, [.text(runID)]))
            let positions = try positionRows.map { positionRow -> NoteProjectionPosition in
                guard positionRow.count == 5, case let .text(noteID) = positionRow[0],
                      case let .text(sourceHash) = positionRow[1],
                      case let .text(vectorHash) = positionRow[2],
                      case let .real(x) = positionRow[3], case let .real(y) = positionRow[4],
                      x.isFinite, y.isFinite else {
                    throw SQLiteFailure(message: "Stored note position is stale or malformed.")
                }
                return NoteProjectionPosition(noteID: noteID, sourceHash: sourceHash,
                                              vectorHash: vectorHash, x: x, y: y)
            }
            guard positions.count <= noteCount else {
                throw SQLiteFailure(message: "Stored projection contains more positions than its input notes.")
            }
            return StoredNoteProjection(runID: runID, folderPath: folderPath,
                                        spaceFingerprint: spaceFingerprint,
                                        inputFingerprint: inputFingerprint,
                                        reducerVersion: reducerVersion, parametersJSON: parametersJSON,
                                        dimensions: dimensions, mean: mean, basis: basis,
                                        createdAt: createdAt, positions: positions)
        }
    }

    func currentProjectionInputs(folder: URL, spaceFingerprint: String) throws -> ProjectionInputSnapshot {
        let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let dimensions = try projectionDimensions(spaceFingerprint: spaceFingerprint)
        let rows = try projectionInputRows(folderPath: folderPath, spaceFingerprint: spaceFingerprint)
        let inputs = try Self.decodeProjectionInputs(rows, dimensions: dimensions)
        return try ProjectionInputSnapshot(folder: folder, spaceFingerprint: spaceFingerprint,
                                           dimensions: dimensions, inputs: inputs)
    }

    func persistProjection(snapshot: ProjectionInputSnapshot,
                          result: NoteProjectionResult) throws -> StoredNoteProjection {
        try Self.validateProjectionResult(snapshot: snapshot, result: result)
        let mean = try ProjectionFloat64Codec.encode(result.mean)
        let basis = try ProjectionFloat64Codec.encode(result.basis)
        let timestamp = Date().timeIntervalSince1970
        let proposedRunID = UUID().uuidString

        return try transaction { transaction in
            let folderRows = try transaction.query(SQLiteStatement(
                "SELECT id FROM folders WHERE root_path = ?", [.text(snapshot.folderPath)]))
            guard case let .text(folderID) = folderRows.first?.first else {
                throw SQLiteFailure(message: "Cannot persist a projection for an unindexed folder.")
            }
            let spaceRows = try transaction.query(SQLiteStatement(
                "SELECT dimensions FROM embedding_spaces WHERE fingerprint = ?",
                [.text(snapshot.spaceFingerprint)]))
            guard spaceRows.first?.first == .integer(Int64(snapshot.dimensions)) else {
                throw SQLiteFailure(message: "Projection model space changed before publication.")
            }

            let currentRows = try Self.projectionInputRows(
                transaction: transaction, folderPath: snapshot.folderPath,
                spaceFingerprint: snapshot.spaceFingerprint)
            let currentInputs = try Self.decodeProjectionInputs(currentRows, dimensions: snapshot.dimensions)
            let currentFingerprint = ProjectionInputSnapshot.fingerprint(
                folderPath: snapshot.folderPath, spaceFingerprint: snapshot.spaceFingerprint,
                inputs: currentInputs, reducerVersion: NoteProjectionReducer.version,
                parametersJSON: NoteProjectionReducer.parametersJSON)
            guard currentFingerprint == snapshot.inputFingerprint else {
                throw SQLiteFailure(message: "Projection inputs changed before the layout could be published.")
            }

            let inserted = try transaction.execute(SQLiteStatement("""
                INSERT INTO projection_runs
                    (run_id, folder_id, space_id, input_fingerprint, reducer_version, parameters_json,
                     dimensions, numeric_encoding, note_count, mean, basis, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(folder_id, space_id, input_fingerprint) DO NOTHING
                """, [.text(proposedRunID), .text(folderID), .text(snapshot.spaceFingerprint),
                      .text(snapshot.inputFingerprint), .text(NoteProjectionReducer.version),
                      .text(NoteProjectionReducer.parametersJSON), .integer(Int64(snapshot.dimensions)),
                      .text(ProjectionFloat64Codec.encoding), .integer(Int64(snapshot.inputs.count)),
                      .blob(mean), .blob(basis), .real(timestamp)]))
            let runRows = try transaction.query(SQLiteStatement("""
                SELECT run_id FROM projection_runs
                WHERE folder_id = ? AND space_id = ? AND input_fingerprint = ?
                """, [.text(folderID), .text(snapshot.spaceFingerprint), .text(snapshot.inputFingerprint)]))
            guard case let .text(runID) = runRows.first?.first else {
                throw SQLiteFailure(message: "Projection publication did not produce a stored run.")
            }
            if inserted == 1 {
                for position in result.positions {
                    try transaction.execute(SQLiteStatement("""
                        INSERT INTO note_positions (run_id, note_id, source_hash, vector_hash, x, y)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, [.text(runID), .text(position.noteID), .text(position.sourceHash),
                              .text(position.vectorHash), .real(position.x), .real(position.y)]))
                }
            }
            guard let stored = try Self.readProjection(
                snapshot: snapshot, transaction: transaction) else {
                throw SQLiteFailure(message: "Stored projection failed its current-source validation.")
            }
            return stored
        }
    }

    func currentProjection(folder: URL, spaceFingerprint: String) throws -> StoredNoteProjection? {
        let snapshot = try currentProjectionInputs(folder: folder, spaceFingerprint: spaceFingerprint)
        return try transaction { transaction in
            try Self.readProjection(snapshot: snapshot, transaction: transaction)
        }
    }

    private func projectionDimensions(spaceFingerprint: String) throws -> Int {
        let rows = try query(SQLiteStatement(
            "SELECT dimensions FROM embedding_spaces WHERE fingerprint = ?", [.text(spaceFingerprint)]))
        guard case let .integer(rawDimensions) = rows.first?.first,
              let dimensions = Int(exactly: rawDimensions), dimensions > 0 else {
            throw SQLiteFailure(message: "Cannot project an unknown or invalid embedding space.")
        }
        return dimensions
    }

    private func projectionInputRows(folderPath: String, spaceFingerprint: String) throws -> [[SQLiteValue]] {
        try query(SQLiteStatement("""
            SELECT n.id, ne.source_hash, ne.vector, ne.vector_hash
            FROM note_embeddings ne
            JOIN notes n ON n.id = ne.note_id
            JOIN folders f ON f.id = n.folder_id
            WHERE f.root_path = ? AND ne.space_id = ? AND ne.state = 'ready'
              AND n.sync_state = 'indexed' AND n.content_hash = ne.source_hash
            ORDER BY n.id
            """, [.text(folderPath), .text(spaceFingerprint)]))
    }

    private static func projectionInputRows(
        transaction: SQLiteTransaction, folderPath: String, spaceFingerprint: String
    ) throws -> [[SQLiteValue]] {
        try transaction.query(SQLiteStatement("""
            SELECT n.id, ne.source_hash, ne.vector, ne.vector_hash
            FROM note_embeddings ne
            JOIN notes n ON n.id = ne.note_id
            JOIN folders f ON f.id = n.folder_id
            WHERE f.root_path = ? AND ne.space_id = ? AND ne.state = 'ready'
              AND n.sync_state = 'indexed' AND n.content_hash = ne.source_hash
            ORDER BY n.id
            """, [.text(folderPath), .text(spaceFingerprint)]))
    }

    private static func decodeProjectionInputs(
        _ rows: [[SQLiteValue]], dimensions: Int
    ) throws -> [ProjectionInput] {
        try rows.map { row in
            guard row.count == 4, case let .text(noteID) = row[0],
                  case let .text(sourceHash) = row[1], case let .blob(data) = row[2],
                  case let .text(vectorHash) = row[3],
                  EmbeddingSpace.hash(data) == vectorHash else {
                throw SQLiteFailure(message: "A current embedding failed projection integrity checks.")
            }
            let vector = try EmbeddingVectorCodec.decode(data, dimensions: dimensions)
            return ProjectionInput(noteID: noteID, sourceHash: sourceHash,
                                   vectorHash: vectorHash, vector: vector)
        }
    }

    private static func validateProjectionResult(
        snapshot: ProjectionInputSnapshot, result: NoteProjectionResult
    ) throws {
        let dimensions = snapshot.dimensions
        guard result.mean.count == dimensions, result.basis.count == dimensions * 2,
              result.mean.allSatisfy(\.isFinite), result.basis.allSatisfy(\.isFinite),
              result.positions.count == snapshot.inputs.count else {
            throw SQLiteFailure(message: "PCA result does not match its input snapshot.")
        }
        let expected = Dictionary(uniqueKeysWithValues: snapshot.inputs.map {
            ($0.noteID, ($0.sourceHash, $0.vectorHash))
        })
        var seen = Set<String>()
        for position in result.positions {
            guard position.x.isFinite, position.y.isFinite,
                  let source = expected[position.noteID],
                  source.0 == position.sourceHash, source.1 == position.vectorHash,
                  seen.insert(position.noteID).inserted else {
                throw SQLiteFailure(message: "PCA result contains stale, duplicate, or invalid coordinates.")
            }
        }
        guard seen.count == expected.count else {
            throw SQLiteFailure(message: "PCA result omitted one or more notes.")
        }
    }

    private static func readProjection(
        snapshot: ProjectionInputSnapshot, transaction: SQLiteTransaction
    ) throws -> StoredNoteProjection? {
        let currentRows = try projectionInputRows(
            transaction: transaction, folderPath: snapshot.folderPath,
            spaceFingerprint: snapshot.spaceFingerprint)
        let currentInputs = try decodeProjectionInputs(currentRows, dimensions: snapshot.dimensions)
        let currentFingerprint = ProjectionInputSnapshot.fingerprint(
            folderPath: snapshot.folderPath, spaceFingerprint: snapshot.spaceFingerprint,
            inputs: currentInputs, reducerVersion: NoteProjectionReducer.version,
            parametersJSON: NoteProjectionReducer.parametersJSON)
        guard currentFingerprint == snapshot.inputFingerprint else { return nil }

        let runRows = try transaction.query(SQLiteStatement("""
            SELECT pr.run_id, pr.reducer_version, pr.parameters_json, pr.dimensions,
                   pr.numeric_encoding, pr.note_count, pr.mean, pr.basis, pr.created_at
            FROM projection_runs pr JOIN folders f ON f.id = pr.folder_id
            WHERE f.root_path = ? AND pr.space_id = ? AND pr.input_fingerprint = ?
            """, [.text(snapshot.folderPath), .text(snapshot.spaceFingerprint),
                  .text(snapshot.inputFingerprint)]))
        guard let row = runRows.first else { return nil }
        guard row.count == 9, case let .text(runID) = row[0],
              case let .text(reducerVersion) = row[1],
              case let .text(parametersJSON) = row[2],
              row[3] == .integer(Int64(snapshot.dimensions)),
              row[4] == .text(ProjectionFloat64Codec.encoding),
              row[5] == .integer(Int64(snapshot.inputs.count)),
              case let .blob(meanData) = row[6], case let .blob(basisData) = row[7],
              case let .real(createdAt) = row[8],
              reducerVersion == NoteProjectionReducer.version,
              parametersJSON == NoteProjectionReducer.parametersJSON else {
            throw SQLiteFailure(message: "Stored projection metadata is incompatible or malformed.")
        }
        let mean = try ProjectionFloat64Codec.decode(meanData, count: snapshot.dimensions)
        let basis = try ProjectionFloat64Codec.decode(basisData, count: snapshot.dimensions * 2)
        let positionRows = try transaction.query(SQLiteStatement("""
            SELECT p.note_id, p.source_hash, p.vector_hash, p.x, p.y
            FROM note_positions p
            JOIN notes n ON n.id = p.note_id
            JOIN note_embeddings ne ON ne.note_id = p.note_id AND ne.space_id = ?
            WHERE p.run_id = ? AND n.sync_state = 'indexed' AND n.content_hash = p.source_hash
              AND ne.state = 'ready' AND ne.source_hash = p.source_hash
              AND ne.vector_hash = p.vector_hash
            ORDER BY p.note_id
            """, [.text(snapshot.spaceFingerprint), .text(runID)]))
        let expected = Dictionary(uniqueKeysWithValues: snapshot.inputs.map {
            ($0.noteID, ($0.sourceHash, $0.vectorHash))
        })
        let positions = try positionRows.map { positionRow -> NoteProjectionPosition in
            guard positionRow.count == 5, case let .text(noteID) = positionRow[0],
                  case let .text(sourceHash) = positionRow[1],
                  case let .text(vectorHash) = positionRow[2],
                  case let .real(x) = positionRow[3], case let .real(y) = positionRow[4],
                  x.isFinite, y.isFinite,
                  let source = expected[noteID], source.0 == sourceHash, source.1 == vectorHash else {
                throw SQLiteFailure(message: "Stored note position is stale or malformed.")
            }
            return NoteProjectionPosition(noteID: noteID, sourceHash: sourceHash,
                                          vectorHash: vectorHash, x: x, y: y)
        }
        guard positions.count == snapshot.inputs.count else { return nil }
        return StoredNoteProjection(runID: runID, folderPath: snapshot.folderPath,
                                    spaceFingerprint: snapshot.spaceFingerprint,
                                    inputFingerprint: snapshot.inputFingerprint,
                                    reducerVersion: reducerVersion, parametersJSON: parametersJSON,
                                    dimensions: snapshot.dimensions, mean: mean, basis: basis,
                                    createdAt: createdAt, positions: positions)
    }
}
