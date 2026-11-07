// A read-only view of a libghostty terminal, valid only inside `GhosttyTerminal.withLocked`.
//
// Every reading goes straight to the C terminal, so it is exact at the moment it is read and the
// lock keeps it from changing under the caller. Grid references are only valid until the next
// change to the terminal, which is why no reading here hands one out.
import GhosttyVt

/// The terminal as seen from inside `GhosttyTerminal.withLocked`. Do not keep it past the closure.
/// After `close()` it reports a closed terminal: `isClosed` is true and every reading is empty.
public struct GhosttyTerminalState {
    /// The C terminal, or nil once closed. Internal: the projection and the snapshot writer read it.
    let raw: VtTerminal?

    init(raw: VtTerminal?) {
        self.raw = raw
    }

    /// The formats `formatted(_:trim:unwrap:)` can produce.
    public enum TextFormat: Sendable {
        /// Text only.
        case plain
        /// Text with the escape sequences that reproduce its styles.
        case vt
    }

    public var isClosed: Bool { raw == nil }

    /// Width in cells.
    public var cols: Int { Int(fetch(GHOSTTY_TERMINAL_DATA_COLS, UInt16(0))) }

    /// Height in cells.
    public var rows: Int { Int(fetch(GHOSTTY_TERMINAL_DATA_ROWS, UInt16(0))) }

    /// The cursor's cell in the active area, zero-based.
    public var cursor: (col: Int, row: Int) {
        (Int(fetch(GHOSTTY_TERMINAL_DATA_CURSOR_X, UInt16(0))), Int(fetch(GHOSTTY_TERMINAL_DATA_CURSOR_Y, UInt16(0))))
    }

    /// DEC mode 25.
    public var isCursorVisible: Bool { fetch(GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, false) }

    /// True while the alternate screen (`?1049h` and friends) is active.
    public var isAlternateScreen: Bool {
        fetch(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, GHOSTTY_TERMINAL_SCREEN_PRIMARY) == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    /// Whether a DEC private mode (or, with `ansi`, an ANSI mode) is set.
    public func mode(_ value: UInt16, ansi: Bool = false) -> Bool {
        guard let raw else { return false }
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, ansi), value: false)
        guard ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else { return false }
        return config.value
    }

    /// The current Kitty keyboard protocol flags. Zero means the program asked for none.
    public var kittyKeyboardFlags: UInt8 { fetch(GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, UInt8(0)) }

    /// True while any mouse tracking mode (X10, normal, button or any) is on.
    public var isMouseTrackingEnabled: Bool { fetch(GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, false) }

    /// Rows of scrollback above the active area.
    public var scrollbackRows: Int { fetch(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, 0) }

    /// The title a program set with OSC 0 or OSC 2.
    public var title: String {
        guard let raw else { return "" }
        return terminalString(raw, GHOSTTY_TERMINAL_DATA_TITLE)
    }

    /// The working directory a program reported (OSC 7 and friends), as the bytes it sent.
    public var pwd: String {
        guard let raw else { return "" }
        return terminalString(raw, GHOSTTY_TERMINAL_DATA_PWD)
    }

    /// The text of one row of the active area, zero-based from the top, with trailing blanks
    /// removed. A wide character counts once. Empty for a row outside the grid.
    public func lineText(_ row: Int) -> String {
        guard let raw, row >= 0, row < rows else { return "" }
        var line = ""
        var codepoints = [UInt32](repeating: 0, count: 8)
        for column in 0..<cols {
            guard var ref = gridRef(raw, column: column, row: row) else { break }
            var cell: GhosttyCell = 0
            guard ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS else { continue }
            var wide = GHOSTTY_CELL_WIDE_NARROW
            _ = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
            var written = 0
            var capacity = codepoints.count
            var result = ghostty_grid_ref_graphemes(&ref, &codepoints, capacity, &written)
            if result == GHOSTTY_OUT_OF_SPACE {
                codepoints = [UInt32](repeating: 0, count: written)
                capacity = codepoints.count
                result = ghostty_grid_ref_graphemes(&ref, &codepoints, capacity, &written)
            }
            guard result == GHOSTTY_SUCCESS, written > 0 else {
                line.append(" ")
                continue
            }
            for codepoint in codepoints.prefix(written) {
                if let scalar = Unicode.Scalar(codepoint) { line.unicodeScalars.append(scalar) }
            }
        }
        while line.last == " " { line.removeLast() }
        return line
    }

    /// True when the cell has a foreground or background colour of its own, set by SGR or by an
    /// erase in a background colour. A cell in the default colours reads false.
    public func cellHasColor(column: Int, row: Int) -> Bool {
        guard let raw, var ref = gridRef(raw, column: column, row: row) else { return false }
        var cell: GhosttyCell = 0
        if ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS {
            var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
            _ = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag)
            if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE || tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB {
                return true
            }
        }
        var style = GhosttyStyle()
        guard ghostty_grid_ref_style(&ref, &style) == GHOSTTY_SUCCESS else { return false }
        return style.fg_color.tag != 0 || style.bg_color.tag != 0
    }

    /// The active screen through libghostty's formatter. nil when closed or when formatting fails.
    public func formatted(_ format: TextFormat = .plain, trim: Bool = true, unwrap: Bool = false) -> String? {
        guard let raw else { return nil }
        let emit: GhosttyFormatterFormat
        switch format {
        case .plain: emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        case .vt: emit = GHOSTTY_FORMATTER_FORMAT_VT
        }
        do {
            return try formatTerminal(raw, format: emit, trim: trim, unwrap: unwrap)
        } catch {
            terminalEngineLog.error("formatting the screen failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: Helpers

    /// One `ghostty_terminal_get` of a fixed-size value, or `fallback` when closed or on failure.
    private func fetch<Value>(_ data: GhosttyTerminalData, _ fallback: Value) -> Value {
        guard let raw else { return fallback }
        var value = fallback
        guard ghostty_terminal_get(raw, data, &value) == GHOSTTY_SUCCESS else { return fallback }
        return value
    }

    private func gridRef(_ raw: VtTerminal, column: Int, row: Int) -> GhosttyGridRef? {
        guard column >= 0, column <= Int(UInt16.max), row >= 0 else { return nil }
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_ACTIVE
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(column), y: UInt32(row))
        var ref = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(raw, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }
}
