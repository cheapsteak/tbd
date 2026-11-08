// Adapted from tkzmux c961533 Sources/TkzTerminalView/MouseController.swift (MIT, see LICENSE-tkzmux.txt).
// MouseController — the AppKit half of mouse reporting, selection, clipboard, scrolling and OSC 8
// links.
//
// Everything that needs a decision lives here; everything that needs libghostty lives behind the
// terminal's input seam (`InputBinding.swift`). The routing policy (report vs select, click
// granularity, wheel row accumulation) is pure and unit-tests against synthesized `NSEvent`s.
//
// ## What this file does NOT do
//
//   * It never writes to a pty. Report and paste bytes go out on the view's `onSend`. The one
//     thing ⌘V sends that is neither is the Ctrl-V chord for an image-only pasteboard, and that
//     goes through the input controller's key path — it is a keystroke, not a paste.
//   * It never opens a link. A ⌘-click on an OSC 8 link hands the URI to the view's `onOpenLink`,
//     and the host decides what a program-supplied URI may open.
//   * It never clears `surface.needsDisplay`; it only ever asks the view for a frame.

import AppKit
import Foundation
import QuartzCore
import UniformTypeIdentifiers

// MARK: - Pure policy

/// What a pointer event should do.
enum MouseRoute: Sendable, Equatable {
    /// Encode a mouse report and send it to the program.
    case report
    /// Drive the local selection instead.
    case select
}

/// Reporting-vs-selection, the one rule: report when the program asked for mouse
/// tracking, unless Shift is held — Shift is the universal "let me select anyway" override.
func terminalMouseRoute(trackingEnabled: Bool, shiftHeld: Bool) -> MouseRoute {
    trackingEnabled && !shiftHeld ? .report : .select
}

/// The terminal button a button event is for. nil for an event that is not a button event, and for
/// an "other" button event numbered 0 or 1, which names no other button.
///
/// Left and right come from the event's type, which AppKit always sets. `buttonNumber` is read
/// only for the other buttons: AppKit documents it for those, and an event built with
/// `NSEvent.mouseEvent(with:…)`, which takes no button, has `buttonNumber` 0 whatever its type, so
/// reading it for a right-button event turns a right-click into a left one.
func terminalMouseButton(for event: NSEvent) -> MouseButton? {
    switch event.type {
    case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
        .left
    case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
        .right
    case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
        event.buttonNumber >= 2 ? terminalMouseButton(nsEventButtonNumber: event.buttonNumber) : nil
    default:
        nil
    }
}

/// `NSEvent.buttonNumber` → libghostty's button numbering. For an "other" button event: left and
/// right are mapped from the event's type, by `terminalMouseButton(for:)`.
///
/// AppKit numbers back/forward 3/4; the terminal protocol puts them at buttons 8/9, and the
/// remaining physical buttons are *not* in numeric order. Mirrors Ghostty's own table
/// (`macos/Sources/Ghostty/Ghostty.Input.swift`, read for reference only).
func terminalMouseButton(nsEventButtonNumber number: Int) -> MouseButton? {
    switch number {
    case 0: .left
    case 1: .right
    case 2: .middle
    case 3: .eight
    case 4: .nine
    case 5: .six
    case 6: .seven
    case 7: .four
    case 8: .five
    case 9: .ten
    case 10: .eleven
    default: nil
    }
}

/// `NSEvent.ModifierFlags` → the encoder's modifier bits. Only the four the protocol encodes plus
/// the two lock keys; device-dependent bits are dropped.
func terminalModifiers(from flags: NSEvent.ModifierFlags) -> TerminalModifiers {
    var mods: TerminalModifiers = []
    if flags.contains(.shift) { mods.insert(.shift) }
    if flags.contains(.control) { mods.insert(.control) }
    if flags.contains(.option) { mods.insert(.option) }
    if flags.contains(.command) { mods.insert(.command) }
    if flags.contains(.capsLock) { mods.insert(.capsLock) }
    return mods
}

/// Where a wheel event sits in its gesture, collapsed from `NSEvent`'s `phase` and
/// `momentumPhase` to what the wheel arithmetic acts on. The app's `ScrollWheelAccumulator.Phase`
/// draws the same lines.
enum WheelPhase: Sendable, Equatable {
    /// Neither phase set: a classic wheel notch, or a precise device that reports no gesture.
    case unphased
    /// Fingers touched down or started moving (`.mayBegin`, `.began`): a new gesture, whose rows
    /// for the program must not inherit the last one's remainder.
    case gestureBegan
    /// The rest of a gesture with fingers on the surface (`.changed`, `.stationary`, `.ended`,
    /// `.cancelled`).
    case gestureChanged
    /// Inertial motion after the fingers lift (`momentumPhase` set). It continues the gesture it
    /// follows, remainder included.
    case momentum

    init(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        if !momentumPhase.isEmpty {
            self = .momentum
        } else if phase.contains(.began) || phase.contains(.mayBegin) {
            self = .gestureBegan
        } else if !phase.isEmpty {
            self = .gestureChanged
        } else {
            self = .unphased
        }
    }
}

/// Bounds what the wheel sends the program, mouse reports under tracking and arrow keys under
/// alternate scroll alike: `sustainedPerSecond`, with a burst of `burst`. The policy and the
/// numbers are those of the app's wheel monitor (`ScrollWheelAccumulator` in TBDApp), so a panel
/// gets the same bound whichever of the two sits in front of the program. What goes over it is
/// dropped, not queued: a backlog would keep scrolling after the fingers stop, and reports still
/// arriving after the program leaves mouse mode would land in it as literal text. Each report or
/// key makes a full-screen program redraw, and a flick's momentum tail, 60 to 120 events a second,
/// would otherwise send one per row of every event.
///
/// Time is the events' own `timestamp`, so tests drive it without a clock or a timer.
struct WheelInputBound: Sendable, Equatable {
    /// Reports or keys the bucket regains per second of event time.
    static let sustainedPerSecond: Double = 100
    /// Reports or keys the bucket holds when full: what passes at once after a pause.
    static let burst = 6

    /// Reports or keys the bucket can still let through. Starts full.
    private var tokens = Double(WheelInputBound.burst)
    /// `timestamp` of the last refill; nil until the first admission.
    private var lastRefill: TimeInterval?

    init() {}

    /// How many of `count` reports or keys pass at `timestamp`, after refilling the bucket for the
    /// event time since the last refill. The rest are dropped.
    mutating func admit(_ count: Int, at timestamp: TimeInterval) -> Int {
        guard count > 0 else { return 0 }
        if let lastRefill {
            // Clamped, so an out-of-order timestamp never drains the bucket.
            let elapsed = max(0, timestamp - lastRefill)
            tokens = min(Double(Self.burst), tokens + elapsed * Self.sustainedPerSecond)
        }
        lastRefill = timestamp
        let admitted = min(count, Int(tokens))
        tokens -= Double(admitted)
        return admitted
    }
}

// MARK: - MouseController

/// Routes `NSEvent`s into the mouse encoder, the selection gesture and the pasteboard.
///
/// An `NSObject` because it owns the view's `NSTrackingArea` and must be able to receive
/// `mouseEntered:` / `mouseExited:` / `mouseMoved:` as its owner. The view does not override
/// `updateTrackingAreas`, so this class installs the area itself.
@MainActor
final class MouseController: NSObject {
    // MARK: Collaborators

    /// The view this controller serves. Weak: the view owns the controller.
    private(set) weak var view: GhosttyTerminalView?

    /// Asks the user whether to paste text libghostty rejected as unsafe. Replaced in tests. The
    /// completion may be called later; `true` re-runs the paste with `allowUnsafe`.
    var confirmUnsafePaste: @MainActor (String, NSWindow?, @escaping @MainActor @Sendable (Bool) -> Void) -> Void =
        MouseController.defaultUnsafePasteConfirmation

    /// The pasteboard used for ⌘C and ⌘V. Injected so tests can use a named scratch board instead
    /// of the user's real clipboard.
    var pasteboard: NSPasteboard = .general

    // MARK: Tuning

    /// How often the autoscroll timer fires while a selection drag is outside the viewport.
    static let autoscrollInterval: Duration = .milliseconds(50)

    private let clock: any Clock<Duration>

    // MARK: Observable state (diagnostics + tests)

    /// The route the last handled press took. `nil` before the first press. Diagnostics only:
    /// each button's own route is recorded at its press, in `pendingReportReleases`.
    private(set) var lastRoute: MouseRoute?
    /// Buttons whose press was reported and whose release has not been. A button's route is
    /// fixed at its press: its drags and its release are reported if and only if it is in here,
    /// whatever later presses did, and whether or not the program still asks for reports.
    private(set) var pendingReportReleases: Set<MouseButton> = []
    /// True between a selection `mouseDown` and its `mouseUp`.
    private(set) var isSelecting = false
    /// True when the last selection drag was Option-held (rectangle).
    private(set) var isRectangleDrag = false
    /// The URI currently underlined by a ⌘-hover, if any.
    private(set) var hoveredLink: String?
    /// The geometry last pushed to the terminal, so a resize or scale change is detected per event.
    private(set) var pushedGeometry: TerminalPixelGeometry?

    // MARK: Private

    private var trackingArea: NSTrackingArea?
    private var accumulator = ScrollAccumulator()
    /// Whether the last wheel event's rows scrolled the viewport; nil before the first.
    private var lastWheelMovedViewport: Bool?
    /// One bucket for the wheel's reports and arrow keys: a program gets one or the other.
    private var programInputBound = WheelInputBound()
    private var autoscrollTask: Task<Void, Never>?
    private var autoscrollPosition = SurfacePoint(x: 0, y: 0)
    /// Where the last reported press or drag was. A release sent on focus loss, with no event of
    /// its own, goes out there.
    private var lastReportPosition = SurfacePoint(x: 0, y: 0)
    /// The last move handled, and whether it was consumed. The tracking area and the responder
    /// chain both deliver a move, as the same `NSEvent`; whichever comes second is a repeat.
    private var lastMoved: (event: NSEvent, consumed: Bool)?
    private var linkOverlay: CALayer?

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
        super.init()
    }

    deinit {
        MainActor.assumeIsolated { autoscrollTask?.cancel() }
    }

    // MARK: - Attach / tracking area

    /// Installs the tracking area on `view` and remembers it.
    ///
    /// `.inVisibleRect` means the rect argument is ignored and AppKit keeps it in sync with the
    /// visible rect, so a resize needs no `updateTrackingAreas` override on the view.
    /// `.activeAlways` so hovering an inactive window still updates the cursor and OSC 8 underline.
    func attach(to view: GhosttyTerminalView) {
        detach()
        self.view = view
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil)
        view.addTrackingArea(area)
        trackingArea = area
        syncGeometry()
    }

    /// Removes the tracking area and any hover decoration.
    func detach() {
        if let view, let area = trackingArea {
            view.removeTrackingArea(area)
        }
        trackingArea = nil
        clearLinkOverlay()
        stopAutoscroll()
        view = nil
    }

    /// The view moved to a window: mouse-moved events must be on for the hover paths.
    func viewDidMoveToWindow() {
        view?.window?.acceptsMouseMovedEvents = true
        pushedGeometry = nil
        syncGeometry()
    }

    // MARK: - Geometry

    /// The rendered geometry the view currently implies, in device pixels.
    func pixelGeometry(of view: GhosttyTerminalView) -> TerminalPixelGeometry {
        let grid = view.gridGeometry
        return TerminalPixelGeometry(
            screenWidth: UInt32(max(0, grid.viewportSizePx.x)),
            screenHeight: UInt32(max(0, grid.viewportSizePx.y)),
            cellWidth: UInt32(max(1, grid.cellSizePx.x)),
            cellHeight: UInt32(max(1, grid.cellSizePx.y)),
            paddingTop: UInt32(max(0, grid.originPx.y)),
            paddingLeft: UInt32(max(0, grid.originPx.x)))
    }

    /// Pushes geometry to the terminal when it changed. Called on every event, which covers both a
    /// window resize and a backing-scale change without needing a hook on the view.
    @discardableResult
    func syncGeometry() -> Bool {
        guard let view else { return false }
        let geometry = pixelGeometry(of: view)
        guard geometry != pushedGeometry else { return false }
        pushedGeometry = geometry
        view.terminal.setMousePixelGeometry(geometry)
        return true
    }

    /// A pointer event's position in surface pixels, clamped into the drawable.
    ///
    /// Clamping matters for the release of a drag that ended outside the view: AppKit still routes
    /// that `mouseUp` here, with a negative or over-wide location.
    func surfacePoint(of event: NSEvent, in view: GhosttyTerminalView) -> SurfacePoint {
        let pixels = view.devicePixels(of: event)
        let geometry = pushedGeometry ?? pixelGeometry(of: view)
        let maxX = Double(max(1, geometry.screenWidth)) - 1
        let maxY = Double(max(1, geometry.screenHeight)) - 1
        return SurfacePoint(
            x: min(max(Double(pixels.x), 0), maxX),
            y: min(max(Double(pixels.y), 0), maxY))
    }

    // MARK: - The router entry point

    /// Handles one mouse or scroll event. Returns `true` when it was consumed.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard let view else { return false }
        syncGeometry()
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return mouseDown(event, in: view)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return mouseUp(event, in: view)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return mouseDragged(event, in: view)
        case .mouseMoved:
            if let lastMoved, lastMoved.event === event { return lastMoved.consumed }
            let consumed = mouseMovedInside(event, in: view)
            lastMoved = (event, consumed)
            return consumed
        case .scrollWheel:
            return scrollWheel(event, in: view)
        case .mouseEntered:
            NSCursor.iBeam.set()
            return false
        case .mouseExited:
            clearLinkOverlay()
            return false
        default:
            return false
        }
    }

    // MARK: Press

    private func mouseDown(_ event: NSEvent, in view: GhosttyTerminalView) -> Bool {
        let terminal = view.terminal
        let mods = terminalModifiers(from: event.modifierFlags)
        let position = surfacePoint(of: event, in: view)

        // ⌘-click on an OSC 8 link opens it and never reaches the terminal or the selection.
        if mods.contains(.command), event.type == .leftMouseDown, let open = view.onOpenLink,
           let run = terminal.hyperlinkRun(at: position) {
            open(run.uri)
            return true
        }

        let route = terminalMouseRoute(trackingEnabled: terminal.isMouseReporting, shiftHeld: mods.contains(.shift))
        lastRoute = route

        guard let button = terminalMouseButton(for: event) else {
            return false
        }

        switch route {
        case .report:
            lastReportPosition = position
            let report = terminal.encodeMouse(
                MousePress(action: .press, button: button, mods: mods, position: position))
            // Only a press that went out earns a release, as in the encoder. One dropped here
            // would otherwise send a release on its own once the program turns reporting on.
            if report != nil { pendingReportReleases.insert(button) }
            send(report)
            return true

        case .select:
            guard button == .left else { return false }
            isSelecting = true
            isRectangleDrag = mods.contains(.option)
            view.isDragging = true
            // `NSEvent.timestamp` is seconds since boot and monotonic, which is exactly what the
            // gesture's repeat detection wants: without it libghostty only ever sees single clicks.
            terminal.selectionPress(at: position, timestamp: event.timestamp)
            view.requestFrame()
            return true
        }
    }

    // MARK: Drag

    private func mouseDragged(_ event: NSEvent, in view: GhosttyTerminalView) -> Bool {
        let terminal = view.terminal
        let mods = terminalModifiers(from: event.modifierFlags)
        let position = surfacePoint(of: event, in: view)

        if let button = terminalMouseButton(for: event),
           pendingReportReleases.contains(button) {
            // Motion must carry the *held* button: button-event tracking (1002) encodes it into
            // the drag report, and a nil button there makes the whole drag silent.
            lastReportPosition = position
            send(terminal.encodeMouse(
                MousePress(action: .motion, button: button, mods: mods, position: position)))
            return true
        }

        guard isSelecting else { return false }
        isRectangleDrag = mods.contains(.option)
        autoscrollPosition = position
        terminal.selectionDrag(to: position, rectangle: isRectangleDrag)
        view.requestFrame()
        updateAutoscroll(in: view)
        return true
    }

    // MARK: Release

    private func mouseUp(_ event: NSEvent, in view: GhosttyTerminalView) -> Bool {
        let terminal = view.terminal
        let mods = terminalModifiers(from: event.modifierFlags)
        let position = surfacePoint(of: event, in: view)

        let button = terminalMouseButton(for: event)
        if let button, pendingReportReleases.remove(button) != nil {
            // Every reported press needs a matching release, including a mouseUp outside the
            // view, one with Shift now held, and one after the program turned reporting off: the
            // held-button set is embedder-tracked, so a missed release leaves 1002 drags on
            // forever. AppKit routes the release to the mouseDown view, so this always runs.
            send(terminal.encodeMouse(
                MousePress(action: .release, button: button, mods: mods, position: position)))
            return true
        }

        guard isSelecting, button == .left else { return false }
        isSelecting = false
        view.isDragging = false
        stopAutoscroll()
        terminal.selectionRelease(at: position)
        view.requestFrame()
        return true
    }

    // MARK: Motion

    private func mouseMovedInside(_ event: NSEvent, in view: GhosttyTerminalView) -> Bool {
        let terminal = view.terminal
        // The tracking area delivers hovers by geometry alone: a view drawn *over* the terminal
        // does not stop them. A hover the pointer cannot actually reach must not be reported —
        // under any-event tracking (1003) every one of them would go to the program as a motion
        // report while the user is looking at something else.
        guard view.isPointerTarget(event) else {
            if hoveredLink != nil { clearLinkOverlay() }
            return false
        }
        let mods = terminalModifiers(from: event.modifierFlags)
        let position = surfacePoint(of: event, in: view)

        // ⌘-hover: underline the OSC 8 run under the pointer and offer the pointing hand.
        if mods.contains(.command), view.onOpenLink != nil {
            if let run = terminal.hyperlinkRun(at: position) {
                showLinkOverlay(run: run, in: view)
                NSCursor.pointingHand.set()
                return true
            }
            clearLinkOverlay()
        } else if hoveredLink != nil {
            clearLinkOverlay()
        }

        guard terminal.isMouseReporting else { return false }
        // A hover carries no button under any-event tracking (1003); under button-event tracking
        // the encoder answers `nil` and nothing is sent.
        send(terminal.encodeMouse(
            MousePress(action: .motion, button: nil, mods: mods, position: position)))
        return true
    }

    // MARK: Wheel

    private func scrollWheel(_ event: NSEvent, in view: GhosttyTerminalView) -> Bool {
        handleWheel(
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            phase: WheelPhase(phase: event.phase, momentumPhase: event.momentumPhase),
            timestamp: event.timestamp,
            at: surfacePoint(of: event, in: view),
            mods: terminalModifiers(from: event.modifierFlags),
            in: view)
        return true
    }

    /// One wheel event, from its deltas on: whole rows, then reports or arrow keys sent to the
    /// program, or a viewport scroll. Returns what was done; reports and arrow keys are counted
    /// after `programInputBound`, which drops those over it.
    ///
    /// Separate from `scrollWheel` because `NSEvent.phase` is not settable on a synthesized event,
    /// so the tests drive the whole path from here, gesture phases and timestamps included.
    ///
    /// - Parameter timestamp: the event's own `timestamp`, in seconds. The bound on reports and
    ///   arrow keys refills from its progress, so no clock is involved.
    @discardableResult
    func handleWheel(
        deltaY: Double,
        hasPreciseDeltas: Bool,
        phase: WheelPhase,
        timestamp: TimeInterval,
        at position: SurfacePoint,
        mods: TerminalModifiers,
        in view: GhosttyTerminalView
    ) -> WheelOutcome {
        let geometry = pushedGeometry ?? pixelGeometry(of: view)
        // The arithmetic depends on where the rows go, which the terminal decides again under its
        // lock as it encodes. A mode change between the two reads costs one event the other
        // arithmetic, nothing more. Both reads go by what libghostty reports, not the mode bits:
        // after `?1000h ?1003h ?1003l` the bits say tracking, but the rows scroll the viewport.
        let movesViewport = view.terminal.wheelScrollsViewport
        // A program that turned reporting on or off mid-gesture changed where the rows go. The
        // bank belongs to the other arithmetic, so it is dropped, as the app's monitor drops it:
        // motion that scrolled the viewport is never reported, nor the other way round.
        if let lastWheelMovedViewport, lastWheelMovedViewport != movesViewport { accumulator.reset() }
        lastWheelMovedViewport = movesViewport
        let rows = wheelRows(
            deltaY: deltaY,
            hasPreciseDeltas: hasPreciseDeltas,
            phase: phase,
            movesViewport: movesViewport,
            backingScale: Double(view.backingScale),
            cellHeightPx: Double(geometry.cellHeight))
        guard rows != 0 else { return .none }

        let outcome = view.terminal.mouseWheel(rows: rows, at: position, mods: mods)
        switch outcome {
        case .report(let press, let count):
            let sent = sendBounded(press, count: count, at: timestamp)
            return sent > 0 ? .report(press: press, count: sent) : .none
        case .cursorKeys(let key, let count):
            let sent = sendBounded(key, count: count, at: timestamp)
            return sent > 0 ? .cursorKeys(key: key, count: sent) : .none
        case .scrolledViewport:
            view.requestFrame()
        case .none:
            break
        }
        return outcome
    }

    /// Sends `unit`, one report or key, as many of `count` times as `programInputBound` admits at
    /// `timestamp`, back to back, and returns how many that was. The rest are dropped.
    private func sendBounded(_ unit: [UInt8], count: Int, at timestamp: TimeInterval) -> Int {
        let admitted = programInputBound.admit(count, at: timestamp)
        if admitted > 0 { send(Array([[UInt8]](repeating: unit, count: admitted).joined())) }
        return admitted
    }

    /// Turns one wheel event into whole rows, carrying the sub-row remainder between events.
    ///
    /// Rows that move the viewport follow SwiftTerm's `scrollWheel`, so shell scrollback scrolls
    /// as fast as in a SwiftTerm panel. Rows the program receives, as reports or arrow keys,
    /// follow the app's wheel monitor (`ScrollWheelAccumulator`), because each one is input the
    /// program redraws for:
    ///
    /// - A classic wheel's notch moves the viewport by its delta rounded, and at least one row,
    ///   as SwiftTerm does. For the program it is one row, whatever its delta, which carries the
    ///   system's wheel acceleration. Either way it ends any precise motion in progress.
    /// - Precise deltas (trackpad, Magic Mouse) accumulate against the cell height, one row per
    ///   whole cell. For the program the remainder is dropped when a new gesture begins and when
    ///   the direction reverses, so a stale fraction never becomes a key; the viewport keeps it,
    ///   as SwiftTerm does. Momentum continues the gesture it follows.
    ///
    /// - Parameters:
    ///   - deltaY: `NSEvent.scrollingDeltaY`, **points** when precise; positive = content moves
    ///     down.
    ///   - hasPreciseDeltas: trackpad / Magic Mouse.
    ///   - phase: where the event sits in its gesture.
    ///   - movesViewport: true when the rows scroll the viewport rather than reach the program.
    ///   - backingScale: points → device pixels, because `cellHeightPx` is in device pixels.
    /// - Returns: whole rows, **negative = up**, matching `GHOSTTY_SCROLL_VIEWPORT_DELTA`.
    func wheelRows(
        deltaY: Double,
        hasPreciseDeltas: Bool,
        phase: WheelPhase,
        movesViewport: Bool,
        backingScale: Double,
        cellHeightPx: Double
    ) -> Int {
        // `scrollingDeltaY` is positive when the content moves down, i.e. when the viewport moves
        // *up*, and rows count up as negative. Hence the negations.
        guard hasPreciseDeltas else {
            accumulator.reset()
            guard deltaY != 0 else { return 0 }
            guard movesViewport else { return deltaY > 0 ? -1 : 1 }
            let rounded = Int(deltaY.rounded())
            return rounded != 0 ? -rounded : (deltaY > 0 ? -1 : 1)
        }
        // Before the zero check: a gesture's first event, `.mayBegin`, usually has no delta.
        if !movesViewport, phase == .gestureBegan { accumulator.reset() }
        guard deltaY != 0, cellHeightPx > 0 else { return 0 }
        let rows = -deltaY * backingScale / cellHeightPx
        // A reversal starts from zero rather than netting against a fraction banked the other way.
        if !movesViewport, accumulator.remainder * rows < 0 { accumulator.reset() }
        return accumulator.consume(rows: rows)
    }

    // MARK: - Tracking-area callbacks

    /// The tracking area's `.mouseMoved` delivery. The explicit `@objc(...)` selectors matter:
    /// this is an `NSObject`, not an `NSResponder`, so Swift would otherwise export
    /// `mouseMovedWith:` and AppKit would find nothing to call on the tracking area's owner.
    /// The view also forwards `mouseMoved(with:)` through the input controller; `handle` drops
    /// whichever of the two deliveries comes second. This one exists so the hover path still works
    /// when the view is not first responder.
    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) {
        guard view != nil else { return }
        _ = handle(event)
    }

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        guard view != nil else { return }
        NSCursor.iBeam.set()
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        clearLinkOverlay()
        NSCursor.arrow.set()
    }

    // MARK: - Focus

    /// Losing focus must reset the encoder: held buttons are embedder state, and a drag that ends
    /// while another window is key would otherwise leave a button held forever. Every reported
    /// button still down is released first, so the program sees its release too: without it, a
    /// program under button-event tracking (1002) goes on treating the button as held.
    func focusDidChange(_ isFocused: Bool) {
        guard !isFocused else { return }
        if let view {
            for button in pendingReportReleases {
                send(view.terminal.encodeMouse(
                    MousePress(action: .release, button: button, mods: [], position: lastReportPosition)))
            }
            view.terminal.resetMouseEncoder()
        }
        pendingReportReleases.removeAll()
        accumulator.reset()
        if isSelecting {
            isSelecting = false
            view?.isDragging = false
            stopAutoscroll()
        }
        clearLinkOverlay()
    }

    // MARK: - Autoscroll

    /// Starts or stops the autoscroll timer to match what the gesture is asking for.
    private func updateAutoscroll(in view: GhosttyTerminalView) {
        guard view.terminal.selectionAutoscrollDirection != .none else {
            stopAutoscroll()
            return
        }
        guard autoscrollTask == nil else { return }
        let clock = self.clock
        let controller = WeakRef(self)
        autoscrollTask = Task { @MainActor in
            while true {
                do {
                    try await clock.sleep(for: MouseController.autoscrollInterval)
                } catch {
                    return
                }
                guard let current = controller.object else { return }
                current.autoscrollTick()
            }
        }
    }

    /// One autoscroll step. Internal so the tests can drive it without a timer.
    func autoscrollTick() {
        guard isSelecting, let view else {
            stopAutoscroll()
            return
        }
        let scrolled = view.terminal.selectionAutoscrollTick(at: autoscrollPosition, rectangle: isRectangleDrag)
        if scrolled == 0 {
            stopAutoscroll()
        } else {
            view.requestFrame()
        }
    }

    private func stopAutoscroll() {
        autoscrollTask?.cancel()
        autoscrollTask = nil
    }

    /// Whether the autoscroll timer is running. Tests only.
    var isAutoscrolling: Bool { autoscrollTask != nil }

    // MARK: - Clipboard

    /// ⌘C. Returns whether anything was copied.
    @discardableResult
    func copySelection() -> Bool {
        guard let view, let text = view.terminal.copySelectionText(), !text.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    /// ⌘V. Tries the paste; libghostty rejects an unsafe one *knowing the terminal's state*
    /// (a multi-line paste into a bracketed-paste program is fine, the same text at a bare prompt
    /// is not), so the confirm sheet is driven by `.rejectedUnsafe` rather than by a pre-check.
    ///
    /// **Text wins.** A pasteboard with text is pasted as text even when an image representation
    /// rides along — a spreadsheet range or a rich-text snippet routinely carries a TIFF or PDF
    /// next to its text, and pasting that as an image chord would break ordinary paste. Only an
    /// image with *no* text sends the Ctrl-V chord.
    @discardableResult
    func pasteFromPasteboard() -> Bool {
        guard let view else { return false }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            guard Self.holdsImage(pasteboard) else { return false }
            return view.inputController.sendClipboardImageChord()
        }

        let first = view.terminal.pasteText(text, source: .clipboard, allowUnsafe: false)
        guard first.outcome == .rejectedUnsafe else {
            send(first.bytes)
            return first.outcome == .written
        }

        let target = WeakRef(view)
        confirmUnsafePaste(text, view.window) { confirmed in
            guard confirmed, let view = target.object else { return }
            view.send(view.terminal.pasteText(text, source: .clipboard, allowUnsafe: true).bytes)
        }
        return true
    }

    /// Whether the pasteboard carries any image representation (PNG, TIFF, JPEG, …). A screenshot
    /// taken to the clipboard is TIFF + PNG with no string at all.
    static func holdsImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    }

    // MARK: - OSC 8 overlay

    /// Draws (or moves) the hover underline under the link run.
    ///
    /// A `CALayer` sublayer rather than a renderer feature: the underline is transient hover
    /// decoration, not terminal content, and this keeps the frame path untouched.
    private func showLinkOverlay(
        run: (uri: String, columns: ClosedRange<UInt16>, row: UInt32),
        in view: GhosttyTerminalView
    ) {
        hoveredLink = run.uri
        guard let host = view.layer else { return }
        let scale = max(1, Double(view.backingScale))
        let grid = view.gridGeometry
        let cellW = Double(grid.cellSizePx.x), cellH = Double(grid.cellSizePx.y)
        let thickness = max(1.0, (cellH / 14).rounded())

        let x = (Double(grid.originPx.x) + Double(run.columns.lowerBound) * cellW) / scale
        let width = Double(run.columns.count) * cellW / scale
        let y = (Double(grid.originPx.y) + Double(run.row + 1) * cellH - thickness) / scale

        let layer = linkOverlay ?? {
            let created = CALayer()
            created.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            created.zPosition = 1
            host.addSublayer(created)
            linkOverlay = created
            return created
        }()
        layer.contentsScale = view.backingScale
        layer.backgroundColor = NSColor.linkColor.cgColor
        layer.frame = CGRect(x: x, y: y, width: width, height: thickness / scale)
        layer.isHidden = false
    }

    private func clearLinkOverlay() {
        // Moving off a link (or letting go of Command) must give the I-beam back; otherwise the
        // pointing hand sticks until the pointer leaves the view entirely.
        if hoveredLink != nil, view?.window?.isKeyWindow ?? false { NSCursor.iBeam.set() }
        hoveredLink = nil
        linkOverlay?.removeFromSuperlayer()
        linkOverlay = nil
    }

    /// The hover underline, while one is shown. Tests only.
    var linkUnderlineLayer: CALayer? { linkOverlay }

    // MARK: - Plumbing

    private func send(_ bytes: [UInt8]?) {
        guard let bytes, !bytes.isEmpty else { return }
        view?.send(bytes)
    }

    private static func defaultUnsafePasteConfirmation(
        _ text: String, _ window: NSWindow?, _ completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Paste this text?"
        alert.informativeText =
            "The clipboard contains a newline, so pasting it could run a command immediately."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { completion(response == .alertFirstButtonReturn) }
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}
