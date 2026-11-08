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
    /// Every URI `onOpenLink` was handed.
    var openedLinks: [String] = []
    /// What `onMouseDownClaimFocus` answers.
    var claimsPress = true
}

/// An 80×24 terminal and a view over it in a monospaced font, 13 pt unless a test needs a render
/// context, and so a glyph atlas, that no other test's view shares.
@MainActor
private struct ViewFixture {
    let terminal: GhosttyTerminal
    let view: GhosttyTerminalView
    let appearance: GhosttyAppearance

    /// - Parameter thinStrokes: the appearance's stroke weight; `nil` keeps `GhosttyAppearance`'s
    ///   own default.
    init(clock: any Clock<Duration> = ContinuousClock(), fontSize: CGFloat = 13, thinStrokes: Bool? = nil) throws {
        terminal = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        var appearance = GhosttyAppearance(
            font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            foreground: .init(r: 0xDD, g: 0xDD, b: 0xDD),
            background: .init(r: 0x10, g: 0x10, b: 0x10),
            cursor: .init(r: 0xFF, g: 0xFF, b: 0xFF))
        if let thinStrokes { appearance.thinStrokes = thinStrokes }
        self.appearance = appearance
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

/// A superview that counts the drags and releases the view passes up the responder chain, which
/// is where a mouse event the view does not handle goes, and sends them no further.
private final class ResponderChainCounter: NSView {
    private(set) var draggedCount = 0
    private(set) var upCount = 0

    override func mouseDragged(with event: NSEvent) { draggedCount += 1 }
    override func mouseUp(with event: NSEvent) { upCount += 1 }
}

/// A `ResponderChainCounter` filling `window`'s content view, with `view` placed in it.
@MainActor
private func placeInCounter(_ view: GhosttyTerminalView, in window: NSWindow) throws -> ResponderChainCounter {
    let content = try #require(window.contentView)
    let counter = ResponderChainCounter(frame: content.bounds)
    content.addSubview(counter)
    place(view, in: counter)
    return counter
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

/// A mouse event at `location`, in window coordinates, addressed to `window`. `eventNumber` tells
/// one press from another: AppKit asks `acceptsFirstMouse` about the activating click's.
@MainActor
private func mouseEvent(
    _ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags = [],
    eventNumber: Int = 0
) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 1))
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

/// One letter as a glyph cache draws it, beside the same letter from an unthickened and a
/// thickened rasterizer on the cache's own font.
private struct StrokeSample {
    let drawn: RasterizedGlyph
    let thin: RasterizedGlyph
    let thick: RasterizedGlyph

    /// The glyph's total coverage: the sum of its alpha bytes.
    static func ink(_ glyph: RasterizedGlyph) -> Int { glyph.pixels.reduce(0) { $0 + Int($1) } }

    var description: String {
        "drawn \(drawn.width)×\(drawn.height) px, ink \(Self.ink(drawn)); "
            + "unthickened \(thin.width)×\(thin.height) px, ink \(Self.ink(thin)); "
            + "thickened \(thick.width)×\(thick.height) px, ink \(Self.ink(thick))"
    }
}

/// `letter` from `cache`, and from an unthickened and a thickened rasterizer on its font.
private func strokeSample(_ cache: GlyphCache, letter: Character = "m") throws -> StrokeSample {
    let thin = GlyphRasterizer(fontSet: cache.fontSet, metrics: cache.metrics, thicken: false)
    let thick = GlyphRasterizer(fontSet: cache.fontSet, metrics: cache.metrics, thicken: true)
    let shaped = cache.shaper.shape(letter)
    let drawn = try #require(cache.rasterizer.rasterize(shaped), "the glyph cache drew no \(letter)")
    try #require(!drawn.isColor, "the \(letter) was drawn as a colour glyph")
    return StrokeSample(
        drawn: drawn,
        thin: try #require(thin.rasterize(shaped), "the unthickened rasterizer drew no \(letter)"),
        thick: try #require(thick.rasterize(shaped), "the thickened rasterizer drew no \(letter)"))
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

    /// Focus can leave in the middle of a drag, and the button's own release may then never reach
    /// the view. The reported button is released as focus goes, so a program under button-event
    /// tracking does not go on treating it as held.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func focusLossReleasesAReportedButton() throws {
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
        fixture.terminal.feed(text: "\u{1b}[?1002h\u{1b}[?1006h")
        // First responder before the focus, as a focused view always is. Otherwise the press's
        // click-to-focus makes it first responder, which takes the focus from the window, and the
        // test window is never key: the view would lose focus before the press, and the
        // `setFocused(false)` below would change nothing.
        try #require(window.makeFirstResponder(view), "the window did not take the view as first responder")
        view.setFocused(true)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 100), in: window))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 80, y: 100), in: window))
        view.setFocused(false)

        let sent = recorder.sent
        let releases = sent.filter { isSGRReport($0, button: 0, final: "m") }
        #expect(sent.first.map { isSGRReport($0, button: 0, final: "M") } == true,
                "the first report was \(String(describing: sent.first)), not a left press")
        #expect(releases.count == 1, "focus loss sent \(releases.count) left releases; all reports: \(sent)")
        #expect(sent.last.map { isSGRReport($0, button: 0, final: "m") } == true,
                "the last report was \(String(describing: sent.last)), not the left release")
        #expect(view.mouseController.pendingReportReleases.isEmpty,
                "\(view.mouseController.pendingReportReleases) still wait for a release")

        // The button's own release can still arrive later. It was already sent, so nothing goes
        // out again.
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 80, y: 100), in: window))
        let afterMouseUp = recorder.sent.dropFirst(sent.count)
        #expect(afterMouseUp.isEmpty, "the mouseUp after the focus-loss release sent \(Array(afterMouseUp))")
    }

    /// After `?1000h ?1003h ?1003l` the 1000 bit is still set, but resetting any tracking mode turns
    /// tracking off, and libghostty reports nothing. A click must then select, as in xterm and
    /// Ghostty, not go to a report that is never sent.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aClickAfterTrackingWasResetSelectsAndSendsNothing() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let content = try #require(window.contentView)
        place(view, in: content)
        view.onSend = { recorder.sent.append($0) }
        fixture.terminal.feed(text: "\u{1b}[?1006h\u{1b}[?1000h\u{1b}[?1003h\u{1b}[?1003l")
        let bitStillSet = fixture.terminal.withLocked { $0.isMouseTrackingEnabled }
        try #require(bitStillSet, "the 1000 bit is not set, so this proves nothing")
        let point = NSPoint(x: 20, y: 100)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: window))
        #expect(view.mouseController.lastRoute == .select,
                "the click took the \(String(describing: view.mouseController.lastRoute)) route")
        #expect(view.mouseController.isSelecting, "the click started no selection")
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: point, in: window))
        #expect(recorder.sent.isEmpty, "the click sent \(recorder.sent)")
        #expect(view.mouseController.pendingReportReleases.isEmpty,
                "\(view.mouseController.pendingReportReleases) wait for a release")
    }

    /// A press made while nothing is reported goes to the selection. If the program sets 1000 again
    /// before the button comes up, the release must not go out on its own: the program never saw
    /// the press.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aPressWithTrackingResetSendsNoReleaseOnceTrackingIsBack() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let content = try #require(window.contentView)
        place(view, in: content)
        view.onSend = { recorder.sent.append($0) }
        fixture.terminal.feed(text: "\u{1b}[?1006h\u{1b}[?1000h\u{1b}[?1003h\u{1b}[?1003l")
        let point = NSPoint(x: 20, y: 100)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: window))
        fixture.terminal.feed(text: "\u{1b}[?1000h")
        try #require(fixture.terminal.isMouseReporting, "setting 1000 again did not turn reporting on")
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: point, in: window))

        #expect(recorder.sent.isEmpty, "the press and release sent \(recorder.sent)")
        #expect(view.mouseController.pendingReportReleases.isEmpty,
                "\(view.mouseController.pendingReportReleases) wait for a release")
    }

    /// The click that brings a background window forward only activates it, as the SwiftTerm
    /// panel's does: the view takes first responder, and the press, its drags and its release
    /// reach neither the program, as mouse reports, nor the selection, which would drop the
    /// selection the user came back to copy, nor the responder chain, as a drag and a release of
    /// a press nobody saw begin. The next click in the window is an ordinary one. The view starts
    /// without first responder, since taking it is part of what is tested.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func theActivatingClickFocusesTheViewAndGoesNoFurther() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let counter = try placeInCounter(view, in: window)
        view.onSend = { recorder.sent.append($0) }
        view.onMouseDownClaimFocus = { recorder.claimsPress }
        fixture.terminal.feed(text: "\u{1b}[?1002h\u{1b}[?1006h")
        let point = NSPoint(x: 20, y: 100)
        let dragPoint = NSPoint(x: 80, y: 100)

        // Reported: the activating press, its drag and its release send nothing.
        let down = try mouseEvent(.leftMouseDown, at: point, in: window, eventNumber: 42)
        let takesIt = view.acceptsFirstMouse(for: down)
        #expect(takesIt, "the view did not take the click that activates its window")
        view.mouseDown(with: down)
        let focused = window.firstResponder === view
        #expect(focused, "the click that activated the window did not focus the terminal under it")
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: dragPoint, in: window, eventNumber: 42))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: dragPoint, in: window, eventNumber: 42))
        let sentByActivation = recorder.sent
        #expect(sentByActivation.isEmpty, "the activating click reached the program: \(sentByActivation)")
        let pending = view.mouseController.pendingReportReleases
        #expect(pending.isEmpty, "\(pending) wait for a release")
        let passedOn = [counter.draggedCount, counter.upCount]
        #expect(passedOn == [0, 0],
                "the activating press's drags and releases went up the responder chain: \(passedOn)")

        // Control: an ordinary click, now the window is active, is reported.
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: window, eventNumber: 43))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: point, in: window, eventNumber: 43))
        let reports = recorder.sent
        let pressAndRelease = reports.count == 2
            && reports.first.map { isSGRReport($0, button: 0, final: "M") } == true
            && reports.last.map { isSGRReport($0, button: 0, final: "m") } == true
        #expect(pressAndRelease, "control: an ordinary click sent \(reports), not a left press and its release")

        // Selected: with reporting off, the activating click starts no selection.
        fixture.terminal.feed(text: "\u{1b}[?1002l")
        try #require(!fixture.terminal.isMouseReporting, "resetting 1002 left reporting on")
        recorder.sent.removeAll()
        window.makeFirstResponder(nil)
        let selectDown = try mouseEvent(.leftMouseDown, at: point, in: window, eventNumber: 44)
        let takesTheSecond = view.acceptsFirstMouse(for: selectDown)
        #expect(takesTheSecond)
        view.mouseDown(with: selectDown)
        let selecting = view.mouseController.isSelecting
        #expect(!selecting, "the click that activated the window started a selection")
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: dragPoint, in: window, eventNumber: 44))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: dragPoint, in: window, eventNumber: 44))
        let refocused = window.firstResponder === view
        #expect(refocused, "the second activating click did not focus the terminal")
        let sentBySecond = recorder.sent
        #expect(sentBySecond.isEmpty, "the activating click sent \(sentBySecond)")
        let passedOnBySecond = [counter.draggedCount, counter.upCount]
        #expect(passedOnBySecond == [0, 0],
                "the second activating press's drags and releases went up the responder chain: \(passedOnBySecond)")

        // Control: an ordinary press selects.
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: window, eventNumber: 45))
        let ordinarySelects = view.mouseController.isSelecting
        #expect(ordinarySelects, "control: an ordinary press started no selection")
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: point, in: window, eventNumber: 45))
    }

    /// A host that declines a press has something drawn over the view that owns its events, so a
    /// ⌘-click in that press opens no OSC 8 link; the same ⌘-click, claimed, does, which shows the
    /// point is on the link. The window's activating ⌘-click on a link opens it, as the SwiftTerm
    /// panel's does, unless the host declined that press too, and is consumed whole either way:
    /// the link is looked up once, at the press, and its release goes nowhere.
    ///
    /// That the lookup happens once is not shown here: a second lookup could only disagree with
    /// the first if the screen changed between the two, and nothing on the main thread runs
    /// between them for a test to change it from.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aCommandClickTheHostDeclinesOpensNoLink() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let counter = try placeInCounter(view, in: window)
        view.onOpenLink = { recorder.openedLinks.append($0) }
        view.onMouseDownClaimFocus = { recorder.claimsPress }
        try #require(window.makeFirstResponder(view), "the window did not take the view as first responder")
        let link = "https://example.com/acme"
        fixture.terminal.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}]8;;\(link)\u{1b}\\open me\u{1b}]8;;\u{1b}\\")
        // On the link's first cells in row 0, whatever the window's scale against the view's.
        let cell = view.cellSize
        let onLink = view.convert(NSPoint(x: cell.width, y: cell.height / 4), to: nil)

        recorder.claimsPress = false
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: onLink, in: window, flags: .command))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onLink, in: window, flags: .command))
        let openedWhenDeclined = recorder.openedLinks
        #expect(openedWhenDeclined.isEmpty, "a ⌘-click the host declined opened \(openedWhenDeclined)")

        let declinedActivating = try mouseEvent(
            .leftMouseDown, at: onLink, in: window, flags: .command, eventNumber: 7)
        let takesDeclined = view.acceptsFirstMouse(for: declinedActivating)
        #expect(takesDeclined)
        view.mouseDown(with: declinedActivating)
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onLink, in: window, flags: .command, eventNumber: 7))
        let openedWhenDeclinedActivating = recorder.openedLinks
        #expect(openedWhenDeclinedActivating.isEmpty,
                "an activating ⌘-click the host declined opened \(openedWhenDeclinedActivating)")

        // Control: the same ⌘-click, claimed, opens the link.
        recorder.claimsPress = true
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: onLink, in: window, flags: .command))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onLink, in: window, flags: .command))
        let openedWhenClaimed = recorder.openedLinks
        #expect(openedWhenClaimed == [link], "control: a claimed ⌘-click on the link opened \(openedWhenClaimed)")

        // The window's activating ⌘-click on the link, claimed, opens it, and its release goes
        // nowhere: not to the selection, not as a report, and not up the responder chain.
        let upsBeforeActivating = counter.upCount
        let activating = try mouseEvent(.leftMouseDown, at: onLink, in: window, flags: .command, eventNumber: 8)
        let takesActivating = view.acceptsFirstMouse(for: activating)
        #expect(takesActivating)
        view.mouseDown(with: activating)
        let selectingAfterActivating = view.mouseController.isSelecting
        #expect(!selectingAfterActivating, "the activating ⌘-click on a link started a selection")
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onLink, in: window, flags: .command, eventNumber: 8))
        let openedWhenActivating = recorder.openedLinks
        #expect(openedWhenActivating == [link, link],
                "the ⌘-click that activated the window landed on a link and opened \(openedWhenActivating)")
        let upsPassedOn = counter.upCount - upsBeforeActivating
        #expect(upsPassedOn == 0,
                "the activating ⌘-click's release went up the responder chain \(upsPassedOn) times")
    }

    /// The report route can still carry a press that encodes as nothing: X10 tracking (`?9h`)
    /// reports only left, middle and right presses, so a back-button press goes out as nothing.
    /// That button must not wait for a release, which the program would get on its own once it
    /// set 1000: it never saw the button go down.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func anUnreportedPressOnTheReportRouteWaitsForNoRelease() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let content = try #require(window.contentView)
        place(view, in: content)
        view.onSend = { recorder.sent.append($0) }
        fixture.terminal.feed(text: "\u{1b}[?9h")
        try #require(fixture.terminal.isMouseReporting, "X10 tracking did not turn reporting on")

        view.otherMouseDown(with: try otherButtonEvent(.otherMouseDown, number: 3))
        try #require(recorder.sent.isEmpty, "X10 tracking reported a back-button press: \(recorder.sent)")
        #expect(view.mouseController.pendingReportReleases.isEmpty,
                "\(view.mouseController.pendingReportReleases) wait for a release the program never saw pressed")

        fixture.terminal.feed(text: "\u{1b}[?1000h")
        view.otherMouseUp(with: try otherButtonEvent(.otherMouseUp, number: 3))
        #expect(recorder.sent.isEmpty, "the release of the unreported press sent \(recorder.sent)")
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
    ///
    /// The encoder also drops a report that repeats the last one, which would hide a missing
    /// check here. So the encoder is made to forget between the two deliveries: tracking goes off
    /// and on again, in two writes, which changes the mouse flags it probes after each. Only the
    /// controller's check that the second delivery is the same event then stops it.
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
        fixture.terminal.feed(text: "\u{1b}[?1003h\u{1b}[?1016h")

        let move = try mouseEvent(.mouseMoved, at: NSPoint(x: 20, y: 100), in: window)
        view.mouseMoved(with: move)
        fixture.terminal.feed(text: "\u{1b}[?1003l")
        fixture.terminal.feed(text: "\u{1b}[?1003h")
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

    /// A skipped DEC 2026 frame keeps the link running so the watchdog is checked each tick. A
    /// terminal that closes while the mode is held, common when a session ends mid-frame, has no
    /// deadline left to wait out: the next tick must park the link, not leave it at 120 Hz.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aTerminalClosedDuringSyncOutputParksTheDisplayLink() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let content = try #require(window.contentView)
        place(view, in: content)

        fixture.terminal.feed(text: "\u{1b}[?2026h")
        view.renderTick(now: .seconds(100))
        try #require(view.frameDriver.demand.hasSyncDeadline, "a frame under mode 2026 was not skipped")
        try #require(!view.frameDriver.isPaused, "the link paused on a skipped frame")

        fixture.terminal.close()
        view.renderTick(now: .seconds(100.01))
        #expect(!view.frameDriver.demand.hasSyncDeadline, "the closed terminal kept a sync deadline")
        #expect(view.frameDriver.isPaused, "the link kept running after the terminal closed")
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

    /// A closed terminal never draws again. Its rows still hold positions in the glyph atlas,
    /// which every view in the same font shares and another view can clear. So the close stops
    /// the blink timer, and no frame asked for afterwards is drawn: the layer keeps the last one.
    @Test(.clockDriven, .enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aClosedTerminalDrawsNoNewFrames() async throws {
        let clock = EventDrivenTestClock()
        // A size no other test uses, so the atlas this test clears is this view's alone.
        let fixture = try ViewFixture(clock: clock, fontSize: 11.5)
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let content = try #require(window.contentView)
        place(view, in: content)

        // Drawn once, with a blinking cursor and the blink timer running.
        fixture.terminal.feed(text: "\u{1b}[1 qabout to close")
        view.renderTick()
        try #require(view.framesCommitted >= 1, "the view committed no frame before the close")
        view.setFocused(true)
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)

        // The close reaches the view one main-actor hop later, through the render signal relay's
        // unstructured task, which nothing can await. Cancelling the timer drops its sleeper at
        // once, so the poll is satisfied on its first look after that hop.
        fixture.terminal.close()
        let closedAt = ContinuousClock.now
        let stopped = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in !clock.hasSleeper }
        if stopped == .timedOut {
            Issue.record(BoundedWaitTimeout(
                what: "the close to stop the blink timer",
                observed: "the timer still armed \(ContinuousClock.now - closedAt) after the close",
                deadline: TestDeadlines.saturatedPass))
        }
        let committedAtClose = view.framesCommitted

        // Another surface on the shared renderer clears the atlas. A block the size of the atlas
        // clears it once and fills it, so the other surface's "B" fits nowhere and clears it again.
        let renderer = view.renderContext.renderer
        let atlas = renderer.glyphCache.grayscale
        let edge = atlas.size
        try #require(atlas.insert(pixels: [UInt8](repeating: 0, count: edge * edge),
                                  width: edge, height: edge, bytesPerRow: edge) != nil)
        let rebuildsBeforeOther = atlas.rebuildCount
        let otherTerminal = try GhosttyTerminal(
            cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { otherTerminal.close() }
        otherTerminal.feed(text: "B")
        let other = TerminalSurface()
        try other.attach(otherTerminal)
        let size = renderer.drawableSize(columns: 10, rows: 3)
        let texture = try #require(renderer.makeOffscreenTexture(width: size.width, height: size.height))
        // No wait for the GPU: the atlas is cleared on the CPU, inside `render`.
        try renderer.render(surface: other, to: texture)
        try #require(atlas.rebuildCount == rebuildsBeforeOther + 1,
                     "the other surface's frame cleared the atlas \(atlas.rebuildCount - rebuildsBeforeOther) times, not once")

        // Several blink periods pass. Each one also delivers the tick and every kind of frame
        // request by hand, so a timer that did not stop, or a guard that let a frame through,
        // shows up as a commit.
        for _ in 0..<4 {
            await clock.advance(by: GhosttyTerminalView.blinkInterval)
            view.blinkTick()
            view.requestFrame()
            view.renderTick()
            view.renderNow()
        }
        #expect(!clock.hasSleeper, "the blink timer is running again after the close")
        #expect(view.framesCommitted == committedAtClose,
                "the closed view committed \(view.framesCommitted - committedAtClose) frames")
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

    /// A view draws text at SwiftTerm's stroke weight. Font smoothing on an alpha-only bitmap is a
    /// stem-darkening pass that makes every stroke about a device pixel heavier, and SwiftTerm draws
    /// without it, so the glyph cache a view is given with the default appearance leaves it off.
    /// Checked on the cache the view really draws from: its glyphs are the bitmaps an unthickened
    /// rasterizer makes, and they carry less ink than a thickened rasterizer's.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aViewDrawsGlyphsWithoutThickening() throws {
        let fixture = try ViewFixture()
        let cache = fixture.view.renderContext.renderer.glyphCache
        let letters: [Character] = ["l", "m"]
        for letter in letters {
            let sample = try strokeSample(cache, letter: letter)
            let sameBitmap = sample.drawn == sample.thin
            #expect(sameBitmap, "the view's \(letter) is not the unthickened one: \(sample.description)")
            let drawnInk = StrokeSample.ink(sample.drawn)
            let thickInk = StrokeSample.ink(sample.thick)
            #expect(drawnInk < thickInk, "the view's \(letter) carries no less ink than the thickened one: \(sample.description)")
        }
    }

    /// The Thin strokes choice decides a view's stroke weight, as it decides SwiftTerm's font
    /// smoothing: with thin strokes the glyphs are the unthickened rasterizer's, and without them
    /// the thickened one's.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice), arguments: [true, false])
    func thinStrokesDecideAViewsStrokeWeight(thinStrokes: Bool) throws {
        let fixture = try ViewFixture(thinStrokes: thinStrokes)
        let view = fixture.view
        let context = view.renderContext
        let thickened = context.thicken
        #expect(thickened == !thinStrokes, "with thin strokes \(thinStrokes) the atlas has thicken \(thickened)")
        let sample = try strokeSample(context.renderer.glyphCache)
        let expected = thinStrokes ? sample.thin : sample.thick
        let matches = sample.drawn == expected
        #expect(matches, "with thin strokes \(thinStrokes) the view's m has the wrong weight: \(sample.description)")

        // A view is built outside a window, as every production view is. Mounting it can move it to
        // the window's backing scale, which takes another context; the weight must survive that.
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let content = try #require(window.contentView)
        place(view, in: content)
        let mountedThickened = view.renderContext.thicken
        #expect(mountedThickened == !thinStrokes,
                "with thin strokes \(thinStrokes) the mounted view's atlas has thicken \(mountedThickened)")
    }

    /// Changing the stroke weight of an open view moves it to a context drawn at the new weight, as
    /// a font change does, and every row is rebuilt against the new atlas. The old atlas is never
    /// drawn from again, so no frame mixes glyphs of both weights. Turning thin strokes back on
    /// returns the view to unthickened glyphs.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func changingTheStrokeWeightRebuildsTheAtlasAtTheNewWeight() throws {
        let fixture = try ViewFixture(thinStrokes: true)
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let content = try #require(window.contentView)
        place(view, in: content)
        fixture.terminal.feed(text: "mmm")
        view.renderTick()
        try #require(view.framesBuilt >= 1, "the view built no frame before the change")
        let thinContext = view.renderContext
        try #require(!thinContext.thicken, "the view started with a thickened atlas")
        let unbuiltStamp = SIMD2<UInt64>(repeating: .max)
        let stampBefore = view.surface.atlasRebuildStamp
        try #require(stampBefore != unbuiltStamp, "the first frame left the surface's atlas stamp unset")

        var heavier = fixture.appearance
        heavier.thinStrokes = false
        view.apply(heavier)
        // Only a re-attach resets the stamp, and nothing builds a frame between `apply` and here.
        // Both atlases start at rebuild generation 1, so without the re-attach the stamp would
        // read as current against the new atlas.
        let stampAfter = view.surface.atlasRebuildStamp
        #expect(stampAfter == unbuiltStamp, "the stroke change did not re-attach the surface: stamp \(stampAfter)")
        let thickContext = view.renderContext
        #expect(thickContext !== thinContext, "turning thin strokes off kept the thin context")
        #expect(thickContext.renderer.glyphCache.grayscale !== thinContext.renderer.glyphCache.grayscale,
                "turning thin strokes off kept the thin glyph atlas")
        #expect(thickContext.thicken, "turning thin strokes off did not thicken the atlas")
        let thick = try strokeSample(thickContext.renderer.glyphCache)
        let thickMatches = thick.drawn == thick.thick
        #expect(thickMatches, "with thin strokes off the view's m is not the thickened one: \(thick.description)")

        // The next frame rebuilds every row once, against the new atlas. The re-attach forces that,
        // and so does the palette `apply` hands the terminal; the count shows it is one pass.
        let rows = fixture.terminal.withLocked { $0.rows }
        let builder = thickContext.renderer.frameBuilder
        let buildsBefore = builder.rowBuildCount
        view.renderTick()
        let rebuilt = builder.rowBuildCount - buildsBefore
        #expect(rebuilt == rows, "the frame after the change built rows \(rebuilt) times for \(rows) rows")

        view.apply(fixture.appearance)
        let backContext = view.renderContext
        #expect(backContext !== thickContext, "turning thin strokes back on kept the thickened context")
        #expect(!backContext.thicken, "turning thin strokes back on left the atlas thickened")
        let thin = try strokeSample(backContext.renderer.glyphCache)
        let thinMatches = thin.drawn == thin.thin
        #expect(thinMatches, "with thin strokes back on the view's m is not the unthickened one: \(thin.description)")
    }

    /// The render context is keyed on stroke weight as well as font and scale. The same font at the
    /// same scale gets one context per weight, each drawing its own atlas, so a weight change can
    /// never be handed the atlas of the other weight. The same weight gets the shared context.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func theRenderContextIsKeyedOnStrokeWeight() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let thin = try TerminalRenderContext.shared(font: font, scale: 2, thicken: false, device: device)
        let thinAgain = try TerminalRenderContext.shared(font: font, scale: 2, thicken: false, device: device)
        let thick = try TerminalRenderContext.shared(font: font, scale: 2, thicken: true, device: device)
        #expect(thinAgain === thin, "the same font, scale and weight built a second context")
        #expect(thick !== thin, "a change of weight was handed the context of the other weight")
        #expect(thick.renderer.glyphCache.grayscale !== thin.renderer.glyphCache.grayscale,
                "both weights draw into one glyph atlas")
        let thinRasterizerThickens = thin.renderer.glyphCache.rasterizer.thicken
        let thickRasterizerThickens = thick.renderer.glyphCache.rasterizer.thicken
        #expect(!thinRasterizerThickens, "the unthickened context's rasterizer thickens")
        #expect(thickRasterizerThickens, "the thickened context's rasterizer does not thicken")
    }
}

/// `GhosttyTerminalView.shellQuoted(_:)`, which quotes a dropped file's path for the shell.
@Suite
@MainActor
struct GhosttyShellQuotingTests {
    /// An apostrophe a combining acute accent, an emoji variation selector or an enclosing keycap
    /// follows forms one `Character` with it, and is escaped all the same, so the path stays one
    /// shell word. Compared as bytes, because `String` equality is canonical equivalence.
    @Test(arguments: ["\u{301}", "\u{FE0F}", "\u{20E3}"])
    func anApostropheAMarkFollowsIsEscaped(_ mark: String) {
        let quoted = GhosttyTerminalView.shellQuoted("/tmp/x'\(mark); echo injected; '.png")
        let expected = "'/tmp/x'\\''\(mark); echo injected; '\\''.png'"
        #expect(Array(quoted.utf8) == Array(expected.utf8))
    }
}
