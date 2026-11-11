import Foundation
import SQLite3

struct SQLiteFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SQLiteValue: Equatable, Sendable {
    case integer(Int64), real(Double), text(String), blob(Data), null
}

struct SQLiteStatement: Sendable {
    let sql: String
    let parameters: [SQLiteValue]

    init(_ sql: String, _ parameters: [SQLiteValue] = []) {
        self.sql = sql
        self.parameters = parameters
    }
}

struct SQLiteMigration: Sendable {
    let version: Int
    let statements: [String]

    // Phase 2.1 reserves version 1 without creating future feature tables.
    static let foundation = [SQLiteMigration(version: 1, statements: [])]
    static let current = foundation + [SQLiteMigration(version: 2, statements: [
        """
        CREATE TABLE folders (
            id TEXT PRIMARY KEY NOT NULL,
            root_path TEXT NOT NULL UNIQUE
        )
        """,
        """
        CREATE TABLE notes (
            id TEXT PRIMARY KEY NOT NULL,
            folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
            relative_path TEXT NOT NULL,
            content_hash TEXT,
            sync_state TEXT NOT NULL CHECK (sync_state IN ('indexed', 'missing', 'error')),
            index_error TEXT,
            indexed_at REAL,
            UNIQUE (folder_id, relative_path)
        )
        """
    ]), SQLiteMigration(version: 3, statements: [
        "ALTER TABLE notes ADD COLUMN observed_created_at REAL",
        "ALTER TABLE notes ADD COLUMN observed_modified_at REAL",
        "ALTER TABLE notes ADD COLUMN preserved_created_at REAL"
    ]), SQLiteMigration(version: 4, statements: [
        """
        CREATE TABLE filename_suggestions (
            note_id TEXT PRIMARY KEY NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            source_hash TEXT NOT NULL, configuration_hash TEXT NOT NULL,
            model_id TEXT NOT NULL, model_revision TEXT NOT NULL, prompt_version TEXT NOT NULL,
            configuration_json TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('queued', 'processing', 'ready', 'error', 'stale')),
            suggested_filename TEXT, error TEXT, attempts INTEGER NOT NULL DEFAULT 0, generated_at REAL
        )
        """
    ]), SQLiteMigration(version: 5, statements: [
        """
        CREATE TABLE embedding_spaces (
            fingerprint TEXT PRIMARY KEY NOT NULL,
            configuration_json TEXT NOT NULL,
            model_id TEXT NOT NULL,
            model_revision TEXT NOT NULL,
            tokenizer_revision TEXT NOT NULL,
            dimensions INTEGER NOT NULL CHECK (dimensions > 0),
            vector_encoding TEXT NOT NULL CHECK (vector_encoding = 'float32-le-v1'),
            pipeline_version TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE note_embeddings (
            note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            space_id TEXT NOT NULL REFERENCES embedding_spaces(fingerprint) ON DELETE CASCADE,
            source_hash TEXT NOT NULL,
            job_token TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('queued', 'processing', 'ready', 'error', 'skipped-empty')),
            vector BLOB,
            vector_hash TEXT,
            attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
            error TEXT,
            updated_at REAL NOT NULL,
            PRIMARY KEY (note_id, space_id),
            CHECK (
                (state = 'ready' AND vector IS NOT NULL AND vector_hash IS NOT NULL)
                OR (state != 'ready' AND vector IS NULL AND vector_hash IS NULL)
            )
        )
        """,
        "CREATE INDEX note_embeddings_state_updated ON note_embeddings(state, updated_at)"
    ]), SQLiteMigration(version: 6, statements: [
        """
        CREATE TABLE projection_runs (
            run_id TEXT PRIMARY KEY NOT NULL,
            folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
            space_id TEXT NOT NULL REFERENCES embedding_spaces(fingerprint) ON DELETE CASCADE,
            input_fingerprint TEXT NOT NULL,
            reducer_version TEXT NOT NULL,
            parameters_json TEXT NOT NULL,
            dimensions INTEGER NOT NULL CHECK (dimensions > 0),
            numeric_encoding TEXT NOT NULL CHECK (numeric_encoding = 'float64-le-v1'),
            note_count INTEGER NOT NULL CHECK (note_count >= 0),
            mean BLOB NOT NULL,
            basis BLOB NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE (folder_id, space_id, input_fingerprint)
        )
        """,
        """
        CREATE TABLE note_positions (
            run_id TEXT NOT NULL REFERENCES projection_runs(run_id) ON DELETE CASCADE,
            note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            source_hash TEXT NOT NULL,
            vector_hash TEXT NOT NULL,
            x REAL NOT NULL CHECK (x BETWEEN -1.0e308 AND 1.0e308),
            y REAL NOT NULL CHECK (y BETWEEN -1.0e308 AND 1.0e308),
            PRIMARY KEY (run_id, note_id)
        )
        """,
        "CREATE INDEX projection_runs_scope_created ON projection_runs(folder_id, space_id, created_at)",
        "CREATE INDEX note_positions_note ON note_positions(note_id)"
    ]), SQLiteMigration(version: 7, statements: [
        """
        CREATE TABLE note_links (
            source_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
            source_hash TEXT NOT NULL,
            parser_version INTEGER NOT NULL,
            target_text TEXT NOT NULL,
            target_location INTEGER NOT NULL,
            target_length INTEGER NOT NULL,
            target_id TEXT REFERENCES notes(id) ON DELETE SET NULL,
            PRIMARY KEY(source_id, target_location)
        )
        """,
        "CREATE INDEX note_links_target ON note_links(target_id)"
    ])]
}

/// All SQLite work, including opening/migrating, runs on this actor's executor.
/// No connection or prepared statement crosses the actor boundary.
actor SQLiteDatabase {
    private let location: URL?
    private let migrations: [SQLiteMigration]
    private var connection: SQLiteConnection?

    init(url: URL? = nil, migrations: [SQLiteMigration] = SQLiteMigration.current) {
        location = url
        self.migrations = migrations
    }

    static func applicationSupportURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true)
        // The bundle identifier remains stable to preserve the existing sandbox container and data.
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw SQLiteFailure(message: "The app bundle identifier is unavailable.")
        }
        return support.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("metadata.sqlite")
    }

    @discardableResult
    func initialize() throws -> URL {
        if let connection { return connection.url }
        guard !migrations.isEmpty,
              migrations.map(\.version) == Array(1...migrations.count) else {
            throw SQLiteFailure(message: "Database migrations must be numbered consecutively from 1.")
        }
        let url = try location ?? Self.applicationSupportURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let opened = try SQLiteConnection(url: url)
        // Publish the connection only after all checks and migrations succeed.
        try opened.configureAndMigrate(migrations)
        connection = opened
        return url
    }

    func query(_ statement: SQLiteStatement) throws -> [[SQLiteValue]] {
        try requireConnection().query(statement)
    }

    func execute(_ statement: SQLiteStatement) throws {
        _ = try requireConnection().query(statement)
    }

    /// Batches are synchronous and bounded by the caller; never await inside a transaction.
    func transaction(_ statements: [SQLiteStatement]) throws {
        let connection = try requireConnection()
        try connection.transaction {
            for statement in statements { _ = try connection.query(statement) }
        }
    }

    func transaction<T>(_ body: (SQLiteTransaction) throws -> T) throws -> T {
        let connection = try requireConnection()
        return try connection.transaction { try body(SQLiteTransaction(connection: connection)) }
    }

    func close() {
        connection = nil
    }

    private func requireConnection() throws -> SQLiteConnection {
        guard let connection else {
            throw SQLiteFailure(message: "The metadata database is not initialized.")
        }
        return connection
    }
}

struct SQLiteTransaction {
    private let connection: SQLiteConnection

    fileprivate init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func query(_ statement: SQLiteStatement) throws -> [[SQLiteValue]] {
        try connection.query(statement)
    }

    @discardableResult
    func execute(_ statement: SQLiteStatement) throws -> Int {
        _ = try connection.query(statement)
        return connection.changes
    }
}

fileprivate final class SQLiteConnection {
    let url: URL
    private let handle: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        self.url = url
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened,
                                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot allocate a connection."
            if let opened { sqlite3_close_v2(opened) }
            throw SQLiteFailure(message: "Cannot open the metadata database: \(message)")
        }
        handle = opened
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 1_500)
    }

    deinit {
        // Every prepared statement is finalized within query(), including error paths.
        sqlite3_close_v2(handle)
    }

    func configureAndMigrate(_ migrations: [SQLiteMigration]) throws {
        let supported = migrations.count
        try checkVersion(supported: supported)
        guard try query(SQLiteStatement("PRAGMA quick_check")) == [[.text("ok")]] else {
            throw SQLiteFailure(message: "The metadata database failed its integrity check. Keep the existing file for recovery.")
        }
        guard sqlite3_db_readonly(handle, "main") == 0 else {
            throw SQLiteFailure(message: "The metadata database is read-only. Check its folder permissions.")
        }
        _ = try query(SQLiteStatement("PRAGMA foreign_keys = ON"))
        guard try query(SQLiteStatement("PRAGMA foreign_keys")) == [[.integer(1)]] else {
            throw SQLiteFailure(message: "Cannot enable database foreign-key protection.")
        }
        // One serialized connection needs no WAL yet. Keep durable rollback journals.
        guard try query(SQLiteStatement("PRAGMA journal_mode = DELETE")) == [[.text("delete")]] else {
            throw SQLiteFailure(message: "Cannot configure database rollback journaling.")
        }
        _ = try query(SQLiteStatement("PRAGMA synchronous = FULL"))
        for migration in migrations {
            try transaction {
                // Recheck under the write lock, including after another process migrated.
                try checkVersion(supported: supported)
                let version = try schemaVersion()
                guard version < migration.version else { return }
                for sql in migration.statements { _ = try query(SQLiteStatement(sql)) }
                _ = try query(SQLiteStatement("PRAGMA user_version = \(migration.version)"))
            }
        }
    }

    private func checkVersion(supported: Int) throws {
        let version = try schemaVersion()
        guard version >= 0, version <= supported else {
            throw SQLiteFailure(message: "This metadata database uses schema \(version), but this app supports \(supported). Open it with a newer app version. The database has been preserved.")
        }
    }

    private func schemaVersion() throws -> Int {
        guard let row = try query(SQLiteStatement("PRAGMA user_version")).first,
              case let .integer(version) = row.first else {
            throw SQLiteFailure(message: "Cannot read the database schema version.")
        }
        return Int(version)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        guard sqlite3_get_autocommit(handle) != 0 else {
            throw SQLiteFailure(message: "Nested database transactions are not supported.")
        }
        _ = try query(SQLiteStatement("BEGIN IMMEDIATE"))
        do {
            let result = try body()
            _ = try query(SQLiteStatement("COMMIT"))
            return result
        } catch {
            _ = try? query(SQLiteStatement("ROLLBACK"))
            throw error
        }
    }

    func query(_ request: SQLiteStatement) throws -> [[SQLiteValue]] {
        guard !request.sql.contains("\u{0}") else {
            throw SQLiteFailure(message: "SQL statements cannot contain null characters.")
        }
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        try request.sql.withCString { sql in
            var tail: UnsafePointer<CChar>?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, &tail) == SQLITE_OK else { throw failure() }
            guard statement != nil,
                  tail.map({ String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true else {
                throw SQLiteFailure(message: "Execute one nonempty SQL statement at a time.")
            }
        }
        guard let statement, sqlite3_bind_parameter_count(statement) == request.parameters.count else {
            throw SQLiteFailure(message: "The database parameter count does not match the statement.")
        }
        for (offset, value) in request.parameters.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .integer(value): result = sqlite3_bind_int64(statement, index, value)
            case let .real(value): result = sqlite3_bind_double(statement, index, value)
            case let .text(value):
                guard let length = Int32(exactly: value.utf8.count) else {
                    throw SQLiteFailure(message: "The database text value is too large.")
                }
                result = value.withCString { sqlite3_bind_text(statement, index, $0, length, transient) }
            case let .blob(value):
                guard let length = Int32(exactly: value.count) else {
                    throw SQLiteFailure(message: "The database binary value is too large.")
                }
                if value.isEmpty {
                    result = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    result = value.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, length, transient)
                    }
                }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        var rows: [[SQLiteValue]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return rows
            case SQLITE_ROW:
                var row: [SQLiteValue] = []
                for column in 0..<sqlite3_column_count(statement) {
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                    case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, column)))
                    case SQLITE_TEXT:
                        let count = Int(sqlite3_column_bytes(statement, column))
                        let bytes = sqlite3_column_text(statement, column)
                        row.append(.text(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)))
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, column))
                        if count == 0 {
                            row.append(.blob(Data()))
                        } else {
                            guard let bytes = sqlite3_column_blob(statement, column) else { throw failure() }
                            row.append(.blob(Data(bytes: bytes, count: count)))
                        }
                    case SQLITE_NULL: row.append(.null)
                    default: throw SQLiteFailure(message: "Unsupported SQLite value type.")
                    }
                }
                rows.append(row)
            default: throw failure()
            }
        }
    }

    private func failure() -> SQLiteFailure {
        SQLiteFailure(message: "Metadata database error (\(sqlite3_extended_errcode(handle))): \(String(cString: sqlite3_errmsg(handle)))")
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
}


extension SQLiteDatabase {
    /// Scanning and reconciliation share the database actor, so scans cannot commit
    /// out of order. Files are read before the short database write transaction.
    @discardableResult
    func reconcile(folder: URL, rename: NoteRename? = nil) throws -> NoteIndexResult {
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        let snapshot = try NoteIndexScanner().scan(canonical)
        let connection = try requireConnection()
        try connection.transaction {
            _ = try connection.query(SQLiteStatement(
                "INSERT INTO folders (id, root_path) VALUES (?, ?) ON CONFLICT(root_path) DO NOTHING",
                [.text(UUID().uuidString), .text(canonical.path)]))
            let folderRows = try connection.query(SQLiteStatement(
                "SELECT id FROM folders WHERE root_path = ?", [.text(canonical.path)]))
            guard case let .text(folderID) = folderRows.first?.first else {
                throw SQLiteFailure(message: "Cannot resolve the indexed notes folder.")
            }
            let scope: SQLiteValue = .text(folderID)
            var previous: [String: [SQLiteValue]] = [:]
            for row in try connection.query(SQLiteStatement(
                "SELECT relative_path, content_hash, sync_state, preserved_created_at FROM notes WHERE folder_id = ?", [scope])) {
                if case let .text(path) = row[0] { previous[path] = row }
            }
            // Only an explicit app rename with matching saved bytes can retain an ID.
            // External rename matching by hash would confuse duplicate-content notes.
            if let rename,
               rename.source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == canonical,
               rename.destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == canonical {
                let old = rename.source.lastPathComponent
                let new = rename.destination.lastPathComponent
                if old != new, !snapshot.contains(where: { $0.path == old }),
                   previous[new] == nil, let oldRow = previous[old], oldRow[2] == .text("indexed"),
                   let newFile = snapshot.first(where: { $0.path == new }), let hash = newFile.hash,
                   (oldRow[1] == .text(hash) ||
                    (rename.originalHash.map(SQLiteValue.text) == oldRow[1] && rename.rewrittenHash == hash)) {
                    _ = try connection.query(SQLiteStatement(
                        "UPDATE notes SET relative_path = ? WHERE folder_id = ? AND relative_path = ?",
                        [.text(new), scope, .text(old)]))
                    previous[new] = previous.removeValue(forKey: old)
                    // A chosen filename supersedes any preview retained under the note ID.
                    _ = try connection.query(SQLiteStatement("""
                        DELETE FROM filename_suggestions
                        WHERE note_id IN (SELECT id FROM notes WHERE folder_id = ? AND relative_path = ?)
                        """, [scope, .text(new)]))
                }
            }
            let present = Set(snapshot.map(\.path))
            let missingPaths = previous.keys.filter { !present.contains($0) }
            if !missingPaths.isEmpty {
                // Layouts describe the complete input set, so discard them when any
                // indexed note disappears. Note deletion cascades embeddings,
                // filename suggestions, and positions in other retained runs.
                _ = try connection.query(SQLiteStatement(
                    "DELETE FROM projection_runs WHERE folder_id = ?", [scope]))
                for path in missingPaths {
                    _ = try connection.query(SQLiteStatement(
                        "DELETE FROM notes WHERE folder_id = ? AND relative_path = ?",
                        [scope, .text(path)]))
                }
            }
            let now = Date().timeIntervalSince1970
            for file in snapshot {
                // Retain the last good hash on read errors, but never call it current.
                let hash: SQLiteValue = file.hash.map(SQLiteValue.text) ?? previous[file.path]?[1] ?? .null
                let state = file.error == nil ? "indexed" : "error"
                _ = try connection.query(SQLiteStatement("""
                    INSERT INTO notes (id, folder_id, relative_path, content_hash, sync_state, index_error, indexed_at, observed_created_at, observed_modified_at, preserved_created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(folder_id, relative_path) DO UPDATE SET
                        observed_created_at = excluded.observed_created_at,
                        observed_modified_at = excluded.observed_modified_at,
                        preserved_created_at = COALESCE(notes.preserved_created_at, excluded.preserved_created_at),
                        content_hash = excluded.content_hash,
                        sync_state = excluded.sync_state,
                        index_error = excluded.index_error,
                        indexed_at = CASE WHEN excluded.sync_state = 'indexed' THEN excluded.indexed_at ELSE notes.indexed_at END
                    WHERE notes.content_hash IS NOT excluded.content_hash
                       OR notes.sync_state != excluded.sync_state
                       OR notes.index_error IS NOT excluded.index_error
                       OR notes.observed_created_at IS NOT excluded.observed_created_at
                       OR notes.observed_modified_at IS NOT excluded.observed_modified_at
                       OR (notes.preserved_created_at IS NULL AND excluded.preserved_created_at IS NOT NULL)
                    """, [.text(UUID().uuidString), scope, .text(file.path), hash, .text(state),
                          file.error.map(SQLiteValue.text) ?? .null, file.error == nil ? .real(now) : .null,
                          file.created.map { .real($0.timeIntervalSince1970) } ?? .null,
                          file.modified.map { .real($0.timeIntervalSince1970) } ?? .null,
                          (file.created ?? file.modified).map { .real($0.timeIntervalSince1970) } ?? .null]))
            }
            // Rebuild this folder's derived relationships from the same saved snapshot.
            // Errors deliberately remove outgoing rows instead of retaining stale ranges.
            let identities = try connection.query(SQLiteStatement(
                "SELECT relative_path, id FROM notes WHERE folder_id = ?", [scope]))
            var ids: [String: SQLiteValue] = [:]
            for row in identities { if case .text(let name) = row[0] { ids[name] = row[1] } }
            _ = try connection.query(SQLiteStatement(
                "DELETE FROM note_links WHERE source_id IN (SELECT id FROM notes WHERE folder_id = ?)", [scope]))
            for file in snapshot {
                guard let hash = file.hash, file.error == nil, let sourceID = ids[file.path] else { continue }
                for link in file.links {
                    let matches = WikiLinks.matches(link.target, names: snapshot.map(\.path))
                    let targetID = matches.count == 1 ? ids[matches[0]] ?? .null : .null
                    _ = try connection.query(SQLiteStatement("""
                        INSERT INTO note_links VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, [sourceID, .text(hash), .integer(Int64(WikiLinks.parserVersion)),
                              .text(link.target), .integer(Int64(link.range.location)),
                              .integer(Int64(link.range.length)), targetID]))
                }
            }
        }
        try execute(SQLiteStatement("""
            UPDATE filename_suggestions SET state = 'stale', suggested_filename = NULL, error = NULL
            WHERE state != 'stale' AND EXISTS (
                SELECT 1 FROM notes n WHERE n.id = filename_suggestions.note_id
                  AND (n.sync_state != 'indexed' OR n.content_hash IS NOT filename_suggestions.source_hash)
            )
            """))
        let rows = try connection.query(SQLiteStatement("""
            SELECT n.relative_path, n.preserved_created_at FROM notes n
            JOIN folders f ON n.folder_id = f.id
            WHERE f.root_path = ? AND n.sync_state != 'missing'
            """, [.text(canonical.path)]))
        var dates: [String: Date] = [:]
        for row in rows {
            if case let .text(path) = row[0], case let .real(value) = row[1] {
                dates[path] = Date(timeIntervalSince1970: value)
            }
        }
        return NoteIndexResult(fileErrors: snapshot.filter { $0.error != nil }.count, dates: dates)
    }
}
