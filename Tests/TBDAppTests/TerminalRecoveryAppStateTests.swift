import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("Terminal recovery AppState")
@MainActor
struct TerminalRecoveryAppStateTests {
    @Test("automatic request returns in-flight without consuming budget")
    func automaticRequestReturnsInFlightWithoutConsumingBudget() async {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID)]
        state.recreatingTerminalIDs.insert(terminalID)

        #expect(await state.requestAutomaticTerminalRecreation(terminalID: terminalID) ==
            .alreadyInFlight)

        state.finishTerminalRecreation(terminalID: terminalID)
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 1))
    }

    @Test("automatic request preserves attempts across RPC failures")
    func automaticRequestPreservesAttemptsAcrossRPCFailures() async {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID)]

        #expect(await state.requestAutomaticTerminalRecreation(terminalID: terminalID) ==
            .failed(attempt: 1))
        #expect(!state.recreatingTerminalIDs.contains(terminalID))
        #expect(await state.requestAutomaticTerminalRecreation(terminalID: terminalID) ==
            .failed(attempt: 2))
        #expect(!state.recreatingTerminalIDs.contains(terminalID))
        #expect(await state.requestAutomaticTerminalRecreation(terminalID: terminalID) ==
            .budgetExhausted)
    }

    @Test("automatic request reports a previously exhausted budget")
    func automaticRequestReportsPreviouslyExhaustedBudget() async {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID)]
        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)
        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)

        #expect(await state.requestAutomaticTerminalRecreation(terminalID: terminalID) ==
            .budgetExhausted)
        #expect(!state.recreatingTerminalIDs.contains(terminalID))
    }

    @Test("in-flight automatic request consumes no attempt")
    func inFlightAutomaticRequestConsumesNoAttempt() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID)]
        state.recreatingTerminalIDs.insert(terminalID)

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .alreadyInFlight)

        state.finishTerminalRecreation(terminalID: terminalID)
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .claimed(attempt: 1))
    }

    @Test("automatic claims persist across reconstructed callers")
    func automaticClaimsPersistAcrossReconstructedCallers() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID)]

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .claimed(attempt: 1))
        state.finishTerminalRecreation(terminalID: terminalID)

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .claimed(attempt: 2))
        state.finishTerminalRecreation(terminalID: terminalID)

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .budgetExhausted)
    }

    @Test("successful viewer attachment resets automatic budget")
    func successfulViewerAttachmentResetsAutomaticBudget() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID)]

        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)
        state.terminalViewerDidStart(terminalID: terminalID)

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .claimed(attempt: 1))
    }

    @Test("deletion outside recovery clears automatic budget and blocks stale retry")
    func deletionOutsideRecoveryClearsBudgetAndBlocksRetry() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID)]

        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)
        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)

        state.removeDeletedTerminalFromState(terminalID: terminalID, worktreeID: worktreeID)

        #expect(state.terminals[worktreeID]?.isEmpty == true)
        #expect(state.terminalRecoveryBudget.claimAttempt(for: terminalID) == 1)
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .terminalUnavailable)
    }

    @Test("new terminal adoption clears stale UUID budget")
    func newTerminalAdoptionClearsStaleUUIDBudget() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()

        _ = state.terminalRecoveryBudget.claimAttempt(for: terminalID)
        _ = state.terminalRecoveryBudget.claimAttempt(for: terminalID)

        state.adoptCreatedTerminal(terminal(id: terminalID, worktreeID: worktreeID))

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .claimed(attempt: 1))
    }

    @Test("an absent snapshot merge does not reset an existing UUID budget")
    func absentSnapshotMergeDoesNotResetExistingBudget() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()

        _ = state.terminalRecoveryBudget.claimAttempt(for: terminalID)
        _ = state.terminalRecoveryBudget.claimAttempt(for: terminalID)

        state.mergeCreatedTerminal(terminal(id: terminalID, worktreeID: worktreeID))

        #expect(state.terminals[worktreeID]?.map(\.id) == [terminalID])
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .budgetExhausted)
    }

    @Test("deletion during recovery defers cleanup and rejects stale adoption")
    func deletionDuringRecoveryDefersCleanupAndRejectsStaleAdoption() async {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        let snapshot = terminal(id: terminalID, worktreeID: worktreeID)
        state.terminals[worktreeID] = [snapshot]

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 1))

        state.removeDeletedTerminalFromState(terminalID: terminalID, worktreeID: worktreeID)

        #expect(state.terminals[worktreeID]?.isEmpty == true)
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .alreadyInFlight)
        #expect(state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))
        state.terminalViewerDidStart(terminalID: terminalID)
        #expect(state.terminalRecoveryBudget.claimAttempt(for: terminalID) == 2)

        state.mergeCreatedTerminal(snapshot)
        #expect(state.terminals[worktreeID]?.isEmpty == true)
        state.adoptTerminalSnapshot([snapshot], worktreeID: worktreeID)
        #expect(state.terminals[worktreeID]?.isEmpty == true)

        state.finishTerminalRecreation(terminalID: terminalID)

        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))
        #expect(state.terminalRecoveryBudget.claimAttempt(for: terminalID) == 1)
        #expect(await state.requestAutomaticTerminalRecreation(terminalID: terminalID) ==
            .terminalUnavailable)
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
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 1))

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

    @Test("snapshot disappearance preserves recovery budget and in-flight dedup")
    func snapshotDisappearancePreservesRecoveryState() {
        let state = AppState()
        let worktreeID = UUID()
        let completedID = UUID()
        let inFlightID = UUID()
        state.terminals[worktreeID] = [
            terminal(id: completedID, worktreeID: worktreeID),
            terminal(id: inFlightID, worktreeID: worktreeID)
        ]
        _ = state.terminalRecoveryBudget.claimAttempt(for: completedID)
        _ = state.terminalRecoveryBudget.claimAttempt(for: completedID)
        #expect(state.claimAutomaticTerminalRecreation(terminalID: inFlightID) ==
            .claimed(attempt: 1))

        state.adoptTerminalSnapshot([], worktreeID: worktreeID)

        #expect(state.terminals[worktreeID]?.isEmpty == true)
        #expect(state.terminalRecoveryBudget.claimAttempt(for: completedID) == nil)
        #expect(state.recreatingTerminalIDs.contains(inFlightID))
        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(inFlightID))
        #expect(state.recentlyDeletedTerminalIDs[completedID] == nil)
        #expect(state.recentlyDeletedTerminalIDs[inFlightID] == nil)
        #expect(state.claimAutomaticTerminalRecreation(terminalID: inFlightID) == .alreadyInFlight)

        state.finishTerminalRecreation(terminalID: inFlightID)
        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(inFlightID))
        #expect(state.terminalRecoveryBudget.claimAttempt(for: inFlightID) == 2)
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
        _ = state.terminalRecoveryBudget.claimAttempt(for: terminalID)
        _ = state.terminalRecoveryBudget.claimAttempt(for: terminalID)

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
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .budgetExhausted)
    }

    @Test("recreation response updates only a live non-deleted terminal")
    func recreatedTerminalAdoptionHonorsDeletionInvariant() {
        let liveState = AppState()
        let deletedState = AppState()
        let worktreeID = UUID()
        let liveID = UUID()
        let deletedID = UUID()
        let deletedAt = Date(timeIntervalSince1970: 1_000)
        let liveOriginal = terminal(id: liveID, worktreeID: worktreeID, label: "Shell")
        let liveUpdated = terminal(id: liveID, worktreeID: worktreeID, label: "Recovered")
        let deletedOriginal = terminal(id: deletedID, worktreeID: worktreeID, label: "Shell")
        let deletedUpdated = terminal(id: deletedID, worktreeID: worktreeID, label: "Recovered")
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

    @Test("terminal removal delta preserves in-flight dedup until recreation finishes")
    func terminalRemovalDeltaPreservesInFlightDedup() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID)]

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 1))

        state.handleDelta(.terminalRemoved(TerminalIDDelta(terminalID: terminalID)))

        #expect(state.terminals[worktreeID]?.isEmpty == true)
        #expect(state.recreatingTerminalIDs.contains(terminalID))
        #expect(state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .alreadyInFlight)

        state.finishTerminalRecreation(terminalID: terminalID)

        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))
        #expect(state.terminalRecoveryBudget.claimAttempt(for: terminalID) == 1)
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
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID)]
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 1))
        state.terminals[worktreeID] = []

        state.handleDelta(.terminalRemoved(TerminalIDDelta(terminalID: terminalID)))

        #expect(state.recreatingTerminalIDs.contains(terminalID))
        #expect(state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .alreadyInFlight)

        state.finishTerminalRecreation(terminalID: terminalID)
        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(terminalID))
        #expect(state.terminalRecoveryBudget.claimAttempt(for: terminalID) == 1)
    }

    @Test("archiving clears terminal budgets without reopening in-flight recovery")
    func archivingClearsRecoveryStateSafely() {
        let state = AppState()
        let worktreeID = UUID()
        let inFlightID = UUID()
        let completedID = UUID()
        state.terminals[worktreeID] = [
            terminal(id: inFlightID, worktreeID: worktreeID),
            terminal(id: completedID, worktreeID: worktreeID)
        ]
        #expect(state.claimAutomaticTerminalRecreation(terminalID: inFlightID) ==
            .claimed(attempt: 1))
        _ = state.terminalRecoveryBudget.claimAttempt(for: completedID)
        _ = state.terminalRecoveryBudget.claimAttempt(for: completedID)

        state.removeArchivedWorktreeFromState(id: worktreeID)

        #expect(state.terminals[worktreeID] == nil)
        #expect(state.recreatingTerminalIDs.contains(inFlightID))
        #expect(state.terminalDeletionsAwaitingRecreationCompletion.contains(inFlightID))
        #expect(state.claimAutomaticTerminalRecreation(terminalID: inFlightID) == .alreadyInFlight)
        #expect(state.terminalRecoveryBudget.claimAttempt(for: completedID) == 1)

        state.finishTerminalRecreation(terminalID: inFlightID)
        #expect(!state.terminalDeletionsAwaitingRecreationCompletion.contains(inFlightID))
        #expect(state.terminalRecoveryBudget.claimAttempt(for: inFlightID) == 1)
    }

    @Test("repeated UUID merge preserves consumed automatic budget")
    func repeatedUUIDMergePreservesConsumedAutomaticBudget() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.mergeCreatedTerminal(terminal(
            id: terminalID,
            worktreeID: worktreeID,
            label: "Starting Shell"
        ))

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 1))
        state.finishTerminalRecreation(terminalID: terminalID)

        let refreshed = terminal(id: terminalID, worktreeID: worktreeID, label: "Shell")
        state.mergeCreatedTerminal(refreshed)

        #expect(state.terminals[worktreeID] == [refreshed])
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(attempt: 2))
    }

    @Test("manual recreation remains available after automatic exhaustion")
    func manualRecreationRemainsAvailableAfterAutomaticExhaustion() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [terminal(id: terminalID, worktreeID: worktreeID)]

        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)
        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .budgetExhausted)

        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .claimed)
        state.finishTerminalRecreation(terminalID: terminalID)
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .budgetExhausted)
    }

    private func terminal(id: UUID, worktreeID: UUID, label: String = "Shell") -> Terminal {
        Terminal(
            id: id,
            worktreeID: worktreeID,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: label,
            kind: .shell
        )
    }
}
