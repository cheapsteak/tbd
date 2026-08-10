import Foundation
import Testing
@testable import TBDApp

@Suite("Terminal recovery budget")
struct TerminalRecoveryBudgetTests {
    @Test("claims two attempts, then exhausts")
    func claimsTwoAttemptsThenExhausts() {
        var budget = TerminalRecoveryBudget()
        let terminalID = UUID()

        #expect(budget.claimAttempt(for: terminalID) == 1)
        #expect(budget.claimAttempt(for: terminalID) == 2)
        #expect(budget.claimAttempt(for: terminalID) == nil)
    }

    @Test("reset restores the first attempt")
    func resetRestoresFirstAttempt() {
        var budget = TerminalRecoveryBudget()
        let terminalID = UUID()

        _ = budget.claimAttempt(for: terminalID)
        _ = budget.claimAttempt(for: terminalID)
        budget.reset(for: terminalID)

        #expect(budget.claimAttempt(for: terminalID) == 1)
    }

    @Test("terminal attempt counts remain independent")
    func terminalAttemptCountsRemainIndependent() {
        var budget = TerminalRecoveryBudget()
        let firstTerminalID = UUID()
        let secondTerminalID = UUID()

        #expect(budget.claimAttempt(for: firstTerminalID) == 1)
        #expect(budget.claimAttempt(for: firstTerminalID) == 2)
        #expect(budget.claimAttempt(for: secondTerminalID) == 1)
        #expect(budget.claimAttempt(for: firstTerminalID) == nil)
        #expect(budget.claimAttempt(for: secondTerminalID) == 2)
    }
}
