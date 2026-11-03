import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// The render half of the stale-hand failure.
///
/// `unreadByRemoteSession` is edge-triggered — written when the daemon
/// broadcasts an attention delta, cleared only when the user selects that
/// session — and `.attentionNeeded` outranks `isWorking` in
/// `RowStatusIndicator.suffix`. So a session that asked for input once, was
/// answered elsewhere, and went back to work kept its hand until somebody
/// clicked it. With thirteen such sessions on screen the sidebar was a wall
/// of hands, none of which meant anything, next to one that did.
@Suite("Remote row attention staleness")
struct RemoteSessionRowAttentionStalenessTests {
    // MARK: - The steady axis withdraws what the edge asserted

    @Test("a resumed session loses the hand a past waiting_input left behind")
    func workingClearsALatchedHand() {
        #expect(RemoteSessionRowPresentation.suffixIndicator(
            agentState: .working, unreadType: .attentionNeeded) == .working)
    }

    @Test("every non-waiting agent state clears it, not just working")
    func everyAdvancedStateClearsIt() {
        // `tool_result`, an idle turn, a session whose state simply stopped
        // being reported — none of them is "a human must act", and each
        // arrived in the live failure.
        #expect(RemoteSessionRowPresentation.suffixIndicator(
            agentState: .idle, unreadType: .attentionNeeded) == nil)
        #expect(RemoteSessionRowPresentation.suffixIndicator(
            agentState: .unknown, unreadType: .attentionNeeded) == nil)
        #expect(RemoteSessionRowPresentation.suffixIndicator(
            agentState: .exited, unreadType: .attentionNeeded) == nil)
    }

    @Test("the genuinely waiting session keeps its hand")
    func stillWaitingKeepsTheHand() {
        // The one correct hand on screen must survive the fix, with or
        // without an unread entry behind it.
        #expect(RemoteSessionRowPresentation.suffixIndicator(
            agentState: .waitingInput, unreadType: .attentionNeeded) == .attention)
        #expect(RemoteSessionRowPresentation.suffixIndicator(
            agentState: .waitingInput, unreadType: nil) == .attention)
    }

    @Test("signals the steady axis cannot express still come through")
    func unreadStillAddsWhatItAloneKnows() {
        // The unread map's job: an exited session's nonzero exit has no
        // steady mapping at all, and must not be swept up by this gate.
        #expect(RemoteSessionRowPresentation.suffixIndicator(
            agentState: .exited, unreadType: .error) == .error)
        #expect(RemoteSessionRowPresentation.suffixIndicator(
            agentState: .working, unreadType: .error) == .error)
        #expect(RemoteSessionRowPresentation.suffixIndicator(
            agentState: .working, unreadType: .responseComplete) == .working)
    }

    @Test("the contribution gate names exactly the two types that render as a hand")
    func gateCoversBothAttentionTypes() {
        for type: NotificationType in [.attentionNeeded, .focusRequest] {
            #expect(RemoteSessionRowPresentation.suffixContribution(
                of: type, agentState: .working) == nil)
            #expect(RemoteSessionRowPresentation.suffixContribution(
                of: type, agentState: .waitingInput) == type)
        }
        // Everything else passes through untouched.
        #expect(RemoteSessionRowPresentation.suffixContribution(
            of: .error, agentState: .working) == .error)
        #expect(RemoteSessionRowPresentation.suffixContribution(
            of: nil, agentState: .working) == nil)
    }

    // MARK: - The sequences the failure was observed across

    @Test("quota wait, credential rotation, then resumed working")
    func quotaThenRotationThenResumed() {
        // The unread entry is written once, at the first edge, and never
        // rewritten by any of what follows — so every step here shares it.
        let latched: NotificationType = .attentionNeeded

        #expect(RemoteSessionRowPresentation.suffixIndicator(
            agentState: .waitingInput, unreadType: latched) == .attention)
        // Still blocked while a credential rotates: still a hand.
        #expect(RemoteSessionRowPresentation.suffixIndicator(
            agentState: .waitingInput, unreadType: latched) == .attention)
        // Resumed: the hand goes, without anyone having to click the row.
        #expect(RemoteSessionRowPresentation.suffixIndicator(
            agentState: .working, unreadType: latched) == .working)
    }

    @Test("a polling refresh alone clears it, with no selection change")
    func pollingRefreshClearsIt() {
        // What the daemon's next `list` produces is a new agent state on the
        // same row, with the unread map untouched. That must be enough.
        let beforeRefresh = RemoteSessionRowPresentation.suffixIndicator(
            agentState: .waitingInput, unreadType: .attentionNeeded)
        let afterRefresh = RemoteSessionRowPresentation.suffixIndicator(
            agentState: .working, unreadType: .attentionNeeded)

        #expect(beforeRefresh == .attention)
        #expect(afterRefresh == .working)
    }

    @Test("selecting the session clears the unread entry without changing the verdict")
    func selectionIsOrthogonal() {
        // Selection clears `unreadByRemoteSession` (AppState+Navigation), so
        // the row is then rendered with a nil unread type. The suffix must
        // read the same either way — the glyph follows the agent axis, and
        // selection is not evidence about it.
        #expect(RemoteSessionRowPresentation.suffixIndicator(agentState: .working, unreadType: nil)
            == RemoteSessionRowPresentation.suffixIndicator(agentState: .working, unreadType: .attentionNeeded))
        #expect(RemoteSessionRowPresentation.suffixIndicator(agentState: .waitingInput, unreadType: nil)
            == RemoteSessionRowPresentation.suffixIndicator(agentState: .waitingInput, unreadType: .attentionNeeded))
    }

    @Test("a relaunch starts with no unread entries and reaches the same verdict")
    func foregroundOrReopenAgrees() {
        // `unreadByRemoteSession` is in-memory, so a reopened app has none —
        // which is exactly the state the fix makes a still-running app agree
        // with. Before it, reopening the app was the only reliable way to
        // clear a stale hand.
        for state: RemoteAgentState in [.working, .idle, .unknown, .exited, .waitingInput] {
            #expect(RemoteSessionRowPresentation.suffixIndicator(agentState: state, unreadType: nil)
                == RemoteSessionRowPresentation.suffixIndicator(agentState: state, unreadType: .attentionNeeded),
                "reopening the app must not be what fixes the glyph for \(state)")
        }
    }

    // MARK: - The bold name is deliberately not part of this

    @Test("the bold name stays latched until the row is looked at")
    func boldNameRemainsEdgeTriggered() {
        // "You have not looked since this happened" stays true after the
        // session resumes, and looking is what clears it. Only the glyph —
        // which claims something is true right now — is gated.
        #expect(RowStatusIndicator.shouldBoldName(NotificationType.attentionNeeded))
    }
}
