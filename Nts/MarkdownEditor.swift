import AppKit
import SwiftUI

/// Retains the native text view because AppKit undo entries target that view.
/// A new SwiftUI wrapper can reconnect it without losing its undo/redo stack.
final class NoteEditorSession {
    let id = UUID()
    private var editor: MarkdownTextView?
    var hasMarkedText: Bool { editor?.hasMarkedText() ?? false }

    var currentText: String? { editor?.string }

    func applyWikiEdits(_ edits: [WikiLinkEdit]) {
        guard let editor else { return }
        let selection = editor.selectedRange()
        func mapped(_ point: Int) -> Int {
            var delta = 0
            for edit in edits.sorted(by: { $0.location < $1.location }) {
                if point < edit.location { break }
                if point <= edit.location + edit.length {
                    return edit.location + delta + min(point - edit.location, edit.replacement.utf16.count)
                }
                delta += edit.replacement.utf16.count - edit.length
            }
            return point + delta
        }
        // Detached sessions can retain a former SwiftUI delegate. Never publish into it.
        let delegate = editor.delegate
        editor.delegate = nil
        editor.breakUndoCoalescing()
        editor.undoManager?.beginUndoGrouping()
        for edit in edits.sorted(by: { $0.location > $1.location }) {
            editor.insertText(edit.replacement, replacementRange: edit.range)
        }
        editor.undoManager?.setActionName("Update Wiki Links")
        editor.undoManager?.endUndoGrouping()
        editor.breakUndoCoalescing()
        let start = mapped(selection.location)
        editor.setSelectedRange(NSRange(location: start, length: max(0, mapped(NSMaxRange(selection)) - start)))
        editor.delegate = delegate
    }

    func textView(for text: String) -> MarkdownTextView {
        let view: MarkdownTextView
        if let editor {
            view = editor
            view.bridgeID = UUID()
            view.delegate = nil
            view.onFocusChange = nil
            view.breakUndoCoalescing()
            view.enclosingScrollView?.documentView = nil
        } else {
            let storage = NSTextStorage()
            let layout = LiveMarkdownLayout()
            let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 0), textContainer: container)
            editor = view
        }
        if view.string != text {
            // Reopening changed disk content must not apply undo ranges from an
            // older version. App-owned saves/renames keep exactly the same text.
            let selection = view.selectedRange()
            view.undoManager?.removeAllActions()
            view.string = text
            let location = min(selection.location, text.utf16.count)
            view.setSelectedRange(NSRange(location: location,
                length: min(selection.length, text.utf16.count - location)))
        }
        return view
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let focusRequested: Bool
    var session: NoteEditorSession?
    var findRequest: UUID?
    var findAction: NSTextFinder.Action = .showFindInterface
    var livePreview = false
    var notesFolder: URL?
    var openNoteLink: ((String) -> Void)? = nil
    let onFocusChange: (Bool) -> Void
    let importImages: ([ImageInput], NSTextView, NSRange) -> Bool
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> EditorScrollView {
        let scroll = EditorScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true

        let editor = (session ?? NoteEditorSession()).textView(for: text)
        let bridgeID = editor.bridgeID
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        editor.textColor = NSColor(NordTheme.text)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Markdown source editor")
        editor.delegate = context.coordinator
        editor.importImages = { [weak coordinator = context.coordinator] inputs, view, range in
            coordinator?.parent.importImages(inputs, view, range) ?? false
        }
        editor.onError = { [weak coordinator = context.coordinator] error in
            coordinator?.parent.onError(error)
        }
        editor.onOpenNoteLink = { [weak coordinator = context.coordinator] target in
            coordinator?.parent.openNoteLink?(target)
        }
        editor.onCompositionEnded = { [weak coordinator = context.coordinator, weak editor] in
            guard let editor else { return }
            coordinator?.refreshAfterComposition(editor)
        }
        editor.onFocusChange = { [weak coordinator = context.coordinator, weak editor] focused in
            DispatchQueue.main.async {
                guard let editor, editor.bridgeID == bridgeID, let window = editor.window,
                      (window.firstResponder === editor) == focused else { return }
                coordinator?.parent.onFocusChange(focused)
            }
        }
        scroll.documentView = editor
        NativeEditorStyle.apply(to: editor)
        editor.registerForDraggedTypes(editor.acceptableDragTypes)
        context.coordinator.refreshPresentation(editor)
        scroll.onAttached = { [weak coordinator = context.coordinator, weak editor] in
            guard let editor, editor.bridgeID == bridgeID else { return }
            coordinator?.focusIfRequested(editor)
            coordinator?.findIfRequested(editor)
        }
        scroll.onResize = { [weak coordinator = context.coordinator, weak editor] in
            guard let editor, editor.bridgeID == bridgeID else { return }
            coordinator?.refreshPresentation(editor)
        }
        return scroll
    }

    static func dismantleNSView(_ scroll: EditorScrollView, coordinator: Coordinator) {
        scroll.onAttached = nil
        scroll.onResize = nil
        guard let editor = scroll.documentView as? MarkdownTextView,
              editor.delegate === coordinator else { return }
        editor.breakUndoCoalescing()
        editor.bridgeID = UUID()
        editor.delegate = nil
        editor.onFocusChange = nil
        editor.importImages = nil
        editor.onError = nil
        editor.onOpenNoteLink = nil
        editor.onCompositionEnded = nil
    }

    func updateNSView(_ scroll: EditorScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? MarkdownTextView else { return }
        if editor.string != text, !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            let location = min(selection.location, text.utf16.count)
            editor.setSelectedRange(NSRange(location: location,
                                            length: min(selection.length, text.utf16.count - location)))
        }
        context.coordinator.refreshPresentation(editor)
        context.coordinator.focusIfRequested(editor)
        context.coordinator.findIfRequested(editor)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        private let formatter = LiveMarkdownFormatter()
        private var handledFindRequest: UUID?
        init(parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            // AppKit can notify during programmatic text/presentation updates.
            // Echoing unchanged text publishes NoteStore changes inside updateNSView.
            if parent.text != editor.string { parent.text = editor.string }
            if let editor = editor as? MarkdownTextView { refreshPresentation(editor) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? MarkdownTextView else { return }
            refreshPresentation(editor)
        }

        func refreshPresentation(_ editor: MarkdownTextView) {
            formatter.apply(to: editor, enabled: parent.livePreview, folder: parent.notesFolder)
        }

        func refreshAfterComposition(_ editor: MarkdownTextView) {
            formatter.invalidate()
            refreshPresentation(editor)
        }

        func findIfRequested(_ editor: NSTextView) {
            guard let request = parent.findRequest, request != handledFindRequest,
                  editor.window != nil else { return }
            handledFindRequest = request
            let action = parent.findAction
            let bridgeID = (editor as? MarkdownTextView)?.bridgeID
            DispatchQueue.main.async { [weak self, weak editor] in
                guard self?.parent.findRequest == request, let editor,
                      (editor as? MarkdownTextView)?.bridgeID == bridgeID,
                      let window = editor.window else { return }
                window.makeFirstResponder(editor)
                let sender = NSMenuItem()
                sender.tag = action.rawValue
                editor.performTextFinderAction(sender)
            }
        }

        func focusIfRequested(_ editor: NSTextView) {
            guard parent.focusRequested else { return }
            let bridgeID = (editor as? MarkdownTextView)?.bridgeID
            DispatchQueue.main.async { [weak self, weak editor] in
                guard self?.parent.focusRequested == true, let editor,
                      (editor as? MarkdownTextView)?.bridgeID == bridgeID,
                      let window = editor.window, window.firstResponder !== editor else { return }
                window.makeFirstResponder(editor)
            }
        }
    }

    final class EditorScrollView: NSScrollView {
        var onAttached: (() -> Void)?
        var onResize: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onAttached?() }
        }

        override func layout() {
            super.layout()
            guard let editor = documentView as? NSTextView else { return }
            let minimum = NSSize(width: 0, height: contentSize.height)
            if editor.minSize != minimum { editor.minSize = minimum }
            if editor.frame.height < contentSize.height {
                editor.setFrameSize(contentSize)
            }
            onResize?()
        }
    }
}

class MarkdownTextView: NSTextView {
    var bridgeID = UUID()
    private let noteUndoManager = UndoManager()
    override var undoManager: UndoManager? { noteUndoManager }
    var importImages: (([ImageInput], NSTextView, NSRange) -> Bool)?
    var onError: ((Error) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onCompositionEnded: (() -> Void)?
    var clipboard: NSPasteboard = .general
    var markdownLinks: [NSRange: URL] = [:]
    var footnoteLinks: [NSRange: NSRange] = [:]
    var wikiLinks: [NSRange: String] = [:]
    var onOpenNoteLink: ((String) -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let layout = layoutManager as? LiveMarkdownLayout {
            layout.hiddenCharacters = []
            layout.replacements = [:]
            layout.images = [:]
            layout.horizontalRules = []
            layout.checkboxes = [:]
            layout.tables = [:]
            layout.quotes = []
            markdownLinks = [:]
            footnoteLinks = [:]
            wikiLinks = [:]
            layout.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: self.string.utf16.count),
                                    changeInLength: 0, actualCharacterRange: nil)
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionEnded?()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        super.insertText(insertString, replacementRange: replacementRange)
        if wasComposing { onCompositionEnded?() }
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL, .png, .tiff]
    }

    override func insertTab(_ sender: Any?) {
        if !indentList(outdent: false) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !indentList(outdent: true) { super.insertBacktab(sender) }
    }

    private func indentList(outdent: Bool) -> Bool {
        guard isEditable, !hasMarkedText() else { return false }
        let source = string as NSString
        let selection = selectedRange()
        // A selection ending at the next line's start belongs to the preceding lines.
        let covered = NSRange(location: selection.location, length: max(0, selection.length - 1))
        let paragraphs = source.paragraphRange(for: covered)
        let code = LiveMarkdownPlan.decorations(in: string).filter {
            if case .code = $0.kind { return $0.isBlock }
            return false
        }
        let regex = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-+*][ \t]+|(\d{1,9})[.)][ \t]+)"#)
        var edits: [(range: NSRange, text: String)] = []
        var updatedLines: [Int: String] = [:]
        func indentationWidth(_ indent: String) -> Int {
            indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        }
        func nextNumber(before location: Int, indent: String) -> Int {
            let width = indentationWidth(indent)
            var previous = location
            while previous > 0 {
                let paragraph = source.paragraphRange(for: NSRange(location: previous - 1, length: 0))
                previous = paragraph.location
                if code.contains(where: { NSLocationInRange(previous, $0.range) }) { break }
                let line = (updatedLines[previous] ?? source.substring(with: paragraph)) as NSString
                if (line as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                guard let match = regex.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) else { break }
                let previousWidth = indentationWidth(line.substring(with: match.range(at: 1)))
                if previousWidth > width { continue } // Skip descendants when returning to a parent list.
                guard previousWidth == width, match.range(at: 2).location != NSNotFound,
                      let number = Int(line.substring(with: match.range(at: 2))) else { break }
                return number + 1
            }
            return 1
        }
        var location = paragraphs.location
        repeat {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: paragraph)
            guard !code.contains(where: { NSLocationInRange(location, $0.range) }),
                  let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
                return false
            }
            let indent = (line as NSString).substring(with: match.range(at: 1))
            let removed = outdent ? (indent.first == "\t" ? 1 : indent.prefix(while: { $0 == " " }).prefix(4).count) : 0
            let newIndent = outdent ? String(indent.dropFirst(removed)) : "    " + indent
            var lineEdits: [(range: NSRange, text: String)] = []
            if outdent {
                if removed > 0 { lineEdits.append((NSRange(location: location, length: removed), "")) }
            } else {
                lineEdits.append((NSRange(location: location, length: 0), "    "))
            }
            if (!outdent || removed > 0), match.range(at: 2).location != NSNotFound {
                let numberRange = match.range(at: 2)
                lineEdits.append((NSRange(location: location + numberRange.location, length: numberRange.length),
                                  String(nextNumber(before: location, indent: newIndent))))
            }
            let updated = NSMutableString(string: line)
            for edit in lineEdits.reversed() {
                updated.replaceCharacters(in: NSRange(location: edit.range.location - location, length: edit.range.length), with: edit.text)
            }
            updatedLines[location] = updated as String
            edits.append(contentsOf: lineEdits)
            location = NSMaxRange(paragraph)
        } while location < NSMaxRange(paragraphs)
        guard !edits.isEmpty else { return true }
        let replacement = NSMutableString(string: source.substring(with: paragraphs))
        for edit in edits.reversed() {
            replacement.replaceCharacters(in: NSRange(location: edit.range.location - paragraphs.location,
                                                       length: edit.range.length), with: edit.text)
        }
        func adjusted(_ offset: Int) -> Int {
            var result = offset
            for edit in edits where edit.range.location <= offset {
                let relative = offset - edit.range.location
                if relative >= edit.range.length {
                    result += edit.text.utf16.count - edit.range.length
                } else {
                    result += min(relative, edit.text.utf16.count) - relative
                }
            }
            return result
        }
        let start = adjusted(selection.location)
        let end = adjusted(NSMaxRange(selection))
        insertText(replacement as String, replacementRange: paragraphs)
        setSelectedRange(NSRange(location: start, length: end - start))
        return true
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { super.insertNewline(sender); return }
        let source = string as NSString
        let selection = selectedRange()
        let paragraph = source.paragraphRange(for: NSRange(location: selection.location, length: 0))
        let line = source.substring(with: paragraph).trimmingCharacters(in: .newlines) as NSString
        let pattern = #"^([ \t]*)(?:([-+*])([ \t]+)(?:\[([ xX])\](?:[ \t]+|$))?|(\d{1,9})([.)])([ \t]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)),
              selection.location >= paragraph.location + match.range.length,
              NSMaxRange(selection) <= paragraph.location + line.length,
              !LiveMarkdownPlan.decorations(in: string).contains(where: {
                  if case .code = $0.kind { return $0.isBlock && NSLocationInRange(selection.location, $0.range) }
                  return false
              }) else { super.insertNewline(sender); return }
        let indent = line.substring(with: match.range(at: 1))
        let content = line.substring(from: match.range.length)
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            insertText(indent, replacementRange: NSRange(location: paragraph.location, length: line.length))
            return
        }
        let prefix: String
        if match.range(at: 5).location != NSNotFound,
           let number = Int(line.substring(with: match.range(at: 5))) {
            prefix = indent + String(number + 1) + line.substring(with: match.range(at: 6)) + line.substring(with: match.range(at: 7))
        } else {
            prefix = indent + line.substring(with: match.range(at: 2)) + line.substring(with: match.range(at: 3))
                + (match.range(at: 4).location == NSNotFound ? "" : "[ ] ")
        }
        insertText("\n" + prefix, replacementRange: selection)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), let target = noteLinkTarget(at: point),
           let onOpenNoteLink {
            onOpenNoteLink(target)
            return
        }
        if event.modifierFlags.contains(.command), let character = markdownCharacter(at: point),
           activateMarkdownLink(at: character) { return }
        if revealMarkdownTable(at: point) { return }
        if toggleCheckbox(at: point) { return }
        super.mouseDown(with: event)
    }

    private func noteLinkTarget(at point: NSPoint) -> String? {
        guard let layout = layoutManager as? LiveMarkdownLayout, let container = textContainer else { return nil }
        layout.ensureLayout(for: container)
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        for (character, preview) in layout.tables {
            let glyph = layout.glyphIndexForCharacter(at: character)
            let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            guard bounds.contains(local) else { continue }
            return preview.noteLinkTarget(at: NSPoint(x: local.x - bounds.minX, y: local.y - bounds.minY))
        }
        return nil
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            _ = activateMarkdownLink(at: charIndex)
        } else {
            setSelectedRange(NSRange(location: charIndex, length: 0))
        }
    }

    @discardableResult
    func activateMarkdownLink(at character: Int, open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        guard !hasMarkedText() else { return false }
        if let target = wikiLinks.first(where: { NSLocationInRange(character, $0.key) })?.value,
           let onOpenNoteLink {
            onOpenNoteLink(target)
            return true
        }
        if let target = footnoteLinks.first(where: { NSLocationInRange(character, $0.key) })?.value {
            setSelectedRange(target)
            scrollRangeToVisible(target)
            return true
        }
        guard let url = markdownLinks.first(where: { NSLocationInRange(character, $0.key) })?.value else { return false }
        return open(url)
    }

    private func markdownCharacter(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, layout.numberOfGlyphs > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    @discardableResult
    func revealMarkdownTable(at point: NSPoint) -> Bool {
        guard !hasMarkedText(), let layout = layoutManager as? LiveMarkdownLayout,
              let container = textContainer else { return false }
        layout.ensureLayout(for: container)
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        for (character, preview) in layout.tables {
            let glyph = layout.glyphIndexForCharacter(at: character)
            let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            guard bounds.contains(local) else { continue }
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: preview.table.range.location, length: 0))
            return true
        }
        return false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEditable, !hasMarkedText(), let layout = layoutManager as? LiveMarkdownLayout,
              let container = textContainer else { return }
        layout.ensureLayout(for: container)
        for range in Array(markdownLinks.keys) + Array(footnoteLinks.keys) + Array(wikiLinks.keys) {
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                let target = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).intersection(self.visibleRect)
                if !target.isEmpty { self.addCursorRect(target, cursor: .pointingHand) }
            }
        }
        for character in layout.checkboxes.keys {
            guard let rect = layout.checkboxRect(at: character) else { continue }
            let target = rect.insetBy(dx: -2, dy: -2)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                .intersection(visibleRect)
            if !target.isEmpty { addCursorRect(target, cursor: .pointingHand) }
        }
    }

    @discardableResult
    func toggleCheckbox(at point: NSPoint) -> Bool {
        guard isEditable, !hasMarkedText(), let layout = layoutManager as? LiveMarkdownLayout,
              let container = textContainer else { return false }
        layout.ensureLayout(for: container)
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        for (character, checkbox) in layout.checkboxes {
            guard let rect = layout.checkboxRect(at: character), rect.insetBy(dx: -2, dy: -2).contains(local) else { continue }
            let selection = selectedRange()
            insertText(checkbox.checked ? " " : "x", replacementRange: checkbox.stateRange)
            setSelectedRange(selection)
            return true
        }
        return false
    }

    // NSTextView has a private undo manager here. Expose the standard responder
    // actions explicitly so the Edit menu/keyboard use that same history.
    @objc func undo(_ sender: Any?) {
        guard let undoManager, undoManager.canUndo else { return }
        breakUndoCoalescing()
        undoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard let undoManager, undoManager.canRedo else { return }
        breakUndoCoalescing()
        undoManager.redo()
    }

    override func cancelOperation(_ sender: Any?) {
        if enclosingScrollView?.isFindBarVisible == true {
            let action = NSMenuItem()
            action.tag = NSTextFinder.Action.hideFindInterface.rawValue
            performTextFinderAction(action)
            window?.makeFirstResponder(self)
        } else {
            super.cancelOperation(sender)
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return undoManager?.canUndo == true }
        if item.action == #selector(redo(_:)) { return undoManager?.canRedo == true }
        if item.action == #selector(paste(_:)), isImageDrop(clipboard) {
            return isEditable && !hasMarkedText()
        }
        return super.validateUserInterfaceItem(item)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isImageDrop(sender.draggingPasteboard) { return hasMarkedText() ? [] : .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isImageDrop(sender.draggingPasteboard) { return hasMarkedText() ? [] : .copy }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isImageDrop(sender.draggingPasteboard) { return !hasMarkedText() }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isImageDrop(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        guard !hasMarkedText() else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let index = min(characterIndexForInsertion(at: point), string.utf16.count)
        return insertImages(from: sender.draggingPasteboard, at: NSRange(location: index, length: 0))
    }

    override func paste(_ sender: Any?) {
        if isImageDrop(clipboard) {
            _ = insertImages(from: clipboard, at: selectedRange())
        } else if pasteMarkdownLink(from: clipboard) {
            return
        } else {
            super.paste(sender)
        }
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if isImageDrop(pasteboard) {
            return insertImages(from: pasteboard, at: selectedRange())
        }
        if pasteMarkdownLink(from: pasteboard) { return true }
        return super.readSelection(from: pasteboard, type: type)
    }

    @discardableResult
    func pasteMarkdownLink(from pasteboard: NSPasteboard) -> Bool {
        let selection = selectedRange()
        guard isEditable, !hasMarkedText(), selectedRanges.count == 1, selection.length > 0,
              NSMaxRange(selection) <= (string as NSString).length,
              let raw = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL) else { return false }
        let destination = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard destination.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = MarkdownLink.resolve(destination, folder: nil),
              url.scheme?.lowercased() == "mailto" ? !url.path.isEmpty : !(url.host ?? "").isEmpty else { return false }
        let label = (string as NSString).substring(with: selection)
        guard label.rangeOfCharacter(from: .newlines) == nil,
              !LiveMarkdownPlan.decorations(in: string).contains(where: {
                  if case .code = $0.kind { return NSIntersectionRange($0.range, selection).length > 0 }
                  return false
              }) else { return false }
        let escaped = label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let address = url.absoluteString
        let target = address.contains("(") || address.contains(")") ? "<" + address + ">" : address
        insertText("[" + escaped + "](" + target + ")", replacementRange: selection)
        return true
    }

    private func isImageDrop(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    @discardableResult
    func insertImages(from pasteboard: NSPasteboard, at range: NSRange) -> Bool {
        guard !hasMarkedText() else { return false }
        do {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL]
            let inputs: [ImageInput]
            if let urls, !urls.isEmpty {
                inputs = try urls.map(ImageInput.read)
            } else if let type = pasteboard.availableType(from: [.png, .tiff]),
                      let data = pasteboard.data(forType: type) {
                inputs = [ImageInput.clipboard(data)]
            } else { throw ImageAssetError.unsupportedImage }
            return importImages?(inputs, self, range) ?? false
        } catch {
            onError?(error)
            return false
        }
    }
}
