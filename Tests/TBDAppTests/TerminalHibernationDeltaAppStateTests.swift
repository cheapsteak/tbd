import Foundation
import TestSupport
import Testing
@testable import TBDApp
import TBDShared

/// `terminalHibernationChanged` delta application to the cached terminal row.
///
/// The parked `TerminalPanelView` materializes the instant `isParked` flips
/// (identity `id-tmuxWindowID-isParked`) and reads `initialSnapshot` from the
/// cached row ONCE at creation, and wake-on-focus filters on the cached row's
/// `hibernateReason` — so BOTH must land on the row together with the
/// `hibernated` flip, not in the later `refreshTerminals` refetch.
@MainActor
@Suite("Hibernation delta handling")
struct TerminalHibernationDeltaAppStateTests {

    private func withState(_ body: (AppState) -> Void) {
        let defaultsSuite = TestDefaultsSuite("HibernationDelta")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        body(AppState(userDefaults: defaults))
    }

    @Test func hibernateDelta_populatesSnapshotAndReasonOnCachedRow() {
        withState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            state.terminals = [worktreeID: [
                Terminal(id: terminalID, worktreeID: worktreeID,
                         tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
            ]]

            state.handleDelta(.terminalHibernationChanged(TerminalHibernationDelta(
                terminalID: terminalID, worktreeID: worktreeID,
                hibernated: true, keepWarm: false,
                suspendedSnapshot: "FROZEN PANE", hibernateReason: .manual
            )))

            let row = state.terminals[worktreeID]?[0]
            #expect(row?.hibernatedAt != nil)
            #expect(row?.suspendedSnapshot == "FROZEN PANE",
                    "the parked view reads the cached row's snapshot at creation — it must arrive with the flip")
            #expect(row?.hibernateReason == .manual,
                    "wake-on-focus filters on the cached reason — it must arrive with the flip")
        }
    }

    /// Parking implies cancellation: the daemon's `setHibernated` cancels any
    /// scheduled auto-resume in the same write, so a `hibernated == true`
    /// delta must nil the cached row's `pendingResumeAt` mirror too —
    /// otherwise the tab's ⏳ glyph and "Cancel Scheduled Resume" item keep
    /// advertising a resume that won't happen for the delta-to-refetch window.
    @Test func hibernateDelta_clearsPendingResumeAt() {
        withState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            state.terminals = [worktreeID: [
                Terminal(id: terminalID, worktreeID: worktreeID,
                         tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude,
                         pendingResumeAt: Date(timeIntervalSince1970: 1_800_000_000))
            ]]

            state.handleDelta(.terminalHibernationChanged(TerminalHibernationDelta(
                terminalID: terminalID, worktreeID: worktreeID,
                hibernated: true, keepWarm: false,
                suspendedSnapshot: nil, hibernateReason: .merged
            )))

            #expect(state.terminals[worktreeID]?[0].pendingResumeAt == nil,
                    "parking cancels the scheduled resume — the cached mirror must clear with the flip")
        }
    }

    /// A wake delta carries no scheduled-resume information, so it must leave
    /// `pendingResumeAt` alone — the refetch is the source of truth for any
    /// resume scheduled after the wake.
    @Test func wakeDelta_leavesPendingResumeAtAlone() {
        withState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            let resumeAt = Date(timeIntervalSince1970: 1_800_000_000)
            state.terminals = [worktreeID: [
                Terminal(id: terminalID, worktreeID: worktreeID,
                         tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude,
                         hibernatedAt: Date(), hibernateReason: .auto,
                         pendingResumeAt: resumeAt)
            ]]

            state.handleDelta(.terminalHibernationChanged(TerminalHibernationDelta(
                terminalID: terminalID, worktreeID: worktreeID,
                hibernated: false, keepWarm: false
            )))

            #expect(state.terminals[worktreeID]?[0].pendingResumeAt == resumeAt,
                    "a wake delta says nothing about scheduled resumes — leave the mirror for the refetch")
        }
    }

    @Test func wakeDelta_clearsReasonAndParkFlag_keepsSnapshot() {
        withState { state in
            let worktreeID = UUID()
            let terminalID = UUID()
            state.terminals = [worktreeID: [
                Terminal(id: terminalID, worktreeID: worktreeID,
                         tmuxWindowID: "@1", tmuxPaneID: "%1",
                         suspendedSnapshot: "FROZEN PANE", kind: .claude,
                         hibernatedAt: Date(), hibernateReason: .manual)
            ]]

            state.handleDelta(.terminalHibernationChanged(TerminalHibernationDelta(
                terminalID: terminalID, worktreeID: worktreeID,
                hibernated: false, keepWarm: false
            )))

            let row = state.terminals[worktreeID]?[0]
            #expect(row?.hibernatedAt == nil)
            #expect(row?.hibernateReason == nil,
                    "wake clears the reason, matching the daemon's clearHibernated")
            // clearHibernated deliberately KEEPS suspendedSnapshot in the DB so
            // the woken view can show the frozen pane while the live tmux
            // client reconnects — the cached row must match.
            #expect(row?.suspendedSnapshot == "FROZEN PANE")
        }
    }
}
