import AppKit
import SwiftUI
import XCTest

final class ImageInsertionTests: XCTestCase {
    private final class UndoableMarkdownView: MarkdownTextView {
        let testUndoManager = UndoManager()
        override var undoManager: UndoManager? { testUndoManager }
    }

    private var folder: URL!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try FileManager.default.removeItem(at: folder)
    }

    private func connect(_ editor: MarkdownTextView) {
        editor.isRichText = false
        editor.importImages = { [folder] inputs, editor, range in
            do {
                let assets = try ImageAssetService().importImages(inputs, into: folder!)
                editor.insertText(assets.map(\.markdown).joined(separator: "\n"), replacementRange: range)
                return true
            } catch { return false }
        }
    }

    @objc func testClipboardImageReplacesSelectionWithUndoAndRedo() {
        MainActor.assumeIsolated {
            let editor = UndoableMarkdownView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            connect(editor)
            editor.allowsUndo = true
            let original = "Café 👩‍💻 end"
            editor.string = original
            let range = (original as NSString).range(of: "👩‍💻")
            editor.setSelectedRange(range)
            pasteboard.declareTypes([.png], owner: nil)
            pasteboard.setData(imageFixture(), forType: .png)
            editor.clipboard = pasteboard
            let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            XCTAssertTrue(editor.validateUserInterfaceItem(pasteItem), "Image clipboard must enable Paste/⌘V")
            let undo = editor.testUndoManager
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            editor.paste(nil)
            undo.endUndoGrouping()
            let filename = try! FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("imgs").path)[0]
            XCTAssertNotNil(filename.range(of: "^screenshot-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\\.png$", options: .regularExpression))
            let pasted = "Café ![image](imgs/\(filename)) end"
            XCTAssertEqual(editor.string, pasted)
            undo.undo()
            XCTAssertEqual(editor.string, original)
            undo.redo()
            XCTAssertEqual(editor.string, pasted)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("imgs/\(filename)").path))
        }
    }

    @objc func testFileDropImportsMultipleImagesAtCaret() throws {
        try MainActor.assumeIsolated {
            let first = folder.appendingPathComponent("First.png")
            let second = folder.appendingPathComponent("Second.png")
            try imageFixture().write(to: first)
            try imageFixture().write(to: second)
            pasteboard.writeObjects([first as NSURL, second as NSURL])
            let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            connect(editor)
            editor.string = "Before\nAfter"
            XCTAssertTrue(editor.insertImages(from: pasteboard, at: NSRange(location: 7, length: 0)))
            XCTAssertEqual(editor.string, "Before\n![image](imgs/first.png)\n![image](imgs/second.png)After")
            XCTAssertEqual(try Data(contentsOf: first), imageFixture())
            XCTAssertEqual(try Data(contentsOf: second), imageFixture())
        }
    }

    @objc func testInvalidImageLeavesTextAndSelectionUntouched() {
        MainActor.assumeIsolated {
            let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            connect(editor)
            editor.string = "Existing draft"
            let selection = NSRange(location: 2, length: 4)
            editor.setSelectedRange(selection)
            pasteboard.declareTypes([.png], owner: nil)
            pasteboard.setData(Data("not an image".utf8), forType: .png)
            XCTAssertFalse(editor.insertImages(from: pasteboard, at: selection))
            XCTAssertEqual(editor.string, "Existing draft")
            XCTAssertEqual(editor.selectedRange(), selection)
        }
    }

    @objc func testImageInsertionDoesNotInterruptMarkedText() {
        MainActor.assumeIsolated {
            let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            connect(editor)
            editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: 0, length: 0))
            let text = editor.string
            let marked = editor.markedRange()
            pasteboard.declareTypes([.png], owner: nil)
            pasteboard.setData(imageFixture(), forType: .png)
            XCTAssertFalse(editor.insertImages(from: pasteboard, at: editor.selectedRange()))
            XCTAssertEqual(editor.string, text)
            XCTAssertEqual(editor.markedRange(), marked)
        }
    }

    @objc func testNativeInsertionUpdatesDraftBinding() {
        MainActor.assumeIsolated {
            var draft = "Café "
            let bridge = MarkdownEditor(text: Binding(get: { draft }, set: { draft = $0 }),
                                        focusRequested: false, onFocusChange: { _ in },
                                        importImages: { _, _, _ in false }, onError: { _ in })
            let coordinator = MarkdownEditor.Coordinator(parent: bridge)
            let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            editor.isRichText = false
            editor.delegate = coordinator
            editor.string = draft
            editor.insertText("![image](imgs/photo.png)", replacementRange: NSRange(location: draft.utf16.count, length: 0))
            XCTAssertEqual(draft, "Café ![image](imgs/photo.png)")
            XCTAssertEqual(draft, editor.string)
        }
    }

    @objc func testUndoHistoriesAreSeparateBetweenNotes() {
        MainActor.assumeIsolated {
            let first = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            let second = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            for editor in [first, second] {
                editor.isRichText = false
                editor.allowsUndo = true
                editor.string = "Original"
                let undo = editor.undoManager!
                undo.groupsByEvent = false
                undo.beginUndoGrouping()
                editor.insertText(" edited", replacementRange: NSRange(location: 8, length: 0))
                undo.endUndoGrouping()
            }
            second.undoManager!.undo()
            XCTAssertEqual(second.string, "Original")
            XCTAssertEqual(first.string, "Original edited")
            XCTAssertTrue(first.undoManager!.canUndo)
        }
    }

}
