import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// AppState's half of a window recreate — the leftover tmux notice's Check
/// Again — and the deletion guards that keep a late daemon response from
/// bringing a removed terminal back.
///
/// The recreate tests use a row on tmux, the only row Check Again reaches; the
/// snapshot and deletion tests use holder rows, because nothing in them
/// depends on the transport.
@Suite("Terminal recreation AppState")
@MainActor
struct TerminalRecoveryAppStateTests {
    @Test("a recreate already in flight is not claimed again")
    func aRecreateInFlightIsNotClaimedAgain() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID, transport: .tmux)]
        state.recreatingTerminalIDs.insert(terminalID)

        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .alreadyInFlight)

        state.finishTerminalRecreation(terminalID: terminalID)
        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .claimed)
    }

    @Test("a terminal AppState does not hold cannot be recreated")
    func anUnknownTerminalCannotBeRecreated() {
        let state = AppState()
        #expect(state.claimManualTerminalRecreation(terminalID: UUID()) == .terminalUnavailable)
    }

    /// A request that never reached the daemon is no refusal to show, and it
    /// must not leave the terminal claimed: the next Check Again has to run.
    @Test("a recreate that fails without a daemon refusal releases its claim")
    func aFailedRecreateReleasesItsClaim() async {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID, transport: .tmux)]

        let refusal = await state.recreateTerminalWindow(terminalID: terminalID)

        #expect(refusal == nil, "a failure the daemon did not write was shown as its refusal")
        #expect(!state.recreatingTerminalIDs.contains(terminalID))
        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .claimed)
    }

    @Test("deletion outside a recreate blocks a stale retry")
    func deletionOutsideARecreateBlocksAStaleRetry() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID, transport: .tmux)]

        state.removeDeletedTerminalFromState(terminalID: terminalID, worktreeID: worktreeID)

        #expect(state.terminals[worktreeID]?.isEmpty == true)
        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))
        #expect(state.recentlyDeletedTerminalIDs[terminalID] != nil)
        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .terminalUnavailable)
    }

    @Test("deletion during a recreate defers cleanup and rejects stale adoption")
    func deletionDuringARecreateDefersCleanupAndRejectsStaleAdoption() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        let snapshot = terminal(id: terminalID, worktreeID: worktreeID, transport: .tmux)
        state.terminals[worktreeID] = [snapshot]

        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .claimed)

        state.removeDeletedTerminalFromState(terminalID: terminalID, worktreeID: worktreeID)

        #expect(state.terminals[worktreeID]?.isEmpty == true)
        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .alreadyInFlight)
        #expect(state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))

        state.mergeCreatedTerminal(snapshot)
        #expect(state.terminals[worktreeID]?.isEmpty == true)
        state.adoptTerminalSnapshot([snapshot], worktreeID: worktreeID)
        #expect(state.terminals[worktreeID]?.isEmpty == true)
        state.adoptRecreatedTerminal(snapshot)
        #expect(state.terminals[worktreeID]?.isEmpty == true)

        state.finishTerminalRecreation(terminalID: terminalID)

        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))
        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .terminalUnavailable)
    }

    @Test("recent deletion blocks stale snapshots only until its bounded expiry")
    func recentDeletionTombstoneExpires() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        let snapshot = terminal(id: terminalID, worktreeID: worktreeID)
        let deletedAt = Date(timeIntervalSince1970: 1_000)
        #expect(AppState.terminalDeletionTombstoneTTL ==
            DaemonClient.rpcRecvDeadlineSeconds + 30)
        state.terminals[worktreeID] = [snapshot]
        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .claimed)

        state.removeDeletedTerminalFromState(
            terminalID: terminalID,
            worktreeID: worktreeID,
            date: deletedAt
        )
        state.finishTerminalRecreation(terminalID: terminalID)

        state.adoptTerminalSnapshot(
            [snapshot],
            worktreeID: worktreeID,
            date: deletedAt.addingTimeInterval(AppState.terminalDeletionTombstoneTTL - 1)
        )
        #expect(state.terminals[worktreeID]?.isEmpty == true)
        #expect(state.recentlyDeletedTerminalIDs[terminalID] == deletedAt)

        state.adoptTerminalSnapshot(
            [snapshot],
            worktreeID: worktreeID,
            date: deletedAt.addingTimeInterval(AppState.terminalDeletionTombstoneTTL + 1)
        )
        #expect(state.terminals[worktreeID] == [snapshot])
        #expect(state.recentlyDeletedTerminalIDs[terminalID] == nil)
    }

    @Test("snapshot disappearance preserves in-flight dedup")
    func snapshotDisappearancePreservesInFlightDedup() {
        let state = AppState()
        let worktreeID = UUID()
        let completedID = UUID()
        let inFlightID = UUID()
        state.terminals[worktreeID] = [
            terminal(id: completedID, worktreeID: worktreeID),
            terminal(id: inFlightID, worktreeID: worktreeID)
        ]
        #expect(state.claimManualTerminalRecreation(terminalID: inFlightID) == .claimed)

        state.adoptTerminalSnapshot([], worktreeID: worktreeID)

        #expect(state.terminals[worktreeID]?.isEmpty == true)
        #expect(state.recreatingTerminalIDs.contains(inFlightID))
        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(inFlightID))
        #expect(state.recentlyDeletedTerminalIDs[completedID] == nil)
        #expect(state.recentlyDeletedTerminalIDs[inFlightID] == nil)
        #expect(state.claimManualTerminalRecreation(terminalID: inFlightID) == .alreadyInFlight)

        state.finishTerminalRecreation(terminalID: inFlightID)
        #expect(!state.recreatingTerminalIDs.contains(inFlightID))
        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(inFlightID))
    }

    @Test("a stale older omission cannot suppress a fresh terminal snapshot")
    func unorderedSnapshotsDoNotTombstoneTerminalAbsence() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        let snapshot = terminal(id: terminalID, worktreeID: worktreeID)
        let olderRequestDate = Date(timeIntervalSince1970: 1_000)
        let newerRequestDate = Date(timeIntervalSince1970: 1_001)
        state.adoptTerminalSnapshot(
            [snapshot],
            worktreeID: worktreeID,
            date: newerRequestDate
        )

        // A stale response completes after the newer response and omits the
        // terminal; a subsequent fresh response must restore it immediately.
        state.adoptTerminalSnapshot(
            [],
            worktreeID: worktreeID,
            date: olderRequestDate
        )
        state.adoptTerminalSnapshot(
            [snapshot],
            worktreeID: worktreeID,
            date: newerRequestDate.addingTimeInterval(1)
        )

        #expect(state.terminals[worktreeID] == [snapshot])
        #expect(state.recentlyDeletedTerminalIDs[terminalID] == nil)
    }

    @Test("recreation response updates only a live non-deleted terminal")
    func recreatedTerminalAdoptionHonorsDeletionInvariant() {
        let liveState = AppState()
        let deletedState = AppState()
        let worktreeID = UUID()
        let liveID = UUID()
        let deletedID = UUID()
        let deletedAt = Date(timeIntervalSince1970: 1_000)
        let liveOriginal = terminal(id: liveID, worktreeID: worktreeID, label: "Shell", transport: .tmux)
        let liveUpdated = terminal(id: liveID, worktreeID: worktreeID, label: "Recovered", transport: .tmux)
        let deletedOriginal = terminal(id: deletedID, worktreeID: worktreeID, label: "Shell", transport: .tmux)
        let deletedUpdated = terminal(
            id: deletedID, worktreeID: worktreeID, label: "Recovered", transport: .tmux)
        liveState.terminals[worktreeID] = [liveOriginal]
        deletedState.terminals[worktreeID] = [deletedOriginal]

        liveState.adoptRecreatedTerminal(liveUpdated)
        deletedState.removeDeletedTerminalFromState(
            terminalID: deletedID,
            worktreeID: worktreeID,
            date: deletedAt
        )
        deletedState.adoptRecreatedTerminal(
            deletedUpdated,
            date: deletedAt.addingTimeInterval(1)
        )

        #expect(liveState.terminals[worktreeID] == [liveUpdated])
        #expect(deletedState.terminals[worktreeID]?.isEmpty == true)
    }

    /// Check Again on a stopped server answers with the row parked, and that
    /// answer is what moves the pane off the leftover notice.
    @Test("a recreate answered with a parked row takes the row off the leftover notice")
    func aParkedAnswerTakesTheRowOffTheNotice() throws {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        let live = terminal(id: terminalID, worktreeID: worktreeID, transport: .tmux)
        state.terminals[worktreeID] = [live]
        #expect(TerminalPanePresentation.showsLeftoverTmuxNotice(for: live))

        let parked = Terminal(
            id: terminalID, worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Shell", kind: .shell, hibernatedAt: Date(), hibernateReason: .recovery,
            transport: .tmux)
        state.adoptRecreatedTerminal(parked)

        let adopted = try #require(state.terminals[worktreeID]?.first)
        #expect(adopted == parked)
        #expect(!TerminalPanePresentation.showsLeftoverTmuxNotice(for: adopted))
    }

    @Test("terminal removal delta preserves in-flight dedup until recreation finishes")
    func terminalRemovalDeltaPreservesInFlightDedup() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID, transport: .tmux)]

        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .claimed)

        state.handleDelta(.terminalRemoved(TerminalIDDelta(terminalID: terminalID)))

        #expect(state.terminals[worktreeID]?.isEmpty == true)
        #expect(state.recreatingTerminalIDs.contains(terminalID))
        #expect(state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))
        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .alreadyInFlight)

        state.finishTerminalRecreation(terminalID: terminalID)

        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))
        #expect(!state.recreatingTerminalIDs.contains(terminalID))
    }

    @Test("terminal removal delta resolves a rowless terminal from its split layout")
    func terminalRemovalDeltaReconcilesGhostLayout() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        let tabID = UUID()
        let webID = UUID()
        let webContent = PaneContent.webview(
            id: webID,
            url: URL(string: "https://example.com")!
        )
        state.terminals[worktreeID] = []
        state.tabs[worktreeID] = [Tab(id: tabID, content: webContent, label: nil)]
        state.layouts[tabID] = .split(
            id: UUID(),
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .pane(webContent)
            ],
            ratios: [0.5, 0.5]
        )

        state.handleDelta(.terminalRemoved(TerminalIDDelta(terminalID: terminalID)))

        #expect(state.layouts[tabID] == .pane(webContent))
        #expect(state.tabs[worktreeID]?.first?.content == webContent)
        #expect(state.recentlyDeletedTerminalIDs[terminalID] != nil)
    }

    @Test("unknown terminal removal delta still protects an in-flight recreation")
    func unknownTerminalRemovalDeltaProtectsInFlightRecreation() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID, transport: .tmux)]
        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .claimed)
        state.terminals[worktreeID] = []

        state.handleDelta(.terminalRemoved(TerminalIDDelta(terminalID: terminalID)))

        #expect(state.recreatingTerminalIDs.contains(terminalID))
        #expect(state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))
        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .alreadyInFlight)

        state.finishTerminalRecreation(terminalID: terminalID)
        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))
    }

    @Test("archiving keeps an in-flight recreate claimed until it finishes")
    func archivingKeepsAnInFlightRecreateClaimed() {
        let state = AppState()
        let worktreeID = UUID()
        let inFlightID = UUID()
        let otherID = UUID()
        state.terminals[worktreeID] = [
            terminal(id: inFlightID, worktreeID: worktreeID, transport: .tmux),
            terminal(id: otherID, worktreeID: worktreeID)
        ]
        #expect(state.claimManualTerminalRecreation(terminalID: inFlightID) == .claimed)

        state.removeArchivedWorktreeFromState(id: worktreeID)

        #expect(state.terminals[worktreeID] == nil)
        #expect(state.recreatingTerminalIDs.contains(inFlightID))
        #expect(state.terminalDeletionsAwaitingRecreationCompletion.contains(inFlightID))
        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(otherID))
        #expect(state.claimManualTerminalRecreation(terminalID: inFlightID) == .alreadyInFlight)

        state.finishTerminalRecreation(terminalID: inFlightID)
        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(inFlightID))
        #expect(state.claimManualTerminalRecreation(terminalID: inFlightID) == .terminalUnavailable)
    }

    @Test("a repeated UUID merge replaces the earlier row")
    func repeatedUUIDMergeReplacesTheEarlierRow() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.mergeCreatedTerminal(terminal(
            id: terminalID,
            worktreeID: worktreeID,
            label: "Starting Shell"
        ))

        let refreshed = terminal(id: terminalID, worktreeID: worktreeID, label: "Shell")
        state.mergeCreatedTerminal(refreshed)

        #expect(state.terminals[worktreeID] == [refreshed])
    }

    private func terminal(
        id: UUID, worktreeID: UUID, label: String = "Shell",
        transport: TerminalTransport = .holder
    ) -> Terminal {
        // A holder row carries EMPTY tmux coordinates by construction.
        let isHolder = transport == .holder
        return Terminal(
            id: id,
            worktreeID: worktreeID,
            tmuxWindowID: isHolder ? "" : "@1",
            tmuxPaneID: isHolder ? "" : "%1",
            label: label,
            kind: .shell,
            transport: transport
        )
    }
}
