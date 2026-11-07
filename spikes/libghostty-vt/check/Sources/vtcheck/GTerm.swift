// libghostty-vt side: the official vt-1.0.0 static library, no patches.
import Foundation
import GhosttyVt

let GX_MODES: UInt32 = 1 << 1, GX_REGION: UInt32 = 1 << 2, GX_ALL: UInt32 = 0xFFF, GX_PALETTE: UInt32 = 1 << 0
/// Everything but the palette. A palette replay would overwrite the receiver's theme.
let GX_HANDOVER: UInt32 = GX_ALL & ~GX_PALETTE

private func col(_ c: GhosttyStyleColor) -> Col {
    switch Int(c.tag) {
    case 1: return .pal(c.value.palette)
    case 2: return .rgb(c.value.rgb.r, c.value.rgb.g, c.value.rgb.b)
    default: return .def
    }
}

private func style(_ s: GhosttyStyle, into c: inout Cell) {
    c.fg = col(s.fg_color); c.bg = col(s.bg_color); c.ul = col(s.underline_color)
    let g = s.flags
    var f: UInt8 = 0
    if g & 1 != 0 { f |= Flag.bold }
    if g & 2 != 0 { f |= Flag.italic }
    if g & 4 != 0 { f |= Flag.dim }
    if g & 8 != 0 { f |= Flag.blink }
    if g & 16 != 0 { f |= Flag.inverse }
    if g & 32 != 0 { f |= Flag.invisible }
    if g & 64 != 0 { f |= Flag.strike }
    if g & 128 != 0 { f |= Flag.overline }
    c.flags = f
    c.underline = UInt8((g >> 8) & 7)
}

/// Set by `diff --no-grapheme`, to show what mode 2027 alone accounts for.
nonisolated(unsafe) var noGrapheme = false

final class GTerm {
    var t: GhosttyTerminal?
    let cols: Int, rows: Int

    /// `scrollback` lines, with the byte limit lifted. The header states that
    /// NULL restores the 10,000-byte default and SIZE_MAX means no byte limit,
    /// so the reference benchmark's `nil` is wrong for this version.
    init(cols: Int, rows: Int, scrollback: Int, grapheme: Bool = !noGrapheme) {
        self.cols = cols; self.rows = rows
        precondition(ghostty_terminal_new(nil, &t, UInt16(cols), UInt16(rows)) == GHOSTTY_SUCCESS)
        configure(scrollback: scrollback, grapheme: grapheme)
    }

    init(taking terminal: GhosttyTerminal?, cols: Int, rows: Int) {
        t = terminal; self.cols = cols; self.rows = rows
    }

    deinit { ghostty_terminal_free(t) }

    func configure(scrollback: Int, grapheme: Bool) {
        var unlimited = UInt.max
        precondition(ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &unlimited) == GHOSTTY_SUCCESS)
        var lines = UInt(scrollback)
        precondition(ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines) == GHOSTTY_SUCCESS)
        if grapheme {
            // As Ghostty.app does: set the default, so a reset keeps it.
            var mode = GhosttyTerminalModeConfig()
            mode.mode = ghostty_mode_new(2027, false)
            mode.value = true
            precondition(ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &mode) == GHOSTTY_SUCCESS)
        }
    }

    func feed(_ b: ArraySlice<UInt8>) {
        b.withUnsafeBufferPointer { ghostty_terminal_vt_write(t, $0.baseAddress, $0.count) }
    }
    func feed(_ b: [UInt8]) { feed(b[...]) }

    /// Feeds until the parser and UTF-8 decoder are at ground. Returns bytes consumed.
    func feedToGround(_ b: ArraySlice<UInt8>) -> Int {
        var stop = GhosttyTerminalWriteStop()
        stop.size = MemoryLayout<GhosttyTerminalWriteStop>.size
        let rc = b.withUnsafeBufferPointer {
            ghostty_terminal_vt_write_until(t, $0.baseAddress, $0.count, GHOSTTY_TERMINAL_BOUNDARY_GROUND.rawValue, &stop)
        }
        precondition(rc == GHOSTTY_SUCCESS || rc == GHOSTTY_NO_VALUE, "vt_write_until \(rc)")
        return stop.consumed
    }

    func vt(extras: UInt32, unwrap: Bool, trim: Bool) -> [UInt8] {
        var f: GhosttyFormatter?
        precondition(ghostty_formatter_terminal_new(nil, &f, t) == GHOSTTY_SUCCESS)
        defer { ghostty_formatter_free(f) }
        var emit = GHOSTTY_FORMATTER_FORMAT_VT
        ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_EMIT, &emit)
        var u = unwrap, tr = trim, x = extras
        ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_UNWRAP, &u)
        ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_TRIM, &tr)
        ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_EXTRAS, &x)
        var ptr: UnsafeMutablePointer<UInt8>?, len = 0
        precondition(ghostty_formatter_format_alloc(f, nil, &ptr, &len) == GHOSTTY_SUCCESS)
        defer { ghostty_free(nil, ptr, len) }
        return ptr.map { Array(UnsafeBufferPointer(start: $0, count: len)) } ?? []
    }

    func encodeSnapshot() -> [UInt8] {
        var ptr: UnsafeMutablePointer<UInt8>?, len = 0
        precondition(ghostty_snapshot_encode_alloc(t, nil, &ptr, &len) == GHOSTTY_SUCCESS)
        defer { ghostty_free(nil, ptr, len) }
        return Array(UnsafeBufferPointer(start: ptr, count: len))
    }

    static func decodeSnapshot(_ b: [UInt8], cols: Int, rows: Int) -> GTerm {
        var d: GhosttySnapshotDecoder?
        var out: GhosttyTerminal?
        let rc: GhosttyResult = b.withUnsafeBufferPointer { p in
            precondition(ghostty_snapshot_decoder_new_buf(nil, &d, p.baseAddress, p.count) == GHOSTTY_SUCCESS)
            return ghostty_snapshot_decoder_decode(d, &out)
        }
        ghostty_snapshot_decoder_free(d)
        precondition(rc == GHOSTTY_SUCCESS, "snapshot decode \(rc)")
        return GTerm(taking: out, cols: cols, rows: rows)
    }

    /// A deep copy, made through the snapshot API.
    func clone() -> GTerm { GTerm.decodeSnapshot(encodeSnapshot(), cols: cols, rows: rows) }

    var scrollbackRows: Int {
        var n = 0
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &n)
        return n
    }

    private func readRow(tag: GhosttyPointTag, y: Int) -> (cells: [Cell], wrapped: Bool) {
        var cells = [Cell](repeating: Cell(), count: cols)
        var ref = GhosttyGridRef()
        var p = GhosttyPoint()
        p.tag = tag
        p.value.coordinate.x = 0
        p.value.coordinate.y = UInt32(y)
        guard ghostty_terminal_grid_ref(t, p, &ref) == GHOSTTY_SUCCESS else { return (cells, false) }
        var r: GhosttyRow = 0
        ghostty_grid_ref_row(&ref, &r)
        var wrapped = false
        ghostty_row_get(r, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &wrapped)
        // Stepping `x` inside the ref avoids one point lookup per cell. The header
        // calls the fields read-only because they are storage coordinates, which
        // for a column within one row is what this relies on. Only a local copy changes.
        var buf = [UInt32](repeating: 0, count: 32)
        for x in 0..<cols {
            ref.x = UInt16(x)
            var raw: GhosttyCell = 0
            ghostty_grid_ref_cell(&ref, &raw)
            var c = Cell()
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            switch wide {
            case GHOSTTY_CELL_WIDE_WIDE: c.width = 2
            case GHOSTTY_CELL_WIDE_SPACER_TAIL: c.width = 0
            default: c.width = 1     // a spacer head is a blank narrow cell to a reader
            }
            var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag)
            switch tag {
            case GHOSTTY_CELL_CONTENT_CODEPOINT:
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &c.cp)
            case GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME:
                var n = 0
                ghostty_grid_ref_graphemes(&ref, &buf, 32, &n)
                if n > 0 { c.cp = buf[0] }
                if n > 1 { c.more = Array(buf[1..<n]) }
            default: break
            }
            var styled = false
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_STYLING, &styled)
            if styled {
                var s = GhosttyStyle()
                ghostty_grid_ref_style(&ref, &s)
                style(s, into: &c)
            }
            if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE {
                var i: UInt8 = 0
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_PALETTE, &i)
                c.bg = .pal(i)
            } else if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB {
                var v = GhosttyColorRgb()
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &v)
                c.bg = .rgb(v.r, v.g, v.b)
            }
            var linked = false
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &linked)
            if linked {
                var n = 0
                ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &n)
                var bytes = [UInt8](repeating: 0, count: n)
                ghostty_grid_ref_hyperlink_uri(&ref, &bytes, n, &n)
                c.link = String(decoding: bytes, as: UTF8.self)
            }
            cells[x] = c
        }
        return (cells, wrapped)
    }

    /// The scrolling region has no getter. It is read back from a formatter run
    /// that asks for that one extra, whose output ends the stream: CSI t;b r when the
    /// region is not full height, then CSI l;r s when DECLRMM margins are set. Parsed
    /// strictly from the end, because printed text can end in "r" or "s" too.
    private func region() -> (Int, Int, Int, Int) {
        var out = vt(extras: GX_REGION, unwrap: false, trim: true)[...]
        var top = 0, bottom = rows - 1, left = 0, right = cols - 1
        func takeTail(_ final: UInt8) -> (Int, Int)? {
            guard out.last == final else { return nil }
            var i = out.endIndex - 2
            var field = [Int](), value = 0, place = 1, digits = 0
            while i >= out.startIndex {
                let c = out[i]
                if c >= 0x30, c <= 0x39 { value += Int(c - 0x30) * place; place *= 10; digits += 1 }
                else if c == 0x3b, digits > 0 { field.insert(value, at: 0); value = 0; place = 1; digits = 0 }
                else { break }
                i -= 1
            }
            guard digits > 0, i >= out.startIndex + 1, out[i] == 0x5b, out[i - 1] == 0x1b else { return nil }
            field.insert(value, at: 0)
            guard field.count == 2 else { return nil }
            out = out[out.startIndex..<(i - 1)]
            return (field[0] - 1, field[1] - 1)
        }
        if let s = takeTail(0x73) { left = s.0; right = s.1 }
        if let r = takeTail(0x72) { top = r.0; bottom = r.1 }
        return (top, bottom, left, right)
    }

    func snap(history: Bool = true) -> Snap {
        var s = Snap()
        s.cols = cols; s.rows = rows
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        s.alt = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
        for y in 0..<rows {
            let r = readRow(tag: GHOSTTY_POINT_TAG_ACTIVE, y: y)
            s.grid.append(r.cells); s.wrap.append(r.wrapped)
        }
        if history && !s.alt {
            let n = scrollbackRows
            s.hist.reserveCapacity(n)
            for y in 0..<n {
                let r = readRow(tag: GHOSTTY_POINT_TAG_HISTORY, y: y)
                s.hist.append(r.cells); s.histWrap.append(r.wrapped)
            }
        }
        var x: UInt16 = 0, y: UInt16 = 0, pending = false, visible = true
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, &pending)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &visible)
        s.cx = Int(x); s.cy = Int(y); s.pending = pending; s.cursorVisible = visible
        for m in comparedModes {
            var q = GhosttyTerminalModeConfig()
            q.mode = ghostty_mode_new(UInt16(m.n), !m.dec)
            if ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MODE, &q) == GHOSTTY_SUCCESS { s.modes[m.name] = q.value }
        }
        (s.top, s.bottom, s.left, s.right) = region()
        var pen = GhosttyStyle()
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_SGR_STYLE, &pen)
        style(pen, into: &s.pen)
        var k: UInt8 = 0
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &k)
        s.kitty = Int(k)
        return s
    }
}
