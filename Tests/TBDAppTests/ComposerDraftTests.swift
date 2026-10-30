import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Drafts are per terminal and survive a session rollover.
///
/// That survival is the whole reason they live on `AppState` rather than in the
/// pane: the transcript table rebuilds under `.id(PaneIdentity(terminalID:
/// sessionID:))`, so a `/clear` tears the view down — and it must not take a
/// half-written message with it.
@MainActor
@Suite("ComposerDraft")
struct ComposerDraftTests {

    private func makeState() -> (AppState, TestDefaultsSuite) {
        let suite = TestDefaultsSuite("ComposerDraftTests")
        return (AppState(userDefaults: suite.defaults), suite)
    }

    @Test func stagingNumbersTokensFromOne() {
        let draft = ComposerDraft()
        #expect(draft.stage(path: "/tmp/a.png", id: UUID()) == 1)
        #expect(draft.stage(path: "/tmp/b.png", id: UUID()) == 2)
    }

    /// **Numbers are never reused within one message.** Reusing a freed number
    /// would silently re-point a token the person had already typed elsewhere.
    @Test func aRemovedNumberIsNotReused() {
        let draft = ComposerDraft()
        _ = draft.stage(path: "/tmp/a.png", id: UUID())
        _ = draft.stage(path: "/tmp/b.png", id: UUID())
        draft.removeAttachment(number: 1)
        #expect(draft.stage(path: "/tmp/c.png", id: UUID()) == 3)
    }

    /// A staged image whose token is gone from the text is DETACHED — greyed and
    /// marked "not in message", never dropped silently.
    @Test func detachedAttachmentsAreTheOnesTheTextNoLongerAnchors() {
        let draft = ComposerDraft()
        let one = draft.stage(path: "/tmp/a.png", id: UUID())
        let two = draft.stage(path: "/tmp/b.png", id: UUID())
        draft.text = "look at \(ComposerTokens.text(for: one))"
        #expect(draft.detachedNumbers == [two])

        draft.text += " and \(ComposerTokens.text(for: two))"
        #expect(draft.detachedNumbers.isEmpty)
    }

    @Test func clearingEmptiesBothHalves() {
        let draft = ComposerDraft()
        _ = draft.stage(path: "/tmp/a.png", id: UUID())
        draft.text = "words"
        draft.clear()
        #expect(draft.text.isEmpty)
        #expect(draft.attachments.isEmpty)
        #expect(draft.stage(path: "/tmp/b.png", id: UUID()) == 1,
                "a cleared draft starts a fresh message, so numbering restarts")
    }

    // MARK: - The registry

    @Test func oneDraftPerTerminal() {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let a = UUID(), b = UUID()

        state.composerDraft(for: a).text = "for a"
        state.composerDraft(for: b).text = "for b"

        #expect(state.composerDraft(for: a).text == "for a")
        #expect(state.composerDraft(for: b).text == "for b")
    }

    /// The same instance comes back, which is what makes the draft survive a
    /// view teardown.
    @Test func theSameTerminalGetsTheSameInstance() {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let id = UUID()
        #expect(state.composerDraft(for: id) === state.composerDraft(for: id))
    }

    @Test func discardingForgetsIt() {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let id = UUID()
        state.composerDraft(for: id).text = "gone soon"
        state.discardComposerDraft(for: id)
        #expect(state.composerDraft(for: id).text.isEmpty)
    }

    // MARK: - Reporting drafts to the daemon

    @Test func whitespaceIsNoContentButAnImageIs() {
        let draft = ComposerDraft()
        #expect(!draft.hasContent)
        draft.text = "  \n"
        #expect(!draft.hasContent, "whitespace is nothing a close would lose")
        _ = draft.stage(path: "/tmp/a.png", id: UUID())
        #expect(draft.hasContent, "a staged image alone is a draft")
    }

    @Test func contentChangeFiresOnlyWhenItFlips() {
        let draft = ComposerDraft()
        let flips = Recorder<Bool>()
        draft.onContentChange = { flips.values.append($0) }

        draft.text = "h"
        draft.text = "hi"
        draft.text = ""
        draft.text = "again"
        draft.clear()

        #expect(flips.values == [true, false, true, false])
    }

    /// The daemon learns every terminal whose draft has content, as a whole
    /// set, on each gain, loss and discard — what `terminal close` checks.
    @Test func terminalDraftsAreReportedAsAWholeSet() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let reports = Recorder<Set<UUID>>()
        state.composerDraftsSetter = { reports.values.append(Set($0)) }
        let a = UUID(), b = UUID()

        state.composerDraft(for: a).text = "for a"
        await state.composerDraftsPush?.value
        state.composerDraft(for: b).text = "for b"
        await state.composerDraftsPush?.value
        state.composerDraft(for: a).text = ""
        await state.composerDraftsPush?.value
        state.discardComposerDraft(for: b)
        await state.composerDraftsPush?.value

        #expect(reports.values == [[a], [a, b], [b], []])
    }

    /// Reports are chained and each reads the set when it runs, so changes
    /// that queue up behind one another still leave the daemon on the latest.
    @Test func queuedReportsEndOnTheLatestSet() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let reports = Recorder<Set<UUID>>()
        state.composerDraftsSetter = { reports.values.append(Set($0)) }
        let id = UUID()

        state.composerDraft(for: id).text = "typed"
        state.composerDraft(for: id).text = ""
        await state.composerDraftsPush?.value

        #expect(reports.values.last == [])
    }

    /// Typing that never changes whether there is a draft sends nothing.
    @Test func editingADraftThatStaysNonEmptyReportsOnce() async {
        let (state, suite) = makeState()
        defer { suite.tearDown() }
        let reports = Recorder<Set<UUID>>()
        state.composerDraftsSetter = { reports.values.append(Set($0)) }
        let id = UUID()

        for text in ["r", "re", "ref", "refactor"] {
            state.composerDraft(for: id).text = text
        }
        await state.composerDraftsPush?.value

        #expect(reports.values == [[id]])
    }
}

/// A reference box for values a `@MainActor` closure appends to.
@MainActor
private final class Recorder<Value> {
    var values: [Value] = []
}
