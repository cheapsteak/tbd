import Foundation
import SwiftTerm
import TBDGhosttyTerminal

/// SwiftTerm's own link detection, for the libghostty engine, which has none: the URL or path the
/// SwiftTerm engine finds under a ⌘-click on the same screen, soft-wrapped across rows or not.
///
/// The SwiftTerm engine finds it in its view's mouse-up, which looks the release up with
/// `Terminal.link(at:mode:)` and hands what it finds to `requestOpenLink`. The matcher behind that
/// call (Ghostty's URL and path pattern, and the rule for which rows a soft wrap or an editor's
/// hard wrap joins into one line) is private to SwiftTerm, and the call is the one way in. So the
/// rows the libghostty view read at the press, those on view and those its lines run on into, are
/// written into a headless SwiftTerm terminal as wide as the grid and as tall as the rows read, each
/// character at its column and each soft wrap made the way a program makes one, by printing on past
/// the end of the row, and SwiftTerm is asked what is under the pressed cell.
enum SwiftTermLinkDetector {
    /// The link SwiftTerm finds under the pressed cell of `clicked`, or nil.
    static func link(in clicked: GhosttyClickedText) -> String? {
        guard clicked.columns > 0, clicked.rows.indices.contains(clicked.row),
              (0..<clicked.columns).contains(clicked.column) else { return nil }
        let silent = SilentDelegate()
        let terminal = SwiftTerm.Terminal(
            delegate: silent,
            options: TerminalOptions(cols: clicked.columns, rows: clicked.rows.count, scrollback: 0))
        return withExtendedLifetime(silent) {
            terminal.terminalLock.withLock { () -> String? in
                Self.write(clicked.rows, into: terminal)
                return terminal.link(
                    at: .screen(Position(col: clicked.column, row: clicked.row)), mode: .explicitAndImplicit)
            }
        }
    }

    /// Writes `rows` into `terminal`, a new one their size, so that its cells hold the same
    /// characters at the same columns and its rows wrap where theirs did. A cell with no text is
    /// left as SwiftTerm leaves one, never written; the second half of a wide character is the
    /// character's own.
    private static func write(_ rows: [GhosttyClickedText.Row], into terminal: SwiftTerm.Terminal) {
        // Whether the cursor waits to wrap past the last column of the row just written.
        var waitsToWrap = false
        for (index, row) in rows.enumerated() {
            let wraps = row.isWrapContinuation && waitsToWrap
            var bytes = ""
            // The column the cursor is known to sit at, if any.
            var cursorColumn: Int?
            for (column, character) in row.text.enumerated() where character != "\0" {
                if !(wraps && column == 0), cursorColumn != column {
                    bytes += "\u{1b}[\(index + 1);\(column + 1)H"
                }
                bytes.append(character)
                // An ASCII character is one column wide in both terminals; another can be two in
                // one and one in the other, so the next character is placed after it explicitly.
                cursorColumn = character.isASCII ? column + 1 : nil
            }
            terminal.feed(text: bytes)
            // SwiftTerm's cursor sits at `cols` once a character lands in the last column.
            let cursor = terminal.getCursorLocation()
            waitsToWrap = cursor.y == index && cursor.x >= terminal.cols
        }
    }

    /// The headless terminal's delegate. It answers nothing: the terminal is read, never asked.
    /// `Terminal` holds its delegate weakly, so `link(in:)` keeps this alive while it reads.
    private final class SilentDelegate: TerminalDelegate {
        func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {}
    }
}
