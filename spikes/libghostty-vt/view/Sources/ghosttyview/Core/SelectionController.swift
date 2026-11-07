// Adapted from tkzmux c961533 Sources/TkzTerminalCore/SelectionController.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// SelectionController.swift — pointer gestures → terminal selection (libghostty-vt `selection.h`).
//
// One of the files allowed to call the C API directly.
// Headless on purpose: no AppKit, so the whole gesture state machine unit-tests. The view layer
// supplies surface pixels, a monotonic timestamp and the double-click interval; it owns the
// autoscroll *timer*, this file owns the autoscroll *policy*.
import GhosttyVt

/// Which coordinate space a grid point is expressed in. Mirrors `GhosttyPointTag`.
public enum TerminalPointSpace: Sendable, Equatable {
    /// The active (bottom) area — never includes scrollback.
    case active
    /// What is currently visible. This is what pointer positions map to.
    case viewport
    /// Whole screen incl. scrollback; resolving these traverses the page list and is slow.
    case screen
    /// Scrollback only; also slow.
    case history

    var ghostty: GhosttyPointTag {
        switch self {
        case .active: GHOSTTY_POINT_TAG_ACTIVE
        case .viewport: GHOSTTY_POINT_TAG_VIEWPORT
        case .screen: GHOSTTY_POINT_TAG_SCREEN
        case .history: GHOSTTY_POINT_TAG_HISTORY
        }
    }
}

/// A cell coordinate in one of the terminal's coordinate spaces.
public struct TerminalGridPoint: Sendable, Equatable {
    /// Column, 0-indexed.
    public var x: UInt16
    /// Row, 0-indexed. `UInt32` because screen/history rows may exceed a page.
    public var y: UInt32
    public var space: TerminalPointSpace

    public init(x: UInt16, y: UInt32, space: TerminalPointSpace = .viewport) {
        self.x = x
        self.y = y
        self.space = space
    }

    var ghostty: GhosttyPoint {
        GhosttyPoint(
            tag: space.ghostty,
            value: GhosttyPointValue(coordinate: GhosttyPointCoordinate(x: x, y: y))
        )
    }
}

/// Selection granularity for one click of a sequence. Mirrors `GhosttySelectionGestureBehavior`.
public enum SelectionBehavior: Sendable, Equatable {
    case cell, word, line, output

    var ghostty: GhosttySelectionGestureBehavior {
        switch self {
        case .cell: GHOSTTY_SELECTION_GESTURE_BEHAVIOR_CELL
        case .word: GHOSTTY_SELECTION_GESTURE_BEHAVIOR_WORD
        case .line: GHOSTTY_SELECTION_GESTURE_BEHAVIOR_LINE
        case .output: GHOSTTY_SELECTION_GESTURE_BEHAVIOR_OUTPUT
        }
    }
}

/// Single / double / triple click granularity. The default is:
/// single = cell, double = word, triple = line.
public struct SelectionBehaviors: Sendable, Equatable {
    public var singleClick: SelectionBehavior
    public var doubleClick: SelectionBehavior
    public var tripleClick: SelectionBehavior

    public init(
        singleClick: SelectionBehavior = .cell,
        doubleClick: SelectionBehavior = .word,
        tripleClick: SelectionBehavior = .line
    ) {
        self.singleClick = singleClick
        self.doubleClick = doubleClick
        self.tripleClick = tripleClick
    }

    public static let `default` = SelectionBehaviors()

    var ghostty: GhosttySelectionGestureBehaviors {
        GhosttySelectionGestureBehaviors(
            single_click: singleClick.ghostty,
            double_click: doubleClick.ghostty,
            triple_click: tripleClick.ghostty
        )
    }
}

/// Whether a drag has left the viewport, and in which direction.
public enum SelectionAutoscroll: Sendable, Equatable {
    case none, up, down
}

/// How far one autoscroll timer tick scrolls. The timer itself lives in the view layer; this
/// value type is the policy, so it is testable on its own.
public struct AutoscrollPolicy: Sendable, Equatable {
    /// Rows scrolled per tick.
    public var rowsPerTick: Int

    public init(rowsPerTick: Int = 1) {
        self.rowsPerTick = max(1, rowsPerTick)
    }

    /// Signed rows for `GHOSTTY_SCROLL_VIEWPORT_DELTA` (negative = up), 0 when idle.
    public func rows(for direction: SelectionAutoscroll) -> Int {
        switch direction {
        case .none: 0
        case .up: -rowsPerTick
        case .down: rowsPerTick
        }
    }
}

/// Drives one session's text selection.
///
/// Not `Sendable`: `GhosttySelectionGesture` is not thread-safe and its grid references are only
/// valid until the next mutating terminal call. `TerminalSession` guards it with its lock, and
/// every method here assumes the caller already holds it.
///
/// The controller keeps a **strong** reference to the terminal handle because
/// `ghostty_selection_gesture_free` needs the live terminal to release its tracked refs.
public final class SelectionController {
    private let terminal: GhosttyTerminalHandle
    private let gesture: GhosttySelectionGesture
    private let pressEvent: GhosttySelectionGestureEvent
    private let dragEvent: GhosttySelectionGestureEvent
    private let releaseEvent: GhosttySelectionGestureEvent
    private let tickEvent: GhosttySelectionGestureEvent

    /// Rendered geometry — assign on resize. Only the horizontal half is handed to libghostty
    /// (`GhosttySelectionGestureGeometry` has no cell height); the vertical mapping is ours.
    public var geometry: TerminalPixelGeometry
    /// Click granularity table. Defaults to cell / word / line.
    public var behaviors: SelectionBehaviors = .default
    /// Max interval between clicks of a repeat sequence, in seconds. The view passes
    /// `NSEvent.doubleClickInterval`; this file must not import AppKit.
    public var doubleClickInterval: Double
    /// Max pointer travel between clicks of a repeat sequence, in surface pixels.
    public var repeatDistance: Double = 4
    /// How far one autoscroll tick scrolls.
    public var autoscrollPolicy = AutoscrollPolicy()

    public init(
        terminal: GhosttyTerminalHandle,
        geometry: TerminalPixelGeometry,
        doubleClickInterval: Double
    ) throws {
        self.terminal = terminal
        self.geometry = geometry
        self.doubleClickInterval = doubleClickInterval

        var gesture: GhosttySelectionGesture?
        try ghosttyCheck(ghostty_selection_gesture_new(nil, &gesture), "ghostty_selection_gesture_new")
        guard let gesture else {
            throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_selection_gesture_new")
        }
        self.gesture = gesture

        func makeEvent(_ type: GhosttySelectionGestureEventType) throws -> GhosttySelectionGestureEvent {
            var event: GhosttySelectionGestureEvent?
            try ghosttyCheck(
                ghostty_selection_gesture_event_new(nil, &event, type),
                "ghostty_selection_gesture_event_new"
            )
            guard let event else {
                throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_selection_gesture_event_new")
            }
            return event
        }
        pressEvent = try makeEvent(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS)
        dragEvent = try makeEvent(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG)
        releaseEvent = try makeEvent(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE)
        tickEvent = try makeEvent(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK)
    }

    deinit {
        ghostty_selection_gesture_event_free(tickEvent)
        ghostty_selection_gesture_event_free(releaseEvent)
        ghostty_selection_gesture_event_free(dragEvent)
        ghostty_selection_gesture_event_free(pressEvent)
        ghostty_selection_gesture_free(gesture, terminal.raw)
    }

    // MARK: - Coordinate mapping

    /// Cell columns of the terminal right now.
    private var columns: UInt16 {
        var value: UInt16 = 0
        _ = ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_COLS, &value)
        return value
    }

    /// Cell rows of the terminal right now.
    private var rows: UInt16 {
        var value: UInt16 = 0
        _ = ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_ROWS, &value)
        return value
    }

    /// Surface pixels → a viewport cell, clamped into the grid so a drag past the edge still
    /// resolves. Returns `nil` only for a degenerate geometry (zero cell size / zero grid).
    public func gridPoint(at position: SurfacePoint) -> TerminalGridPoint? {
        let cols = columns, rows = rows
        guard geometry.cellWidth > 0, geometry.cellHeight > 0, cols > 0, rows > 0 else { return nil }
        let cx = (position.x - Double(geometry.paddingLeft)) / Double(geometry.cellWidth)
        let cy = (position.y - Double(geometry.paddingTop)) / Double(geometry.cellHeight)
        let col = min(max(cx.isFinite ? cx.rounded(.down) : 0, 0), Double(cols - 1))
        let row = min(max(cy.isFinite ? cy.rounded(.down) : 0, 0), Double(rows - 1))
        return TerminalGridPoint(x: UInt16(col), y: UInt32(row), space: .viewport)
    }

    private func gridRef(at point: TerminalGridPoint) throws -> GhosttyGridRef {
        var ref = GhosttyGridRef()
        try ghosttyCheck(
            ghostty_terminal_grid_ref(terminal.raw, point.ghostty, &ref),
            "ghostty_terminal_grid_ref"
        )
        return ref
    }

    private var gestureGeometry: GhosttySelectionGestureGeometry {
        GhosttySelectionGestureGeometry(
            columns: UInt32(columns),
            cell_width: max(geometry.cellWidth, 1),
            padding_left: geometry.paddingLeft,
            screen_height: max(geometry.screenHeight, 1)
        )
    }

    // MARK: - Gesture events

    /// Left-button press. Returns `true` if a selection was produced and installed (double click =
    /// word, triple = line); a plain single click produces none and clears any existing selection.
    ///
    /// - Parameter timestamp: a monotonic time in seconds (`NSEvent.timestamp`). Without it
    ///   libghostty can only ever see single clicks.
    @discardableResult
    public func press(at position: SurfacePoint, timestamp: Double) throws -> Bool {
        guard let point = gridPoint(at: position) else { return false }
        var ref = try gridRef(at: point)
        try set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)

        var surface = GhosttySurfacePosition(x: position.x, y: position.y)
        try set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &surface)

        var timeNs = UInt64(max(0, timestamp) * 1_000_000_000)
        try set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &timeNs)

        var intervalNs = UInt64(max(0, doubleClickInterval) * 1_000_000_000)
        try set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &intervalNs)

        var distance = repeatDistance
        try set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance)

        var table = behaviors.ghostty
        try set(pressEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_BEHAVIORS, &table)

        return try apply(pressEvent, clearOnNoValue: true)
    }

    /// Drag to a new position. `rectangle` = Option held.
    ///
    /// The cell under the pointer is included only once the pointer is past its horizontal
    /// midpoint — libghostty derives that from `OPT_POSITION` + `OPT_GEOMETRY`, not from the grid
    /// ref, which is why both are set here. That is standard terminal drag behaviour; the view
    /// layer must pass the real pointer pixels, never a re-centred cell coordinate.
    @discardableResult
    public func drag(to position: SurfacePoint, rectangle: Bool = false) throws -> Bool {
        guard let point = gridPoint(at: position) else { return false }
        var ref = try gridRef(at: point)
        try set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)

        var surface = GhosttySurfacePosition(x: position.x, y: position.y)
        try set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &surface)

        var geo = gestureGeometry
        try set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geo)

        var rect = rectangle
        try set(dragEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rect)

        return try apply(dragEvent, clearOnNoValue: false)
    }

    /// Button release. Never produces a selection; it only ends the click sequence.
    public func release(at position: SurfacePoint?) throws {
        if let position, let point = gridPoint(at: position) {
            var ref = try gridRef(at: point)
            try set(releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        } else {
            try set(releaseEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, nil)
        }
        _ = try apply(releaseEvent, clearOnNoValue: false)
    }

    /// The autoscroll libghostty is currently asking for, from the last drag.
    public var autoscrollDirection: SelectionAutoscroll {
        var value = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
        guard ghostty_selection_gesture_get(
            gesture, terminal.raw, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &value
        ) == GHOSTTY_SUCCESS else { return .none }
        switch value {
        case GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_UP: return .up
        case GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_DOWN: return .down
        default: return .none
        }
    }

    /// Whether the current (or last) click sequence has dragged at all.
    public var hasDragged: Bool {
        var value = false
        guard ghostty_selection_gesture_get(
            gesture, terminal.raw, GHOSTTY_SELECTION_GESTURE_DATA_DRAGGED, &value
        ) == GHOSTTY_SUCCESS else { return false }
        return value
    }

    /// Click count of the active sequence (0 = inactive).
    public var clickCount: Int {
        var value: UInt8 = 0
        guard ghostty_selection_gesture_get(
            gesture, terminal.raw, GHOSTTY_SELECTION_GESTURE_DATA_CLICK_COUNT, &value
        ) == GHOSTTY_SUCCESS else { return 0 }
        return Int(value)
    }

    /// One tick of the view layer's autoscroll timer while a drag is outside the viewport:
    /// scroll by the policy's rows, then extend the selection to the (clamped) pointer cell.
    ///
    /// Returns the rows actually scrolled, or 0 when no autoscroll is pending.
    @discardableResult
    public func autoscrollTick(at position: SurfacePoint, rectangle: Bool = false) throws -> Int {
        let direction = autoscrollDirection
        let rows = autoscrollPolicy.rows(for: direction)
        guard rows != 0 else { return 0 }

        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = rows
        _ = ghostty_terminal_scroll_viewport(terminal.raw, behavior)

        guard let point = gridPoint(at: position) else { return rows }
        var viewport = GhosttyPointCoordinate(x: point.x, y: point.y)
        try set(tickEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &viewport)

        var surface = GhosttySurfacePosition(x: position.x, y: position.y)
        try set(tickEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &surface)

        var geo = gestureGeometry
        try set(tickEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geo)

        var rect = rectangle
        try set(tickEvent, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rect)

        _ = try apply(tickEvent, clearOnNoValue: false)
        return rows
    }

    /// Cancel the click sequence and release the gesture's tracked refs. Does not clear the
    /// terminal's installed selection — call `clearSelection()` for that.
    public func reset() {
        ghostty_selection_gesture_reset(gesture, terminal.raw)
    }

    /// Drop the terminal's active selection.
    public func clearSelection() {
        _ = ghostty_terminal_set(terminal.raw, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
    }

    /// Is there an active selection?
    public var hasSelection: Bool {
        var selection = GhosttySelection()
        return ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
    }

    /// The selected text, formatted the way Ghostty's own copy does it (plain, unwrapped,
    /// trailing whitespace trimmed). `nil` when there is no selection.
    public func copySelection() -> String? {
        Self.copySelection(terminal: terminal)
    }

    /// Free-function form for callers that hold a terminal but no controller (e.g. Select All).
    /// Caller holds the terminal lock.
    public static func copySelection(terminal: GhosttyTerminalHandle) -> String? {
        // PORT: ghostty_terminal_selection_format_alloc is gone in vt-1.0.0. The replacement is a
        // formatter carrying the selection; plain + unwrap + trim is what formatter.h documents as
        // "the same text Ghostty copies". Unlike the old API, NULL no longer means "the active
        // selection" (it means the whole screen), so the selection must be read and passed in.
        var selection = GhosttySelection()
        guard ghostty_terminal_get(terminal.raw, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
        else { return nil }

        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, terminal.raw) == GHOSTTY_SUCCESS, let formatter
        else { return nil }
        defer { ghostty_formatter_free(formatter) }
        var emit = GHOSTTY_FORMATTER_FORMAT_PLAIN, unwrap = true, trim = true
        _ = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit)
        _ = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap)
        _ = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim)
        guard ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection) == GHOSTTY_SUCCESS
        else { return nil }

        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        let result = ghostty_formatter_format_alloc(formatter, nil, &buffer, &length)
        guard result == GHOSTTY_SUCCESS, let buffer else { return nil }
        defer { ghostty_free(nil, buffer, length) }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
    }

    // MARK: - Plumbing

    private func set(
        _ event: GhosttySelectionGestureEvent,
        _ option: GhosttySelectionGestureEventOption,
        _ value: UnsafeRawPointer?
    ) throws {
        try ghosttyCheck(
            ghostty_selection_gesture_event_set(event, option, value),
            "ghostty_selection_gesture_event_set"
        )
    }

    /// Apply an event and install whatever selection it produced.
    /// `GHOSTTY_NO_VALUE` is normal (press/release), not an error.
    private func apply(_ event: GhosttySelectionGestureEvent, clearOnNoValue: Bool) throws -> Bool {
        var selection = GhosttySelection()
        let result = ghostty_selection_gesture_event(gesture, terminal.raw, event, &selection)
        if result == GHOSTTY_NO_VALUE {
            if clearOnNoValue { clearSelection() }
            return false
        }
        try ghosttyCheck(result, "ghostty_selection_gesture_event")
        try ghosttyCheck(
            ghostty_terminal_set(terminal.raw, GHOSTTY_TERMINAL_OPT_SELECTION, &selection),
            "ghostty_terminal_set(OPT_SELECTION)"
        )
        return true
    }
}

// MARK: - OSC 8 hyperlinks

/// Looking up the OSC 8 URI under the pointer, for the ⌘-hover underline and ⌘-click open.
///
/// Every call takes a terminal grid point and resolves it through `ghostty_terminal_grid_ref`, so
/// **the caller must hold the terminal lock** and must not mutate the terminal in between — grid
/// refs are only valid until the next mutating call.
public enum HyperlinkLookup {
    /// The OSC 8 URI of the cell at `point`, or `nil` when the cell has none.
    public static func uri(at point: TerminalGridPoint, in terminal: GhosttyTerminalHandle) -> String? {
        var ref = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(terminal.raw, point.ghostty, &ref) == GHOSTTY_SUCCESS else { return nil }
        return uri(of: &ref)
    }

    private static func uri(of ref: inout GhosttyGridRef) -> String? {
        var needed = 0
        let probe = ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &needed)
        guard probe == GHOSTTY_OUT_OF_SPACE || probe == GHOSTTY_SUCCESS, needed > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: needed)
        var written = 0
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            ghostty_grid_ref_hyperlink_uri(&ref, buffer.baseAddress, buffer.count, &written)
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return String(decoding: bytes.prefix(written), as: UTF8.self)
    }

    /// The URI under `point` plus the run of contiguous cells on the same row that share it —
    /// what the underline overlay draws. Columns are inclusive and in `point`'s own space.
    public static func run(
        at point: TerminalGridPoint,
        in terminal: GhosttyTerminalHandle,
        columns: UInt16
    ) -> (uri: String, columns: ClosedRange<UInt16>)? {
        guard let uri = uri(at: point, in: terminal) else { return nil }
        var first = point.x
        while first > 0 {
            let candidate = TerminalGridPoint(x: first - 1, y: point.y, space: point.space)
            guard Self.uri(at: candidate, in: terminal) == uri else { break }
            first -= 1
        }
        var last = point.x
        while last + 1 < columns {
            let candidate = TerminalGridPoint(x: last + 1, y: point.y, space: point.space)
            guard Self.uri(at: candidate, in: terminal) == uri else { break }
            last += 1
        }
        return (uri, first...last)
    }
}

