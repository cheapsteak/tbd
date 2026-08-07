import ArgumentParser
import Testing
@testable import TBDCLI

/// Tier 1 — argument parsing and validation only; no socket, no daemon.
///
/// The daemon enforces every one of these shapes independently, because the CLI
/// is not its only caller. These exist so a human gets the message before a
/// socket is opened, and so the two never drift apart silently.
@Suite("tbd terminal send parsing")
struct TerminalSendCommandTests {

    /// `ParsableCommand.parse` runs `validate()`, so a rejected shape throws
    /// here rather than reaching `run()`.
    private func parse(_ arguments: [String]) throws -> TerminalSend {
        try TerminalSend.parse(arguments)
    }

    // MARK: - The shapes that stand

    @Test("--text alone parses and does not submit")
    func textAlone() throws {
        let cmd = try parse(["--terminal", "ABC", "--text", "hello"])
        #expect(cmd.text == "hello")
        #expect(cmd.keys == nil)
        #expect(cmd.submit == false)
        #expect(cmd.verify == false)
    }

    /// The pair every delivery uses, and the one Nightwatch's Python dispatches.
    @Test("--text --submit parses unchanged")
    func textSubmit() throws {
        let cmd = try parse(["--terminal", "ABC", "--text", "hello", "--submit"])
        #expect(cmd.text == "hello")
        #expect(cmd.submit == true)
    }

    @Test("--keys parses on its own")
    func keysAlone() throws {
        let cmd = try parse(["--terminal", "ABC", "--keys", "Escape Enter"])
        #expect(cmd.keys == "Escape Enter")
        #expect(cmd.text == nil)
    }

    @Test("--verify parses alongside --text --submit")
    func verifyWithTextSubmit() throws {
        let cmd = try parse(["--terminal", "ABC", "--text", "hi", "--submit", "--verify"])
        #expect(cmd.verify == true)
    }

    /// An empty text payload is a real way to press Enter, and must stay
    /// parseable — it is only `--verify` that an empty payload cannot support.
    @Test("empty --text with --submit parses")
    func emptyTextSubmit() throws {
        let cmd = try parse(["--terminal", "ABC", "--text", "", "--submit"])
        #expect(cmd.text == "")
        #expect(cmd.submit == true)
    }

    // MARK: - The shapes that are refused

    @Test("--text and --keys together are refused")
    func bothPayloadsRefused() {
        #expect(throws: (any Error).self) {
            _ = try parse(["--terminal", "ABC", "--text", "hi", "--keys", "Enter"])
        }
    }

    @Test("no payload at all is refused")
    func noPayloadRefused() {
        #expect(throws: (any Error).self) {
            _ = try parse(["--terminal", "ABC"])
        }
    }

    @Test("--submit with --keys is refused")
    func submitWithKeysRefused() {
        #expect(throws: (any Error).self) {
            _ = try parse(["--terminal", "ABC", "--keys", "Escape", "--submit"])
        }
    }

    @Test("--verify with --keys is refused")
    func verifyWithKeysRefused() {
        #expect(throws: (any Error).self) {
            _ = try parse(["--terminal", "ABC", "--keys", "Escape", "--verify"])
        }
    }

    @Test("--verify without --submit is refused")
    func verifyWithoutSubmitRefused() {
        #expect(throws: (any Error).self) {
            _ = try parse(["--terminal", "ABC", "--text", "hi", "--verify"])
        }
    }

    @Test("--verify with an empty --text is refused")
    func verifyWithEmptyTextRefused() {
        #expect(throws: (any Error).self) {
            _ = try parse(["--terminal", "ABC", "--text", "", "--submit", "--verify"])
        }
    }
}
