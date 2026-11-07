// Adapted from tkzmux c961533 Sources/TkzTerminalCore/MouseEncoder.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// MouseEncoder.swift — mouse events → terminal reports (libghostty-vt `mouse/encoder.h`).
//
// One of the files allowed to call the C API directly.
// Deliberately lives in TkzTerminalCore, not TkzTerminalView, so it unit-tests without AppKit:
// the view layer translates `NSEvent` into the plain-data `MousePress` below and nothing else.
//
// Threading: `MouseEncoder` is a non-Sendable class, like the handles it wraps. `TerminalSession`
// owns one per session and serialises every call under its lock.
import GhosttyVt

// MARK: - Plain data the view layer supplies

/// What the pointer did. Mirrors `GhosttyMouseAction`.
public enum MouseAction: Sendable, Equatable {
    case press, release, motion
}

/// Which button. Mirrors `GhosttyMouseButton` (the wheel is buttons four/five).
public enum MouseButton: Sendable, Equatable {
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
public struct TerminalModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let shift = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
    public static let control = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL))
    /// macOS Option / Alt.
    public static let option = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_ALT))
    /// macOS Command / Super.
    public static let command = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER))
    public static let capsLock = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_CAPS_LOCK))
    public static let numLock = TerminalModifiers(rawValue: UInt16(GHOSTTY_MODS_NUM_LOCK))

    var ghostty: GhosttyMods { rawValue }
}

/// A pointer position in *surface* pixels — (0, 0) at the top-left of the terminal view,
/// **before** any padding is subtracted. The encoder does the pixel → cell conversion itself
/// from `MouseEncoder.geometry`, so the view must not pre-divide by the cell size.
public struct SurfacePoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One normalised pointer event. Despite the name it covers press, release *and* motion —
/// `action` says which. Everything the AppKit layer must fill in is here and nowhere else.
public struct MousePress: Sendable, Equatable {
    public var action: MouseAction
    /// For press/release, the button that changed. For **motion**, the button currently held —
    /// button-event tracking (mode 1002) encodes it into the drag report, so `mouseDragged` must
    /// pass it; `nil` (no button) is right only for a hover in any-event tracking (mode 1003).
    public var button: MouseButton?
    public var mods: TerminalModifiers
    /// Surface-space pixels (see `SurfacePoint`). `GhosttyMousePosition` is `float`; the
    /// conversion happens at the boundary, so callers keep AppKit's `CGFloat` precision here.
    public var position: SurfacePoint

    public init(
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
public struct TerminalPixelGeometry: Sendable, Equatable {
    public var screenWidth: UInt32
    public var screenHeight: UInt32
    public var cellWidth: UInt32
    public var cellHeight: UInt32
    public var paddingTop: UInt32
    public var paddingBottom: UInt32
    public var paddingLeft: UInt32
    public var paddingRight: UInt32

    public init(
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
/// keeps one per session (`var accumulator = ScrollAccumulator()`).
public struct ScrollAccumulator: Sendable, Equatable {
    /// Unconsumed fraction of a row. Positive = downward.
    public private(set) var remainder: Double = 0

    public init() {}

    /// Add `pixels` of vertical scroll (positive = content scrolls *down*, i.e. `NSEvent`'s
    /// `-scrollingDeltaY`) and return the whole rows now due. The fraction is carried over.
    public mutating func consume(pixels: Double, cellHeight: Double) -> Int {
        guard cellHeight > 0, pixels.isFinite else { return 0 }
        return consume(rows: pixels / cellHeight)
    }

    /// Add `rows` (may be fractional) and return the whole rows now due.
    public mutating func consume(rows: Double) -> Int {
        guard rows.isFinite else { return 0 }
        remainder += rows
        let whole = remainder < 0 ? remainder.rounded(.up) : remainder.rounded(.down)
        remainder -= whole
        return Int(whole)
    }

    /// Drop the carried fraction — call at the end of a scroll gesture (`NSEvent.phase == .ended`)
    /// so a new flick starts clean.
    public mutating func reset() { remainder = 0 }
}

/// What a wheel event should do, decided by `MouseEncoder.wheel(rows:…)`.
public enum WheelOutcome: Sendable, Equatable {
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
/// Not `Sendable`: the C objects are not thread-safe. `TerminalSession` guards it with its lock.
public final class MouseEncoder {
    private let handle: GhosttyMouseEncoderHandle
    private let event: GhosttyMouseEvent
    /// Buttons currently held. `setopt_from_terminal` explicitly does *not* touch
    /// `OPT_ANY_BUTTON_PRESSED`, so the encoder has to keep this itself and push it on every
    /// encode. Internal rather than private so tests can assert it never leaks a wheel "press".
    private(set) var heldButtons: Set<MouseButton> = []

    /// Rendered geometry. Assign on every resize; it is pushed to `OPT_SIZE` immediately.
    public var geometry: TerminalPixelGeometry {
        didSet { applyGeometry() }
    }

    public init(geometry: TerminalPixelGeometry) throws {
        handle = try GhosttyMouseEncoderHandle()
        var event: GhosttyMouseEvent?
        try ghosttyCheck(ghostty_mouse_event_new(nil, &event), "ghostty_mouse_event_new")
        guard let event else {
            throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_mouse_event_new")
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
    public func reset() {
        heldButtons.removeAll()
        _ = ghostty_mouse_encoder_reset(handle.raw)
    }

    /// Is any mouse tracking mode (X10 / normal / button / any-event) active?
    ///
    /// The view layer uses this to decide reporting-vs-selection: report unless Shift is held.
    /// Caller holds the terminal lock.
    public static func isTrackingEnabled(_ terminal: GhosttyTerminalHandle) -> Bool {
        var tracking = false
        guard ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking) == GHOSTTY_SUCCESS
        else { return false }
        return tracking
    }

    /// Is the viewport pinned to the active area? `false` means the user has scrolled into
    /// history — the view layer uses it to decide whether to jump to the bottom on key input.
    /// Caller holds the terminal lock.
    public static func isViewportPinned(_ terminal: GhosttyTerminalHandle) -> Bool {
        var pinned = false
        guard ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &pinned) == GHOSTTY_SUCCESS
        else { return true }
        return pinned
    }

    /// Encode one pointer event using the terminal's current tracking mode and report format.
    ///
    /// Returns `nil` when the terminal wants no report at all — tracking off, a motion event in a
    /// mode that only reports buttons, or a motion that stayed inside the same cell.
    /// Caller holds the terminal lock.
    public func encode(_ press: MousePress, terminal: GhosttyTerminalHandle) throws -> [UInt8]? {
        // Options (tracking mode + format) come from the terminal; size and any-button do not.
        _ = ghostty_mouse_encoder_set_from_terminal(handle.raw, terminal.raw)

        switch press.action {
        case .press: if let button = press.button { heldButtons.insert(button) }
        case .release: if let button = press.button { heldButtons.remove(button) }
        case .motion: break
        }
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
    public func wheel(
        rows: Int,
        at position: SurfacePoint,
        mods: TerminalModifiers = [],
        terminal: GhosttyTerminalHandle
    ) throws -> WheelOutcome {
        guard rows != 0 else { return .none }

        guard Self.isTrackingEnabled(terminal) else {
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = rows
            _ = ghostty_terminal_scroll_viewport(terminal.raw, behavior)
            return .scrolledViewport(rows: rows)
        }

        let button: MouseButton = rows < 0 ? .four : .five
        var bytes: [UInt8] = []
        for _ in 0..<abs(rows) {
            // A wheel "click" is a press with no matching release; do not let it leak into
            // `heldButtons`, or button-event motion tracking would think a button is held.
            let press = MousePress(action: .press, button: button, mods: mods, position: position)
            let held = heldButtons
            if let encoded = try encode(press, terminal: terminal) { bytes += encoded }
            heldButtons = held
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
