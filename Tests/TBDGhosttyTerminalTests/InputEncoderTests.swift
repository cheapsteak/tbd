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

@Suite(.fastPassBounded)
struct MouseEncoderTests {
    /// Ten-pixel cells, so the point (5, 5) is cell 1;1.
    private static let geometry = TerminalPixelGeometry(screenWidth: 100, screenHeight: 100, cellWidth: 10, cellHeight: 10)
    private static let point = SurfacePoint(x: 5, y: 5)

    private func encode(_ press: MousePress, with encoder: MouseEncoder, on terminal: GhosttyTerminal) throws -> [UInt8]? {
        try terminal.withLocked { state in
            try encoder.encode(press, terminal: try #require(state.raw, "the terminal is closed"))
        }
    }

    /// The press went out, so its release must too, even though the program turned reporting
    /// off in between. It goes out as SGR, as the press did, although the terminal is back on
    /// the default format by then.
    @Test func releaseOfAReportedPressGoesOutAfterTrackingTurnsOff() throws {
        let terminal = try GhosttyTerminal(cols: 10, rows: 10, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        let encoder = try MouseEncoder(geometry: Self.geometry)
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")

        let press = try encode(MousePress(action: .press, button: .left, position: Self.point), with: encoder, on: terminal)
        #expect(press == Array("\u{1b}[<0;1;1M".utf8), "the press encoded as \(String(describing: press))")

        terminal.feed(text: "\u{1b}[?1000l\u{1b}[?1006l")
        let release = try encode(
            MousePress(action: .release, button: .left, position: Self.point), with: encoder, on: terminal)
        #expect(release == Array("\u{1b}[<0;1;1m".utf8), "the release encoded as \(String(describing: release))")
        #expect(encoder.pressEncodings.isEmpty, "the release left \(encoder.pressEncodings) recorded")
    }

    /// Only a reported press earns a release. With tracking off throughout there is nothing to close.
    @Test func releaseWithNoReportedPressStaysSilent() throws {
        let terminal = try GhosttyTerminal(cols: 10, rows: 10, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        let encoder = try MouseEncoder(geometry: Self.geometry)

        let press = try encode(MousePress(action: .press, button: .left, position: Self.point), with: encoder, on: terminal)
        let release = try encode(
            MousePress(action: .release, button: .left, position: Self.point), with: encoder, on: terminal)
        #expect(press == nil, "with tracking off the press encoded as \(String(describing: press))")
        #expect(release == nil, "with tracking off the release encoded as \(String(describing: release))")
    }

    /// A wheel click is a press with no release, so it must leave no button held or recorded.
    @Test func wheelLeavesNoButtonHeld() throws {
        let terminal = try GhosttyTerminal(cols: 10, rows: 10, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        let encoder = try MouseEncoder(geometry: Self.geometry)
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")

        let outcome = try terminal.withLocked { state in
            try encoder.wheel(rows: 2, at: Self.point, terminal: try #require(state.raw, "the terminal is closed"))
        }
        guard case .report(let bytes) = outcome, !bytes.isEmpty else {
            Issue.record("two rows of wheel under mode 1000 gave \(outcome), not a report")
            return
        }
        #expect(encoder.heldButtons.isEmpty, "the wheel left \(encoder.heldButtons) held")
        #expect(encoder.pressEncodings.isEmpty, "the wheel left \(encoder.pressEncodings) recorded")
    }
}
