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
            // Two comparisons rather than `location + length <= ns.length`:
            // the range this is most likely to refuse is
            // `NSRange(location: NSNotFound, …)`, whose location is `Int.max`,
            // and that addition traps before the comparison can refuse it.
            guard range.location >= 0, range.length >= 0,
                  range.location <= ns.length,
                  range.length <= ns.length - range.location else { return }
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
        makeScrollView(coordinator: context.coordinator)
    }

    /// Build the scroll view and the text view inside it.
    ///
    /// Split out of `makeNSView(context:)` because an
    /// `NSViewRepresentableContext` cannot be constructed outside SwiftUI, and
    /// the geometry set up here is exactly what a test has to be able to reach.
    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // A fixed maximum height with a scroller past it, so a growing message
        // never shifts the transcript above it.
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
        let textView = ComposerTextView(frame: NSRect(origin: .zero, size: contentSize))
        // The geometry `NSTextView.scrollableTextView()` would have set up,
        // spelled out because a subclass rules that factory out. It is stated
        // rather than inherited: `NSScrollView`'s `documentView` setter happens
        // to re-seed `minSize`, `maxSize` and the container from the clip view,
        // and `widthTracksTextView` happens to default to `true`, so a text view
        // built at `.zero` does grow today — but none of that is documented, and
        // a composer that silently stops growing is a box a paragraph cannot be
        // typed into.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = coordinator
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
        coordinator.textView = textView
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageComposerTextView?
        weak var textView: ComposerTextView?
        private var lastAppliedToken: Int?
        /// True for the duration of one command's application. AppKit posts its
        /// text and selection notifications synchronously from `insertText`, and
        /// a command is applied from inside `updateNSView` — so those reports are
        /// swallowed here and re-issued one turn later.
        private var isApplyingCommand = false

        override init() { super.init() }

        init(_ parent: MessageComposerTextView) {
            self.parent = parent
            super.init()
        }

        /// Run a command once. Returns whether it ran.
        ///
        /// **Every kind reports, and every kind reports LATE.** `.restore` and
        /// `.clear` assign `.string`, which posts no text-change notification at
        /// all, so the report has to be made here rather than hoped for; a send
        /// clears the box, and a composer whose state is not resynchronised
        /// still believes it holds the message that just went out.
        /// `.replaceRange` and `.insertAtCaret` do go through `didChangeText` —
        /// but synchronously, from inside `updateNSView`.
        ///
        /// Either way the report writes `@Observable` state that sibling views
        /// render, and SwiftUI treats a write during a view update as undefined
        /// behavior. So the notifications this application raises are swallowed
        /// and ONE report is made a main-actor turn later, the same deferral
        /// `MessageComposerView.adopt` makes for its registration.
        @discardableResult
        func applyIfNew(_ command: ComposerCommand, to textView: NSTextView) -> Bool {
            guard lastAppliedToken != command.token else { return false }
            lastAppliedToken = command.token
            isApplyingCommand = true
            MessageComposerTextView.apply(command, to: textView)
            isApplyingCommand = false
            scheduleReport(textView)
            return true
        }

        /// The one deferred report. Weak on both sides: a pane torn down inside
        /// the one-turn gap leaves nothing to report to.
        private func scheduleReport(_ textView: NSTextView) {
            Task { @MainActor [weak self, weak textView] in
                guard let self, let textView else { return }
                self.report(textView)
            }
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
            // A command's own notifications are swallowed; `scheduleReport`
            // makes the one report that covers them.
            guard !isApplyingCommand else { return }
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
            case .menuUp, .menuDown, .menuAccept, .menuAcceptOrSubmit, .menuClose:
                // Only reachable with the menu open — the router returns these
                // five solely under `menuOpen`, so Tab still moves focus and the
                // arrows still move the caret when nothing is showing.
                // `.menuAcceptOrSubmit` is Return, and the caller decides
                // between accepting and sending: only it knows whether a row is
                // highlighted.
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

    /// The placeholder drawn after the caret, naming what an accepted command
    /// takes. Set by the composer view whenever the text changes; nil hides it.
    ///
    /// **Drawn, never inserted.** Putting the hint in the storage would make it
    /// part of the message — the composer's whole plain-text contract is that
    /// what is in the view is what is sent.
    var argumentHint: String? {
        didSet { if argumentHint != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let argumentHint, !argumentHint.isEmpty,
              let layoutManager, let textContainer else { return }
        let caret = selectedRange().location
        let glyph = layoutManager.glyphIndexForCharacter(at: caret)
        var origin = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 0), in: textContainer).origin
        origin.x += textContainerOrigin.x
        origin.y += textContainerOrigin.y
        (argumentHint as NSString).draw(
            at: origin,
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
    }

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
