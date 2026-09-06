import AppKit
import SwiftUI

/// A one-shot imperative instruction for the composer's text view.
///
/// The composer needs three writes `SubmittingTextEditor`'s one-way contract
/// forbids — restore a draft, replace a token on accept, clear on send — and its
/// doc comment already names the shape to add them in: "an explicit command
/// rather than as state SwiftUI can resend at a moment of its own choosing".
/// That is what the token is for: the coordinator remembers the last one it ran,
/// so a republish carrying the same command does nothing.
struct ComposerCommand: Equatable {
    enum Kind: Equatable {
        /// Replace everything — restoring a draft when the pane reappears.
        case restore(String)
        /// Replace one range, caret after the insertion — accepting a completion.
        case replaceRange(NSRange, with: String)
        /// Insert at the caret — an image token.
        case insertAtCaret(String)
        /// Empty it — a successful send.
        case clear
    }
    /// Monotonic. A command whose token the coordinator has already run is
    /// ignored.
    let token: Int
    let kind: Kind
}

/// The composer's text view: plain text, chat-box Return semantics, an image
/// paste that never becomes an inline attachment, and three one-shot commands.
///
/// **Plain text, deliberately.** Image tokens are ordinary characters styled
/// through the layout manager's temporary attributes, which never touch the
/// storage. Enabling rich text to make them real attachments would reopen the
/// substitution and paste-formatting hazards the submitting editor closed, and a
/// styled plain-text token gives the same anchor.
///
/// **The paste override reads the pasteboard itself** and does not add image
/// types to the view's readable types, so `NSTextView`'s default pipeline never
/// inserts an inline attachment — the same shape `TBDTerminalView.paste(_:)`
/// already uses.
///
/// SwiftUI's `TextEditor` is rejected because Apple documents neither whether its
/// key handler runs before insertion nor its behavior during composition, and it
/// has no fit-to-content sizing on macOS. `NSTextView`'s built-in completion is
/// rejected because Apple documents it as a plain string list.
struct MessageComposerTextView: NSViewRepresentable {
    /// Roughly six lines, then it scrolls. A first message is often a paragraph;
    /// a box that stretched to fit one would push the transcript off screen.
    static let maxVisibleLines = 6

    var command: ComposerCommand?
    var isEnabled: Bool = true
    /// Every edit and every selection change: the text, the caret's UTF-16
    /// location, and whether an input method is mid-composition. The caller's own
    /// state follows the view rather than driving it.
    ///
    /// The third value is not a convenience: the completion controller dismisses
    /// the menu outright while text is marked, and it can only know that from the
    /// text view — so the view reports it rather than letting a caller guess.
    var onTextChange: (String, Int, Bool) -> Void
    /// Return, carrying the TEXT VIEW's current string — never anything held on
    /// this struct, which a SwiftUI update pass can leave one behind.
    var onSubmit: (String) -> Void
    /// Escape with no menu open.
    var onEscape: () -> Void
    /// Pasted or dropped image bytes, already lifted off the pasteboard.
    var onImageData: (Data) -> Void
    /// Read at decision time, so a stale menu-open flag is impossible.
    var menuIsOpen: () -> Bool
    var onMenuAction: (ComposerKeyRouter.Action) -> Void
    /// The text view, handed out once when it is made.
    ///
    /// Deliberately not a lifecycle pair driven from `dismantleNSView`: the
    /// SwiftUI view that owns this one registers and unregisters itself in
    /// `onAppear`/`onDisappear`, which are ordered against its own state, and a
    /// second teardown signal arriving from AppKit would be a second source of
    /// truth for the same fact. This hand-out exists only so that view has an
    /// `NSView` to focus and to draw an argument hint on.
    var onViewReady: ((NSView) -> Void)?

    // MARK: - Command application

    /// Apply one command. Static and free of the coordinator so every case is
    /// testable against a bare `NSTextView`.
    static func apply(_ command: ComposerCommand, to textView: NSTextView) {
        let ns = textView.string as NSString
        switch command.kind {
        case .restore(let text):
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        case .replaceRange(let range, let replacement):
            // Refused rather than clamped: a range the text no longer holds means
            // the person edited while this was in flight, and inserting at a
            // clamped position would put the token somewhere nobody asked for.
            guard range.location >= 0, range.length >= 0,
                  range.location + range.length <= ns.length else { return }
            textView.insertText(replacement, replacementRange: range)
            textView.setSelectedRange(
                NSRange(location: range.location + (replacement as NSString).length, length: 0))
        case .insertAtCaret(let text):
            textView.insertText(text, replacementRange: textView.selectedRange())
        case .clear:
            textView.string = ""
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        // A fixed maximum height with a scroller past it, so a growing message
        // never shifts the transcript above it.
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = ComposerTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        // The TRANSCRIPT text theme, not the terminal's: the composer sits under
        // the transcript and belongs to it.
        textView.font = TranscriptTextTheme.chatBubble.bodyFont
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // Handed to an agent verbatim; silently turning a straight quote into a
        // curly one corrupts a prompt that quotes code.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.onImageData = onImageData
        textView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = textView
        context.coordinator.textView = textView
        onViewReady?(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Refreshing the parent is load-bearing: `self` is a fresh struct each
        // pass, and this is what keeps the closures pointing at the current
        // body's. Deliberately nothing else touches the text or the selection —
        // that is the whole contract — except a command that has not run yet.
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.onImageData = onImageData
        if let command {
            context.coordinator.applyIfNew(command, to: textView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageComposerTextView?
        weak var textView: ComposerTextView?
        private var lastAppliedToken: Int?

        override init() { super.init() }

        init(_ parent: MessageComposerTextView) {
            self.parent = parent
            super.init()
        }

        /// Run a command once. Returns whether it ran.
        @discardableResult
        func applyIfNew(_ command: ComposerCommand, to textView: NSTextView) -> Bool {
            guard lastAppliedToken != command.token else { return false }
            lastAppliedToken = command.token
            MessageComposerTextView.apply(command, to: textView)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            report(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // The caret leaving a token closes the menu, which is a selection
            // change and not an edit — so it needs its own hook.
            report(textView)
        }

        private func report(_ textView: NSTextView) {
            parent?.onTextChange(
                textView.string, textView.selectedRange().location, textView.hasMarkedText())
        }

        func textView(
            _ textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let parent else { return false }
            let event = NSApp.currentEvent
            let flags = event?.modifierFlags ?? []
            let action = ComposerKeyRouter.action(
                selector: commandSelector,
                shiftHeld: flags.contains(.shift),
                commandHeld: flags.contains(.command),
                controlHeld: flags.contains(.control),
                hasMarkedText: textView.hasMarkedText(),
                // Read at decision time, from the controller — never a flag
                // captured earlier, which could describe a menu that has closed.
                menuOpen: parent.menuIsOpen())

            switch action {
            case .submit:
                // The text view, never the parent: a SwiftUI update pass can
                // leave `parent` one keystroke behind, and the view cannot be.
                parent.onSubmit(textView.string)
                return true
            case .newline:
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case .blur:
                parent.onEscape()
                return true
            case .menuUp, .menuDown, .menuAccept, .menuClose:
                // Only reachable with the menu open — the router returns these
                // four solely under `menuOpen`, so Tab still moves focus and the
                // arrows still move the caret when nothing is showing.
                parent.onMenuAction(action)
                return true
            case .passThrough:
                return false
            }
        }
    }
}

/// The text view, with the paste and drop overrides.
final class ComposerTextView: NSTextView {
    var onImageData: ((Data) -> Void)?

    /// Text wins when the pasteboard advertises both, preserving ordinary Cmd-V.
    /// An image-only paste is lifted here and never handed to `super`, so
    /// AppKit's default pipeline cannot insert an inline attachment.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == nil,
           let data = ComposerImagePreparer.imageData(from: pasteboard) {
            onImageData?(data)
            return
        }
        super.pasteAsPlainText(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        // Anything else — dragged text, most of all — stays AppKit's business.
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty
        else { return super.performDragOperation(sender) }
        var handled = false
        for url in urls {
            guard let data = ComposerImagePreparer.imageData(fromFileAt: url) else { continue }
            onImageData?(data)
            handled = true
        }
        // A dropped file that holds no image is not ours; let the text view do
        // what it would have done with it.
        return handled ? true : super.performDragOperation(sender)
    }
}
