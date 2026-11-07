// Adapted from tkzmux c961533 Sources/TkzTerminalView/TerminalMetalView.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// TerminalMetalView — the NSView that a terminal session is drawn into (M1.6).
//
// Responsibilities, and nothing else:
//
//   * own the `CAMetalLayer` and keep its scale / drawable size correct,
//   * own the single `TerminalSurface` and swap sessions through `show(_:)`,
//   * drive frames from a `DisplayLinkDriver` that is paused unless there is work,
//   * coalesce resizes into one grid resize per tick and present transactionally while live,
//   * rebuild the world when the backing scale changes,
//   * forward input events to an `inputDelegate` — it encodes nothing itself.
//
// ## Keyboard and mouse are deliberately *not* here
//
// Every responder method below does exactly one thing: hand the `NSEvent` to `inputDelegate` and
// fall back to `super` when the delegate did not consume it. The encoders those delegates call
// (`KeyEncoder`, `MouseEncoder`, `SelectionController`) all live in `TkzTerminalCore`, so the whole
// input path unit-tests without AppKit. `NSTextInputClient` conformance is *not* declared here on
// purpose: `TerminalMetalView+TextInput` adds it in an extension in its own file.

import AppKit
import Foundation
import Metal
import QuartzCore
import Synchronization
import os

// MARK: - Input seam

/// The seam the keyboard/IME and mouse/selection controllers plug into.
///
/// One method for every event, because the encoders need the raw `NSEvent` (modifier side bits,
/// `characters(byApplyingModifiers:)`, real pointer pixels). Returning `true` means "consumed"; the
/// view then does *not* call `super`.
@MainActor
public protocol TerminalViewInputDelegate: AnyObject {
    /// A key, modifier, mouse or scroll event arrived. Return `true` if it was handled.
    func terminalView(_ view: TerminalMetalView, handle event: NSEvent) -> Bool
    /// Focus changed. This is the DEC 1004 (focus reporting) hook: Claude Code sets mode 1004, so
    /// `TerminalInputController` answers this with `ghostty_focus_encode` when the mode is on.
    func terminalView(_ view: TerminalMetalView, didChangeFocus isFocused: Bool)
}

extension TerminalViewInputDelegate {
    public func terminalView(_ view: TerminalMetalView, didChangeFocus isFocused: Bool) {}
}

// MARK: - Render signal relay

/// Bridges a session's `renderSignal` (called on the session's IO queue, `@Sendable`) to a single
/// coalesced main-thread wake-up.
///
/// A busy `cat` signals thousands of times a second; without the pending flag that would be
/// thousands of main-queue hops per frame. With it, at most one hop is in flight at a time.
///
/// The relay is a separate object rather than a closure over the view because `show(_:)` needs to
/// be able to *orphan* it: a session is only ever signalled while it is the visible one.
public final class RenderSignalRelay: Sendable {
    private let pending = Mutex(false)
    private let count = Mutex(0)
    private let deliver: @MainActor @Sendable () -> Void

    init(deliver: @escaping @MainActor @Sendable () -> Void) {
        self.deliver = deliver
    }

    /// Called from the session's IO queue.
    public func signal() {
        count.withLock { $0 += 1 }
        let alreadyPending = pending.withLock { value -> Bool in
            if value { return true }
            value = true
            return false
        }
        guard !alreadyPending else { return }
        Task { @MainActor in
            self.pending.withLock { $0 = false }
            self.deliver()
        }
    }

    /// How many times the session signalled this relay. Tests only.
    public var signalCount: Int { count.withLock { $0 } }
}

// MARK: - TerminalMetalView

public final class TerminalMetalView: NSView {
    // MARK: Collaborators

    public let renderContext: TerminalRenderContext
    /// The one surface this view draws. Only the *visible* session is attached to it.
    public let surface = TerminalSurface()
    public let frameDriver = DisplayLinkDriver()
    /// The input and mouse controllers install themselves here. Weak: the controller owns them.
    public weak var inputDelegate: TerminalViewInputDelegate?

    /// Called after the grid size changed, so the owner can push it to the pty
    /// (`Pty.resize`). The view never owns a pty.
    public var onGridResize: ((TerminalSize) -> Void)?

    /// The visible session, or nil.
    public private(set) var session: TerminalSession?

    // MARK: Diagnostics (read by the dev window and the tests)

    public private(set) var gridResizeCount = 0
    public private(set) var framesRendered = 0
    public private(set) var currentGridSize = TerminalSize(rows: 24, cols: 80)

    // MARK: Private state

    private var relay: RenderSignalRelay?
    private var pendingGridResize = false
    private var isTerminalFocused = false
    private var blinkTimer: (any DispatchSourceTimer)?
    private var observedWindow: NSWindow?
    private let logger = Logger(subsystem: "ghosttyview", category: "terminalview")

    /// macOS default cursor blink half-period.
    private static let blinkInterval: Double = 0.53

    // MARK: - Init

    public init(renderContext: TerminalRenderContext, frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600)) {
        self.renderContext = renderContext
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        renderContext.register(surface)
        updateDrawableSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TerminalMetalView is created in code") }

    deinit {
        MainActor.assumeIsolated {
            blinkTimer?.cancel()
            NotificationCenter.default.removeObserver(self)
            renderContext.unregister(surface)
        }
    }

    // MARK: - Layer

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderContext.device
        // Must match the renderer's pipeline attachment format exactly.
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        // 3, not 2: with `presentsWithTransaction` during a live resize the present is synchronous
        // on the main thread, and a pool of 2 leaves `nextDrawable()` blocking (up to a second)
        // whenever both a drag frame and a display-link frame are in flight. Apple's guidance for
        // the transactional path is 3.
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        layer.isOpaque = true
        layer.contentsScale = window?.backingScaleFactor ?? renderContext.scale
        layer.needsDisplayOnBoundsChange = false
        return layer
    }

    public var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Session attach / detach

    /// Makes `session` the visible one: the previous surface state is freed and the new session is
    /// attached (whose first update is always `DIRTY_FULL`). `nil` shows nothing.
    ///
    /// ## Why a background session cannot wake the display link
    ///
    /// The render signal is not a flag that is *checked*; it is a closure that only the visible
    /// session **has**. `show` clears the outgoing session's `renderSignal` before installing one on
    /// the incoming session, so a background session that produces megabytes of output calls
    /// nothing, hops to no queue, and cannot un-pause anything. That is structural, not a policy.
    public func show(_ session: TerminalSession?) {
        if let previous = self.session {
            previous.setRenderSignal(nil)
        }
        relay = nil
        surface.detach()
        self.session = session

        guard let session else {
            stopBlinkTimer()
            frameDriver.update {
                $0.hasVisibleSession = false
                $0.needsUpdate = false
            }
            return
        }

        do {
            try surface.attach(session)
        } catch {
            logger.error("attach failed: \(String(describing: error), privacy: .public)")
            self.session = nil
            frameDriver.update { $0.hasVisibleSession = false }
            return
        }

        surface.isFocused = isTerminalFocused
        surface.cursorBlinkOn = true
        surface.isCursorSuppressed = false

        let relay = RenderSignalRelay { [weak self] in self?.frameDriver.requestFrame() }
        self.relay = relay
        session.setRenderSignal { [weak relay] in relay?.signal() }

        frameDriver.update {
            $0.hasVisibleSession = true
            $0.needsUpdate = true
        }
        applyGridSize(force: true)
        startBlinkTimerIfNeeded()
    }

    /// Hides the visible session's cursor and parks the blink timer.
    ///
    /// The owner calls this when the shell behind the visible session has exited: the last screen
    /// stays (the row is resumable), but nothing should look like it is waiting for a keystroke.
    /// Reset by the next `show(_:)`, so it cannot leak onto a live session.
    public func setCursorSuppressed(_ suppressed: Bool) {
        guard surface.isCursorSuppressed != suppressed else { return }
        surface.isCursorSuppressed = suppressed
        if suppressed {
            stopBlinkTimer()
        } else {
            startBlinkTimerIfNeeded()
        }
        frameDriver.update { $0.needsUpdate = true }
    }

    /// The relay currently wired to the visible session. Tests hold on to it across a `show(_:)`
    /// to prove that a backgrounded session no longer signals.
    var renderSignalRelay: RenderSignalRelay? { relay }

    // MARK: - Geometry

    /// The backing scale in force, whether or not the view has a window yet.
    public var backingScale: CGFloat {
        window?.backingScaleFactor ?? metalLayer?.contentsScale ?? renderContext.scale
    }

    /// Cell geometry in device pixels.
    public var cellMetrics: CellMetrics { renderContext.metrics }

    /// Where the grid sits inside the drawable, in device pixels (top-left origin, no padding).
    /// `MouseController` uses this to turn pointer pixels into cells — it must pass *real* pointer pixels, so
    /// the view deliberately exposes geometry rather than a cell lookup.
    public var gridGeometry: GridGeometry {
        let size = drawablePixelSize()
        return GridGeometry(metrics: renderContext.metrics,
                            viewportWidth: size.width, viewportHeight: size.height)
    }

    /// A mouse event's location in **device pixels**, top-left origin (the view is flipped).
    public func devicePixels(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let scale = backingScale
        return CGPoint(x: point.x * scale, y: point.y * scale)
    }

    private func drawablePixelSize() -> (width: Int, height: Int) {
        let scale = backingScale
        return (max(1, Int((bounds.width * scale).rounded(.down))),
                max(1, Int((bounds.height * scale).rounded(.down))))
    }

    private func updateDrawableSize() {
        guard let layer = metalLayer else { return }
        let size = drawablePixelSize()
        let newSize = CGSize(width: size.width, height: size.height)
        guard layer.drawableSize != newSize else { return }
        layer.drawableSize = newSize
        // A sub-cell resize changes the drawable without changing the grid, so nothing would mark
        // the surface dirty and the renderer would skip — leaving Core Animation to stretch the
        // previous texture over the new bounds (shimmer during a drag, a stale frame after it).
        // The viewport is part of the frame, so a drawable-size change is a reason to redraw.
        surface.markNeedsDisplay()
    }

    /// The grid the current bounds and cell metrics imply. Leftover pixels at the right/bottom edge
    /// are simply cleared to the background colour (the renderer pins the grid top-left).
    public func gridSizeForBounds() -> TerminalSize {
        let metrics = renderContext.metrics
        let pixels = drawablePixelSize()
        let cols = max(1, pixels.width / max(1, metrics.width))
        let rows = max(1, pixels.height / max(1, metrics.height))
        return TerminalSize(
            rows: UInt16(min(rows, Int(UInt16.max))),
            cols: UInt16(min(cols, Int(UInt16.max))),
            cellWidthPx: UInt16(min(metrics.width, Int(UInt16.max))),
            cellHeightPx: UInt16(min(metrics.height, Int(UInt16.max))))
    }

    // MARK: - Resize


    /// AppKit calls this many times during a live resize and several times during a single layout
    /// pass. Outside a live resize the new size is only *recorded*; the display-link tick applies it
    /// once, so N calls in one tick produce exactly one `ghostty_terminal_resize` + `pty.resize`.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        pendingGridResize = true
        if inLiveResize {
            // A live resize must present inside the Core Animation transaction that resized the
            // layer, and every layout pass owes it a presented frame.
            applyPendingGridResize()
            surface.markNeedsDisplay()
            renderNow(transactional: true)
        } else {
            frameDriver.requestFrame()
        }
    }

    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        metalLayer?.presentsWithTransaction = true
        frameDriver.update { $0.isLiveResizing = true }
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        metalLayer?.presentsWithTransaction = false
        frameDriver.update { $0.isLiveResizing = false }
        applyPendingGridResize()
        frameDriver.requestFrame()
    }

    /// Applies the coalesced grid size, if one is pending.
    func applyPendingGridResize() {
        guard pendingGridResize else { return }
        pendingGridResize = false
        applyGridSize(force: false)
    }

    private func applyGridSize(force: Bool) {
        let size = gridSizeForBounds()
        guard force || size != currentGridSize else { return }
        currentGridSize = size
        gridResizeCount += 1
        if let session {
            do {
                try session.resize(
                    cols: size.cols, rows: size.rows,
                    cellWidthPx: UInt32(size.cellWidthPx), cellHeightPx: UInt32(size.cellHeightPx))
            } catch {
                logger.error("terminal resize failed: \(String(describing: error), privacy: .public)")
            }
        }
        onGridResize?(size)
        frameDriver.requestFrame()
    }

    // MARK: - Backing scale

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale(window?.backingScaleFactor ?? renderContext.scale)
    }

    /// Rebuilds the font set / atlas / renderer at `scale`, re-attaches every surface, and resizes
    /// the grid — new metrics mean a different number of cells fits in the same bounds.
    ///
    /// Split out of `viewDidChangeBackingProperties` so it can be driven without a window.
    func applyBackingScale(_ scale: CGFloat) {
        metalLayer?.contentsScale = scale
        updateDrawableSize()
        var rebuilt = false
        do {
            rebuilt = try renderContext.setScale(scale)
        } catch {
            logger.error("renderer rebuild failed: \(String(describing: error), privacy: .public)")
        }
        if rebuilt {
            metalLayer?.device = renderContext.device
        }
        applyGridSize(force: rebuilt)
        frameDriver.requestFrame()
    }

    // MARK: - Window / display link

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: nil, object: observedWindow)
            NotificationCenter.default.removeObserver(
                self, name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        observedWindow = window

        guard let window else {
            frameDriver.adopt(nil)
            stopBlinkTimer()
            frameDriver.update { $0.isOccluded = true }
            return
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowOcclusionChanged(_:)),
                           name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.addObserver(self, selector: #selector(windowBecameKey(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowResignedKey(_:)),
                           name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(applicationBecameActive(_:)),
                           name: NSApplication.didBecomeActiveNotification, object: nil)

        // `NSView.displayLink(target:selector:)` (macOS 14+) is bound to the screen the view is on
        // and stops itself when the view leaves the screen — the reason we do not use CVDisplayLink.
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        frameDriver.adopt(link)

        refreshOcclusion()
        applyBackingScale(window.backingScaleFactor)
        setFocused(window.isKeyWindow && window.firstResponder === self)
        startBlinkTimerIfNeeded()
        frameDriver.requestFrame()
    }

    /// Recomputes occlusion from the window. Called from the occlusion notification, and again
    /// whenever the window becomes key or the app is activated — a missed notification would
    /// otherwise leave the link parked forever, which is the one failure mode of this optimization.
    func refreshOcclusion() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        frameDriver.update { $0.isOccluded = !visible }
        if visible { frameDriver.requestFrame() }
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        refreshOcclusion()
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        refreshOcclusion()
        setFocused(window?.firstResponder === self)
    }

    @objc private func applicationBecameActive(_ notification: Notification) {
        refreshOcclusion()
    }

    @objc private func windowResignedKey(_ notification: Notification) {
        setFocused(false)
    }

    // MARK: - The frame

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        Stats.shared.noteTick(view: ObjectIdentifier(self), time: link.timestamp, duration: link.duration,
                              running: frameDriver.demand.needsUpdate)
        renderTick()
    }

    /// One display-link tick. Also the tests' entry point.
    func renderTick() {
        applyPendingGridResize()

        if let session {
            switch session.syncOutputDecision() {
            case .skipFrame:
                // DEC 2026 is held: hide the unsynchronized frame, but keep the link running so the
                // watchdog deadline is evaluated on the next tick.
                frameDriver.update { $0.hasSyncDeadline = true }
                return
            case .render, .forceOffAndRender:
                // `forceOffAndRender` already reset the mode inside `syncOutputDecision`.
                frameDriver.update { $0.hasSyncDeadline = false }
            }
        }

        renderNow(transactional: false)
    }

    /// Renders one frame.
    ///
    /// - Parameter transactional: unused now that `TerminalRenderer.render(surface:layer:)` reads
    ///   `layer.presentsWithTransaction` itself and does the `waitUntilScheduled()` + `present()`
    ///   handshake internally. Kept as a parameter because the live-resize call site documents
    ///   intent, and because presenting through `MTLCommandBuffer.present` during a transaction
    ///   would schedule the present outside the Core Animation transaction — the exact tearing this
    ///   path exists to avoid.
    func renderNow(transactional: Bool) {
        guard surface.isAttached, window != nil, let layer = metalLayer,
              layer.drawableSize.width >= 1, layer.drawableSize.height >= 1 else {
            frameDriver.update { $0.needsUpdate = surface.isAttached && surface.needsDisplay }
            return
        }
        do {
            // One path for both cases: the renderer honours `layer.presentsWithTransaction`, and
            // because it acquires the drawable *after* the skip check, a skipped frame still holds
            // no drawable even during a live resize.
            let outcome = try renderContext.renderer.render(surface: surface, layer: layer)
            if outcome.didEncode { framesRendered += 1 }
        } catch {
            logger.error("render failed: \(String(describing: error), privacy: .public)")
        }
        frameDriver.update { $0.needsUpdate = surface.needsDisplay }
    }

    // MARK: - Cursor blink

    /// The blink is a **timer**, not a display-link demand: it flips `surface.cursorBlinkOn` twice a
    /// second, which marks the surface dirty, which wakes the link for exactly one frame.
    private func startBlinkTimerIfNeeded() {
        stopBlinkTimer()
        guard surface.isAttached, window != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + TerminalMetalView.blinkInterval,
                       repeating: TerminalMetalView.blinkInterval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.surface.isAttached, self.isTerminalFocused,
                      self.surface.cursor.isBlinking, self.surface.cursor.isVisible else { return }
                self.surface.cursorBlinkOn.toggle()
                self.frameDriver.requestFrame()
            }
        }
        timer.resume()
        blinkTimer = timer
    }

    private func stopBlinkTimer() {
        blinkTimer?.cancel()
        blinkTimer = nil
    }

    /// Shows the cursor and restarts the blink phase. `TerminalInputController` calls this on every keypress so the
    /// cursor is solid while typing.
    public func resetCursorBlink() {
        surface.cursorBlinkOn = true
        startBlinkTimerIfNeeded()
        frameDriver.requestFrame()
    }

    // MARK: - Focus

    public var isTerminalFocusedForTesting: Bool { isTerminalFocused }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { setFocused(window?.isKeyWindow ?? true) }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { setFocused(false) }
        return ok
    }

    func setFocused(_ focused: Bool) {
        guard focused != isTerminalFocused else { return }
        isTerminalFocused = focused
        surface.isFocused = focused
        if focused { surface.cursorBlinkOn = true }
        startBlinkTimerIfNeeded()
        inputDelegate?.terminalView(self, didChangeFocus: focused)
        frameDriver.requestFrame()
    }

    // MARK: - Input forwarding (supply the delegate)

    private func forward(_ event: NSEvent) -> Bool {
        inputDelegate?.terminalView(self, handle: event) ?? false
    }

    /// Whether the pointer at `event` would land on this view — nothing hidden about it, and no
    /// sibling drawn over it at that point. `NSTrackingArea` does not check either, so a hover
    /// handler has to. Outside a window there is nothing to be covered by.
    public func isPointerTarget(_ event: NSEvent) -> Bool {
        guard !isHiddenOrHasHiddenAncestor else { return false }
        guard let window, let content = window.contentView else { return true }
        guard let hit = content.hitTest(event.locationInWindow) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    public override func keyDown(with event: NSEvent) {
        if !forward(event) { super.keyDown(with: event) }
    }
    public override func keyUp(with event: NSEvent) {
        if !forward(event) { super.keyUp(with: event) }
    }
    public override func flagsChanged(with event: NSEvent) {
        if !forward(event) { super.flagsChanged(with: event) }
    }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        forward(event) || super.performKeyEquivalent(with: event)
    }
    public override func mouseDown(with event: NSEvent) {
        // Click-to-focus. With one terminal in the window this was invisible — the view was made
        // first responder when the session was shown and nothing ever took it away. With several
        // panes it is the whole mechanism: `TerminalInputController.acceptsKeyDown` declines every
        // event whose view is not the first responder, so a pane that cannot take focus by being
        // clicked cannot be typed into at all.
        if let window, window.firstResponder !== self { window.makeFirstResponder(self) }
        if !forward(event) { super.mouseDown(with: event) }
    }
    public override func mouseUp(with event: NSEvent) {
        if !forward(event) { super.mouseUp(with: event) }
    }
    public override func mouseDragged(with event: NSEvent) {
        if !forward(event) { super.mouseDragged(with: event) }
    }
    public override func mouseMoved(with event: NSEvent) {
        if !forward(event) { super.mouseMoved(with: event) }
    }
    public override func rightMouseDown(with event: NSEvent) {
        if !forward(event) { super.rightMouseDown(with: event) }
    }
    public override func rightMouseUp(with event: NSEvent) {
        if !forward(event) { super.rightMouseUp(with: event) }
    }
    public override func rightMouseDragged(with event: NSEvent) {
        if !forward(event) { super.rightMouseDragged(with: event) }
    }
    public override func otherMouseDown(with event: NSEvent) {
        if !forward(event) { super.otherMouseDown(with: event) }
    }
    public override func otherMouseUp(with event: NSEvent) {
        if !forward(event) { super.otherMouseUp(with: event) }
    }
    public override func otherMouseDragged(with event: NSEvent) {
        if !forward(event) { super.otherMouseDragged(with: event) }
    }
    public override func scrollWheel(with event: NSEvent) {
        if !forward(event) { super.scrollWheel(with: event) }
    }

    /// `MouseController` sets this to `true` while a selection drag is running so the link keeps ticking for
    /// autoscroll even when the terminal itself is idle.
    public var isDragging: Bool {
        get { frameDriver.demand.isDragging }
        set { frameDriver.update { $0.isDragging = newValue } }
    }
}
