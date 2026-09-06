import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Drafts are per terminal and survive a session rollover.
///
/// That survival is the whole reason they live on `AppState` rather than in the
/// pane: the transcript table rebuilds under `.id(PaneIdentity(terminalID:
/// sessionID:))`, so a `/clear` tears the view down — and it must not take a
/// half-written message with it.
@MainActor
@Suite("ComposerDraft")
struct ComposerDraftTests {

    private func makeState() -> (AppState, String) {
        let suiteName = "ComposerDraftTests-\(UUID().uuidString)"
        return (AppState(userDefaults: UserDefaults(suiteName: suiteName)!), suiteName)
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
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let a = UUID(), b = UUID()

        state.composerDraft(for: a).text = "for a"
        state.composerDraft(for: b).text = "for b"

        #expect(state.composerDraft(for: a).text == "for a")
        #expect(state.composerDraft(for: b).text == "for b")
    }

    /// The same instance comes back, which is what makes the draft survive a
    /// view teardown.
    @Test func theSameTerminalGetsTheSameInstance() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        #expect(state.composerDraft(for: id) === state.composerDraft(for: id))
    }

    @Test func discardingForgetsIt() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        state.composerDraft(for: id).text = "gone soon"
        state.discardComposerDraft(for: id)
        #expect(state.composerDraft(for: id).text.isEmpty)
    }
}
