import Foundation
import CryptoKit

struct FilenameSuggestionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol FilenameGenerating: Sendable {
    func download(configuration: FilenameModelConfiguration, progress: @escaping @Sendable (Double) -> Void) async throws
    func isAvailable(configuration: FilenameModelConfiguration) async -> Bool
    func generate(text: String, configuration: FilenameModelConfiguration) async throws -> String
    func unload() async
}

extension FilenameGenerating {
    func isAvailable(configuration: FilenameModelConfiguration) async -> Bool { true }
}

struct FilenameJob: Sendable {
    let noteID: String
    let url: URL
    let sourceHash: String
    let configurationHash: String
}

struct FilenameSuggestion: Equatable, Sendable {
    let state: String
    let filename: String?
    let error: String?
}

struct FilenameOutput {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Accept a single title or stem, then normalize to the app's portable filename form.
    /// Do not extract a name from paths, multiple lines or reasoning blocks.
    static func filename(from raw: String, in folder: URL, current: URL) throws -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["Title:", "Filename:", "Título:", "Titre:"] {
            if title.lowercased().hasPrefix(label.lowercased()) {
                title = String(title.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        // A single quoted title is common model formatting; code blocks remain invalid.
        for quote in ["\"", "'", "`"] {
            if title.count >= 2, title.hasPrefix(quote), title.hasSuffix(quote) {
                title = String(title.dropFirst().dropLast())
                break
            }
        }
        if title.lowercased().hasSuffix(".md") { title = String(title.dropLast(3)) }
        title = title.trimmingCharacters(in: .whitespaces).lowercased().precomposedStringWithCanonicalMapping
        let allowed = CharacterSet.letters.union(.decimalDigits).union(.whitespaces)
        let words = title.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        guard !title.isEmpty, !title.contains(where: \.isNewline),
              !title.hasPrefix("-"), !title.hasSuffix("-"),
              !words.isEmpty, words.count <= 6,
              title.unicodeScalars.allSatisfy({ allowed.contains($0) || $0 == "-" }) else {
            throw FilenameSuggestionFailure(message: "The model did not return a valid filename. Try generating again.")
        }
        let stem = words.joined(separator: "-")
        guard stem.utf8.count <= 180 else {
            throw FilenameSuggestionFailure(message: "The model did not return a valid filename. Try generating again.")
        }
        let filename = stem + ".md"
        let target = folder.appendingPathComponent(filename)
        if target != current, FileManager.default.fileExists(atPath: target.path) {
            throw FilenameSuggestionFailure(message: "The suggested filename already exists. Try generating again.")
        }
        return filename
    }
}

extension SQLiteDatabase {
    /// Revalidate the clicked result, not a later replacement suggestion.
    /// The filesystem service checks these bytes again inside coordinated rename.
    func filenameApplicationData(url: URL, filename: String, configuration: FilenameModelConfiguration) throws -> Data {
        let folder = url.deletingLastPathComponent()
        let rows = try query(SQLiteStatement("""
            SELECT s.source_hash FROM filename_suggestions s
            JOIN notes n ON n.id = s.note_id JOIN folders f ON f.id = n.folder_id
            WHERE f.root_path = ? AND n.relative_path = ? AND n.sync_state = 'indexed'
              AND s.state = 'ready' AND s.suggested_filename = ? AND s.configuration_hash = ?
              AND s.source_hash = n.content_hash
            """, [.text(folder.resolvingSymlinksInPath().standardizedFileURL.path), .text(url.lastPathComponent),
                  .text(filename), .text(configuration.fingerprint)]))
        guard case let .text(hash) = rows.first?.first else {
            throw FilenameSuggestionFailure(message: "This suggestion is no longer current. Generate a new filename first.")
        }
        let data = try NoteFileService().read(url).data
        guard FilenameOutput.hash(data) == hash else {
            throw FilenameSuggestionFailure(message: "The saved note changed. Generate a new filename before applying it.")
        }
        guard filename.hasSuffix(".md"),
              try FilenameOutput.filename(from: String(filename.dropLast(3)), in: folder, current: url) == filename else {
            throw FilenameSuggestionFailure(message: "The suggested filename is invalid. Generate a new filename first.")
        }
        return data
    }

    func queueFilename(url: URL, configuration: FilenameModelConfiguration, force: Bool = false) throws {
        // Reconciliation has completed before this call; read saved bytes on the database actor.
        let data = try NoteFileService().read(url).data
        let hash = FilenameOutput.hash(data)
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        try execute(SQLiteStatement("""
            INSERT INTO filename_suggestions
              (note_id, source_hash, configuration_hash, model_id, model_revision, prompt_version, configuration_json, state, attempts)
            SELECT n.id, ?, ?, ?, ?, ?, ?, 'queued', 0 FROM notes n JOIN folders f ON n.folder_id = f.id
            WHERE f.root_path = ? AND n.relative_path = ? AND n.content_hash = ? AND n.sync_state = 'indexed'
            ON CONFLICT(note_id) DO UPDATE SET
              source_hash = excluded.source_hash, configuration_hash = excluded.configuration_hash,
              model_id = excluded.model_id, model_revision = excluded.model_revision,
              prompt_version = excluded.prompt_version, configuration_json = excluded.configuration_json,
              state = 'queued', suggested_filename = NULL, error = NULL, generated_at = NULL,
              attempts = CASE WHEN filename_suggestions.source_hash = excluded.source_hash
                AND filename_suggestions.configuration_hash = excluded.configuration_hash THEN filename_suggestions.attempts ELSE 0 END
            WHERE filename_suggestions.source_hash != excluded.source_hash
               OR filename_suggestions.configuration_hash != excluded.configuration_hash
               OR filename_suggestions.state IN ('error', 'stale') OR ? = 1
            """, [.text(hash), .text(configuration.fingerprint), .text(configuration.modelID), .text(configuration.revision),
                  .text(configuration.promptVersion), .text(configuration.json), .text(folder), .text(url.lastPathComponent),
                  .text(hash), .integer(force ? 1 : 0)]))
    }

    func pendingFilenames(folder: URL, configuration: FilenameModelConfiguration) throws -> [FilenameJob] {
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        return try query(SQLiteStatement("""
            SELECT n.id, n.relative_path, s.source_hash FROM filename_suggestions s
            JOIN notes n ON n.id = s.note_id JOIN folders f ON f.id = n.folder_id
            WHERE f.root_path = ? AND s.configuration_hash = ? AND s.state IN ('queued', 'processing')
              AND n.sync_state = 'indexed' AND n.content_hash = s.source_hash ORDER BY n.relative_path
            """, [.text(canonical.path), .text(configuration.fingerprint)])).compactMap { row in
                guard case let .text(id) = row[0], case let .text(path) = row[1], case let .text(hash) = row[2] else { return nil }
                return FilenameJob(noteID: id, url: folder.appendingPathComponent(path), sourceHash: hash,
                                   configurationHash: configuration.fingerprint)
            }
    }

    func filenameInput(_ job: FilenameJob) throws -> String? {
        let contents = try NoteFileService().read(job.url)
        guard FilenameOutput.hash(contents.data) == job.sourceHash else { return nil }
        let rows = try query(SQLiteStatement("""
            SELECT s.note_id FROM filename_suggestions s JOIN notes n ON n.id = s.note_id
            WHERE s.note_id = ? AND s.source_hash = ? AND s.configuration_hash = ?
              AND s.state IN ('queued', 'processing') AND n.content_hash = s.source_hash AND n.sync_state = 'indexed'
            """, [.text(job.noteID), .text(job.sourceHash), .text(job.configurationHash)]))
        guard !rows.isEmpty else { return nil }
        try execute(SQLiteStatement("UPDATE filename_suggestions SET state = 'processing', attempts = attempts + 1 WHERE note_id = ?", [.text(job.noteID)]))
        return contents.text
    }

    /// Compare both current disk bytes and registry/configuration inside the serialized actor.
    func finishFilename(_ job: FilenameJob, filename: String?, error: String?) throws {
        let data = try? NoteFileService().read(job.url).data
        let current = data.map(FilenameOutput.hash) == job.sourceHash
        try execute(SQLiteStatement("""
            UPDATE filename_suggestions SET state = ?, suggested_filename = ?, error = ?, generated_at = ?
            WHERE note_id = ? AND source_hash = ? AND configuration_hash = ?
              AND state = 'processing'
              AND EXISTS (SELECT 1 FROM notes n WHERE n.id = note_id AND n.content_hash = source_hash AND n.sync_state = 'indexed')
            """, [.text(current ? (error == nil ? "ready" : "error") : "stale"),
                  current ? (filename.map(SQLiteValue.text) ?? .null) : .null,
                  current ? (error.map(SQLiteValue.text) ?? .null) : .null,
                  current && error == nil ? .real(Date().timeIntervalSince1970) : .null,
                  .text(job.noteID), .text(job.sourceHash), .text(job.configurationHash)]))
    }

    func dismissFilename(url: URL) throws {
        try execute(SQLiteStatement("""
            DELETE FROM filename_suggestions WHERE note_id IN (
                SELECT n.id FROM notes n JOIN folders f ON f.id = n.folder_id
                WHERE f.root_path = ? AND n.relative_path = ?
            )
            """, [.text(url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path),
                  .text(url.lastPathComponent)]))
    }

    func filenameSuggestions(folder: URL, configuration: FilenameModelConfiguration) throws -> [String: FilenameSuggestion] {
        let rows = try query(SQLiteStatement("""
            SELECT n.relative_path, s.state, s.suggested_filename, s.error FROM filename_suggestions s
            JOIN notes n ON n.id = s.note_id JOIN folders f ON f.id = n.folder_id
            WHERE f.root_path = ? AND s.configuration_hash = ? AND s.source_hash = n.content_hash AND n.sync_state = 'indexed'
            """, [.text(folder.resolvingSymlinksInPath().standardizedFileURL.path), .text(configuration.fingerprint)]))
        var result: [String: FilenameSuggestion] = [:]
        for row in rows {
            guard case let .text(path) = row[0], case let .text(state) = row[1] else { continue }
            func string(_ value: SQLiteValue) -> String? { if case let .text(text) = value { return text }; return nil }
            result[path] = FilenameSuggestion(state: state, filename: string(row[2]), error: string(row[3]))
        }
        return result
    }
}
