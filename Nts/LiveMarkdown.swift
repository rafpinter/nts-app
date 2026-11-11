import AppKit
import CoreText
import UniformTypeIdentifiers

struct MarkdownDecoration {
    enum Kind {
        case heading(Int), strong, emphasis, code, strike, underline, quote, link(String)
        case image(String), list(Bool?), orderedList, horizontalRule, table(MarkdownTable)
        case footnoteReference(String), footnoteDefinition(String)
        case wikiLink(String)
    }
    let kind: Kind
    let range: NSRange
    let content: NSRange
    let markers: [NSRange]
    let isBlock: Bool
}

enum LiveMarkdownPlan {
    static func decorations(in source: String) -> [MarkdownDecoration] {
        let text = source as NSString
        let all = NSRange(location: 0, length: text.length)
        var result: [MarkdownDecoration] = []
        var fenced: [NSRange] = []
        var opening: (range: NSRange, fence: String)?
        let fences = matches(#"(?m)^ {0,3}(`{3,}|~{3,})[^\r\n]*(?:\r?\n|$)"#, in: source)
        for match in fences {
            let fence = text.substring(with: match.range(at: 1))
            if let start = opening {
                if fence.first == start.fence.first, fence.count >= start.fence.count {
                    let range = NSRange(location: start.range.location, length: NSMaxRange(match.range) - start.range.location)
                    let content = NSRange(location: NSMaxRange(start.range), length: match.range.location - NSMaxRange(start.range))
                    result.append(MarkdownDecoration(kind: .code, range: range, content: content,
                                                     markers: [start.range, match.range], isBlock: true))
                    fenced.append(range)
                    opening = nil
                }
            } else { opening = (match.range, fence) }
        }
        if let start = opening {
            let range = NSRange(location: start.range.location, length: text.length - start.range.location)
            result.append(MarkdownDecoration(kind: .code, range: range,
                                             content: NSRange(location: NSMaxRange(start.range), length: text.length - NSMaxRange(start.range)),
                                             markers: [start.range], isBlock: true))
            fenced.append(range)
        }
        var rules: [NSRange] = []
        func outsideCode(_ range: NSRange) -> Bool { !(fenced + rules).contains { NSIntersectionRange($0, range).length > 0 } }
        // Setext headings take precedence over thematic breaks. A lone hyphen is
        // an unfinished list marker while editing, not a heading underline.
        for match in matches(#"(?m)^ {0,3}([^\s>#|][^\r\n]*)\r?\n {0,3}(=+|-{2,})[ \t]*(?=\r?$)"#, in: source) where outsideCode(match.range) {
            let content = match.range(at: 1)
            let title = text.substring(with: content)
            guard title.range(of: #"^(?:[-+*][ \t]+|\d{1,9}[.)][ \t]+)"#, options: .regularExpression) == nil else { continue }
            let level = text.substring(with: match.range(at: 2)).hasPrefix("=") ? 1 : 2
            let marker = NSRange(location: NSMaxRange(content), length: NSMaxRange(match.range) - NSMaxRange(content))
            result.append(MarkdownDecoration(kind: .heading(level), range: match.range, content: content,
                markers: [marker], isBlock: true))
            rules.append(marker)
        }
        for table in MarkdownTable.parse(source, excluding: fenced + rules) {
            result.append(MarkdownDecoration(kind: .table(table), range: table.range, content: table.range,
                                             markers: [table.range], isBlock: true))
            rules.append(table.range)
        }
        for match in matches(#"(?m)^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})\r?$"#, in: source) where outsideCode(match.range) {
            result.append(MarkdownDecoration(kind: .horizontalRule, range: match.range, content: match.range,
                                             markers: [match.range], isBlock: true))
            rules.append(match.range)
        }
        for match in matches(#"(?m)^ {0,3}(#{1,6})[ \t]+([^\r\n]+)"#, in: source) where outsideCode(match.range) {
            let content = match.range(at: 2)
            result.append(MarkdownDecoration(kind: .heading(match.range(at: 1).length), range: match.range,
                                             content: content, markers: [NSRange(location: match.range.location, length: content.location - match.range.location)], isBlock: true))
        }
        for match in matches(#"(?m)^[ \t]*((?:>[ \t]?)+)"#, in: source) where outsideCode(match.range) {
            let paragraph = text.paragraphRange(for: match.range)
            result.append(MarkdownDecoration(kind: .quote, range: paragraph, content: paragraph,
                                             markers: [match.range], isBlock: true))
        }
        for match in matches(#"(?m)^[ \t]*([-+*])[ \t]+(?:\[([ xX])\](?:[ \t]+|(?=\r?$)))?"#, in: source) where outsideCode(match.range) {
            let check = match.range(at: 2)
            let checked: Bool? = check.location == NSNotFound ? nil : text.substring(with: check).lowercased() == "x"
            let start = match.range(at: 1).location
            let prefix = NSRange(location: start, length: NSMaxRange(match.range) - start)
            let paragraph = text.paragraphRange(for: match.range)
            result.append(MarkdownDecoration(kind: .list(checked), range: paragraph, content: paragraph,
                                             markers: [prefix], isBlock: true))
        }
        for match in matches(#"(?m)^[ \t]*(\d{1,9}[.)])[ \t]+"#, in: source) where outsideCode(match.range) {
            let paragraph = text.paragraphRange(for: match.range)
            result.append(MarkdownDecoration(kind: .orderedList, range: paragraph, content: paragraph,
                                             markers: [], isBlock: true))
        }
        for match in matches(#"(?m)^ {0,3}\[\^([^\]\s]+)\]:[ \t]*(.*)$"#, in: source) where outsideCode(match.range) {
            result.append(MarkdownDecoration(kind: .footnoteDefinition(text.substring(with: match.range(at: 1))),
                range: match.range, content: match.range(at: 2), markers: [], isBlock: true))
        }
        var inlineCode: [NSRange] = []
        for match in matches(#"(?<!\\)(`+)([^`\r\n]+)\1"#, in: source) where outsideCode(match.range) {
            let content = match.range(at: 2)
            result.append(MarkdownDecoration(kind: .code, range: match.range, content: content,
                                             markers: edges(of: match.range, around: content), isBlock: false))
            inlineCode.append(match.range)
        }
        for match in matches(#"(?<!\\)\[\^([^\]\s]+)\](?!:)"#, in: source)
            where outsideCode(match.range) && !inlineCode.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            let content = match.range(at: 1)
            result.append(MarkdownDecoration(kind: .footnoteReference(text.substring(with: content)),
                range: match.range, content: content, markers: edges(of: match.range, around: content), isBlock: false))
        }
        let inlineRules: [(String, MarkdownDecoration.Kind)] = [
            (#"(?<!\\)(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, .strong),
            (#"(?<![\\*])\*([^*\r\n]+)\*(?!\*)"#, .emphasis),
            (#"(?<![\\\w])_([^_\r\n]+)_(?!\w)"#, .emphasis),
            (#"(?<!\\)(~~)([^\r\n]+?)\1"#, .strike),
            (#"(?i)(?<!\\)<u>([^\r\n]+?)</u>"#, .underline)
        ]
        for (pattern, kind) in inlineRules {
            for match in matches(pattern, in: source) where outsideCode(match.range)
                && !inlineCode.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                let content = match.range(at: match.numberOfRanges - 1)
                result.append(MarkdownDecoration(kind: kind, range: match.range, content: content,
                                                 markers: edges(of: match.range, around: content), isBlock: false))
            }
        }
        for match in matches(#"(?<!\\)!\[([^\]\r\n]*)\]\((?:<([^>\r\n]+)>|([^\s)]+))(?:[ \t]+[\"'][^\r\n]*?[\"'])?\)"#, in: source)
            where outsideCode(match.range) && !inlineCode.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            let path = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            result.append(MarkdownDecoration(kind: .image(text.substring(with: path)), range: match.range,
                                             content: match.range(at: 1), markers: [match.range], isBlock: false))
        }
        // Be conservative with wiki targets inside indented or multiline code.
        let wikiCode = matches(#"(?s)(?<!`)(`+)(?!`)(.*?)\1(?!`)"#, in: source).map(\.range)
            + matches(#"(?m)^(?: {4}|\t)[^\r\n]*"#, in: source).map(\.range)
        for match in matches(#"(?<![\\!\[])\[\[([^\[\]|\r\n]+)(?:\|([^\[\]\r\n]+))?\]\]"#, in: source)
            where outsideCode(match.range) && !(inlineCode + wikiCode).contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            let target = text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            let content = match.range(at: 2).location == NSNotFound ? match.range(at: 1) : match.range(at: 2)
            result.append(MarkdownDecoration(kind: .wikiLink(target), range: match.range, content: content,
                                             markers: edges(of: match.range, around: content), isBlock: false))
        }
        for match in matches(#"(?<!!)(?<![\\\[])\[((?:\\.|[^\]\\\r\n])+)\]\((?:<([^>\r\n]+)>|((?:[^\s()]|\([^()\r\n]*\))+))(?:[ \t]+["'][^\r\n]*?["'])?\)"#, in: source)
            where outsideCode(match.range) && !inlineCode.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            let content = match.range(at: 1)
            let destination = match.range(at: 2).location == NSNotFound ? match.range(at: 3) : match.range(at: 2)
            result.append(MarkdownDecoration(kind: .link(text.substring(with: destination)), range: match.range, content: content,
                                             markers: edges(of: match.range, around: content), isBlock: false))
        }
        return result.filter { NSMaxRange($0.range) <= NSMaxRange(all) }
    }

    static func isActive(_ range: NSRange, selection: NSRange) -> Bool {
        if selection.length == 0 { return selection.location >= range.location && selection.location <= NSMaxRange(range) }
        return NSIntersectionRange(range, selection).length > 0
    }

    private static func edges(of range: NSRange, around content: NSRange) -> [NSRange] {
        [NSRange(location: range.location, length: content.location - range.location),
         NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content))]
    }

    private static func matches(_ pattern: String, in source: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: source, range: NSRange(location: 0, length: source.utf16.count))
    }
}

struct MarkdownTable {
    let range: NSRange
    let rows: [[String]]
    let alignments: [NSTextAlignment]

    static func cells(in line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|"), !value.hasSuffix("\\|") { value.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in value {
            if escaped {
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else if character == "|" { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func parse(_ source: String, excluding excluded: [NSRange]) -> [MarkdownTable] {
        let text = source as NSString
        var lines: [(range: NSRange, text: String)] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { value, range, _, _ in
            lines.append((range, value ?? ""))
        }
        let delimiter = try! NSRegularExpression(pattern: #"^:?-{3,}:?$"#)
        var result: [MarkdownTable] = []
        var index = 0
        while index + 1 < lines.count {
            let header = lines[index]
            let separator = lines[index + 1]
            let headings = cells(in: header.text)
            let dividers = cells(in: separator.text)
            guard header.text.contains("|"), separator.text.contains("|"), headings.count == dividers.count,
                  dividers.allSatisfy({ delimiter.firstMatch(in: $0, range: NSRange(location: 0, length: $0.utf16.count)) != nil }),
                  !excluded.contains(where: { NSIntersectionRange($0, NSRange(location: header.range.location,
                      length: NSMaxRange(separator.range) - header.range.location)).length > 0 }) else { index += 1; continue }
            var rows = [headings]
            var end = NSMaxRange(separator.range)
            index += 2
            while index < lines.count, lines[index].text.contains("|"),
                  !excluded.contains(where: { NSIntersectionRange($0, lines[index].range).length > 0 }) {
                let values = cells(in: lines[index].text)
                rows.append(Array((values + Array(repeating: "", count: headings.count)).prefix(headings.count)))
                end = NSMaxRange(lines[index].range)
                index += 1
            }
            result.append(MarkdownTable(range: NSRange(location: header.range.location, length: end - header.range.location),
                rows: rows, alignments: dividers.map {
                    $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .right) : .left
                }))
        }
        return result
    }
}

/// A table is a source-preserving preview, like the existing image preview.
/// Selecting any part of its source returns the whole table to editable Markdown.
struct MarkdownTablePreview {
    let table: MarkdownTable
    let width: CGFloat
    let rowHeights: [CGFloat]
    let cells: [[NSAttributedString]]
    var height: CGFloat { rowHeights.reduce(0, +) }

    init(table: MarkdownTable, width: CGFloat) {
        self.table = table
        self.width = max(40, width)
        let cellWidth = max(1, self.width / CGFloat(table.alignments.count) - 16)
        cells = table.rows.enumerated().map { row, values in
            values.enumerated().map { column, value in
                let style = NSMutableParagraphStyle()
                style.alignment = table.alignments[column]
                let rendered = NSMutableAttributedString(string: value, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: row == 0 ? .semibold : .regular),
                    .foregroundColor: NSColor(NordTheme.text), .paragraphStyle: style
                ])
                // Keep inline formatting in cells without invoking an HTML renderer.
                var hidden = IndexSet()
                for item in LiveMarkdownPlan.decorations(in: value) {
                    switch item.kind {
                    case .strong: rendered.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold), range: item.content)
                    case .emphasis: rendered.addAttribute(.obliqueness, value: 0.2, range: item.content)
                    case .strike: rendered.addAttribute(.strikethroughStyle, value: 1, range: item.content)
                    case .underline: rendered.addAttribute(.underlineStyle, value: 1, range: item.content)
                    case .code: rendered.addAttribute(.foregroundColor, value: NSColor(NordTheme.accent), range: item.content)
                    default: continue
                    }
                    for marker in item.markers { hidden.insert(integersIn: marker.location..<NSMaxRange(marker)) }
                }
                for range in hidden.rangeView.reversed() { rendered.deleteCharacters(in: NSRange(range)) }
                return rendered
            }
        }
        rowHeights = cells.map { row in
            max(32, row.map { ceil($0.boundingRect(with: NSSize(width: cellWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 16 }.max() ?? 32)
        }
    }

    func draw(at origin: NSPoint) {
        let columnWidth = width / CGFloat(table.alignments.count)
        var y = origin.y
        for (row, height) in rowHeights.enumerated() {
            if row == 0 {
                NSColor(NordTheme.surface).setFill()
                NSRect(x: origin.x, y: y, width: width, height: height).fill()
            }
            for column in table.alignments.indices {
                let rect = NSRect(x: origin.x + CGFloat(column) * columnWidth, y: y, width: columnWidth, height: height)
                NSColor(NordTheme.border).setStroke()
                NSBezierPath(rect: rect).stroke()
                cells[row][column].draw(with: rect.insetBy(dx: 8, dy: 8), options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
            y += height
        }
    }
}

enum MarkdownLink {
    static func resolve(_ destination: String, folder: URL?) -> URL? {
        guard let url = URL(string: destination) else { return nil }
        if let scheme = url.scheme?.lowercased() {
            return ["https", "http", "mailto"].contains(scheme) ? url : nil
        }
        guard !destination.hasPrefix("//"), let folder else { return nil }
        return URL(string: destination, relativeTo: folder.appendingPathComponent("", isDirectory: true))?.absoluteURL
    }
}

enum MarkdownCodeHighlighter {
    enum Role { case keyword, string, number, comment }
    struct Token { let range: NSRange; let role: Role }

    static func tokens(in source: String, language: String) -> [Token] {
        let language = language.lowercased()
        let aliases = ["js": "javascript", "ts": "typescript", "py": "python", "sh": "bash",
                       "shell": "bash", "c++": "cpp", "c#": "csharp", "yml": "yaml"]
        let name = aliases[language] ?? language
        let supported = ["swift", "javascript", "typescript", "python", "json", "bash", "sql", "css", "html", "xml",
                         "c", "cpp", "csharp", "java", "kotlin", "rust", "go", "ruby", "yaml"]
        guard supported.contains(name) else { return [] }
        let hashComments = ["python", "bash", "ruby", "yaml"].contains(name)
        let markup = ["html", "xml"].contains(name)
        let comment: String
        if markup { comment = #"<!--[\s\S]*?(?:-->|$)"# }
        else if name == "json" { comment = #"(?!)"# }
        else if name == "sql" { comment = #"--[^\r\n]*|/\*[\s\S]*?(?:\*/|$)"# }
        else if hashComments { comment = #"#[^\r\n]*"# }
        else { comment = #"//[^\r\n]*|/\*[\s\S]*?(?:\*/|$)"# }
        let strings = #""""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$)|"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|`(?:\\.|[^`\\])*`"#
        let pattern = "(?<comment>" + comment + ")|(?<string>" + strings
            + #")|(?<number>\b(?:0[xX][\da-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b)|(?<word>[A-Za-z_$][\w$]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let words = Set(("actor any as async await associatedtype break case catch class const continue def default defer delete do dyn "
            + "else enum except export extends extension false False final finally fn for from func function get guard if impl import in init "
            + "interface internal is lambda let match module mut namespace new nil None null of open override package private protocol pub public "
            + "raise readonly ref repeat required return self Self set some static struct super switch this throw throws trait true True try "
            + "type typealias typeof undefined union use using val var virtual void when where while with yield "
            + "SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER ON AS INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE DROP ALTER GROUP BY ORDER HAVING LIMIT AND OR NOT NULL TRUE FALSE").components(separatedBy: " "))
        return regex.matches(in: source, range: NSRange(location: 0, length: source.utf16.count)).compactMap { match in
            for (group, role) in [("comment", Role.comment), ("string", .string), ("number", .number)] {
                let range = match.range(withName: group)
                if range.location != NSNotFound { return Token(range: range, role: role) }
            }
            let range = match.range(withName: "word")
            let word = (source as NSString).substring(with: range)
            if words.contains(word) || (name == "sql" && words.contains(word.uppercased())) || markup && source.utf16.count > range.location && range.location > 0 && (source as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) == "<" {
                return Token(range: range, role: .keyword)
            }
            return nil
        }
    }

    static func apply(to storage: NSTextStorage, content: NSRange, language: String) {
        let source = (storage.string as NSString).substring(with: content)
        for token in tokens(in: source, language: language) {
            let color: NSColor
            switch token.role {
            case .keyword: color = NSColor(calibratedRed: 0.71, green: 0.56, blue: 0.68, alpha: 1)
            case .string: color = NSColor(calibratedRed: 0.64, green: 0.75, blue: 0.55, alpha: 1)
            case .number: color = NSColor(calibratedRed: 0.82, green: 0.62, blue: 0.45, alpha: 1)
            case .comment: color = NSColor(NordTheme.muted)
            }
            storage.addAttribute(.foregroundColor, value: color,
                range: NSRange(location: content.location + token.range.location, length: token.range.length))
        }
    }
}

enum LocalMarkdownImage {
    static func resolve(_ path: String, in folder: URL) -> URL? {
        guard !path.hasPrefix("/"), !path.contains("\\"), URL(string: path)?.scheme == nil,
              let decoded = path.removingPercentEncoding else { return nil }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
        guard file != root, file.pathComponents.starts(with: root.pathComponents),
              let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image), type != .svg else { return nil }
        return file
    }
}

final class LiveMarkdownLayout: NSLayoutManager, NSLayoutManagerDelegate {
    var hiddenCharacters = IndexSet()
    var replacements: [Int: UniChar] = [:]
    var images: [Int: NSImage] = [:]
    var horizontalRules = IndexSet()
    var checkboxes: [Int: (checked: Bool, stateRange: NSRange)] = [:]
    var tables: [Int: MarkdownTablePreview] = [:]
    var quotes: [NSRange] = []
    var imageWidth: CGFloat = 400

    override init() { super.init(); delegate = self }
    required init?(coder: NSCoder) { super.init(coder: coder); delegate = self }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        var generated = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var flags = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        for index in 0..<glyphRange.length {
            let character = characterIndexes[index]
            if images[character] != nil || tables[character] != nil || horizontalRules.contains(character) || checkboxes[character] != nil {
                generated[index] = 0
                flags[index] = .controlCharacter
            } else if var replacement = replacements[character] {
                var glyph: CGGlyph = 0
                if CTFontGetGlyphsForCharacters(font as CTFont, &replacement, &glyph, 1) { generated[index] = glyph }
            } else if hiddenCharacters.contains(character) {
                flags[index] = .null
            }
        }
        generated.withUnsafeBufferPointer { glyphBuffer in
            flags.withUnsafeBufferPointer { flagBuffer in
                setGlyphs(glyphBuffer.baseAddress!, properties: flagBuffer.baseAddress!,
                          characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            }
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        images[charIndex] != nil || tables[charIndex] != nil || horizontalRules.contains(charIndex) || checkboxes[charIndex] != nil ? .whitespace : action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        if checkboxes[charIndex] != nil { return NSRect(x: 0, y: -12, width: 16, height: 14) }
        if let table = tables[charIndex] {
            return NSRect(x: 0, y: -table.height + 4, width: table.width, height: table.height)
        }
        if horizontalRules.contains(charIndex) {
            return NSRect(x: 0, y: -14, width: max(1, proposedRect.width - 2 * textContainer.lineFragmentPadding), height: 18)
        }
        guard let image = images[charIndex], image.size.width > 0, image.size.height > 0 else { return .zero }
        let availableWidth = max(1, min(imageWidth, proposedRect.width - 10))
        let scale = min(1, availableWidth / image.size.width, 600 / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        return NSRect(x: 0, y: -height + 4, width: width, height: height)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let container = textContainers.first else { return }
        NSColor(NordTheme.accent).setFill()
        for rect in quoteBarRects(forGlyphRange: glyphsToShow) {
            rect.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
        for (character, table) in tables {
            let glyph = glyphIndexForCharacter(at: character)
            guard NSLocationInRange(glyph, glyphsToShow) else { continue }
            let rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            table.draw(at: NSPoint(x: origin.x + rect.minX, y: origin.y + rect.minY))
        }
        for (character, checkbox) in checkboxes {
            let glyph = glyphIndexForCharacter(at: character)
            guard NSLocationInRange(glyph, glyphsToShow), let rect = checkboxRect(at: character) else { continue }
            let box = rect.offsetBy(dx: origin.x, dy: origin.y)
            NSColor(NordTheme.accent).setStroke()
            let outline = NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.5
            outline.stroke()
            if checkbox.checked {
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + 3, y: box.midY))
                check.line(to: NSPoint(x: box.minX + 6, y: box.maxY - 4))
                check.line(to: NSPoint(x: box.maxX - 3, y: box.minY + 4))
                check.lineWidth = 1.5
                check.stroke()
            }
        }
        for character in horizontalRules {
            let glyph = glyphIndexForCharacter(at: character)
            guard NSLocationInRange(glyph, glyphsToShow) else { continue }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            NSColor(NordTheme.muted).setFill()
            NSRect(x: origin.x + line.minX + container.lineFragmentPadding,
                   y: origin.y + line.midY, width: max(0, line.width - 2 * container.lineFragmentPadding),
                   height: 1).fill()
        }
        for (character, image) in images {
            let glyph = glyphIndexForCharacter(at: character)
            guard NSLocationInRange(glyph, glyphsToShow) else { continue }
            let bounds = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            guard image.size.width > 0, image.size.height > 0 else { continue }
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let rect = NSRect(x: bounds.minX, y: bounds.minY,
                              width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    func quoteBarRects(forGlyphRange visibleGlyphs: NSRange) -> [NSRect] {
        guard let container = textContainers.first, let storage = textStorage else { return [] }
        let source = storage.string as NSString
        var result: [NSRect] = []
        for range in quotes {
            // Hidden '>' markers can share a glyph boundary with the preceding
            // paragraph. Anchor the bar to the quote's visible content instead.
            var first = range.location
            while first < NSMaxRange(range), hiddenCharacters.contains(first) { first += 1 }
            guard first < NSMaxRange(range) else { continue }
            var end = NSMaxRange(range)
            while end > first + 1, [10, 13].contains(source.character(at: end - 1)) { end -= 1 }
            let firstGlyph = glyphIndexForCharacter(at: first)
            let lastGlyph = glyphIndexForCharacter(at: end - 1)
            let line = source.substring(with: range)
            let depth = max(1, line.prefix(while: { $0 == ">" || $0 == " " || $0 == "\t" }).filter { $0 == ">" }.count)
            var glyph = firstGlyph
            while glyph <= lastGlyph {
                var fragment = NSRange()
                let rect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragment)
                if NSIntersectionRange(fragment, visibleGlyphs).length > 0 {
                    for level in 0..<depth {
                        result.append(NSRect(x: container.lineFragmentPadding + 4 + CGFloat(level) * 24,
                            y: rect.minY, width: 3, height: rect.height))
                    }
                }
                guard NSMaxRange(fragment) > glyph else { break }
                glyph = NSMaxRange(fragment)
            }
        }
        return result
    }

    func checkboxRect(at character: Int) -> NSRect? {
        guard checkboxes[character] != nil else { return nil }
        let glyph = glyphIndexForCharacter(at: character)
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let position = location(forGlyphAt: glyph)
        return NSRect(x: line.minX + position.x, y: line.midY - 7, width: 14, height: 14)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        for (character, table) in tables where NSLocationInRange(character, characters) {
            lineFragmentRect.pointee.size.height = max(lineFragmentRect.pointee.height, table.height)
            lineFragmentUsedRect.pointee.size.height = max(lineFragmentUsedRect.pointee.height, table.height)
            baselineOffset.pointee = max(baselineOffset.pointee, table.height - 4)
        }
        for (character, image) in images where NSLocationInRange(character, characters) {
            guard image.size.width > 0, image.size.height > 0 else { continue }
            let width = max(1, min(imageWidth, lineFragmentRect.pointee.width - 10))
            let scale = min(1, width / image.size.width, 600 / image.size.height)
            let height = image.size.height * scale
            lineFragmentRect.pointee.size.height = max(lineFragmentRect.pointee.height, height)
            lineFragmentUsedRect.pointee.size.height = max(lineFragmentUsedRect.pointee.height, height)
            baselineOffset.pointee = max(baselineOffset.pointee, height - 4)
        }
        return true
    }
}

final class LiveMarkdownFormatter {
    private var applying = false
    private let cache = NSCache<NSURL, NSImage>()
    private var source = ""
    private var decorations: [MarkdownDecoration] = []
    private var lastSelection = NSRange(location: NSNotFound, length: 0)
    private var lastEnabled: Bool?
    private var lastFolder: URL?
    private var lastWidth: CGFloat = -1

    init() { cache.countLimit = 24 }

    func invalidate() { lastEnabled = nil }

    func apply(to editor: MarkdownTextView, enabled: Bool, folder: URL?) {
        guard !applying, !editor.hasMarkedText(), let storage = editor.textStorage,
              let layout = editor.layoutManager as? LiveMarkdownLayout else { return }
        applying = true
        defer { applying = false }
        let full = NSRange(location: 0, length: storage.length)
        let selection = editor.selectedRange()
        guard source != editor.string || selection != lastSelection || enabled != lastEnabled
                || folder != lastFolder || editor.bounds.width != lastWidth else { return }
        lastSelection = selection
        lastEnabled = enabled
        lastFolder = folder
        lastWidth = editor.bounds.width
        if source != editor.string {
            source = editor.string
            decorations = LiveMarkdownPlan.decorations(in: source)
        }
        let base = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        layout.hiddenCharacters = []
        layout.replacements = [:]
        layout.images = [:]
        layout.horizontalRules = []
        layout.checkboxes = [:]
        layout.tables = [:]
        layout.quotes = []
        editor.markdownLinks = [:]
        editor.footnoteLinks = [:]
        editor.wikiLinks = [:]
        layout.imageWidth = max(1, editor.bounds.width - 10)
        storage.beginEditing()
        storage.setAttributes([.font: base, .foregroundColor: NSColor(NordTheme.text)], range: full)
        if enabled {
            var definitions: [String: NSRange] = [:]
            var references: [String: NSRange] = [:]
            for item in decorations {
                if case .footnoteDefinition(let id) = item.kind, definitions[id] == nil { definitions[id] = item.range }
                if case .footnoteReference(let id) = item.kind, references[id] == nil { references[id] = item.range }
            }
            for item in decorations {
                let activeRange = item.isBlock ? (source as NSString).paragraphRange(for: selection) : selection
                let active = item.isBlock ? NSIntersectionRange(item.range, activeRange).length > 0
                    : LiveMarkdownPlan.isActive(item.range, selection: selection)
                switch item.kind {
                case .horizontalRule:
                    if !active { layout.horizontalRules.insert(item.range.location) }
                case .heading(let level):
                    storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: [28, 23, 20, 18, 16, 15][level - 1], weight: .semibold),
                                           .foregroundColor: NSColor(NordTheme.accent)], range: item.content)
                case .table(let table):
                    if !active {
                        layout.tables[item.range.location] = MarkdownTablePreview(table: table,
                            width: max(40, (editor.textContainer?.containerSize.width ?? editor.bounds.width) - 20))
                    }
                case .strong:
                    let existing = storage.attribute(.font, at: item.content.location, effectiveRange: nil) as? NSFont ?? base
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(existing, toHaveTrait: .boldFontMask), range: item.content)
                case .emphasis:
                    let existing = storage.attribute(.font, at: item.content.location, effectiveRange: nil) as? NSFont ?? base
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(existing, toHaveTrait: .italicFontMask), range: item.content)
                case .code:
                    storage.addAttributes([.foregroundColor: NSColor(NordTheme.accent), .backgroundColor: NSColor(NordTheme.sidebar)], range: item.content)
                    if item.isBlock, let opening = item.markers.first {
                        let fence = (source as NSString).substring(with: opening).trimmingCharacters(in: .whitespacesAndNewlines)
                        let language = fence.drop(while: { $0 == "`" || $0 == "~" }).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                        MarkdownCodeHighlighter.apply(to: storage, content: item.content, language: language)
                    }
                case .strike:
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: item.content)
                case .underline:
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: item.content)
                case .quote:
                    storage.addAttribute(.foregroundColor, value: NSColor(NordTheme.muted), range: item.content)
                    let style = NSMutableParagraphStyle()
                    let prefix = (source as NSString).substring(with: item.markers[0])
                    let indent = CGFloat(prefix.filter { $0 == ">" }.count) * 24
                    style.firstLineHeadIndent = indent
                    style.headIndent = indent
                    storage.addAttribute(.paragraphStyle, value: style, range: item.range)
                    layout.quotes.append(item.range)
                case .link(let destination):
                    storage.addAttributes([.foregroundColor: NSColor(NordTheme.accent),
                                           .underlineStyle: NSUnderlineStyle.single.rawValue], range: item.content)
                    if let url = MarkdownLink.resolve(destination, folder: folder) {
                        storage.addAttribute(.link, value: url, range: item.content)
                        editor.markdownLinks[item.content] = url
                    }
                case .wikiLink(let target):
                    storage.addAttributes([.foregroundColor: NSColor(NordTheme.accent),
                        .underlineStyle: NSUnderlineStyle.single.rawValue], range: item.content)
                    editor.wikiLinks[item.content] = target
                case .footnoteReference(let id):
                    storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                        .baselineOffset: 5, .foregroundColor: NSColor(NordTheme.accent)], range: item.content)
                    if let target = definitions[id] { editor.footnoteLinks[item.content] = target }
                case .footnoteDefinition(let id):
                    let label = NSRange(location: item.range.location, length: item.content.location - item.range.location)
                    storage.addAttributes([.foregroundColor: NSColor(NordTheme.accent),
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)], range: label)
                    let style = NSMutableParagraphStyle()
                    style.headIndent = 24
                    storage.addAttribute(.paragraphStyle, value: style, range: item.range)
                    if let target = references[id] { editor.footnoteLinks[label] = target }
                case .orderedList:
                    let line = (source as NSString).substring(with: item.range)
                    let prefixRange = (line as NSString).range(of: #"^[ \t]*\d{1,9}[.)][ \t]+"#, options: .regularExpression)
                    let prefix = (line as NSString).substring(with: prefixRange)
                    let style = NSMutableParagraphStyle()
                    let indent = CGFloat(line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }) * 9
                    style.firstLineHeadIndent = 0
                    style.headIndent = max(indent + 27, (prefix as NSString).size(withAttributes: [.font: base]).width)
                    storage.addAttribute(.paragraphStyle, value: style, range: item.range)
                case .list(let checked):
                    if !active, let marker = item.markers.first {
                        layout.replacements[marker.location] = checked.map { $0 ? 0x2611 : 0x2610 } ?? 0x2022
                        if let checked {
                            let bracket = (source as NSString).range(of: "[", options: [], range: marker)
                            layout.checkboxes[marker.location] = (checked, NSRange(location: bracket.location + 1, length: 1))
                        }
                        if marker.length > 2 {
                            let trailingSpace = (source as NSString).substring(with: NSRange(location: NSMaxRange(marker) - 1, length: 1))
                            let end = NSMaxRange(marker) - (trailingSpace == " " || trailingSpace == "\t" ? 1 : 0)
                            layout.hiddenCharacters.insert(integersIn: (marker.location + 1)..<end)
                        }
                    }
                    continue
                case .image(let path):
                    guard !active, let folder, let url = LocalMarkdownImage.resolve(path, in: folder) else { continue }
                    let image: NSImage?
                    if let cached = cache.object(forKey: url as NSURL) { image = cached }
                    else {
                        image = NSImage(contentsOf: url)
                        if let image { cache.setObject(image, forKey: url as NSURL) }
                    }
                    guard let image else { continue }
                    layout.images[item.range.location] = image
                }
                if !active {
                    for marker in item.markers { layout.hiddenCharacters.insert(integersIn: marker.location..<NSMaxRange(marker)) }
                }
            }
        }
        storage.endEditing()
        editor.typingAttributes = [.font: base, .foregroundColor: NSColor(NordTheme.text)]
        layout.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        editor.needsDisplay = true
        editor.window?.invalidateCursorRects(for: editor)
    }
}
