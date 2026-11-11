import AppKit
import XCTest
import SwiftUI

final class NativeEditorTests: XCTestCase {
    @objc func testPasteURLOverSelectionCreatesMarkdownLinkAndUndoesOnce() {
        MainActor.assumeIsolated {
            let view = MarkdownTextView(frame: .zero)
            view.isRichText = false
            view.allowsUndo = true
            view.string = "Visit Café 👩‍💻 today"
            let original = view.string
            view.setSelectedRange((original as NSString).range(of: "Café 👩‍💻"))
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("https://example.com", forType: .string)
            view.clipboard = board
            let undo = view.undoManager!
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            view.paste(nil)
            undo.endUndoGrouping()
            XCTAssertEqual(view.string, "Visit [Café 👩‍💻](https://example.com) today")
            XCTAssertEqual(view.selectedRange().length, 0)
            undo.undo()
            XCTAssertEqual(view.string, original)
            undo.redo()
            XCTAssertEqual(view.string, "Visit [Café 👩‍💻](https://example.com) today")
        }
    }

    @objc func testPasteLinkHandlesURLTypesEscapingAndParentheses() {
        MainActor.assumeIsolated {
            let view = MarkdownTextView(frame: .zero)
            view.isRichText = false
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            for (label, url, expected) in [
                ("Docs", "https://example.com/a_(b)", "[Docs](<https://example.com/a_(b)>)"),
                ("Email", "mailto:hello@example.com", "[Email](mailto:hello@example.com)"),
                ("See [docs]", "https://example.com", "[See \\[docs\\]](https://example.com)")
            ] {
                view.string = label
                view.setSelectedRange(NSRange(location: 0, length: label.utf16.count))
                board.clearContents()
                board.setString(url, forType: .URL)
                XCTAssertTrue(view.readSelection(from: board, type: .URL))
                XCTAssertEqual(view.string, expected)
                XCTAssertTrue(LiveMarkdownPlan.decorations(in: view.string).contains { if case .link = $0.kind { return true }; return false })
            }
        }
    }

    @objc func testLinkPasteLeavesPlainTextCodeAndEmptySelectionsToNormalPaste() {
        MainActor.assumeIsolated {
            let view = MarkdownTextView(frame: .zero)
            view.isRichText = false
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            for (source, selection, clipboard) in [
                ("Text", NSRange(location: 0, length: 4), "ordinary text"),
                ("Text", NSRange(location: 0, length: 4), "https://one.com https://two.com"),
                ("Text", NSRange(location: 0, length: 4), "javascript:alert(1)"),
                ("Text", NSRange(location: 0, length: 4), "https://"),
                ("Text", NSRange(location: 4, length: 0), "https://example.com"),
                ("`code`", NSRange(location: 1, length: 4), "https://example.com"),
                ("```\ncode\n```", NSRange(location: 4, length: 4), "https://example.com"),
                ("two\nlines", NSRange(location: 0, length: 9), "https://example.com")
            ] {
                view.string = source
                view.setSelectedRange(selection)
                board.clearContents()
                board.setString(clipboard, forType: .string)
                XCTAssertFalse(view.pasteMarkdownLink(from: board))
                XCTAssertEqual(view.string, source)
            }
        }
    }

    @MainActor private func reconnect(_ store: NoteStore) -> (MarkdownTextView, MarkdownEditor.Coordinator) {
        let editor = store.editorSession.textView(for: store.text)
        editor.isRichText = false
        editor.allowsUndo = true
        let bridge = MarkdownEditor(text: Binding(get: { store.text }, set: { store.text = $0 }),
                                    focusRequested: false, session: store.editorSession, livePreview: true,
                                    onFocusChange: { _ in }, importImages: { _, _, _ in false }, onError: { _ in })
        let coordinator = MarkdownEditor.Coordinator(parent: bridge)
        editor.delegate = coordinator
        NativeEditorStyle.apply(to: editor)
        coordinator.refreshPresentation(editor)
        return (editor, coordinator)
    }

    @MainActor private func edit(_ editor: MarkdownTextView, _ text: String, range: NSRange) {
        let history = editor.undoManager!
        history.groupsByEvent = false
        history.beginUndoGrouping()
        editor.insertText(text, replacementRange: range)
        history.endUndoGrouping()
    }

    @objc @MainActor func testNoteSwitchPreservesIndependentEraseUndoRedoAndSaveBaseline() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.md"), b = folder.appendingPathComponent("b.md")
        let paragraph = "# Important paragraph\nCafé 👩‍💻 日本語"
        try Data(paragraph.utf8).write(to: a)
        try Data("Note B".utf8).write(to: b)
        let store = NoteStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try store.activateFolder(folder)
        store.open(a)
        let first = reconnect(store)
        let oldScroll = MarkdownEditor.EditorScrollView()
        oldScroll.documentView = first.0
        let aID = store.editorID
        edit(first.0, "", range: NSRange(location: 0, length: paragraph.utf16.count))
        store.find()
        store.open(b)
        XCTAssertNil(store.findRequest, "Leaving a note must not replay its previous Find command")
        MarkdownEditor.dismantleNSView(oldScroll, coordinator: first.1)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "")
        let second = reconnect(store)
        edit(second.0, " edited", range: NSRange(location: 6, length: 0))
        second.0.setSelectedRange(NSRange(location: 2, length: 0))
        store.open(a)
        let returned = reconnect(store)
        XCTAssertEqual(store.editorID, aID)
        XCTAssertTrue(returned.0 === first.0)
        XCTAssertNil(store.findRequest)
        // A late teardown from the old wrapper cannot detach the new binding.
        MarkdownEditor.dismantleNSView(oldScroll, coordinator: first.1)
        returned.0.undo(nil)
        XCTAssertEqual(store.text, paragraph)
        XCTAssertTrue(store.isDirty, "Undo restores a draft, without silently rewriting the disk baseline")
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "")
        XCTAssertTrue(store.save())
        returned.0.redo(nil)
        XCTAssertEqual(store.text, "")
        returned.0.undo(nil)
        store.open(b)
        let returnedB = reconnect(store)
        XCTAssertTrue(returnedB.0 === second.0)
        XCTAssertEqual(returnedB.0.selectedRange(), NSRange(location: 2, length: 0))
        returnedB.0.undo(nil)
        XCTAssertEqual(store.text, "Note B")
        XCTAssertEqual(returned.0.string, paragraph)
        withExtendedLifetime([first.1, second.1, returned.1, returnedB.1]) {}
    }

    @objc @MainActor func testFirstSaveAndRenameKeepSessionAcrossNavigation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try store.activateFolder(folder)
        store.text = "Draft"
        let initial = reconnect(store)
        let id = store.editorID
        edit(initial.0, " addition", range: NSRange(location: 5, length: 0))
        XCTAssertTrue(store.save())
        let original = try XCTUnwrap(store.selected)
        try store.rename(original, to: "renamed.md")
        let renamed = try XCTUnwrap(store.selected)
        store.create()
        store.open(renamed)
        let returned = reconnect(store)
        XCTAssertEqual(store.editorID, id)
        XCTAssertTrue(initial.0 === returned.0)
        returned.0.undo(nil)
        XCTAssertEqual(store.text, "Draft")
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "Draft addition")
        withExtendedLifetime([initial.1, returned.1]) {}
    }

    @objc @MainActor func testExternalTextChangeResetsOnlyThatNotesUndoHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("a.md")
        try Data("Original".utf8).write(to: url)
        let store = NoteStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try store.activateFolder(folder)
        store.open(url)
        let initial = reconnect(store)
        edit(initial.0, " edited", range: NSRange(location: 8, length: 0))
        store.create() // Saves and leaves the note.
        try Data("External replacement".utf8).write(to: url)
        store.open(url)
        let returned = reconnect(store)
        XCTAssertFalse(returned.0.undoManager!.canUndo)
        returned.0.undo(nil)
        XCTAssertEqual(store.text, "External replacement")
        XCTAssertFalse(store.isDirty)
        withExtendedLifetime([initial.1, returned.1]) {}
    }

    @objc @MainActor func testDeletionRestoreKeepsTextUndoForCapturedUnsavedDraft() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("a.md")
        try Data("Saved text".utf8).write(to: url)
        let store = NoteStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                              trashNote: { url, _ in try FileManager.default.removeItem(at: url) })
        try store.activateFolder(folder)
        store.open(url)
        let initial = reconnect(store)
        edit(initial.0, " unsaved", range: NSRange(location: 10, length: 0))
        store.deleteFromSidebar()
        store.restoreDeletedNote()
        let restored = reconnect(store)
        XCTAssertTrue(initial.0 === restored.0)
        XCTAssertEqual(store.text, "Saved text unsaved")
        restored.0.undo(nil)
        XCTAssertEqual(store.text, "Saved text")
        XCTAssertFalse(store.isDirty)
        XCTAssertTrue(restored.0.undoManager!.canRedo)
        withExtendedLifetime([initial.1, restored.1]) {}
    }

    @objc func testNativeFindBarOpensAndClosesWithoutChangingTextOrUndo() {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            let editor = MarkdownTextView(frame: scroll.bounds)
            editor.isRichText = false
            editor.allowsUndo = true
            editor.string = "needle café needle 日本語"
            scroll.documentView = editor
            window.contentView = scroll
            NativeEditorStyle.apply(to: editor)
            window.makeFirstResponder(editor)
            let source = editor.string
            let history = editor.undoManager!
            history.groupsByEvent = false
            history.beginUndoGrouping()
            editor.insertText("!", replacementRange: NSRange(location: source.utf16.count, length: 0))
            history.endUndoGrouping()
            let edited = editor.string
            let pasteboard = NSPasteboard(name: .find)
            let previousQuery = pasteboard.string(forType: .string)
            defer {
                pasteboard.clearContents()
                if let previousQuery { pasteboard.setString(previousQuery, forType: .string) }
            }
            pasteboard.clearContents()
            pasteboard.setString("needle", forType: .string)
            func find(_ action: NSTextFinder.Action) {
                let item = NSMenuItem()
                item.tag = action.rawValue
                editor.performTextFinderAction(item)
            }
            editor.setSelectedRange(NSRange(location: 0, length: 6))
            find(.setSearchString)
            find(.showFindInterface)
            XCTAssertTrue(scroll.isFindBarVisible)
            // Native match selection requires an active GUI/key window, which
            // this command-line test runner cannot acquire. Verify it manually.
            editor.cancelOperation(nil)
            XCTAssertFalse(scroll.isFindBarVisible)
            XCTAssertEqual(editor.string, edited)
            XCTAssertTrue(history.canUndo)
            editor.undo(nil)
            XCTAssertEqual(editor.string, source)
        }
    }

    @objc func testStandardUndoRedoActionsRestoreErasedTextAndDraftBinding() {
        MainActor.assumeIsolated {
            var draft = "# My written note\nCafé 👩‍💻 日本語"
            let original = draft
            let bridge = MarkdownEditor(text: Binding(get: { draft }, set: { draft = $0 }),
                                        focusRequested: false, livePreview: true,
                                        onFocusChange: { _ in }, importImages: { _, _, _ in false },
                                        onError: { _ in })
            let coordinator = MarkdownEditor.Coordinator(parent: bridge)
            let storage = NSTextStorage()
            let layout = LiveMarkdownLayout()
            let container = NSTextContainer(size: NSSize(width: 600, height: 400))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400),
                                          textContainer: container)
            editor.isRichText = false
            editor.allowsUndo = true
            editor.string = draft
            editor.delegate = coordinator
            coordinator.refreshPresentation(editor)
            let history = editor.undoManager!
            history.groupsByEvent = false
            history.beginUndoGrouping()
            editor.setSelectedRange(NSRange(location: 0, length: original.utf16.count))
            editor.deleteBackward(nil)
            history.endUndoGrouping()
            XCTAssertEqual(editor.string, "")
            XCTAssertEqual(draft, "")
            XCTAssertTrue(history.canUndo)
            // Exercise the standard responder action, rather than calling
            // UndoManager directly (which concealed the broken menu routing).
            XCTAssertTrue(editor.responds(to: NSSelectorFromString("undo:")))
            XCTAssertTrue(editor.tryToPerform(NSSelectorFromString("undo:"), with: nil))
            XCTAssertEqual(editor.string, original)
            XCTAssertEqual(draft, original)
            XCTAssertTrue(history.canRedo)
            XCTAssertTrue(editor.tryToPerform(NSSelectorFromString("redo:"), with: nil))
            XCTAssertEqual(editor.string, "")
            XCTAssertEqual(draft, "")
            XCTAssertTrue(editor.tryToPerform(NSSelectorFromString("undo:"), with: nil))
            XCTAssertEqual(draft, original)
        }
    }

    @objc func testUnchangedTextNotificationsDoNotRepublishDraft() {
        MainActor.assumeIsolated {
            var draft = "# Saved note"
            var publications = 0
            let bridge = MarkdownEditor(text: Binding(get: { draft }, set: {
                draft = $0
                publications += 1
            }), focusRequested: false, livePreview: true,
            onFocusChange: { _ in }, importImages: { _, _, _ in false }, onError: { _ in })
            let coordinator = MarkdownEditor.Coordinator(parent: bridge)
            let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            editor.string = draft
            editor.delegate = coordinator
            let notification = Notification(name: NSText.didChangeNotification, object: editor)
            // Repeated native notifications for model-driven/attribute-only updates
            // must not echo through the SwiftUI binding.
            coordinator.textDidChange(notification)
            coordinator.textDidChange(notification)
            XCTAssertEqual(publications, 0)
            editor.string = "Actual edit"
            coordinator.textDidChange(notification)
            XCTAssertEqual(draft, "Actual edit")
            XCTAssertEqual(publications, 1)
            coordinator.textDidChange(notification)
            XCTAssertEqual(publications, 1)
        }
    }

    @objc func testListContinuationAndExitPreserveUndo() {
        MainActor.assumeIsolated {
            for (source, prefix) in [("- Café 👩‍💻", "- "), ("* item", "* "), ("+ item", "+ "),
                                     ("1. item", "2. "), ("9) item", "10) "),
                                     ("  - nested", "  - "), ("- [ ] task", "- [ ] "), ("- [x] done", "- [ ] ")] {
                let view = MarkdownTextView(frame: .zero)
                view.isRichText = false
                view.allowsUndo = true
                view.string = source
                view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
                let undo = view.undoManager!
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                view.insertNewline(nil)
                undo.endUndoGrouping()
                let continued = source + "\n" + prefix
                XCTAssertEqual(view.string, continued)
                XCTAssertEqual(view.selectedRange().location, continued.utf16.count)
                undo.beginUndoGrouping()
                view.insertNewline(nil)
                undo.endUndoGrouping()
                let indent = String(prefix.prefix(while: { $0 == " " || $0 == "\t" }))
                XCTAssertEqual(view.string, source + "\n" + indent)
                undo.undo()
                XCTAssertEqual(view.string, continued)
                undo.undo()
                XCTAssertEqual(view.string, source)
                undo.redo()
                XCTAssertEqual(view.string, continued)
            }
        }
    }

    @objc func testTabAndBacktabNestListsAndContinueTheirMarkers() {
        MainActor.assumeIsolated {
            for (source, nested, next, rootNext) in [("- Café 👩‍💻", "- Café 👩‍💻", "- ", "- "),
                ("* item", "* item", "* ", "* "), ("- [x] task", "- [x] task", "- [ ] ", "- [ ] "),
                ("1. item", "1. item", "2. ", "1. "), ("9) item", "1) item", "2) ", "1) ")] {
                let view = MarkdownTextView(frame: .zero)
                view.isRichText = false
                view.allowsUndo = true
                view.string = source
                view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
                let undo = view.undoManager!
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                view.insertTab(nil)
                undo.endUndoGrouping()
                XCTAssertEqual(view.string, "    " + nested)
                XCTAssertEqual(view.selectedRange().location, nested.utf16.count + 4)
                undo.undo()
                XCTAssertEqual(view.string, source)
                undo.redo()
                XCTAssertEqual(view.string, "    " + nested)
                view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
                undo.beginUndoGrouping()
                view.insertNewline(nil)
                undo.endUndoGrouping()
                XCTAssertEqual(view.string, "    " + nested + "\n    " + next)
                undo.beginUndoGrouping()
                view.insertBacktab(nil)
                undo.endUndoGrouping()
                XCTAssertEqual(view.string, "    " + nested + "\n" + rootNext)
            }
        }
    }

    @objc func testNumberedListTabRestartsAndBacktabContinuesParentWithUndo() {
        MainActor.assumeIsolated {
            for (source, nested, restored) in [
                ("1. a\n2. b\n3. Café 👩‍💻", "1. a\n2. b\n    1. Café 👩‍💻", "1. a\n2. b\n3. Café 👩‍💻"),
                ("8) a\n9) b\n10) c", "8) a\n9) b\n    1) c", "8) a\n9) b\n10) c"),
                ("1. a\n    1. b\n2. c", "1. a\n    1. b\n    2. c", "1. a\n    1. b\n2. c")
            ] {
                let view = MarkdownTextView(frame: .zero)
                view.isRichText = false
                view.allowsUndo = true
                view.string = source
                view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
                let undo = view.undoManager!
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                view.insertTab(nil)
                undo.endUndoGrouping()
                XCTAssertEqual(view.string, nested)
                XCTAssertEqual(view.selectedRange().location, nested.utf16.count)
                undo.beginUndoGrouping()
                view.insertBacktab(nil)
                undo.endUndoGrouping()
                XCTAssertEqual(view.string, restored)
                XCTAssertEqual(view.selectedRange().location, restored.utf16.count)
                undo.undo()
                XCTAssertEqual(view.string, nested)
                undo.undo()
                XCTAssertEqual(view.string, source)
            }
        }
    }

    @objc func testNumberedListSelectionAndOutdentSkipDescendants() {
        MainActor.assumeIsolated {
            let view = MarkdownTextView(frame: .zero)
            view.isRichText = false
            let source = "1. a\n2. b\n3. c\n4. d"
            view.string = source
            let start = (source as NSString).range(of: "3. c").location
            view.setSelectedRange(NSRange(location: start, length: source.utf16.count - start))
            view.insertTab(nil)
            XCTAssertEqual(view.string, "1. a\n2. b\n    1. c\n    2. d")
            view.insertBacktab(nil)
            XCTAssertEqual(view.string, source)
            for (source, expected) in [
                ("1. a\n2. b\n    1. c\n    2. d", "1. a\n2. b\n    1. c\n3. d"),
                ("1. a\n2. b\n\t1. c", "1. a\n2. b\n3. c"),
                ("1. old\n\nNew paragraph\n    7. c", "1. old\n\nNew paragraph\n1. c")
            ] {
                view.string = source
                view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
                view.insertBacktab(nil)
                XCTAssertEqual(view.string, expected)
            }
        }
    }

    @objc func testListIndentSelectionAndMixedWhitespaceOutdent() {
        MainActor.assumeIsolated {
            let view = MarkdownTextView(frame: .zero)
            view.isRichText = false
            let source = "- first\n- [ ] second\nplain"
            view.string = source
            let selection = NSRange(location: 2, length: 18)
            view.setSelectedRange(selection)
            view.insertTab(nil)
            XCTAssertEqual(view.string, "    - first\n    - [ ] second\nplain")
            view.insertBacktab(nil)
            XCTAssertEqual(view.string, source)
            XCTAssertEqual(view.selectedRange(), selection)
            for (source, expected) in [("\t- item", "- item"), ("  - item", "- item"), ("- item", "- item")] {
                view.string = source
                view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
                view.insertBacktab(nil)
                XCTAssertEqual(view.string, expected)
            }
        }
    }

    @objc func testListContinuationSplitsTextAndSkipsCode() {
        MainActor.assumeIsolated {
            for (source, selection, expected) in [
                ("- first second", NSRange(location: 8, length: 0), "- first \n- second"),
                ("- first second", NSRange(location: 8, length: 6), "- first \n- "),
                ("plain", NSRange(location: 5, length: 0), "plain\n"),
                ("---", NSRange(location: 3, length: 0), "---\n"),
                ("```\n- code\n```", NSRange(location: 10, length: 0), "```\n- code\n\n```")
            ] {
                let view = MarkdownTextView(frame: .zero)
                view.isRichText = false
                view.string = source
                view.setSelectedRange(selection)
                view.insertNewline(nil)
                XCTAssertEqual(view.string, expected)
            }
        }
    }

    private final class UndoableTextView: NSTextView {
        let testUndoManager = UndoManager()
        override var undoManager: UndoManager? { testUndoManager }
    }

    @objc func testStylePreservesLongUnicodeTextAndSelection() {
        MainActor.assumeIsolated {
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            let line = "# Café 👩‍💻\n日本語 — مرحبا\n`let value = 42`\n"
            let original = String(repeating: line, count: 5_000)
            editor.string = original
            let selection = (original as NSString).range(of: "👩‍💻")
            editor.setSelectedRange(selection)
            for _ in 0..<3 { NativeEditorStyle.apply(to: editor) }
            XCTAssertEqual(editor.string, original)
            XCTAssertEqual(editor.selectedRange(), selection)
        }
    }

    @objc func testStylePreservesNativeTypingUndoAndRedo() {
        MainActor.assumeIsolated {
            let editor = UndoableTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            editor.isRichText = false
            editor.allowsUndo = true
            editor.string = "Café ☕️"
            let original = editor.string
            let caret = NSRange(location: original.utf16.count, length: 0)
            editor.setSelectedRange(caret)
            let undo = editor.testUndoManager
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            editor.insertText("\n# Heading", replacementRange: caret)
            undo.endUndoGrouping()
            let edited = editor.string
            let selection = editor.selectedRange()
            NativeEditorStyle.apply(to: editor)
            XCTAssertEqual(editor.string, edited)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertTrue(undo.canUndo)
            undo.undo()
            XCTAssertEqual(editor.string, original)
            undo.redo()
            XCTAssertEqual(editor.string, edited)
        }
    }

    @objc func testStylePreservesMarkedTextComposition() {
        MainActor.assumeIsolated {
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            editor.isRichText = false
            editor.string = "Draft "
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: editor.selectedRange())
            XCTAssertTrue(editor.hasMarkedText())
            let text = editor.string
            let selection = editor.selectedRange()
            let marked = editor.markedRange()
            NativeEditorStyle.apply(to: editor)
            XCTAssertEqual(editor.string, text)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(editor.markedRange(), marked)
            XCTAssertTrue(editor.hasMarkedText())
        }
    }
}
