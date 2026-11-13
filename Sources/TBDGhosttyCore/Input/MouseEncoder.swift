// Adapted from tkzmux c961533 Sources/TkzTerminalCore/MouseEncoder.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// MouseEncoder.swift — mouse events → terminal reports (libghostty-vt `mouse/encoder.h`).
//
// No AppKit here, so it unit-tests without a window: the view layer translates `NSEvent` into the
// plain-data `MousePress` below and nothing else.
//
// Threading: `MouseEncoder` is a non-Sendable class, like the handles it wraps. `InputBinding`
// owns one per terminal and every call runs under the terminal's lock.
import GhosttyVt

// MARK: - Plain data the view layer supplies

/// What the pointer did. Mirrors `GhosttyMouseAction`.
package enum MouseAction: Sendable, Equatable {
    case press, release, motion
}

/// Which button. Mirrors `GhosttyMouseButton` (the wheel is buttons four/five).
package enum MouseButton: Sendable, Equatable {
    case left, right, middle, four, five, six, seven, eight, nine, ten, eleven

    var ghostty: GhosttyMouseButton {
        switch self {
        case .left: GHOSTTY_MOUSE_BUTTON_LEFT
        case .right: GHOSTTY_MOUSE_BUTTON_RIGHT
        case .middle: GHOSTTY_MOUSE_BUTTON_MIDDLE
        case .four: GHOSTTY_MOUSE_BUTTON_FOUR
        case .five: GHOSTTY_MOUSE_BUTTON_FIVE
        case .six: GHOSTTY_MOUSE_BUTTON_SIX
        case .seven: GHOSTTY_MOUSE_BUTTON_SEVEN
        case .eight: GHOSTTY_MOUSE_BUTTON_EIGHT
        case .nine: GHOSTTY_MOUSE_BUTTON_NINE
        case .ten: GHOSTTY_MOUSE_BUTTON_TEN
        case .eleven: GHOSTTY_MOUSE_BUTTON_ELEVEN
        }
    }
}

/// Keyboard modifiers held during a pointer event. Mirrors the `GHOSTTY_MODS_*` bits.
package struct TerminalModifiers: OptionSet, Sendable, Equatable {
    package let rawValue: UInt16
    package init(rawValue: UInt16) { self.rawValue = rawValue }

    package static let shift = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
    package static let control = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL))
    /// macOS Option / Alt.
    package static let option = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_ALT))
    /// macOS Command / Super.
    package static let command = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER))
    package static let capsLock = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_CAPS_LOCK))
    static let numLock = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_NUM_LOCK))

    var ghostty: GhosttyMods { rawValue }
}

/// A pointer position in *surface* pixels — (0, 0) at the top-left of the terminal view,
/// **before** any padding is subtracted. The encoder does the pixel → cell conversion itself
/// from `MouseEncoder.geometry`, so the view must not pre-divide by the cell size.
package struct SurfacePoint: Sendable, Equatable {
    var x: Double
    var y: Double
    package init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One normalised pointer event. Despite the name it covers press, release *and* motion —
/// `action` says which. Everything the AppKit layer must fill in is here and nowhere else.
package struct MousePress: Sendable, Equatable {
    var action: MouseAction
    /// For press/release, the button that changed. For **motion**, the button currently held —
    /// button-event tracking (mode 1002) encodes it into the drag report, so `mouseDragged` must
    /// pass it; `nil` (no button) is right only for a hover in any-event tracking (mode 1003).
    var button: MouseButton?
    var mods: TerminalModifiers
    /// Surface-space pixels (see `SurfacePoint`). `GhosttyMousePosition` is `float`; the
    /// conversion happens at the boundary, so callers keep AppKit's `CGFloat` precision here.
    var position: SurfacePoint

    package init(
        action: MouseAction,
        button: MouseButton?,
        mods: TerminalModifiers = [],
        position: SurfacePoint
    ) {
        self.action = action
        self.button = button
        self.mods = mods
        self.position = position
    }
}

/// The rendered geometry the encoder needs to turn surface pixels into 1-based cell coordinates.
/// Mirrors `GhosttyMouseEncoderSize`; push it on every resize / backing-scale change.
package struct TerminalPixelGeometry: Sendable, Equatable {
    package var screenWidth: UInt32
    package var screenHeight: UInt32
    var cellWidth: UInt32
    package var cellHeight: UInt32
    var paddingTop: UInt32
    var paddingBottom: UInt32
    var paddingLeft: UInt32
    var paddingRight: UInt32

    package init(
        screenWidth: UInt32,
        screenHeight: UInt32,
        cellWidth: UInt32,
        cellHeight: UInt32,
        paddingTop: UInt32 = 0,
        paddingBottom: UInt32 = 0,
        paddingLeft: UInt32 = 0,
        paddingRight: UInt32 = 0
    ) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingTop = paddingTop
        self.paddingBottom = paddingBottom
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
    }

    var ghostty: GhosttyMouseEncoderSize {
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.stride
        size.screen_width = screenWidth
        size.screen_height = screenHeight
        size.cell_width = cellWidth
        size.cell_height = cellHeight
        size.padding_top = paddingTop
        size.padding_bottom = paddingBottom
        size.padding_left = paddingLeft
        size.padding_right = paddingRight
        return size
    }
}

// MARK: - Scroll accumulation

/// Turns continuous (trackpad) scroll deltas into whole rows, keeping the remainder so slow
/// two-finger scrolling still advances one row at a time instead of being rounded away.
///
/// A value type on purpose: the policy is unit-testable without a terminal, and the view layer
/// keeps one per view (`var accumulator = ScrollAccumulator()`).
package struct ScrollAccumulator: Sendable, Equatable {
    /// Unconsumed fraction of a row. Positive = downward.
    package private(set) var remainder: Double = 0

    package init() {}

    /// Add `pixels` of vertical scroll (positive = content scrolls *down*, i.e. `NSEvent`'s
    /// `-scrollingDeltaY`) and return the whole rows now due. The fraction is carried over.
    mutating func consume(pixels: Double, cellHeight: Double) -> Int {
        guard cellHeight > 0, pixels.isFinite else { return 0 }
        return consume(rows: pixels / cellHeight)
    }

    /// Add `rows` (may be fractional) and return the whole rows now due.
    package mutating func consume(rows: Double) -> Int {
        guard rows.isFinite else { return 0 }
        remainder += rows
        let whole = remainder < 0 ? remainder.rounded(.up) : remainder.rounded(.down)
        remainder -= whole
        return Int(whole)
    }

    /// Drop the carried fraction — call when a new gesture begins or the direction reverses, so a
    /// stale fraction never joins motion it did not belong to.
    package mutating func reset() { remainder = 0 }
}

/// What a wheel event should do, decided by `MouseEncoder.wheel(rows:…)`.
package enum WheelOutcome: Sendable, Equatable {
    /// Nothing to do (zero rows, or the terminal wanted no report).
    case none
    /// Write `press`, the report of one wheel press for button four (up) or five (down), to the
    /// pty `count` times, once per row (mouse tracking is on). A count rather than the bytes, so
    /// the view can bound how many it sends.
    case report(press: [UInt8], count: Int)
    /// Write `key`, a cursor-up or cursor-down key, to the pty `count` times, once per row, because
    /// a program on the alternate screen with alternate scroll (`?1007h`) asked for the wheel as
    /// arrow keys. A count rather than the bytes, so the view can bound how many it sends.
    case cursorKeys(key: [UInt8], count: Int)
    /// Mouse tracking is off and the viewport was scrolled by this many rows (negative = up).
    case scrolledViewport(rows: Int)
}

/// Where wheel rows go under the terminal's modes as they stand, as `MouseEncoder.wheel` decides.
package enum WheelRoute: Sendable, Equatable {
    /// To the program as mouse reports: libghostty reports the mouse.
    case reports
    /// To the program as arrow keys under `?1007`, or nowhere without it: the alternate screen,
    /// with nothing reported.
    case alternateScroll
    /// To the viewport: the primary screen, with nothing reported.
    case viewport
}

// MARK: - The encoder

/// Wraps `GhosttyMouseEncoder` plus one reusable `GhosttyMouseEvent`.
///
/// ## Where the encoder's options come from
///
/// libghostty encodes under a tracking mode and a report format that it keeps as terminal flags,
/// not as the DEC mode bits. A program that sets a mouse mode makes it the current one, and one
/// that resets any of them turns tracking (or the format) off, whatever other bits are still set:
/// after `?1000h ?1003h ?1003l` the bits still say 1000 but the flags say no tracking, and after
/// `?1006h ?1015h` both format bits are set but urxvt is in force. Only `set_from_terminal` reads
/// the flags; there is no getter. So the encoder is set from the terminal on every event, and the
/// encoding a press went out under is kept as a second encoder, set from the terminal at the press.
///
/// The same goes for deciding whether to report at all. `GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING`
/// reads the bits, so the view would route a click to "report" that libghostty then drops: no
/// report and no selection. What the flags leave in force is found instead by encoding a few
/// probe events (`ReportProbe`) after every write that may have changed them, and the view routes
/// clicks, hovers and the wheel by that.
///
/// Not `Sendable`: the C objects are not thread-safe. Only used under the terminal's lock.
final class MouseEncoder {
    private let handle: GhosttyMouseEncoderHandle
    private let event: GhosttyMouseEvent
    /// Buttons held as far as the program knows: those whose press was reported and whose release
    /// has not gone out. `setopt_from_terminal` explicitly does *not* touch
    /// `OPT_ANY_BUTTON_PRESSED`, so the encoder pushes this on every encode.
    ///
    /// The keys of `pressEncodings`, so the two cannot disagree. A press that went out unreported
    /// never joins: the controller passes on only the releases of reported presses, so its release
    /// would never come here, and the button would stay held until focus was lost. Internal rather
    /// than private so tests can assert it never leaks a wheel "press".
    var heldButtons: Set<MouseButton> { Set(pressEncodings.keys) }
    /// For each reported, still-held button, an encoder set from the terminal as its press went
    /// out. The release is encoded with it, so a program that turned reporting off, or changed
    /// format, while the button was down still gets the release, in the press's encoding.
    private(set) var pressEncodings: [MouseButton: GhosttyMouseEncoderHandle] = [:]

    /// What libghostty reports under the terminal's mouse flags, read back the only way they can
    /// be: by encoding one event of each kind with an encoder set from the terminal. A left press
    /// is reported under any tracking mode, its release under all but X10, a move with the button
    /// held under button- and any-event tracking, and a bare move under any-event tracking alone.
    /// The probe sits in cell 200, where the five report formats all encode differently, so two
    /// probes are equal exactly when the tracking mode and the format are.
    struct ReportProbe: Equatable, Sendable {
        var press: [UInt8]?
        var release: [UInt8]?
        var drag: [UInt8]?
        var hover: [UInt8]?

        /// Tracking is on: a press is reported, so a click goes to the program, not the selection.
        var reportsPresses: Bool { press != nil }

        /// Tracking is off.
        static let silent = ReportProbe()
    }

    /// Encodes the probes. Set from the terminal before each probe, with a fixed geometry of its
    /// own, so a probe reads the flags alone.
    private let probeHandle: GhosttyMouseEncoderHandle
    /// One pixel per cell, wide enough for the probe's cell 200.
    private static let probeGeometry = TerminalPixelGeometry(
        screenWidth: 400, screenHeight: 10, cellWidth: 1, cellHeight: 1)
    private static let probePoint = SurfacePoint(x: 199.5, y: 0.5)

    /// The flags as of the terminal's last write or reset. nil until first needed. Kept up to date
    /// by `terminalModesMayHaveChanged`, so an event reads it and never probes.
    private var probe: ReportProbe?

    /// The last motion report sent since the last press, release, change of mouse flags or resize.
    /// A motion whose report repeats it is dropped: the bytes carry the cell, the button bits and
    /// the modifiers, and the flags have not changed since, so the program would learn nothing
    /// from it. SGR-Pixels reports carry pixels, so every pixel of motion still goes out there, as
    /// the mode asks.
    // libghostty-vt drops repeats only with OPT_TRACK_LAST_CELL, off by default and keyed on the cell alone.
    private var lastMotion: [UInt8]?

    /// Rendered geometry. Assign on every resize; it is pushed to `OPT_SIZE` immediately. A resize
    /// moves what a cell means, so it also forgets the last motion.
    var geometry: TerminalPixelGeometry {
        didSet {
            applyGeometry()
            lastMotion = nil
        }
    }

    init(geometry: TerminalPixelGeometry) throws {
        handle = try GhosttyMouseEncoderHandle()
        probeHandle = try GhosttyMouseEncoderHandle()
        var probeSize = Self.probeGeometry.ghostty
        _ = ghostty_mouse_encoder_set(probeHandle.raw, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &probeSize)
        var event: GhosttyMouseEvent?
        try ghosttyCheck(ghostty_mouse_event_new(nil, &event), "ghostty_mouse_event_new")
        guard let event else {
            throw GhosttyCallError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_mouse_event_new")
        }
        self.event = event
        self.geometry = geometry
        applyGeometry()
    }

    deinit { ghostty_mouse_event_free(event) }

    /// Pushes the geometry to the encoder and to every press's encoder, so a release after a
    /// resize lands in the right cell.
    private func applyGeometry() {
        var size = geometry.ghostty
        for encoder in [handle] + Array(pressEncodings.values) {
            _ = ghostty_mouse_encoder_set(encoder.raw, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        }
    }

    /// Forget motion de-duplication state and which buttons are held. Call on focus loss and when
    /// the terminal is reset.
    func reset() {
        pressEncodings.removeAll()
        lastMotion = nil
        _ = ghostty_mouse_encoder_reset(handle.raw)
    }

    /// Will libghostty report a press? That is, is a mouse tracking mode in force?
    ///
    /// Read from the flags, as the encoder encodes, not from the mode bits: after
    /// `?1000h ?1003h ?1003l` the bits still say 1000, but nothing is reported, so this is false
    /// and a click selects. The view routes clicks and hovers by it, and the wheel decides
    /// between reporting and scrolling by it. Caller holds the terminal lock.
    func isReporting(terminal: VtTerminal) -> Bool {
        currentProbe(terminal).reportsPresses
    }

    /// The probe as of the last write, made now if there has been none since this encoder was.
    private func currentProbe(_ terminal: VtTerminal) -> ReportProbe {
        if let probe { return probe }
        return refreshProbe(terminal)
    }

    /// Probes the flags again, and forgets the last motion if they changed.
    @discardableResult
    private func refreshProbe(_ terminal: VtTerminal) -> ReportProbe {
        let fresh = probeReports(terminal)
        if fresh != probe {
            probe = fresh
            lastMotion = nil
        }
        return fresh
    }

    /// Encodes the four probe events under the terminal's flags. An event the encoder fails on is
    /// one it would not report, so it counts as unreported.
    private func probeReports(_ terminal: VtTerminal) -> ReportProbe {
        _ = ghostty_mouse_encoder_set_from_terminal(probeHandle.raw, terminal)
        let point = Self.probePoint
        let press = try? encodeEvent(
            MousePress(action: .press, button: .left, position: point), with: probeHandle, anyPressed: true)
        // No tracking mode reports a release or a move without reporting the press.
        guard press != nil else { return .silent }
        let release = try? encodeEvent(
            MousePress(action: .release, button: .left, position: point), with: probeHandle, anyPressed: false)
        let drag = try? encodeEvent(
            MousePress(action: .motion, button: .left, position: point), with: probeHandle, anyPressed: true)
        let hover = try? encodeEvent(
            MousePress(action: .motion, button: nil, position: point), with: probeHandle, anyPressed: false)
        return ReportProbe(press: press, release: release, drag: drag, hover: hover)
    }

    /// Sets the encoder from the terminal's current mouse flags. Every event runs this first.
    /// Caller holds the lock.
    private func syncFromTerminal(_ terminal: VtTerminal) {
        _ = ghostty_mouse_encoder_set_from_terminal(handle.raw, terminal)
        _ = currentProbe(terminal)
    }

    /// Probes the terminal's mouse flags again. The binding calls this after the terminal has
    /// parsed program output or been reset, so tracking that goes off and on again in two writes
    /// between events still forgets the last motion, even when no mode bit changes:
    /// `?1000l` with 1000 never set turns tracking off, and `?1003h` with 1003 still set turns it
    /// back on. The view sends the encoder no events while tracking is off, so the events alone
    /// would never see the gap. Caller holds the lock.
    func terminalModesMayHaveChanged(_ terminal: VtTerminal) {
        refreshProbe(terminal)
    }

    /// A new encoder set from `terminal` as it is now, with this encoder's size: the record of
    /// the encoding a press went out under. nil, logged, if it cannot be made.
    private func pressEncoder(from terminal: VtTerminal) -> GhosttyMouseEncoderHandle? {
        do {
            let encoder = try GhosttyMouseEncoderHandle()
            _ = ghostty_mouse_encoder_set_from_terminal(encoder.raw, terminal)
            var size = geometry.ghostty
            _ = ghostty_mouse_encoder_set(encoder.raw, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
            return encoder
        } catch {
            terminalEngineLog.error(
                "recording a press's encoding failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Encode one pointer event using the terminal's current tracking mode and report format.
    ///
    /// Returns `nil` when the terminal wants no report at all — tracking off, a motion event in a
    /// mode that only reports buttons, or a motion whose report repeats the last one (see
    /// `lastMotion`), or a release whose press was not reported. A release of a press that was
    /// reported is encoded as the press was, so it goes out even if the program has since turned
    /// reporting off.
    ///
    /// Every report goes through here, the view's and `GhosttyTerminal.encodeMouse`'s alike, so
    /// this is the one place repeated motion is dropped. Caller holds the terminal lock.
    func encode(_ press: MousePress, terminal: VtTerminal) throws -> [UInt8]? {
        syncFromTerminal(terminal)

        switch press.action {
        case .press:
            lastMotion = nil
            guard let button = press.button else { return try encodeEvent(press, with: handle) }
            pressEncodings[button] = nil
            // The encoder is told this button is down while it encodes the press itself.
            let bytes = try encodeEvent(press, with: handle, anyPressed: true)
            // Only a reported press earns a release, and only a reported press is held. Without
            // its own encoder, the release goes out under the flags in force when it comes.
            if bytes != nil { pressEncodings[button] = pressEncoder(from: terminal) ?? handle }
            return bytes

        case .release:
            lastMotion = nil
            guard let button = press.button else { return try encodeEvent(press, with: handle) }
            // A press that went out unreported has nothing to close, even if the program has
            // turned reporting on since: a release alone would tell it a button came up that it
            // never saw go down.
            guard let encoder = pressEncodings.removeValue(forKey: button) else { return nil }
            return try encodeEvent(press, with: encoder)

        case .motion:
            guard let bytes = try encodeEvent(press, with: handle), bytes != lastMotion else { return nil }
            lastMotion = bytes
            return bytes
        }
    }

    /// Hands `press` to libghostty through `encoder`, whose options are already set, and returns
    /// the report it wrote. nil when it wrote none. `anyPressed` defaults to whether any button is
    /// held, which a release has already left; a press passes true itself.
    private func encodeEvent(
        _ press: MousePress, with encoder: GhosttyMouseEncoderHandle, anyPressed: Bool? = nil
    ) throws -> [UInt8]? {
        var pressed = anyPressed ?? !pressEncodings.isEmpty
        _ = ghostty_mouse_encoder_set(encoder.raw, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)

        _ = ghostty_mouse_event_set_action(event, press.action.ghostty)
        if let button = press.button {
            _ = ghostty_mouse_event_set_button(event, button.ghostty)
        } else {
            _ = ghostty_mouse_event_clear_button(event)
        }
        _ = ghostty_mouse_event_set_mods(event, press.mods.ghostty)
        _ = ghostty_mouse_event_set_position(
            event,
            GhosttyMousePosition(x: Float(press.position.x), y: Float(press.position.y))
        )

        // Fast path: a report never exceeds a few dozen bytes. Retry once if the library disagrees.
        var stack = [UInt8](repeating: 0, count: 64)
        var written = 0
        var result = stack.withUnsafeMutableBufferPointer { buffer in
            ghostty_mouse_encoder_encode(encoder.raw, event, buffer.baseAddress, buffer.count, &written)
        }
        if result == GHOSTTY_OUT_OF_SPACE {
            var heap = [UInt8](repeating: 0, count: written)
            result = heap.withUnsafeMutableBufferPointer { buffer in
                ghostty_mouse_encoder_encode(encoder.raw, event, buffer.baseAddress, buffer.count, &written)
            }
            try ghosttyCheck(result, "ghostty_mouse_encoder_encode")
            guard written > 0 else { return nil }
            return Array(heap.prefix(written))
        }
        try ghosttyCheck(result, "ghostty_mouse_encoder_encode")
        guard written > 0 else { return nil }
        return Array(stack.prefix(written))
    }

    /// Where wheel rows go under `terminal`'s modes as they stand: reports while libghostty
    /// reports the mouse, by the flags rather than the mode bits, then alternate scroll on the
    /// alternate screen, then the viewport. `wheel` goes by it, and the view reads it to choose
    /// its arithmetic. Caller holds the terminal lock.
    func wheelRoute(terminal: VtTerminal) -> WheelRoute {
        if isReporting(terminal: terminal) { return .reports }
        return GhosttyTerminalState(raw: terminal).isAlternateScreen ? .alternateScroll : .viewport
    }

    /// Turn accumulated whole rows of scrolling into mouse reports, arrow keys or a viewport scroll.
    ///
    /// - Parameter rows: whole rows to scroll; **negative = up**, matching
    ///   `GHOSTTY_SCROLL_VIEWPORT_DELTA` ("up is negative"). Feed it from `ScrollAccumulator`.
    ///
    /// The order is Ghostty's own (`Surface.zig`, `scrollCallback`), as `wheelRoute` gives it:
    ///   * With tracking on, one *press* report per row is due for button four (up) / five (down);
    ///     that is what xterm-style wheel reporting is — see the measured bytes in the tests. Every
    ///     row's report is the same press in the same cell, so it is encoded once and counted.
    ///   * Otherwise, on the alternate screen, the wheel is arrow keys when the program has
    ///     alternate scroll (`?1007`) set, which is how `less`, `man` and vim scroll by wheel, and
    ///     nothing when it has not: the alternate screen has no scrollback to move through.
    ///   * Otherwise the viewport is scrolled and no bytes are produced.
    ///
    /// Caller holds the terminal lock.
    func wheel(
        rows: Int,
        at position: SurfacePoint,
        mods: TerminalModifiers = [],
        terminal: VtTerminal
    ) throws -> WheelOutcome {
        guard rows != 0 else { return .none }

        switch wheelRoute(terminal: terminal) {
        case .alternateScroll:
            // Arrow keys here match SwiftTerm's own view, and are what makes the wheel work in
            // less and vim. The app has its own policy for these events, which drops them where
            // arrow keys typed into an agent's composer would recall its history. Its scroll
            // monitor (`ScrollWheelAccumulator`) sits in front of the terminal view on every
            // transport, and once this engine is wired in it will sit in front of this view
            // too, so the app's policy applies there and this path is the view's own fallback.
            let state = GhosttyTerminalState(raw: terminal)
            guard state.mode(Self.alternateScrollMode) else { return .none }
            let key = Self.alternateScrollKey(
                up: rows < 0, applicationCursorKeys: state.mode(Self.applicationCursorKeysMode))
            return .cursorKeys(key: key, count: abs(rows))
        case .viewport:
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = rows
            _ = ghostty_terminal_scroll_viewport(terminal, behavior)
            return .scrolledViewport(rows: rows)
        case .reports:
            break
        }

        syncFromTerminal(terminal)
        lastMotion = nil
        let press = MousePress(action: .press, button: rows < 0 ? .four : .five, mods: mods, position: position)
        // A wheel "click" is a press with no release. It goes straight to the encoder, so it never
        // joins `pressEncodings`, where it would count as a held button. The encoder is still told
        // a button is down, as for any press.
        guard let report = try encodeEvent(press, with: handle, anyPressed: true), !report.isEmpty else {
            return .none
        }
        return .report(press: report, count: abs(rows))
    }

    // MARK: Alternate scroll

    /// DEC private mode 1007, alternate scroll. On in a new terminal, as in Ghostty and SwiftTerm.
    static let alternateScrollMode: UInt16 = 1007
    /// DEC private mode 1, DECCKM: the cursor keys send `ESC O A` rather than `ESC [ A`.
    static let applicationCursorKeysMode: UInt16 = 1

    /// The key one row of wheel scrolling types under alternate scroll: cursor up or cursor down.
    /// Under DECCKM it is the application form, as the real key is.
    static func alternateScrollKey(up: Bool, applicationCursorKeys: Bool) -> [UInt8] {
        [0x1B, UInt8(ascii: applicationCursorKeys ? "O" : "["), UInt8(ascii: up ? "A" : "B")]
    }
}

extension MouseAction {
    var ghostty: GhosttyMouseAction {
        switch self {
        case .press: GHOSTTY_MOUSE_ACTION_PRESS
        case .release: GHOSTTY_MOUSE_ACTION_RELEASE
        case .motion: GHOSTTY_MOUSE_ACTION_MOTION
        }
    }
}
