// Adapted from tkzmux c961533 Sources/TkzTerminalView/TerminalMetalView.swift, TkzTerminalView.swift and DisplayLinkDriver.swift (MIT, see LICENSE-tkzmux.txt).
// Dropping a frame at the GPU's limits, rather than blocking, adapted from termio 8196587 Shared/Sources/TermioStream/TermiodStreamRenderer.swift (MIT, see LICENSE-termio.txt).
// `LeadingEdgePolicy`, drawing output at once after a quiet refresh interval, follows Alacritty's `FrameTimer::compute_timeout` (alacritty/src/display/mod.rs, Apache-2.0 or MIT) and SwiftTerm's `FrameDriver.tickAfterResumeIfDue` (Sources/SwiftTerm/Apple/FrameDriver.swift, MIT). Its small-output check is an idea from kitty and iTerm2 (GPL); no code comes from either.
// GhosttyTerminalView — the NSView one libghostty terminal is drawn into.
//
// Responsibilities, and nothing else:
//
//   * own the `CAMetalLayer` and keep its scale and drawable size correct,
//   * own the terminal's `TerminalSurface`, attached only while the view can be seen,
//   * drive frames from a display link that is paused unless there is work,
//   * coalesce resizes into one grid resize per pass and present transactionally while live,
//   * rebuild the glyph atlas when the backing scale, the font or the stroke weight changes,
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
//
// ## Output draws on the leading edge
//
// Each wake-up decides once, by `LeadingEdgePolicy`, whether to draw at once or leave the frame to
// the display link. Small output into a screen that has had no output frame for a refresh
// interval draws at once, inside the wake-up, so an echo does not wait for the next tick. Bulk
// output, and output that comes within an interval of the last output frame, is drawn by the
// tick, once per refresh.

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
/// A busy `cat` signals thousands of times a second; without the pending hint that would be
/// thousands of main-queue hops per frame. With it, at most one hop is in flight at a time. A
/// signal that finds a hint pending folds into it (`RenderHint.merged(with:)`), and the hop hands
/// the folded hint to the view.
///
/// A view cancels its relay when it detaches. A queued hop holds the relay, and the view it reaches
/// may have attached again since, with a relay of its own: a cancelled relay's hop delivers nothing,
/// so a hint from before the detach, and any hold end in it, never reaches the attached view.
final class RenderSignalRelay: Sendable {
    private let pending = Mutex<RenderHint?>(nil)
    private let cancelled = Mutex(false)
    private let deliver: @MainActor @Sendable (RenderHint) -> Void

    init(deliver: @escaping @MainActor @Sendable (RenderHint) -> Void) {
        self.deliver = deliver
    }

    /// Ends every delivery, including a hop already queued. Called on main, where the hop runs, so
    /// a hop queued before the call finds it.
    func cancel() {
        cancelled.withLock { $0 = true }
    }

    /// Called from the feeding thread.
    func signal(_ hint: RenderHint) {
        let alreadyPending = pending.withLock { value -> Bool in
            if let current = value {
                value = current.merged(with: hint)
                return true
            }
            value = hint
            return false
        }
        guard !alreadyPending else { return }
        Task { @MainActor in
            let hint = self.pending.withLock { value -> RenderHint in
                let taken = value ?? .empty
                value = nil
                return taken
            }
            let isCancelled = self.cancelled.withLock { $0 }
            guard !isCancelled else { return }
            self.deliver(hint)
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
        view?.displayLinkFired(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
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

// MARK: - Leading-edge policy

/// What a render signal's delivery knows when it decides whether to draw at once. A pure value,
/// gathered on main.
struct LeadingEdgeFacts: Sendable, Equatable {
    /// The view can build frames: `canBuildFrames`, and a layer to draw into. The frame sizes its
    /// drawable to at least one pixel each way, so the layer is all rule 1's size check needs.
    var canBuildFrames: Bool
    /// A live resize is in progress. `setFrameSize` draws each step inside its Core Animation
    /// transaction.
    var isLiveResizing: Bool
    /// When the delivery runs, in the display link's timebase.
    var now: Duration
    /// When the last output frame was built, or nil before the first: the later of
    /// `GhosttyTerminalView.lastOutputFrameAt` and `lastEmptyLeadingEdgeDrawAt`.
    var lastOutputFrameAt: Duration?
    /// How long one frame stays on screen: see `LeadingEdgePolicy.refreshInterval`.
    var refreshInterval: Duration
    /// Fewer than three of the surface's frames are in flight on the GPU.
    var ringHasFreeSlot: Bool
    /// The layer's drawables awaiting their present report, as the tracker counts them.
    var drawablesAwaitingPresent: Int
    /// From the render hint: output fed since a frame last read the terminal.
    var outputBytesSinceFrame: Int
    /// From the render hint: a DEC 2026 hold is open.
    var holdOpen: Bool
    /// From the render hint: a hold ended in the chunks this delivery covers.
    var holdEnded: Bool
}

/// Whether a render signal's delivery draws at once or leaves the frame to the display link. A
/// pure function of `LeadingEdgeFacts`: it reads no clock and no state.
///
/// It limits only the leading edge. A delivery draws at once only after a full refresh interval
/// with no output frame, and only small output or a finished hold, so sustained output is still
/// drawn by the tick, once per refresh. A delivery that covers no output at all, such as a
/// resize's, a reset's or a change of colours with nothing fed since a frame last read the
/// terminal, is left to the tick too: the leading edge is for output, and frames that no output
/// causes keep going through the display link. With output still unread, such a delivery is
/// decided as that output's own would be.
enum LeadingEdgePolicy {
    /// Output this size or larger goes to the tick, unless a hold just ended. An echo is a few
    /// bytes and a prompt or status-line redraw usually a few hundred; a coloured full-screen
    /// redraw is several KiB.
    static let smallOutputLimit = 1024
    /// The refresh interval of a window with no screen, as in the offscreen tests.
    static let fallbackRefreshInterval = Duration.seconds(1) / 60

    /// Why a delivery leaves its frame to the display link. One per rule, in rule order; the last
    /// rule, that the output is small, has two: none at all, and too much.
    enum Reason: Sendable, Equatable, CaseIterable {
        /// The view cannot build a frame: detached, hidden, occluded, closed or sizeless.
        case cannotBuildFrames
        /// A live resize draws from `setFrameSize` instead.
        case liveResize
        /// A DEC 2026 hold is open, so the tick would skip the frame anyway.
        case holdOpen
        /// An output frame was built less than a refresh interval ago.
        case withinRefreshInterval
        /// The ring has no free slot.
        case ringFull
        /// `TerminalRenderer.maxDrawablesAwaitingPresent` drawables await their present report.
        case drawablesBehind
        /// No output had been fed since a frame last read the terminal when the call signalled:
        /// it was a resize, a reset or new defaults, with any earlier output already read.
        case noOutput
        /// `smallOutputLimit` or more bytes have been fed since the last frame, and no hold ended.
        case bulkOutput
    }

    enum Decision: Sendable, Equatable {
        /// Draw now, with the tick's own `renderTick(now:)`.
        case drawNow
        /// Ask the display link for a frame, and leave the drawing to its next tick.
        case coalesce(Reason)
    }

    /// The decision, checking the rules in order: the first that fails names the reason.
    static func decide(_ facts: LeadingEdgeFacts) -> Decision {
        guard facts.canBuildFrames else { return .coalesce(.cannotBuildFrames) }
        guard !facts.isLiveResizing else { return .coalesce(.liveResize) }
        guard !facts.holdOpen else { return .coalesce(.holdOpen) }
        if let last = facts.lastOutputFrameAt, facts.now - last < facts.refreshInterval {
            return .coalesce(.withinRefreshInterval)
        }
        guard facts.ringHasFreeSlot else { return .coalesce(.ringFull) }
        guard facts.drawablesAwaitingPresent < TerminalRenderer.maxDrawablesAwaitingPresent else {
            return .coalesce(.drawablesBehind)
        }
        // Frames that no output causes go through the display link. A hold's end the program
        // writes is output (`ESC[?2026l`); a reset's or a resize's is not reported as one.
        guard facts.outputBytesSinceFrame > 0 else { return .coalesce(.noOutput) }
        // A finished hold is a complete frame, the program promised, so its size does not matter.
        guard facts.holdEnded || facts.outputBytesSinceFrame < smallOutputLimit else {
            return .coalesce(.bulkOutput)
        }
        return .drawNow
    }

    /// How long one frame stays on screen. While the link runs, its own interval
    /// (`targetTimestamp - timestamp` from its last tick); while it is paused, and before its first
    /// tick after a resume, the screen's `minimumRefreshInterval`; with no screen,
    /// `fallbackRefreshInterval`.
    static func refreshInterval(linkInterval: Duration?, screenMinimumRefreshInterval: TimeInterval?) -> Duration {
        if let linkInterval, linkInterval > .zero { return linkInterval }
        if let screen = screenMinimumRefreshInterval, screen > 0, screen.isFinite { return .seconds(screen) }
        return fallbackRefreshInterval
    }
}

/// What a frame does when the GPU is behind: all three of the surface's ring slots are in flight,
/// or `TerminalRenderer.maxDrawablesAwaitingPresent` of the layer's drawables await their present
/// report.
enum GPUBackpressure {
    /// Drop the frame before building it, and keep the link ticking until the GPU catches up. What
    /// a display tick does, so main never blocks on the GPU.
    case drop
    /// Build it anyway: wait on the ring for a slot, and ask for a drawable whatever the tracker
    /// counts. What `drawFrameNow()` and a live resize do.
    case wait
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
    /// The running link's refresh interval, `targetTimestamp - timestamp` from its last tick. nil
    /// while the link is paused, and from a resume until the link's first tick after it: the
    /// interval a paused link last ran at says nothing about the screen it resumes on.
    private(set) var linkInterval: Duration?

    private var link: CADisplayLink?

    /// Never below 60 Hz, up to the 120 Hz a ProMotion display offers.
    static let frameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)

    /// Takes ownership of `link`, invalidating any previous one, and applies the policy. Pass nil
    /// when the view leaves its window.
    func adopt(_ link: CADisplayLink?) {
        if let existing = self.link, existing !== link { existing.invalidate() }
        if self.link !== link { linkInterval = nil }
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

    /// A tick of the running link: `interval` is how long its frame stays on screen. Kept as
    /// `linkInterval` until the link pauses. Ignored while paused, and when `interval` is not
    /// positive.
    func noteTick(interval: Duration) {
        guard !isPaused, interval > .zero else { return }
        linkInterval = interval
    }

    private func apply() {
        let run = DisplayLinkPolicy.shouldRun(demand)
        guard run == isPaused else { return }
        isPaused = !run
        // A pause ends the interval's run, and a resume waits for its first tick to learn it anew.
        linkInterval = nil
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

/// One font at one backing scale and stroke weight: the `FontSet`, `GlyphCache` and
/// `TerminalRenderer` built from it.
///
/// Views with the same font, scale and stroke weight share one context, so they share one glyph
/// atlas and one compiled pipeline. A view whose scale, font or stroke weight changes takes another
/// context and re-attaches its surface: an attach always produces a full rebuild, so no row keeps
/// an atlas position from the old atlas. A context lives while a view holds it.
@MainActor
final class TerminalRenderContext {
    let renderer: TerminalRenderer
    let font: NSFont
    /// The backing scale the atlas was rasterized at.
    let scale: CGFloat
    /// Whether the atlas's glyphs were drawn with stem darkening (`GlyphRasterizer.thicken`).
    let thicken: Bool

    var metrics: CellMetrics { renderer.glyphCache.metrics }
    var device: MTLDevice { renderer.device }

    private init(font: NSFont, scale: CGFloat, thicken: Bool, device: MTLDevice) throws(GhosttyError) {
        let fontSet = FontSet(font: font, scale: scale)
        do {
            let glyphCache = GlyphCache(fontSet: fontSet, device: device, thicken: thicken)
            renderer = try TerminalRenderer(device: device, glyphCache: glyphCache)
        } catch let error as GhosttyError {
            throw error
        } catch {
            throw GhosttyError.renderInit(String(describing: error))
        }
        self.font = font
        self.scale = scale
        self.thicken = thicken
    }

    private struct Key: Hashable {
        let fontName: String
        let pointSize: CGFloat
        let scale: CGFloat
        /// In the key so a change of stroke weight takes a new atlas. One atlas never holds glyphs
        /// drawn at both weights, which is what an atlas keyed without it would end up with.
        let thicken: Bool
    }

    private static var cache: [Key: WeakRef<TerminalRenderContext>] = [:]

    /// The context for `font` at `scale`, with or without stem darkening, built on first use.
    static func shared(font: NSFont, scale: CGFloat, thicken: Bool, device: MTLDevice) throws(GhosttyError)
        -> TerminalRenderContext {
        let scale = max(1, scale)
        let key = Key(fontName: font.fontName, pointSize: font.pointSize, scale: scale, thicken: thicken)
        cache = cache.filter { $0.value.object != nil }
        if let existing = cache[key]?.object { return existing }
        let context = try TerminalRenderContext(font: font, scale: scale, thicken: thicken, device: device)
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

    /// A frame has been encoded and committed to the GPU: the last work the app does on it, on the
    /// main thread, right after `onDrawStart`'s frame. Not called for a frame that drew nothing.
    public var onFrameEncoded: (@MainActor () -> Void)?

    /// The user ⌘-clicked an OSC 8 link. The view opens nothing itself: a program controls this
    /// string entirely, so the host decides what it may open.
    public var onOpenLink: (@MainActor (String) -> Void)?

    /// The view gained or lost keyboard focus.
    public var onFocusChanged: (@MainActor (Bool) -> Void)?

    // MARK: Host hooks
    //
    // Each of these is nil by default, and while it is nil the view behaves as it does on its
    // own. A host that embeds the view among others (the app's panels) sets the ones it needs.

    /// Called on every left mouse-down, before the view handles it, so the host can move its own
    /// focus to this view. `false` declines the press: something the host draws over the view owns
    /// its events, so a ⌘-click in that press opens no link. The view still takes first responder
    /// and handles the rest of the click either way.
    public var onMouseDownClaimFocus: (@MainActor () -> Bool)?

    /// The view became the first responder (`true`) or stopped being it (`false`), however focus
    /// moved. Unlike `onFocusChanged`, a window gaining or losing key status does not call it.
    public var onFirstResponderChanged: (@MainActor (Bool) -> Void)?

    /// Offered a paste's text, or a drop's, before the terminal brackets it. Returning `true`
    /// consumes it: the view sends nothing. `false`, or no hook, pastes as usual.
    public var onPaste: (@MainActor (String) -> Bool)?

    /// ⌘W while this view is the first responder. Without it ⌘W goes on through the responder
    /// chain to the menu.
    public var onCloseTab: (@MainActor () -> Void)?

    /// Called once, a main-queue turn after the first layout that gives the view a non-zero size,
    /// so the grid it reports is the one the layout chose.
    public var onReady: (@MainActor () -> Void)?

    /// Called each time the view is put into a window.
    public var onMovedToWindow: (@MainActor () -> Void)?

    /// Whether the view takes the click that activates its window. On by default. The click it
    /// takes only activates, as in any macOS terminal: the view becomes first responder, and the
    /// press, its drags and its release reach neither the program nor the selection, so the
    /// selection the user came back to copy stays. A ⌘-click on an OSC 8 link still opens it.
    public var acceptsActivatingClick = true

    /// Whether Option acts as Meta (Option-b sends `ESC b`) rather than typing the layout's
    /// character (`∫`). On by default, as in SwiftTerm, so Option-Backspace deletes a word. Off is
    /// the macOS text default, and the only setting under which dead keys work.
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
    /// seen and a display tick, or a render signal's delivery that draws at once, finds work: the
    /// terminal is read into the render state and, if it changed, encoded. A hidden or windowless
    /// view builds none, and neither does a tick that finds the GPU behind. A test seam, and how a
    /// delivery that draws at once learns whether its draw built a frame.
    public private(set) var framesBuilt = 0
    /// How many of the built frames were encoded and committed to the GPU. A built frame with
    /// nothing changed, or with no drawable to draw into, is not committed. A test seam, and how a
    /// delivery that draws at once learns whether its draw committed one.
    public private(set) var framesCommitted = 0

    /// The `now` of the last output frame: one that was encoded and whose build consumed program
    /// output (`FrameUpdate.outputBytes`). nil before the first. The tick, the leading edge and
    /// the live-resize path all stamp it. A frame with no output in it stamps nothing, so the
    /// cursor frame a key press's blink reset asks for cannot hold back the echo that follows.
    private(set) var lastOutputFrameAt: Duration?
    /// The `now` of the last delivery that drew at once, built a frame that consumed its output,
    /// and committed nothing, because that output changed nothing on screen: the view is scrolled
    /// back into history, or the output only set a title or a mode. Rule 4 counts it as an output
    /// frame. Uncounted, output that draws nothing would never stamp `lastOutputFrameAt`, and
    /// every delivery would build a frame of its own, at the main-queue hop rate in place of once
    /// per refresh. A build that found no output stamps nothing: a tick drew that output before
    /// the delivery ran, and its frame stamped `lastOutputFrameAt` already.
    private(set) var lastEmptyLeadingEdgeDrawAt: Duration?
    /// Whether the last frame built found no program output to consume. False after a build that
    /// threw, which may have consumed some.
    private var lastBuildFoundNoOutput = false
    /// What rule 4 measures from: the later of `lastOutputFrameAt` and
    /// `lastEmptyLeadingEdgeDrawAt`, or nil before either.
    private var lastFrameLimitingTheLeadingEdge: Duration? {
        guard let empty = lastEmptyLeadingEdgeDrawAt else { return lastOutputFrameAt }
        guard let output = lastOutputFrameAt else { return empty }
        return max(output, empty)
    }
    /// How many render-signal deliveries have reached `LeadingEdgePolicy`, and what the last one
    /// decided. Test seams.
    private(set) var renderSignalDeliveries = 0
    private(set) var lastLeadingEdgeDecision: LeadingEdgePolicy.Decision?

    // MARK: Collaborators

    let surface = TerminalSurface()
    /// The layer's drawables awaiting their present report. The view's, not the surface's: the
    /// drawables belong to the layer and outlive a detach.
    let drawableTracker = DrawableTracker()
    let frameDriver = DisplayLinkDriver()
    let inputController = TerminalInputController()
    let mouseController: MouseController
    private(set) var renderContext: TerminalRenderContext

    /// Whether `window` counts as visible. A seam: a test window is never on screen, so the tests
    /// replace this to separate "hidden" from "occluded". Set it before the view joins a window;
    /// the view reads it when it moves to one and when the window's occlusion changes.
    public var windowVisibility: @MainActor (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) }

    /// Now, as a duration since a fixed origin. A seam the tests set. Compared with the display
    /// link's timestamps, which are host time, so it is the same clock and not the wall clock.
    var now: @MainActor () -> Duration = { .seconds(CACurrentMediaTime()) }

    /// The layer's `nextDrawable()`, as the renderer calls it. A seam: a test returns nil to stand
    /// for a full pool, which the real call would wait a second to report.
    var nextDrawable: (CAMetalLayer) -> (any CAMetalDrawable)? = { $0.nextDrawable() }

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
    private var didFireReady = false
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
        renderContext = try TerminalRenderContext.shared(
            font: appearance.font, scale: scale, thicken: !appearance.thinStrokes, device: device)
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
        // Theme colours are sRGB values. Tagged, Core Animation colour-matches the drawable to the
        // display as it does a layer-backed view's backing store; untagged (nil), the bytes are
        // taken as the display's own gamut and look oversaturated on a wide-gamut (P3) display.
        // SwiftTerm's Metal layer is tagged the same way.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
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
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard acceptsActivatingClick else { return false }
        activationClickEventNumber = event?.eventNumber
        return true
    }

    // MARK: - Appearance

    /// Applies new colours, cursor, font and stroke weight. What is on screen stays; the terminal's
    /// default colours change under any a program set, and a new font or stroke weight rebuilds the
    /// glyph atlas and re-fits the grid.
    public func apply(_ appearance: GhosttyAppearance) {
        let glyphsChanged = appearance.font != terminalAppearance.font
            || appearance.thinStrokes != terminalAppearance.thinStrokes
        terminalAppearance = appearance
        terminal.apply(appearance)
        if glyphsChanged {
            useRenderContext(font: appearance.font, thicken: !appearance.thinStrokes, scale: renderContext.scale)
        }
        surface.markNeedsDisplay()
        startBlinkIfNeeded()
        refreshPreeditOverlay()
        requestFrame()
    }

    /// Switches to the context for `font` at `scale`, with or without stem darkening, and
    /// re-attaches the surface, so every row is rebuilt against the new atlas. Keeps the current
    /// context if the new one cannot be built.
    private func useRenderContext(font: NSFont, thicken: Bool, scale: CGFloat) {
        guard font != renderContext.font || thicken != renderContext.thicken
            || max(1, scale) != renderContext.scale else { return }
        let next: TerminalRenderContext
        do {
            next = try TerminalRenderContext.shared(
                font: font, scale: scale, thicken: thicken, device: renderContext.device)
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
        // While detached the view took no frames, so the watchdog's record of when a hold was
        // first seen is stale. Kept, it would force off a hold the program began just now. The
        // call also sets the hold from one read of mode 2026, and drops a hold's end that no
        // signal took. It comes before the signal is installed, so the end it drops cannot reach
        // the view's first hint. An end raised after this read is a real one, and is handed on.
        terminal.resetSyncOutputWatchdog()
        let target = selfRef
        let relay = RenderSignalRelay { target.object?.renderSignalled($0) }
        self.relay = relay
        renderSignalToken = terminal.setRenderSignal { [weak relay] in relay?.signal($0) }
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
        // A delivery already queued must not reach the view: it may attach again before the
        // delivery runs, and the hint, with any hold end in it, is from before the attach.
        relay?.cancel()
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

    /// The terminal's render signal, on the main thread, with the hint the relay folded from every
    /// signal since the last delivery. `close()` signals one last time, and the view stops its
    /// cursor blink then and asks for no frame, so nothing keeps waking a view that will never draw
    /// again.
    ///
    /// Otherwise the delivery decides once, by `LeadingEdgePolicy`, whether to draw now. It draws
    /// with the tick's own `renderTick(now:)`, inside this delivery, so the leading edge adds no
    /// main-queue hop. Anything else asks the display link for a frame.
    private func renderSignalled(_ hint: RenderHint) {
        guard !terminal.isClosed else {
            stopBlink()
            return
        }
        let now = self.now()
        let decision = LeadingEdgePolicy.decide(leadingEdgeFacts(hint, now: now))
        renderSignalDeliveries += 1
        lastLeadingEdgeDecision = decision
        switch decision {
        case .drawNow:
            let built = framesBuilt
            let committed = framesCommitted
            renderTick(now: now)
            if framesBuilt > built, framesCommitted == committed, !lastBuildFoundNoOutput {
                lastEmptyLeadingEdgeDrawAt = now
            }
        case .coalesce:
            frameDriver.requestFrame()
        }
    }

    /// What `LeadingEdgePolicy` decides from, read on main. Main is the only thread that takes
    /// ring slots and drawables, so the GPU facts stay true until this delivery acts on them.
    ///
    /// The drawables are read with `peekAwaitingPresent(now:)`, which changes nothing: a delivery
    /// that coalesces must not clear the tracker or start a nil drawable's hold, as a view that
    /// cannot draw would otherwise do on every chunk. A delivery that draws calls `renderTick`,
    /// whose own check, at the same `now`, does both.
    private func leadingEdgeFacts(_ hint: RenderHint, now: Duration) -> LeadingEdgeFacts {
        // Rule 1's size check needs only the layer: `renderNow` sizes the drawable from
        // `drawablePixelSize()`, which is never below one pixel each way.
        LeadingEdgeFacts(
            canBuildFrames: canBuildFrames && metalLayer != nil,
            isLiveResizing: frameDriver.demand.isLiveResizing,
            now: now,
            lastOutputFrameAt: lastFrameLimitingTheLeadingEdge,
            refreshInterval: refreshInterval,
            ringHasFreeSlot: surface.frameRing?.hasFreeSlot ?? true,
            drawablesAwaitingPresent: drawableTracker.peekAwaitingPresent(now: now),
            outputBytesSinceFrame: hint.outputBytesSinceFrame,
            holdOpen: hint.holdOpen,
            holdEnded: hint.holdEnded)
    }

    /// How long one frame stays on screen: the running link's own interval, else the window's
    /// screen's `minimumRefreshInterval`, else `LeadingEdgePolicy.fallbackRefreshInterval`.
    var refreshInterval: Duration {
        LeadingEdgePolicy.refreshInterval(
            linkInterval: frameDriver.linkInterval,
            screenMinimumRefreshInterval: window?.screen?.minimumRefreshInterval)
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
        } else if window == nil {
            // A view outside a window gets no layout pass and no display tick, so nothing else
            // would hand the terminal its new size. A host that sizes the view before it joins a
            // window hears `onSizeChanged` at once, as it would from SwiftTerm.
            applyPendingGridResize()
        } else {
            needsLayout = true
            requestFrame()
        }
    }

    public override func layout() {
        super.layout()
        updateAttachment()
        applyPendingGridResize()
        if !didFireReady, bounds.width > 0, bounds.height > 0 {
            didFireReady = true
            let callback = onReady
            onReady = nil
            DispatchQueue.main.async { callback?() }
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
        refreshPreeditOverlay()
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
        useRenderContext(font: terminalAppearance.font, thicken: !terminalAppearance.thinStrokes, scale: scale)
        pendingGridResize = true
        applyPendingGridResize()
        refreshPreeditOverlay()
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
        registerForDraggedTypes([.fileURL])
        onMovedToWindow?()
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

    /// Draws one frame now, outside the display link, if the view can be seen and anything
    /// changed. For a host's instruments and tests, which cannot wait on a display link that an
    /// offscreen window never runs.
    ///
    /// It waits for the GPU rather than drop the frame, as a live resize does. Those callers draw
    /// in offscreen windows, whose presents may never be reported, and the drawable limit would
    /// stop them drawing for longer than they wait. Its drawables still go into the tracker.
    public func drawFrameNow() {
        renderTick(backpressure: .wait)
    }

    /// The display link's tick. Keeps the link's refresh interval for the leading edge, then draws
    /// the frame due at `timestamp`.
    func displayLinkFired(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        frameDriver.noteTick(interval: .seconds(targetTimestamp - timestamp))
        renderTick(now: .seconds(timestamp))
    }

    /// One display tick. A render signal's delivery that draws at once calls it too, and so do the
    /// tests.
    ///
    /// - Parameters:
    ///   - now: when the frame is due, as a duration since any fixed origin; nil reads the `now`
    ///     seam. The display link passes its own timestamp. The DEC 2026 watchdog and the drawable
    ///     tracker only compare these.
    ///   - backpressure: what the frame does if the GPU is behind.
    func renderTick(now: Duration? = nil, backpressure: GPUBackpressure = .drop) {
        let now = now ?? self.now()
        applyPendingGridResize()
        guard canBuildFrames else {
            // Nothing can be drawn, so there is no DEC 2026 deadline to wait out either. A kept
            // deadline would hold the link running: a terminal closed right after a skipped frame
            // would tick at 120 Hz for good. Every way back to drawable asks for a frame, and that
            // tick reads the hold afresh.
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
        renderNow(now: now, backpressure: backpressure)
    }

    /// Builds and, when something changed, draws one frame. The renderer honours
    /// `layer.presentsWithTransaction` itself, so the live-resize path and the display-link path
    /// share this.
    ///
    /// - Parameters:
    ///   - now: when the frame is due; nil reads the `now` seam, as the live-resize path does.
    ///   - backpressure: what the frame does if the GPU is behind. A live resize always waits.
    func renderNow(now: Duration? = nil, backpressure: GPUBackpressure = .drop) {
        let now = now ?? self.now()
        // The layer may have been made after the last resize, so its drawable size is set here too.
        updateDrawableSize()
        guard canBuildFrames, let layer = metalLayer,
              layer.drawableSize.width >= 1, layer.drawableSize.height >= 1 else {
            frameDriver.update { $0.needsUpdate = false }
            return
        }
        // A live resize promised Core Animation a present in this transaction, so it never drops.
        let waits = backpressure == .wait || layer.presentsWithTransaction
        if !waits, isGPUBehind(now: now) {
            // Dropped before the build: no lock taken and no dirty state consumed. `needsUpdate`
            // stays set so the link keeps ticking until the GPU catches up. Handed
            // `surface.needsDisplay` instead, the link would park: output nobody built leaves the
            // surface looking clean.
            frameDriver.update { $0.needsUpdate = true }
            return
        }
        framesBuilt += 1
        lastBuildFoundNoOutput = false
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
                surface: surface, layer: layer, tracker: drawableTracker, now: now,
                waitsForSlot: waits, nextDrawable: nextDrawable,
                willEncode: { self.onDrawStart?() },
                onPresented: presented)
            lastBuildFoundNoOutput = outcome.update.outputBytes == 0
            if outcome.didEncode {
                framesCommitted += 1
                // An output frame. One whose build consumed no output, such as a cursor-only frame,
                // stamps nothing: it must not use up the interval the next echo draws at once in.
                // The stamp never moves back. A tick's `now` is its link's timestamp, the vsync it
                // fired for, which can be earlier than a delivery's `now` drawn just before it ran.
                if outcome.update.outputBytes > 0 { lastOutputFrameAt = max(lastOutputFrameAt ?? now, now) }
                onFrameEncoded?()
            }
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
        // Program output can move the cursor under a composition.
        refreshPreeditOverlay()
        frameDriver.update { $0.needsUpdate = surface.needsDisplay }
    }

    /// Whether a frame due at `now` would find the GPU behind: the ring has no free slot, or the
    /// tracker counts the drawable limit. Main is the only thread that takes slots and drawables,
    /// so a no here stays true until this frame takes them. The tracker is asked on every tick,
    /// full ring or not, so its timers run on every frame's `now`, whichever of the two holds the
    /// frame back.
    private func isGPUBehind(now: Duration) -> Bool {
        let ringHasFreeSlot = surface.frameRing?.hasFreeSlot ?? true
        let awaitingPresent = drawableTracker.awaitingPresent(now: now)
        return !ringHasFreeSlot || awaitingPresent >= drawableTracker.limit
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
        if accepted {
            setFocused(window?.isKeyWindow ?? true)
            onFirstResponderChanged?(true)
        }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            // A composition belongs to the focused view; left in place it would show on a pane
            // that no longer takes the input method's keys.
            discardComposition()
            setFocused(false)
            onFirstResponderChanged?(false)
        }
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

    /// Edit > Select All (⌘A): everything on the screen, scrollback included, as SwiftTerm selects
    /// it. Nothing reaches the program.
    public override func selectAll(_ sender: Any?) {
        if terminal.selectAll() { requestFrame() }
    }

    /// Edit > Paste: the pasteboard's text, bracketed and checked by libghostty. `onPaste` sees
    /// the text first.
    @objc func paste(_ sender: Any?) {
        if let onPaste, let text = mouseController.pasteboard.string(forType: .string), !text.isEmpty,
           onPaste(text) {
            return
        }
        mouseController.pasteFromPasteboard()
    }

    // MARK: - Drop

    /// Text a drop produced, such as the shell-quoted paths of dropped files. `onPaste` sees it
    /// first; otherwise it is sent as typed, unbracketed, as SwiftTerm sends a drop. Split from
    /// `performDragOperation` so a test can drive it: `NSDraggingInfo` cannot be built in one.
    public func deliverDroppedText(_ text: String) {
        guard !text.isEmpty else { return }
        if let onPaste, onPaste(text) { return }
        send(Array(text.utf8))
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLsOnly) else {
            return []
        }
        return .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: fileURLsOnly)
                as? [URL], !urls.isEmpty else { return false }
        deliverDroppedText(urls.map { Self.shellQuoted($0.path) }.joined(separator: " "))
        return true
    }

    /// `path` as one shell word: unchanged when every character is safe, single-quoted otherwise.
    ///
    /// Each `'` is written `'\''`, replaced scalar by scalar so a `'` that a combining mark follows
    /// is escaped too: `replacingOccurrences(of:with:)` compares composed character sequences and
    /// would leave it, ending the quoted word early.
    static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !path.isEmpty, path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        var quoted = String.UnicodeScalarView()
        quoted.append("'")
        for scalar in path.unicodeScalars {
            if scalar == "'" {
                quoted.append(contentsOf: #"'\''"#.unicodeScalars)
            } else {
                quoted.append(scalar)
            }
        }
        quoted.append("'")
        return String(quoted)
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

    /// A ⌘ key arrives here only once no menu item took it, and SwiftTerm's view consumes it then,
    /// sending what the macOS key bindings make of it (`handleCommandKeyDown`).
    public override func keyDown(with event: NSEvent) {
        if forward(event) || inputController.handleCommandKeyDown(event) { return }
        super.keyDown(with: event)
    }

    public override func keyUp(with event: NSEvent) {
        if !forward(event) { super.keyUp(with: event) }
    }

    public override func flagsChanged(with event: NSEvent) {
        if !forward(event) { super.flagsChanged(with: event) }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // `performKeyEquivalent` walks the whole view hierarchy, so only the first responder acts.
        if let onCloseTab, window?.firstResponder === self, event.type == .keyDown,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            onCloseTab()
            return true
        }
        return forward(event) || super.performKeyEquivalent(with: event)
    }

    /// The event number of the mouse-down AppKit last asked about in `acceptsFirstMouse`, which it
    /// asks only for a click into a window that is not key. The matching `mouseDown` is that
    /// activating click.
    private var activationClickEventNumber: Int?

    /// Set while the left press under way is the window's activating click, which the view
    /// consumed: its drags and its release go nowhere either. The mouse controller saw no press
    /// begin, so it declines them, and without this they would go on up the responder chain as a
    /// drag and a release of a press nobody saw begin.
    private var pressIsConsumed = false

    /// Set while the host declined the left press under way (`onMouseDownClaimFocus` answered
    /// `false`), from its mouse-down through its mouse-up. A ⌘-click in it opens no link: the
    /// host has something over the view that owns its events.
    private(set) var hostDeclinedPress = false

    public override func mouseDown(with event: NSEvent) {
        let isActivationClick = event.eventNumber == activationClickEventNumber
        activationClickEventNumber = nil
        pressIsConsumed = false
        hostDeclinedPress = onMouseDownClaimFocus?() == false
        // Click-to-focus. `TerminalInputController.acceptsKeyDown` declines every event whose view
        // is not the first responder, so a pane that cannot take focus by being clicked cannot be
        // typed into at all. The activating click focuses the view too.
        if let window, window.firstResponder !== self { window.makeFirstResponder(self) }
        // The activating click does nothing else (`acceptsActivatingClick`), except open the link
        // under a ⌘-click this press may open. The link is looked up once, here: the feed thread
        // can rewrite the screen between two lookups, and a press let through on the first that
        // found nothing on the second would go on as an ordinary click.
        if isActivationClick {
            if let open = onOpenLink, let uri = mouseController.linkToOpen(at: event) {
                open(uri)
            }
            pressIsConsumed = true
            return
        }
        if !forward(event) { super.mouseDown(with: event) }
    }

    public override func mouseUp(with event: NSEvent) {
        defer {
            pressIsConsumed = false
            hostDeclinedPress = false
        }
        guard !pressIsConsumed else { return }
        if !forward(event) { super.mouseUp(with: event) }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard !pressIsConsumed else { return }
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
