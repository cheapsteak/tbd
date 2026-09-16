import ArgumentParser
import Foundation
import Testing
@testable import TBDCLI
import TBDShared

@Suite("tbd terminal continue-in-claude")
struct TerminalContinueInClaudeCommandTests {
    private let terminalID = "2D5B06CC-4930-445D-B562-7BF7C1706418"

    @Test("requires the named terminal option")
    func requiresTerminalOption() {
        #expect(throws: (any Error).self) {
            _ = try TerminalContinueInClaude.parse([])
        }
        #expect(throws: (any Error).self) {
            _ = try TerminalContinueInClaude.parse([terminalID])
        }
    }

    @Test("accepts an ambient-account request")
    func parsesAmbientRequest() throws {
        let command = try TerminalContinueInClaude.parse([
            "--terminal", terminalID,
        ])

        #expect(command.terminal == terminalID)
        #expect(command.profile == nil)
        #expect(!command.json)
    }

    @Test("accepts profile selection and JSON output")
    func parsesProfileAndJSON() throws {
        let command = try TerminalContinueInClaude.parse([
            "--terminal", terminalID,
            "--profile", "Work",
            "--json",
        ])

        #expect(command.terminal == terminalID)
        #expect(command.profile == "Work")
        #expect(command.json)
    }

    @Test("accepts a profile UUID for the shared resolver")
    func parsesProfileUUID() throws {
        let profileID = UUID().uuidString
        let command = try TerminalContinueInClaude.parse([
            "--terminal", terminalID,
            "--profile", profileID,
        ])

        #expect(command.profile == profileID)
    }

    @Test("plain output reports the unchanged row and selected account")
    func rendersReplacementOutcome() {
        let id = UUID(uuidString: terminalID)!
        let terminal = Terminal(
            id: id,
            worktreeID: UUID(),
            tmuxWindowID: "@9",
            tmuxPaneID: "%9",
            claudeSessionID: "claude-session",
            profileID: UUID(),
            kind: .claude)

        let output = TerminalContinueInClaude.plainOutput(
            terminal: terminal,
            accountLabel: "Work")

        #expect(output.contains("Terminal: \(id)"))
        #expect(output.contains("Account:  Work"))
    }
}
