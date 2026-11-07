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
    /// The retained scrollback plus viewport, for replaying into a fresh
    /// terminal: the history half of `TerminalSnapshotWriter`'s preamble.
    /// Trailing blank rows stay whenever the walk holds history, because the
    /// receiver's scroll depends on them (see `lines`).
    public static func styledHistory(of terminal: Terminal, maxScrollbackLines: Int) -> String {
        join(
            lines(of: terminal, maxScrollbackLines: maxScrollbackLines, purpose: .replay),
            cols: terminal.cols, purpose: .replay)
    }

    /// The same walk for a capture that is printed rather than replayed: the
    /// Closed Terminals file that `HolderReader.closedTerminalCapture` and
    /// `ViewerScreenProducer` both write, which a revive `cat`s under its own
    /// banner. No receiver scrolls through it, so trailing blank rows always
    /// go: kept, each would push the revived prompt one more line below the
    /// session's last line. Both stores call this, so their captures stay
    /// identical.
    ///
    /// A capture is read as text too: the Session History viewer, which a
    /// dev server's "Show last output" also opens, shows it through
    /// `ANSIEscape.strip`, which deletes every escape sequence and leaves
    /// every other control character in place. So a capture holds only text
    /// and SGR runs, and every blank it sends is a space: ECH and CUF would
    /// strip to nothing and close up the gap they stand for, and a BS would
    /// land in the text as a raw U+0008. A revive may also print a capture
    /// into a tab narrower than the session's, where CUF stops at the last
    /// column while a space wraps. For that tab, each row ends at its last
    /// character, so a row coloured out to the edge does not wrap there into
    /// an extra row of coloured spaces.
    public static func styledCapture(of terminal: Terminal, maxScrollbackLines: Int) -> String {
        join(
            lines(of: terminal, maxScrollbackLines: maxScrollbackLines, purpose: .capture),
            cols: terminal.cols, purpose: .capture)
    }

    public static func styledViewport(of terminal: Terminal) -> String {
        let rows = (0..<terminal.rows).compactMap { terminal.getLine(row: $0) }
        return join(rows, cols: terminal.cols, purpose: .replay)
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
    ///
    /// Every row moves the receiver down exactly one row: a hard break by its
    /// `\r\n`, a continuation by the wrap its first printed cell causes. That
    /// is why `render` always prints a continuation's first cell, even on a
    /// row that holds nothing (see `continuation` there). The first walked row
    /// is never treated as a continuation, because nothing above it on the
    /// receiver leaves a pending wrap to continue. A capture has no receiver
    /// to keep in step, so it sends rows as they are (see `styledCapture`).
    private static func join(_ lines: [BufferLine], cols: Int, purpose: Purpose) -> String {
        var out = ""
        for (index, line) in lines.enumerated() {
            if index > 0 && !line.isWrapped { out += "\r\n" }
            let continuesPreviousLine = index > 0 && line.isWrapped
            let continuesToNextLine = index + 1 < lines.count && lines[index + 1].isWrapped
            out += render(
                line: line, cols: cols, fullWidth: continuesToNextLine,
                continuation: continuesPreviousLine, purpose: purpose)
        }
        return out
    }

    /// What a walk is for: a replay into a receiver that must end up as the
    /// source is, or a capture that is printed and read rather than replayed.
    /// It decides whether trailing blank rows may go and how blanks are sent.
    private enum Purpose {
        case replay
        case capture
    }

    private static func lines(
        of terminal: Terminal, maxScrollbackLines: Int, purpose: Purpose
    ) -> [BufferLine] {
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

        // A replay drops trailing blank rows only when the walk holds no row
        // above the viewport. The receiver starts on an erased screen with
        // the cursor at home, and once it reaches its bottom row, every
        // further row it is sent scrolls one row into its scrollback. So for
        // the viewport to land where it was, a walk that holds history must
        // send every row and move the receiver down one row for each (`join`
        // says how a continuation does). Each trailing row dropped is a
        // scroll the receiver never makes: the viewport lands that many rows
        // low, the history comes up that many rows short, and the absolute
        // cursor address that ends the snapshot points at the wrong line. The
        // cap above changes only how much history there is, so the same test
        // holds for a capped walk.
        //
        // Without history the receiver never scrolls, its screen below the
        // last row sent is already blank, and the closing cursor address puts
        // the cursor back wherever it was. There a trailing blank row adds
        // only a line ending, so dropping it lets a short screen walk as its
        // text instead of its text plus a run of empty lines. A row is blank
        // when `render` sends none of it (`sentLength` is 0), so in a replay
        // a row of coloured blanks stays. A wrapped continuation is never
        // dropped, and a blank row earlier in the walk is real content and
        // stays.
        //
        // A capture always drops them: it is printed, not replayed, so there
        // is no scroll to protect (see `styledCapture`).
        //
        // `styledViewport` does not apply this trim: on the alt screen a blank
        // trailing row is the application's own layout, not unused padding.
        let holdsHistory = walked.count > viewportRows
        if purpose == .capture || !holdsHistory {
            while let last = walked.last, !last.isWrapped,
                  sentLength(of: last, cols: terminal.cols, purpose: purpose) == 0 {
                walked.removeLast()
            }
        }

        return walked
    }

    /// How many leading cells `render` sends of a line that no later line
    /// continues. A replay sends its `visibleLength`. A capture sends through
    /// the last character only (see `styledCapture`).
    private static func sentLength(of line: BufferLine, cols: Int, purpose: Purpose) -> Int {
        switch purpose {
        case .replay:
            return visibleLength(of: line, cols: cols)
        case .capture:
            return min(line.getTrimmedLength(), cols)
        }
    }

    /// How many leading cells a receiver needs to show `line` as the source
    /// does: through the last character, or through the last blank that
    /// `isVisibleWhenBlank` says can be seen, whichever is further.
    ///
    /// `getTrimmedLength()` alone is not enough. It stops after the last cell
    /// with a character, and erasing under a background colour (BCE, such as
    /// `ESC[44m ESC[2J`, `ESC[41m ESC[K`, ECH or DCH) leaves blanks with no
    /// character that still carry the colour. A receiver that is not sent
    /// them shows the default background there.
    ///
    /// When what a line prints reaches the last column, the receiver is left
    /// in pending wrap, as it is after any line of text that long. Nothing
    /// that follows prints before the cursor moves: `join` sends `\r\n` next,
    /// whose CR clears the pending wrap before the LF moves down, and after
    /// the last line the writer sends only mode escapes and cursor moves
    /// before anything prints again. So no extra row wraps.
    ///
    /// Only the first `cols` cells count, because `render` never sends one
    /// past them. A line can hold more: the alternate screen has no
    /// scrollback, so narrowing the terminal does not reflow it, and its rows
    /// keep their old width. A coloured blank out there is off screen, and
    /// counting it would stretch the row to the last column with blanks the
    /// source shows as nothing.
    private static func visibleLength(of line: BufferLine, cols: Int) -> Int {
        let width = min(line.count, cols)
        let trimmed = min(line.getTrimmedLength(), width)
        // Every cell from `trimmed` on has no character, so only attributes
        // can make one of them visible.
        var length = width
        while length > trimmed {
            if isVisibleWhenBlank(line[length - 1].attribute) { return length }
            length -= 1
        }
        return trimmed
    }

    /// Whether a cell with no character looks different from the erased cells
    /// a receiver starts with, which the prelude erased under SGR 0.
    ///
    /// A background colour fills the cell, and inverse fills it with the
    /// foreground colour. Underline and strikethrough are lines a terminal
    /// draws across the cell whether or not it holds a glyph. Bold, dim,
    /// italic, blink, invisible and a foreground colour change only how a
    /// glyph is drawn, and a blank has none, so they do not count. SwiftTerm's
    /// erase keeps only the background, so the background is the case erasing
    /// produces; the other three count because a blank that carried them would
    /// be just as visible. Both default background cases count as default,
    /// because `SGREncoder` writes neither and the receiver cannot tell them
    /// apart.
    private static func isVisibleWhenBlank(_ attribute: Attribute) -> Bool {
        switch attribute.bg {
        case .defaultColor, .defaultInvertedColor:
            break
        case .ansi256, .trueColor:
            return true
        }
        let style = attribute.style
        return style.contains(.inverse)
            || style.contains(.underline) || attribute.underlineStyle != .none
            || style.contains(.crossedOut)
    }

    /// Whether ECH, sent under this attribute's SGR, leaves a blank that
    /// carries exactly this attribute. SwiftTerm's erase cell keeps only the
    /// background, so it does for a default foreground and no style.
    private static func erasesExactly(_ attribute: Attribute) -> Bool {
        attribute.fg == .defaultColor && attribute.style.isEmpty
            && attribute.underlineStyle == .none && attribute.underlineColor == nil
    }

    /// An unwritten or erased cell: code 0, one column wide. The trailing
    /// half of a wide character also has code 0, but no width.
    private static func isBlank(_ cell: CharData) -> Bool {
        cell.width == 1 && cell.getCharacter() == Character(Unicode.Scalar(0))
    }

    /// The column just past the run of blanks from `start` that `render`
    /// erases with ECH, at most `end`, or `start` itself when the blank at
    /// `start` goes as a space instead.
    ///
    /// ECH leaves a cell with no character, as the source's blank is, so a
    /// receiver's row comes out no longer than the source's. That length is
    /// what reflow wraps by, so a row of coloured spaces wraps on a narrower
    /// screen where the source's row of coloured blanks does not, and
    /// pushes rows into history the source never had. Two kinds of blank go
    /// this way: one past the line's last character (`trimmed`), whatever its
    /// background, and one under a background colour anywhere. A default
    /// blank before the last character changes neither the row's length nor
    /// its look, so it stays a space.
    ///
    /// Only a blank ECH can reproduce goes this way (`erasesExactly`), and a
    /// run holds one attribute, because ECH erases under the SGR that is open
    /// when it is sent.
    private static func erasedRunEnd(
        of line: BufferLine, from start: Int, before end: Int, trimmed: Int
    ) -> Int {
        let attribute = line[start].attribute
        guard erasesExactly(attribute), start >= trimmed || isVisibleWhenBlank(attribute)
        else { return start }
        var column = start
        while column < end, isBlank(line[column]), line[column].attribute == attribute {
            column += 1
        }
        return column
    }

    private static func render(
        line: BufferLine, cols: Int, fullWidth: Bool, continuation: Bool, purpose: Purpose
    ) -> String {
        // A line the next one wraps from is emitted at full width; `join` is
        // what withholds its line ending so DECAWM re-wraps it in the
        // receiver. Otherwise the line ends at its `sentLength`, so a
        // mostly-empty screen does not cost `cols` bytes/row, and in a
        // replay a coloured blank at the end of a line still arrives.
        //
        // The full-width branch caps at `line.count`, not just `cols`: a
        // scrollback line shorter than the terminal's current column count
        // (reachable around resize/reflow) would otherwise read past its own
        // storage — `BufferLine`'s subscript clamps an out-of-range index to
        // its last cell instead of trapping, which would silently repeat
        // that cell out to `cols`.
        //
        // In a replay, a continuation always sends at least its first cell.
        // The receiver reaches a continuation only by printing past the edge
        // of the row above, because SwiftTerm wraps when it prints and at no
        // other time, so a continuation that sent nothing would leave the
        // receiver one row short, with the viewport one row low and the
        // closing cursor address on the row above. EL never clears a row's
        // wrap flag, so `ESC[2K` on a wrapped row leaves exactly that: a
        // continuation with nothing in it. Sending a line break there instead
        // would land the receiver on the row too, but as a hard break: reflow
        // on a resize and selection would then split a line the source keeps
        // whole, and a handback would carry that split to the daemon. A
        // capture has no receiver to keep in step, so an empty continuation
        // sends nothing there.
        var limit = fullWidth
            ? min(cols, line.count)
            : sentLength(of: line, cols: cols, purpose: purpose)
        if purpose == .replay && continuation { limit = max(limit, min(1, line.count)) }
        guard limit > 0 else { return "" }

        // On a row the next one continues, ECH runs stop one cell short of
        // the end, so the last cell prints whatever it holds, a blank as a
        // space. Only printing in the last column leaves the receiver in
        // pending wrap, which is what carries the continuation's first cell
        // onto the next row.
        let eraseLimit = fullWidth ? limit - 1 : limit
        let trimmed = line.getTrimmedLength()

        var out = ""
        var openAttribute: Attribute?
        var column = 0
        while column < limit {
            let cell = line[column]
            // The trailing half of a wide character. Emitting it would double
            // every CJK glyph and every emoji.
            if cell.width == 0 {
                column += 1
                continue
            }
            if openAttribute != cell.attribute {
                out += SGREncoder.sequence(for: cell.attribute)
                openAttribute = cell.attribute
            }
            // An unwritten or erased cell carries code 0, and
            // `CharData.getCharacter()` renders that literally as
            // `Character(Unicode.Scalar(0))`, which must not reach the wire.
            // On the receiving terminal 0x00 is an `.execute` code with no
            // case in ground-state dispatch — it logs an unknown code and
            // advances nothing, so the column collapses instead of holding a
            // position: `ESC[10Chello` comes back as `hello` at column 0.
            let character = cell.getCharacter()
            guard character == Character(Unicode.Scalar(0)) else {
                out.append(character)
                column += 1
                continue
            }
            // In a replay a blank goes one of two ways. A run `erasedRunEnd`
            // accepts is erased with ECH under the run's SGR, which paints the
            // background and moves nothing, then stepped over with CUF. The
            // CUF is left off when the run ends the row, because a line
            // ending or the end of the walk comes next. Any other blank goes
            // as a space, which moves the cursor one column under the open
            // SGR, so a styled blank still shows. In a capture every blank
            // goes as a space (see `styledCapture`).
            let runEnd = purpose == .replay
                ? erasedRunEnd(of: line, from: column, before: eraseLimit, trimmed: trimmed)
                : column
            guard runEnd > column else {
                out.append(" ")
                column += 1
                continue
            }
            // A continuation's first cell is printed all the same, because
            // printing is what wraps the receiver onto the row (see above).
            // BS then backs over it, so the run erases it with the rest.
            if continuation && column == 0 { out += " \u{8}" }
            let count = runEnd - column
            out += "\u{1b}[\(count)X"
            if runEnd < limit { out += "\u{1b}[\(count)C" }
            column = runEnd
        }
        // Never leave an attribute open across a line boundary.
        if openAttribute != nil { out += "\u{1b}[0m" }
        return out
    }
}
