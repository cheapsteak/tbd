// Adapted from tkzmux c961533 Sources/TkzTerminalView/MouseController.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// MouseController — the AppKit half of mouse reporting, selection, clipboard, scrolling and OSC 8
// links (M1.8).
//
// Everything that needs a decision lives here; everything that needs libghostty lives behind
// `MouseControllerTerminal`. That split is deliberate:
//
//   * the routing policy (report vs select, click granularity, wheel row accumulation, the link
//     scheme allow-list) is pure and unit-tests against synthesized `NSEvent`s,
//   * the terminal side is one narrow protocol, so the tests can drive a *real* libghostty
//     terminal through it without a `TerminalSession`, a pty or a window.
//
// ## What this file does NOT do
//
//   * it never touches a `Pty`. Report bytes go out through `sendBytes`, which the input
//     controller wires to the session; paste bytes are produced *inside* libghostty and leave
//     through the terminal's own WRITE_PTY sink. The one thing ⌘V sends that is neither is the
//     Ctrl-V chord for an image-only pasteboard, and that goes through `pasteClipboardImage` to
//     the input controller's key path — it is a keystroke, not a paste.
//   * it never clears `surface.needsDisplay`; it only ever calls `frameDriver.requestFrame()`.
//   * it does not consume `session.events`. `handle(_ event: TerminalEvent)` is called by whoever
//     owns that stream, for the OSC 52 `.clipboardWrite` case.

import AppKit
import Foundation
import QuartzCore
import UniformTypeIdentifiers

// MARK: - The terminal port

/// Everything `MouseController` needs from a terminal, and nothing else.
///
/// `TkzTerminalCore` cannot import `TkzTerminalView`, so `TerminalSession` cannot declare this
/// conformance itself; the binding is the one-line `extension TerminalSession: MouseControllerTerminal {}`
/// at the foot of this file, against the session's input seam (M1 integration).
/// Every method is main-actor: the implementation is expected to take the session lock internally.
@MainActor
public protocol MouseControllerTerminal: AnyObject {
    /// `GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING` — any of X10 / normal / button / any-event.
    var isMouseTrackingEnabled: Bool { get }

    /// Push rendered geometry to the mouse encoder *and* the selection controller
    /// (`OPT_SIZE` + `SelectionController.geometry`). Called on resize and backing-scale change.
    func setMousePixelGeometry(_ geometry: TerminalPixelGeometry)

    /// Encode one pointer event. Returns `nil` when the terminal wants no report.
    func encodeMouse(_ press: MousePress) throws -> [UInt8]?

    /// Whole rows of wheel scrolling: reports when tracking is on, a viewport scroll when it is off.
    func mouseWheel(rows: Int, at position: SurfacePoint, mods: TerminalModifiers) throws -> WheelOutcome

    /// `MouseEncoder.reset()` — forget held buttons and motion de-duplication. Focus loss.
    func resetMouseEncoder()

    @discardableResult
    func selectionPress(at position: SurfacePoint, timestamp: Double) throws -> Bool
    @discardableResult
    func selectionDrag(to position: SurfacePoint, rectangle: Bool) throws -> Bool
    func selectionRelease(at position: SurfacePoint?) throws
    /// One tick of the view layer's autoscroll timer. Returns the rows scrolled (0 = nothing due).
    @discardableResult
    func selectionAutoscrollTick(at position: SurfacePoint, rectangle: Bool) throws -> Int
    /// What the last drag asked the view to autoscroll.
    var selectionAutoscrollDirection: SelectionAutoscroll { get }
    /// Click count of the active gesture sequence (1 = single, 2 = double, 3 = triple, 0 = idle).
    var selectionClickCount: Int { get }
    /// The granularity table in force — the tests assert single/double/triple map to cell/word/line.
    var selectionBehaviors: SelectionBehaviors { get }

    func copySelectionText() -> String?
    func clearSelection()

    /// `PasteSupport.paste`. `.rejectedUnsafe` means nothing was written and the user must confirm.
    @discardableResult
    func pasteText(_ text: String, allowUnsafe: Bool) throws -> PasteOutcome

    /// The OSC 8 URI under `position` plus the run of cells sharing it, for the hover underline.
    func hyperlinkRun(at position: SurfacePoint) -> (uri: String, columns: ClosedRange<UInt16>, row: UInt32)?


}

// MARK: - Pure policy

/// What a pointer event should do.
public enum MouseRoute: Sendable, Equatable {
    /// Encode a mouse report and send it to the pty.
    case report
    /// Drive the local selection instead.
    case select
}

/// Reporting-vs-selection, the one rule: report when the program asked for mouse
/// tracking, unless Shift is held — Shift is the universal "let me select anyway" override.
public func terminalMouseRoute(trackingEnabled: Bool, shiftHeld: Bool) -> MouseRoute {
    trackingEnabled && !shiftHeld ? .report : .select
}

/// What to do with an OSC 8 URI a program put on the wire.
///
/// A terminal program controls this string *entirely*, so the opener is an allow-list, never a
/// deny-list: anything that is not one of the four schemes is refused outright
/// rather than handed to `NSWorkspace`.
public enum TerminalLinkAction: Sendable, Equatable {
    /// Safe to hand to `NSWorkspace.shared.open`.
    case open(URL)
    /// A `file:` URL: revealed in Finder rather than launched, because "open" on a local path means
    /// "run it with its default handler" and a program-supplied path must never get that.
    case reveal(URL)
    /// Not a URL, or not an allowed scheme.
    case refuse
}

/// The link allow-list. Pure and total, so it is tested directly.
public func terminalLinkAction(for string: String) -> TerminalLinkAction {
    guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return .refuse }
    switch scheme {
    case "http", "https", "mailto":
        // A scheme alone is not a URL: `http:` with no host would be opened as a bare scheme.
        if scheme != "mailto", url.host?.isEmpty ?? true { return .refuse }
        return .open(url)
    case "file":
        guard url.isFileURL, !url.path.isEmpty else { return .refuse }
        return .reveal(url)
    default:
        return .refuse
    }
}

/// `NSEvent.buttonNumber` → libghostty's button numbering.
///
/// AppKit numbers back/forward 3/4; the terminal protocol puts them at buttons 8/9, and the
/// remaining physical buttons are *not* in numeric order. Mirrors Ghostty's own table
/// (`macos/Sources/Ghostty/Ghostty.Input.swift`, read for reference only).
public func terminalMouseButton(nsEventButtonNumber number: Int) -> MouseButton? {
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
public func terminalModifiers(from flags: NSEvent.ModifierFlags) -> TerminalModifiers {
    var mods: TerminalModifiers = []
    if flags.contains(.shift) { mods.insert(.shift) }
    if flags.contains(.control) { mods.insert(.control) }
    if flags.contains(.option) { mods.insert(.option) }
    if flags.contains(.command) { mods.insert(.command) }
    if flags.contains(.capsLock) { mods.insert(.capsLock) }
    return mods
}

// MARK: - MouseController

/// Routes `NSEvent`s into `MouseEncoder` / `SelectionController` / the pasteboard.
///
/// An `NSObject` because it owns the view's `NSTrackingArea` and must be able to receive
/// `mouseEntered:` / `mouseExited:` / `mouseMoved:` as its owner. `TerminalMetalView` deliberately
/// does not override `updateTrackingAreas`, so this class installs and refreshes the area itself.
///
/// Install it with `attach(to:)`, then make it the input controller's `mouseHandler`; the router
/// calls `handle(_:in:)` for every mouse and scroll event.
@MainActor
public final class MouseController: NSObject, TerminalMouseHandling {
    // MARK: Collaborators

    /// The terminal this controller drives, looked up per event so a `TerminalMetalView.show(_:)`
    /// session swap is picked up with no extra wiring. Defaults to the view's own visible session;
    /// the tests replace it with a bare `LiveTestTerminal` so they need no session at all.
    public var terminalForView: (TerminalMetalView) -> (any MouseControllerTerminal)? = { $0.session }

    /// Where mouse *report* bytes go. The input controller wires this to the session's pty writer;
    /// this class never touches a `Pty` itself. Paste bytes do **not** come through here — they are
    /// produced inside libghostty and leave through the terminal's own WRITE_PTY sink.
    public var sendBytes: (([UInt8]) -> Void)?

    /// Asks the user whether to paste text libghostty rejected as unsafe. Replaced in tests.
    /// The completion may be called asynchronously; `true` re-runs the paste with `allowUnsafe`.
    public var confirmUnsafePaste: @MainActor (String, NSWindow?, @escaping (Bool) -> Void) -> Void =
        MouseController.defaultUnsafePasteConfirmation

    /// The pasteboard used for ⌘C / ⌘V / OSC 52. Injected so tests can use a named scratch board
    /// instead of the user's real clipboard.
    public var pasteboard: NSPasteboard = .general

    /// ⌘V found an image and **no text** on the pasteboard. The host wires this to
    /// `TerminalInputController.sendClipboardImageChord(in:)`, which sends the Ctrl-V keystroke
    /// that makes Claude Code read the clipboard image itself. Returns whether anything was sent;
    /// nil (unwired) means an image-only ⌘V declines, exactly as it did before.
    public var pasteClipboardImage: (@MainActor (TerminalMetalView) -> Bool)?

    /// Opens a vetted link. Injected so the tests never launch anything.
    public var openURL: @MainActor (TerminalLinkAction) -> Void = MouseController.defaultOpen

    // MARK: Tuning

    /// How often the autoscroll timer fires while a selection drag is outside the viewport.
    public var autoscrollInterval: Double = 0.05

    // MARK: Observable state (diagnostics + tests)

    /// The route the last handled press took. `nil` before the first press.
    public private(set) var lastRoute: MouseRoute?
    /// The button currently held for reporting, if any. A motion event must carry it or drags are
    /// silent under mode 1002.
    public private(set) var reportingButton: MouseButton?
    /// Buttons pressed while reporting, so a `mouseUp` that lands outside the view still releases.
    public private(set) var pendingReportReleases: Set<MouseButton> = []
    /// True between a selection `mouseDown` and its `mouseUp`.
    public private(set) var isSelecting = false
    /// True when the last selection drag was Option-held (rectangle).
    public private(set) var isRectangleDrag = false
    /// The URI currently underlined by a ⌘-hover, if any.
    public private(set) var hoveredLink: String?
    /// The geometry last pushed to the terminal, so a resize or scale change is detected per event.
    public private(set) var pushedGeometry: TerminalPixelGeometry?
    /// Rows the wheel has asked for, newest last. Diagnostics.
    public private(set) var lastWheelRows = 0
    /// Every non-zero wheel event, in rows (**negative = up**), whether the terminal scrolled its
    /// viewport or reported the wheel to the program. On the alternate screen this is the only
    /// evidence that the user is scrolling at all.
    public var onWheelRows: ((Int) -> Void)?

    // MARK: Private

    private weak var attachedView: TerminalMetalView?
    private var trackingArea: NSTrackingArea?
    private var accumulator = ScrollAccumulator()
    private var autoscrollTimer: (any DispatchSourceTimer)?
    private var autoscrollPosition = SurfacePoint(x: 0, y: 0)
    private var lastMovedEvent: NSEvent?
    private var linkOverlay: CALayer?

    public override init() {
        super.init()
    }

    deinit {
        MainActor.assumeIsolated {
            autoscrollTimer?.cancel()
            autoscrollTimer = nil
        }
    }

    // MARK: - Attach / tracking area

    /// Installs the tracking area on `view` and remembers it for cursor and overlay work.
    ///
    /// `.inVisibleRect` means the rect argument is ignored and AppKit keeps it in sync with the
    /// visible rect, so a resize needs no `updateTrackingAreas` override on the view.
    /// `.activeAlways` so hovering an inactive window still updates the cursor and OSC 8 underline.
    public func attach(to view: TerminalMetalView) {
        detach()
        attachedView = view
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil)
        view.addTrackingArea(area)
        trackingArea = area
        view.window?.acceptsMouseMovedEvents = true
        syncGeometry(from: view)
    }

    /// Removes the tracking area and any hover decoration.
    public func detach() {
        if let view = attachedView, let area = trackingArea {
            view.removeTrackingArea(area)
        }
        trackingArea = nil
        clearLinkOverlay()
        stopAutoscroll()
        attachedView = nil
    }

    /// The tracking area currently installed. Tests assert its options.
    public var installedTrackingArea: NSTrackingArea? { trackingArea }

    // MARK: - Geometry

    /// The rendered geometry `view` currently implies, in device pixels.
    public func pixelGeometry(of view: TerminalMetalView) -> TerminalPixelGeometry {
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
    public func syncGeometry(from view: TerminalMetalView) -> Bool {
        let geometry = pixelGeometry(of: view)
        guard geometry != pushedGeometry else { return false }
        pushedGeometry = geometry
        terminalForView(view)?.setMousePixelGeometry(geometry)
        return true
    }

    /// A pointer event's position in surface pixels, clamped into the drawable.
    ///
    /// Clamping matters for the release of a drag that ended outside the view: AppKit still routes
    /// that `mouseUp` here, with a negative or over-wide location.
    public func surfacePoint(of event: NSEvent, in view: TerminalMetalView) -> SurfacePoint {
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
    ///
    /// `TerminalMouseHandling`: `TerminalInputController` is the only `TerminalViewInputDelegate`
    /// and forwards every mouse and scroll event here unchanged.
    @discardableResult
    public func handle(_ event: NSEvent, in view: TerminalMetalView) -> Bool {
        syncGeometry(from: view)
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return mouseDown(event, in: view)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return mouseUp(event, in: view)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return mouseDragged(event, in: view)
        case .mouseMoved:
            return mouseMovedInside(event, in: view)
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

    private func mouseDown(_ event: NSEvent, in view: TerminalMetalView) -> Bool {
        guard let terminal = terminalForView(view) else { return false }
        let mods = terminalModifiers(from: event.modifierFlags)
        let position = surfacePoint(of: event, in: view)

        // ⌘-click on an OSC 8 link opens it and never reaches the terminal or the selection.
        if mods.contains(.command), event.type == .leftMouseDown,
           let run = terminal.hyperlinkRun(at: position) {
            openURL(terminalLinkAction(for: run.uri))
            return true
        }

        let route = terminalMouseRoute(
            trackingEnabled: terminal.isMouseTrackingEnabled, shiftHeld: mods.contains(.shift))
        lastRoute = route

        guard let button = terminalMouseButton(nsEventButtonNumber: event.buttonNumber) else {
            return false
        }

        switch route {
        case .report:
            reportingButton = button
            pendingReportReleases.insert(button)
            send(try? terminal.encodeMouse(
                MousePress(action: .press, button: button, mods: mods, position: position)))
            return true

        case .select:
            guard button == .left else { return false }
            isSelecting = true
            isRectangleDrag = mods.contains(.option)
            view.isDragging = true
            // `NSEvent.timestamp` is seconds since boot and monotonic, which is exactly what the
            // gesture's repeat detection wants: without it libghostty only ever sees single clicks.
            _ = try? terminal.selectionPress(at: position, timestamp: event.timestamp)
            view.frameDriver.requestFrame()
            return true
        }
    }

    // MARK: Drag

    private func mouseDragged(_ event: NSEvent, in view: TerminalMetalView) -> Bool {
        guard let terminal = terminalForView(view) else { return false }
        let mods = terminalModifiers(from: event.modifierFlags)
        let position = surfacePoint(of: event, in: view)

        if lastRoute == .report, let button = reportingButton {
            // Motion must carry the *held* button: button-event tracking (1002) encodes it into
            // the drag report, and a nil button there makes the whole drag silent.
            send(try? terminal.encodeMouse(
                MousePress(action: .motion, button: button, mods: mods, position: position)))
            return true
        }

        guard isSelecting else { return false }
        isRectangleDrag = mods.contains(.option)
        autoscrollPosition = position
        _ = try? terminal.selectionDrag(to: position, rectangle: isRectangleDrag)
        view.frameDriver.requestFrame()
        updateAutoscroll(terminal: terminal, view: view)
        return true
    }

    // MARK: Release

    private func mouseUp(_ event: NSEvent, in view: TerminalMetalView) -> Bool {
        guard let terminal = terminalForView(view) else { return false }
        let mods = terminalModifiers(from: event.modifierFlags)
        let position = surfacePoint(of: event, in: view)

        if lastRoute == .report {
            // Every press needs a matching release, including a mouseUp outside the view: the
            // held-button set is embedder-tracked, so a missed release leaves 1002 drags on
            // forever. AppKit routes the release to the mouseDown view, so this always runs.
            let button = terminalMouseButton(nsEventButtonNumber: event.buttonNumber)
            let releases = button.map { [$0] } ?? Array(pendingReportReleases)
            for released in releases {
                pendingReportReleases.remove(released)
                send(try? terminal.encodeMouse(
                    MousePress(action: .release, button: released, mods: mods, position: position)))
            }
            reportingButton = nil
            return true
        }

        guard isSelecting else { return false }
        isSelecting = false
        view.isDragging = false
        stopAutoscroll()
        try? terminal.selectionRelease(at: position)
        view.frameDriver.requestFrame()
        return true
    }

    // MARK: Motion

    private func mouseMovedInside(_ event: NSEvent, in view: TerminalMetalView) -> Bool {
        guard let terminal = terminalForView(view) else { return false }
        // The tracking area delivers hovers by geometry alone: a view drawn *over* the terminal
        // (the changes viewer) does not stop them. A hover the pointer cannot actually
        // reach must not be reported — under any-event tracking (1003) every one of them would
        // go down the pty as a motion report while the user is looking at something else.
        guard view.isPointerTarget(event) else {
            if hoveredLink != nil { clearLinkOverlay() }
            return false
        }
        let mods = terminalModifiers(from: event.modifierFlags)
        let position = surfacePoint(of: event, in: view)

        // ⌘-hover: underline the OSC 8 run under the pointer and offer the pointing hand.
        if mods.contains(.command) {
            if let run = terminal.hyperlinkRun(at: position),
               terminalLinkAction(for: run.uri) != .refuse {
                showLinkOverlay(run: run, in: view)
                NSCursor.pointingHand.set()
                return true
            }
            clearLinkOverlay()
        } else if hoveredLink != nil {
            clearLinkOverlay()
        }

        guard terminal.isMouseTrackingEnabled else { return false }
        // A hover carries no button under any-event tracking (1003); under button-event tracking
        // the encoder answers `nil` and nothing is sent.
        send(try? terminal.encodeMouse(
            MousePress(action: .motion, button: nil, mods: mods, position: position)))
        return true
    }

    // MARK: Wheel

    private func scrollWheel(_ event: NSEvent, in view: TerminalMetalView) -> Bool {
        guard let terminal = terminalForView(view) else { return false }
        let mods = terminalModifiers(from: event.modifierFlags)
        let position = surfacePoint(of: event, in: view)
        let geometry = pushedGeometry ?? pixelGeometry(of: view)

        let rows = wheelRows(
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            backingScale: Double(view.backingScale),
            cellHeightPx: Double(geometry.cellHeight),
            gestureEnded: event.phase.contains(.ended) || event.momentumPhase.contains(.ended))
        lastWheelRows = rows
        guard rows != 0 else { return true }
        onWheelRows?(rows)

        switch (try? terminal.mouseWheel(rows: rows, at: position, mods: mods)) ?? WheelOutcome.none {
        case .report(let bytes):
            send(bytes)
        case .scrolledViewport:
            view.frameDriver.requestFrame()
        case .none:
            break
        }
        return true
    }

    /// Turns one wheel event into whole rows, carrying the sub-row remainder between events.
    ///
    /// Pure apart from the accumulator, and separate from `scrollWheel` because `NSEvent.phase` is
    /// not settable on a synthesized event — the tests drive this directly.
    ///
    /// - Parameters:
    ///   - deltaY: `NSEvent.scrollingDeltaY`, in **points**, positive = content moves down.
    ///   - hasPreciseDeltas: trackpad / Magic Mouse. `false` means the delta is already in lines.
    ///   - backingScale: points → device pixels, because `cellHeightPx` is in device pixels.
    ///   - gestureEnded: `phase`/`momentumPhase` contains `.ended`; drops the carried fraction.
    /// - Returns: whole rows, **negative = up**, matching `GHOSTTY_SCROLL_VIEWPORT_DELTA`.
    public func wheelRows(
        deltaY: Double,
        hasPreciseDeltas: Bool,
        backingScale: Double,
        cellHeightPx: Double,
        gestureEnded: Bool
    ) -> Int {
        // The accumulator counts positive = downward; `scrollingDeltaY` is positive when the
        // content moves down, i.e. when the viewport moves *up*. Hence the negation.
        let rows: Int
        if hasPreciseDeltas {
            rows = accumulator.consume(pixels: -deltaY * backingScale, cellHeight: cellHeightPx)
        } else {
            rows = accumulator.consume(rows: -deltaY)
        }
        if gestureEnded { accumulator.reset() }
        return rows
    }

    /// The accumulator's unconsumed fraction of a row. Tests assert `.ended` clears it.
    public var scrollRemainder: Double { accumulator.remainder }

    // MARK: - Tracking-area callbacks

    /// The tracking area's `.mouseMoved` delivery. The explicit `@objc(...)` selectors matter:
    /// this is an `NSObject`, not an `NSResponder`, so Swift would otherwise export
    /// `mouseMovedWith:` and AppKit would find nothing to call on the tracking area's owner.
    /// The view also forwards `mouseMoved(with:)`
    /// through the input delegate, so this de-duplicates by event identity and exists only so the
    /// hover path still works when the view is not first responder.
    @objc(mouseMoved:) public func mouseMoved(with event: NSEvent) {
        guard let view = attachedView, event !== lastMovedEvent else { return }
        lastMovedEvent = event
        _ = handle(event, in: view)
    }

    @objc(mouseEntered:) public func mouseEntered(with event: NSEvent) {
        guard attachedView != nil else { return }
        NSCursor.iBeam.set()
    }

    @objc(mouseExited:) public func mouseExited(with event: NSEvent) {
        clearLinkOverlay()
        NSCursor.arrow.set()
    }

    // MARK: - Focus

    /// Call from `TerminalViewInputDelegate.terminalView(_:didChangeFocus:)`.
    ///
    /// Losing focus must reset the encoder: held buttons are embedder state, and a drag that ends
    /// while another window is key would otherwise leave a button held forever.
    public func focusDidChange(_ isFocused: Bool, in view: TerminalMetalView? = nil) {
        guard !isFocused else { return }
        let target = view ?? attachedView
        if let target { terminalForView(target)?.resetMouseEncoder() }
        reportingButton = nil
        pendingReportReleases.removeAll()
        accumulator.reset()
        if isSelecting {
            isSelecting = false
            target?.isDragging = false
            stopAutoscroll()
        }
        clearLinkOverlay()
    }

    // MARK: - Autoscroll

    /// Starts or stops the autoscroll timer to match what the gesture is asking for.
    private func updateAutoscroll(terminal: any MouseControllerTerminal, view: TerminalMetalView) {
        guard terminal.selectionAutoscrollDirection != .none else {
            stopAutoscroll()
            return
        }
        guard autoscrollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + autoscrollInterval,
                       repeating: autoscrollInterval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view else { return }
                self.autoscrollTick(in: view)
            }
        }
        timer.resume()
        autoscrollTimer = timer
    }

    /// One autoscroll step. Public so the tests can drive it without a real timer.
    public func autoscrollTick(in view: TerminalMetalView) {
        guard isSelecting, let terminal = terminalForView(view) else {
            stopAutoscroll()
            return
        }
        let scrolled = (try? terminal.selectionAutoscrollTick(
            at: autoscrollPosition, rectangle: isRectangleDrag)) ?? 0
        if scrolled == 0 {
            stopAutoscroll()
        } else {
            view.frameDriver.requestFrame()
        }
    }

    private func stopAutoscroll() {
        autoscrollTimer?.cancel()
        autoscrollTimer = nil
    }

    /// Whether the autoscroll timer is running. Tests only.
    public var isAutoscrolling: Bool { autoscrollTimer != nil }

    // MARK: - Clipboard

    /// ⌘C. The router only forwards mouse events, so the input controller calls this from its
    /// key/command path.
    @discardableResult
    public func copySelection(in view: TerminalMetalView) -> Bool {
        guard let terminal = terminalForView(view),
              let text = terminal.copySelectionText(), !text.isEmpty else { return false }
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
    /// image with *no* text goes to `pasteClipboardImage`.
    @discardableResult
    public func pasteFromPasteboard(in view: TerminalMetalView) -> Bool {
        guard let terminal = terminalForView(view) else { return false }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            guard Self.holdsImage(pasteboard) else { return false }
            return pasteClipboardImage?(view) ?? false
        }

        let outcome = (try? terminal.pasteText(text, allowUnsafe: false)) ?? .nothingToPaste
        guard outcome == .rejectedUnsafe else { return outcome == .written }

        confirmUnsafePaste(text, view.window) { [weak self, weak view] confirmed in
            MainActor.assumeIsolated {
                guard confirmed, let self, let view, let terminal = self.terminalForView(view) else { return }
                _ = try? terminal.pasteText(text, allowUnsafe: true)
            }
        }
        return true
    }

    /// Whether the pasteboard carries any image representation (PNG, TIFF, JPEG, …). A screenshot
    /// taken to the clipboard is TIFF + PNG with no string at all.
    static func holdsImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    }

    /// OSC 52. This is the seam for a host that wants the payload to reach AppKit here rather than
    /// routing `.clipboardWrite` to a pasteboard sink of its own — do not wire both.
    ///
    /// `TerminalSession` already answers the protocol (SUCCESS for the standard location,
    /// and clipboard *reads* are refused DENIED inside the session) and surfaces the payload as a
    /// `TerminalEvent`; whoever owns `session.events` routes it here so the text reaches AppKit.
    public func handle(_ event: TerminalEvent) {
        guard case .clipboardWrite(let text) = event, !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - OSC 8 overlay

    /// Draws (or moves) the hover underline under the link run.
    ///
    /// A `CALayer` sublayer rather than a renderer feature: the underline is transient hover
    /// decoration, not terminal content, and this keeps the frame path untouched.
    private func showLinkOverlay(
        run: (uri: String, columns: ClosedRange<UInt16>, row: UInt32),
        in view: TerminalMetalView
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
        if hoveredLink != nil, attachedView?.window?.isKeyWindow ?? false { NSCursor.iBeam.set() }
        hoveredLink = nil
        linkOverlay?.removeFromSuperlayer()
        linkOverlay = nil
    }

    /// The plain-text file path under `position`, resolved to a file that exists, with the run of
    /// cells to underline. Nil when there is no resolver, no path-shaped token, or no such file.
    public var linkUnderlineLayer: CALayer? { linkOverlay }

    // MARK: - Plumbing

    private func send(_ bytes: [UInt8]??) {
        guard let bytes = bytes ?? nil, !bytes.isEmpty else { return }
        sendBytes?(bytes)
    }

    private static func defaultOpen(_ action: TerminalLinkAction) {
        switch action {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .refuse:
            NSSound.beep()
        }
    }

    private static func defaultUnsafePasteConfirmation(
        _ text: String, _ window: NSWindow?, _ completion: @escaping (Bool) -> Void
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
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

// MARK: - TerminalSession binding

/// `TerminalSession`'s input seam is exactly this protocol: every method takes the session lock,
/// returns mouse report bytes to the caller (they leave through `sendBytes`), and lets paste bytes
/// out through the session's own WRITE_PTY sink. Nothing to implement here.
extension TerminalSession: MouseControllerTerminal {}
