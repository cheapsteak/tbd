import Foundation
import Testing
@testable import TBDDaemonLib

/// Unit tests for the `send-keys -H` hex encoder (addendum §2). No tmux.
@Suite("SendKeysEncoder")
struct SendKeysEncoderTests {

    /// Parse the hex tokens back out of an emitted command, ignoring the
    /// `send-keys -H -t %pane ` prefix, so order/round-trip can be asserted.
    private func hexTokens(of command: String, paneID: String) -> [String] {
        let prefix = "send-keys -H -t \(paneID) "
        #expect(command.hasPrefix(prefix), "command must start with the send-keys -H prefix: \(command)")
        let tail = String(command.dropFirst(prefix.count))
        return tail.split(separator: " ").map(String.init)
    }

    @Test("empty input emits no commands (never a blank command)")
    func emptyIsNoCommands() {
        #expect(SendKeysEncoder.commands(paneID: "%0", bytes: Data()) == [])
    }

    @Test("a single byte emits one command with one hex token")
    func singleByte() {
        let commands = SendKeysEncoder.commands(paneID: "%3", bytes: Data([0x68]))
        #expect(commands == ["send-keys -H -t %3 68"])
    }

    @Test("exactly maxBytesPerCommand fits in one command")
    func boundaryExactlyOneCommand() {
        let bytes = Data(repeating: 0x61, count: 330)
        let commands = SendKeysEncoder.commands(paneID: "%0", bytes: bytes, maxBytesPerCommand: 330)
        #expect(commands.count == 1)
        #expect(hexTokens(of: commands[0], paneID: "%0").count == 330)
    }

    @Test("one past the cap splits into two commands (330 + 1)")
    func boundaryOnePastCap() {
        let bytes = Data(repeating: 0x61, count: 331)
        let commands = SendKeysEncoder.commands(paneID: "%0", bytes: bytes, maxBytesPerCommand: 330)
        #expect(commands.count == 2)
        #expect(hexTokens(of: commands[0], paneID: "%0").count == 330)
        #expect(hexTokens(of: commands[1], paneID: "%0").count == 1)
    }

    @Test("a large paste chunks by the cap and reassembles in order")
    func largePasteChunkOrder() {
        // 4096 distinct-ish bytes; reassembled hex must equal the input order.
        let input = (0..<4096).map { UInt8($0 & 0xff) }
        let commands = SendKeysEncoder.commands(paneID: "%7", bytes: Data(input), maxBytesPerCommand: 330)
        #expect(commands.count == (4096 + 329) / 330)   // ceil
        for command in commands {
            #expect(hexTokens(of: command, paneID: "%7").count <= 330)
        }
        let reassembled = commands.flatMap { hexTokens(of: $0, paneID: "%7") }
        let expected = input.map { String(format: "%02x", $0) }
        #expect(reassembled == expected)
    }

    @Test("hex is lowercase, two digits, for boundary byte values")
    func hexCorrectness() {
        let commands = SendKeysEncoder.commands(paneID: "%0", bytes: Data([0x00, 0x1f, 0xff]))
        #expect(commands == ["send-keys -H -t %0 00 1f ff"])
    }

    @Test("UTF-8 multibyte bytes pass through verbatim")
    func utf8Passthrough() {
        let bytes = Data("é→".utf8)   // é = c3 a9, → = e2 86 92
        let commands = SendKeysEncoder.commands(paneID: "%0", bytes: bytes)
        #expect(commands == ["send-keys -H -t %0 c3 a9 e2 86 92"])
    }

    @Test("every emitted command is non-blank and prefixed")
    func nonBlankPrefixed() {
        let commands = SendKeysEncoder.commands(paneID: "%12", bytes: Data(repeating: 0x03, count: 700))
        #expect(!commands.isEmpty)
        for command in commands {
            #expect(command.hasPrefix("send-keys -H -t %12 "))
            #expect(!command.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
