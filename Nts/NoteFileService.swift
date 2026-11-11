import Foundation
import CryptoKit

struct NoteFile: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let date: Date
    var observedCreated: Date? = nil
    var observedModified: Date? = nil
    var name: String { url.lastPathComponent }
    var displayName: String { url.deletingPathExtension().lastPathComponent }

    static func orderingDate(created: Date?, modified: Date?) -> Date {
        created ?? modified ?? .distantPast
    }
}

enum NoteFileError: LocalizedError {
    case invalidUTF8
    case changedOnDisk
    case invalidFile
    case invalidName
    case nameAlreadyExists

    var errorDescription: String? {
        switch self {
        case .invalidUTF8: return "This note isn't UTF-8 text. Open it in another editor and convert it to UTF-8."
        case .changedOnDisk: return "This note changed on disk. Your edits are still here. Copy them somewhere safe, then reopen the note before saving."
        case .invalidFile: return "The note is missing or is no longer a regular file. Your edits are still here."
        case .invalidName: return "Use a nonempty filename without slashes, colons, control characters, or a leading dot."
        case .nameAlreadyExists: return "The name already exists."
        }
    }
}

struct NoteFileService {
    private let manager = FileManager.default

    func list(in folder: URL) throws -> [NoteFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey,
                                       .creationDateKey, .contentModificationDateKey]
        return try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return NoteFile(url: url, date: NoteFile.orderingDate(
                    created: values.creationDate, modified: values.contentModificationDate),
                    observedCreated: values.creationDate, observedModified: values.contentModificationDate)
            }
            .sorted { $0.date == $1.date ? $0.name < $1.name : $0.date > $1.date }
    }

    func read(_ url: URL) throws -> (text: String, data: Data) {
        try validate(url)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw NoteFileError.invalidUTF8 }
        return (text, data)
    }

    func create(in folder: URL, now: Date = Date(), text: String = "") throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = formatter.string(from: now)
        var suffix = 0
        while true {
            let name = suffix == 0 ? base : "\(base)-\(suffix)"
            let url = folder.appendingPathComponent(name).appendingPathExtension("md")
            do {
                // Exclusive creation: never truncate a file even if it appears after listing.
                try Data(text.utf8).write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as NSError {
                guard error.domain == NSCocoaErrorDomain,
                      error.code == CocoaError.fileWriteFileExists.rawValue else { throw error }
                suffix += 1
            }
        }
    }

    func create(in folder: URL, title: String, text: String) throws -> URL {
        let words = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let stem = words.map { word in
            String(word.unicodeScalars.filter {
                CharacterSet.letters.union(.decimalDigits).contains($0)
            })
        }.filter { !$0.isEmpty }.joined(separator: "-").lowercased()
        guard !stem.isEmpty else { return try create(in: folder, text: text) }
        let safeStem = String(stem.prefix(180))
        var suffix = 0
        while true {
            let name = suffix == 0 ? safeStem : "\(safeStem)-\(suffix)"
            let url = folder.appendingPathComponent(name).appendingPathExtension("md")
            do {
                try Data(text.utf8).write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as NSError {
                guard error.domain == NSCocoaErrorDomain,
                      error.code == CocoaError.fileWriteFileExists.rawValue else { throw error }
                suffix += 1
            }
        }
    }

    func save(_ text: String, to url: URL, expected: Data) throws -> Data {
        let data = Data(text.utf8)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result {
                try validate(target)
                guard try Data(contentsOf: target) == expected else { throw NoteFileError.changedOnDisk }
                // Replace atomically while retaining the original file's creation
                // date and permissions. Data.write(.atomic) resets the birth date.
                let temporary = target.deletingLastPathComponent()
                    .appendingPathComponent(".nts-\(UUID().uuidString).tmp")
                defer { try? manager.removeItem(at: temporary) }
                try data.write(to: temporary, options: .withoutOverwriting)
                _ = try manager.replaceItemAt(target, withItemAt: temporary)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw NoteFileError.invalidFile }
        try result.get()
        return data
    }

    func restore(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .withoutOverwriting)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                    && error.code == CocoaError.fileWriteFileExists.rawValue {
            throw NoteFileError.nameAlreadyExists
        }
    }

    func trash(_ url: URL, expected: Data) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            result = Result {
                try validate(target)
                guard try Data(contentsOf: target) == expected else { throw NoteFileError.changedOnDisk }
                try manager.trashItem(at: target, resultingItemURL: nil)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw NoteFileError.invalidFile }
        try result.get()
    }

    func rename(_ url: URL, to proposedName: String, expected: Data? = nil) throws -> URL {
        let destination = try renameDestination(url, proposedName: proposedName)
        try validate(url)
        guard destination != url else { return url }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forMoving,
                               writingItemAt: destination, options: [], error: &coordinationError) { source, target in
            result = Result {
                try validate(source)
                if let expected, try Data(contentsOf: source) != expected {
                    throw NoteFileError.changedOnDisk
                }
                // moveItem refuses an existing destination instead of overwriting it.
                do {
                    try manager.moveItem(at: source, to: target)
                } catch let error as NSError where error.domain == NSCocoaErrorDomain
                    && error.code == CocoaError.fileWriteFileExists.rawValue {
                    throw NoteFileError.nameAlreadyExists
                }
                coordinator.item(at: source, didMoveTo: target)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw NoteFileError.invalidFile }
        try result.get()
        return destination
    }

    func renameDestination(_ url: URL, proposedName: String) throws -> URL {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."),
              !name.contains("/"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw NoteFileError.invalidName
        }
        let filename = name.lowercased().hasSuffix(".md") ? name : name + ".md"
        let destination = url.deletingLastPathComponent().appendingPathComponent(filename)
        return destination
    }

    private func validate(_ url: URL) throws {
        // Listed URLs may cache resource values; validate the current on-disk item.
        let freshURL = URL(fileURLWithPath: url.path)
        let values = try freshURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw NoteFileError.invalidFile }
    }
}

enum WikiRenameError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Originals live outside disposable SQLite until the operation commits or recovers.
struct WikiRenamePlan: Codable, Sendable {
    struct Change: Codable, Sendable {
        let name: String
        let before: Data
        let after: Data
        let edits: [WikiLinkEdit]
    }
    let folder: URL
    let old: String
    let new: String
    let source: Data
    let changes: [Change]
    var destination: URL { folder.appendingPathComponent(new) }

    static func prepare(_ url: URL, name: String, expected: Data?) throws -> Self {
        let files = NoteFileService()
        let destination = try files.renameDestination(url, proposedName: name)
        let folder = url.deletingLastPathComponent()
        let source = try files.read(url).data
        if let expected, source != expected { throw NoteFileError.changedOnDisk }
        let notes = try files.list(in: folder)
        let names = notes.map(\.name)
        var changes: [Change] = []
        if url != destination {
            for note in notes {
                let content = try files.read(note.url)
                let edits = try WikiLinks.edits(in: content.text, old: url.lastPathComponent,
                                               new: destination.lastPathComponent, names: names)
                if !edits.isEmpty {
                    changes.append(Change(name: note.name, before: content.data,
                        after: Data(WikiLinkEdit.applying(edits, to: content.text).utf8), edits: edits))
                }
            }
        }
        return Self(folder: folder, old: url.lastPathComponent, new: destination.lastPathComponent,
                    source: source, changes: changes)
    }
}

struct WikiRenameCoordinator {
    var recoveryRoot: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Nts/RenameRecovery", isDirectory: true)
    // Fault injection occurs after each filesystem mutation, including the move.
    var checkpoint: (Int) throws -> Void = { _ in }

    func journal(_ folder: URL) -> URL {
        let key = folder.standardizedFileURL.path.utf8.map { String(format: "%02x", $0) }.joined()
        // Keep the filename bounded even for deeply nested folder paths.
        return recoveryRoot.appendingPathComponent(String(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()) + ".json")
    }

    func recover(folder: URL) throws {
        let record = journal(folder)
        guard FileManager.default.fileExists(atPath: record.path) else { return }
        let plan = try JSONDecoder().decode(WikiRenamePlan.self, from: Data(contentsOf: record))
        guard plan.folder.standardizedFileURL == folder.standardizedFileURL,
              [plan.old, plan.new].allSatisfy({ URL(fileURLWithPath: $0).lastPathComponent == $0 }),
              plan.changes.allSatisfy({ URL(fileURLWithPath: $0.name).lastPathComponent == $0.name }) else {
            throw WikiRenameError.message("The rename recovery record is invalid. Recovery files have been preserved.")
        }
        do {
            let files = NoteFileService()
            let oldURL = folder.appendingPathComponent(plan.old)
            // Exact directory spelling distinguishes case-only moves on APFS.
            let presentNames = try files.list(in: folder).map(\.name)
            let moved = !presentNames.contains(plan.old) && presentNames.contains(plan.new)
            for change in plan.changes.reversed() {
                let url = folder.appendingPathComponent(change.name == plan.old && moved ? plan.new : change.name)
                let current = try files.read(url).data
                if current == change.before { continue }
                guard current == change.after, let original = String(data: change.before, encoding: .utf8) else {
                    throw NoteFileError.changedOnDisk
                }
                _ = try files.save(original, to: url, expected: change.after)
            }
            if moved { _ = try files.rename(plan.destination, to: plan.old, expected: plan.source) }
            else {
                guard try files.read(oldURL).data == plan.source else { throw NoteFileError.changedOnDisk }
            }
            try FileManager.default.removeItem(at: record)
        } catch {
            throw WikiRenameError.message("Rename recovery needs attention: a file is missing or changed. Originals are preserved at \(record.path). Restore the conflicting file before retrying. \(error.localizedDescription)")
        }
    }

    func execute(_ plan: WikiRenamePlan) throws {
        try recover(folder: plan.folder)
        guard plan.old != plan.new else { return }
        let files = NoteFileService()
        let sourceURL = plan.folder.appendingPathComponent(plan.old)
        // Fresh preparation also catches new inbound links since the background scan.
        let fresh = try WikiRenamePlan.prepare(sourceURL, name: plan.new, expected: plan.source)
        guard fresh.changes.map(\.name) == plan.changes.map(\.name),
              zip(fresh.changes, plan.changes).allSatisfy({
                  $0.before == $1.before && $0.after == $1.after
              }) else {
            throw NoteFileError.changedOnDisk
        }
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let record = journal(plan.folder)
        try JSONEncoder().encode(plan).write(to: record, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        do {
            _ = try files.rename(sourceURL, to: plan.new, expected: plan.source)
            try checkpoint(0)
            for (offset, change) in plan.changes.enumerated() {
                let url = plan.folder.appendingPathComponent(change.name == plan.old ? plan.new : change.name)
                _ = try files.save(String(decoding: change.after, as: UTF8.self), to: url, expected: change.before)
                try checkpoint(offset + 1)
            }
            // Removing the journal is the commit point. A crash before it rolls back.
            try FileManager.default.removeItem(at: record)
        } catch {
            try recover(folder: plan.folder)
            throw error
        }
    }
}
