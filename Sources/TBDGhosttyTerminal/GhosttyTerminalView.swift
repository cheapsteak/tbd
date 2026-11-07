// Adapted from tkzmux c961533 Sources/TkzTerminalView/TerminalMetalView.swift, TkzTerminalView.swift and DisplayLinkDriver.swift (MIT, see LICENSE-tkzmux.txt).
// GhosttyTerminalView — the NSView one libghostty terminal is drawn into.
//
// Responsibilities, and nothing else:
//
//   * own the `CAMetalLayer` and keep its scale and drawable size correct,
//   * own the terminal's `TerminalSurface`, attached only while the view can be seen,
//   * drive frames from a display link that is paused unless there is work,
//   * coalesce resizes into one grid resize per pass and present transactionally while live,
//   * rebuild the glyph atlas when the backing scale or the font changes,
//   * hand input events to `TerminalInputController` and `MouseController`, which encode them.
//
// ## Hidden views cost nothing
//
// TBD keeps terminals for unselected tabs alive and fed, hidden inside one window. So a view
// builds frames only while it has a window, is not hidden (itself or through an ancestor), and its
// window is not occluded. A view that cannot be seen detaches its surface, which frees the render
// state and instance buffers, and takes its render signal off the terminal, so the IO thread's
// feeds wake nothing. Shown again, it re-attaches, and the first frame after an attach is always a
// full rebuild. `framesBuilt` counts the frames built, for the tests that hold this to account.
//
// ## Threading
//
// Everything here is main-thread. The terminal is fed on an IO thread; its render signal is the
// only thing that crosses back, through `RenderSignalRelay`, which coalesces any number of signals
// into at most one main-thread wake-up at a time.

import AppKit
import Foundation
import Metal
import QuartzCore
import Synchronization
import os

// MARK: - Small helpers

/// A weak reference that can cross into a `Task` or a `@Sendable` closure. Main-actor isolated,
/// so it is `Sendable` whatever it points at, and the object is only read on the main thread.
@MainActor
final class WeakRef<Object: AnyObject> {
    weak var object: Object?

    init(_ object: Object) {
        self.object = object
    }
}

/// Bridges a terminal's render signal (called on the feeding thread, `@Sendable`) to a single
/// coalesced main-thread wake-up.
///
/// A busy `cat` signals thousands of times a second; without the pending flag that would be
/// thousands of main-queue hops per frame. With it, at most one hop is in flight at a time.
final class RenderSignalRelay: Sendable {
    private let pending = Mutex(false)
    private let deliver: @MainActor @Sendable () -> Void

    init(deliver: @escaping @MainActor @Sendable () -> Void) {
        self.deliver = deliver
    }

    /// Called from the feeding thread.
    func signal() {
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
}

/// The display link's target. A link retains its target, so it targets this proxy, which holds the
/// view weakly: a view dropped while still in a window is freed rather than kept alive by its link.
@MainActor
final class DisplayLinkProxy: NSObject {
    weak var view: GhosttyTerminalView?

    init(_ view: GhosttyTerminalView) {
        self.view = view
    }

    @objc func fired(_ link: CADisplayLink) {
        view?.renderTick(now: .seconds(link.timestamp))
    }
}

// MARK: - Display link policy

/// Everything that can justify running the display link. A pure value.
///
/// Note what is *not* here: "the cursor is blinking". A blink is an **event** (the blink timer flips
/// `TerminalSurface.cursorBlinkOn`, which marks the surface dirty and sets `needsUpdate`), not a
/// state — modelling it as a state would hold the link at 120 Hz forever and idle CPU with it.
struct DisplayLinkDemand: Sendable, Hashable {
    /// The surface has unrendered changes (output, blink flip, focus change, selection…).
    var needsUpdate = false
    /// A mouse drag (selection or autoscroll) is in progress.
    var isDragging = false
    /// DEC 2026 (synchronized output) is held: frames are being skipped, but the watchdog deadline
    /// must still be evaluated every tick, so the link keeps running.
    var hasSyncDeadline = false
    /// A live resize is in progress. Frames go out transactionally from `setFrameSize`.
    var isLiveResizing = false
    /// The window is fully occluded, miniaturized, or there is no window. Nothing can be seen.
    var isOccluded = true
    /// The surface is attached: the view has a window and is not hidden.
    var hasVisibleSurface = false
}

/// The pause/resume decision, as a pure function of the demand.
enum DisplayLinkPolicy {
    static func shouldRun(_ demand: DisplayLinkDemand) -> Bool {
        // Occlusion and "nothing attached" veto everything: an occluded window cannot show a frame
        // and a detached surface renders nothing anyway.
        guard demand.hasVisibleSurface, !demand.isOccluded else { return false }
        // A live resize *pauses* the link rather than running it. During a drag `setFrameSize`
        // renders synchronously under `presentsWithTransaction`, so a ticking link is not just
        // redundant, it is harmful: both paths call `nextDrawable()`, the layer only has a few
        // drawables, and a synchronous present that finds the pool empty blocks for up to a second.
        guard !demand.isLiveResizing else { return false }
        return demand.needsUpdate || demand.isDragging || demand.hasSyncDeadline
    }
}

/// Owns a `CADisplayLink` and keeps it paused unless `DisplayLinkPolicy` says otherwise.
///
/// The link is created by the view (`NSView.displayLink(target:selector:)`, which stops itself when
/// the view leaves the screen) and handed over with `adopt(_:)`. A driver with no link still tracks
/// the demand, which is what lets the tests drive the same decision code the app runs.
@MainActor
final class DisplayLinkDriver {
    private(set) var demand = DisplayLinkDemand()
    /// The link's pause state. A driver with no link still tracks it.
    private(set) var isPaused = true
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0

    private var link: CADisplayLink?

    /// Never below 60 Hz, up to the 120 Hz a ProMotion display offers.
    static let frameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)

    /// Takes ownership of `link`, invalidating any previous one, and applies the policy. Pass nil
    /// when the view leaves its window.
    func adopt(_ link: CADisplayLink?) {
        if let existing = self.link, existing !== link { existing.invalidate() }
        self.link = link
        link?.preferredFrameRateRange = Self.frameRateRange
        link?.isPaused = isPaused
        apply()
    }

    /// Mutates the demand and applies the policy. The only way to change the demand.
    func update(_ mutate: (inout DisplayLinkDemand) -> Void) {
        var next = demand
        mutate(&next)
        guard next != demand else { return }
        demand = next
        apply()
    }

    /// "Something changed, draw a frame."
    func requestFrame() {
        update { $0.needsUpdate = true }
    }

    private func apply() {
        let run = DisplayLinkPolicy.shouldRun(demand)
        guard run == isPaused else { return }
        isPaused = !run
        if run { resumeCount += 1 } else { pauseCount += 1 }
        link?.isPaused = isPaused
        terminalEngineLog.debug("""
            display link \(self.isPaused ? "paused" : "resumed", privacy: .public) \
            (needsUpdate=\(self.demand.needsUpdate, privacy: .public) \
            drag=\(self.demand.isDragging, privacy: .public) \
            sync=\(self.demand.hasSyncDeadline, privacy: .public) \
            liveResize=\(self.demand.isLiveResizing, privacy: .public) \
            occluded=\(self.demand.isOccluded, privacy: .public) \
            surface=\(self.demand.hasVisibleSurface, privacy: .public))
            """)
    }
}

// MARK: - Render context

/// One font at one backing scale: the `FontSet`, `GlyphCache` and `TerminalRenderer` built from it.
///
/// Views with the same font and scale share one context, so they share one glyph atlas and one
/// compiled pipeline. A view whose scale or font changes takes another context and re-attaches its
/// surface: an attach always produces a full rebuild, so no row keeps an atlas position from the
/// old atlas. A context lives while a view holds it.
@MainActor
final class TerminalRenderContext {
    let renderer: TerminalRenderer
    let font: NSFont
    /// The backing scale the atlas was rasterized at.
    let scale: CGFloat

    var metrics: CellMetrics { renderer.glyphCache.metrics }
    var device: MTLDevice { renderer.device }

    private init(font: NSFont, scale: CGFloat, device: MTLDevice) throws(GhosttyError) {
        let fontSet = FontSet(font: font, scale: scale)
        do {
            renderer = try TerminalRenderer(device: device, glyphCache: GlyphCache(fontSet: fontSet, device: device))
        } catch let error as GhosttyError {
            throw error
        } catch {
            throw GhosttyError.renderInit(String(describing: error))
        }
        self.font = font
        self.scale = scale
    }

    private struct Key: Hashable {
        let fontName: String
        let pointSize: CGFloat
        let scale: CGFloat
    }

    private static var cache: [Key: WeakRef<TerminalRenderContext>] = [:]

    /// The context for `font` at `scale`, built on first use.
    static func shared(font: NSFont, scale: CGFloat, device: MTLDevice) throws(GhosttyError) -> TerminalRenderContext {
        let scale = max(1, scale)
        let key = Key(fontName: font.fontName, pointSize: font.pointSize, scale: scale)
        cache = cache.filter { $0.value.object != nil }
        if let existing = cache[key]?.object { return existing }
        let context = try TerminalRenderContext(font: font, scale: scale, device: device)
        cache[key] = WeakRef(context)
        return context
    }
}

// MARK: - GhosttyTerminalView

/// An `NSView` that draws one `GhosttyTerminal` with Metal and turns keyboard, mouse, paste and
/// IME input into the bytes the program behind the terminal should receive.
///
/// The view never writes to a pty: what the user types comes out on `onSend`, and the host sends
/// it on. It never owns the terminal either; the host feeds it and closes it.
@MainActor
public final class GhosttyTerminalView: NSView {
    // MARK: Public surface

    /// The terminal this view draws.
    public let terminal: GhosttyTerminal

    /// The appearance last applied. Not `appearance`: that is `NSView`'s light or dark appearance.
    public private(set) var terminalAppearance: GhosttyAppearance

    /// Bytes the user produced: keys, paste, focus reports and mouse reports. Main thread.
    public var onSend: (@MainActor ([UInt8]) -> Void)?

    /// The grid changed size. Called after the terminal itself has been resized.
    public var onSizeChanged: (@MainActor (Int, Int) -> Void)?

    /// A frame is about to be drawn: the terminal changed and the view is encoding it.
    public var onDrawStart: (@MainActor () -> Void)?

    /// A drawn frame reached the screen. From the drawable's presented handler, hopped to main.
    public var onFramePresented: (@MainActor () -> Void)?

    /// The user ⌘-clicked an OSC 8 link. The view opens nothing itself: a program controls this
    /// string entirely, so the host decides what it may open.
    public var onOpenLink: (@MainActor (String) -> Void)?

    /// The view gained or lost keyboard focus.
    public var onFocusChanged: (@MainActor (Bool) -> Void)?

    /// Whether Option acts as Meta (Option-b sends `ESC b`) rather than typing the layout's
    /// character (`∫`). Off is the macOS default, and the only setting under which dead keys work.
    public var optionAsMeta: Bool {
        get { inputController.optionAsAlt != .never }
        set { inputController.optionAsAlt = newValue ? .both : .never }
    }

    /// The grid size the view last gave the terminal. Before the view has a size, the terminal's.
    public var gridSize: (cols: Int, rows: Int) { (grid.cols, grid.rows) }

    /// One cell, in points.
    public var cellSize: CGSize {
        let metrics = renderContext.metrics
        return CGSize(width: CGFloat(metrics.width) / renderContext.scale,
                      height: CGFloat(metrics.height) / renderContext.scale)
    }

    /// How many frames this view has built from its terminal. A frame is built when the view can be
    /// seen and a display tick finds work: the terminal is read into the render state and, if it
    /// changed, encoded. A hidden or windowless view builds none. A test seam.
    public private(set) var framesBuilt = 0
    /// How many of the built frames were encoded and committed to the GPU. A built frame with
    /// nothing changed, or with no drawable to draw into, is not committed. A test seam.
    public private(set) var framesCommitted = 0

    // MARK: Collaborators

    let surface = TerminalSurface()
    let frameDriver = DisplayLinkDriver()
    let inputController = TerminalInputController()
    let mouseController: MouseController
    private(set) var renderContext: TerminalRenderContext

    /// Whether `window` counts as visible. A seam: a test window is never on screen, so the tests
    /// replace this to separate "hidden" from "occluded".
    var windowVisibility: @MainActor (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) }

    // MARK: Private state

    private struct GridSize: Equatable {
        var cols: Int
        var rows: Int
        /// The cell size the terminal was given, in device pixels. Zero until the view has a size.
        var cellWidthPx: UInt32 = 0
        var cellHeightPx: UInt32 = 0
    }

    private var grid: GridSize
    private var relay: RenderSignalRelay?
    /// The render signal this view installed, so it only ever clears its own.
    private var renderSignalToken: RenderSignalToken?
    /// True from a failed attach until one succeeds. Only the first failure of a run is logged:
    /// the attach is retried on every layout pass, and a surface that cannot attach would
    /// otherwise log on each one.
    private var attachFailing = false
    /// True from a frame whose render threw until one renders without throwing. Only the first
    /// failure of a run is logged, for the same reason as `attachFailing`.
    private var renderFailing = false
    private var pendingGridResize = false
    private var isTerminalFocused = false
    private var blinkTask: Task<Void, Never>?
    private weak var observedWindow: NSWindow?
    private let clock: any Clock<Duration>
    private lazy var selfRef = WeakRef(self)

    /// macOS's cursor blink half-period.
    static let blinkInterval: Duration = .milliseconds(530)

    // MARK: - Init

    /// - Throws: `.metalUnavailable` without a Metal device, `.renderInit` when the shaders or the
    ///   pipelines cannot be built. The caller falls back to another engine for either.
    public init(
        terminal: GhosttyTerminal,
        appearance: GhosttyAppearance,
        clock: any Clock<Duration> = ContinuousClock()
    ) throws(GhosttyError) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw .metalUnavailable }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        renderContext = try TerminalRenderContext.shared(font: appearance.font, scale: scale, device: device)
        self.terminal = terminal
        terminalAppearance = appearance
        self.clock = clock
        mouseController = MouseController(clock: clock)
        let size = terminal.withLocked { (cols: $0.cols, rows: $0.rows) }
        grid = GridSize(cols: max(1, size.cols), rows: max(1, size.rows))
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        inputController.view = self
        mouseController.attach(to: self)
        terminal.apply(appearance)
        updateDrawableSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("GhosttyTerminalView is created in code") }

    deinit {
        MainActor.assumeIsolated {
            blinkTask?.cancel()
            frameDriver.adopt(nil)
            NotificationCenter.default.removeObserver(self)
            if let renderSignalToken { terminal.clearRenderSignal(renderSignalToken) }
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
        // whenever both a drag frame and a display-link frame are in flight.
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        layer.isOpaque = true
        layer.contentsScale = window?.backingScaleFactor ?? renderContext.scale
        layer.needsDisplayOnBoundsChange = false
        return layer
    }

    var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Appearance

    /// Applies new colours, cursor and font. What is on screen stays; the terminal's default
    /// colours change under any a program set, and a new font rebuilds the glyph atlas and
    /// re-fits the grid.
    public func apply(_ appearance: GhosttyAppearance) {
        let fontChanged = appearance.font != terminalAppearance.font
        terminalAppearance = appearance
        terminal.apply(appearance)
        if fontChanged { useRenderContext(font: appearance.font, scale: renderContext.scale) }
        surface.markNeedsDisplay()
        startBlinkIfNeeded()
        requestFrame()
    }

    /// Switches to the context for `font` at `scale` and re-attaches the surface, so every row is
    /// rebuilt against the new atlas. Keeps the current context if the new one cannot be built.
    private func useRenderContext(font: NSFont, scale: CGFloat) {
        guard font != renderContext.font || max(1, scale) != renderContext.scale else { return }
        let next: TerminalRenderContext
        do {
            next = try TerminalRenderContext.shared(font: font, scale: scale, device: renderContext.device)
        } catch {
            terminalEngineLog.error("rebuilding the renderer failed: \(String(describing: error), privacy: .public)")
            return
        }
        renderContext = next
        metalLayer?.device = next.device
        if surface.isAttached {
            do {
                try surface.attach(terminal)
            } catch {
                noteAttachFailure(error, "re-attaching the surface failed")
                // The failed attach left the surface detached. Detach the view's half too, so
                // the next layout pass or backing change sees a detached view and retries.
                detachSurface()
            }
        }
        pendingGridResize = true
        applyPendingGridResize()
        mouseController.syncGeometry()
    }

    // MARK: - Visibility and attachment

    /// True while the view can be seen and its terminal is open: in a window, not hidden, and the
    /// window not occluded.
    ///
    /// A closed terminal never draws again, and the layer keeps the last frame it presented. Its
    /// render state still holds that frame's rows, but their atlas positions point into a glyph
    /// atlas shared with every view in the same font, which another view can clear. A new frame
    /// would draw from whatever was packed there since.
    var canBuildFrames: Bool {
        surface.isAttached && window != nil && !isHiddenOrHasHiddenAncestor && !frameDriver.demand.isOccluded
            && !terminal.isClosed
    }

    /// Attaches the surface while the view has a window and is not hidden, and detaches it
    /// otherwise. Detaching frees the render state and takes the render signal off the terminal,
    /// so a hidden view costs only the terminal itself.
    ///
    /// Also called from `layout()` and `viewDidChangeBackingProperties()`, which is what retries
    /// an attach that failed. Nothing else retries it, so a surface that cannot attach costs one
    /// attempt per layout pass and never a loop.
    private func updateAttachment() {
        if window != nil, !isHiddenOrHasHiddenAncestor {
            guard !surface.isAttached else { return }
            attachSurface()
        } else {
            detachSurface()
        }
    }

    private func attachSurface() {
        do {
            try surface.attach(terminal)
        } catch {
            noteAttachFailure(error, "attaching the surface failed")
            return
        }
        if attachFailing {
            terminalEngineLog.notice("attaching the surface succeeded after failing")
            attachFailing = false
        }
        surface.isFocused = isTerminalFocused
        surface.cursorBlinkOn = true
        let target = selfRef
        let relay = RenderSignalRelay { target.object?.renderSignalled() }
        self.relay = relay
        renderSignalToken = terminal.setRenderSignal { [weak relay] in relay?.signal() }
        // While detached the view took no frames, so the watchdog's record of when mode 2026
        // was first seen is stale. Kept, it would force off a mode the program set just now.
        terminal.resetSyncOutputWatchdog()
        frameDriver.update {
            $0.hasVisibleSurface = true
            $0.needsUpdate = true
        }
        applyPendingGridResize()
        startBlinkIfNeeded()
    }

    /// Detaches the surface and the view's half of the attachment. Also run when the surface is
    /// already detached but the view's half is not, as after a failed re-attach.
    private func detachSurface() {
        guard surface.isAttached || renderSignalToken != nil else { return }
        if let renderSignalToken { terminal.clearRenderSignal(renderSignalToken) }
        renderSignalToken = nil
        relay = nil
        // Before the detach, which leaves a clean surface: stopping the blink marks it dirty.
        stopBlink()
        surface.detach()
        frameDriver.update {
            $0.hasVisibleSurface = false
            $0.needsUpdate = false
        }
    }

    /// Logs an attach failure, once per run of failures.
    private func noteAttachFailure(_ error: any Error, _ what: StaticString) {
        if !attachFailing {
            terminalEngineLog.error(
                "\(String(describing: what), privacy: .public): \(String(describing: error), privacy: .public)")
        }
        attachFailing = true
    }

    /// `viewDidHide` and `viewDidUnhide` cover an ancestor being hidden; this covers the view's own
    /// flag directly, so attachment never depends on AppKit sending those for a windowless view.
    /// `updateAttachment` is idempotent, so being told twice costs nothing.
    public override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            updateAttachment()
            if !isHidden { requestFrame() }
        }
    }

    public override func viewDidHide() {
        super.viewDidHide()
        updateAttachment()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAttachment()
        requestFrame()
    }

    /// Hides the cursor whatever the terminal's modes say, for a terminal whose program has exited.
    func setCursorSuppressed(_ suppressed: Bool) {
        guard surface.isCursorSuppressed != suppressed else { return }
        surface.isCursorSuppressed = suppressed
        if suppressed { stopBlink() } else { startBlinkIfNeeded() }
        requestFrame()
    }

    /// Asks for a frame on the next display tick.
    func requestFrame() {
        frameDriver.requestFrame()
    }

    /// The terminal's render signal, on the main thread. `close()` signals one last time, and the
    /// view stops its cursor blink then and asks for no frame, so nothing keeps waking a view that
    /// will never draw again.
    private func renderSignalled() {
        guard !terminal.isClosed else {
            stopBlink()
            return
        }
        frameDriver.requestFrame()
    }

    /// Sends user input on `onSend`.
    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        onSend?(bytes)
    }

    // MARK: - Geometry

    /// The backing scale in force, whether or not the view has a window yet.
    var backingScale: CGFloat {
        window?.backingScaleFactor ?? renderContext.scale
    }

    /// Where the grid sits inside the drawable, in device pixels (top-left origin, no padding).
    var gridGeometry: GridGeometry {
        let size = drawablePixelSize()
        return GridGeometry(metrics: renderContext.metrics, viewportWidth: size.width, viewportHeight: size.height)
    }

    /// A mouse event's location in **device pixels**, top-left origin (the view is flipped).
    func devicePixels(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let scale = backingScale
        return CGPoint(x: point.x * scale, y: point.y * scale)
    }

    /// The cell under `point`, a location in the window's coordinates, or nil outside the grid.
    public func gridPosition(atWindowLocation point: CGPoint) -> (col: Int, row: Int)? {
        let local = convert(point, from: nil)
        let metrics = renderContext.metrics
        let x = local.x * renderContext.scale
        let y = local.y * renderContext.scale
        guard x >= 0, y >= 0, x.isFinite, y.isFinite else { return nil }
        let col = Int(x) / max(1, metrics.width)
        let row = Int(y) / max(1, metrics.height)
        guard col < grid.cols, row < grid.rows else { return nil }
        return (col, row)
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
        // previous texture over the new bounds. The viewport is part of the frame, so a
        // drawable-size change is a reason to redraw.
        surface.markNeedsDisplay()
    }

    /// The grid the current bounds and cell metrics imply. Leftover pixels at the right and bottom
    /// edges are cleared to the background colour (the renderer pins the grid top-left).
    private func gridSizeForBounds() -> GridSize {
        let metrics = renderContext.metrics
        let pixels = drawablePixelSize()
        let cols = max(1, pixels.width / max(1, metrics.width))
        let rows = max(1, pixels.height / max(1, metrics.height))
        return GridSize(
            cols: min(cols, Int(UInt16.max)), rows: min(rows, Int(UInt16.max)),
            cellWidthPx: UInt32(metrics.width), cellHeightPx: UInt32(metrics.height))
    }

    // MARK: - Resize

    /// AppKit calls this many times during a live resize and several times during a single layout
    /// pass. Outside a live resize the new size is only *recorded*; the next layout pass or display
    /// tick applies it once, so N calls produce one terminal resize and one `onSizeChanged`.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        pendingGridResize = true
        if inLiveResize {
            // A live resize must present inside the Core Animation transaction that resized the
            // layer, and every layout pass owes it a presented frame.
            applyPendingGridResize()
            surface.markNeedsDisplay()
            renderNow()
        } else {
            needsLayout = true
            requestFrame()
        }
    }

    public override func layout() {
        super.layout()
        updateAttachment()
        applyPendingGridResize()
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
        requestFrame()
    }

    /// Applies the coalesced grid size, if one is pending.
    func applyPendingGridResize() {
        guard pendingGridResize else { return }
        pendingGridResize = false
        applyGridSize()
    }

    /// Resizes the terminal to the bounds, then tells the host. A view with no size yet leaves the
    /// terminal alone: fitting it to a zero frame would reflow its screen into one column.
    private func applyGridSize() {
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        let size = gridSizeForBounds()
        guard size != grid else { return }
        let gridChanged = size.cols != grid.cols || size.rows != grid.rows
        grid = size
        terminal.resize(cols: size.cols, rows: size.rows, cellWidthPx: size.cellWidthPx, cellHeightPx: size.cellHeightPx)
        mouseController.syncGeometry()
        if gridChanged { onSizeChanged?(size.cols, size.rows) }
        requestFrame()
    }

    // MARK: - Backing scale

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale(window?.backingScaleFactor ?? renderContext.scale)
        updateAttachment()
    }

    /// Rebuilds the atlas at `scale` when it changed, and re-fits the grid: new metrics mean a
    /// different number of cells fits in the same bounds.
    private func applyBackingScale(_ scale: CGFloat) {
        metalLayer?.contentsScale = scale
        updateDrawableSize()
        useRenderContext(font: terminalAppearance.font, scale: scale)
        pendingGridResize = true
        applyPendingGridResize()
        requestFrame()
    }

    // MARK: - Window and display link

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()

        guard let window else {
            frameDriver.adopt(nil)
            frameDriver.update { $0.isOccluded = true }
            setFocused(false)
            updateAttachment()
            return
        }

        observedWindow = window
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowOcclusionChanged(_:)),
                           name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.addObserver(self, selector: #selector(windowBecameKey(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowResignedKey(_:)),
                           name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(applicationBecameActive(_:)),
                           name: NSApplication.didBecomeActiveNotification, object: nil)

        // `NSView.displayLink(target:selector:)` is bound to the screen the view is on and stops
        // itself when the view leaves the screen — the reason this is not a CVDisplayLink.
        let link = displayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.fired(_:)))
        link.add(to: .main, forMode: .common)
        frameDriver.adopt(link)

        terminal.setSelectionDoubleClickInterval(NSEvent.doubleClickInterval)
        refreshOcclusion()
        applyBackingScale(window.backingScaleFactor)
        updateAttachment()
        mouseController.viewDidMoveToWindow()
        setFocused(window.isKeyWindow && window.firstResponder === self)
        requestFrame()
    }

    private func stopObservingWindow() {
        let center = NotificationCenter.default
        if let observedWindow {
            center.removeObserver(self, name: nil, object: observedWindow)
        }
        center.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        observedWindow = nil
    }

    /// Recomputes occlusion from the window. Called from the occlusion notification, and again
    /// whenever the window becomes key or the app is activated — a missed notification would
    /// otherwise leave the link parked forever, which is the one failure mode of this optimization.
    func refreshOcclusion() {
        let visible = window.map { windowVisibility($0) } ?? false
        frameDriver.update { $0.isOccluded = !visible }
        if visible { requestFrame() }
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

    /// One display tick. Also the tests' entry point.
    ///
    /// - Parameter now: when the frame is due, as a duration since any fixed origin. The display
    ///   link passes its own timestamp; the DEC 2026 watchdog only compares these.
    func renderTick(now: Duration = .seconds(CACurrentMediaTime())) {
        applyPendingGridResize()
        guard canBuildFrames else {
            // Nothing can be drawn, so there is no DEC 2026 deadline to wait out either. A kept
            // deadline would hold the link running: a terminal closed right after a skipped frame
            // would tick at 120 Hz for good. Every way back to drawable asks for a frame, and that
            // tick reads the mode afresh.
            frameDriver.update {
                $0.needsUpdate = false
                $0.hasSyncDeadline = false
            }
            return
        }
        switch terminal.syncOutputDecision(now: now) {
        case .skipFrame:
            // DEC 2026 is held: hide the unsynchronized frame, but keep the link running so the
            // watchdog deadline is evaluated on the next tick.
            frameDriver.update { $0.hasSyncDeadline = true }
            return
        case .render, .forceOffAndRender:
            frameDriver.update { $0.hasSyncDeadline = false }
        }
        renderNow()
    }

    /// Builds and, when something changed, draws one frame. The renderer honours
    /// `layer.presentsWithTransaction` itself, so the live-resize path and the display-link path
    /// share this.
    func renderNow() {
        // The layer may have been made after the last resize, so its drawable size is set here too.
        updateDrawableSize()
        guard canBuildFrames, let layer = metalLayer,
              layer.drawableSize.width >= 1, layer.drawableSize.height >= 1 else {
            frameDriver.update { $0.needsUpdate = false }
            return
        }
        framesBuilt += 1
        let target = selfRef
        // A statement body, not a bare `Task {}`: as a single expression the closure would return
        // the Task and no longer be a `() -> Void`.
        var presented: (@Sendable () -> Void)?
        if onFramePresented != nil {
            presented = { @Sendable in
                _ = Task { @MainActor in target.object?.onFramePresented?() }
            }
        }
        do {
            let outcome = try renderContext.renderer.render(
                surface: surface, layer: layer,
                willEncode: { self.onDrawStart?() },
                onPresented: presented)
            if outcome.didEncode { framesCommitted += 1 }
        } catch {
            if !renderFailing {
                terminalEngineLog.error("rendering a frame failed: \(String(describing: error), privacy: .public)")
                renderFailing = true
            }
            // A failed frame leaves the surface dirty, so handing `needsDisplay` to the link would
            // rerun the failure on every tick. Park the link instead: the next thing that asks for
            // a frame (output, the blink, a resize, focus) tries again.
            frameDriver.update { $0.needsUpdate = false }
            return
        }
        if renderFailing {
            terminalEngineLog.notice("rendering a frame succeeded after failing")
            renderFailing = false
        }
        frameDriver.update { $0.needsUpdate = surface.needsDisplay }
    }

    // MARK: - Cursor blink

    /// The blink is a timer on the injected clock, not a display-link demand: it flips
    /// `surface.cursorBlinkOn`, which marks the surface dirty, which wakes the link for one frame.
    /// It runs only while the view is attached and focused, and never once the terminal is closed.
    private func startBlinkIfNeeded() {
        stopBlink()
        guard surface.isAttached, isTerminalFocused, !surface.isCursorSuppressed, !terminal.isClosed else { return }
        let clock = self.clock
        let target = selfRef
        blinkTask = Task { @MainActor in
            while true {
                do {
                    try await clock.sleep(for: GhosttyTerminalView.blinkInterval)
                } catch {
                    return
                }
                guard let view = target.object else { return }
                view.blinkTick()
            }
        }
    }

    /// Stops the blink with the cursor shown. Stopped in the off phase it would otherwise stay
    /// hidden, as an unfocused view's hollow cursor did.
    private func stopBlink() {
        blinkTask?.cancel()
        blinkTask = nil
        surface.cursorBlinkOn = true
    }

    /// One blink half-period.
    ///
    /// The timer runs while the view is focused, whatever cursor the program asked for. When the
    /// program stops the blink — a steady style, or the cursor hidden — this puts the phase back
    /// on instead of toggling, so the cursor does not stay hidden in the off phase.
    func blinkTick() {
        // The close's own signal stops the blink. This catches a tick already due when it lands.
        guard !terminal.isClosed else {
            stopBlink()
            return
        }
        guard surface.isAttached, isTerminalFocused else { return }
        guard surface.cursor.isBlinking, surface.cursor.isVisible else {
            if !surface.cursorBlinkOn {
                surface.cursorBlinkOn = true
                requestFrame()
            }
            return
        }
        surface.cursorBlinkOn.toggle()
        requestFrame()
    }

    /// Shows the cursor and restarts the blink phase. The input controller calls this on every
    /// key press, so the cursor is solid while typing.
    func resetCursorBlink() {
        surface.cursorBlinkOn = true
        startBlinkIfNeeded()
        requestFrame()
    }

    // MARK: - Focus

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { setFocused(window?.isKeyWindow ?? true) }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { setFocused(false) }
        return accepted
    }

    /// Internal so the blink tests can focus a view in a window that is never key.
    func setFocused(_ focused: Bool) {
        guard focused != isTerminalFocused else { return }
        isTerminalFocused = focused
        surface.isFocused = focused
        if focused { surface.cursorBlinkOn = true }
        startBlinkIfNeeded()
        inputController.focusDidChange(focused)
        onFocusChanged?(focused)
        requestFrame()
    }

    // MARK: - Clipboard

    /// Edit > Copy: the selection's text.
    @objc func copy(_ sender: Any?) {
        mouseController.copySelection()
    }

    /// Edit > Paste: the pasteboard's text, bracketed and checked by libghostty.
    @objc func paste(_ sender: Any?) {
        mouseController.pasteFromPasteboard()
    }

    // MARK: - Input forwarding

    private func forward(_ event: NSEvent) -> Bool {
        inputController.handle(event)
    }

    /// Whether the pointer at `event` would land on this view — nothing hidden about it, and no
    /// sibling drawn over it at that point. `NSTrackingArea` does not check either, so a hover
    /// handler has to. Outside a window there is nothing to be covered by.
    func isPointerTarget(_ event: NSEvent) -> Bool {
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
        // Click-to-focus. `TerminalInputController.acceptsKeyDown` declines every event whose view
        // is not the first responder, so a pane that cannot take focus by being clicked cannot be
        // typed into at all.
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

    /// `MouseController` sets this while a selection drag runs, so the link keeps ticking for
    /// autoscroll even when the terminal itself is idle.
    var isDragging: Bool {
        get { frameDriver.demand.isDragging }
        set { frameDriver.update { $0.isDragging = newValue } }
    }
}
