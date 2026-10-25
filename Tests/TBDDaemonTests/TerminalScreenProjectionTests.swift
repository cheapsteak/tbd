import Foundation
import SwiftTerm
import Testing

// Scoped, for the reason `TerminalScreenProjection` itself imports this way:
// `TBDShared.Terminal` is the DB row model and `SwiftTerm.Terminal` is the
// emulator, and every bare `Terminal` below is the emulator.
import struct TBDShared.TerminalScreen

@testable import TBDTerminalSerialization

/// What `TerminalScreenProjection` does that the holder suites cannot see from
/// outside: which branch a modes-only request takes, and the tail cut at a
/// depth inside the viewport.
///
/// The projection's output for real screens — never-written cells, a stored
/// DEL, wide glyphs, the three modes, the cursor, `viewportStart` inside and
/// past the end of `lines`, and the viewport-only render — is pinned through
/// the daemon's own reader by `HolderScreenContractTests` and
/// `HolderRenderProjectionTests`, against the production path rather than a
/// copy of it.
///
/// Every case is driven through a real `Terminal` fed real bytes, never a
/// hand-built grid: a fixture that assembled rows itself would agree with
/// anything.
@Suite struct TerminalScreenProjectionTests {

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

    // MARK: - The modes-only path does no per-row work

    /// The input path's oracle asks with `maxLines: 0` before composing every
    /// message to a session a viewer holds, and the viewer answers on its main
    /// actor under the terminal lock inside a 150 ms bound. So "no lines" has
    /// to mean **no walk**, not a smaller reply: a `rowText` call per retained
    /// row, thousands of them, could exceed that bound and drop the send back
    /// onto the frozen modes — the exact failure the pull exists to remove.
    ///
    /// Counted rather than inferred, because equality cannot show which branch
    /// ran: the same values come out whether the guard sits above the loop or
    /// below it. SwiftTerm's row accessors are `public` rather than `open`, so
    /// they cannot be intercepted by a subclass; `project`'s defaulted
    /// `onRowAccess` is the seam instead. Move the guard back below the loop
    /// and this fails.
    @Test("a modes-only projection touches no rows at all")
    func modesOnlyProjectionTouchesNoRows() {
        let deep = Fixture(feeding: (1...400).map { "line \($0)" }.joined(separator: "\r\n"))

        var accesses = 0
        let projected = TerminalScreenProjection.project(
            deep.terminal, maxLines: 0, onRowAccess: { accesses += 1 })

        #expect(accesses == 0, "a modes-only projection walked \(accesses) rows")
        #expect(projected.lines.isEmpty)
    }

    /// The counter's other half, so the test above cannot pass because the seam
    /// is simply never called. A depth that does ask for lines must walk, and
    /// it walks the whole retained buffer — the tail cut happens after the
    /// enumeration, because there is no public line count to cut against.
    @Test("a projection that asks for lines does walk, and the counter sees it")
    func projectionWithLinesWalksTheBuffer() {
        let deep = Fixture(feeding: (1...400).map { "line \($0)" }.joined(separator: "\r\n"))

        var accesses = 0
        let projected = TerminalScreenProjection.project(
            deep.terminal, maxLines: 5, onRowAccess: { accesses += 1 })

        #expect(accesses > 5, "the walk enumerates the buffer, not just the requested tail")
        #expect(projected.lines.count == 5)
    }

    /// And the correctness half: the early return is not a second answer. Its
    /// cursor, size and modes are the full walk's, over a screen with two set
    /// modes, a deep buffer — where the two paths have the most room to
    /// disagree about `viewportStart` — and an empty one.
    @Test("the modes-only path agrees with the full walk at depth zero")
    func modesOnlyPathAgreesWithTheFullWalk() {
        for fixture in [
            Fixture(feeding: "\u{1b}[?2004h\u{1b}[?1hfirst\r\nsecond"),
            Fixture(feeding: (1...400).map { "line \($0)" }.joined(separator: "\r\n")),
            Fixture(feeding: ""),
        ] {
            let modesOnly = TerminalScreenProjection.project(fixture.terminal, maxLines: 0)
            let full = TerminalScreenProjection.project(fixture.terminal, maxLines: 10_000)
            // The algebra the early return relies on, stated: with no lines the
            // tail cut drops every row, so the offset is `-rows` whatever the
            // buffer holds.
            #expect(modesOnly == ProjectedScreen(
                lines: [],
                viewportStart: -fixture.terminal.rows,
                cursorRow: full.cursorRow,
                cursorColumn: full.cursorColumn,
                size: full.size,
                modes: full.modes))
        }
    }

    // MARK: - The tail cut

    /// A cut inside the viewport makes `viewportStart` negative, the second of
    /// the two out-of-range cases `TerminalScreen` documents.
    /// `HolderScreenContractTests` pins the other one (past the end of
    /// `lines`); no holder suite cuts inside the viewport, so this case lives
    /// here.
    @Test("a tail cut inside the viewport puts viewportStart below zero")
    func tailCutInsideTheViewportGoesNegative() {
        let fixture = Fixture(feeding: (1...30).map { "r\($0)" }.joined(separator: "\r\n"))
        let projected = TerminalScreenProjection.project(fixture.terminal, maxLines: 2)
        #expect(projected.viewportStart < 0, "viewportStart was \(projected.viewportStart)")
    }
}
