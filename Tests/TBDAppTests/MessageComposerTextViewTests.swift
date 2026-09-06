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
@MainActor
@Suite("MessageComposerTextView commands")
struct MessageComposerTextViewTests {

    private func makeTextView(_ initial: String = "") -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        view.string = initial
        return view
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
}
