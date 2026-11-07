// Adapted from tkzmux c961533 Sources/TkzTerminalCore/TerminalSession.swift, its input seam and DEC 2026 watchdog (MIT, see LICENSE-tkzmux.txt).
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
/// while the mode is set, and force it off if a program leaves it set.
///
/// Time is a `Duration` since any fixed origin. The view passes the display link's timestamp, so
/// the policy compares the moments frames were due and never reads a clock itself.
struct SyncOutputWatchdog: Sendable, Equatable {
    /// How long a program may hold mode 2026 before we stop believing it.
    var timeout: Duration

    private var activeSince: Duration?

    init(timeout: Duration = .seconds(1)) {
        self.timeout = timeout
        self.activeSince = nil
    }

    enum Decision: Sendable, Equatable {
        /// Mode 2026 is not set: render normally.
        case render
        /// Mode 2026 has been set for less than `timeout`: skip this frame, keep the link running.
        case skipFrame
        /// Mode 2026 has been held too long: force it off and render.
        case forceOffAndRender
    }

    /// `modeActive` comes from `ghostty_terminal_get(DATA_MODE, ghostty_mode_new(2026, false))`.
    mutating func evaluate(modeActive: Bool, now: Duration) -> Decision {
        guard modeActive else {
            activeSince = nil
            return .render
        }
        guard let since = activeSince else {
            activeSince = now
            return .skipFrame
        }
        if now - since >= timeout {
            activeSince = nil
            return .forceOffAndRender
        }
        return .skipFrame
    }

    /// Whether the mode has been continuously active since the last `.render`.
    var isTracking: Bool { activeSince != nil }

    /// Forgets when the mode was first seen, so the next active tick starts the timeout afresh.
    mutating func reset() { activeSince = nil }
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
        do {
            return try withBound(make: { try InputBinding(terminal: $0) }, body) ?? fallback
        } catch {
            terminalEngineLog.error(
                "\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return fallback
        }
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

    /// Whole rows of wheel scrolling. With tracking on the reports are returned in `.report`. With
    /// tracking off, on the alternate screen under `?1007`, arrow keys are returned in
    /// `.cursorKeys`; elsewhere the viewport is scrolled under the lock and the caller should ask
    /// for a frame.
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

    /// Restarts the DEC 2026 watchdog. The view calls this when it attaches: it took no frames
    /// while detached, so the watchdog's record of when the mode was first seen is stale. Kept,
    /// it would force off at the first frame a mode the program set only just now.
    func resetSyncOutputWatchdog() {
        input("resetting the synchronized-output watchdog", fallback: ()) { _, binding in
            binding.watchdog.reset()
        }
    }

    /// One render-tick decision: reads mode 2026, runs the watchdog, and forces the mode off when a
    /// program has held it past the timeout. A closed terminal renders.
    func syncOutputDecision(now: Duration) -> SyncOutputWatchdog.Decision {
        input("checking synchronized output", fallback: .render) { raw, binding in
            var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
            let active = ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS
                && config.value
            let decision = binding.watchdog.evaluate(modeActive: active, now: now)
            if decision == .forceOffAndRender {
                var off = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
                _ = ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_MODE, &off)
            }
            return decision
        }
    }
}
