import Foundation
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

@Suite(.fastPassBounded)
struct KeyEncoderTests {
    /// `ghostty_key_event_set_utf8` does not copy. The event outlives `encode`, so leaving the
    /// text set would leave the event pointing into a buffer Swift frees as `withUTF8` returns.
    @Test func encodeClearsTheEventTextBeforeReturning() throws {
        let terminal = try GhosttyTerminal(cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        let encoder = try KeyEncoder()
        let press = KeyPress(
            key: MacKeyCodes.key(forVirtualKeyCode: 0x00), text: "a", unshiftedCodepoint: 0x61)

        let bytes = try terminal.withLocked { state in
            try encoder.encode(press, terminal: try #require(state.raw, "the terminal is closed"))
        }

        #expect(bytes == Array("a".utf8), "the press encoded as \(bytes), not as its text")
        #expect(encoder.eventTextLength == 0, "the event still points at \(encoder.eventTextLength) bytes of freed text")
    }
}
