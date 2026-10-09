import Foundation
import SwiftTerm
import TBDShared

/// Everything a `TerminalScreen` needs that can be read from a grid, and
/// nothing that cannot.
///
/// The split is the point. A screen's lines, its viewport offset, its cursor
/// *position*, its size and the three child modes are all properties of a
/// `Terminal`, so one walk can produce them for either store. A screen's
/// `source`, `ageMilliseconds`, `modesObserved`, `contentObserved` and its
/// cursor's *visibility* are not: they are facts about which emulator answered,
/// how it came to exist and what it was told, and only the daemon knows them.
/// So this type carries the first set and the daemon stamps the second —
/// which is also why nothing here throws. `TerminalScreen`'s construction is
/// the one place the whitelist is enforced, and it is enforced where the throw
/// can be handled.
public struct ProjectedScreen: Sendable, Equatable {
    /// The requested tail of scrollback plus the viewport, one entry per row,
    /// right-trimmed, with trailing blank rows dropped.
    public let lines: [String]
    /// The index in `lines` of the viewport's first row — `TerminalScreen`'s
    /// field of the same name, with the same two documented out-of-range
    /// cases, derived here so the two stores cannot disagree about the
    /// arithmetic.
    public let viewportStart: Int
    /// The cursor in viewport coordinates. **Position only**: visibility is
    /// `DECTCEM`, which no public SwiftTerm property exposes and which a
    /// `DECRQM` probe must not be used to read (see `project`), so whoever
    /// tracks the child's notifications supplies it.
    public let cursorRow: Int
    public let cursorColumn: Int
    public let size: TerminalScreen.Size
    public let modes: TerminalScreen.ChildModes

    public init(
        lines: [String],
        viewportStart: Int,
        cursorRow: Int,
        cursorColumn: Int,
        size: TerminalScreen.Size,
        modes: TerminalScreen.ChildModes
    ) {
        self.lines = lines
        self.viewportStart = viewportStart
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.size = size
        self.modes = modes
    }
}

/// The one cell walk behind every typed screen, on either side of the
/// transport.
///
/// The pty-holder transport has two stores — the daemon's retained emulator
/// while a session is detached, a viewer's SwiftTerm while it is attached —
/// and the screen contract requires that **the two stores project identically
/// by construction**
/// (`docs/specs/2026-09-05-child-as-contract-party-design.md`). Two
/// implementations that agree today are not that: a fix to the character
/// provider, the trailing-blank trim or the `viewportStart` arithmetic lands in
/// one of them and a reader cannot tell which store answered it. So the walk
/// lives here, in the module both processes already link for the handback
/// preamble, and each store supplies only what is its own.
///
/// **Every function here reads `Terminal` state, so the caller must hold
/// `terminal.terminalLock` for the whole call** — the same rule
/// `TerminalCellWalk` states, for the same reason: `Terminal` is not
/// `Sendable`, does not lock itself, and is fed from a different thread than
/// the one rendering it in both processes. Taking the lock here would also
/// break the guarantee a screen depends on, which is that lines, cursor, size
/// and modes are **one observation**; the caller's single hold is what makes
/// them one fact rather than four.
///
/// **Nothing here feeds the terminal.** No `DECRQM` probe, no alt-screen
/// toggle — a projection runs against a live parser whose last chunk may have
/// ended mid-sequence, and an `ESC` fed into that aborts the child's pending
/// sequence, prints its remainder into the grid as literal text and swallows
/// the reply to a query the child was in the middle of asking.
/// `TerminalSnapshotWriter` does probe, once per attach, and argues that case
/// in its own doc. This is why `ProjectedScreen` carries no cursor visibility
/// and why `modes` reads all three flags from public properties.
public enum TerminalScreenProjection {

    /// The scrollback tail plus viewport as whitelisted plain lines, with the
    /// viewport offset, the cursor position, the grid size and the child's
    /// three modes — one observation of `terminal`, taken under the caller's
    /// lock.
    ///
    /// `maxLines` caps how many lines come back, keeping the **tail**: the
    /// newest rows are what a reader asking for 50 lines wants. `maxLines <= 0`
    /// yields no lines at all, which is what makes a modes-only reading free —
    /// the walk still runs, but nothing is projected and nothing is returned.
    ///
    /// The line walk enumerates from `totalLinesTrimmed`, the absolute index of
    /// the oldest line still held, until `getScrollInvariantLine` returns nil,
    /// because there is no public line count and `Buffer.lines` is internal.
    public static func project(_ terminal: Terminal, maxLines: Int) -> ProjectedScreen {
        var enumerated: [String] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            enumerated.append(rowText(line))
            row += 1
        }
        let enumeratedCount = enumerated.count

        var lines = enumerated
        if maxLines <= 0 {
            lines = []
        } else if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        let droppedFromFront = enumeratedCount - lines.count
        dropTrailingBlanks(&lines)

        // SwiftTerm's line list is always `yBase + rows` long, so the viewport
        // is its tail — but `yBase` is not public, so the index of the
        // viewport's first row is derived from the length instead. The tail cut
        // then shifts it, which is why `droppedFromFront` comes off it: the
        // result is an index into `lines`, not into the buffer. It can land
        // outside `lines` in both directions, which `TerminalScreen`'s own
        // documentation states and callers must bounds check.
        let viewportStart = enumeratedCount - terminal.rows - droppedFromFront

        return ProjectedScreen(
            lines: lines,
            viewportStart: viewportStart,
            cursorRow: terminal.buffer.y,
            cursorColumn: terminal.buffer.x,
            size: TerminalScreen.Size(columns: terminal.cols, rows: terminal.rows),
            modes: modes(of: terminal))
    }

    /// The viewport alone as plain lines, trailing blank rows dropped — the
    /// scrollback-free twin of `project`, for a diagnostic render that wants
    /// the screen a person would be looking at and none of the facts around it.
    ///
    /// Shares `rowText` and the trim with `project` rather than re-deriving
    /// either, which is the whole reason it lives here instead of beside its
    /// caller.
    public static func viewportLines(of terminal: Terminal) -> [String] {
        var lines: [String] = []
        lines.reserveCapacity(terminal.rows)
        for row in 0..<terminal.rows {
            lines.append(terminal.getLine(row: row).map { rowText($0) } ?? "")
        }
        dropTrailingBlanks(&lines)
        return lines
    }

    /// The three child modes, all readable from public properties.
    ///
    /// `TerminalModeCapture` reads these same three the same way, and its
    /// comment records why 1049 in particular must come from the property:
    /// `cmdDecRqm`'s switch does not carry it, so a `DECRQM` query answers
    /// "unknown".
    public static func modes(of terminal: Terminal) -> TerminalScreen.ChildModes {
        TerminalScreen.ChildModes(
            bracketedPaste: terminal.bracketedPasteMode,
            applicationCursor: terminal.applicationCursor,
            alternateScreen: terminal.isCurrentBufferAlternate)
    }

    /// One row of the grid as text, the way a reader of `terminal.output`
    /// needs it: **a cell nobody ever wrote projects as a space, never as
    /// `U+0000`.**
    ///
    /// A never-written or erased cell holds `CharData.Null`, whose code is 0,
    /// and `translateToString`'s default path renders that literally. The
    /// result looks right and is not: a TUI paints differentially, positioning
    /// the cursor past the cells it is leaving alone rather than overwriting
    /// them with blanks, so the skipped cells become invisible NULs scattered
    /// through the line — and which cells get skipped changes with every
    /// repaint, so the holes appear to move. Every consumer of this string
    /// matches on text (fleet supervision, the pending-input rail, the login
    /// driver), and a NUL is a missing character nothing displays. `tmux
    /// capture-pane`, which this replaces for machine reads, returns spaces;
    /// so does the styled serializer in `TerminalCellWalk`.
    ///
    /// `skipNullCellsFollowingWide` is the other half and not optional: the
    /// trailing cell of a two-column glyph carries code 0 as well, and padding
    /// *it* to a space would put a stray blank after every CJK character and
    /// every emoji. Trimming is unaffected — `trimRight` is computed from
    /// `getTrimmedLength()` before the projection runs, so a row nobody wrote
    /// still renders empty rather than as a row of spaces.
    ///
    /// **`U+0000` is not the only cell a screen line may not hold.** SwiftTerm's
    /// printable-run inserter takes every byte from `0x20` through `0x7f`
    /// without consulting a width, so a `printf '\x7f'` leaves a `DEL` in a cell
    /// — legal for a child to emit, and refused by `TerminalScreen`'s
    /// whitelist. Mapping only the NUL would therefore let one such byte break
    /// *every* later read of that session until the line left the scrollback: a
    /// session-wide outage caused by the session's own output.
    ///
    /// `DEL` is the only one reachable today — a C1 control is dropped before
    /// insertion, because non-ASCII goes through a width table and nothing of
    /// width zero is inserted. The projection is written against
    /// `TerminalScreen.isDisallowed` anyway, rather than against the list of
    /// scalars currently known to get through: the render and the whitelist
    /// cannot disagree if they read the same predicate, and a width table that
    /// changes its mind cannot reopen the outage. `U+FFFD` rather than a space
    /// for these, because unlike a never-written cell something *was* written
    /// and a reader should see that something is there.
    public static func rowText(_ line: BufferLine) -> String {
        line.translateToString(
            trimRight: true,
            skipNullCellsFollowingWide: true,
            characterProvider: { cell in
                let character = cell.getCharacter()
                if character == Character(Unicode.Scalar(0)) { return " " }
                guard character.unicodeScalars.contains(where: TerminalScreen.isDisallowed) else {
                    return character
                }
                return "\u{FFFD}"
            })
    }

    /// Drops trailing blank rows — a screen is 24 rows whether or not the job
    /// filled them, and shipping 20 empty ones helps nobody.
    ///
    /// It deliberately does **not** stop at the viewport's first row, which is
    /// one of the two reasons `viewportStart` can land past the end of `lines`.
    private static func dropTrailingBlanks(_ lines: inout [String]) {
        while let last = lines.last, last.isEmpty { lines.removeLast() }
    }
}
