import ArgumentParser
import Testing
@testable import TBDCLI

@Suite("tbd terminal continue-in-codex parsing")
struct TerminalContinueInCodexCommandTests {
    @Test("accepts a positional terminal ID")
    func parsesTerminalID() throws {
        let id = "2D5B06CC-4930-445D-B562-7BF7C1706418"
        let command = try TerminalContinueInCodex.parse([id])

        #expect(command.terminal == id)
        #expect(!command.json)
    }

    @Test("accepts JSON output")
    func parsesJSONFlag() throws {
        let id = "2D5B06CC-4930-445D-B562-7BF7C1706418"
        let command = try TerminalContinueInCodex.parse([id, "--json"])

        #expect(command.terminal == id)
        #expect(command.json)
    }

    @Test("requires a terminal ID")
    func requiresTerminalID() {
        #expect(throws: (any Error).self) {
            _ = try TerminalContinueInCodex.parse([])
        }
    }
}
