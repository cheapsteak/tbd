import AppKit
import Foundation
import Metal
@testable import TBDGhosttyCore
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
    /// Every text `onCommandClickText` was offered.
    var clickedTexts: [GhosttyClickedText] = []
    /// Whether `onCommandClickText` answers that the host opened something (`.opened`), or that it
    /// found nothing (`.nothing`).
    var opensText = false
}

/// An 80×24 terminal and a view over it in a monospaced font, 13 pt unless a test needs a render
/// context, and so a glyph atlas, that no other test's view shares.
@MainActor
private struct ViewFixture {
    let terminal: GhosttyTerminal
    let view: GhosttyTerminalView
    let appearance: GhosttyAppearance

    /// - Parameters:
    ///   - thinStrokes: the appearance's stroke weight; `nil` keeps `GhosttyAppearance`'s own
    ///     default.
    ///   - reportsPresents: report each committed frame's drawable presented, through the
    ///     tracker's test seam, as Metal would. An offscreen window's drawables may never be
    ///     reported, and two unreported ones stop output drawing at once. A test that leaves its
    ///     frames' drawables unreported passes `false`, and the tracker then ignores what Metal
    ///     reports too, so a drawable stays unreported until the test reports it.
    init(
        clock: any Clock<Duration> = ContinuousClock(), fontSize: CGFloat = 13, thinStrokes: Bool? = nil,
        reportsPresents: Bool = true
    ) throws {
        terminal = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        var appearance = GhosttyAppearance(
            font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            foreground: .init(r: 0xDD, g: 0xDD, b: 0xDD),
            background: .init(r: 0x10, g: 0x10, b: 0x10),
            cursor: .init(r: 0xFF, g: 0xFF, b: 0xFF))
        if let thinStrokes { appearance.thinStrokes = thinStrokes }
        self.appearance = appearance
        view = try GhosttyTerminalView(terminal: terminal, appearance: appearance, clock: clock)
        let tracker = view.drawableTracker
        if reportsPresents {
            view.onFrameEncoded = { tracker.reportNewestPresented() }
        } else {
            tracker.ignoresPresentedHandlers = true
        }
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

    /// The Metal layer is tagged sRGB, so Core Animation colour-matches the drawable the way it
    /// does a layer-backed view's backing store. Untagged, theme colours would be shown as the
    /// display's own gamut, oversaturated on a P3 display next to SwiftTerm.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func metalLayerIsTaggedSRGB() throws {
        let fixture = try ViewFixture()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        place(fixture.view, in: try #require(window.contentView))

        let layer = try #require(fixture.view.metalLayer, "the view is not backed by a CAMetalLayer")
        let name: String? = layer.colorspace?.name.map { $0 as String }
        let sRGB: String = CGColorSpace.sRGB as String
        #expect(name == sRGB, "the Metal layer's colour space is \(name ?? "nil"), not sRGB")
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
    /// shown. Otherwise the hold's first sighting before the hide counts against it, and the
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

/// A ⌘-click on plain text. The view reads the screen once, at the press, offers it to the host's
/// `onCommandClickText`, and consumes the press whole when the host says it opened something. An
/// OSC 8 link under the press comes first, and its text is never offered; nor is a press the host
/// declined.
@Suite(.fastPassBounded)
@MainActor
struct GhosttyCommandClickTextTests {
    /// The window point at the centre of the cell at `column`, `row`.
    private func point(column: Int, row: Int, in view: GhosttyTerminalView) -> NSPoint {
        let cell = view.cellSize
        return view.convert(
            NSPoint(x: (CGFloat(column) + 0.5) * cell.width, y: (CGFloat(row) + 0.5) * cell.height), to: nil)
    }

    /// Hands `view`'s hooks to `recorder`.
    private func record(_ view: GhosttyTerminalView, into recorder: ViewRecorder) {
        view.onSend = { recorder.sent.append($0) }
        view.onOpenLink = { recorder.openedLinks.append($0) }
        view.onMouseDownClaimFocus = { recorder.claimsPress }
        view.onCommandClickText = { text in
            recorder.clickedTexts.append(text)
            return recorder.opensText ? .opened : .nothing
        }
    }

    /// One SGR mouse report ending in `final`, whatever the button and modifier bits.
    private func isReport(_ bytes: [UInt8], final: Character) -> Bool {
        bytes.starts(with: Array("\u{1b}[<".utf8)) && bytes.last == final.asciiValue
    }

    /// A line that runs off the viewport is read on past both its edges, as SwiftTerm reads a line
    /// on its whole buffer, so a link on it is not cut where the view ends; and no further than the
    /// line runs.
    @Test func aLineRunningOffTheViewportIsReadOnPastBothEdges() throws {
        let terminal = try GhosttyTerminal(cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        // Screen rows: 0 "go", 1 to 6 one soft-wrapped line of 52 "y"s, the last row holding two of
        // them, and 7 "end". A page back from the bottom shows rows 2 to 4, all inside the line.
        terminal.feed(text: "go\r\n" + String(repeating: "y", count: 52) + "\r\nend")
        let scrolled = terminal.scrollViewportByPage(up: true)
        try #require(scrolled, "the viewport did not scroll back")
        let top = terminal.withLocked { $0.viewportTopScreenRow }
        let startsOnRowTwo = top == 2
        try #require(startsOnRowTwo, "the viewport starts on screen row \(String(describing: top)), not 2")

        let clicked = terminal.withLocked { GhosttyClickedText(viewportOf: $0, column: 3, row: 0) }

        let full = String(repeating: "y", count: 10)
        let expectedRows = [GhosttyClickedText.Row(text: full, isWrapContinuation: false)]
            + Array(repeating: GhosttyClickedText.Row(text: full, isWrapContinuation: true), count: 4)
            + [GhosttyClickedText.Row(text: "yy" + String(repeating: "\0", count: 8), isWrapContinuation: true)]
        let rows = clicked.rows
        #expect(rows == expectedRows, "the line read as \(rows.map(\.text.debugDescription))")
        let pressed = [clicked.column, clicked.row]
        #expect(pressed == [3, 1], "the pressed cell is column, row \(pressed) of the rows read")
    }

    /// Rows past the viewport are read on while SwiftTerm could join them: across a soft wrap, or
    /// under a row with text at or past its middle column, which its hard-wrap heuristic needs.
    @Test func aRowIsReadOnIntoWhileSwiftTermCouldJoinIt() {
        func row(_ text: String, wraps: Bool = false) -> GhosttyClickedText.Row {
            GhosttyClickedText.Row(text: text + String(repeating: "\0", count: 10 - text.count), isWrapContinuation: wraps)
        }
        let acrossASoftWrap = GhosttyClickedText.Row.mayJoin(row("go"), row("on", wraps: true), columns: 10)
        #expect(acrossASoftWrap, "a soft wrap does not join")
        let underTextAtTheMiddle = GhosttyClickedText.Row.mayJoin(row("aaaaa"), row("on"), columns: 10)
        #expect(underTextAtTheMiddle, "text reaching the middle column does not join")
        let underTextShortOfIt = GhosttyClickedText.Row.mayJoin(row("aaaa"), row("on"), columns: 10)
        #expect(!underTextShortOfIt, "text short of the middle column joins")
        let underTrailingSpaces = GhosttyClickedText.Row.mayJoin(row("aa        "), row("on"), columns: 10)
        #expect(!underTrailingSpaces, "spaces past the text count as text")
    }

    /// The rows come over as SwiftTerm reads its own: one character per column, `"\0"` for a cell
    /// with no text, and the row a soft wrap continues marked.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func theHostIsOfferedTheViewportThePressedCellAndTheSoftWraps() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        _ = try placeInCounter(view, in: window)
        record(view, into: recorder)
        let grid = view.gridSize
        let full = String(repeating: "a", count: grid.cols)
        fixture.terminal.feed(text: "\u{1b}[H\u{1b}[2J\(full)bc\r\n\u{65E5}x")
        let pressed = point(column: 1, row: 1, in: view)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: pressed, in: window, flags: .command))
        // The host opened nothing, so the press goes on as an ordinary click, which selects.
        let selects = view.mouseController.isSelecting
        #expect(selects, "a ⌘-press the host opened nothing for started no selection")
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: pressed, in: window, flags: .command))

        let offered = recorder.clickedTexts
        try #require(offered.count == 1, "the host was offered \(offered.count) texts")
        let text = offered[0]
        let shape = [text.column, text.row, text.columns, text.rows.count]
        #expect(shape == [1, 1, grid.cols, grid.rows], "column, row, columns and rows: \(shape)")
        let activates = text.activatesWindow
        #expect(!activates, "an ordinary ⌘-press was offered as the activating click")
        try #require(text.rows.count >= 3, "\(text.rows.count) rows")
        let top = text.rows[0]
        let topText = top.text
        #expect(topText == full, "row 0 reads \(topText.debugDescription)")
        let topWraps = top.isWrapContinuation
        #expect(!topWraps, "row 0 continues a row above it")
        let wrapped = text.rows[1]
        let wrappedText = wrapped.text
        let expectedWrapped = "bc" + String(repeating: "\0", count: grid.cols - 2)
        #expect(wrappedText == expectedWrapped, "row 1 reads \(wrappedText.debugDescription)")
        let wrappedWraps = wrapped.isWrapContinuation
        #expect(wrappedWraps, "row 1 does not continue row 0")
        // The second half of a wide character holds no text.
        let wideText = text.rows[2].text
        let wideStart = wideText.hasPrefix("\u{65E5}\0x")
        #expect(wideStart, "row 2 reads \(wideText.debugDescription)")

        // Control: a press without ⌘ is never offered.
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: pressed, in: window))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: pressed, in: window))
        let offeredAfterPlainClick = recorder.clickedTexts.count
        #expect(offeredAfterPlainClick == 1, "a press without ⌘ was offered to the host")
    }

    /// A program reporting the mouse gets none of a ⌘-press the host opened something for: not the
    /// press, not its drag, not its release, and neither does the selection or the responder chain.
    /// Nor does it get a ⌘-press the host opens nothing for: ⌘ is the view's link modifier, and a
    /// mouse report has no bit for it, so the program would read a plain click. The same press
    /// without ⌘ is an ordinary click, and is reported.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aPressTheHostOpensIsConsumedWholeEvenWhileTheProgramReportsTheMouse() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let counter = try placeInCounter(view, in: window)
        record(view, into: recorder)
        try #require(window.makeFirstResponder(view), "the window did not take the view as first responder")
        fixture.terminal.feed(text: "\u{1b}[H\u{1b}[2Jsee notes.txt\u{1b}[?1002h\u{1b}[?1006h")
        try #require(fixture.terminal.isMouseReporting, "the program did not take the mouse")
        let onText = point(column: 5, row: 0, in: view)
        let dragTo = point(column: 9, row: 0, in: view)

        recorder.opensText = true
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: onText, in: window, flags: .command))
        let selecting = view.mouseController.isSelecting
        #expect(!selecting, "a ⌘-press the host opened something for started a selection")
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: dragTo, in: window, flags: .command))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: dragTo, in: window, flags: .command))
        let offered = recorder.clickedTexts.count
        #expect(offered == 1, "the press was offered \(offered) times")
        let sentByOpened = recorder.sent
        #expect(sentByOpened.isEmpty, "a ⌘-press the host opened something for reached the program: \(sentByOpened)")
        let passedOn = [counter.draggedCount, counter.upCount]
        #expect(passedOn == [0, 0], "its drag and release went up the responder chain: \(passedOn)")
        let pending = view.mouseController.pendingReportReleases
        #expect(pending.isEmpty, "\(pending) wait for a release")

        // The host opens nothing, and the ⌘-press still reaches neither the program nor the
        // responder chain.
        recorder.opensText = false
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: onText, in: window, flags: .command))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onText, in: window, flags: .command))
        let sentByUnopened = recorder.sent
        #expect(sentByUnopened.isEmpty, "a ⌘-press the host opened nothing for reached the program: \(sentByUnopened)")
        let upsByUnopened = counter.upCount
        #expect(upsByUnopened == 0, "the release of a ⌘-press the host opened nothing for went up the responder chain")

        // Control: without ⌘, the same press is an ordinary, reported click.
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: onText, in: window))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onText, in: window))
        let reports = recorder.sent
        let pressAndRelease = reports.count == 2
            && reports.first.map { isReport($0, final: "M") } == true
            && reports.last.map { isReport($0, final: "m") } == true
        #expect(pressAndRelease, "control: a click without ⌘ sent \(reports)")
    }

    /// The link is looked up first and opens alone: the host is not offered the text a link shows,
    /// so one ⌘-click never opens two things. It opens at the release, which goes no further.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func anOSC8LinkOpensOnceAndItsTextIsNeverOffered() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let counter = try placeInCounter(view, in: window)
        record(view, into: recorder)
        recorder.opensText = true
        try #require(window.makeFirstResponder(view), "the window did not take the view as first responder")
        let link = "https://example.com/acme"
        fixture.terminal.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}]8;;\(link)\u{1b}\\notes.txt\u{1b}]8;;\u{1b}\\")
        let onLink = point(column: 1, row: 0, in: view)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: onLink, in: window, flags: .command))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onLink, in: window, flags: .command))

        let opened = recorder.openedLinks
        #expect(opened == [link], "the ⌘-click on the link opened \(opened)")
        let offered = recorder.clickedTexts.count
        #expect(offered == 0, "the host was also offered the link's text")
        let ups = counter.upCount
        #expect(ups == 0, "the release of the ⌘-click that opened the link went up the responder chain")
    }

    /// Any drag of a ⌘-press the view passed on ends it as a click, so the link under it opens
    /// nothing, even once the selection the press began is no longer under way: here losing focus
    /// ended it before the drag. Control: the same press, released where it went down, opens it.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aDragOfAPressPassedOnOpensNoLinkOnceItsSelectionEnded() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        _ = try placeInCounter(view, in: window)
        record(view, into: recorder)
        // First responder before the focus. Otherwise the press's click-to-focus takes the focus
        // from the window, which is never key, and the `setFocused(false)` below changes nothing.
        try #require(window.makeFirstResponder(view), "the window did not take the view as first responder")
        view.setFocused(true)
        let link = "https://example.com/acme"
        fixture.terminal.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}]8;;\(link)\u{1b}\\open the acme page\u{1b}]8;;\u{1b}\\")
        let onLink = point(column: 1, row: 0, in: view)
        let alongLink = point(column: 9, row: 0, in: view)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: onLink, in: window, flags: .command))
        let selecting = view.mouseController.isSelecting
        try #require(selecting, "the ⌘-press on the link started no selection")
        view.setFocused(false)
        let stillSelecting = view.mouseController.isSelecting
        try #require(!stillSelecting, "losing focus left the selection under way")
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: alongLink, in: window, flags: .command))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: alongLink, in: window, flags: .command))
        let openedByDrag = recorder.openedLinks
        #expect(openedByDrag.isEmpty, "the ⌘-drag opened \(openedByDrag)")

        // Control: released where it went down, the same press opens the link.
        view.setFocused(true)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: onLink, in: window, flags: .command))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onLink, in: window, flags: .command))
        let openedByClick = recorder.openedLinks
        #expect(openedByClick == [link], "control: the ⌘-click on the link opened \(openedByClick)")
    }

    /// A press the host declined has something drawn over the view that owns it, so its text is not
    /// offered, whether or not it activates the window. Claimed, the same ⌘-press is.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aPressTheHostDeclinedIsNeverOffered() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        _ = try placeInCounter(view, in: window)
        record(view, into: recorder)
        recorder.opensText = true
        fixture.terminal.feed(text: "\u{1b}[H\u{1b}[2Jsee notes.txt")
        let onText = point(column: 5, row: 0, in: view)

        recorder.claimsPress = false
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: onText, in: window, flags: .command))
        let selects = view.mouseController.isSelecting
        #expect(selects, "a declined ⌘-press did not go on as an ordinary click")
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onText, in: window, flags: .command))
        let activating = try mouseEvent(.leftMouseDown, at: onText, in: window, flags: .command, eventNumber: 11)
        let takesIt = view.acceptsFirstMouse(for: activating)
        #expect(takesIt)
        view.mouseDown(with: activating)
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onText, in: window, flags: .command, eventNumber: 11))
        let offeredWhenDeclined = recorder.clickedTexts.count
        #expect(offeredWhenDeclined == 0, "a declined ⌘-press was offered to the host")

        // Control: claimed, the same ⌘-press is offered.
        recorder.claimsPress = true
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: onText, in: window, flags: .command, eventNumber: 12))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onText, in: window, flags: .command, eventNumber: 12))
        let offeredWhenClaimed = recorder.clickedTexts.count
        #expect(offeredWhenClaimed == 1, "a claimed ⌘-press was offered \(offeredWhenClaimed) times")
    }

    /// The click that brings the window forward is offered too, marked as that click, and is
    /// consumed whichever way the host answers: it only activates unless the host opened something.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func theActivatingCommandClickIsOfferedAndConsumedWhicheverWayTheHostAnswers() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let recorder = ViewRecorder()
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let counter = try placeInCounter(view, in: window)
        record(view, into: recorder)
        fixture.terminal.feed(text: "\u{1b}[H\u{1b}[2Jsee notes.txt\u{1b}[?1002h\u{1b}[?1006h")
        let onText = point(column: 5, row: 0, in: view)

        for (offset, opens) in [false, true].enumerated() {
            recorder.opensText = opens
            let number = 21 + offset
            let down = try mouseEvent(.leftMouseDown, at: onText, in: window, flags: .command, eventNumber: number)
            let takesIt = view.acceptsFirstMouse(for: down)
            #expect(takesIt)
            view.mouseDown(with: down)
            let selecting = view.mouseController.isSelecting
            #expect(!selecting, "the activating ⌘-click started a selection, the host opening \(opens)")
            view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onText, in: window, flags: .command, eventNumber: number))
        }
        let markedActivating = recorder.clickedTexts.map(\.activatesWindow)
        #expect(markedActivating == [true, true], "the activating ⌘-clicks were offered as \(markedActivating)")
        let sent = recorder.sent
        #expect(sent.isEmpty, "the activating ⌘-clicks reached the program: \(sent)")
        let ups = counter.upCount
        #expect(ups == 0, "the activating ⌘-clicks' releases went up the responder chain")

        // Control: a ⌘-press in the active window is offered as an ordinary one.
        recorder.opensText = true
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: onText, in: window, flags: .command, eventNumber: 30))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: onText, in: window, flags: .command, eventNumber: 30))
        let lastActivates = recorder.clickedTexts.last?.activatesWindow
        #expect(lastActivates == false, "an ordinary ⌘-press was offered as \(String(describing: lastActivates))")
    }
}

/// How a nil drawable's hold on the drawable limit ends.
enum NilDrawableHoldEnd: Sendable, CaseIterable {
    /// A present report arrives.
    case report
    /// `presentReportTimeout` passes from the first check after the nil drawable.
    case timeout
}

/// A display tick never waits on the ring, and waits for a drawable only within a bound. With the
/// ring full, or while a nil drawable's hold lasts, it drops the frame before building it and
/// keeps the link ticking. With the layer's drawables awaiting their present report it draws
/// anyway; only a leading-edge draw drops there. `drawFrameNow()` and a live resize wait instead.
///
/// The unreported drawables are entries put into the view's tracker by hand. Real ones would do,
/// but Metal may report them at any moment, and a report would end the state under test.
@Suite(.fastPassBounded)
@MainActor
struct GhosttyTerminalViewBackpressureTests {
    /// Puts the view in `window` and draws and reports a first frame at 100 s, so the surface is
    /// clean and the link parked: a tick that then handed the surface's `needsDisplay` to the link
    /// would show as `needsUpdate` false.
    private func placeWithAFirstFrame(_ fixture: ViewFixture, in window: NSWindow) throws {
        let view = fixture.view
        place(view, in: try #require(window.contentView))
        view.now = { .seconds(100) }
        view.renderTick()
        let committed = view.framesCommitted
        try #require(committed == 1,
                     "the first frame was not committed (nil drawables so far: \(view.renderContext.renderer.stats.nilDrawables))")
        let parked = !view.frameDriver.demand.needsUpdate
        try #require(parked, "the link kept ticking after the first frame")
    }

    /// With all three ring slots in flight, a tick builds nothing, asks for no drawable and keeps
    /// `needsUpdate` set. Once the GPU gives a slot back, the view draws.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aTickWithTheRingFullBuildsNothingUntilASlotIsFree() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        try placeWithAFirstFrame(fixture, in: window)

        let held = HeldRingSlots(on: view.surface)
        defer { held.releaseAll() }
        try #require(held.held == FrameRing.depth, "only \(held.held) of the ring's slots could be taken")
        fixture.terminal.feed(text: "behind the GPU")
        // The render signal's delivery would ask for this frame. A synchronous test never lets it run.
        view.requestFrame()
        let built = view.framesBuilt
        let requests = view.renderContext.renderer.stats.drawableRequests

        view.renderTick(now: .seconds(100.25))
        let builtAtLimit = view.framesBuilt - built
        #expect(builtAtLimit == 0, "a tick with the ring full built \(builtAtLimit) frames")
        let askedAtLimit = view.renderContext.renderer.stats.drawableRequests - requests
        #expect(askedAtLimit == 0, "a tick with the ring full asked for \(askedAtLimit) drawables")
        let ticking = view.frameDriver.demand.needsUpdate
        #expect(ticking, "a tick with the ring full let the link park")

        held.releaseOne()
        view.renderTick(now: .seconds(100.5))
        let committed = view.framesCommitted
        #expect(committed == 2, "with a slot free again the view committed \(committed) frames in all, not 2")
    }

    /// Bulk output keeps the main thread busy, and Metal's present reports reach the tracker more
    /// than three refreshes after the frame that acquired each drawable. So two or three drawables
    /// await their report at every tick. The tick draws anyway: fed output before each of 20 ticks
    /// one refresh apart, every tick commits a frame.
    ///
    /// Each drawable is reported through the tracker's own report call three ticks after the tick
    /// that acquired it, once that later tick has run, as a handler queued behind it would. The
    /// fixture has the tracker ignore Metal's own reports, which an offscreen window may send at
    /// once, while the test waits for a ring slot, and which would hide the late ones. Each
    /// chunk is bulk output, so its render signal's delivery leaves the frame to the tick. Before
    /// each tick the test waits for the GPU to hand back a ring slot: the ring's limit is real GPU
    /// work, and a tick still drops at it.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func everyTickDrawsWhilePresentReportsComeThreeRefreshesLate() async throws {
        let fixture = try ViewFixture(reportsPresents: false)
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        place(view, in: try #require(window.contentView))
        let start = Duration.seconds(100)
        let interval = LeadingEdgePolicy.fallbackRefreshInterval
        let now = ManualNow(start)
        view.now = { now.value }
        let tracker = view.drawableTracker
        let ticks = 20
        let reportDelay = 3
        // More than the small-output limit, so no delivery draws a frame of its own.
        let chunk = String(repeating: "x", count: LeadingEdgePolicy.smallOutputLimit) + "\r\n"
        var acquiredByTick: [Int: DrawableTracker.DrawableID] = [:]
        var ticksThatCommittedNothing: [Int] = []

        for tick in 0..<ticks {
            let tickNow = start + interval * tick
            now.value = tickNow
            fixture.terminal.feed(text: chunk)
            try await waitForAFreeRingSlot(view)
            let committed = view.framesCommitted
            let acquired = tracker.acquiredCount
            view.renderTick(now: tickNow)
            if view.framesCommitted == committed { ticksThatCommittedNothing.append(tick) }
            if tracker.acquiredCount > acquired, let id = tracker.newestEntryID { acquiredByTick[tick] = id }
            // Delivered after this tick's check: the drawable of the tick `reportDelay` before it.
            if let late = acquiredByTick.removeValue(forKey: tick - reportDelay) {
                tracker.reportPresented(late, presentedTime: tickNow / .seconds(1))
            }
        }
        let nils = view.renderContext.renderer.stats.nilDrawables
        #expect(ticksThatCommittedNothing.isEmpty,
                "with each present reported \(reportDelay) refreshes late, the ticks \(ticksThatCommittedNothing) of \(ticks) committed no frame (nil drawables: \(nils))")
    }

    /// Two drawables unreported and younger than `presentReportTimeout`: a leading-edge draw
    /// builds nothing, asks for no drawable and keeps `needsUpdate` set. A tick at the same `now`
    /// asks for a drawable anyway and commits its frame, and the present-timing log notes no drop
    /// for it.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aTickDrawsWithTwoDrawablesUnreportedWhereTheLeadingEdgeDrops() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        try placeWithAFirstFrame(fixture, in: window)

        let tracker = view.drawableTracker
        let timing = tracker.presentTiming
        _ = tracker.add(acquiredAt: .seconds(100.25))
        _ = tracker.add(acquiredAt: .seconds(100.5))
        fixture.terminal.feed(text: "waiting on the screen")
        view.requestFrame()
        let built = view.framesBuilt
        let requests = view.renderContext.renderer.stats.drawableRequests
        let notedBefore = timing.gpuBehindNoted

        // 0.75 s after the older drawable: younger than the timeout, so nothing is cleared.
        view.renderTick(now: .seconds(101), backpressure: .leadingEdge)
        let builtByEdge = view.framesBuilt - built
        #expect(builtByEdge == 0, "a leading-edge draw with two drawables unreported built \(builtByEdge) frames")
        let askedByEdge = view.renderContext.renderer.stats.drawableRequests - requests
        #expect(askedByEdge == 0, "a leading-edge draw with two drawables unreported asked for \(askedByEdge) drawables")
        let ticking = view.frameDriver.demand.needsUpdate
        #expect(ticking, "a leading-edge draw with two drawables unreported let the link park")
        let notedByEdge = timing.gpuBehindNoted - notedBefore
        #expect(notedByEdge == 1, "the leading edge's drop was noted \(notedByEdge) times")

        view.renderTick(now: .seconds(101))
        let askedByTick = view.renderContext.renderer.stats.drawableRequests - requests
        #expect(askedByTick == 1, "a tick with two drawables unreported asked for \(askedByTick) drawables")
        let committed = view.framesCommitted
        #expect(committed == 2,
                "a tick with two drawables unreported left the view at \(committed) frames committed, not 2 (nil drawables so far: \(view.renderContext.renderer.stats.nilDrawables))")
        let notedByTick = timing.gpuBehindNoted - notedBefore - notedByEdge
        #expect(notedByTick == 0, "a tick that drew was noted as dropped \(notedByTick) times")
    }

    /// A frame dropped at a GPU limit hands the present-timing log what it found: whether the
    /// ring was full, whether a nil drawable's hold lasted, and the age of each unreported drawable
    /// by the frame's `now`. A tick drops at the full ring, and a leading-edge draw at the drawable
    /// limit, where a tick draws. A frame that draws hands it nothing.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice), arguments: GPULimit.allCases)
    func aDroppedFrameHandsThePresentTimingLogWhatItFound(_ limit: GPULimit) throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        try placeWithAFirstFrame(fixture, in: window)

        let tracker = view.drawableTracker
        let timing = tracker.presentTiming
        var held: HeldRingSlots?
        defer { held?.releaseAll() }
        var newer: DrawableTracker.DrawableID?
        let expectedAges: [String]
        let backpressure: GPUBackpressure
        switch limit {
        case .ringFull:
            let slots = HeldRingSlots(on: view.surface)
            held = slots
            try #require(slots.held == FrameRing.depth, "only \(slots.held) of the ring's slots could be taken")
            expectedAges = []
            backpressure = .tick
        case .drawablesBehind:
            // Younger than `presentReportTimeout`, so the tracker clears neither.
            _ = tracker.add(acquiredAt: .seconds(100.25))
            newer = tracker.add(acquiredAt: .seconds(100.5))
            expectedAges = ["750.000", "500.000"]
            backpressure = .leadingEdge
        }
        fixture.terminal.feed(text: "behind the GPU")
        view.requestFrame()
        let notedBefore = timing.gpuBehindNoted

        view.renderTick(now: .seconds(101), backpressure: backpressure)
        let noted = timing.gpuBehindNoted - notedBefore
        try #require(noted == 1, "a frame dropped at the \(limit) limit was noted \(noted) times")
        let found = try #require(timing.lastGPUBehind, "a frame dropped at the \(limit) limit left no sample")
        let ringFree = found.ringHasFreeSlot
        let expectedRingFree = limit != .ringFull
        #expect(ringFree == expectedRingFree, "a frame dropped at the \(limit) limit read the ring free: \(ringFree)")
        let heldFound = found.nilDrawableHold
        #expect(!heldFound, "a frame dropped at the \(limit) limit read a nil drawable's hold")
        let ages = found.entryAges.map(PresentTimingLog.milliseconds)
        #expect(ages == expectedAges, "a frame dropped at the \(limit) limit read the ages \(ages)")

        switch limit {
        case .ringFull:
            held?.releaseOne()
        case .drawablesBehind:
            if let newer { tracker.reportPresented(newer, presentedTime: 101) }
        }
        let notedBeforeDraw = timing.gpuBehindNoted
        view.renderTick(now: .seconds(101.25), backpressure: backpressure)
        let committed = view.framesCommitted
        try #require(committed == 2,
                     "once the \(limit) limit cleared the view committed \(committed) frames in all, not 2")
        let notedByDraw = timing.gpuBehindNoted - notedBeforeDraw
        #expect(notedByDraw == 0, "a frame that drew was noted as dropped \(notedByDraw) times")
    }

    /// A tick asks for a drawable whatever the tracker counts, here with two drawables unreported
    /// and younger than `presentReportTimeout`. The seam returns nil, as a full pool would after
    /// `nextDrawable()`'s one-second wait: `nilDrawables` rises by one, nothing commits, and
    /// `needsUpdate` stays set. The ticks within the next `presentReportTimeout` drop before they
    /// build, ask for no drawable, and are noted as held, a late report of a present made before
    /// the nil notwithstanding. Then a report of a later present, or the end of that timeout with
    /// the seam handing out drawables again, lets the next tick draw.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice),
          arguments: NilDrawableHoldEnd.allCases)
    func aNilDrawableHoldsTheTickOffForATimeout(end: NilDrawableHoldEnd) throws {
        // The test sends every report: one from Metal, dated by real host time, would end the hold.
        let fixture = try ViewFixture(reportsPresents: false)
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        // No frame before this one, so no real drawable is out when the hold starts.
        place(view, in: try #require(window.contentView))
        let tracker = view.drawableTracker
        let timing = tracker.presentTiming
        let older = tracker.add(acquiredAt: .seconds(100.5))
        let newer = tracker.add(acquiredAt: .seconds(100.75))
        fixture.terminal.feed(text: "a stalled screen")
        view.nextDrawable = { _ in nil }

        let before = view.renderContext.renderer.stats
        view.renderTick(now: .seconds(101))
        let afterNil = view.renderContext.renderer.stats
        let asked = afterNil.drawableRequests - before.drawableRequests
        #expect(asked == 1, "a tick with two drawables unreported asked for \(asked) drawables")
        let nils = afterNil.nilDrawables - before.nilDrawables
        #expect(nils == 1, "the full pool's nil drawable counted \(nils) times")
        let committedAtNil = view.framesCommitted
        #expect(committedAtNil == 0, "a frame with no drawable was committed")
        let tickingAtNil = view.frameDriver.demand.needsUpdate
        #expect(tickingAtNil, "a frame with no drawable let the link park")

        // The hold is timed from the next check, at 101.25 s. A late report of a present made
        // before the nil, as bulk output leaves queued, does not end it.
        let notedBeforeHold = timing.gpuBehindNoted
        view.renderTick(now: .seconds(101.25))
        tracker.reportPresented(older, presentedTime: 100.875)
        view.renderTick(now: .seconds(102))
        let askedInHold = view.renderContext.renderer.stats.drawableRequests - afterNil.drawableRequests
        #expect(askedInHold == 0, "ticks within a timeout of the nil drawable asked for \(askedInHold) drawables")
        let tickingInHold = view.frameDriver.demand.needsUpdate
        #expect(tickingInHold, "a tick held off by a nil drawable let the link park")
        let notedInHold = timing.gpuBehindNoted - notedBeforeHold
        #expect(notedInHold == 2, "the two held ticks were noted as dropped \(notedInHold) times")
        let found = timing.lastGPUBehind
        let heldFound = found?.nilDrawableHold ?? false
        let ringFreeFound = found?.ringHasFreeSlot ?? false
        #expect(heldFound && ringFreeFound,
                "a held tick was noted with the hold \(heldFound) and the ring free \(ringFreeFound)")

        view.nextDrawable = { $0.nextDrawable() }
        switch end {
        case .report:
            // A present made after the nil came back, a second after the tick that asked, freed
            // a drawable. The tick is still within the hold's timeout, so only the report can
            // end it.
            tracker.reportPresented(newer, presentedTime: 102)
            view.renderTick(now: .seconds(102))
        case .timeout:
            view.renderTick(now: .seconds(102.25))
        }
        let askedAfter = view.renderContext.renderer.stats.drawableRequests - afterNil.drawableRequests
        #expect(askedAfter == 1, "after the hold ended (\(end)) the tick asked for \(askedAfter) drawables")
        let committed = view.framesCommitted
        #expect(committed == 1,
                "after the hold ended (\(end)) the view committed \(committed) frames (nil drawables so far: \(view.renderContext.renderer.stats.nilDrawables))")
    }

    /// A frame whose render encoder cannot be made drops its acquired drawable unpresented. The
    /// drop path removes that drawable's entry by id, since no report may ever come for it and an
    /// entry left behind would count against the limit until the timeout.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aDrawableDroppedForWantOfAnEncoderLeavesTheTracker() throws {
        // A font size no other test uses, so a renderer no other view shares: the seam below
        // changes it for every view drawn with it.
        let fixture = try ViewFixture(fontSize: 12.25, reportsPresents: false)
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        place(view, in: try #require(window.contentView))
        view.now = { .seconds(100) }
        let renderer = view.renderContext.renderer
        let makeRenderEncoder = renderer.makeRenderEncoder
        renderer.makeRenderEncoder = { _, _ in nil }
        defer { renderer.makeRenderEncoder = makeRenderEncoder }
        let tracker = view.drawableTracker
        let acquiredBefore = tracker.acquiredCount
        fixture.terminal.feed(text: "no encoder")

        view.renderTick()
        let built = view.framesBuilt
        #expect(built == 1, "the tick built \(built) frames")
        let acquired = tracker.acquiredCount - acquiredBefore
        try #require(acquired == 1,
                     "the frame acquired \(acquired) drawables (nil drawables so far: \(renderer.stats.nilDrawables))")
        let committed = view.framesCommitted
        #expect(committed == 0, "a frame with no encoder was committed \(committed) times")
        let left = tracker.entryCount
        #expect(left == 0, "the drawable dropped unpresented left \(left) entries")
    }

    /// `drawFrameNow()` skips both GPU checks, because the instruments that call it draw in
    /// offscreen windows whose presents may never be reported, and a frame they ask for is one
    /// they mean to see drawn. With two drawables unreported and a nil drawable's hold lasting, a
    /// tick drops, and `drawFrameNow()` still commits. Its drawable is still tracked.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func drawFrameNowDrawsThroughANilDrawablesHold() throws {
        let fixture = try ViewFixture(reportsPresents: false)
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        place(view, in: try #require(window.contentView))
        view.now = { .seconds(100.5) }
        let tracker = view.drawableTracker
        _ = tracker.add(acquiredAt: .seconds(100))
        _ = tracker.add(acquiredAt: .seconds(100.25))
        tracker.noteNoDrawable(requestedAt: .seconds(100.5))
        fixture.terminal.feed(text: "an instrumented frame")

        // Control, first, while no real drawable is out to be reported: a tick in the hold drops.
        view.renderTick()
        let builtByTick = view.framesBuilt
        #expect(builtByTick == 0, "control: a tick in a nil drawable's hold built \(builtByTick) frames")

        let acquired = tracker.acquiredCount
        view.drawFrameNow()
        let committed = view.framesCommitted
        #expect(committed == 1,
                "drawFrameNow committed \(committed) frames in a nil drawable's hold (nil drawables so far: \(view.renderContext.renderer.stats.nilDrawables))")
        let tracked = tracker.acquiredCount - acquired
        #expect(tracked == 1, "drawFrameNow's drawable went into the tracker \(tracked) times")
    }

    /// A live resize promised Core Animation a present in its transaction, so its frame skips both
    /// GPU checks and is drawn, here with two drawables unreported and a nil drawable's hold
    /// lasting.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aLiveResizeFrameDrawsThroughANilDrawablesHold() throws {
        // The test sends every report: one from Metal, dated by real host time, would end the hold.
        let fixture = try ViewFixture(reportsPresents: false)
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        place(view, in: try #require(window.contentView))
        view.now = { .seconds(100.5) }
        let tracker = view.drawableTracker
        _ = tracker.add(acquiredAt: .seconds(100))
        _ = tracker.add(acquiredAt: .seconds(100.25))
        tracker.noteNoDrawable(requestedAt: .seconds(100.5))

        // Control: outside the resize the same frame is dropped.
        view.renderNow()
        let builtOutside = view.framesBuilt
        #expect(builtOutside == 0, "control: outside a live resize the frame was built \(builtOutside) times")

        view.viewWillStartLiveResize()
        defer { view.viewDidEndLiveResize() }
        view.renderNow()
        let committed = view.framesCommitted
        #expect(committed == 1,
                "a live resize's frame was committed \(committed) times (nil drawables so far: \(view.renderContext.renderer.stats.nilDrawables))")
    }

    /// A tick asks for a drawable whatever the tracker counts, so only rule 1 keeps a view the
    /// screen does not show from asking. Hidden or in an occluded window, with two drawables
    /// unreported as bulk output leaves them, a tick builds nothing and asks for no drawable. Shown
    /// again, the next tick draws.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice), arguments: Concealment.allCases)
    func aViewTheScreenDoesNotShowAsksForNoDrawable(_ concealment: Concealment) throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        place(view, in: try #require(window.contentView))
        let tracker = view.drawableTracker
        _ = tracker.add(acquiredAt: .seconds(100))
        _ = tracker.add(acquiredAt: .seconds(100.25))
        switch concealment {
        case .hidden:
            view.isHidden = true
        case .occluded:
            view.windowVisibility = { _ in false }
            view.refreshOcclusion()
        }
        let requests = view.renderContext.renderer.stats.drawableRequests

        for index in 0..<10 {
            fixture.terminal.feed(text: "line \(index)\r\n")
            view.renderTick(now: Duration.seconds(100.5) + LeadingEdgePolicy.fallbackRefreshInterval * index)
        }
        let built = view.framesBuilt
        #expect(built == 0, "a view \(concealment) built \(built) frames")
        let asked = view.renderContext.renderer.stats.drawableRequests - requests
        #expect(asked == 0, "a view \(concealment) asked for \(asked) drawables")

        switch concealment {
        case .hidden:
            view.isHidden = false
        case .occluded:
            view.windowVisibility = { _ in true }
            view.refreshOcclusion()
        }
        view.renderTick(now: .seconds(100.75))
        let committed = view.framesCommitted
        #expect(committed == 1,
                "a view shown again committed \(committed) frames, not 1 (nil drawables so far: \(view.renderContext.renderer.stats.nilDrawables))")
    }
}

/// A `now` the test moves by hand, for the view's `now` seam.
@MainActor
private final class ManualNow {
    var value: Duration

    init(_ value: Duration) {
        self.value = value
    }
}

/// The view, carried into a `@Sendable` wait condition. The view itself is not `Sendable`; a
/// main-actor class that holds it is, and the condition reads it back on the main actor.
@MainActor
private final class ViewHandle {
    let view: GhosttyTerminalView

    init(_ view: GhosttyTerminalView) {
        self.view = view
    }
}

/// Waits, bounded, until the GPU has handed back a ring slot. A test that has committed several
/// frames calls it before the next frame it needs drawn, so that frame is not dropped for a frame
/// the GPU is still finishing. The wait suspends, so a render signal's delivery queued on main
/// runs in it.
@MainActor
private func waitForAFreeRingSlot(_ view: GhosttyTerminalView) async throws {
    let handle = ViewHandle(view)
    try await waitFor("the GPU to hand back a ring slot") { @Sendable in
        await MainActor.run { handle.view.surface.frameRing?.hasFreeSlot ?? true }
    }
}

/// How a view is kept off the screen.
enum Concealment: Sendable, CaseIterable {
    /// The view itself is hidden.
    case hidden
    /// The view's window is occluded.
    case occluded
}

/// Which GPU limit a test holds the view at.
enum GPULimit: Sendable, CaseIterable {
    /// All three of the surface's ring slots in flight.
    case ringFull
    /// `TerminalRenderer.maxDrawablesAwaitingPresent` drawables awaiting their present report.
    case drawablesBehind
}

/// Output draws on the leading edge: a render signal's delivery draws small output into an idle
/// view at once, inside the delivery and without a display tick, and leaves everything else to
/// the tick. Each test drives the view's `now` seam by hand. The fixture's window is offscreen, so
/// its display link never ticks: a frame drawn with no `renderTick()` was drawn by the delivery.
@Suite(.fastPassBounded)
@MainActor
struct GhosttyTerminalViewLeadingEdgeTests {
    /// Puts the view in `window` with its time on `now`, and draws a first frame: the attach's
    /// full rebuild, which consumed no output and so stamps no output frame.
    private func placeWithAFirstFrame(_ fixture: ViewFixture, in window: NSWindow, now: ManualNow) throws {
        let view = fixture.view
        place(view, in: try #require(window.contentView))
        view.now = { now.value }
        view.renderTick()
        let committed = view.framesCommitted
        try #require(committed == 1,
                     "the first frame was not committed (nil drawables so far: \(view.renderContext.renderer.stats.nilDrawables))")
        let stamped = view.lastOutputFrameAt
        let none: Duration? = nil
        try #require(stamped == none, "a frame with no output stamped an output frame at \(String(describing: stamped))")
    }

    /// Feeds `text` and waits, bounded, for its render signal's delivery: one main-queue turn.
    private func feedAndDeliver(_ text: String, to fixture: ViewFixture) async throws {
        try await signalAndDeliver(to: fixture) { fixture.terminal.feed(text: text) }
    }

    /// Runs `call`, which must signal a render, and waits, bounded, for the delivery.
    private func signalAndDeliver(to fixture: ViewFixture, _ call: () -> Void) async throws {
        let handle = ViewHandle(fixture.view)
        let before = handle.view.renderSignalDeliveries
        call()
        try await waitFor("the render signal's delivery") {
            await MainActor.run { handle.view.renderSignalDeliveries > before }
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aSmallFeedIntoAnIdleViewDrawsWithoutATick() async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)

        try await feedAndDeliver("a", to: fixture)
        let decision = view.lastLeadingEdgeDecision
        let drawNow: LeadingEdgePolicy.Decision? = .drawNow
        #expect(decision == drawNow, "a 1-byte feed into an idle view answered \(String(describing: decision))")
        let committed = view.framesCommitted
        #expect(committed == 2, "the delivery committed \(committed - 1) frames, not 1")
        let stamped = view.lastOutputFrameAt
        let expectedStamp: Duration? = .seconds(100)
        #expect(stamped == expectedStamp, "the frame that drew the feed stamped \(String(describing: stamped))")
    }

    /// Within a refresh interval of the last output frame, a feed waits for the tick. One interval
    /// after it, a feed draws at once again.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aFeedWithinTheIntervalWaitsForTheTickAndOneIntervalLaterDrawsAtOnce() async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)
        let interval = view.refreshInterval
        try #require(interval > .milliseconds(2), "the refresh interval is \(interval), too short for this test")
        try await feedAndDeliver("a", to: fixture)
        let afterFirst = view.framesCommitted
        try #require(afterFirst == 2, "the first feed was not drawn at once")

        now.value = .seconds(100.002)
        try await feedAndDeliver("b", to: fixture)
        let waited = view.lastLeadingEdgeDecision
        let within: LeadingEdgePolicy.Decision? = .coalesce(.withinRefreshInterval)
        #expect(waited == within, "a feed 2 ms after an output frame answered \(String(describing: waited))")
        let committedWaiting = view.framesCommitted
        #expect(committedWaiting == afterFirst, "a feed 2 ms after an output frame was drawn before the tick")
        let ticking = view.frameDriver.demand.needsUpdate
        #expect(ticking, "the feed left to the tick asked the link for no frame")

        view.renderTick()
        let afterTick = view.framesCommitted
        #expect(afterTick == afterFirst + 1, "the tick committed \(afterTick - afterFirst) frames, not 1")
        let tickStamp = try #require(view.lastOutputFrameAt, "the tick's output frame stamped nothing")
        let expectedTickStamp: Duration = .seconds(100.002)
        #expect(tickStamp == expectedTickStamp, "the tick's output frame stamped \(tickStamp)")

        now.value = tickStamp + interval
        try await waitForAFreeRingSlot(view)
        try await feedAndDeliver("c", to: fixture)
        let drew = view.lastLeadingEdgeDecision
        let drawNow: LeadingEdgePolicy.Decision? = .drawNow
        #expect(drew == drawNow, "a feed one interval after the last output frame answered \(String(describing: drew))")
        let afterLast = view.framesCommitted
        #expect(afterLast == afterTick + 1, "a feed one interval after the last output frame committed \(afterLast - afterTick) frames")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func twoKilobytesInOneChunkWaitForTheTick() async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)

        try await feedAndDeliver(String(repeating: "x", count: 2048), to: fixture)
        let decision = view.lastLeadingEdgeDecision
        let bulk: LeadingEdgePolicy.Decision? = .coalesce(.bulkOutput)
        #expect(decision == bulk, "2 KB in one chunk answered \(String(describing: decision))")
        let committed = view.framesCommitted
        #expect(committed == 1, "2 KB in one chunk was drawn before the tick")

        view.renderTick()
        let afterTick = view.framesCommitted
        #expect(afterTick == 2, "the tick committed \(afterTick - 1) frames, not 1")
    }

    /// A hold hides its frame, and its end draws at once whatever its size: the program promised
    /// a complete frame. A chunk that ends a hold and begins the next draws nothing at once.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aHoldDrawsNothingAndItsEndDrawsAtOnce() async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)
        let begin = "\u{1b}[?2026h"
        let end = "\u{1b}[?2026l"

        // More than the small-output limit, so only the end of the hold can draw it at once.
        try await feedAndDeliver(begin + String(repeating: "x", count: 2048), to: fixture)
        let held = view.lastLeadingEdgeDecision
        let holdOpen: LeadingEdgePolicy.Decision? = .coalesce(.holdOpen)
        #expect(held == holdOpen, "a feed inside a hold answered \(String(describing: held))")
        let committedInHold = view.framesCommitted
        #expect(committedInHold == 1, "a feed inside a hold was drawn")

        try await feedAndDeliver(end, to: fixture)
        let released = view.lastLeadingEdgeDecision
        let drawNow: LeadingEdgePolicy.Decision? = .drawNow
        #expect(released == drawNow, "the end of a 2 KB hold answered \(String(describing: released))")
        let committedAtEnd = view.framesCommitted
        #expect(committedAtEnd == 2, "the end of the hold committed \(committedAtEnd - 1) frames, not 1")

        // A whole interval later, so only the hold can hold the frame back.
        now.value = .seconds(100) + view.refreshInterval
        try await feedAndDeliver(begin + "next", to: fixture)
        try await feedAndDeliver(end + begin + "and the next", to: fixture)
        let reopened = view.lastLeadingEdgeDecision
        #expect(reopened == holdOpen, "a chunk that ended a hold and began the next answered \(String(describing: reopened))")
        let committedReopened = view.framesCommitted
        #expect(committedReopened == committedAtEnd, "a chunk that ended a hold and began the next was drawn at once")
    }

    /// A live resize draws from `setFrameSize`, so a delivery leaves it alone. That path's own
    /// frame stamps the last output frame.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aLiveResizeDrawsNoLeadingEdgeFrame() async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)
        view.viewWillStartLiveResize()
        defer { view.viewDidEndLiveResize() }

        try await feedAndDeliver("a", to: fixture)
        let decision = view.lastLeadingEdgeDecision
        let liveResize: LeadingEdgePolicy.Decision? = .coalesce(.liveResize)
        #expect(decision == liveResize, "a feed during a live resize answered \(String(describing: decision))")
        let committed = view.framesCommitted
        #expect(committed == 1, "a feed during a live resize was drawn by the delivery")

        // The frame `setFrameSize` draws, which reads the `now` seam.
        now.value = .seconds(100.25)
        view.renderNow()
        let afterResizeFrame = view.framesCommitted
        #expect(afterResizeFrame == 2, "the live resize's frame was not committed")
        let stamped = view.lastOutputFrameAt
        let expectedStamp: Duration? = .seconds(100.25)
        #expect(stamped == expectedStamp, "the live resize's output frame stamped \(String(describing: stamped))")
    }

    /// A signal with no output behind it, as a reset's, is left to the tick: the leading edge is
    /// for output. The output that follows it still draws at once.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aResetDrawsNothingAtOnceAndTheOutputAfterItDoes() async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)

        try await signalAndDeliver(to: fixture) { fixture.terminal.reset() }
        let reset = view.lastLeadingEdgeDecision
        let noOutput: LeadingEdgePolicy.Decision? = .coalesce(.noOutput)
        #expect(reset == noOutput, "a reset answered \(String(describing: reset))")
        let committedAfterReset = view.framesCommitted
        #expect(committedAfterReset == 1, "a reset was drawn by the delivery")
        let ticking = view.frameDriver.demand.needsUpdate
        #expect(ticking, "the reset left to the tick asked the link for no frame")

        try await feedAndDeliver("$ ", to: fixture)
        let prompt = view.lastLeadingEdgeDecision
        let drawNow: LeadingEdgePolicy.Decision? = .drawNow
        #expect(prompt == drawNow, "the prompt after a reset answered \(String(describing: prompt))")
        let committed = view.framesCommitted
        #expect(committed == 2, "the prompt after a reset committed \(committed - 1) frames, not 1")
    }

    /// Output that changes nothing on screen builds a frame and commits none, so it stamps no
    /// output frame. The delivery that drew it still counts for rule 4: output within an interval
    /// of it goes to the tick, so such output is read once per refresh, not at every hop.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func outputThatDrawsNothingStillLimitsTheLeadingEdgeToOncePerInterval() async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)

        // SGR 0 with the default rendition already set: output, and nothing to draw.
        let built = view.framesBuilt
        try await feedAndDeliver("\u{1b}[0m", to: fixture)
        let invisible = view.lastLeadingEdgeDecision
        let drawNow: LeadingEdgePolicy.Decision? = .drawNow
        try #require(invisible == drawNow, "output that draws nothing answered \(String(describing: invisible))")
        let builtForIt = view.framesBuilt - built
        try #require(builtForIt == 1, "the delivery built \(builtForIt) frames for output that draws nothing")
        let committedForIt = view.framesCommitted
        try #require(committedForIt == 1, "SGR 0 committed a frame, so this test's premise fails")
        let stamped = view.lastOutputFrameAt
        let none: Duration? = nil
        #expect(stamped == none, "a frame that committed nothing stamped an output frame at \(String(describing: stamped))")

        now.value = .seconds(100.002)
        try await feedAndDeliver("a", to: fixture)
        let next = view.lastLeadingEdgeDecision
        let within: LeadingEdgePolicy.Decision? = .coalesce(.withinRefreshInterval)
        #expect(next == within, "output 2 ms after a delivery that drew nothing answered \(String(describing: next))")

        now.value = .seconds(100) + view.refreshInterval
        try await feedAndDeliver("b", to: fixture)
        let later = view.lastLeadingEdgeDecision
        #expect(later == drawNow, "output one interval later answered \(String(describing: later))")
    }

    /// A tick can draw output before that output's delivery runs. The delivery's hint still counts
    /// the output, so it draws, and its build finds none left to consume and commits nothing. That
    /// is output a tick drew, not output that draws nothing, so it stamps no empty draw, and the
    /// next output draws at once.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aDeliveryWhoseOutputATickDrewFirstDoesNotHoldBackTheNext() async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)

        let built = view.framesBuilt
        let committed = view.framesCommitted
        try await signalAndDeliver(to: fixture) {
            fixture.terminal.feed(text: "a")
            // The tick runs before the delivery and draws the output.
            view.renderTick()
            // The delivery runs past the refresh interval and the tracker's present-report
            // timeout, so neither rule 4 nor the drawables keep it from drawing.
            now.value = .seconds(102)
        }
        let stampedByTheTick = view.lastOutputFrameAt
        let tickStamp: Duration? = .seconds(100)
        try #require(stampedByTheTick == tickStamp, "the tick's frame stamped \(String(describing: stampedByTheTick))")
        let decision = view.lastLeadingEdgeDecision
        let drawNow: LeadingEdgePolicy.Decision? = .drawNow
        try #require(decision == drawNow, "the delivery after the tick answered \(String(describing: decision))")
        let builtForBoth = view.framesBuilt - built
        try #require(builtForBoth == 2, "the tick and the delivery built \(builtForBoth) frames, not 2")
        let committedForBoth = view.framesCommitted - committed
        try #require(committedForBoth == 1, "the tick and the delivery committed \(committedForBoth) frames, not the tick's 1")
        let empty = view.lastEmptyLeadingEdgeDrawAt
        let none: Duration? = nil
        #expect(empty == none, "a delivery whose output a tick drew stamped an empty draw at \(String(describing: empty))")

        now.value = .seconds(102.002)
        try await waitForAFreeRingSlot(view)
        try await feedAndDeliver("b", to: fixture)
        let next = view.lastLeadingEdgeDecision
        #expect(next == drawNow, "output 2 ms after a delivery that found its output drawn answered \(String(describing: next))")
    }

    /// A delivery that coalesces only peeks at the tracker. Entries past the timeout stay for the
    /// next frame's own check to clear, and no notice logs.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aDeliveryThatCoalescesLeavesTheTrackerAlone() async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)
        // A live resize, so the delivery coalesces before the GPU rules.
        view.viewWillStartLiveResize()
        defer { view.viewDidEndLiveResize() }
        let tracker = view.drawableTracker
        // Two drawables with no report since, acquired more than `presentReportTimeout` ago.
        _ = tracker.add(acquiredAt: .seconds(98))
        _ = tracker.add(acquiredAt: .seconds(98.5))

        try await feedAndDeliver("a", to: fixture)
        let decision = view.lastLeadingEdgeDecision
        let liveResize: LeadingEdgePolicy.Decision? = .coalesce(.liveResize)
        try #require(decision == liveResize, "a feed during a live resize answered \(String(describing: decision))")
        let afterDelivery = [tracker.entryCount, tracker.timeoutClears, tracker.lostReportNotices]
        #expect(afterDelivery == [2, 0, 0], "after a coalesced delivery, [entries, clears, notices] is \(afterDelivery)")
    }

    /// A delivery queued before the view detaches never reaches it, even when the view attaches
    /// again before the delivery runs: its hint, here a finished 2 KB hold, is from before the
    /// attach. The test waits for the hop of the relay the view detached from, so it does not
    /// depend on the order hops run in.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aDeliveryQueuedBeforeADetachDoesNotReachTheViewAttachedAgain() async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)
        let before = view.renderSignalDeliveries
        let relayBeforeTheDetach = try #require(view.relay, "the attached view has no relay")

        // The feed queues its delivery; the view detaches and attaches again in the same turn.
        fixture.terminal.feed(text: "\u{1b}[?2026h" + String(repeating: "x", count: 2048) + "\u{1b}[?2026l")
        view.isHidden = true
        view.isHidden = false
        let attached = view.surface.isAttached
        try #require(attached, "showing the view again left its surface detached")

        let queued = relayBeforeTheDetach.hasPendingHint
        try #require(queued, "the feed's delivery ran before the view detached")

        try await waitFor("the hop queued before the detach to run") {
            await MainActor.run { !relayBeforeTheDetach.hasPendingHint }
        }
        let delivered = view.renderSignalDeliveries - before
        #expect(delivered == 0, "a delivery queued before the detach reached the view \(delivered) times")
    }

    /// A tick's `now` is the vsync it fired for, which can be earlier than the `now` of a frame a
    /// delivery drew just before the tick ran. The tick's output frame keeps the later stamp.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aTickForAnEarlierVsyncDoesNotMoveTheStampBack() async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100.005))
        try placeWithAFirstFrame(fixture, in: window, now: now)
        try await feedAndDeliver("a", to: fixture)
        let drawn = view.lastOutputFrameAt
        let deliveryStamp: Duration? = .seconds(100.005)
        try #require(drawn == deliveryStamp, "the delivery's frame stamped \(String(describing: drawn))")

        // Output the delivery leaves to the tick, and the tick for the vsync at 100 s drawing it.
        try await feedAndDeliver("b", to: fixture)
        try await waitForAFreeRingSlot(view)
        let beforeTick = view.framesCommitted
        view.renderTick(now: .seconds(100))
        let tickFrames = view.framesCommitted - beforeTick
        try #require(tickFrames == 1, "the tick did not draw the output left to it")
        let afterTick = view.lastOutputFrameAt
        #expect(afterTick == deliveryStamp, "a tick for an earlier vsync moved the stamp to \(String(describing: afterTick))")
    }

    /// At either GPU limit the delivery builds nothing and asks for no drawable. Once the limit
    /// clears, the next feed draws at once.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice), arguments: GPULimit.allCases)
    func theLeadingEdgeDrawsNothingAtAGPULimit(_ limit: GPULimit) async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)

        let tracker = view.drawableTracker
        var held: HeldRingSlots?
        defer { held?.releaseAll() }
        var newer: DrawableTracker.DrawableID?
        let expected: LeadingEdgePolicy.Decision?
        switch limit {
        case .ringFull:
            let slots = HeldRingSlots(on: view.surface)
            held = slots
            try #require(slots.held == FrameRing.depth, "only \(slots.held) of the ring's slots could be taken")
            expected = .coalesce(.ringFull)
        case .drawablesBehind:
            // Younger than `presentReportTimeout`, so the tracker clears neither.
            _ = tracker.add(acquiredAt: .seconds(99.75))
            newer = tracker.add(acquiredAt: .seconds(99.875))
            expected = .coalesce(.drawablesBehind)
        }
        let built = view.framesBuilt
        let acquired = tracker.acquiredCount

        try await feedAndDeliver("a", to: fixture)
        let decision = view.lastLeadingEdgeDecision
        #expect(decision == expected, "a feed at the \(limit) limit answered \(String(describing: decision))")
        let builtAtLimit = view.framesBuilt - built
        #expect(builtAtLimit == 0, "the delivery built \(builtAtLimit) frames at the \(limit) limit")
        let acquiredAtLimit = tracker.acquiredCount - acquired
        #expect(acquiredAtLimit == 0, "the delivery took \(acquiredAtLimit) drawables at the \(limit) limit")
        let ticking = view.frameDriver.demand.needsUpdate
        #expect(ticking, "the delivery at the \(limit) limit asked the link for no frame")

        switch limit {
        case .ringFull:
            held?.releaseOne()
        case .drawablesBehind:
            if let newer { tracker.reportPresented(newer, presentedTime: 100) }
        }
        try await feedAndDeliver("b", to: fixture)
        let afterClear = view.lastLeadingEdgeDecision
        let drawNow: LeadingEdgePolicy.Decision? = .drawNow
        #expect(afterClear == drawNow, "a feed once the \(limit) limit cleared answered \(String(describing: afterClear))")
        let committed = view.framesCommitted
        #expect(committed == 2, "once the \(limit) limit cleared the view committed \(committed) frames in all, not 2")
    }

    /// A key press's blink reset can draw a cursor-only frame just before the echo arrives. That
    /// frame consumed no output, so it stamps nothing, and the echo still draws at once.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func aBlinkResetsCursorFrameDoesNotHoldBackTheEcho() async throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)
        try await feedAndDeliver("$ ", to: fixture)
        let prompt = view.lastOutputFrameAt
        let promptStamp: Duration? = .seconds(100)
        try #require(prompt == promptStamp, "the prompt was not drawn as an output frame: \(String(describing: prompt))")

        // The cursor in its blink's off phase, drawn.
        now.value = .seconds(101)
        view.surface.cursorBlinkOn = false
        try await waitForAFreeRingSlot(view)
        view.renderTick()
        // The key press: the reset turns the cursor back on, and a tick draws that frame.
        now.value = .seconds(101.5)
        view.resetCursorBlink()
        try await waitForAFreeRingSlot(view)
        let beforeCursorFrame = view.framesCommitted
        view.renderTick()
        let cursorFrames = view.framesCommitted - beforeCursorFrame
        try #require(cursorFrames == 1, "the blink reset's cursor frame was not drawn")
        let afterCursorFrame = view.lastOutputFrameAt
        #expect(afterCursorFrame == promptStamp, "a cursor-only frame stamped an output frame at \(String(describing: afterCursorFrame))")

        // The echo, 2 ms after the cursor frame.
        now.value = .seconds(101.502)
        try await waitForAFreeRingSlot(view)
        try await feedAndDeliver("l", to: fixture)
        let decision = view.lastLeadingEdgeDecision
        let drawNow: LeadingEdgePolicy.Decision? = .drawNow
        #expect(decision == drawNow, "the echo 2 ms after a cursor-only frame answered \(String(describing: decision))")
        let committed = view.framesCommitted
        #expect(committed == beforeCursorFrame + 2, "the echo was not drawn at once")
    }

    /// The fixture's link never ticks, so its interval is the screen's, or the fallback with no
    /// screen. A tick of the running link sets the link's own, and the pause that ends its run
    /// forgets it.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func theRefreshIntervalIsTheRunningLinksElseTheScreensElseTheFallback() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
        }
        let now = ManualNow(.seconds(100))
        try placeWithAFirstFrame(fixture, in: window, now: now)
        // The fixture's window is offscreen, so it has no screen and the fallback stands in.
        // Should AppKit give it one, the screen's own interval does.
        let paused: Duration
        if let screen = window.screen {
            paused = .seconds(screen.minimumRefreshInterval)
        } else {
            paused = LeadingEdgePolicy.fallbackRefreshInterval
        }
        let atRest = view.refreshInterval
        #expect(atRest == paused, "the paused link's interval is \(atRest), not the screen's or the fallback \(paused)")

        // A drag keeps the link running through the tick.
        view.isDragging = true
        try #require(!view.frameDriver.isPaused, "a drag did not resume the link")
        let tickInterval = Duration.seconds(1) / 120
        view.displayLinkFired(timestamp: 200, targetTimestamp: 200 + 1.0 / 120)
        let running = view.refreshInterval
        // The tick's interval went through a `CFTimeInterval`, so allow for rounding.
        let gap = running > tickInterval ? running - tickInterval : tickInterval - running
        let tolerance: Duration = .microseconds(1)
        #expect(gap < tolerance, "the running link's interval is \(running), not \(tickInterval)")

        view.isDragging = false
        try #require(view.frameDriver.isPaused, "the link kept running with nothing to draw")
        let afterPause = view.refreshInterval
        #expect(afterPause == paused, "after the pause the interval is \(afterPause), not \(paused)")
    }
}
