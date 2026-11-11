import Foundation
import CryptoKit

struct NoteRename: Sendable {
    let source: URL
    let destination: URL
    var originalHash: String? = nil
    var rewrittenHash: String? = nil
}

struct NoteIndexResult: Sendable {
    let fileErrors: Int
    let dates: [String: Date]
}

struct IndexedFile {
    let path: String
    let hash: String?
    let error: String?
    let created: Date?
    let modified: Date?
    var links: [WikiLinkOccurrence] = []
}

/// Reads saved files only; it has no editor binding and never writes Markdown.
struct NoteIndexScanner {
    func scan(_ folder: URL) throws -> [IndexedFile] {
        let files = NoteFileService()
        // A failed directory listing aborts reconciliation; never mark everything missing.
        return try files.list(in: folder).map { note in
            do {
                let contents = try files.read(note.url)
                let hash = SHA256.hash(data: contents.data).map { String(format: "%02x", $0) }.joined()
                return IndexedFile(path: note.name, hash: hash, error: nil, created: note.observedCreated, modified: note.observedModified, links: WikiLinks.occurrences(in: contents.text))
            } catch {
                return IndexedFile(path: note.name, hash: nil, error: error.localizedDescription, created: note.observedCreated, modified: note.observedModified)
            }
        }
    }
}

/// Wiki links use the editor's code-aware syntax parser, with exact UTF-16 target spans.
struct WikiLinkOccurrence: Sendable {
    let target: String
    let range: NSRange
}

enum WikiLinks {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static let parserVersion = 1
    static func occurrences(in text: String) -> [WikiLinkOccurrence] {
        let source = text as NSString
        return LiveMarkdownPlan.decorations(in: text).compactMap { item in
            guard case .wikiLink(let target) = item.kind else { return nil }
            let inner = NSRange(location: item.range.location + 2, length: item.range.length - 4)
            let raw = source.substring(with: inner).components(separatedBy: "|")[0]
            let leading = raw.prefix(while: { $0.isWhitespace }).utf16.count
            return WikiLinkOccurrence(target: target,
                range: NSRange(location: inner.location + leading, length: target.utf16.count))
        }
    }

    static func matches(_ target: String, names: [String]) -> [String] {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = names.filter { $0 == target || ($0 as NSString).deletingPathExtension == target }
        return exact.isEmpty ? names.filter {
            $0.caseInsensitiveCompare(target) == .orderedSame ||
            ($0 as NSString).deletingPathExtension.caseInsensitiveCompare(target) == .orderedSame
        } : exact
    }

    static func edits(in text: String, old: String, new: String, names: [String]) throws -> [WikiLinkEdit] {
        let afterNames = names.map { $0 == old ? new : $0 }
        return try occurrences(in: text).compactMap { link in
            guard matches(link.target, names: names) == [old] else { return nil }
            var replacement = link.target.lowercased().hasSuffix(".md") ? new : (new as NSString).deletingPathExtension
            if matches(replacement, names: afterNames) != [new] { replacement = new }
            guard matches(replacement, names: afterNames) == [new],
                  !replacement.contains("["), !replacement.contains("]"), !replacement.contains("|") else {
                throw WikiRenameError.message("This filename cannot be used as an unambiguous wiki-link target.")
            }
            return WikiLinkEdit(location: link.range.location, length: link.range.length, replacement: replacement)
        }
    }
}

struct WikiLinkEdit: Codable, Sendable {
    let location: Int
    let length: Int
    let replacement: String
    var range: NSRange { NSRange(location: location, length: length) }
    static func applying(_ edits: [Self], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.location > $1.location }) {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }
}
