import AppKit
import Foundation
import Testing
@testable import TBDApp

/// The imperative half of the composer's text view.
///
/// `SubmittingTextEditor`'s one-way contract is what makes its caret safe: a
/// SwiftUI update pass is not ordered against typing, so writing text back from
/// a republish can delete a character the person just typed and strand the caret
/// at the end. This view keeps that contract and adds the three writes the
/// composer genuinely needs, as ONE-SHOT COMMANDS carrying a token — the idiom
/// the transcript pane already uses for scroll-to-bottom — so a re-sent value
/// can never re-apply.
/// Records `onTextChange` calls. A reference type because the representable's
/// callbacks are escaping closures, and a captured local `var` cannot be
/// mutated from one under Swift 6 concurrency checking.
@MainActor
private final class TextChangeRecorder {
    var reports: [(text: String, caret: Int, marked: Bool)] = []
}

@MainActor
@Suite("MessageComposerTextView commands")
struct MessageComposerTextViewTests {

    private func makeTextView(_ initial: String = "") -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        view.string = initial
        return view
    }

    /// A representable with inert callbacks, apart from any the caller replaces.
    private func makeComposer(
        onTextChange: @escaping (String, Int, Bool) -> Void = { _, _, _ in }
    ) -> MessageComposerTextView {
        MessageComposerTextView(
            onTextChange: onTextChange,
            onSubmit: { _ in },
            onEscape: {},
            onImageData: { _ in },
            menuIsOpen: { false },
            onMenuAction: { _ in })
    }

    @Test func restoreReplacesTheWholeText() {
        let view = makeTextView("stale")
        MessageComposerTextView.apply(
            ComposerCommand(token: 1, kind: .restore("a draft")), to: view)
        #expect(view.string == "a draft")
        #expect(view.selectedRange().location == 7, "the caret lands at the end of a restore")
    }

    @Test func replaceRangePutsTheCaretAfterTheInsertion() {
        let view = makeTextView("please /comp and more")
        MessageComposerTextView.apply(
            ComposerCommand(
                token: 1,
                kind: .replaceRange(NSRange(location: 7, length: 5), with: "/compact ")),
            to: view)
        #expect(view.string == "please /compact  and more")
        #expect(view.selectedRange().location == 16)
    }

    @Test func insertAtCaretGoesWhereTheCaretIs() {
        let view = makeTextView("look at  please")
        view.setSelectedRange(NSRange(location: 8, length: 0))
        MessageComposerTextView.apply(
            ComposerCommand(token: 1, kind: .insertAtCaret("[Image #1]")), to: view)
        #expect(view.string == "look at [Image #1] please")
    }

    @Test func clearEmptiesIt() {
        let view = makeTextView("something")
        MessageComposerTextView.apply(ComposerCommand(token: 1, kind: .clear), to: view)
        #expect(view.string.isEmpty)
    }

    /// **A command applies once.** The coordinator remembers the last token it
    /// ran, so a SwiftUI republish carrying the same command is a no-op — which
    /// is exactly the staleness the one-way contract exists to prevent.
    @Test func aCommandWithTheSameTokenDoesNotReapply() {
        let coordinator = MessageComposerTextView.Coordinator()
        let view = makeTextView("start")
        let command = ComposerCommand(token: 7, kind: .clear)

        #expect(coordinator.applyIfNew(command, to: view))
        view.string = "typed again"
        #expect(!coordinator.applyIfNew(command, to: view))
        #expect(view.string == "typed again", "a re-sent command must not clobber typing")

        #expect(coordinator.applyIfNew(ComposerCommand(token: 8, kind: .clear), to: view))
        #expect(view.string.isEmpty)
    }

    /// A range the text no longer holds — the person edited while a completion
    /// was being accepted — is refused rather than applied at a clamped
    /// position, which would insert the token in the wrong place.
    @Test func anOutOfBoundsRangeIsRefused() {
        let view = makeTextView("short")
        MessageComposerTextView.apply(
            ComposerCommand(
                token: 1,
                kind: .replaceRange(NSRange(location: 40, length: 5), with: "x")),
            to: view)
        #expect(view.string == "short")
    }

    /// **The text view actually grows, and overflows into a scroll.** A
    /// regression guard rather than a bug fix: the composer builds its own
    /// `NSTextView` instead of taking one from
    /// `NSTextView.scrollableTextView()`, so the sizing that factory performs —
    /// `minSize`, `maxSize`, the container size, `widthTracksTextView` — is
    /// stated by hand, and nothing else in this process would notice if a later
    /// edit dropped one of them and left the box a sliver.
    ///
    /// Layout has to be forced: nothing here is in a window, and `sizeToFit()`
    /// reports the last laid-out size rather than laying out first.
    @Test func theTextViewGrowsWithItsContentAndScrollsPastTheCap() throws {
        let scrollView = makeComposer().makeScrollView(
            coordinator: MessageComposerTextView.Coordinator())
        scrollView.setFrameSize(NSSize(width: 300, height: 40))
        scrollView.layoutSubtreeIfNeeded()
        let textView = try #require(scrollView.documentView as? NSTextView)

        func layOut() {
            if let manager = textView.layoutManager, let container = textView.textContainer {
                manager.ensureLayout(for: container)
            }
            textView.sizeToFit()
        }

        textView.string = "one line"
        layOut()
        let oneLine = textView.frame.height
        #expect(oneLine > 0, "a view clamped by a zero maxSize can never show anything")

        textView.string = Array(repeating: "line", count: 5).joined(separator: "\n")
        layOut()
        let fiveLines = textView.frame.height
        #expect(fiveLines > oneLine, "five lines must be taller than one")

        // Past the visible cap the document keeps growing and the scroll view
        // scrolls it, rather than the box swallowing the overflow.
        textView.string = Array(repeating: "line", count: 40).joined(separator: "\n")
        layOut()
        #expect(textView.frame.height > scrollView.contentSize.height,
                "overflowing text must make the document taller than the clip view")
    }

    /// **A wholesale write reports itself, rather than hoping AppKit will.**
    /// `.restore` and `.clear` assign `NSTextView.string`, which — measured on
    /// this AppKit — posts no text-change notification at all; what fires is a
    /// selection change, and only because the caret is reset afterwards.
    /// Leaning on that leaves `onTextChange` depending on an undocumented side
    /// effect for the one write that must never be missed: a send clears the
    /// box, and a composer whose state is not resynchronised still believes it
    /// holds the message that was just sent.
    ///
    /// The text view here is deliberately NOT wired to the coordinator as its
    /// delegate, so what is measured is the command path's own reporting rather
    /// than whatever notifications AppKit chose to post.
    @Test func clearOnAlreadyEmptyTextReportsWithoutAnyNotification() async {
        let recorder = TextChangeRecorder()
        let coordinator = MessageComposerTextView.Coordinator(
            makeComposer { text, caret, marked in
                recorder.reports.append((text, caret, marked))
            })
        let view = makeTextView("")

        coordinator.applyIfNew(ComposerCommand(token: 1, kind: .clear), to: view)

        #expect(recorder.reports.isEmpty,
                "a command runs inside updateNSView; nothing may be reported there")
        await Task.yield()

        #expect(recorder.reports.count == 1, "an empty clear still has to report")
        #expect(recorder.reports.first?.text == "")
        #expect(recorder.reports.first?.caret == 0)
        #expect(recorder.reports.first?.marked == false,
                "the marked flag is read off the text view, never assumed")
    }

    /// A `.restore` reports too, carrying the text and the caret it just placed.
    @Test func restoreReportsWithoutAnyNotification() async {
        let recorder = TextChangeRecorder()
        let coordinator = MessageComposerTextView.Coordinator(
            makeComposer { text, caret, marked in
                recorder.reports.append((text, caret, marked))
            })
        let view = makeTextView("")

        coordinator.applyIfNew(ComposerCommand(token: 1, kind: .restore("draft")), to: view)

        #expect(recorder.reports.isEmpty, "the report is deferred off the update pass")
        await Task.yield()

        #expect(recorder.reports.count == 1)
        #expect(recorder.reports.first?.text == "draft")
        #expect(recorder.reports.first?.caret == 5)
    }

    /// **An insertion reports late too, and exactly once.**
    ///
    /// `.replaceRange` and `.insertAtCaret` go through
    /// `insertText(_:replacementRange:)`, which posts `didChangeText` and a
    /// selection change SYNCHRONOUSLY — and the command is applied from inside
    /// `updateNSView`, so reporting from those notifications writes `draft.text`,
    /// the completion controller and the argument hint, all of them
    /// `@Observable` state that sibling views render, during a SwiftUI view
    /// update. The coordinator is wired as the delegate here precisely so those
    /// notifications fire; what must come out of them is nothing at all, and one
    /// report a turn later.
    @Test func anInsertionReportsOnceOnALaterTurn() async {
        let recorder = TextChangeRecorder()
        let coordinator = MessageComposerTextView.Coordinator(
            makeComposer { text, caret, marked in
                recorder.reports.append((text, caret, marked))
            })
        let view = makeTextView("please /comp")
        view.delegate = coordinator
        defer { view.delegate = nil }

        coordinator.applyIfNew(
            ComposerCommand(
                token: 1,
                kind: .replaceRange(NSRange(location: 7, length: 5), with: "/compact ")),
            to: view)

        #expect(recorder.reports.isEmpty,
                "AppKit's own notifications must not report from inside the update pass")
        await Task.yield()

        #expect(recorder.reports.count == 1, "one command, one report")
        #expect(recorder.reports.first?.text == "please /compact ")
        #expect(recorder.reports.first?.caret == 16, "the caret follows the insertion")
    }

    /// **A "not found" range is refused, not trapped.** A completion whose token
    /// the text no longer holds produces `NSRange(location: NSNotFound, …)`,
    /// whose location is `Int.max`; a bounds check written as
    /// `location + length <= length` overflows and crashes the app before it can
    /// refuse anything.
    @Test func aNotFoundRangeIsRefusedRatherThanOverflowing() {
        let view = makeTextView("short")
        MessageComposerTextView.apply(
            ComposerCommand(
                token: 1,
                kind: .replaceRange(NSRange(location: NSNotFound, length: 3), with: "x")),
            to: view)
        #expect(view.string == "short")
    }
}
