import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// `RemoteSessionRowPresentation`, a remote session row's caption and glyph:
/// - `caption(state:agentState:gone:exitCode:staleness:)` — the starting,
///   exited, gone and unavailable captions, their precedence, and the
///   staleness suffix.
/// - `stalenessCaption(health:lastSuccessfulSnapshotAt:now:)`.
/// - `suffixIndicator(agentState:unreadType:)` — the steady-state mapping and
///   its merge with the unread entry.
/// - `higherSeverity(_:_:)`.
@Suite("RemoteSessionRowPresentation")
struct RemoteSessionRowPresentationTests {

    // MARK: - RemoteSessionRowPresentation.caption(state:agentState:gone:exitCode:)

    @Test func caption_startingIsStartingEllipsis() {
        #expect(RemoteSessionRowPresentation.caption(
            state: .starting, agentState: .unknown, gone: false, exitCode: nil
        ) == "Starting…")
    }

    @Test func caption_runningIsNil() {
        #expect(RemoteSessionRowPresentation.caption(
            state: .running, agentState: .idle, gone: false, exitCode: nil
        ) == nil)
    }

    @Test func caption_runningUnknownSurfacesUnavailableAgentState() {
        #expect(RemoteSessionRowPresentation.caption(
            state: .running, agentState: .unknown, gone: false, exitCode: nil
        ) == "agent state unavailable")
    }

    @Test func caption_runningKnownAgentStatesRemainQuiet() {
        #expect(RemoteSessionRowPresentation.caption(
            state: .running, agentState: .working, gone: false, exitCode: nil
        ) == nil)
        #expect(RemoteSessionRowPresentation.caption(
            state: .running, agentState: .idle, gone: false, exitCode: nil
        ) == nil)
    }

    @Test func caption_unknownSurfacesUnavailableTerminalState() {
        #expect(RemoteSessionRowPresentation.caption(
            state: .unknown, agentState: .unknown, gone: false, exitCode: nil
        ) == "terminal state unavailable")
    }

    @Test func caption_exitedWithKnownCodeIncludesCode() {
        #expect(RemoteSessionRowPresentation.caption(
            state: .exited, agentState: .exited, gone: false, exitCode: 1
        ) == "exited (code 1)")
    }

    @Test func caption_exitedWithoutKnownCodeOmitsCode() {
        #expect(RemoteSessionRowPresentation.caption(
            state: .exited, agentState: .exited, gone: false, exitCode: nil
        ) == "exited")
    }

    @Test func caption_goneWinsOverExitedCode() {
        #expect(RemoteSessionRowPresentation.caption(
            state: .exited, agentState: .exited, gone: true, exitCode: 1
        ) == "no longer reported")
    }

    @Test func caption_goneWinsOverStarting() {
        #expect(RemoteSessionRowPresentation.caption(
            state: .starting, agentState: .unknown, gone: true, exitCode: nil
        ) == "no longer reported")
    }

    @Test func caption_goneWinsOverRunningUnknownAgentState() {
        #expect(RemoteSessionRowPresentation.caption(
            state: .running, agentState: .unknown, gone: true, exitCode: nil
        ) == "no longer reported")
    }

    // MARK: - RemoteSessionRowPresentation.caption(staleness:) combining

    @Test func caption_stalenessAloneRendersWhenThereIsNoOtherCaption() {
        // The maintainer's exact scenario: a plain running session (no other
        // caption) under an unhealthy provider must not go silent — this is
        // the only signal a grouped row (no visible provider header nearby)
        // gets that its data might be hours old.
        #expect(
            RemoteSessionRowPresentation.caption(
                state: .running, agentState: .idle, gone: false,
                exitCode: nil, staleness: "as of 2h ago"
            )
                == "as of 2h ago"
        )
    }

    @Test func caption_stalenessCombinesWithUnavailableAgentState() {
        #expect(RemoteSessionRowPresentation.caption(
            state: .running,
            agentState: .unknown,
            gone: false,
            exitCode: nil,
            staleness: "as of 2h ago"
        ) == "agent state unavailable · as of 2h ago")
    }

    @Test func caption_stalenessCombinesWithUnavailableTerminalState() {
        #expect(RemoteSessionRowPresentation.caption(
            state: .unknown,
            agentState: .unknown,
            gone: false,
            exitCode: nil,
            staleness: "as of 2h ago"
        ) == "terminal state unavailable · as of 2h ago")
    }

    @Test func caption_stalenessCombinesWithAnExistingCaption() {
        #expect(
            RemoteSessionRowPresentation.caption(
                state: .exited, agentState: .exited, gone: false,
                exitCode: 1, staleness: "as of 2h ago"
            )
                == "exited (code 1) · as of 2h ago"
        )
    }

    @Test func caption_stalenessCombinesWithGone() {
        #expect(
            RemoteSessionRowPresentation.caption(
                state: .exited, agentState: .exited, gone: true,
                exitCode: 1, staleness: "as of 2h ago"
            )
                == "no longer reported · as of 2h ago"
        )
    }

    @Test func caption_nilStalenessLeavesExistingCaptionsUnchanged() {
        // Every pre-existing call site (no `staleness` argument) must render
        // exactly as before this task.
        #expect(RemoteSessionRowPresentation.caption(
            state: .running, agentState: .idle, gone: false, exitCode: nil
        ) == nil)
        #expect(RemoteSessionRowPresentation.caption(
            state: .starting, agentState: .unknown, gone: false, exitCode: nil
        ) == "Starting…")
    }

    // MARK: - RemoteSessionRowPresentation.stalenessCaption(health:lastSeen:now:)

    @Test func stalenessCaption_nilWhenProviderIsHealthy() {
        #expect(RemoteSessionRowPresentation.stalenessCaption(
            health: .ok, lastSuccessfulSnapshotAt: Date(), now: Date()) == nil)
    }

    @Test func stalenessCaption_reflectsRelativeAgeWhenStale() {
        let now = Date(timeIntervalSince1970: 10_000)
        let lastSeen = now.addingTimeInterval(-2 * 3600)
        #expect(RemoteSessionRowPresentation.stalenessCaption(
            health: .stale, lastSuccessfulSnapshotAt: lastSeen, now: now) == "as of 2h ago")
    }

    @Test func stalenessCaption_justNowOmitsTheTrailingAgo() {
        let now = Date(timeIntervalSince1970: 10_000)
        let lastSeen = now.addingTimeInterval(-5)
        #expect(RemoteSessionRowPresentation.stalenessCaption(
            health: .error, lastSuccessfulSnapshotAt: lastSeen, now: now) == "as of just now")
    }

    @Test func stalenessCaption_rendersForNeedsAuthHealthToo() {
        let now = Date(timeIntervalSince1970: 10_000)
        let lastSeen = now.addingTimeInterval(-5 * 60)
        #expect(RemoteSessionRowPresentation.stalenessCaption(
            health: .needsAuth, lastSuccessfulSnapshotAt: lastSeen, now: now) == "as of 5m ago")
    }

    // MARK: - RemoteSessionRowPresentation.suffixIndicator(agentState:unreadType:) — steady-state mapping + severity merge

    @Test func suffixIndicator_workingIsWorking() {
        #expect(RemoteSessionRowPresentation.suffixIndicator(agentState: .working, unreadType: nil) == .working)
    }

    /// The steady-state divergence: `waitingInput` maps to `.attention` on
    /// every call, purely from `agentState` — there is no edge/latch here,
    /// unlike the `unreadByRemoteSession` bookkeeping (which is edge-
    /// triggered and clears on select). Calling this twice in a row for the
    /// same still-waiting session must keep returning `.attention`.
    @Test func suffixIndicator_waitingInputIsAttentionSteadily() {
        #expect(RemoteSessionRowPresentation.suffixIndicator(agentState: .waitingInput, unreadType: nil) == .attention)
        #expect(RemoteSessionRowPresentation.suffixIndicator(agentState: .waitingInput, unreadType: nil) == .attention)
    }

    @Test func suffixIndicator_idleIsNil() {
        #expect(RemoteSessionRowPresentation.suffixIndicator(agentState: .idle, unreadType: nil) == nil)
    }

    @Test func suffixIndicator_unknownIsNil() {
        #expect(RemoteSessionRowPresentation.suffixIndicator(agentState: .unknown, unreadType: nil) == nil)
    }

    @Test func suffixIndicator_exitedWithNoUnreadIsNil() {
        // `.exited` agentState alone produces no suffix glyph — the exited/gone
        // presentation is secondary-toned text + a caption, not a suffix icon —
        // UNLESS the unread entry says otherwise (see the nonzero-exit test below).
        #expect(RemoteSessionRowPresentation.suffixIndicator(agentState: .exited, unreadType: nil) == nil)
    }

    // MARK: - severity merge (unread entry vs. steady agentState)

    /// The bug this merge fixes: a nonzero exit records `.error` in
    /// `unreadByRemoteSession`, but `agentState` is `.exited` (no steady
    /// mapping) — without folding the unread entry in, the suffix would be
    /// nil and the loudest case would render as the quietest row.
    @Test func suffixIndicator_erroredUnreadShowsErrorEvenWithNoSteadySignal() {
        #expect(RemoteSessionRowPresentation.suffixIndicator(agentState: .exited, unreadType: .error) == .error)
    }

    /// Error (severity 4) beats the steady attention mapping (severity 3) —
    /// `RowStatusIndicator.suffix`'s existing precedence, not a new ladder.
    @Test func suffixIndicator_erroredUnreadBeatsSteadyWaitingInput() {
        #expect(RemoteSessionRowPresentation.suffixIndicator(agentState: .waitingInput, unreadType: .error) == .error)
    }

    /// A lower-severity unread entry (`.responseComplete`, severity 1) must
    /// not mask a still-waiting steady state (severity 3 via `.attentionNeeded`).
    @Test func suffixIndicator_steadyWaitingInputBeatsLowerSeverityUnread() {
        #expect(RemoteSessionRowPresentation.suffixIndicator(agentState: .waitingInput, unreadType: .responseComplete) == .attention)
    }

    // MARK: - RemoteSessionRowPresentation.higherSeverity(_:_:)

    @Test func higherSeverity_bothNilIsNil() {
        #expect(RemoteSessionRowPresentation.higherSeverity(nil, nil) == nil)
    }

    @Test func higherSeverity_onlyFirstIsFirst() {
        #expect(RemoteSessionRowPresentation.higherSeverity(.error, nil) == .error)
    }

    @Test func higherSeverity_onlySecondIsSecond() {
        #expect(RemoteSessionRowPresentation.higherSeverity(nil, .attentionNeeded) == .attentionNeeded)
    }

    @Test func higherSeverity_picksHigherOfTwo() {
        #expect(RemoteSessionRowPresentation.higherSeverity(.responseComplete, .error) == .error)
        #expect(RemoteSessionRowPresentation.higherSeverity(.error, .responseComplete) == .error)
    }
}
