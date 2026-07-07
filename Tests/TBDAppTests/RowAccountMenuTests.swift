import Foundation
import Testing
@testable import TBDApp
import TBDShared

// MARK: - Fixtures

private func claudeTerminal(label: String?) -> Terminal {
    Terminal(id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
             label: label, createdAt: Date(timeIntervalSince1970: 0), kind: .claude)
}

@Suite("RowAccountMenu — session label")
struct RowAccountMenuSessionLabelTests {
    @Test func labelFallsBackToClaudeIndexWhenTerminalHasNoLabel() {
        #expect(RowAccountMenu.sessionLabel(terminal: claudeTerminal(label: nil),
                                            fallbackIndex: 3) == "Claude 3")
        #expect(RowAccountMenu.sessionLabel(terminal: claudeTerminal(label: "   "),
                                            fallbackIndex: 1) == "Claude 1")
        #expect(RowAccountMenu.sessionLabel(terminal: claudeTerminal(label: "Reviewer"),
                                            fallbackIndex: 1) == "Reviewer")
    }
}
