import Testing
import ArgumentParser
@testable import TBDCLI

@Suite("tbd terminal focus parsing")
struct TerminalFocusCommandTests {
    @Test func parsesTerminalMessageAndActivate() throws {
        let cmd = try TerminalFocus.parse(["--terminal", "ABC", "--message", "look", "--activate"])
        #expect(cmd.terminal == "ABC")
        #expect(cmd.message == "look")
        #expect(cmd.activate == true)
    }

    @Test func activateDefaultsFalseAndMessageOptional() throws {
        let cmd = try TerminalFocus.parse(["--terminal", "ABC"])
        #expect(cmd.activate == false)
        #expect(cmd.message == nil)
    }

    @Test func requiresTerminal() {
        #expect(throws: (any Error).self) {
            _ = try TerminalFocus.parse([])
        }
    }
}
