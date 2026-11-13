import GhosttyVt
@testable import TBDGhosttyCore
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// A detach can come in the middle of an escape sequence, so a terminal must be clonable there.
/// libghostty can clone one only if it kept the unfinished bytes, and it keeps them only when
/// tracking was on before they arrived.
///
/// This file imports `GhosttyVt` for `ghostty_snapshot_encode_alloc`, whose C terminal type is also
/// named `GhosttyTerminal`, so the Swift class is spelled with its module name throughout.
@Suite(.fastPassBounded)
struct ContinuationTests {
    /// Half an SGR: a 256-colour foreground with its index cut short.
    private static let partial = Array("\u{1b}[38;5".utf8)
    private static let remainder = Array(";196mX".utf8)

    private static func makeTerminal() throws -> TBDGhosttyCore.GhosttyTerminal {
        try TBDGhosttyCore.GhosttyTerminal(
            cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
    }

    /// `ghostty_snapshot_encode` into a buffer it allocates, which is freed at once: only whether
    /// the encode worked matters here.
    private static func encodeSnapshot(_ raw: VtTerminal) -> GhosttyResult {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        let result = ghostty_snapshot_encode_alloc(raw, nil, &bytes, &length)
        if result == GHOSTTY_SUCCESS { ghostty_free(nil, bytes, length) }
        return result
    }

    @Test func terminalStoppedMidSequenceCanBeClonedAndThenFinishesIt() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        terminal.feed(Self.partial[...])

        let (limit, encoded, pending) = try terminal.withLocked { state -> (Int, GhosttyResult, [UInt8]?) in
            let raw = try #require(state.raw, "the terminal is closed")
            var limit = 0
            _ = ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_CONTINUATION_MAX_BYTES, &limit)
            return (limit, Self.encodeSnapshot(raw), state.pendingContinuationBytes())
        }
        #expect(limit == TBDGhosttyCore.GhosttyTerminal.continuationMaxBytes,
                "continuation tracking is set to \(limit) bytes")
        #expect(encoded == GHOSTTY_SUCCESS, "cloning in the middle of an SGR returned \(encoded.rawValue)")
        #expect(pending == Self.partial, "the pending bytes were \(String(describing: pending))")

        // The rest of the sequence, from the live stream, completes it.
        terminal.feed(Self.remainder[...])
        let (text, color, pendingAfter) = terminal.withLocked { state in
            (state.lineText(0), state.foregroundPaletteIndex(column: 0, row: 0), state.pendingContinuationBytes())
        }
        #expect(text == "X", "row 0 reads \(text.debugDescription)")
        #expect(color == 196, "the X has palette colour \(String(describing: color))")
        #expect(pendingAfter == [UInt8](), "with the sequence finished, \(String(describing: pendingAfter)) is still pending")
    }

    /// The control for the test above. With tracking off, libghostty refuses to clone the same
    /// half sequence, so the encode there succeeds because tracking is on and not regardless.
    @Test func withoutTrackingATerminalStoppedMidSequenceCannotBeCloned() throws {
        let terminal = try Self.makeTerminal()
        defer { terminal.close() }
        try terminal.withLocked { state in
            let raw = try #require(state.raw, "the terminal is closed")
            let disabled = ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, nil)
            try #require(disabled == GHOSTTY_SUCCESS, "turning tracking off returned \(disabled.rawValue)")
        }
        terminal.feed(Self.partial[...])

        let (encoded, pending) = try terminal.withLocked { state -> (GhosttyResult, [UInt8]?) in
            let raw = try #require(state.raw, "the terminal is closed")
            return (Self.encodeSnapshot(raw), state.pendingContinuationBytes())
        }
        #expect(encoded != GHOSTTY_SUCCESS, "with tracking off, cloning in the middle of an SGR succeeded")
        #expect(pending == nil, "with tracking off, \(String(describing: pending)) was reported pending")
    }
}
