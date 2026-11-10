// Reads a libghostty terminal cell by cell, for the screen projection, the styled capture, the
// detach handback and the text under a ⌘-click.
//
// Everything here runs on the `GhosttyTerminalState` that `GhosttyTerminal.withLocked` hands out,
// so the terminal cannot change under a walk, and nothing here feeds the terminal. The cell reading
// is adapted from the libghostty proof of concept's `GTerm.readRow`
// (spikes/libghostty-vt/check/Sources/vtcheck/GTerm.swift on branch spike/libghostty-vt-poc).
import Foundation
import GhosttyVt

/// A colour as a libghostty cell or pen stores it.
enum GhosttyCellColor: Equatable, Sendable {
    /// The terminal's default colour for that ground.
    case none
    case palette(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    init(_ color: GhosttyStyleColor) {
        // `tag` is 0 for none, 1 for a palette index and 2 for RGB.
        switch color.tag {
        case 1: self = .palette(color.value.palette)
        case 2: self = .rgb(color.value.rgb.r, color.value.rgb.g, color.value.rgb.b)
        default: self = .none
        }
    }
}

/// The style of one cell, or of the cursor's pen, in libghostty's terms.
struct GhosttyCellStyle: Equatable, Sendable {
    // `GHOSTTY_STYLE_FLAG_*`. The underline style sits above them, in bits 8 to 10.
    static let bold: UInt16 = 1 << 0
    static let italic: UInt16 = 1 << 1
    static let faint: UInt16 = 1 << 2
    static let blink: UInt16 = 1 << 3
    static let inverse: UInt16 = 1 << 4
    static let invisible: UInt16 = 1 << 5
    static let strikethrough: UInt16 = 1 << 6
    static let overline: UInt16 = 1 << 7

    var foreground: GhosttyCellColor = .none
    var background: GhosttyCellColor = .none
    var underlineColor: GhosttyCellColor = .none
    /// The flag bits above.
    var flags: UInt16 = 0
    /// `GhosttySgrUnderline`: 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed.
    var underline: UInt8 = 0

    init() {}

    init(_ style: GhosttyStyle) {
        foreground = GhosttyCellColor(style.fg_color)
        background = GhosttyCellColor(style.bg_color)
        underlineColor = GhosttyCellColor(style.underline_color)
        flags = style.flags & 0xFF
        underline = UInt8((style.flags >> 8) & 0x7)
    }
}

/// One cell of the grid.
struct GhosttyGridCell: Equatable, Sendable {
    enum Width: Equatable, Sendable {
        case narrow
        /// The first half of a two-column character.
        case wide
        /// The second half of a two-column character. It holds no text of its own.
        case spacerTail
        /// The blank a wide character left at the end of a row when it did not fit and wrapped.
        case spacerHead
    }

    /// The cell's scalars, empty for a cell with no text.
    var scalars: [UInt32] = []
    var width: Width = .narrow
    var style = GhosttyCellStyle()
    /// The OSC 8 target, read only when a walk asks for it.
    var hyperlink: String?

    /// The first scalar, or 0 for a cell with no text. SwiftTerm's walks test the same value.
    var code: UInt32 { scalars.first ?? 0 }

    /// The columns SwiftTerm gives the same cell: 2 for a wide character, 0 for its second half,
    /// and 1 otherwise, so a spacer head counts as a blank narrow cell.
    var columns: Int {
        switch width {
        case .wide: return 2
        case .spacerTail: return 0
        case .narrow, .spacerHead: return 1
        }
    }

    /// The cell's text, empty for a cell with no text.
    var text: String {
        var view = String.UnicodeScalarView()
        for value in scalars {
            if let scalar = Unicode.Scalar(value) { view.append(scalar) }
        }
        return String(view)
    }
}

/// One row of the grid.
struct GhosttyGridRow: Sendable {
    var cells: [GhosttyGridCell]
    /// True when the row continues the one above it: a soft wrap.
    var isWrapContinuation: Bool
}

extension GhosttyTerminalState {
    /// Where a row is counted from.
    enum GridArea: Sendable {
        /// The screen, row 0 at the top.
        case active
        /// The scrollback above the screen, row 0 the oldest.
        case history
        /// The rows on view, row 0 at the top, wherever the user has scrolled to.
        case viewport

        var tag: GhosttyPointTag {
            switch self {
            case .active: GHOSTTY_POINT_TAG_ACTIVE
            case .history: GHOSTTY_POINT_TAG_HISTORY
            case .viewport: GHOSTTY_POINT_TAG_VIEWPORT
            }
        }
    }

    /// Rows of scrollback above the screen. The alternate screen keeps none.
    var historyRowCount: Int { isAlternateScreen ? 0 : scrollbackRows }

    /// True when the cursor sits past a character printed in the last column, so the next one wraps.
    var cursorPendingWrap: Bool {
        guard let raw else { return false }
        var pending = false
        guard ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, &pending) == GHOSTTY_SUCCESS
        else { return false }
        return pending
    }

    /// True when the VT stream is between sequences: its parser is not inside an escape sequence
    /// and its UTF-8 decoder is not inside a character. True as well when it cannot be read.
    var isAtGround: Bool {
        guard let raw else { return true }
        var ground = true
        guard ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_VT_GROUND, &ground) == GHOSTTY_SUCCESS
        else { return true }
        return ground
    }

    /// The mouse tracking mode the terminal reports with: 9, 1000, 1002 or 1003, or 0 for none.
    /// libghostty's mode table keeps a replaced mode set, so this, not `mode(_:)`, says which one
    /// is in effect. nil when closed or when the probe fails.
    var mouseTrackingInEffect: Int? { raw.flatMap { GhosttySnapshotWriter.effectiveMouseMode($0) } }

    /// The mouse report encoding in effect: 1005, 1006, 1015 or 1016, or 0 for X10's. nil when
    /// closed or when the probe fails.
    var mouseEncodingInEffect: Int? { raw.flatMap { GhosttySnapshotWriter.effectiveMouseEncoding($0) } }

    /// The pen: the style the next printed character gets.
    var cursorStyle: GhosttyCellStyle {
        guard let raw else { return GhosttyCellStyle() }
        var style = GhosttyStyle()
        guard ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_CURSOR_SGR_STYLE, &style) == GHOSTTY_SUCCESS
        else { return GhosttyCellStyle() }
        return GhosttyCellStyle(style)
    }

    /// One row, every cell of it. nil for a row outside `area` or once the terminal is closed.
    func gridRow(_ area: GridArea, _ row: Int, hyperlinks: Bool = false) -> GhosttyGridRow? {
        guard let raw, row >= 0 else { return nil }
        let width = cols
        var point = GhosttyPoint()
        point.tag = area.tag
        point.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(row))
        var ref = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(raw, point, &ref) == GHOSTTY_SUCCESS else { return nil }

        var rowHandle: GhosttyRow = 0
        var wrapped = false
        if ghostty_grid_ref_row(&ref, &rowHandle) == GHOSTTY_SUCCESS {
            _ = ghostty_row_get(rowHandle, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &wrapped)
        }

        var cells: [GhosttyGridCell] = []
        cells.reserveCapacity(width)
        var scratch = [UInt32](repeating: 0, count: 16)
        for column in 0..<width {
            // Stepping the column inside one reference saves a point lookup per cell. The fields are
            // storage coordinates, which for a column within one row is the column itself.
            ref.x = UInt16(clamping: column)
            cells.append(Self.cell(at: &ref, scratch: &scratch, hyperlinks: hyperlinks))
        }
        return GhosttyGridRow(cells: cells, isWrapContinuation: wrapped)
    }

    private static func cell(
        at ref: inout GhosttyGridRef, scratch: inout [UInt32], hyperlinks: Bool
    ) -> GhosttyGridCell {
        var item = GhosttyGridCell()
        var raw: GhosttyCell = 0
        guard ghostty_grid_ref_cell(&ref, &raw) == GHOSTTY_SUCCESS else { return item }

        var wide = GHOSTTY_CELL_WIDE_NARROW
        _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
        switch wide {
        case GHOSTTY_CELL_WIDE_WIDE: item.width = .wide
        case GHOSTTY_CELL_WIDE_SPACER_TAIL: item.width = .spacerTail
        case GHOSTTY_CELL_WIDE_SPACER_HEAD: item.width = .spacerHead
        default: item.width = .narrow
        }

        var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
        _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag)
        switch tag {
        case GHOSTTY_CELL_CONTENT_CODEPOINT:
            var codepoint: UInt32 = 0
            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint)
            if codepoint != 0 { item.scalars = [codepoint] }
        case GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME:
            item.scalars = graphemes(at: &ref, scratch: &scratch)
        default:
            break
        }

        var styled = false
        _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_STYLING, &styled)
        if styled {
            var style = GhosttyStyle()
            if ghostty_grid_ref_style(&ref, &style) == GHOSTTY_SUCCESS { item.style = GhosttyCellStyle(style) }
        }
        // An erase in a background colour leaves a cell that carries only that colour.
        if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE {
            var index: UInt8 = 0
            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_PALETTE, &index)
            item.style.background = .palette(index)
        } else if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB {
            var rgb = GhosttyColorRgb()
            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &rgb)
            item.style.background = .rgb(rgb.r, rgb.g, rgb.b)
        }

        if hyperlinks {
            var linked = false
            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &linked)
            if linked { item.hyperlink = hyperlink(at: &ref) }
        }
        return item
    }

    private static func graphemes(at ref: inout GhosttyGridRef, scratch: inout [UInt32]) -> [UInt32] {
        var written = 0
        var capacity = scratch.count
        var result = ghostty_grid_ref_graphemes(&ref, &scratch, capacity, &written)
        if result == GHOSTTY_OUT_OF_SPACE {
            scratch = [UInt32](repeating: 0, count: written)
            capacity = scratch.count
            result = ghostty_grid_ref_graphemes(&ref, &scratch, capacity, &written)
        }
        guard result == GHOSTTY_SUCCESS else { return [] }
        return Array(scratch.prefix(written))
    }

    private static func hyperlink(at ref: inout GhosttyGridRef) -> String? {
        var length = 0
        let sized = ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &length)
        guard sized == GHOSTTY_SUCCESS || sized == GHOSTTY_OUT_OF_SPACE, length > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        let capacity = bytes.count
        guard ghostty_grid_ref_hyperlink_uri(&ref, &bytes, capacity, &length) == GHOSTTY_SUCCESS else { return nil }
        return String(bytes: bytes.prefix(length), encoding: .utf8)
    }

    /// The screen through libghostty's VT formatter, with the given `GhosttyFormatterExtras` bits.
    /// The tests read the scrolling region back from its tail, because the region has no getter.
    func formattedVT(extras: UInt32, unwrap: Bool, trim: Bool) throws -> [UInt8] {
        guard let raw else { return [] }
        return try GhosttyVTFormat.format(raw, extras: extras, unwrap: unwrap, trim: trim, selection: nil)
    }
}

/// libghostty's VT formatter, with the options the handback and the tests set.
enum GhosttyVTFormat {
    // `GhosttyFormatterExtras` bits, from formatter.h.
    static let palette: UInt32 = 1 << 0
    static let modes: UInt32 = 1 << 1
    static let scrollingRegion: UInt32 = 1 << 2
    static let tabstops: UInt32 = 1 << 3
    static let pwd: UInt32 = 1 << 4
    static let keyboard: UInt32 = 1 << 5
    static let cursor: UInt32 = 1 << 6
    static let style: UInt32 = 1 << 7
    static let hyperlink: UInt32 = 1 << 8
    static let protection: UInt32 = 1 << 9
    static let kittyKeyboard: UInt32 = 1 << 10
    static let charsets: UInt32 = 1 << 11
    static let all: UInt32 = 0xFFF

    /// Formats `terminal`, or only `selection` of it when one is given.
    static func format(
        _ terminal: VtTerminal, extras: UInt32, unwrap: Bool, trim: Bool, selection: GhosttySelection?
    ) throws -> [UInt8] {
        var formatter: GhosttyFormatter?
        try ghosttyCheck(ghostty_formatter_terminal_new(nil, &formatter, terminal), "ghostty_formatter_terminal_new")
        guard let formatter else {
            throw GhosttyCallError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_formatter_terminal_new")
        }
        defer { ghostty_formatter_free(formatter) }
        var emit = GHOSTTY_FORMATTER_FORMAT_VT
        var wantUnwrap = unwrap, wantTrim = trim, wantExtras = extras
        try ghosttyCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit), "FORMATTER_OPT_EMIT")
        try ghosttyCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &wantUnwrap), "FORMATTER_OPT_UNWRAP")
        try ghosttyCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &wantTrim), "FORMATTER_OPT_TRIM")
        try ghosttyCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &wantExtras), "FORMATTER_OPT_EXTRAS")
        if var selection {
            try ghosttyCheck(
                ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection), "FORMATTER_OPT_SELECTION")
        }
        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        try ghosttyCheck(
            ghostty_formatter_format_alloc(formatter, nil, &buffer, &length), "ghostty_formatter_format_alloc")
        guard let buffer else { return [] }
        defer { ghostty_free(nil, buffer, length) }
        return Array(UnsafeBufferPointer(start: buffer, count: length))
    }
}
