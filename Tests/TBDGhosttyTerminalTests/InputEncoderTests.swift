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

    /// libghostty encodes under the mouse mode set last, and resetting any of them turns tracking
    /// off, whatever bits are still set. After `?1000h ?1003h ?1003l` the bits still say 1000 but
    /// clicks go unreported. The held button's release must still go out, and clicks must go out
    /// again once the program sets 1000 again, although that changes no bit.
    @Test func trackingFollowsTheModeSetLastNotTheModeBits() throws {
        let terminal = try GhosttyTerminal(cols: 10, rows: 10, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        let encoder = try MouseEncoder(geometry: Self.geometry)
        let down = MousePress(action: .press, button: .left, position: Self.point)
        let up = MousePress(action: .release, button: .left, position: Self.point)
        terminal.feed(text: "\u{1b}[?1006h\u{1b}[?1000h\u{1b}[?1003h")

        let press = try encode(down, with: encoder, on: terminal)
        #expect(press == Array("\u{1b}[<0;1;1M".utf8), "the press encoded as \(String(describing: press))")
        terminal.feed(text: "\u{1b}[?1003l")
        let release = try encode(up, with: encoder, on: terminal)
        #expect(release == Array("\u{1b}[<0;1;1m".utf8), "the held button's release encoded as \(String(describing: release))")

        // Tracking is off in libghostty now, though the 1000 bit is still set.
        let unreportedPress = try encode(down, with: encoder, on: terminal)
        let unreportedRelease = try encode(up, with: encoder, on: terminal)
        #expect(unreportedPress == nil, "with tracking off a press encoded as \(String(describing: unreportedPress))")
        #expect(unreportedRelease == nil, "with tracking off a release encoded as \(String(describing: unreportedRelease))")

        terminal.feed(text: "\u{1b}[?1000h")
        let click = try encode(down, with: encoder, on: terminal)
        #expect(click == Array("\u{1b}[<0;1;1M".utf8), "after 1000 was set again a press encoded as \(String(describing: click))")
    }

    /// Of two report formats the one set last wins, not the widest: after `?1006h ?1015h` reports
    /// are urxvt. A press's release keeps its format once reporting is off, so it is urxvt too.
    @Test func formatFollowsTheModeSetLast() throws {
        let terminal = try GhosttyTerminal(cols: 10, rows: 10, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        let encoder = try MouseEncoder(geometry: Self.geometry)
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?1015h")

        let press = try encode(MousePress(action: .press, button: .left, position: Self.point), with: encoder, on: terminal)
        #expect(press == Array("\u{1b}[32;1;1M".utf8), "the press encoded as \(String(describing: press))")
        terminal.feed(text: "\u{1b}[?1000l")
        let release = try encode(
            MousePress(action: .release, button: .left, position: Self.point), with: encoder, on: terminal)
        #expect(release == Array("\u{1b}[35;1;1M".utf8), "the release encoded as \(String(describing: release))")
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

    /// Under any-event tracking a move is reported once per cell, not once per pixel: the encoder
    /// drops a motion report that repeats the last one, and forgets it when the modes change.
    /// Driven through the terminal's own input seam, so the encoder is the one bound to the
    /// terminal, which hears about every write.
    @Test func motionIsReportedOncePerCellUnderAnyEventTracking() throws {
        let terminal = try GhosttyTerminal(cols: 10, rows: 10, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        terminal.setMousePixelGeometry(Self.geometry)
        terminal.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")
        let firstCell = Array("\u{1b}[<35;1;1M".utf8)
        let secondCell = Array("\u{1b}[<35;2;1M".utf8)

        // Twenty moves inside cell 1;1, x from 0.5 to 9.05 px, then one into cell 2;1.
        let inside = (0..<20).compactMap { step in
            terminal.encodeMouse(Self.motion(toX: 0.5 + Double(step) * 0.45))
        }
        #expect(inside == [firstCell], "twenty moves inside one cell gave \(inside.count) reports: \(inside)")
        let crossing = terminal.encodeMouse(Self.motion(toX: 15))
        #expect(crossing == secondCell, "the move into the next cell gave \(String(describing: crossing))")
        let again = terminal.encodeMouse(Self.motion(toX: 16))
        #expect(again == nil, "a second move inside cell 2;1 gave \(String(describing: again))")

        // Off and on again, in two writes with no event between. The encoder starts afresh, so the
        // same move that was just dropped as a repeat is reported.
        terminal.feed(text: "\u{1b}[?1003l")
        terminal.feed(text: "\u{1b}[?1003h")
        let afterToggle = terminal.encodeMouse(Self.motion(toX: 16))
        #expect(afterToggle == secondCell,
                "after tracking went off and on, the move gave \(String(describing: afterToggle)): the encoder was not reset")
    }

    /// A button-less move to `x` on the first row.
    private static func motion(toX x: Double) -> MousePress {
        MousePress(action: .motion, button: nil, position: SurfacePoint(x: x, y: 5))
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
