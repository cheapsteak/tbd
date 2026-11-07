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
enum MouseAction: Sendable, Equatable {
    case press, release, motion
}

/// Which button. Mirrors `GhosttyMouseButton` (the wheel is buttons four/five).
enum MouseButton: Sendable, Equatable {
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
struct TerminalModifiers: OptionSet, Sendable, Equatable {
    let rawValue: UInt16
    init(rawValue: UInt16) { self.rawValue = rawValue }

    static let shift = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
    static let control = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL))
    /// macOS Option / Alt.
    static let option = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_ALT))
    /// macOS Command / Super.
    static let command = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER))
    static let capsLock = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_CAPS_LOCK))
    static let numLock = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_NUM_LOCK))

    var ghostty: GhosttyMods { rawValue }
}

/// A pointer position in *surface* pixels — (0, 0) at the top-left of the terminal view,
/// **before** any padding is subtracted. The encoder does the pixel → cell conversion itself
/// from `MouseEncoder.geometry`, so the view must not pre-divide by the cell size.
struct SurfacePoint: Sendable, Equatable {
    var x: Double
    var y: Double
    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One normalised pointer event. Despite the name it covers press, release *and* motion —
/// `action` says which. Everything the AppKit layer must fill in is here and nowhere else.
struct MousePress: Sendable, Equatable {
    var action: MouseAction
    /// For press/release, the button that changed. For **motion**, the button currently held —
    /// button-event tracking (mode 1002) encodes it into the drag report, so `mouseDragged` must
    /// pass it; `nil` (no button) is right only for a hover in any-event tracking (mode 1003).
    var button: MouseButton?
    var mods: TerminalModifiers
    /// Surface-space pixels (see `SurfacePoint`). `GhosttyMousePosition` is `float`; the
    /// conversion happens at the boundary, so callers keep AppKit's `CGFloat` precision here.
    var position: SurfacePoint

    init(
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
struct TerminalPixelGeometry: Sendable, Equatable {
    var screenWidth: UInt32
    var screenHeight: UInt32
    var cellWidth: UInt32
    var cellHeight: UInt32
    var paddingTop: UInt32
    var paddingBottom: UInt32
    var paddingLeft: UInt32
    var paddingRight: UInt32

    init(
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
struct ScrollAccumulator: Sendable, Equatable {
    /// Unconsumed fraction of a row. Positive = downward.
    private(set) var remainder: Double = 0

    init() {}

    /// Add `pixels` of vertical scroll (positive = content scrolls *down*, i.e. `NSEvent`'s
    /// `-scrollingDeltaY`) and return the whole rows now due. The fraction is carried over.
    mutating func consume(pixels: Double, cellHeight: Double) -> Int {
        guard cellHeight > 0, pixels.isFinite else { return 0 }
        return consume(rows: pixels / cellHeight)
    }

    /// Add `rows` (may be fractional) and return the whole rows now due.
    mutating func consume(rows: Double) -> Int {
        guard rows.isFinite else { return 0 }
        remainder += rows
        let whole = remainder < 0 ? remainder.rounded(.up) : remainder.rounded(.down)
        remainder -= whole
        return Int(whole)
    }

    /// Drop the carried fraction — call at the end of a scroll gesture (`NSEvent.phase == .ended`)
    /// so a new flick starts clean.
    mutating func reset() { remainder = 0 }
}

/// What a wheel event should do, decided by `MouseEncoder.wheel(rows:…)`.
enum WheelOutcome: Sendable, Equatable {
    /// Nothing to do (zero rows, or the terminal wanted no report).
    case none
    /// Write these bytes to the pty (mouse tracking is on).
    case report([UInt8])
    /// Mouse tracking is off and the viewport was scrolled by this many rows (negative = up).
    case scrolledViewport(rows: Int)
}

// MARK: - The encoder

/// Wraps `GhosttyMouseEncoder` plus one reusable `GhosttyMouseEvent`.
///
/// Not `Sendable`: the C objects are not thread-safe. Only used under the terminal's lock.
final class MouseEncoder {
    private let handle: GhosttyMouseEncoderHandle
    private let event: GhosttyMouseEvent
    /// Buttons currently held. `setopt_from_terminal` explicitly does *not* touch
    /// `OPT_ANY_BUTTON_PRESSED`, so the encoder has to keep this itself and push it on every
    /// encode. Internal rather than private so tests can assert it never leaks a wheel "press".
    private(set) var heldButtons: Set<MouseButton> = []
    /// The encoding each reported, still-held button was pressed under. A program can turn
    /// reporting off while a button is down; the press already went out, so its release must go
    /// out too, encoded as the press was.
    private(set) var pressEncodings: [MouseButton: ReportEncoding] = [:]

    /// The tracking mode and report format an event is encoded under.
    struct ReportEncoding: Equatable {
        var tracking: GhosttyMouseTrackingMode
        var format: GhosttyMouseFormat
    }

    /// The DEC private modes the encoder's options come from: four tracking modes and four report
    /// formats. `set_from_terminal` reads the same state, but libghostty has no getter for it.
    struct MouseModes: OptionSet, Sendable {
        let rawValue: UInt8

        init(rawValue: UInt8) { self.rawValue = rawValue }

        static let x10 = MouseModes(rawValue: 1 << 0)
        static let normal = MouseModes(rawValue: 1 << 1)
        static let button = MouseModes(rawValue: 1 << 2)
        static let any = MouseModes(rawValue: 1 << 3)
        static let utf8 = MouseModes(rawValue: 1 << 4)
        static let sgr = MouseModes(rawValue: 1 << 5)
        static let urxvt = MouseModes(rawValue: 1 << 6)
        static let sgrPixels = MouseModes(rawValue: 1 << 7)

        private static let numbers: [(mode: MouseModes, number: UInt16)] = [
            (.x10, 9), (.normal, 1000), (.button, 1002), (.any, 1003),
            (.utf8, 1005), (.sgr, 1006), (.urxvt, 1015), (.sgrPixels, 1016),
        ]

        /// The modes `terminal` has set. Caller holds the lock.
        init(of terminal: VtTerminal) {
            var modes: MouseModes = []
            for entry in Self.numbers {
                var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(entry.number, false), value: false)
                if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS,
                   config.value {
                    modes.insert(entry.mode)
                }
            }
            self = modes
        }

        /// The tracking mode and format these modes imply. When a program has set several
        /// tracking modes the widest wins, as programs enable them narrowest first; likewise for
        /// the formats.
        var encoding: ReportEncoding {
            var encoding = ReportEncoding(tracking: GHOSTTY_MOUSE_TRACKING_NONE, format: GHOSTTY_MOUSE_FORMAT_X10)
            if contains(.any) {
                encoding.tracking = GHOSTTY_MOUSE_TRACKING_ANY
            } else if contains(.button) {
                encoding.tracking = GHOSTTY_MOUSE_TRACKING_BUTTON
            } else if contains(.normal) {
                encoding.tracking = GHOSTTY_MOUSE_TRACKING_NORMAL
            } else if contains(.x10) {
                encoding.tracking = GHOSTTY_MOUSE_TRACKING_X10
            }
            if contains(.sgrPixels) {
                encoding.format = GHOSTTY_MOUSE_FORMAT_SGR_PIXELS
            } else if contains(.sgr) {
                encoding.format = GHOSTTY_MOUSE_FORMAT_SGR
            } else if contains(.urxvt) {
                encoding.format = GHOSTTY_MOUSE_FORMAT_URXVT
            } else if contains(.utf8) {
                encoding.format = GHOSTTY_MOUSE_FORMAT_UTF8
            }
            return encoding
        }
    }

    /// The modes the encoder's options were last set from, or nil when they were set some other
    /// way. A change of modes ends `lastMotion`, so the modes are compared here rather than set
    /// from the terminal again on every event.
    private var syncedModes: MouseModes?

    /// A motion report that went out, and the tracking mode and format it went out under.
    private struct ReportedMotion: Equatable {
        var bytes: [UInt8]
        var encoding: ReportEncoding
    }

    /// The last motion report sent since the last press, release, mode change or resize. A motion
    /// whose report repeats it is dropped: the bytes carry the cell, the button bits and the
    /// modifiers, so under the same mode the program would learn nothing from it. SGR-Pixels
    /// reports carry pixels, so every pixel of motion still goes out there, as the mode asks.
    // libghostty-vt drops repeats only with OPT_TRACK_LAST_CELL, off by default and keyed on the cell alone.
    private var lastMotion: ReportedMotion?

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

    private func applyGeometry() {
        var size = geometry.ghostty
        _ = ghostty_mouse_encoder_set(handle.raw, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
    }

    /// Forget motion de-duplication state and which buttons are held. Call on focus loss and when
    /// the terminal is reset.
    func reset() {
        heldButtons.removeAll()
        pressEncodings.removeAll()
        lastMotion = nil
        _ = ghostty_mouse_encoder_reset(handle.raw)
    }

    /// Is any mouse tracking mode (X10 / normal / button / any-event) active?
    ///
    /// The view layer uses this to decide reporting-vs-selection: report unless Shift is held.
    /// Caller holds the terminal lock.
    static func isTrackingEnabled(_ terminal: VtTerminal) -> Bool {
        var tracking = false
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking) == GHOSTTY_SUCCESS
        else { return false }
        return tracking
    }

    /// Sets the encoder's tracking mode and format from `terminal` if its mouse modes differ
    /// from the ones they were last set from. Caller holds the lock.
    private func syncModes(_ modes: MouseModes, terminal: VtTerminal) {
        guard modes != syncedModes else { return }
        _ = ghostty_mouse_encoder_set_from_terminal(handle.raw, terminal)
        syncedModes = modes
        lastMotion = nil
    }

    /// Re-reads the terminal's mouse modes. The binding calls this after the terminal has parsed
    /// program output or been reset, so a mode the program turns off and on again in two writes
    /// between events still forgets the last motion. The view sends the encoder no events while
    /// tracking is off, so the events alone would never see the gap. Caller holds the lock.
    func terminalModesMayHaveChanged(_ terminal: VtTerminal) {
        syncModes(MouseModes(of: terminal), terminal: terminal)
    }

    private func apply(_ encoding: ReportEncoding) {
        var tracking = encoding.tracking
        _ = ghostty_mouse_encoder_set(handle.raw, GHOSTTY_MOUSE_ENCODER_OPT_EVENT, &tracking)
        var format = encoding.format
        _ = ghostty_mouse_encoder_set(handle.raw, GHOSTTY_MOUSE_ENCODER_OPT_FORMAT, &format)
        // Set by hand, so the next event sets them from the terminal again.
        syncedModes = nil
    }

    /// Encode one pointer event using the terminal's current tracking mode and report format.
    ///
    /// Returns `nil` when the terminal wants no report at all — tracking off, a motion event in a
    /// mode that only reports buttons, or a motion whose report repeats the last one (see
    /// `lastMotion`). The one exception is the release of a press that was reported: that goes out
    /// even if the program has since turned tracking off, in the encoding the press had.
    ///
    /// Every report goes through here, the view's and `GhosttyTerminal.encodeMouse`'s alike, so
    /// this is the one place repeated motion is dropped. Caller holds the terminal lock.
    func encode(_ press: MousePress, terminal: VtTerminal) throws -> [UInt8]? {
        // Options (tracking mode + format) come from the terminal, and are set again only when its
        // mouse modes changed; size and any-button do not come from it.
        let modes = MouseModes(of: terminal)
        syncModes(modes, terminal: terminal)

        switch press.action {
        case .press:
            lastMotion = nil
            if let button = press.button {
                heldButtons.insert(button)
                pressEncodings[button] = Self.isTrackingEnabled(terminal) ? modes.encoding : nil
            }
        case .release:
            lastMotion = nil
            if let button = press.button {
                heldButtons.remove(button)
                if let pressed = pressEncodings.removeValue(forKey: button), !Self.isTrackingEnabled(terminal) {
                    apply(pressed)
                }
            }
        case .motion: break
        }
        guard let bytes = try encodeEvent(press) else { return nil }
        guard press.action == .motion else { return bytes }
        let motion = ReportedMotion(bytes: bytes, encoding: modes.encoding)
        guard motion != lastMotion else { return nil }
        lastMotion = motion
        return bytes
    }

    /// Hands `press` to libghostty under the options already set, and returns the report it
    /// wrote. nil when it wrote none.
    private func encodeEvent(_ press: MousePress) throws -> [UInt8]? {
        var anyPressed = !heldButtons.isEmpty
        _ = ghostty_mouse_encoder_set(handle.raw, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &anyPressed)

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
            ghostty_mouse_encoder_encode(handle.raw, event, buffer.baseAddress, buffer.count, &written)
        }
        if result == GHOSTTY_OUT_OF_SPACE {
            var heap = [UInt8](repeating: 0, count: written)
            result = heap.withUnsafeMutableBufferPointer { buffer in
                ghostty_mouse_encoder_encode(handle.raw, event, buffer.baseAddress, buffer.count, &written)
            }
            try ghosttyCheck(result, "ghostty_mouse_encoder_encode")
            guard written > 0 else { return nil }
            return Array(heap.prefix(written))
        }
        try ghosttyCheck(result, "ghostty_mouse_encoder_encode")
        guard written > 0 else { return nil }
        return Array(stack.prefix(written))
    }

    /// Turn accumulated whole rows of scrolling into either mouse reports or a viewport scroll.
    ///
    /// - Parameter rows: whole rows to scroll; **negative = up**, matching
    ///   `GHOSTTY_SCROLL_VIEWPORT_DELTA` ("up is negative"). Feed it from `ScrollAccumulator`.
    ///
    /// With tracking on, one *press* report per row is emitted for button four (up) / five (down);
    /// that is what xterm-style wheel reporting is — see the measured bytes in the tests.
    /// With tracking off the viewport is scrolled instead and no bytes are produced.
    /// Caller holds the terminal lock.
    func wheel(
        rows: Int,
        at position: SurfacePoint,
        mods: TerminalModifiers = [],
        terminal: VtTerminal
    ) throws -> WheelOutcome {
        guard rows != 0 else { return .none }

        guard Self.isTrackingEnabled(terminal) else {
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = rows
            _ = ghostty_terminal_scroll_viewport(terminal, behavior)
            return .scrolledViewport(rows: rows)
        }

        let button: MouseButton = rows < 0 ? .four : .five
        var bytes: [UInt8] = []
        for _ in 0..<abs(rows) {
            // A wheel "click" is a press with no matching release; do not let it leak into
            // `heldButtons`, or button-event motion tracking would think a button is held, nor
            // into `pressEncodings`.
            let press = MousePress(action: .press, button: button, mods: mods, position: position)
            let held = heldButtons
            let encodings = pressEncodings
            if let encoded = try encode(press, terminal: terminal) { bytes += encoded }
            heldButtons = held
            pressEncodings = encodings
        }
        return bytes.isEmpty ? .none : .report(bytes)
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
