import Foundation
import SwiftTerm
import Testing

// Scoped, for the reason `TerminalScreenProjection` itself imports this way:
// `TBDShared.Terminal` is the DB row model and `SwiftTerm.Terminal` is the
// emulator, and every bare `Terminal` below is the emulator.
import struct TBDShared.TerminalScreen

@testable import TBDTerminalSerialization

/// The shared projection must produce exactly what the daemon's private walk
/// produced before it was lifted out.
///
/// The screen contract requires that the daemon's retained emulator and a
/// viewer's SwiftTerm "project identically by construction", and a projection
/// that lives in one shared place is how that is held. But a lift is only
/// trustworthy if it changed nothing, and "the existing suites still pass" is
/// evidence about the cases those suites happen to cover
/// (`HolderScreenContractTests`, `HolderRenderProjectionTests`) rather than
/// about the walk as a whole.
///
/// So this suite carries `Reference`: the pre-lift code, verbatim — the cell
/// walk, the character provider, the tail cut, the trailing-blank trim and the
/// `viewportStart` arithmetic exactly as they read inside `HolderEmulator` —
/// and asserts field-by-field equality against `TerminalScreenProjection` over
/// screens built to exercise each of those pieces. A copy is normally the thing
/// to avoid; here it is the measurement, and it is confined to a test so no
/// production path can read it.
///
/// **It discriminates.** Every rule under test is one a plausible transcription
/// slip would break: substitute `U+0000` with `U+FFFD` instead of a space, trim
/// before the tail cut instead of after, keep the head instead of the tail,
/// forget `skipNullCellsFollowingWide`, or subtract `droppedFromFront` the
/// wrong way, and one of these cases disagrees.
///
/// Both sides are driven through a real `Terminal` fed real bytes, never a
/// hand-built grid: a fixture that assembled rows itself would agree with
/// anything.
@Suite struct TerminalScreenProjectionParityTests {

    private static let esc = "\u{1b}"

    // MARK: - The reference: the walk as it stood before the lift

    /// `HolderEmulator.screen`'s body, minus everything only the daemon knows.
    ///
    /// Copied rather than called on purpose — see the suite's doc. Caller holds
    /// `terminal.terminalLock`, as the production projection's caller does.
    private enum Reference {
        static func project(_ terminal: Terminal, maxLines: Int) -> ProjectedScreen {
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
            while let last = lines.last, last.isEmpty { lines.removeLast() }

            let viewportStart = enumeratedCount - terminal.rows - droppedFromFront

            return ProjectedScreen(
                lines: lines,
                viewportStart: viewportStart,
                cursorRow: terminal.buffer.y,
                cursorColumn: terminal.buffer.x,
                size: TerminalScreen.Size(columns: terminal.cols, rows: terminal.rows),
                modes: TerminalScreen.ChildModes(
                    bracketedPaste: terminal.bracketedPasteMode,
                    applicationCursor: terminal.applicationCursor,
                    alternateScreen: terminal.isCurrentBufferAlternate))
        }

        static func rowText(_ line: BufferLine) -> String {
            line.translateToString(
                trimRight: true,
                skipNullCellsFollowingWide: true,
                characterProvider: { cell in
                    let character = cell.getCharacter()
                    if character == Character(Unicode.Scalar(0)) { return " " }
                    guard character.unicodeScalars.contains(where: TerminalScreen.isDisallowed)
                    else {
                        return character
                    }
                    return "\u{FFFD}"
                })
        }

        /// `HolderEmulator.renderScreen`'s body as it stood before the lift:
        /// the viewport rows through `rowText`, trailing blanks dropped, joined
        /// with `\n`.
        static func renderScreen(_ terminal: Terminal) -> String {
            var lines: [String] = []
            lines.reserveCapacity(terminal.rows)
            for row in 0..<terminal.rows {
                lines.append(terminal.getLine(row: row).map { rowText($0) } ?? "")
            }
            while let last = lines.last, last.isEmpty { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Harness

    private final class SilentDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// A headless terminal fed through `Terminal.feed`, which is the production
    /// path on both sides of the transport: the daemon's drain loop feeds it,
    /// and so does a handback preamble.
    private struct Fixture {
        let delegate = SilentDelegate()
        let terminal: Terminal

        init(columns: Int = 40, rows: Int = 8, scrollback: Int = 200, feeding text: String) {
            terminal = Terminal(
                delegate: delegate,
                options: TerminalOptions(cols: columns, rows: rows, scrollback: scrollback))
            terminal.feed(text: text)
        }
    }

    /// Asserts the two projections agree on every field, at every depth that
    /// changes which branch of the tail cut runs.
    private func expectParity(
        _ fixture: Fixture, depths: [Int], _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for depth in depths {
            let shared = TerminalScreenProjection.project(fixture.terminal, maxLines: depth)
            let reference = Reference.project(fixture.terminal, maxLines: depth)
            #expect(
                shared == reference,
                """
                \(label) at maxLines \(depth): shared \(shared) disagreed with the pre-lift \
                reference \(reference)
                """,
                sourceLocation: sourceLocation)
        }
    }

    /// Every depth worth trying for a fixture: zero (the modes-only arm), a cut
    /// inside the viewport, a cut inside the scrollback, and more than the
    /// buffer holds.
    private static let depths = [0, 1, 3, 6, 8, 12, 50, 10_000]

    // MARK: - The cases

    @Test("a differentially painted line projects identically")
    func differentialPaintParity() {
        // `ESC[3G` positions past cells nobody wrote, which is the shape that
        // put 1,595 `U+0000`s into a live sweep.
        let fixture = Fixture(feeding: "✻\(Self.esc)[3GCogitated")
        expectParity(fixture, depths: Self.depths, "a differentially painted line")
    }

    @Test("a DEL a child stored in a cell projects identically")
    func delSubstitutionParity() {
        let fixture = Fixture(feeding: "a\(Self.esc)[4Gb\u{7f}c")
        expectParity(fixture, depths: Self.depths, "a DEL beside an unwritten cell")
    }

    @Test("wide glyphs project identically")
    func wideGlyphParity() {
        let fixture = Fixture(feeding: "日本 x\r\nmixed 🌍 tail")
        expectParity(fixture, depths: Self.depths, "wide glyphs")
    }

    @Test("a buffer with scrollback projects identically at every depth")
    func scrollbackParity() {
        let body = (1...60).map { "line \($0)" }.joined(separator: "\r\n")
        let fixture = Fixture(feeding: body)
        expectParity(fixture, depths: Self.depths, "60 lines over an 8-row viewport")
    }

    /// The case that makes `viewportStart` land **past the end** of `lines`:
    /// the trailing-blank trim does not stop at the viewport's first row, so a
    /// wholly blank viewport over blank-tailed scrollback has both trimmed away
    /// and the index is left beyond the array rather than at it.
    @Test("a blank viewport over blank-tailed scrollback projects identically")
    func trimmedPastTheViewportParity() {
        let blankTail = String(repeating: "\r\n", count: 9)
        let fixture = Fixture(
            feeding: (1...20).map { "row \($0)" }.joined(separator: "\r\n") + blankTail)
        expectParity(fixture, depths: Self.depths, "a trimmed-away viewport")

        // Guards the case rather than the parity: a fixture that stopped
        // producing an out-of-range offset would still satisfy the equality
        // above while asserting nothing about the arithmetic.
        let shared = TerminalScreenProjection.project(fixture.terminal, maxLines: 10_000)
        #expect(
            shared.viewportStart > shared.lines.count,
            "viewportStart \(shared.viewportStart) over \(shared.lines.count) lines")
    }

    /// And the case that makes it negative: a tail cut inside the viewport.
    @Test("a tail cut inside the viewport projects identically")
    func negativeViewportStartParity() {
        let fixture = Fixture(feeding: (1...30).map { "r\($0)" }.joined(separator: "\r\n"))
        let shared = TerminalScreenProjection.project(fixture.terminal, maxLines: 2)
        let reference = Reference.project(fixture.terminal, maxLines: 2)
        #expect(shared == reference)
        // Guards the case rather than the parity: a fixture that stopped
        // producing a negative offset would still pass the equality above and
        // assert nothing about the arithmetic this test is here for.
        #expect(shared.viewportStart < 0, "viewportStart was \(shared.viewportStart)")
    }

    /// Tab-laid-out text, a moved cursor and two set modes in one stream.
    ///
    /// The tabs are here for the cells they skip, not for a tab character in
    /// the output: `HT` moves the cursor to the next stop and writes nothing,
    /// so the columns it passes over are never-written cells and project as
    /// spaces. A screen line may hold a tab, and none produced from a grid
    /// does.
    @Test("a moved cursor and set modes come through identically")
    func cursorAndModesParity() {
        let fixture = Fixture(
            feeding: "col\tcol\tcol\r\n\(Self.esc)[?2004h\(Self.esc)[?1h\(Self.esc)[3;7H")
        expectParity(fixture, depths: Self.depths, "a moved cursor and set modes")

        // Guards the fixture: a stream that failed to set the modes or move the
        // cursor would make the parity assertion above compare two sets of
        // defaults and assert nothing.
        let shared = TerminalScreenProjection.project(fixture.terminal, maxLines: 50)
        #expect(shared.modes.bracketedPaste)
        #expect(shared.modes.applicationCursor)
        // `ESC[3;7H` is one-based, so the viewport-relative cursor is (2, 6).
        #expect(
            shared.cursorRow == 2 && shared.cursorColumn == 6,
            "cursor landed at (\(shared.cursorRow), \(shared.cursorColumn))")
    }

    @Test("the alternate screen projects identically")
    func alternateScreenParity() {
        let fixture = Fixture(
            feeding: "scrolled away\r\n\(Self.esc)[?1049hALT SCREEN\r\nsecond alt row")
        expectParity(fixture, depths: Self.depths, "the alternate screen")
        #expect(TerminalScreenProjection.project(fixture.terminal, maxLines: 50)
            .modes.alternateScreen)
    }

    // MARK: - The viewport-only render

    /// `renderScreen` went through the lift too, and its trim and character
    /// provider are the ones `project` uses — so it gets the same treatment.
    @Test("the viewport-only render is unchanged by the lift")
    func viewportRenderParity() {
        for fixture in [
            Fixture(feeding: "✻\(Self.esc)[3GCogitated"),
            Fixture(feeding: "a\(Self.esc)[4Gb\u{7f}c"),
            Fixture(feeding: "日本 x\r\nmixed 🌍 tail"),
            Fixture(feeding: (1...60).map { "line \($0)" }.joined(separator: "\r\n")),
        ] {
            let shared = TerminalScreenProjection.viewportLines(of: fixture.terminal)
                .joined(separator: "\n")
            #expect(shared == Reference.renderScreen(fixture.terminal))
        }
    }
}
