import AppKit
import Foundation
import GhosttyVt
import Metal
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

// This file imports `GhosttyVt` for the Kitty storage limit and build info, and the C terminal type
// is also named `GhosttyTerminal`, so the Swift class is spelled with its module name throughout.

/// What a view sent. Main-actor isolated, so a `@MainActor` callback can append to it without
/// capturing a mutable local.
@MainActor
private final class WheelSent {
    var sent: [[UInt8]] = []
}

private func makeTerminal(
    cols: Int = 80, rows: Int = 24, callbacks: GhosttyTerminalCallbacks = GhosttyTerminalCallbacks()
) throws -> TBDGhosttyTerminal.GhosttyTerminal {
    try TBDGhosttyTerminal.GhosttyTerminal(cols: cols, rows: rows, scrollbackLines: 100, callbacks: callbacks)
}

/// Ten-pixel cells, so the point (5, 5) is cell 1;1.
private let wheelGeometry = TerminalPixelGeometry(screenWidth: 800, screenHeight: 240, cellWidth: 10, cellHeight: 10)
private let wheelPoint = SurfacePoint(x: 5, y: 5)

/// `count` copies of `key`, back to back.
private func repeated(_ key: String, _ count: Int) -> [UInt8] {
    Array(String(repeating: key, count: count).utf8)
}

private let cursorDown = Array("\u{1b}[B".utf8)
private let cursorUp = Array("\u{1b}[A".utf8)

private func describe(_ outcome: WheelOutcome) -> String {
    switch outcome {
    case .none: "nothing"
    case .report(let press, let count): "\(count) of the report \(String(decoding: press, as: UTF8.self).debugDescription)"
    case .cursorKeys(let key, let count): "\(count) of the key \(String(decoding: key, as: UTF8.self).debugDescription)"
    case .scrolledViewport(let rows): "a viewport scroll of \(rows) rows"
    }
}

private func scrollMetrics(of terminal: TBDGhosttyTerminal.GhosttyTerminal) throws -> TerminalScrollMetrics {
    try terminal.withLocked { state in
        TerminalScrollMetrics.read(try #require(state.raw, "the terminal is closed"))
    }
}

/// The Kitty image storage limit of the active screen, or nil when the library was built without
/// Kitty graphics.
private func kittyStorageLimit(of terminal: TBDGhosttyTerminal.GhosttyTerminal) throws -> UInt64? {
    try terminal.withLocked { state -> UInt64? in
        let raw = try #require(state.raw, "the terminal is closed")
        var limit: UInt64 = .max
        let result = ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT, &limit)
        if result == GHOSTTY_UNSUPPORTED { return nil }
        try #require(result == GHOSTTY_SUCCESS, "reading the Kitty storage limit returned \(result.rawValue)")
        return limit
    }
}

/// True when this build of libghostty has Kitty graphics at all.
private func libraryHasKittyGraphics() -> Bool {
    var enabled = false
    guard ghostty_build_info(GHOSTTY_BUILD_INFO_KITTY_GRAPHICS, &enabled) == GHOSTTY_SUCCESS else { return false }
    return enabled
}

/// A Kitty graphics query that a terminal with the protocol answers `OK`: one 1×1 RGB pixel, sent
/// directly, for image 31.
private let kittyQuery = "\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\"
/// The plan's shorter query, with no image size. A terminal with the protocol answers it with an
/// error rather than `OK`; one without it answers nothing.
private let shortKittyQuery = "\u{1b}_Gi=1,a=q;AAAA\u{1b}\\"

/// A wheel outcome other than the one a test expected, recorded as an error so its description
/// reaches the CI summary.
private struct UnexpectedWheelOutcome: Error, CustomStringConvertible {
    let description: String
}

private func repliesText(_ recorder: CallbackRecorder) -> String {
    recorder.writes.map { String(decoding: $0, as: UTF8.self) }.joined()
}

@Suite(.fastPassBounded)
@MainActor
struct WheelPowerlineKittyTests {
    // MARK: - Wheel

    /// On the alternate screen, with alternate scroll on and no mouse reporting, each wheel row is
    /// an arrow key: the application form under DECCKM, nothing once the program turns alternate
    /// scroll off, and mouse reports once it turns reporting on.
    @Test func wheelSendsArrowsOnAlternateScreenWithAlternateScroll() throws {
        let terminal = try makeTerminal()
        defer { terminal.close() }
        terminal.setMousePixelGeometry(wheelGeometry)
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[?1007h")

        let down = terminal.mouseWheel(rows: 3, at: wheelPoint, mods: [])
        #expect(down == .cursorKeys(key: cursorDown, count: 3), "three rows down gave \(describe(down))")
        let up = terminal.mouseWheel(rows: -2, at: wheelPoint, mods: [])
        #expect(up == .cursorKeys(key: cursorUp, count: 2), "two rows up gave \(describe(up))")

        terminal.feed(text: "\u{1b}[?1h")
        let application = terminal.mouseWheel(rows: 1, at: wheelPoint, mods: [])
        #expect(application == .cursorKeys(key: Array("\u{1b}OB".utf8), count: 1),
                "under DECCKM a row down gave \(describe(application))")

        terminal.feed(text: "\u{1b}[?1007l")
        let off = terminal.mouseWheel(rows: 3, at: wheelPoint, mods: [])
        #expect(off == .none, "with alternate scroll off the wheel gave \(describe(off))")

        terminal.feed(text: "\u{1b}[?1007h\u{1b}[?1000h\u{1b}[?1006h")
        let tracked = terminal.mouseWheel(rows: 1, at: wheelPoint, mods: [])
        guard case .report(let press, 1) = tracked, press.starts(with: Array("\u{1b}[<65;".utf8)) else {
            Issue.record(UnexpectedWheelOutcome(
                description: "with mouse reporting on the wheel gave \(describe(tracked)), not a button-5 report"))
            return
        }
    }

    /// A new terminal has alternate scroll on, as Ghostty and SwiftTerm do, so `less` scrolls by wheel
    /// without asking. Through the view, a classic wheel's notch is one arrow key whatever its
    /// delta, which carries the wheel's acceleration rather than a row count.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aWheelNotchIsOneArrowKeyWhateverItsDelta() throws {
        let (terminal, view, recorder) = try makeView()
        terminal.feed(text: "\u{1b}[?1049h")
        #expect(terminal.withLocked { $0.mode(1007) }, "a new terminal starts with alternate scroll off")

        let down = Self.wheel(view, deltaY: -3, precise: false, phase: .unphased, at: 1)
        #expect(recorder.sent == [cursorDown], "a wheel-down notch of 3 lines sent \(recorder.sent), from \(describe(down))")
        recorder.sent = []
        let up = Self.wheel(view, deltaY: 12, precise: false, phase: .unphased, at: 2)
        #expect(recorder.sent == [cursorUp], "a wheel-up notch of 12 lines sent \(recorder.sent), from \(describe(up))")
    }

    /// Under DECCKM the arrow key a notch types through the view is the application form, as the
    /// real key is: a notch up on the alternate screen, with nothing reported, sends `ESC O A`.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aNotchUnderDECCKMTypesTheApplicationArrow() throws {
        let (terminal, view, recorder) = try makeView()
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[?1h")
        let reporting = terminal.isMouseReporting
        try #require(!reporting, "a new terminal reports the mouse, so this proves nothing")

        let up = Self.wheel(view, deltaY: 3, precise: false, phase: .unphased, at: 1)
        #expect(recorder.sent == [Array("\u{1b}OA".utf8)],
                "a wheel-up notch under DECCKM sent \(recorder.sent), from \(describe(up))")
    }

    /// A trackpad moves by fractions of a line. They add up to whole lines within a gesture, and
    /// the fraction one gesture leaves is dropped when the next begins, so a short flick sends
    /// nothing and lends nothing to the next gesture.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func trackpadFractionsBuildUpIntoWholeLines() throws {
        let (terminal, view, recorder) = try makeView()
        terminal.feed(text: "\u{1b}[?1049h")
        // Points down, as `scrollingDeltaY` reports a scroll toward the end.
        let fraction = -0.3 * Double(view.cellSize.height)

        Self.wheel(view, deltaY: fraction, phase: .gestureBegan, at: 1)
        #expect(recorder.sent.isEmpty, "a 0.3-line flick sent \(recorder.sent)")

        // Had the flick's fraction been kept, the third of these would make a whole line.
        Self.wheel(view, deltaY: fraction, phase: .gestureBegan, at: 2)
        Self.wheel(view, deltaY: fraction, phase: .gestureChanged, at: 2.01)
        Self.wheel(view, deltaY: fraction, phase: .gestureChanged, at: 2.02)
        #expect(recorder.sent.isEmpty, "0.9 of a line sent \(recorder.sent)")
        Self.wheel(view, deltaY: fraction, phase: .gestureChanged, at: 2.03)
        #expect(recorder.sent == [cursorDown], "1.2 lines sent \(recorder.sent)")
    }

    /// Reversing direction drops the fraction banked the other way rather than netting against it.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aReversalDiscardsTheRemainder() throws {
        let (terminal, view, recorder) = try makeView()
        terminal.feed(text: "\u{1b}[?1049h")
        let line = Double(view.cellSize.height)

        // 0.7 of a line down, then 1.1 up in two steps. Netted against the 0.7, the 1.1 would
        // leave 0.4 up and send nothing; with the 0.7 dropped, it is a whole line up.
        Self.wheel(view, deltaY: -0.7 * line, phase: .gestureBegan, at: 1)
        Self.wheel(view, deltaY: 0.5 * line, phase: .gestureChanged, at: 1.01)
        #expect(recorder.sent.isEmpty, "0.7 of a line down and 0.5 up sent \(recorder.sent)")
        let up = Self.wheel(view, deltaY: 0.6 * line, phase: .gestureChanged, at: 1.02)
        #expect(recorder.sent == [cursorUp], "after the reversal, 1.1 lines up sent \(recorder.sent), from \(describe(up))")
    }

    /// On the primary screen the wheel moves the viewport as far as SwiftTerm's `scrollWheel` (at
    /// the pinned fedbcac) moves its scrollback, so shell scrollback is as fast in either engine.
    /// The expected lines are SwiftTerm's formula worked by hand, not this view's arithmetic.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func theViewportScrollsAtSwiftTermsWheelSpeed() throws {
        let (terminal, view, recorder) = try makeView()
        terminal.feed(text: (0..<60).map { "line \($0)\r\n" }.joined())
        let line = Double(view.cellSize.height)
        // SwiftTerm, positive = up: a notch scrolls `Int(scrollingDeltaY.rounded())` lines, or one
        // line its way when that rounds to 0, and empties the bank. Precise points add to the bank,
        // and `Int(bank / cellHeight)` lines are taken from it; a reversal nets against it.
        let steps: [(deltaY: Double, precise: Bool, phase: WheelPhase, swiftTermLines: Int)] = [
            (1, false, .unphased, 1),
            (0.3, false, .unphased, 1),
            (2.5, false, .unphased, 3),
            (7, false, .unphased, 7),
            (-4.4, false, .unphased, -4),
            (2.5 * line, true, .gestureBegan, 2),       // bank 0.5 of a cell
            (0.75 * line, true, .gestureChanged, 1),    // bank 0.25
            (-1.1 * line, true, .gestureChanged, 0),    // bank -0.85: netted, not dropped
            (-0.25 * line, true, .gestureChanged, -1),  // bank -0.1
        ]
        for (index, step) in steps.enumerated() {
            let before = try scrollMetrics(of: terminal).offset
            let outcome = Self.wheel(view, deltaY: step.deltaY, precise: step.precise, phase: step.phase, at: Double(index))
            let moved = try scrollMetrics(of: terminal).offset - before
            #expect(moved == -step.swiftTermLines,
                    "deltaY \(step.deltaY) moved the viewport \(moved) rows, SwiftTerm \(-step.swiftTermLines): \(describe(outcome))")
        }
        #expect(recorder.sent.isEmpty, "scrolling the primary screen sent \(recorder.sent)")
    }

    /// A program that turns reporting on in the middle of a trackpad gesture gets reports for the
    /// motion after the flip alone: the viewport moves no further, and the fraction the viewport
    /// banked before the flip is not reported.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func turningReportingOnMidGestureReportsNoStaleRemainder() throws {
        let (terminal, view, recorder) = try makeView()
        terminal.feed(text: (0..<60).map { "line \($0)\r\n" }.joined())
        let line = Double(view.cellSize.height)

        // 1.7 lines up with reporting off: the viewport moves one row and banks 0.7.
        let start = try scrollMetrics(of: terminal).offset
        Self.wheel(view, deltaY: 1.7 * line, phase: .gestureBegan, at: 1)
        let beforeFlip = try scrollMetrics(of: terminal).offset
        try #require(beforeFlip == start - 1, "1.7 lines up moved the viewport from row \(start) to \(beforeFlip)")

        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let reporting = terminal.isMouseReporting
        try #require(reporting, "?1000h did not turn mouse reporting on")
        let afterFlip = try scrollMetrics(of: terminal).offset

        // Half a line more. With the 0.7 kept, it would make a whole row, and a report.
        let half = Self.wheel(view, deltaY: 0.5 * line, phase: .gestureChanged, at: 1.01)
        #expect(recorder.sent.isEmpty, "half a line after the flip sent \(recorder.sent), from \(describe(half))")

        // 0.6 more makes 1.1 lines since the flip: one report, button 4.
        let whole = Self.wheel(view, deltaY: 0.6 * line, phase: .gestureChanged, at: 1.02)
        let sent = Array(recorder.sent.joined())
        let reports = sent.filter { $0 == 0x1B }.count
        let isWheelUp = sent.starts(with: Array("\u{1b}[<64;".utf8))
        #expect(reports == 1 && isWheelUp,
                "1.1 lines up after the flip sent \(String(decoding: sent, as: UTF8.self).debugDescription), from \(describe(whole))")
        let end = try scrollMetrics(of: terminal).offset
        #expect(end == afterFlip, "after the flip the wheel moved the viewport from row \(afterFlip) to \(end)")
    }

    /// After `?1000h ?1003h ?1003l` the 1000 bit is still set, but libghostty reports nothing, so
    /// the wheel scrolls the viewport, and at the viewport's speed: a notch of 3 lines moves it 3
    /// rows, not the one row a notch is when it goes to the program.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aNotchAfterTrackingWasResetScrollsTheViewportAtItsSpeed() throws {
        let (terminal, view, recorder) = try makeView()
        terminal.feed(text: (0..<60).map { "line \($0)\r\n" }.joined()
            + "\u{1b}[?1006h\u{1b}[?1000h\u{1b}[?1003h\u{1b}[?1003l")
        let bitStillSet = terminal.withLocked { $0.isMouseTrackingEnabled }
        try #require(bitStillSet, "the 1000 bit is not set, so this proves nothing")
        let reporting = terminal.isMouseReporting
        try #require(!reporting, "libghostty still reports the mouse, so this proves nothing")

        let before = try scrollMetrics(of: terminal).offset
        let outcome = Self.wheel(view, deltaY: 3, precise: false, phase: .unphased, at: 1)
        let moved = try scrollMetrics(of: terminal).offset - before
        #expect(moved == -3, "a wheel-up notch of 3 lines moved the viewport \(moved) rows: \(describe(outcome))")
        #expect(recorder.sent.isEmpty, "the notch sent \(recorder.sent)")
    }

    /// A flick's momentum tail, 60 events of two lines each within 100 ms, types no more arrow keys
    /// than the bound lets through: the burst at once, then 100 a second, so at most 16 of the 120.
    /// The keys over the bound are dropped, not queued: an event after the tail sends only its own.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aMomentumTailIsBoundedByTheBurst() throws {
        let (terminal, view, recorder) = try makeView()
        terminal.feed(text: "\u{1b}[?1049h")
        let line = Double(view.cellSize.height)
        let events = 60
        let span: TimeInterval = 0.1

        for index in 0..<events {
            Self.wheel(view, deltaY: -2 * line, phase: .momentum, at: 10 + span * Double(index) / Double(events))
        }
        let sent = Array(recorder.sent.joined())
        let typed = sent.count / cursorDown.count
        let bound = WheelInputBound.burst + Int(span * WheelInputBound.sustainedPerSecond)
        #expect(sent == repeated("\u{1b}[B", typed), "the momentum tail sent \(String(decoding: sent, as: UTF8.self).debugDescription)")
        #expect(typed >= WheelInputBound.burst && typed <= bound,
                "120 lines of momentum in 100 ms typed \(typed) arrow keys, not from \(WheelInputBound.burst) to \(bound)")

        recorder.sent = []
        // A line and a half, so the one whole line does not hang on rounding.
        Self.wheel(view, deltaY: -1.5 * line, phase: .gestureBegan, at: 11)
        #expect(recorder.sent == [cursorDown], "a line and a half a second after the tail sent \(recorder.sent)")
    }

    /// Wheel reports under mouse tracking have the same bound as the arrow keys, the app's wheel
    /// monitor's: the burst at once, then 100 a second, the rest dropped. Time is the events' own
    /// timestamps, as in the app's monitor, so the test sets it; each is a binary fraction, so the
    /// refills are exact.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func wheelReportsAreBoundedLikeTheArrowKeys() throws {
        let (terminal, view, recorder) = try makeView()
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let reporting = terminal.isMouseReporting
        try #require(reporting, "?1000h did not turn mouse reporting on")
        let line = Double(view.cellSize.height)
        /// The reports sent since the last call: each starts with the one ESC it holds.
        func reportsSent() -> Int {
            defer { recorder.sent = [] }
            return recorder.sent.joined().filter { $0 == 0x1B }.count
        }

        // Ten notches at once: one report each, until the burst is spent.
        for _ in 0..<10 { Self.wheel(view, deltaY: -1, precise: false, phase: .unphased, at: 8) }
        let burst = reportsSent()
        #expect(burst == WheelInputBound.burst, "ten notches at once sent \(burst) reports")

        // A thirty-second of a second later the bucket holds 3.125 reports, so three go out.
        for _ in 0..<10 { Self.wheel(view, deltaY: -1, precise: false, phase: .unphased, at: 8.03125) }
        let refilled = reportsSent()
        #expect(refilled == 3, "ten notches 1/32 s after the burst sent \(refilled) reports, not 3")

        // After a second the bucket is full again, and holds no more than the burst: one event
        // worth twenty rows sends six.
        let outcome = Self.wheel(view, deltaY: -20 * line, phase: .momentum, at: 9.03125)
        let afterPause = reportsSent()
        #expect(afterPause == WheelInputBound.burst,
                "twenty rows a second after the refill sent \(afterPause) reports: \(describe(outcome))")
        guard case .report(let press, WheelInputBound.burst) = outcome,
              press.starts(with: Array("\u{1b}[<65;".utf8)) else {
            Issue.record(UnexpectedWheelOutcome(
                description: "twenty rows of momentum gave \(describe(outcome)), not \(WheelInputBound.burst) button-5 reports"))
            return
        }
    }

    /// On the primary screen the wheel moves the viewport through scrollback and sends the program
    /// nothing, alternate scroll or not.
    @Test func wheelScrollsViewportOnPrimaryScreen() throws {
        let recorder = CallbackRecorder()
        let terminal = try makeTerminal(callbacks: recorder.callbacks)
        defer { terminal.close() }
        terminal.setMousePixelGeometry(wheelGeometry)
        terminal.feed(text: (0..<60).map { "line \($0)\r\n" }.joined() + "\u{1b}[?1007h")
        let bottom = try scrollMetrics(of: terminal)
        try #require(bottom.scrollableRows >= 3, "60 lines left only \(bottom.scrollableRows) rows of scrollback")

        let up = terminal.mouseWheel(rows: -3, at: wheelPoint, mods: [])
        #expect(up == .scrolledViewport(rows: -3), "three rows up gave \(describe(up))")
        let scrolled = try scrollMetrics(of: terminal)
        #expect(scrolled.offset == bottom.offset - 3, "the viewport went from row \(bottom.offset) to \(scrolled.offset)")

        let down = terminal.mouseWheel(rows: 3, at: wheelPoint, mods: [])
        #expect(down == .scrolledViewport(rows: 3), "three rows down gave \(describe(down))")
        #expect(try scrollMetrics(of: terminal).offset == bottom.offset, "the viewport did not come back to the bottom")
        #expect(recorder.writes.isEmpty, "scrolling the primary screen sent \(recorder.writes)")
    }

    // MARK: - Powerline

    /// The four separators are drawn as sprites that fill the cell: the solid arrows have a full
    /// edge on their base side and reach the other edge at mid-height, and the outlines are hollow.
    @Test func powerlineSpritesFillTheCell() throws {
        let fontSet = FontSet(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), scale: 2)
        let metrics = CellMetrics(fontSet: fontSet)
        let sprites = BoxSprites(metrics: metrics, padding: 1)
        let width = metrics.width
        let height = metrics.height
        for value: UInt32 in 0xE0B0...0xE0B3 {
            #expect(BoxSprites.covers(try #require(Unicode.Scalar(value))), "U+\(String(value, radix: 16)) is not a sprite")
        }
        #expect(!BoxSprites.covers("\u{E0B4}"), "U+E0B4, which nothing draws, was taken as a sprite")

        let right = try #require(sprites.rasterize("\u{E0B0}"))
        let rightOutline = try #require(sprites.rasterize("\u{E0B1}"))
        let left = try #require(sprites.rasterize("\u{E0B2}"))
        let leftOutline = try #require(sprites.rasterize("\u{E0B3}"))
        for glyph in [right, rightOutline, left, leftOutline] {
            #expect(glyph.width == width + 2 && glyph.height == height + 2, "a sprite is \(glyph.width)×\(glyph.height)")
        }

        /// The coverage of cell pixel (x, y), y from the top. The bitmap's first row is its top.
        func alpha(_ glyph: RasterizedGlyph, _ x: Int, _ y: Int) -> UInt8 {
            glyph.pixels[(y + 1) * glyph.bytesPerRow + (x + 1) * glyph.bytesPerPixel]
        }
        func solidRows(_ glyph: RasterizedGlyph, column: Int) -> Int {
            (0..<height).filter { alpha(glyph, column, $0) > 128 }.count
        }
        func ink(_ glyph: RasterizedGlyph) -> Int { glyph.pixels.reduce(0) { $0 + Int($1) } }

        #expect(solidRows(right, column: 0) >= height - 4, "U+E0B0's base is solid in \(solidRows(right, column: 0)) of \(height) rows")
        #expect(alpha(right, width - 1, height / 2) > 64, "U+E0B0 does not reach the right edge")
        #expect(alpha(right, width - 1, 0) == 0 && alpha(right, width - 1, height - 1) == 0, "U+E0B0 fills its right corners")

        #expect(solidRows(left, column: width - 1) >= height - 4,
                "U+E0B2's base is solid in \(solidRows(left, column: width - 1)) of \(height) rows")
        #expect(alpha(left, 0, height / 2) > 64, "U+E0B2 does not reach the left edge")
        #expect(alpha(left, 0, 0) == 0 && alpha(left, 0, height - 1) == 0, "U+E0B2 fills its left corners")

        #expect(alpha(rightOutline, width - 1, height / 2) > 64, "U+E0B1 does not reach the right edge")
        #expect(alpha(rightOutline, 0, height / 2) == 0, "U+E0B1 is filled where it should be hollow")
        #expect(alpha(leftOutline, 0, height / 2) > 64, "U+E0B3 does not reach the left edge")
        #expect(alpha(leftOutline, width - 1, height / 2) == 0, "U+E0B3 is filled where it should be hollow")
        #expect(ink(rightOutline) < ink(right) / 2 && ink(leftOutline) < ink(left) / 2,
                "an outline carries as much ink as the solid arrow")
    }

    /// The separators reach the screen: each cell of a frame holding them has ink, and the solid
    /// arrows are heavy on their base side.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func powerlineGlyphsRender() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let glyphCache = GlyphCache(fontSet: FontSet(font: font, scale: 2), device: device)
        let renderer = try TerminalRenderer(device: device, glyphCache: glyphCache)

        // Six columns, so the cursor ends on column 5, past the blank reference cell at column 4,
        // and hidden as well: a block cursor on the reference cell lights all of it.
        let terminal = try makeTerminal(cols: 6, rows: 1)
        defer { terminal.close() }
        // White on black, with a blank control cell of the same black after the glyphs.
        terminal.feed(text: "\u{1b}[?25l\u{1b}[38;2;255;255;255;48;2;0;0;0m\u{E0B0}\u{E0B1}\u{E0B2}\u{E0B3} \u{1b}[0m")

        let surface = TerminalSurface()
        try surface.attach(terminal)
        let size = renderer.drawableSize(columns: 6, rows: 1)
        let texture = try #require(renderer.makeOffscreenTexture(width: size.width, height: size.height))
        let outcome = try renderer.render(surface: surface, to: texture)
        #expect(outcome.didEncode, "the first frame after attach was skipped")
        outcome.commandBuffer?.waitUntilCompleted()

        let pixels = TerminalRenderer.bgraBytes(of: texture)
        let metrics = glyphCache.metrics
        /// The pixel at (`x`, `y`) as red, green and blue. The texture is BGRA.
        func rgb(_ x: Int, _ y: Int) -> [Int] {
            let offset = (y * texture.width + x) * 4
            return [Int(pixels[offset + 2]), Int(pixels[offset + 1]), Int(pixels[offset])]
        }
        // The cells' background, as drawn: the middle of the blank cell.
        let background = rgb(4 * metrics.width + metrics.width / 2, metrics.height / 2)
        /// Pixels in `column`, between `from` and `to` thirds of its width, more than a quarter of
        /// the range away from the background in some channel.
        func inked(column: Int, thirds: Range<Int> = 0..<3) -> Int {
            let start = column * metrics.width + metrics.width * thirds.lowerBound / 3
            let end = column * metrics.width + metrics.width * thirds.upperBound / 3
            var count = 0
            for y in 0..<metrics.height {
                for x in start..<end where zip(rgb(x, y), background).contains(where: { abs($0 - $1) > 64 }) {
                    count += 1
                }
            }
            return count
        }

        // A twentieth of a cell. An outline, the thinnest of the four, inks about a fifth.
        let minimumInk = metrics.width * metrics.height / 20
        let blank = inked(column: 4)
        for column in 0..<4 {
            let ink = inked(column: column)
            #expect(ink > blank + minimumInk,
                    "cell \(column) has \(ink) pixels off the background \(background), the blank cell \(blank)")
        }
        let rightBase = inked(column: 0, thirds: 0..<1)
        let rightPoint = inked(column: 0, thirds: 2..<3)
        #expect(rightBase > rightPoint * 2, "U+E0B0 has \(rightBase) light pixels on its base side and \(rightPoint) at its point")
        let leftBase = inked(column: 2, thirds: 2..<3)
        let leftPoint = inked(column: 2, thirds: 0..<1)
        #expect(leftBase > leftPoint * 2, "U+E0B2 has \(leftBase) light pixels on its base side and \(leftPoint) at its point")
    }

    // MARK: - Kitty graphics

    /// Nothing draws Kitty images, so a program asking whether they are supported gets no answer,
    /// on either screen and after either kind of reset: the storage limit is zero.
    @Test func kittyGraphicsQueryGetsNoOK() throws {
        let recorder = CallbackRecorder()
        let terminal = try makeTerminal(callbacks: recorder.callbacks)
        defer { terminal.close() }

        try Self.expectNoKittyReply("on the primary screen", terminal: terminal, recorder: recorder)
        terminal.feed(text: "\u{1b}[?1049h")
        try Self.expectNoKittyReply("on the alternate screen", terminal: terminal, recorder: recorder)
        terminal.feed(text: "\u{1b}[?1049l")
        terminal.reset()
        try Self.expectNoKittyReply("after a reset", terminal: terminal, recorder: recorder)
        terminal.feed(text: "\u{1b}c")
        try Self.expectNoKittyReply("after a RIS", terminal: terminal, recorder: recorder)
        terminal.feed(text: "\u{1b}[?1049h")
        try Self.expectNoKittyReply("on the alternate screen after a RIS", terminal: terminal, recorder: recorder)
    }

    /// Feeds both Kitty queries and expects no reply to either, and a storage limit of zero.
    private static func expectNoKittyReply(
        _ situation: String, terminal: TBDGhosttyTerminal.GhosttyTerminal, recorder: CallbackRecorder
    ) throws {
        let before = recorder.writes.count
        terminal.feed(text: kittyQuery + shortKittyQuery)
        let replies = recorder.writes.dropFirst(before).map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!replies.contains("OK"), "\(situation), a Kitty query was answered OK: \(replies.debugDescription)")
        #expect(!replies.contains("\u{1b}_G"), "\(situation), a Kitty query was answered: \(replies.debugDescription)")
        if let limit = try kittyStorageLimit(of: terminal) {
            #expect(limit == TBDGhosttyTerminal.GhosttyTerminal.kittyImageStorageLimit,
                    "\(situation), the Kitty storage limit is \(limit) bytes")
        }
    }

    /// The control for the test above: with the library's own limit put back, the same query is
    /// answered OK, so the silence there comes from the limit and not from the query.
    @Test(.enabled(if: libraryHasKittyGraphics(), "this libghostty was built without Kitty graphics"))
    func kittyGraphicsQueryIsAnsweredWithTheLibraryDefault() throws {
        let recorder = CallbackRecorder()
        let terminal = try makeTerminal(callbacks: recorder.callbacks)
        defer { terminal.close() }

        let restored = terminal.withRaw { raw in
            ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, nil)
        }
        try #require(restored == GHOSTTY_SUCCESS, "putting the default Kitty limit back returned \(String(describing: restored))")
        terminal.feed(text: kittyQuery)
        let replies = repliesText(recorder)
        #expect(replies.contains("OK"), "with the library's limit the query was answered \(replies.debugDescription)")
    }

    // MARK: - Fixture

    /// One wheel event through the view's mouse controller, at event time `timestamp` seconds.
    /// `deltaY` is in points from a trackpad (`precise`), in lines from a classic wheel.
    @discardableResult
    private static func wheel(
        _ view: GhosttyTerminalView, deltaY: Double, precise: Bool = true, phase: WheelPhase, at timestamp: TimeInterval
    ) -> WheelOutcome {
        view.mouseController.handleWheel(
            deltaY: deltaY, hasPreciseDeltas: precise, phase: phase, timestamp: timestamp,
            at: wheelPoint, mods: [], in: view)
    }

    /// A terminal and a windowless view over it, 400×200 points, recording what it sends.
    private func makeView() throws -> (TBDGhosttyTerminal.GhosttyTerminal, GhosttyTerminalView, WheelSent) {
        let terminal = try makeTerminal()
        let appearance = GhosttyAppearance(
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            foreground: .init(r: 0xDD, g: 0xDD, b: 0xDD),
            background: .init(r: 0x10, g: 0x10, b: 0x10),
            cursor: .init(r: 0xFF, g: 0xFF, b: 0xFF))
        let view = try GhosttyTerminalView(terminal: terminal, appearance: appearance)
        view.setFrameSize(NSSize(width: 400, height: 200))
        // The mouse encoder has the geometry it would get on the view's first event, so a report
        // at `wheelPoint` lands inside the screen.
        view.mouseController.syncGeometry()
        let recorder = WheelSent()
        view.onSend = { recorder.sent.append($0) }
        return (terminal, view, recorder)
    }
}
