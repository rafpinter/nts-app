import AppKit
import SwiftUI

enum NativeEditorStyle {
    static func apply(to textView: NSTextView) {
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        if let scrollView = textView.enclosingScrollView {
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            scrollView.autohidesScrollers = true
        }
        textView.insertionPointColor = NSColor(NordTheme.accent)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(NordTheme.accent).withAlphaComponent(0.25),
            .foregroundColor: NSColor(NordTheme.text)
        ]
        textView.textContainerInset = NSSize(width: 0, height: 8)
        // Markdown/code should stay exactly as typed. Keep native caret movement,
        // selection, undo, and input methods; never replace the text storage here.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
    }
}
