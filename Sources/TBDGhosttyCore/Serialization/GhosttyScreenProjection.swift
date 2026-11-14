// The daemon's screen requests and styled captures, answered from a libghostty terminal.
//
// A viewer that runs libghostty answers the same requests a SwiftTerm viewer answers through
// `TerminalScreenProjection.project` and `TerminalCellWalk.styledCapture`, so a reader cannot tell
// which engine replied. Each walk below follows its SwiftTerm twin step by step, and the comments
// name the step. `ProjectionParityTests` holds the two to each other across the handover corpus.
// Scoped, as `TerminalScreenProjection` does: only the screen model is needed from TBDShared.
import struct TBDShared.ProjectedScreen
import struct TBDShared.TerminalScreen

public enum GhosttyScreenProjection {
    /// The scrollback tail plus the screen as plain lines, with the viewport offset, the cursor,
    /// the size and the child's three modes: one reading, taken inside `withLocked`.
    ///
    /// The same contract as `TerminalScreenProjection.project`: `maxLines` keeps the newest lines,
    /// trailing blank lines are dropped, and `maxLines <= 0` reads no row at all.
    public static func project(_ state: GhosttyTerminalState, maxLines: Int) -> ProjectedScreen {
        let rows = state.rows
        let cursor = state.cursor
        // SwiftTerm marks a pending wrap by putting the cursor one past the last column, where
        // libghostty keeps it in the last column with a flag. Report SwiftTerm's form.
        let cursorColumn = cursor.col + (state.cursorPendingWrap ? 1 : 0)
        let size = TerminalScreen.Size(columns: state.cols, rows: rows)
        let modes = TerminalScreen.ChildModes(
            bracketedPaste: state.mode(2004),
            applicationCursor: state.mode(1),
            alternateScreen: state.isAlternateScreen)

        guard maxLines > 0, !state.isClosed else {
            return ProjectedScreen(
                lines: [], viewportStart: -rows, cursorRow: cursor.row, cursorColumn: cursorColumn,
                size: size, modes: modes)
        }
        let history = state.historyRowCount
        let total = history + rows
        let kept = min(maxLines, total)
        var lines: [String] = []
        lines.reserveCapacity(kept)
        // Only the kept tail is read. SwiftTerm reads every row and then cuts, which comes to the same.
        for index in (total - kept)..<total {
            lines.append(row(state, index, history: history).map(rowText) ?? "")
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }

        // SwiftTerm's `enumeratedCount - rows - droppedFromFront`, with `droppedFromFront` equal to
        // `total - kept`.
        return ProjectedScreen(
            lines: lines, viewportStart: kept - rows, cursorRow: cursor.row, cursorColumn: cursorColumn,
            size: size, modes: modes)
    }

    /// The scrollback tail plus the screen with SGR styling, the way `TerminalCellWalk.styledCapture`
    /// renders a SwiftTerm terminal: soft-wrapped rows joined, trailing blank rows dropped, and
    /// blanks as spaces.
    public static func styledCapture(_ state: GhosttyTerminalState, maxScrollbackLines: Int) -> String {
        guard !state.isClosed else { return "" }
        let rows = state.rows
        let cols = state.cols
        let history = state.historyRowCount
        let total = history + rows
        let kept = min(total, max(0, maxScrollbackLines) + rows)
        var lines: [GhosttyGridRow] = ((total - kept)..<total).map { index in
            row(state, index, history: history) ?? GhosttyGridRow(cells: [], isWrapContinuation: false)
        }
        // A capture drops trailing rows that show nothing and do not continue a wrapped line.
        while let last = lines.last, !last.isWrapContinuation, captureLength(last.cells, cols: cols) == 0 {
            lines.removeLast()
        }

        var out = ""
        for index in lines.indices {
            let line = lines[index]
            if index > 0 && !line.isWrapContinuation { out += "\r\n" }
            let continuesToNextLine = index + 1 < lines.count && lines[index + 1].isWrapContinuation
            out += renderCapture(line.cells, cols: cols, fullWidth: continuesToNextLine)
        }
        return out
    }

    // MARK: - Rows

    /// Row `index` counted from the oldest scrollback row, with the screen after the scrollback.
    private static func row(_ state: GhosttyTerminalState, _ index: Int, history: Int) -> GhosttyGridRow? {
        index < history ? state.gridRow(.history, index) : state.gridRow(.active, index - history)
    }

    /// `TerminalScreenProjection.rowText`: `translateToString(trimRight: true,
    /// skipNullCellsFollowingWide: true)` with its character provider. A cell with no text reads as
    /// a space, a scalar `TerminalScreen` refuses reads as U+FFFD, and the second half of a wide
    /// character is skipped.
    static func rowText(_ row: GhosttyGridRow) -> String {
        let cells = row.cells
        let limit = min(cells.count, trimmedLength(cells))
        var out = ""
        var index = 0
        while index < limit {
            let cell = cells[index]
            if index > 0 && cell.code == 0 && cells[index - 1].columns == 2 {
                index += 1
                continue
            }
            out += projectedText(cell)
            if cell.columns == 2, index + 1 < limit, cells[index + 1].code == 0 {
                index += 2
                continue
            }
            index += 1
        }
        return out
    }

    private static func projectedText(_ cell: GhosttyGridCell) -> String {
        guard cell.code != 0 else { return " " }
        let text = cell.text
        return text.unicodeScalars.contains(where: TerminalScreen.isDisallowed) ? "\u{FFFD}" : text
    }

    /// SwiftTerm's `BufferLine.getTrimmedLength`: the end of the last cell that holds text, wide
    /// cells counted at full width.
    static func trimmedLength(_ cells: [GhosttyGridCell]) -> Int {
        for index in cells.indices.reversed() where cells[index].code != 0 {
            return index + cells[index].columns
        }
        return 0
    }

    /// `TerminalCellWalk.trimmedLength`: `trimmedLength` clamped to the row, so a wide character at
    /// the last column cannot claim a column past the edge.
    static func captureLength(_ cells: [GhosttyGridCell], cols: Int) -> Int {
        let width = min(cells.count, cols)
        let trimmed = trimmedLength(cells)
        guard trimmed > width else { return trimmed }
        for column in (0..<width).reversed() where cells[column].code != 0 {
            return min(column + cells[column].columns, width)
        }
        return 0
    }

    // MARK: - Capture rendering

    /// `TerminalCellWalk.render` for a capture. A row is rendered to its trimmed length, or to the
    /// full width when the next row continues it, opening an SGR run wherever the style changes.
    ///
    /// The run is compared by the sequence it encodes to, not by the raw style: libghostty keeps
    /// attributes SwiftTerm has no field for, overline among them, and a change in one of those
    /// alone must not open a run SwiftTerm would never open.
    static func renderCapture(_ cells: [GhosttyGridCell], cols: Int, fullWidth: Bool) -> String {
        let limit = fullWidth ? min(cols, cells.count) : captureLength(cells, cols: cols)
        guard limit > 0 else { return "" }
        var out = ""
        var openSequence: String?
        var column = 0
        while column < limit {
            let cell = cells[column]
            if cell.columns == 0 {
                column += 1
                continue
            }
            let sequence = sgrSequence(cell.style)
            if openSequence != sequence {
                out += sequence
                openSequence = sequence
            }
            if column + cell.columns > cols {
                out.append(" ")
            } else {
                out += cell.code == 0 ? " " : cell.text
            }
            column += 1
        }
        if openSequence != nil { out += "\u{1b}[0m" }
        return out
    }

    /// `SGREncoder.sequence(for:)` for a libghostty style: a reset, then the attributes SwiftTerm
    /// can hold, in the order it writes them.
    static func sgrSequence(_ style: GhosttyCellStyle) -> String {
        var parts = ["0"]
        let flags = style.flags
        if flags & GhosttyCellStyle.bold != 0 { parts.append("1") }
        if flags & GhosttyCellStyle.faint != 0 { parts.append("2") }
        if flags & GhosttyCellStyle.italic != 0 { parts.append("3") }
        if flags & GhosttyCellStyle.blink != 0 { parts.append("5") }
        if flags & GhosttyCellStyle.inverse != 0 { parts.append("7") }
        if flags & GhosttyCellStyle.invisible != 0 { parts.append("8") }
        if flags & GhosttyCellStyle.strikethrough != 0 { parts.append("9") }
        switch style.underline {
        case 0: break
        case 2: parts.append("4:2")
        case 3: parts.append("4:3")
        case 4: parts.append("4:4")
        case 5: parts.append("4:5")
        default: parts.append("4")
        }
        parts += colorParameters(style.foreground, base: 30, bright: 90, extended: 38)
        parts += colorParameters(style.background, base: 40, bright: 100, extended: 48)
        switch style.underlineColor {
        case .none: break
        // Underline colour has no 16-colour form, so a palette index is always written in full.
        case .palette(let index): parts += ["58", "5", "\(index)"]
        case .rgb(let red, let green, let blue): parts += ["58", "2", "\(red)", "\(green)", "\(blue)"]
        }
        return "\u{1b}[" + parts.joined(separator: ";") + "m"
    }

    private static func colorParameters(_ color: GhosttyCellColor, base: Int, bright: Int, extended: Int) -> [String] {
        switch color {
        case .none:
            return []
        case .rgb(let red, let green, let blue):
            return ["\(extended)", "2", "\(red)", "\(green)", "\(blue)"]
        case .palette(let index):
            let value = Int(index)
            // The 256-colour range starts at 16. Below it, the 16-colour forms.
            if value >= 16 { return ["\(extended)", "5", "\(value)"] }
            return value >= 8 ? ["\(bright + value - 8)"] : ["\(base + value)"]
        }
    }
}
