import AppKit
import Clocks
import Foundation
import SwiftTerm
import TBDShared
import TBDTerminalSerialization
import Testing
@testable import TBDApp
import TestSupport

/// Where the cursor lands in a holder terminal that is rebuilt at a height
/// other than the one its session was last viewed at.
///
/// A terminal moved from a short pane to a tall one is rebuilt: the new panel
/// attaches, and the daemon hands it a snapshot of the session's screen. The
/// snapshot replays the history one row per line and ends with an absolute
/// cursor position, so it rebuilds the screen only in a receiver of the size
/// it was written at. Written at the short pane's height and fed into the tall
/// one, the history fills the tall terminal to the bottom while the cursor
/// lands at the short height, rows above the line it belongs to, and what the
/// user types next overwrites older output.
///
/// The first test shows the engines are not the cause: each keeps the cursor
/// on its line when its own grid shrinks and grows back. The second shows the
/// snapshot is, and that a snapshot written at the receiver's size puts the
/// cursor back on its line in either engine. Writing it at that size is what
/// `HolderRegistry.beginAttach` does when the attach names the viewer's grid,
/// which `HolderAttachViewerGridTests` checks against a real holder.
@MainActor
@Suite("A holder terminal rebuilt at a new height keeps its cursor on its line", .fastPassBounded)
struct TerminalEngineReattachCursorTests {

    private static let tall = NSSize(width: 800, height: 600)
    private static let short = NSSize(width: 800, height: 300)

    /// One hundred numbered lines, more than either height holds, so both
    /// grids have scrollback to give up and take back. The cursor ends on the
    /// blank row after `line 99`.
    private static let numberedLines = (0..<100).map { "line \($0)\r\n" }.joined()
    private static let lastLine = "line 99"

    @Test("Shrinking the grid and growing it back leaves the cursor on the row after its last line",
          arguments: TerminalEngineFactory.availableKinds)
    func shrinkThenGrowKeepsTheCursorOnItsLine(kind: TerminalEngineKind) async throws {
        let fixture = EngineUnderTest(kind: kind, label: "EngineReattachCursor.Resize")
        defer { fixture.tearDown() }
        #expect(fixture.engine.kind == kind, "asked for \(kind), the factory built \(fixture.engine.kind)")
        let view = fixture.engine.view
        let window = EngineTestSupport.mount(view, size: Self.tall)
        defer { EngineTestSupport.unmount(window) }
        await EngineTestSupport.settle()
        let tall = fixture.engine.gridSize

        fixture.feed(Self.numberedLines)
        await EngineTestSupport.settle()
        let before = cursorPlace(of: fixture.engine)
        #expect(before.row == tall.rows - 1, "\(kind): before any resize the cursor is at \(before)")

        view.setFrameSize(Self.short)
        await EngineTestSupport.settle()
        let short = fixture.engine.gridSize
        try #require(short.rows < tall.rows, "\(kind): the short frame left the grid at \(short.rows) rows")
        let shrunk = cursorPlace(of: fixture.engine)
        #expect(shrunk.row == short.rows - 1, "\(kind): at \(short.rows) rows the cursor is at \(shrunk)")
        #expect(shrunk.lineAbove == Self.lastLine, "\(kind): at \(short.rows) rows the cursor is at \(shrunk)")

        view.setFrameSize(Self.tall)
        await EngineTestSupport.settle()
        let grown = fixture.engine.gridSize
        try #require(grown.rows == tall.rows, "\(kind): the tall frame gave \(grown.rows) rows, not \(tall.rows)")
        let regrown = cursorPlace(of: fixture.engine)
        #expect(regrown.row == tall.rows - 1, "\(kind): grown back to \(tall.rows) rows the cursor is at \(regrown)")
        #expect(regrown.lineAbove == Self.lastLine,
                "\(kind): grown back to \(tall.rows) rows the cursor is at \(regrown)")
    }

    @Test("A snapshot puts the cursor on its line only when it was written at the receiver's height",
          arguments: TerminalEngineFactory.availableKinds)
    func aSnapshotWrittenAtTheViewersHeightPutsTheCursorOnItsLine(kind: TerminalEngineKind) async throws {
        let fixture = EngineUnderTest(kind: kind, label: "EngineReattachCursor.Snapshot")
        defer { fixture.tearDown() }
        #expect(fixture.engine.kind == kind, "asked for \(kind), the factory built \(fixture.engine.kind)")
        let window = EngineTestSupport.mount(fixture.engine.view, size: Self.tall)
        defer { EngineTestSupport.unmount(window) }
        await EngineTestSupport.settle()
        let viewer = fixture.engine.gridSize
        let shortRows = viewer.rows / 2
        try #require(shortRows >= 5, "\(kind): a \(viewer.rows)-row viewer is too short to halve")

        // The session as the daemon holds it after a short viewer: a headless
        // SwiftTerm, the daemon's emulator, at the viewer's width and half its
        // height.
        let session = HeadlessSession(cols: viewer.cols, rows: shortRows)
        session.feed(Self.numberedLines)

        // The control, and the defect: written at the short height, the
        // history fills the viewer to the bottom and the cursor stops at the
        // short height.
        fixture.engine.prepareForPreamble()
        fixture.engine.ingestSnapshot(session.snapshot())
        await EngineTestSupport.settle()
        let misplaced = cursorPlace(of: fixture.engine)
        let bottomRow = viewer.rows - 2
        let bottomLine: String? = fixture.engine.withScreen { $0.lineText(row: bottomRow) }
        #expect(bottomLine == Self.lastLine,
                "\(kind): the short snapshot's history should reach the viewer's bottom; row \(bottomRow) reads \(bottomLine.debugDescription)")
        #expect(misplaced.row == shortRows - 1,
                "\(kind): a snapshot written at \(shortRows) rows put the cursor at \(misplaced)")

        // Reshaped to the viewer's grid before the snapshot is written.
        session.resize(cols: viewer.cols, rows: viewer.rows)
        fixture.engine.prepareForPreamble()
        fixture.engine.ingestSnapshot(session.snapshot())
        await EngineTestSupport.settle()
        let placed = cursorPlace(of: fixture.engine)
        #expect(placed.row == viewer.rows - 1,
                "\(kind): a snapshot written at the viewer's \(viewer.rows) rows put the cursor at \(placed)")
        #expect(placed.lineAbove == Self.lastLine,
                "\(kind): a snapshot written at the viewer's \(viewer.rows) rows put the cursor at \(placed)")
    }

    // MARK: - The attach names the grid

    @Test("A holder panel's attach asks for the snapshot at its engine's grid",
          arguments: TerminalEngineFactory.availableKinds)
    func theAttachCarriesTheEnginesGrid(kind: TerminalEngineKind) async throws {
        let fixture = EngineUnderTest(kind: kind, label: "EngineReattachCursor.AttachGrid")
        defer { fixture.tearDown() }
        #expect(fixture.engine.kind == kind, "asked for \(kind), the factory built \(fixture.engine.kind)")
        let window = EngineTestSupport.mount(fixture.engine.view, size: Self.tall)
        defer { EngineTestSupport.unmount(window) }
        await EngineTestSupport.settle()
        let grid = fixture.engine.gridSize

        let sent = await attachGrids(attaching: fixture.engine, defaults: fixture.suite.defaults)

        let expected: [HolderTestGrid?] = [HolderTestGrid(cols: grid.cols, rows: grid.rows)]
        #expect(sent == expected, "\(kind): a \(grid.cols)x\(grid.rows) engine's attach carried \(sent)")
    }

    /// The other branch of the floor: a transient size below it reaches
    /// neither the daemon nor the child, the same rule the resize path keeps.
    @Test("A holder panel whose grid is below the resize floor names no grid",
          arguments: TerminalEngineFactory.availableKinds)
    func aGridBelowTheFloorIsNotSent(kind: TerminalEngineKind) async throws {
        let fixture = EngineUnderTest(kind: kind, label: "EngineReattachCursor.AttachGridFloor")
        defer { fixture.tearDown() }
        #expect(fixture.engine.kind == kind, "asked for \(kind), the factory built \(fixture.engine.kind)")
        let window = EngineTestSupport.mount(fixture.engine.view, size: NSSize(width: 100, height: 40))
        defer { EngineTestSupport.unmount(window) }
        await EngineTestSupport.settle()
        let grid = fixture.engine.gridSize
        try #require(
            grid.cols < TerminalGeometryLimits.minCols || grid.rows < TerminalGeometryLimits.minRows,
            "\(kind): a 100x40 frame gave a \(grid.cols)x\(grid.rows) grid, which is not below the floor")

        let sent = await attachGrids(attaching: fixture.engine, defaults: fixture.suite.defaults)

        let expected: [HolderTestGrid?] = [nil]
        #expect(sent == expected, "\(kind): a \(grid.cols)x\(grid.rows) engine's attach carried \(sent)")
    }

    /// Runs a holder panel's attach over `engine` against a scripted daemon,
    /// and returns the grid each attach request carried.
    private func attachGrids(
        attaching engine: any TerminalEngine, defaults: UserDefaults
    ) async -> [HolderTestGrid?] {
        let pty = HolderTestPTY()
        defer { pty.closeFar() }
        let attachment = pty.attachment(generation: 5)
        let stub = ScriptedHolderDaemon(attach: { _ in attachment })
        let worktreeID = UUID()
        let terminalID = UUID()
        let state = AppState(userDefaults: defaults)
        state.terminals[worktreeID] = [TBDShared.Terminal(
            id: terminalID, worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            label: "Shell", kind: .shell, transport: .holder)]
        let coordinator = TerminalPanelRepresentable.Coordinator(clock: ImmediateClock<Duration>())
        coordinator.appState = state
        coordinator.panelID = terminalID
        coordinator.engine = engine
        coordinator.holderAttachClient = stub
        coordinator.holderAttachRetryDelays = []
        defer { coordinator.cleanup() }

        await coordinator.startHolderClient(engine: engine)
        #expect(stub.events == ["attach", "ready"], "the attach did not go live: \(stub.events)")
        return stub.attachGrids
    }

    // MARK: - Reading the cursor

    /// The cursor's viewport row and the text of the row above it, which is
    /// the line the cursor follows.
    private struct CursorPlace: CustomStringConvertible {
        let row: Int
        let lineAbove: String?

        var description: String { "row \(row), under \(lineAbove.debugDescription)" }
    }

    private func cursorPlace(of engine: any TerminalEngine) -> CursorPlace {
        engine.withScreen { (screen: any TerminalScreenReader) -> CursorPlace in
            let row = screen.projection(maxLines: 0).cursorRow
            return CursorPlace(row: row, lineAbove: screen.lineText(row: row - 1))
        }
    }
}

/// A session's screen as the daemon keeps it: a headless SwiftTerm, written
/// out by the same `TerminalSnapshotWriter` the attach uses.
///
/// The collector is retained here because `Terminal.tdel` is weak, and it
/// answers the writer's mode queries synchronously, as the daemon's does.
private final class HeadlessSession {
    private let reply = SnapshotReplyCollector()
    private let terminal: SwiftTerm.Terminal

    init(cols: Int, rows: Int) {
        terminal = SwiftTerm.Terminal(
            delegate: reply, options: TerminalOptions(cols: cols, rows: rows, scrollback: 1_000))
        reply.terminal = terminal
    }

    func feed(_ text: String) {
        terminal.feed(text: text)
    }

    /// What `HolderEmulator.resize` does to the daemon's emulator.
    func resize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
    }

    func snapshot() -> Data {
        TerminalSnapshotWriter.snapshot(of: terminal, reply: reply, maxScrollbackLines: 1_000)
    }
}
