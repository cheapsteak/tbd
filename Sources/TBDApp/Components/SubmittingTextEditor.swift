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
/// **The text flows one way only.** `initialText` seeds the view once, when it
/// is made; from then on the `NSTextView` owns what it holds and SwiftUI is
/// merely told about it, through `onTextChange` and through the string handed
/// to `onSubmit`. Nothing writes the editor's contents from outside, and
/// `updateNSView` touches neither the text nor the selection.
///
/// That is what makes the caret safe, structurally rather than by policing. A
/// SwiftUI update pass is not ordered against the operator's typing: the parent
/// republishes for its own reasons — a poll tick, a subscription event — and
/// such a pass can be evaluated with a text snapshot taken BEFORE the keystroke
/// the text view has already applied. Writing that snapshot back shows the
/// operator a character they just typed disappearing, and, because assigning
/// `NSTextView.string` slams the insertion point to the end of the document, it
/// strands the caret at the end even after the following pass restores the
/// text — worst of all when they had moved back to edit an earlier sentence.
/// A view that never accepts text cannot be told anything stale.
///
/// The same reasoning decides where a submit reads its text: `onSubmit` is
/// handed the TEXT VIEW's current string, not anything held on this struct. The
/// coordinator's `parent` is itself refreshed by an update pass and can be one
/// behind; the text view cannot.
///
/// The tradeoff, stated plainly: there is no way to set the text from outside
/// after the view exists. Restoring a draft, filling in a template, or clearing
/// the box would need an explicit imperative path — a coordinator method driven
/// by an identity token, say — and that path does not exist. It is deliberately
/// absent rather than provisionally missing: no call site needs it, and adding
/// a write-back door reopens the ambiguity the one-way flow removes. Add it
/// when something genuinely needs it, as an explicit command rather than as
/// state SwiftUI can resend at a moment of its own choosing.
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
    /// What the box starts with. Read once, in `makeNSView`; later changes to
    /// it are ignored by design.
    var initialText: String = ""
    /// Every edit, as the text view now holds it. The caller's own state
    /// follows the view rather than driving it.
    var onTextChange: (String) -> Void
    /// Return, when the text is submittable, carrying the text view's current
    /// string. The caller applies its own enablement rules — a Return must not
    /// do what a disabled button cannot — and judges blankness on the string it
    /// is given, which is the one value guaranteed not to lag.
    var onSubmit: (String) -> Void
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
        textView.string = initialText
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

    /// Refreshing the coordinator's parent is the whole job — and it is
    /// load-bearing, not vestigial: `self` is a fresh struct each pass, so this
    /// is what keeps `onTextChange`, `onSubmit` and `onCancel` pointing at the
    /// current body's closures rather than at the ones captured when the view
    /// was made. Deliberately nothing else: this pass must not touch the text
    /// view's contents or its selection, which is the entire contract above.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SubmittingTextEditor

        init(_ parent: SubmittingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onTextChange(textView.string)
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
                // The text view, never `parent` — see the type's doc comment.
                parent.onSubmit(textView.string)
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
