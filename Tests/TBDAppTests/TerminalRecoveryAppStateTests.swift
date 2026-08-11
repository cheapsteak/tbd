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
        let terminalID = UUID()
        state.recreatingTerminalIDs.insert(terminalID)

        #expect(await state.requestAutomaticTerminalRecreation(terminalID: terminalID) ==
            .alreadyInFlight)

        state.finishTerminalRecreation(terminalID: terminalID)
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(automaticAttempt: 1))
    }

    @Test("automatic request preserves attempts across RPC failures")
    func automaticRequestPreservesAttemptsAcrossRPCFailures() async {
        let state = AppState()
        let terminalID = UUID()

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
        let terminalID = UUID()
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
        let terminalID = UUID()
        state.recreatingTerminalIDs.insert(terminalID)

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .alreadyInFlight)

        state.finishTerminalRecreation(terminalID: terminalID)
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .claimed(automaticAttempt: 1))
    }

    @Test("automatic claims persist across reconstructed callers")
    func automaticClaimsPersistAcrossReconstructedCallers() {
        let state = AppState()
        let terminalID = UUID()

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .claimed(automaticAttempt: 1))
        state.finishTerminalRecreation(terminalID: terminalID)

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .claimed(automaticAttempt: 2))
        state.finishTerminalRecreation(terminalID: terminalID)

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .budgetExhausted)
    }

    @Test("successful viewer attachment resets automatic budget")
    func successfulViewerAttachmentResetsAutomaticBudget() {
        let state = AppState()
        let terminalID = UUID()

        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)
        state.terminalViewerDidStart(terminalID: terminalID)

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .claimed(automaticAttempt: 1))
    }

    @Test("deletion clears automatic budget")
    func deletionClearsAutomaticBudget() {
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
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .claimed(automaticAttempt: 1))
    }

    @Test("new terminal adoption clears stale UUID budget")
    func newTerminalAdoptionClearsStaleUUIDBudget() {
        let state = AppState()
        let worktreeID = UUID()
        let terminalID = UUID()

        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)
        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)

        state.mergeCreatedTerminal(terminal(id: terminalID, worktreeID: worktreeID))

        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .claimed(automaticAttempt: 1))
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
            .claimed(automaticAttempt: 1))
        state.finishTerminalRecreation(terminalID: terminalID)

        let refreshed = terminal(id: terminalID, worktreeID: worktreeID, label: "Shell")
        state.mergeCreatedTerminal(refreshed)

        #expect(state.terminals[worktreeID] == [refreshed])
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) ==
            .claimed(automaticAttempt: 2))
    }

    @Test("manual recreation remains available after automatic exhaustion")
    func manualRecreationRemainsAvailableAfterAutomaticExhaustion() {
        let state = AppState()
        let terminalID = UUID()

        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)
        _ = state.claimAutomaticTerminalRecreation(terminalID: terminalID)
        state.finishTerminalRecreation(terminalID: terminalID)
        #expect(state.claimAutomaticTerminalRecreation(terminalID: terminalID) == .budgetExhausted)

        #expect(state.claimManualTerminalRecreation(terminalID: terminalID) == .claimed(automaticAttempt: nil))
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
