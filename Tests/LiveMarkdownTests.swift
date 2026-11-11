import AppKit
import XCTest

final class LiveMarkdownTests: XCTestCase {
    @objc func testWikiLinksParseAliasesSkipCodeAndNavigateInsideApp() {
        let source = "[[Café 👩‍💻]] and [[Other note.md|Read more]]\n`[[inline]]`\n```\n[[block]]\n```\n\\[[escaped]] ![[embed]]\n\nEnd"
        let links = LiveMarkdownPlan.decorations(in: source).filter { if case .wikiLink = $0.kind { return true }; return false }
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.map { (source as NSString).substring(with: $0.content) }, ["Café 👩‍💻", "Read more"])
        MainActor.assumeIsolated {
            let view = editor(source)
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertEqual(view.wikiLinks.count, 2)
            var opened: String?
            view.onOpenNoteLink = { opened = $0 }
            XCTAssertTrue(view.activateMarkdownLink(at: links[0].content.location) { _ in XCTFail("Note links must stay inside the app"); return false })
            XCTAssertEqual(opened, "Café 👩‍💻")
            XCTAssertTrue(view.activateMarkdownLink(at: links[1].content.location))
            XCTAssertEqual(opened, "Other note.md")
            let layout = view.layoutManager as! LiveMarkdownLayout
            XCTAssertTrue(layout.hiddenCharacters.contains(links[1].range.location))
            view.setSelectedRange(NSRange(location: links[1].content.location, length: 0))
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertFalse(layout.hiddenCharacters.contains(links[1].range.location))
            formatter.apply(to: view, enabled: false, folder: nil)
            XCTAssertTrue(view.wikiLinks.isEmpty)
            XCTAssertEqual(view.string, source)
        }
    }

    private func editor(_ source: String) -> MarkdownTextView {
        let storage = NSTextStorage()
        let layout = LiveMarkdownLayout()
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.isRichText = false
        view.allowsUndo = true
        view.string = source
        view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        return view
    }

    @objc func testDecorationPlanUsesUTF16AndExcludesCode() {
        let source = "👩‍💻 **bold**\n\n```\n**literal**\n```\n\n`**also literal**`"
        let plan = LiveMarkdownPlan.decorations(in: source)
        let strong = plan.filter { if case .strong = $0.kind { return true }; return false }
        XCTAssertEqual(strong.count, 1)
        XCTAssertEqual((source as NSString).substring(with: strong[0].content), "bold")
        XCTAssertEqual(strong[0].range, (source as NSString).range(of: "**bold**"))
    }

    @objc func testUnderlineRendersAlongsideBoldStrikeAndRule() {
        MainActor.assumeIsolated {
            let source = "**bold** <u>Café 👩‍💻</u> ~~old~~\n\n---\n\nEnd"
            let view = editor(source)
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: nil)
            let storage = view.textStorage!
            let text = source as NSString
            let bold = text.range(of: "bold").location
            XCTAssertTrue(NSFontManager.shared.traits(of: storage.attribute(.font, at: bold, effectiveRange: nil) as! NSFont).contains(.boldFontMask))
            let underline = text.range(of: "Café").location
            let struck = text.range(of: "~~old~~").location + 2
            XCTAssertEqual(storage.attribute(.underlineStyle, at: underline, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
            XCTAssertEqual(storage.attribute(.strikethroughStyle, at: struck, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
            let layout = view.layoutManager as! LiveMarkdownLayout
            XCTAssertEqual(layout.horizontalRules.count, 1)
            let tag = text.range(of: "<u>").location
            XCTAssertTrue(layout.hiddenCharacters.contains(tag))
            view.setSelectedRange(NSRange(location: underline, length: 0))
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertFalse(layout.hiddenCharacters.contains(tag))
            formatter.apply(to: view, enabled: false, folder: nil)
            XCTAssertNil(storage.attribute(.underlineStyle, at: underline, effectiveRange: nil))
            XCTAssertNil(storage.attribute(.strikethroughStyle, at: struck, effectiveRange: nil))
            XCTAssertEqual(view.string, source)
        }
    }

    @objc func testUnderlineExcludesCodeAndEscapedTags() {
        let source = "<u>yes</u> `<u>inline</u>`\n```\n<u>block</u>\n```\n\\<u>escaped</u>"
        let underlines = LiveMarkdownPlan.decorations(in: source).filter {
            if case .underline = $0.kind { return true }
            return false
        }
        XCTAssertEqual(underlines.count, 1)
        XCTAssertEqual(underlines.first.map { (source as NSString).substring(with: $0.content) }, "yes")
    }

    @objc func testFormattingPreservesSourceCaretAndUndo() {
        MainActor.assumeIsolated {
            let view = editor("# Heading\n\nCafé 👩‍💻")
            let original = view.string
            let undo = view.undoManager!
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            view.insertText(" **bold**", replacementRange: view.selectedRange())
            undo.endUndoGrouping()
            let edited = view.string
            let caret = view.selectedRange()
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: nil)
            formatter.apply(to: view, enabled: false, folder: nil)
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertEqual(view.string, edited)
            XCTAssertEqual(view.selectedRange(), caret)
            undo.undo()
            XCTAssertEqual(view.string, original)
            formatter.apply(to: view, enabled: true, folder: nil)
            undo.redo()
            XCTAssertEqual(view.string, edited)
        }
    }

    @objc func testInactiveSyntaxIsHiddenAndCursorRevealsIt() {
        MainActor.assumeIsolated {
            let view = editor("**bold**\n\nEnd")
            let formatter = LiveMarkdownFormatter()
            let layout = view.layoutManager as! LiveMarkdownLayout
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertTrue(layout.hiddenCharacters.contains(0))
            layout.ensureLayout(for: view.textContainer!)
            let glyph = layout.glyphIndexForCharacter(at: 0)
            XCTAssertTrue(layout.propertyForGlyph(at: glyph).contains(.null))
            view.setSelectedRange(NSRange(location: 3, length: 0))
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertFalse(layout.hiddenCharacters.contains(0))
            XCTAssertEqual(view.string, "**bold**\n\nEnd")
        }
    }

    @objc func testSourceModeRestoresAllGlyphs() {
        MainActor.assumeIsolated {
            let view = editor("# Heading\n\n**bold** *italic* `code` ~~old~~\n\nEnd")
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: nil)
            let layout = view.layoutManager as! LiveMarkdownLayout
            XCTAssertFalse(layout.hiddenCharacters.isEmpty)
            formatter.apply(to: view, enabled: false, folder: nil)
            XCTAssertTrue(layout.hiddenCharacters.isEmpty)
            XCTAssertTrue(layout.images.isEmpty)
            XCTAssertEqual((view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 15)
        }
    }

    @objc func testHorizontalRulesAndEmptyCheckboxes() {
        MainActor.assumeIsolated {
            for source in ["Above\n\n---\nBelow", "Above\n\n---\n\nBelow", "Above\n\n---"] {
                let view = editor(source)
                view.setSelectedRange(NSRange(location: 0, length: 0))
                LiveMarkdownFormatter().apply(to: view, enabled: true, folder: nil)
                let layout = view.layoutManager as! LiveMarkdownLayout
                layout.ensureLayout(for: view.textContainer!)
                let character = (source as NSString).range(of: "---").location
                let glyph = layout.glyphIndexForCharacter(at: character)
                let above = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                let divider = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                XCTAssertGreaterThanOrEqual(divider.minY, above.maxY)
                XCTAssertGreaterThanOrEqual(divider.height, 18)
                XCTAssertTrue(layout.propertyForGlyph(at: glyph).contains(.controlCharacter))
            }
            let source = "---\n\n* * *\n\n___\n\n- [ ]\n- [x]\n\n```\n---\n```\n\nEnd"
            let view = editor(source)
            let formatter = LiveMarkdownFormatter()
            let layout = view.layoutManager as! LiveMarkdownLayout
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertEqual(layout.horizontalRules.count, 3)
            let unchecked = (source as NSString).range(of: "- [ ]")
            let checked = (source as NSString).range(of: "- [x]")
            XCTAssertEqual(layout.replacements[unchecked.location], 0x2610)
            XCTAssertEqual(layout.replacements[checked.location], 0x2611)
            XCTAssertTrue(layout.hiddenCharacters.contains(NSMaxRange(unchecked) - 1))
            XCTAssertEqual(view.string, source)
            view.setSelectedRange(NSRange(location: 1, length: 0))
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertFalse(layout.horizontalRules.contains(0))
            XCTAssertFalse(layout.hiddenCharacters.contains(0))
            formatter.apply(to: view, enabled: false, folder: nil)
            XCTAssertTrue(layout.horizontalRules.isEmpty)
            XCTAssertTrue(layout.replacements.isEmpty)
        }
    }

    @objc func testSetextHeadingsTakePrecedenceOverDividersAndSkipCode() {
        let source = "Café 👩‍💻\n===\n\nSubtitle\n---\n\n---\n\n```\nLiteral\n===\n```"
        let plan = LiveMarkdownPlan.decorations(in: source)
        let headings = plan.compactMap { item -> Int? in
            if case .heading(let level) = item.kind { return level }
            return nil
        }
        XCTAssertEqual(headings, [1, 2])
        XCTAssertEqual(plan.filter { if case .horizontalRule = $0.kind { return true }; return false }.count, 1)
        let mixed = LiveMarkdownPlan.decorations(in: "**Title**\n===\n\n1. Item\n---")
        XCTAssertEqual(mixed.filter { if case .heading = $0.kind { return true }; return false }.count, 1)
        XCTAssertEqual(mixed.filter { if case .strong = $0.kind { return true }; return false }.count, 1)
        XCTAssertEqual(mixed.filter { if case .horizontalRule = $0.kind { return true }; return false }.count, 1)
        MainActor.assumeIsolated {
            let view = editor(source + "\n\nEnd")
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertEqual((view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 28)
            let marker = (source as NSString).range(of: "===").location
            XCTAssertTrue((view.layoutManager as! LiveMarkdownLayout).hiddenCharacters.contains(marker))
            view.setSelectedRange(NSRange(location: marker, length: 0))
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertFalse((view.layoutManager as! LiveMarkdownLayout).hiddenCharacters.contains(marker))
        }
    }

    @objc func testEmptyHyphenListDoesNotRestylePrecedingParagraph() {
        MainActor.assumeIsolated {
            for source in ["feijoada\n-", "feijoada\n- ", "feijoada\n-\t", "Café 👩‍💻\r\n  - "] {
                let plan = LiveMarkdownPlan.decorations(in: source)
                XCTAssertFalse(plan.contains { if case .heading = $0.kind { return true }; return false })
                let view = editor(source)
                let selection = view.selectedRange()
                let formatter = LiveMarkdownFormatter()
                formatter.apply(to: view, enabled: true, folder: nil)
                XCTAssertEqual((view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 15)
                XCTAssertEqual(view.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                               NSColor(NordTheme.text))
                XCTAssertEqual(view.string, source)
                XCTAssertEqual(view.selectedRange(), selection)
                XCTAssertFalse(view.undoManager!.canUndo)
            }
            // Removing a second underline hyphen must also clear existing heading styling.
            let view = editor("feijoada\n--")
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertEqual((view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 23)
            let last = NSRange(location: view.string.utf16.count - 1, length: 1)
            view.insertText(" ", replacementRange: last)
            let selection = view.selectedRange()
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertEqual(view.string, "feijoada\n- ")
            XCTAssertEqual((view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 15)
            XCTAssertEqual(view.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                           NSColor(NordTheme.text))
            XCTAssertEqual(view.selectedRange(), selection)
            view.undoManager!.undo()
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertEqual(view.string, "feijoada\n--")
            XCTAssertEqual((view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 23)
        }
    }

    @objc func testTablesParseAlignmentEscapesAndUnevenRows() {
        let source = "| Name | Count | Note |\n| :--- | ---: | :---: |\n| Café \\| tea | 2 | **yes** |\n| short |\n\nEnd"
        let tables = MarkdownTable.parse(source, excluding: [])
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables.first?.alignments, [.left, .right, .center])
        XCTAssertEqual(tables.first?.rows[1], ["Café | tea", "2", "**yes**"])
        XCTAssertEqual(tables.first?.rows[2], ["short", "", ""])
        XCTAssertTrue(MarkdownTable.parse("a | b\n-- | ---", excluding: []).isEmpty)
        XCTAssertTrue(MarkdownTable.parse("a | b\n--- | --- | ---", excluding: []).isEmpty)
        let fenced = "```\n" + source + "\n```"
        XCTAssertFalse(LiveMarkdownPlan.decorations(in: fenced).contains { if case .table = $0.kind { return true }; return false })
    }

    @objc func testTablePreviewReservesSpaceRevealsSourceAndResizes() {
        MainActor.assumeIsolated {
            let source = "| Name | Count |\n| --- | ---: |\n| Café 👩‍💻 with a long wrapped cell | 2 |\n\nEnd"
            let view = editor(source)
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: nil)
            let layout = view.layoutManager as! LiveMarkdownLayout
            XCTAssertEqual(layout.tables.count, 1)
            layout.ensureLayout(for: view.textContainer!)
            let preview = layout.tables[0]!
            let glyph = layout.glyphIndexForCharacter(at: 0)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer!)
            XCTAssertGreaterThanOrEqual(rect.height, preview.height)
            let following = layout.glyphIndexForCharacter(at: (source as NSString).range(of: "End").location)
            XCTAssertGreaterThanOrEqual(layout.lineFragmentRect(forGlyphAt: following, effectiveRange: nil).minY, rect.maxY)
            let narrow = MarkdownTablePreview(table: preview.table, width: 150)
            XCTAssertGreaterThan(narrow.height, preview.height)
            XCTAssertTrue(view.revealMarkdownTable(at: NSPoint(x: rect.midX + view.textContainerOrigin.x,
                                                               y: rect.midY + view.textContainerOrigin.y)))
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertTrue(layout.tables.isEmpty)
            XCTAssertEqual(view.string, source)
            view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
            formatter.apply(to: view, enabled: false, folder: nil)
            XCTAssertTrue(layout.hiddenCharacters.isEmpty)
        }
    }

    @objc func testWikiLinksRenderAndRemainNavigableInsideTablePreview() {
        let source = """
        | Page | Inside |
        | --- | --- |
        | [[Field Notes]] | A small plan for a slower Saturday |
        | [[Reading List]] | A few books to come back to |
        | [[Tiny Swift Snippet]] | A cheerful little bit of code |
        """
        let table = MarkdownTable.parse(source, excluding: []).first!
        let preview = MarkdownTablePreview(table: table, width: 600)

        for (row, target) in ["Field Notes", "Reading List", "Tiny Swift Snippet"].enumerated() {
            let rendered = preview.cells[row + 1][0]
            XCTAssertEqual(rendered.string, target)
            XCTAssertNotNil(rendered.attribute(.underlineStyle, at: 0, effectiveRange: nil))
            XCTAssertEqual(preview.noteLinkTarget(at: NSPoint(
                x: 12, y: preview.rowHeights[0...row].reduce(0, +) + 12)), target)
        }
    }

    @objc func testLinksResolveAndActivateWithoutOpeningApplicationsInTests() {
        MainActor.assumeIsolated {
            let source = "[Docs](https://example.com/a_(b)) [Note](<other%20note.md>) [Bad](javascript:alert)\n\nEnd"
            let view = editor(source)
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: URL(fileURLWithPath: "/tmp/notes", isDirectory: true))
            XCTAssertEqual(view.markdownLinks.count, 2)
            var opened: URL?
            XCTAssertTrue(view.activateMarkdownLink(at: 1) { opened = $0; return true })
            XCTAssertEqual(opened?.absoluteString, "https://example.com/a_(b)")
            let note = (source as NSString).range(of: "Note").location
            XCTAssertTrue(view.activateMarkdownLink(at: note) { opened = $0; return true })
            XCTAssertEqual(opened?.path, "/tmp/notes/other note.md")
            XCTAssertFalse(view.activateMarkdownLink(at: (source as NSString).range(of: "Bad").location) { _ in XCTFail(); return true })
            formatter.apply(to: view, enabled: false, folder: nil)
            XCTAssertTrue(view.markdownLinks.isEmpty)
            XCTAssertNil(view.textStorage!.attribute(.link, at: 1, effectiveRange: nil))
        }
        XCTAssertNil(MarkdownLink.resolve("data:text/html,test", folder: nil))
        XCTAssertNotNil(MarkdownLink.resolve("mailto:hello@example.com", folder: nil))
    }

    @objc func testFootnotesNavigateBothWaysAndIgnoreCodeOrMissingDefinitions() {
        MainActor.assumeIsolated {
            let source = "Text[^note] and [^missing]. `[^code]`\n\n[^note]: Café explanation\n\nEnd"
            let view = editor(source)
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: nil)
            let reference = (source as NSString).range(of: "[^note]")
            let definition = (source as NSString).range(of: "[^note]: Café explanation")
            XCTAssertEqual(view.footnoteLinks.count, 2)
            XCTAssertTrue(view.activateMarkdownLink(at: reference.location + 2))
            XCTAssertEqual(view.selectedRange(), definition)
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertTrue(view.activateMarkdownLink(at: definition.location))
            XCTAssertEqual(view.selectedRange(), reference)
            XCTAssertFalse(view.activateMarkdownLink(at: (source as NSString).range(of: "missing").location))
            XCTAssertEqual(view.string, source)
            formatter.apply(to: view, enabled: false, folder: nil)
            XCTAssertTrue(view.footnoteLinks.isEmpty)
        }
    }

    @objc func testNumberedListsAndWrappedBlockquotesHaveParagraphLayout() {
        MainActor.assumeIsolated {
            let source = "1. First\n    2) Nested\n\n> A long quote that wraps across lines\n\nEnd"
            let view = editor(source)
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: nil)
            let style = view.textStorage!.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertGreaterThan(style?.headIndent ?? 0, 0)
            let quote = (source as NSString).range(of: "> ").location
            let quoteStyle = view.textStorage!.attribute(.paragraphStyle, at: quote, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(quoteStyle?.headIndent, 24)
            let layout = view.layoutManager as! LiveMarkdownLayout
            XCTAssertEqual(layout.quotes.count, 1)
            formatter.apply(to: view, enabled: false, folder: nil)
            XCTAssertTrue(layout.quotes.isEmpty)
            XCTAssertNil(view.textStorage!.attribute(.paragraphStyle, at: quote, effectiveRange: nil))
            XCTAssertEqual(view.string, source)
        }
    }

    @objc func testQuoteBarsStayInsideQuotedLines() {
        MainActor.assumeIsolated {
            for source in ["Above\n> Quote\nBelow", "Above\n\n> Quote\n\nBelow",
                           "Above\n> A long quote that wraps across several lines in a narrow editor.\nBelow",
                           "Above\n>\n> > Nested 👩‍💻\nBelow", "Above\n> Quote 👩‍💻"] {
                let view = editor(source)
                view.textContainer!.containerSize.width = 180
                view.setSelectedRange(NSRange(location: 0, length: 0))
                let formatter = LiveMarkdownFormatter()
                formatter.apply(to: view, enabled: true, folder: nil)
                let layout = view.layoutManager as! LiveMarkdownLayout
                layout.ensureLayout(for: view.textContainer!)
                let allGlyphs = NSRange(location: 0, length: layout.numberOfGlyphs)
                let bars = layout.quoteBarRects(forGlyphRange: allGlyphs)
                XCTAssertFalse(bars.isEmpty, source)
                let above = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                for bar in bars {
                    XCTAssertGreaterThanOrEqual(bar.minY, above.maxY, source)
                }
                let below = (source as NSString).range(of: "Below")
                if below.location != NSNotFound {
                    let glyph = layout.glyphIndexForCharacter(at: below.location)
                    let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    for bar in bars { XCTAssertLessThanOrEqual(bar.maxY, rect.minY, source) }
                }
                // Every visual line of a quote has a bar, including wrapped text.
                let quote = (source as NSString).range(of: "Quote")
                if quote.location != NSNotFound {
                    let glyph = layout.glyphIndexForCharacter(at: quote.location)
                    let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    XCTAssertTrue(bars.contains { $0.minY == rect.minY && $0.height == rect.height })
                }
                XCTAssertEqual(view.string, source)
            }
        }
    }

    @objc func testFencedCodeHighlightingKeepsStringsCommentsAndUTF16RangesSeparate() {
        let source = "let café = \"👩‍💻 // not a comment\" // let 42\nlet count = 123"
        let tokens = MarkdownCodeHighlighter.tokens(in: source, language: "swift")
        func values(_ role: MarkdownCodeHighlighter.Role) -> [String] {
            tokens.filter { $0.role == role }.map { (source as NSString).substring(with: $0.range) }
        }
        XCTAssertEqual(values(.keyword), ["let", "let"])
        XCTAssertEqual(values(.string), ["\"👩‍💻 // not a comment\""])
        XCTAssertEqual(values(.comment), ["// let 42"])
        XCTAssertEqual(values(.number), ["123"])
        XCTAssertTrue(MarkdownCodeHighlighter.tokens(in: source, language: "unknown").isEmpty)
        XCTAssertFalse(MarkdownCodeHighlighter.tokens(in: "def x(): # comment", language: "py").isEmpty)
        MainActor.assumeIsolated {
            let markdown = "```swift\n" + source + "\n```\n\nEnd"
            let view = editor(markdown)
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: nil)
            let keyword = (markdown as NSString).range(of: "let").location
            let number = (markdown as NSString).range(of: "123").location
            XCTAssertNotEqual(view.textStorage!.attribute(.foregroundColor, at: keyword, effectiveRange: nil) as? NSColor,
                              view.textStorage!.attribute(.foregroundColor, at: number, effectiveRange: nil) as? NSColor)
            XCTAssertEqual(view.string, markdown)
        }
    }

    @objc func testImageWidgetHasLayoutWithoutChangingMarkdown() throws {
        try MainActor.assumeIsolated {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("imgs"), withIntermediateDirectories: true)
            try imageFixture(width: 200, height: 100).write(to: folder.appendingPathComponent("imgs/photo.png"))
            let source = "![image](imgs/photo.png)\n\nEnd"
            let view = editor(source)
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: folder)
            let layout = view.layoutManager as! LiveMarkdownLayout
            XCTAssertNotNil(layout.images[0])
            layout.ensureLayout(for: view.textContainer!)
            let glyph = layout.glyphIndexForCharacter(at: 0)
            let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer!)
            XCTAssertGreaterThan(bounds.width, 100)
            XCTAssertGreaterThan(bounds.height, 50)
            XCTAssertEqual(view.string, source)
            for size in [NSSize(width: 800, height: 2400), NSSize(width: 2400, height: 800)] {
                layout.images[0] = NSImage(size: size)
                let imageBounds = layout.layoutManager(layout, boundingBoxForControlGlyphAt: glyph,
                    for: view.textContainer!, proposedLineFragment: NSRect(x: 0, y: 0, width: 300, height: 20),
                    glyphPosition: .zero, characterIndex: 0)
                XCTAssertEqual(imageBounds.width / imageBounds.height, size.width / size.height, accuracy: 0.001)
                XCTAssertLessThanOrEqual(imageBounds.width, 290)
                XCTAssertLessThanOrEqual(imageBounds.height, 600)
            }
            view.setSelectedRange(NSRange(location: 3, length: 0))
            formatter.apply(to: view, enabled: true, folder: folder)
            XCTAssertNil(layout.images[0], "Entering the image reveals its editable Markdown")
            XCTAssertFalse(layout.hiddenCharacters.contains(0))
        }
    }

    @objc func testListAndCheckboxGlyphsAreDecorations() {
        MainActor.assumeIsolated {
            let source = "- item\n- [x] done\n- [ ] pending\n\nEnd"
            let view = editor(source)
            LiveMarkdownFormatter().apply(to: view, enabled: true, folder: nil)
            let layout = view.layoutManager as! LiveMarkdownLayout
            XCTAssertEqual(layout.replacements.values.sorted(), [0x2022, 0x2610, 0x2611])
            XCTAssertEqual(view.string, source)
            let formatter = LiveMarkdownFormatter()
            let unchecked = (source as NSString).range(of: "- [ ]").location
            let checked = (source as NSString).range(of: "- [x]").location
            layout.ensureLayout(for: view.textContainer!)
            for character in [unchecked, checked] {
                let glyph = layout.glyphIndexForCharacter(at: character)
                XCTAssertTrue(layout.propertyForGlyph(at: glyph).contains(.controlCharacter))
                let rect = layout.checkboxRect(at: character)!
                let caret = view.selectedRange()
                let before = view.string
                view.undoManager!.groupsByEvent = false
                view.undoManager!.beginUndoGrouping()
                XCTAssertTrue(view.toggleCheckbox(at: NSPoint(x: rect.midX + view.textContainerOrigin.x,
                                                              y: rect.midY + view.textContainerOrigin.y)))
                view.undoManager!.endUndoGrouping()
                XCTAssertNotEqual(view.string, before)
                XCTAssertEqual(view.selectedRange(), caret)
                formatter.apply(to: view, enabled: true, folder: nil)
                XCTAssertEqual(layout.checkboxes[character]?.checked, character == unchecked)
                view.undoManager!.undo()
                XCTAssertEqual(view.string, before)
                formatter.apply(to: view, enabled: true, folder: nil)
                layout.ensureLayout(for: view.textContainer!)
            }
        }
    }

    @objc func testMarkedTextClearsFoldingAndKeepsComposition() {
        MainActor.assumeIsolated {
            let view = editor("**bold**\n\n")
            let formatter = LiveMarkdownFormatter()
            formatter.apply(to: view, enabled: true, folder: nil)
            let layout = view.layoutManager as! LiveMarkdownLayout
            XCTAssertFalse(layout.hiddenCharacters.isEmpty)
            view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
            let marked = view.markedRange()
            let source = view.string
            formatter.apply(to: view, enabled: true, folder: nil)
            XCTAssertTrue(layout.hiddenCharacters.isEmpty)
            XCTAssertEqual(view.markedRange(), marked)
            XCTAssertEqual(view.string, source)
        }
    }

    @objc func testLongUnicodeDocumentAndHeadingFont() {
        MainActor.assumeIsolated {
            let source = "# Title\n\n" + String(repeating: "Café 👩‍💻 日本語 **bold**\n", count: 2_000) + "\nEnd"
            let view = editor(source)
            LiveMarkdownFormatter().apply(to: view, enabled: true, folder: nil)
            XCTAssertEqual(view.string, source)
            XCTAssertEqual((view.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as! NSFont).pointSize, 28)
        }
    }
}

final class LocalMarkdownImageTests: XCTestCase {
    @objc func testRelativePathsAndPercentEncodedNames() {
        let root = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        XCTAssertEqual(LocalMarkdownImage.resolve("imgs/photo.png", in: root)?.path, "/tmp/notes/imgs/photo.png")
        XCTAssertEqual(LocalMarkdownImage.resolve("imgs/my%20photo.png", in: root)?.lastPathComponent, "my photo.png")
    }

    @objc func testRejectsOutsideAndUnsupportedReferences() {
        let root = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        for path in ["../outside.png", "%2e%2e/outside.png", "/tmp/outside.png", "https://example.com/photo.png", "imgs/script.svg", "note.md"] {
            XCTAssertNil(LocalMarkdownImage.resolve(path, in: root), path)
        }
    }

    @objc func testSymlinkCannotEscapeNotesFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.png")
        try imageFixture().write(to: outside)
        try FileManager.default.createSymbolicLink(at: notes.appendingPathComponent("link.png"), withDestinationURL: outside)
        XCTAssertNil(LocalMarkdownImage.resolve("link.png", in: notes))
    }
}
