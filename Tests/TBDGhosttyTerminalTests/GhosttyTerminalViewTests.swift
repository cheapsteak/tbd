import AppKit
import Foundation
import Metal
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// What a view's callbacks were handed. Main-actor isolated, so the `@MainActor` callbacks can
/// write to it without capturing a mutable local.
@MainActor
private final class ViewRecorder {
    var sent: [[UInt8]] = []
    /// What `onSizeChanged` reported, as `[cols, rows]`.
    var sizes: [[Int]] = []
    /// The terminal's own grid, read from inside `onSizeChanged`, as `[cols, rows]`.
    var terminalSizesSeen: [[Int]] = []
}

/// An 80×24 terminal and a view over it in a 13 pt monospaced font.
@MainActor
private struct ViewFixture {
    let terminal: GhosttyTerminal
    let view: GhosttyTerminalView
    let appearance: GhosttyAppearance

    init(clock: any Clock<Duration> = ContinuousClock()) throws {
        terminal = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        appearance = GhosttyAppearance(
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            foreground: .init(r: 0xDD, g: 0xDD, b: 0xDD),
            background: .init(r: 0x10, g: 0x10, b: 0x10),
            cursor: .init(r: 0xFF, g: 0xFF, b: 0xFF))
        view = try GhosttyTerminalView(terminal: terminal, appearance: appearance, clock: clock)
    }
}

/// An offscreen window the view can sit in. Never ordered front, so it is never on screen; the
/// tests replace `windowVisibility` to separate "hidden" from "occluded".
@MainActor
private func makeOffscreenWindow() -> NSWindow {
    // Enough of an application for AppKit to have an app object; `NSWindow` reaches for one.
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 200),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    return window
}

/// Puts `view`, 400×200 points, into `parent`, which must already be in a window. The window is
/// never on screen, so the view counts it as visible; only hiding keeps its frames off.
@MainActor
private func place(_ view: GhosttyTerminalView, in parent: NSView) {
    view.windowVisibility = { _ in true }
    view.setFrameSize(NSSize(width: 400, height: 200))
    parent.addSubview(view)
}

/// What a view's frame counters were at one moment.
private struct FrameCounts: Equatable {
    var built: Int
    var committed: Int
}

@MainActor
private func frameCounts(of view: GhosttyTerminalView) -> FrameCounts {
    FrameCounts(built: view.framesBuilt, committed: view.framesCommitted)
}

/// A mouse event at `location`, in window coordinates, addressed to `window`.
@MainActor
private func mouseEvent(
    _ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

/// A mouse event of `type` for no window. Its `buttonNumber` is 0 whatever the type.
private func windowlessMouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

/// An "other" button event carrying `number` as its `buttonNumber`, built as a `CGEvent` because
/// `NSEvent.mouseEvent(with:…)` takes no button.
private func otherButtonEvent(_ type: CGEventType, number: Int64) throws -> NSEvent {
    let cgEvent = try #require(CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center))
    cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: number)
    let event = try #require(NSEvent(cgEvent: cgEvent))
    try #require(event.buttonNumber == Int(number), "the event carries button \(event.buttonNumber)")
    return event
}

/// True when `bytes` is one SGR mouse report for `button`: `ESC [ < button ; … final`.
private func isSGRReport(_ bytes: [UInt8], button: Int, final: Character) -> Bool {
    bytes.starts(with: Array("\u{1b}[<\(button);".utf8)) && bytes.last == final.asciiValue
}

@Suite(.fastPassBounded)
@MainActor
struct GhosttyTerminalViewTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func typedKeyReachesOnSend() throws {
        let fixture = try ViewFixture()
        let recorder = ViewRecorder()
        fixture.view.onSend = { recorder.sent.append($0) }

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
            keyCode: 0))
        fixture.view.keyDown(with: event)

        #expect(recorder.sent == [[0x61]], "an a key-down sent \(recorder.sent)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func resizeCallsTerminalBeforeOnSizeChanged() throws {
        let fixture = try ViewFixture()
        let recorder = ViewRecorder()
        let terminal = fixture.terminal
        fixture.view.onSizeChanged = { cols, rows in
            recorder.sizes.append([cols, rows])
            recorder.terminalSizesSeen.append(terminal.withLocked { [$0.cols, $0.rows] })
        }

        // Half a point over 40×10 cells, so rounding cannot land on 39 or 9.
        let cell = fixture.view.cellSize
        fixture.view.setFrameSize(NSSize(width: cell.width * 40 + 0.5, height: cell.height * 10 + 0.5))
        fixture.view.renderTick()

        #expect(recorder.sizes == [[40, 10]], "onSizeChanged reported \(recorder.sizes)")
        #expect(recorder.terminalSizesSeen == [[40, 10]],
                "inside onSizeChanged the terminal was \(recorder.terminalSizesSeen)")
        let grid = fixture.view.gridSize
        #expect(grid.cols == 40 && grid.rows == 10, "the view's grid is \(grid)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func hiddenViewBuildsNoFrames() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let content = try #require(window.contentView)

        // A test window is never on screen; count it as visible so only `isHidden` keeps frames off.
        view.windowVisibility = { _ in true }
        view.setFrameSize(NSSize(width: 400, height: 200))
        view.isHidden = true
        content.addSubview(view)

        for index in 0..<30 {
            fixture.terminal.feed(text: "line \(index)\r\n")
            view.renderTick()
        }
        #expect(frameCounts(of: view) == FrameCounts(built: 0, committed: 0),
                "a hidden view built or committed frames: \(frameCounts(of: view))")
        #expect(!view.surface.isAttached, "a hidden view kept its surface attached")

        // The same counters must move once the view is shown, or the zeros above prove nothing.
        view.isHidden = false
        view.renderTick()
        #expect(view.framesBuilt >= 1, "a view shown again built no frame")
        #expect(view.framesCommitted >= 1,
                "a view shown again committed no frame (nil drawables so far: \(view.renderContext.renderer.stats.nilDrawables))")
    }

    /// Hiding an ancestor detaches the view as hiding the view does. AppKit reports it through
    /// `viewDidHide`, not through the view's own `isHidden`.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func viewUnderAHiddenAncestorBuildsNoFrames() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let content = try #require(window.contentView)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        content.addSubview(container)
        place(view, in: container)

        view.renderTick()
        let shown = frameCounts(of: view)
        #expect(shown.committed >= 1,
                "the shown view committed no frame (nil drawables so far: \(view.renderContext.renderer.stats.nilDrawables))")

        container.isHidden = true
        #expect(!view.surface.isAttached, "hiding the view's container left its surface attached")
        for index in 0..<30 {
            fixture.terminal.feed(text: "line \(index)\r\n")
            view.renderTick()
        }
        #expect(frameCounts(of: view) == shown,
                "under a hidden container the view went from \(shown) to \(frameCounts(of: view))")

        container.isHidden = false
        view.renderTick()
        #expect(view.surface.isAttached, "showing the container again left the view detached")
        #expect(view.framesCommitted > shown.committed, "the view shown again committed no frame")
    }

    /// An occluded window keeps its views from building frames, and they build again once it is
    /// visible.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func viewInAnOccludedWindowBuildsNoFrames() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let content = try #require(window.contentView)
        place(view, in: content)
        view.windowVisibility = { _ in false }
        view.refreshOcclusion()

        for index in 0..<30 {
            fixture.terminal.feed(text: "line \(index)\r\n")
            view.renderTick()
        }
        #expect(frameCounts(of: view) == FrameCounts(built: 0, committed: 0),
                "a view in an occluded window built or committed frames: \(frameCounts(of: view))")

        view.windowVisibility = { _ in true }
        view.refreshOcclusion()
        view.renderTick()
        #expect(view.framesCommitted >= 1, "the view committed no frame once its window was visible")
    }

    /// A button's route is fixed when it goes down. A Shift-click that starts a selection in
    /// between must not stop the reported right button's release, and neither must the program
    /// turning reporting off before the button comes up.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func reportedPressIsReleasedWhateverHappensInBetween() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let content = try #require(window.contentView)
        view.windowVisibility = { _ in true }
        view.setFrameSize(NSSize(width: 400, height: 200))
        content.addSubview(view)
        view.onSend = { recorder.sent.append($0) }
        fixture.terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let point = NSPoint(x: 20, y: 100)

        view.rightMouseDown(with: try mouseEvent(.rightMouseDown, at: point, in: window))
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: window, flags: .shift))
        fixture.terminal.feed(text: "\u{1b}[?1000l")
        view.rightMouseUp(with: try mouseEvent(.rightMouseUp, at: point, in: window))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: point, in: window, flags: .shift))

        #expect(recorder.sent.count == 2, "sent \(recorder.sent.count) reports, not a press and its release")
        #expect(recorder.sent.first.map { isSGRReport($0, button: 2, final: "M") } == true,
                "the first report was \(String(describing: recorder.sent.first)), not a right press")
        #expect(recorder.sent.last.map { isSGRReport($0, button: 2, final: "m") } == true,
                "the last report was \(String(describing: recorder.sent.last)), not a right release")
        #expect(view.mouseController.pendingReportReleases.isEmpty,
                "\(view.mouseController.pendingReportReleases) still wait for a release")
    }

    /// Left and right come from the event's type, every phase of it. An event built with
    /// `NSEvent.mouseEvent(with:…)` has `buttonNumber` 0 whatever its type, so a mapping that read
    /// the number would call these right-button events left. Only an "other" event is read by its
    /// number, which a `CGEvent` sets.
    @Test func buttonComesFromTheEventTypeAndTheNumberOnlyForOtherButtons() throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .leftMouseDragged] {
            let button = terminalMouseButton(for: try windowlessMouseEvent(type))
            #expect(button == .left, "\(type) mapped to \(String(describing: button))")
        }
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp, .rightMouseDragged] {
            let button = terminalMouseButton(for: try windowlessMouseEvent(type))
            #expect(button == .right, "\(type) mapped to \(String(describing: button))")
        }
        let middle = terminalMouseButton(for: try otherButtonEvent(.otherMouseDown, number: 2))
        #expect(middle == .middle, "other button 2 mapped to \(String(describing: middle))")
        let back = terminalMouseButton(for: try otherButtonEvent(.otherMouseUp, number: 3))
        #expect(back == .eight, "other button 3 mapped to \(String(describing: back))")
        let numberless = terminalMouseButton(for: try windowlessMouseEvent(.otherMouseDragged))
        #expect(numberless == nil, "an other event numbered 0 mapped to \(String(describing: numberless))")
        let notAButton = terminalMouseButton(for: try windowlessMouseEvent(.mouseMoved))
        #expect(notAButton == nil, "a move mapped to \(String(describing: notAButton))")
    }

    /// The tracking area and the responder chain each deliver the same move. Under any-event
    /// tracking a move is a report, so a repeat would reach the program twice.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func moveDeliveredOnBothPathsIsReportedOnce() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let content = try #require(window.contentView)
        view.windowVisibility = { _ in true }
        view.setFrameSize(NSSize(width: 400, height: 200))
        content.addSubview(view)
        view.onSend = { recorder.sent.append($0) }
        fixture.terminal.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")

        let move = try mouseEvent(.mouseMoved, at: NSPoint(x: 20, y: 100), in: window)
        view.mouseMoved(with: move)
        view.mouseController.mouseMoved(with: move)

        #expect(recorder.sent.count == 1, "one move was reported \(recorder.sent.count) times")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func windowlessViewBuildsNoFrames() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        view.setFrameSize(NSSize(width: 400, height: 200))

        for index in 0..<30 {
            fixture.terminal.feed(text: "line \(index)\r\n")
            view.renderTick()
        }
        #expect(view.framesBuilt == 0, "a windowless view built \(view.framesBuilt) frames")
    }

    /// Two views over one terminal. Hiding the first must not take the second's render signal
    /// off: only the view that installed a signal may clear it.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func hidingOneViewKeepsTheOtherViewsRenderSignal() throws {
        let fixture = try ViewFixture()
        let second = try GhosttyTerminalView(terminal: fixture.terminal, appearance: fixture.appearance)
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let content = try #require(window.contentView)
        place(fixture.view, in: content)
        place(second, in: content)
        #expect(fixture.terminal.hasRenderSignal, "two attached views left the terminal with no render signal")

        fixture.view.isHidden = true
        #expect(second.surface.isAttached, "hiding the first view detached the second")
        #expect(fixture.terminal.hasRenderSignal, "hiding the first view took the second view's render signal off")

        second.isHidden = true
        #expect(!fixture.terminal.hasRenderSignal, "hiding both views left a render signal installed")
    }

    /// A view takes no frames while hidden, so the DEC 2026 watchdog must start afresh when it is
    /// shown. Otherwise the mode's first sighting before the hide counts against it, and the
    /// first frame after the show forces it off.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func syncOutputIsTimedAfreshWhenTheViewIsShownAgain() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let content = try #require(window.contentView)
        place(view, in: content)
        let terminal = fixture.terminal

        terminal.feed(text: "\u{1b}[?2026h")
        view.renderTick(now: .seconds(100))
        view.isHidden = true
        view.isHidden = false

        view.renderTick(now: .seconds(110))
        let heldAfterShow = terminal.withLocked { $0.mode(2026) }
        #expect(heldAfterShow, "the first frame after the view was shown forced synchronized output off")
        // The watchdog still works: held past its timeout from the new first sighting, the mode
        // is forced off.
        view.renderTick(now: .seconds(111.5))
        let heldPastTimeout = terminal.withLocked { $0.mode(2026) }
        #expect(!heldPastTimeout, "mode 2026 held 1.5 s past the show was not forced off")
    }

    /// A steady cursor set while the blink is in its off phase must show. DECSCUSR 1 is a
    /// blinking block and DECSCUSR 2 a steady one.
    @Test(.clockDriven, .enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func steadyCursorSetInTheBlinkOffPhaseIsShown() async throws {
        let clock = EventDrivenTestClock()
        let fixture = try ViewFixture(clock: clock)
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let content = try #require(window.contentView)
        place(view, in: content)

        fixture.terminal.feed(text: "\u{1b}[1 q")
        view.renderTick()
        try #require(view.surface.cursor.isBlinking, "DECSCUSR 1 did not make the cursor blink")
        view.setFocused(true)

        // One half-period turns the cursor off. The timer arming again is the tick having run.
        try await clock.requireAdvanceWhenArmed(by: GhosttyTerminalView.blinkInterval, timeout: TestDeadlines.saturatedPass)
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        try #require(!view.surface.cursorBlinkOn, "the first blink tick left the cursor on")
        #expect(!view.surface.isCursorDrawn, "a blinking cursor in its off phase was drawn")

        fixture.terminal.feed(text: "\u{1b}[2 q")
        view.renderTick()
        #expect(view.surface.isCursorDrawn, "a steady cursor set in the blink's off phase is hidden")

        // The next tick puts the phase itself back on.
        try await clock.requireAdvanceWhenArmed(by: GhosttyTerminalView.blinkInterval, timeout: TestDeadlines.saturatedPass)
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        #expect(view.surface.cursorBlinkOn, "the tick after the cursor went steady left the blink phase off")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func applyingAppearanceUpdatesPaletteAndCellSize() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let content = try #require(window.contentView)
        place(view, in: content)
        view.renderTick()

        let custom = GhosttyAppearance.RGB(r: 0x12, g: 0x34, b: 0x56)
        let background = GhosttyAppearance.RGB(r: 0x20, g: 0x21, b: 0x22)
        var next = fixture.appearance
        next.palette[1] = custom
        next.background = background
        view.apply(next)

        let palette = fixture.terminal.withLocked { $0.palette }
        let backgroundInForce = fixture.terminal.withLocked { $0.backgroundColor }
        let entry = palette.count > 1 ? palette[1] : nil
        #expect(palette.count == 256, "the terminal reports \(palette.count) palette entries")
        #expect(entry == custom, "palette[1] reads back as \(String(describing: entry))")
        #expect(backgroundInForce == background, "the background reads back as \(String(describing: backgroundInForce))")

        let cellBefore = view.cellSize
        let gridBefore = view.gridSize
        let atlasBefore = view.renderContext.renderer.glyphCache.grayscale
        var larger = next
        larger.font = NSFont.monospacedSystemFont(ofSize: 26, weight: .regular)
        view.apply(larger)
        view.renderTick()

        let cellAfter = view.cellSize
        #expect(cellAfter.width > cellBefore.width && cellAfter.height > cellBefore.height,
                "a 26 pt font gave cells of \(cellAfter), against \(cellBefore) at 13 pt")
        // The same 400×200 points hold fewer of the larger cells.
        let gridAfter = view.gridSize
        #expect(gridAfter.cols < gridBefore.cols && gridAfter.rows < gridBefore.rows,
                "the grid went from \(gridBefore) to \(gridAfter) with cells twice the size")
        let terminalGrid = fixture.terminal.withLocked { [$0.cols, $0.rows] }
        #expect(terminalGrid == [gridAfter.cols, gridAfter.rows],
                "the terminal is \(terminalGrid) but the view's grid is \(gridAfter)")
        // A new font means a new glyph atlas, and rows rebuilt against its metrics. A fresh atlas
        // numbers its generations from the start again, so identity is what tells them apart.
        let atlasAfter = view.renderContext.renderer.glyphCache.grayscale
        #expect(atlasAfter !== atlasBefore, "the 26 pt font still draws from the 13 pt glyph atlas")
        #expect(view.surface.metrics == view.renderContext.metrics,
                "the surface was built at \(String(describing: view.surface.metrics)), not at the new font's metrics")
    }
}
