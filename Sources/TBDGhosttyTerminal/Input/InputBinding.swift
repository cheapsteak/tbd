// Adapted from tkzmux c961533 Sources/TkzTerminalCore/TerminalSession.swift, its input seam and DEC 2026 watchdog (MIT, see LICENSE-tkzmux.txt).
// The watchdog's hold edges, force-off and attach read adapted from termio 8196587 Shared/Sources/TermioStream/TermiodStreamTerminal.swift (MIT, see LICENSE-termio.txt).
// The input half of a terminal: its key and mouse encoders, its selection gesture and its DEC 2026
// watchdog, bound to the terminal so they live and die with the C handle.
//
// Every encoder call needs the live C terminal (the encoders re-read its modes on every call) and
// must run under the terminal's lock, so the objects are bound with `GhosttyTerminal.withBound`
// and reached only through the methods below. Each takes the lock once, does the libghostty work,
// and returns what the view needs. None calls back into the view, and none signals a frame: the
// view asks for one itself after anything that changes what is on screen.
//
// ## Where the bytes come out
//
//   * Key, focus and mouse bytes are returned to the caller, which sends them on `onSend`.
//   * Paste bytes are written by libghostty itself, through `WRITE_PTY`, while the paste runs.
//     `pasteText` takes them out of the terminal's pending output under the same lock and returns
//     them too, so a paste reaches the program the same way a key does. They never reach the
//     terminal's own `writePty` callback, which carries the program's replies.
//
// A failed libghostty call is logged and answered with the empty result (no bytes, no selection).
// A key or a click that cannot be encoded is dropped; it does not take the terminal down.
import GhosttyVt

// MARK: - DEC 2026 watchdog

/// The DEC 2026 (synchronized output) policy, as a pure value so it can be tested without a VT.
///
/// libghostty-vt does **not** hide unsynchronized frames: with mode 2026 set the render state still
/// reports rows dirty. Hiding is the host's job, exactly as in Ghostty's own renderer: skip frames
/// while a hold is open, and force the mode off if a program leaves it set.
///
/// The hold comes from libghostty's `RENDER_HOLD` edges (`IOContext.holdOpen`), not from a read of
/// the mode. The watchdog times how long ticks have seen a hold without a break, from the first
/// tick that saw one. A hold that ends and another that starts between two ticks do not restart
/// it: timed per hold, back-to-back holds that span every tick would hide every frame for good.
///
/// Time is a `Duration` since any fixed origin. The view passes the display link's timestamp, so
/// the policy compares the moments frames were due and never reads a clock itself.
struct SyncOutputWatchdog: Sendable, Equatable {
    /// The DEC private mode number of synchronized output.
    static let mode: UInt16 = 2026

    /// How long a program may hold mode 2026 before we stop believing it.
    var timeout: Duration

    private var activeSince: Duration?
    /// Ticks that skipped their frame since `activeSince`.
    private var skippedTicks = 0
    /// The run that the last answer, if it was `.forceOffAndRender`, ended. nil after any other.
    private(set) var lastForceOff: ForceOff?

    init(timeout: Duration = .seconds(1)) {
        self.timeout = timeout
        self.activeSince = nil
    }

    enum Decision: Sendable, Equatable {
        /// No hold is open: render normally.
        case render
        /// Ticks have seen a hold for less than `timeout`: skip this frame, keep the link running.
        case skipFrame
        /// Ticks have seen a hold for `timeout`: force the mode off and render.
        case forceOffAndRender
    }

    /// What a force-off logs: how long ticks saw the hold, and how many frames they skipped.
    struct ForceOff: Sendable, Equatable {
        /// From the first tick that saw the hold to the tick that forced it off.
        var heldFor: Duration
        /// The ticks in that run that skipped their frame. The tick that forces off renders.
        var skippedTicks: Int

        var notice: String {
            let milliseconds = Int((heldFor / Duration.milliseconds(1)).rounded())
            return "forced DEC 2026 off: ticks saw a hold for \(milliseconds) ms without a break, "
                + "and \(skippedTicks) ticks skipped their frame"
        }
    }

    /// Logs a force-off at `.notice`, so A/B logs show runs of skipped frames that ended in one.
    static func logForceOff(_ forceOff: ForceOff) {
        terminalEngineLog.notice("\(forceOff.notice, privacy: .public)")
    }

    /// `holdOpen` is `IOContext.holdOpen`: whether a DEC 2026 hold is open as this tick is due.
    mutating func evaluate(holdOpen: Bool, now: Duration) -> Decision {
        lastForceOff = nil
        guard holdOpen else {
            reset()
            return .render
        }
        guard let since = activeSince else {
            activeSince = now
            skippedTicks = 1
            return .skipFrame
        }
        if now - since >= timeout {
            lastForceOff = ForceOff(heldFor: now - since, skippedTicks: skippedTicks)
            activeSince = nil
            skippedTicks = 0
            return .forceOffAndRender
        }
        skippedTicks += 1
        return .skipFrame
    }

    /// Whether ticks have seen a hold without a break since the last `.render`.
    var isTracking: Bool { activeSince != nil }

    /// Forgets when the hold was first seen, so the next tick that sees one starts the timeout
    /// afresh.
    mutating func reset() {
        activeSince = nil
        skippedTicks = 0
        lastForceOff = nil
    }
}

// MARK: - The binding

/// Everything on the input side that must live exactly as long as one C terminal.
///
/// The key and mouse encoders hold no terminal, but they are kept here so every encoder call runs
/// under the terminal's lock. The selection gesture does need the terminal: `releaseBinding` frees
/// it while the terminal is still alive, and `GhosttyTerminal.close()` calls that before it frees
/// the C terminal.
final class InputBinding: TerminalBoundObject {
    let keyEncoder: KeyEncoder
    let mouseEncoder: MouseEncoder
    let selection: SelectionController
    var watchdog = SyncOutputWatchdog()

    /// macOS's default double-click interval. The view pushes the user's real one on attach.
    static let defaultDoubleClickInterval: Double = 0.5

    init(terminal: VtTerminal) throws {
        let geometry = TerminalPixelGeometry(screenWidth: 0, screenHeight: 0, cellWidth: 1, cellHeight: 1)
        keyEncoder = try KeyEncoder()
        mouseEncoder = try MouseEncoder(geometry: geometry)
        selection = try SelectionController(
            terminal: terminal, geometry: geometry, doubleClickInterval: Self.defaultDoubleClickInterval)
    }

    func releaseBinding(_ terminal: VtTerminal) {
        selection.release()
    }

    func terminalModesMayHaveChanged(_ terminal: VtTerminal) {
        mouseEncoder.terminalModesMayHaveChanged(terminal)
    }
}

// MARK: - The input seam

extension GhosttyTerminal {
    /// Runs `body` with the live terminal and its input binding, under the lock. Logs a failure
    /// and returns `fallback`; also returns `fallback` once the terminal is closed.
    private func input<T>(
        _ operation: String, fallback: T, _ body: (VtTerminal, InputBinding) throws -> T
    ) -> T {
        inputWithContext(operation, fallback: fallback) { raw, binding, _ in try body(raw, binding) }
    }

    /// `input`, plus the callbacks' context, where the hold edges keep `holdOpen`.
    private func inputWithContext<T>(
        _ operation: String, fallback: T, _ body: (VtTerminal, InputBinding, IOContext) throws -> T
    ) -> T {
        do {
            return try withBound(make: { try InputBinding(terminal: $0) }, body) ?? fallback
        } catch {
            terminalEngineLog.error(
                "\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return fallback
        }
    }

    /// The terminal's input binding, made now if nothing has made it yet. nil once the terminal is
    /// closed, or if it cannot be made.
    func inputBindingIfOpen() -> InputBinding? {
        input("making the input binding", fallback: nil) { _, binding in binding }
    }

    // MARK: Keys

    /// Encodes one key press against the terminal's current modes. Returns the bytes for the caller
    /// to send; **nothing is sent here**. Empty is the normal result for a bare modifier, a release
    /// in legacy mode, or a composing key.
    func encodeKey(_ press: KeyPress, optionAsAlt: OptionAsAlt) -> [UInt8] {
        input("encoding a key", fallback: []) { raw, binding in
            try binding.keyEncoder.encode(press, terminal: raw, optionAsAlt: optionAsAlt)
        }
    }

    // MARK: Viewport

    /// Moves the viewport down to the active area, as typing does in every terminal. Returns true
    /// when it moved, so the caller asks for a frame only then.
    @discardableResult
    func scrollViewportToBottom() -> Bool {
        withRaw { raw -> Bool in
            let metrics = TerminalScrollMetrics.read(raw)
            guard metrics.offset + metrics.visible < metrics.total else { return false }
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
            _ = ghostty_terminal_scroll_viewport(raw, behavior)
            return true
        } ?? false
    }

    /// SwiftTerm's PageUp and PageDown: the viewport moves a page, a screen's height of rows,
    /// while the program has claimed neither key. It has when it set Kitty keyboard flags, turned
    /// on application cursor keys (DECCKM), or is on the alternate screen, and then this scrolls
    /// nothing and returns false, so the key goes to the program. Returns true when it scrolled,
    /// even by nothing at the end of the scrollback, as SwiftTerm takes the key there too.
    ///
    /// `ignoringApplicationCursorKeys` leaves DECCKM out of that test. SwiftTerm does that for a
    /// page key with Option held while Option is not Meta, which it pages through `pageUp()`.
    func scrollViewportByPage(up: Bool, ignoringApplicationCursorKeys: Bool = false) -> Bool {
        withRaw { raw -> Bool in
            let state = GhosttyTerminalState(raw: raw)
            let claimedByCursorKeys = !ignoringApplicationCursorKeys
                && state.mode(MouseEncoder.applicationCursorKeysMode)
            guard state.kittyKeyboardFlags == 0, !claimedByCursorKeys, !state.isAlternateScreen else { return false }
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = up ? -state.rows : state.rows
            _ = ghostty_terminal_scroll_viewport(raw, behavior)
            return true
        } ?? false
    }

    // MARK: Paste

    /// Pastes `text`: bracketing (mode 2004), newline conversion, unsafe-byte stripping and the
    /// Kitty paste event all happen inside libghostty. Returns what happened and the bytes to send.
    ///
    /// `.rejectedUnsafe` means no bytes: confirm with the user, then call again with `allowUnsafe`.
    func pasteText(
        _ text: String, source: PasteSource, allowUnsafe: Bool
    ) -> (outcome: PasteOutcome, bytes: [UInt8]) {
        do {
            let result = try withBoundCapturingPty(make: { try InputBinding(terminal: $0) }) { raw, _ in
                try PasteSupport.paste(text: text, into: raw, source: source, allowUnsafe: allowUnsafe)
            }
            guard let result else { return (.nothingToPaste, []) }
            return (result.value, result.pty)
        } catch {
            terminalEngineLog.error("pasting failed: \(String(describing: error), privacy: .public)")
            return (.nothingToPaste, [])
        }
    }

    // MARK: Mouse

    /// Pushes rendered geometry to the mouse encoder and the selection controller.
    func setMousePixelGeometry(_ geometry: TerminalPixelGeometry) {
        input("setting the mouse geometry", fallback: ()) { _, binding in
            binding.mouseEncoder.geometry = geometry
            binding.selection.geometry = geometry
        }
    }

    /// Encodes one pointer event. Returns the report for the caller to send, or nil when the
    /// terminal wants none (tracking off, or a motion inside the same cell).
    func encodeMouse(_ press: MousePress) -> [UInt8]? {
        input("encoding a mouse event", fallback: nil) { raw, binding in
            try binding.mouseEncoder.encode(press, terminal: raw)
        }
    }

    /// Whether libghostty will report a mouse press under the program's mouse modes as they stand
    /// now. The view routes clicks, hovers and the wheel by it. Not the same as a mode bit being
    /// set: after `?1000h ?1003h ?1003l` the 1000 bit is still set and nothing is reported. See
    /// `MouseEncoder`. False once the terminal is closed.
    var isMouseReporting: Bool {
        input("reading the mouse modes", fallback: false) { raw, binding in
            binding.mouseEncoder.isReporting(terminal: raw)
        }
    }

    /// Where wheel rows would go, under one lock, as `MouseEncoder.wheel` decides: reports, arrow
    /// keys or the viewport. Read from what libghostty reports, like `isMouseReporting`, not from
    /// the mode bits. The viewport once the terminal is closed, when the wheel does nothing anyway.
    var wheelRoute: WheelRoute {
        input("reading where the wheel goes", fallback: .viewport) { raw, binding in
            binding.mouseEncoder.wheelRoute(terminal: raw)
        }
    }

    /// Whole rows of wheel scrolling. With tracking on, the report and how many of it are returned
    /// in `.report`. With tracking off, on the alternate screen under `?1007`, the arrow key and
    /// how many of it are returned in `.cursorKeys`; elsewhere the viewport is scrolled under the
    /// lock and the caller should ask for a frame.
    func mouseWheel(rows: Int, at position: SurfacePoint, mods: TerminalModifiers) -> WheelOutcome {
        input("encoding the wheel", fallback: .none) { raw, binding in
            try binding.mouseEncoder.wheel(rows: rows, at: position, mods: mods, terminal: raw)
        }
    }

    /// Forgets held buttons and motion de-duplication. Call on focus loss.
    func resetMouseEncoder() {
        input("resetting the mouse encoder", fallback: ()) { _, binding in binding.mouseEncoder.reset() }
    }

    // MARK: Selection

    /// `NSEvent.doubleClickInterval`, in seconds. Without it libghostty only ever sees single clicks.
    func setSelectionDoubleClickInterval(_ seconds: Double) {
        input("setting the double-click interval", fallback: ()) { _, binding in
            binding.selection.doubleClickInterval = seconds
        }
    }

    @discardableResult
    func selectionPress(at position: SurfacePoint, timestamp: Double) -> Bool {
        input("starting a selection", fallback: false) { _, binding in
            try binding.selection.press(at: position, timestamp: timestamp)
        }
    }

    @discardableResult
    func selectionDrag(to position: SurfacePoint, rectangle: Bool) -> Bool {
        input("extending a selection", fallback: false) { _, binding in
            try binding.selection.drag(to: position, rectangle: rectangle)
        }
    }

    func selectionRelease(at position: SurfacePoint?) {
        input("ending a selection", fallback: ()) { _, binding in try binding.selection.release(at: position) }
    }

    /// One tick of the view's autoscroll timer. Returns the rows scrolled; 0 means none was due.
    @discardableResult
    func selectionAutoscrollTick(at position: SurfacePoint, rectangle: Bool) -> Int {
        input("autoscrolling a selection", fallback: 0) { _, binding in
            try binding.selection.autoscrollTick(at: position, rectangle: rectangle)
        }
    }

    /// What the last drag is asking the view to autoscroll.
    var selectionAutoscrollDirection: SelectionAutoscroll {
        input("reading the autoscroll", fallback: .none) { _, binding in binding.selection.autoscrollDirection }
    }

    /// Drops the active selection and ends the click sequence.
    func clearSelection() {
        input("clearing the selection", fallback: ()) { _, binding in
            binding.selection.reset()
            binding.selection.clearSelection()
        }
    }

    /// Selects the whole screen, scrollback included, and ends the click sequence. Returns false
    /// when there is nothing to select or the terminal is closed.
    @discardableResult
    func selectAll() -> Bool {
        input("selecting everything", fallback: false) { _, binding in try binding.selection.selectAll() }
    }

    /// The selected text, formatted the way a terminal copy does it. nil with no selection.
    func copySelectionText() -> String? {
        input("copying the selection", fallback: nil) { _, binding in binding.selection.copySelection() }
    }

    /// The OSC 8 URI under `position` plus the run of cells sharing it, for the hover underline.
    /// Grid refs are only valid until the next change to the terminal, so the whole lookup, and the
    /// row walk that widens it, runs inside one lock hold.
    func hyperlinkRun(at position: SurfacePoint) -> (uri: String, columns: ClosedRange<UInt16>, row: UInt32)? {
        input("reading a link", fallback: nil) { raw, binding in
            guard let point = binding.selection.gridPoint(at: position) else { return nil }
            var columns: UInt16 = 0
            _ = ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_COLS, &columns)
            guard let run = HyperlinkLookup.run(at: point, in: raw, columns: columns) else { return nil }
            return (run.uri, run.columns, point.y)
        }
    }

    // MARK: DEC 2026

    /// Restarts the DEC 2026 watchdog and sets `holdOpen` from one read of the mode, in one lock
    /// hold. The view calls this when it attaches. It took no frames while detached, so the
    /// watchdog's record of when the hold was first seen is stale: kept, it would force off at
    /// the first frame a hold the program began only just now. The edges cover every write, reset
    /// and resize; the read keeps `holdOpen` right after a change that raised no edge, as
    /// `OPT_MODE` raises none.
    func resetSyncOutputWatchdog() {
        inputWithContext("resetting the synchronized-output watchdog", fallback: ()) { raw, binding, context in
            binding.watchdog.reset()
            context.holdOpen = GhosttyTerminalState(raw: raw).mode(SyncOutputWatchdog.mode)
        }
    }

    /// One render-tick decision: runs the watchdog on `holdOpen`, and forces the mode off when ticks
    /// have seen a hold for the timeout. A closed terminal renders.
    ///
    /// - Parameter onForceOff: hears each force-off, after the lock drops. It logs the notice;
    ///   tests replace it.
    func syncOutputDecision(
        now: Duration,
        onForceOff: (SyncOutputWatchdog.ForceOff) -> Void = SyncOutputWatchdog.logForceOff
    ) -> SyncOutputWatchdog.Decision {
        var forceOff: SyncOutputWatchdog.ForceOff?
        let decision: SyncOutputWatchdog.Decision = inputWithContext(
            "checking synchronized output", fallback: .render
        ) { raw, binding, context in
            let decision = binding.watchdog.evaluate(holdOpen: context.holdOpen, now: now)
            if decision == .forceOffAndRender {
                var off = GhosttyTerminalModeConfig(
                    mode: ghostty_mode_new(SyncOutputWatchdog.mode, false), value: false)
                _ = ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_MODE, &off)
                // `OPT_MODE` raises no edge, so the hold is closed here. Left open, the ticks
                // after it would go on skipping frames with the mode already off.
                context.holdOpen = false
                forceOff = binding.watchdog.lastForceOff
            }
            return decision
        }
        if let forceOff { onForceOff(forceOff) }
        return decision
    }
}
