import Testing
import ArgumentParser
@testable import TBDCLI

@Suite("tbd terminal pin parsing")
struct TerminalPinCommandTests {
    @Test func pinParsesTerminalArgument() throws {
        let cmd = try TerminalPin.parse(["ABC"])
        #expect(cmd.terminal == "ABC")
    }

    @Test func unpinParsesTerminalArgument() throws {
        let cmd = try TerminalUnpin.parse(["ABC"])
        #expect(cmd.terminal == "ABC")
    }

    @Test func pinRequiresTerminal() {
        #expect(throws: (any Error).self) {
            _ = try TerminalPin.parse([])
        }
    }

    @Test func unpinRequiresTerminal() {
        #expect(throws: (any Error).self) {
            _ = try TerminalUnpin.parse([])
        }
    }
}
