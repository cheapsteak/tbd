import AppKit
import SwiftUI

/// What the composer does with a Return-family command.
///
/// Pure, because everything interesting about chat-box Return semantics is a
/// decision, and the AppKit glue around it is not testable in this process.
/// The three inputs are exactly what `doCommandBy` can know: which command
/// AppKit resolved the keystroke to, whether Shift was down, and whether an
/// input method is mid-composition.
enum ComposerReturnKey {
    enum Action: Equatable {
        /// Send the message.
        case submit
        /// Insert a line break and keep composing.
        case newline
        /// Not ours — let AppKit do whatever it would have done.
        case passThrough
    }

    /// Decide from the resolved command.
    ///
    /// `insertNewline:` is what plain Return AND Shift+Return both resolve to —
    /// `StandardKeyBinding.dict` has no Shift+Return entry, so the modifier is
    /// the only thing separating them and has to be read from the event.
    /// `insertNewlineIgnoringFieldEditor:` is Option+Return, which IS a
    /// standard binding and arrives already distinguished.
    ///
    /// `hasMarkedText` is the IME guard: while a Japanese or Chinese candidate
    /// window is open, Return commits the composition and must never send the
    /// message. In practice the input context usually consumes that keystroke
    /// before `doCommandBy` is reached; this makes the guarantee explicit
    /// rather than dependent on that.
    static func action(
        selector: Selector, shiftHeld: Bool, hasMarkedText: Bool
    ) -> Action {
        guard !hasMarkedText else { return .passThrough }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            return shiftHeld ? .newline : .submit
        }
        if selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            return .newline
        }
        return .passThrough
    }
}

/// A scrolling multi-line text editor with chat-box Return semantics: Return
/// sends, Shift+Return and Option+Return insert a line break.
///
/// An `NSTextView` rather than SwiftUI's `TextEditor` (which never submits) or
/// `TextField(axis: .vertical)` (which does, for free, but grows with its
/// content instead of scrolling). A first message is a task brief — the whole
/// premise of parking one is that the operator already knows what they want
/// done — so paragraphs are the expected case, and a sheet that stretches to
/// fit one serves it worse than a box that scrolls.
///
/// Automatic quote and dash substitution are OFF. This text is handed to an
/// agent verbatim, and silently turning `"` into `"` corrupts a prompt that
/// quotes code.
struct SubmittingTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Return, when the text is submittable. The caller applies its own
    /// enablement rules — a Return must not do what a disabled button cannot.
    var onSubmit: () -> Void
    /// Escape. Forwarded explicitly because an `NSTextView` answers
    /// `cancelOperation:` itself, and a sheet's Cancel button would otherwise
    /// never see the key.
    var onCancel: (() -> Void)?
    var focusOnAppear: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        if focusOnAppear {
            // The sheet's window does not exist yet on the first pass.
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only when they differ: assigning `string` collapses the selection, so
        // an unconditional write would fight the cursor on every keystroke.
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SubmittingTextEditor

        init(_ parent: SubmittingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(
            _ textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)),
               let onCancel = parent.onCancel {
                onCancel()
                return true
            }
            let action = ComposerReturnKey.action(
                selector: commandSelector,
                shiftHeld: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false,
                hasMarkedText: textView.hasMarkedText()
            )
            switch action {
            case .submit:
                parent.onSubmit()
                return true
            case .newline:
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case .passThrough:
                return false
            }
        }
    }
}
