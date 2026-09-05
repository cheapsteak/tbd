import Foundation
import SwiftTerm

/// Renders a terminal's retained scrollback and current screen as styled lines.
///
/// **Every function here reads `Terminal` state, so the caller must hold
/// `terminal.terminalLock` for the whole call.** `Terminal` is not `Sendable`,
/// does not lock itself, and is fed from a different thread than the one
/// rendering it in both processes that use this — the daemon's drain thread
/// against its emulator, the app's IO thread against its view. Reading a buffer
/// mid-parse garbles the output rather than crashing, which is why the rule is
/// stated rather than left to be noticed. The lock is not taken here because
/// it is not re-entrant and every real caller is already inside it: the whole
/// snapshot — mode capture, this walk, and the alt-screen toggle around it —
/// has to be one critical section or the pieces disagree about which screen
/// they describe.
///
/// Each returned line is self-contained: it opens with an SGR run and carries
/// its own attribute changes, so a reader can begin at any line. Lines carry no
/// terminator — the caller joins them with `\r\n` and must not add a trailing
/// one, because a trailing newline scrolls one extra row into the receiver's
/// scrollback (the same rule `ReplayWriter.assemble` follows for the same
/// reason).
public enum TerminalCellWalk {
    public static func styledHistory(of terminal: Terminal, maxScrollbackLines: Int) -> String {
        join(lines(of: terminal, maxScrollbackLines: maxScrollbackLines), cols: terminal.cols)
    }

    public static func styledViewport(of terminal: Terminal) -> String {
        let rows = (0..<terminal.rows).compactMap { terminal.getLine(row: $0) }
        return join(rows, cols: terminal.cols)
    }

    /// Joins rendered lines with `\r\n` — but ONLY before a line that is not a
    /// wrapped continuation. A continuation must follow its predecessor with no
    /// line ending at all, so the receiver's DECAWM re-wraps it at its own
    /// width. Emitting a separator there hard-breaks the line instead, and no
    /// assertion about the resulting text can tell the two apart.
    ///
    /// A line's own `isWrapped` says whether IT continues its predecessor —
    /// that is what gates the separator above. Whether a line must itself be
    /// emitted at full width is the opposite question: whether the NEXT line
    /// continues it. Reusing `isWrapped` for both pads the last physical row
    /// of a wrapped paragraph out to the full column count with blank cells
    /// instead of trimming it, because that row's own flag is `true` (it
    /// continues the row above) even though nothing continues it.
    private static func join(_ lines: [BufferLine], cols: Int) -> String {
        var out = ""
        for (index, line) in lines.enumerated() {
            if index > 0 && !line.isWrapped { out += "\r\n" }
            let continuesToNextLine = index + 1 < lines.count && lines[index + 1].isWrapped
            out += render(line: line, cols: cols, fullWidth: continuesToNextLine)
        }
        return out
    }

    private static func lines(of terminal: Terminal, maxScrollbackLines: Int) -> [BufferLine] {
        // `Buffer.lines` is internal and there is no public line count, so the
        // only way to enumerate is to walk from the oldest retained row until
        // the accessor stops answering. See HolderReader.swift:893-906.
        var rows: [Int] = []
        var row = terminal.buffer.totalLinesTrimmed
        while terminal.getScrollInvariantLine(row: row) != nil {
            rows.append(row)
            row += 1
        }

        // Keep the TAIL when capping: the newest scrollback is the part a
        // returning viewer is looking for. The viewport always survives.
        let viewportRows = terminal.rows
        if rows.count > maxScrollbackLines + viewportRows {
            rows = Array(rows.suffix(maxScrollbackLines + viewportRows))
        }

        var walked = rows.compactMap { terminal.getScrollInvariantLine(row: $0) }

        // Rows below the cursor that were never written to carry no
        // information — an attaching viewer's screen is already blank there —
        // and each one is a hard break (never a wrap continuation), so walking
        // them fragments an otherwise-unbroken line into several pieces that
        // still render identically on screen. Drop them from the tail only; a
        // blank line earlier in the buffer is real content and stays.
        // `styledViewport` does not apply this trim: on the alt screen a blank
        // trailing row is the application's own layout, not unused padding.
        while let last = walked.last, !last.isWrapped, last.getTrimmedLength() == 0 {
            walked.removeLast()
        }

        return walked
    }

    private static func render(line: BufferLine, cols: Int, fullWidth: Bool) -> String {
        // A line the next one wraps from is emitted at full width; `join` is
        // what withholds its line ending so DECAWM re-wraps it in the
        // receiver. Otherwise the line is trimmed, so a mostly-empty screen
        // does not cost `cols` bytes/row.
        //
        // The full-width branch caps at `line.count`, not just `cols`: a
        // scrollback line shorter than the terminal's current column count
        // (reachable around resize/reflow) would otherwise read past its own
        // storage — `BufferLine`'s subscript clamps an out-of-range index to
        // its last cell instead of trapping, which would silently repeat
        // that cell out to `cols`.
        let limit = fullWidth ? min(cols, line.count) : min(line.getTrimmedLength(), cols)
        guard limit > 0 else { return "" }

        var out = ""
        var openAttribute: Attribute?
        for column in 0..<limit {
            let cell = line[column]
            // The trailing half of a wide character. Emitting it would double
            // every CJK glyph and every emoji.
            if cell.width == 0 { continue }
            if openAttribute != cell.attribute {
                out += SGREncoder.sequence(for: cell.attribute)
                openAttribute = cell.attribute
            }
            // An unwritten or erased cell carries code 0, and
            // `CharData.getCharacter()` renders that literally as
            // `Character(Unicode.Scalar(0))`. On the receiving terminal 0x00
            // is an `.execute` code with no case in ground-state dispatch —
            // it logs an unknown code and advances nothing, so the column
            // collapses instead of holding a position: `ESC[10Chello` comes
            // back as `hello` at column 0, and any background colour on the
            // blank cell is lost with it. A space cell moves the cursor
            // forward exactly one column, under whatever SGR run is already
            // open, so a coloured blank still paints its background.
            let character = cell.getCharacter()
            out.append(character == Character(Unicode.Scalar(0)) ? " " : character)
        }
        // Never leave an attribute open across a line boundary.
        if openAttribute != nil { out += "\u{1b}[0m" }
        return out
    }
}
