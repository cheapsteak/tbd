import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The size a holder session's attach snapshot is written at.
///
/// A snapshot replays the history one row per line and ends with an absolute
/// cursor position, so it rebuilds the screen only in a receiver of the
/// emulator's own size. The emulator sits at its previous viewer's size. When
/// the next viewer is taller, the history fills it to the bottom while the
/// cursor lands at the old height, rows above its line, and what the user
/// types next overwrites older output. So an attach names its viewer's grid,
/// and the daemon reshapes the session to it, emulator and tty both, before it
/// writes the snapshot.
///
/// **Tier 3.** A real `TBDHolder`, a real pty, and a real job.
@Suite(.serialized)
struct HolderAttachViewerGridTests {

    /// Prints one hundred numbered lines, more than either height holds, then
    /// answers lines and is otherwise silent: a job writing on its own would
    /// fill the terminal queue while the vended descriptor sits unread.
    private static let numberedJob =
        "i=0; while [ $i -lt 100 ]; do echo \"line $i\"; i=$((i+1)); done; "
        + "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done"
    private static let lastLine = "line 99"

    /// The size every fixture starts at, from `HolderProcessFixture.launch`.
    private static let launched = (columns: 80, rows: 24)
    /// A taller viewer at the same width, so nothing rewraps.
    private static let viewer = (columns: 80, rows: 40)

    @Test func anAttachNamingItsViewersGridIsSnapshottedAtThatSize() async throws {
        let fixture = try await GridFixture.start(command: Self.numberedJob)
        defer { fixture.tearDown() }
        try await fixture.waitForTheLastLine(Self.lastLine)

        let vend = try await fixture.registry.beginAttach(
            terminalID: fixture.terminalID, viewerGrid: Self.viewer)
        defer { close(vend.ptyFD) }

        let grid = await fixture.reader.gridSize
        #expect(grid == Self.viewer, "the emulator was left at \(grid.columns)x\(grid.rows)")
        let onTheTTY = try #require(await fixture.reader.ptyWindowSize)
        #expect(
            onTheTTY == Self.viewer,
            """
            no viewer holds the pty yet, so the daemon is the one to size it — the child is \
            still laying itself out at \(onTheTTY.columns)x\(onTheTTY.rows)
            """)

        let replay = CursorReplay(columns: Self.viewer.columns, rows: Self.viewer.rows)
        replay.feed(vend.snapshotPreamble)
        let cursor = replay.cursorRow
        let lineAbove = replay.line(cursor - 1)
        #expect(cursor == Self.viewer.rows - 1, "the replayed cursor is on row \(cursor)")
        #expect(
            lineAbove == Self.lastLine,
            "the replayed cursor is on row \(cursor), under \(lineAbove.debugDescription)")
    }

    /// The control that makes the test above discriminate: with no grid named,
    /// the session keeps its size and its snapshot misplaces the cursor in a
    /// taller viewer, which is the defect.
    @Test func anAttachNamingNoGridLeavesTheSessionAtItsSize() async throws {
        let fixture = try await GridFixture.start(command: Self.numberedJob)
        defer { fixture.tearDown() }
        try await fixture.waitForTheLastLine(Self.lastLine)

        let vend = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        defer { close(vend.ptyFD) }

        let grid = await fixture.reader.gridSize
        #expect(grid == Self.launched, "the emulator moved to \(grid.columns)x\(grid.rows)")
        let onTheTTY = try #require(await fixture.reader.ptyWindowSize)
        #expect(onTheTTY == Self.launched, "the tty moved to \(onTheTTY.columns)x\(onTheTTY.rows)")

        let replay = CursorReplay(columns: Self.viewer.columns, rows: Self.viewer.rows)
        replay.feed(vend.snapshotPreamble)
        let cursor = replay.cursorRow
        let bottomLine = replay.line(Self.viewer.rows - 2)
        #expect(
            bottomLine == Self.lastLine,
            "the history should fill the taller viewer to its bottom: \(bottomLine.debugDescription)")
        #expect(
            cursor == Self.launched.rows - 1,
            "a snapshot written at \(Self.launched.rows) rows put the cursor on row \(cursor)")
    }
}

// MARK: - Fixture

/// A live holder, the registry that adopted it, and its reader.
///
/// Its own copy, as `HolderResizeRoutingTests`' fixture is: the attach suites'
/// fixtures are `private` to their files.
private struct GridFixture {
    let process: HolderProcessFixture
    let registry: HolderRegistry
    let reader: HolderReader

    var terminalID: UUID { process.sessionID }

    static func start(command: String) async throws -> GridFixture {
        let process = try await HolderProcessFixture.start(
            launch: HolderProcessFixture.launch(command: command))
        // The spawner's handshake connection has to go first: a holder serves
        // one client at a time and the adoption below opens its own.
        await process.client.close()
        let registry = HolderRegistry(
            owner: process.owner,
            environment: HolderProcessFixture.environment(home: process.home),
            listTerminals: { [] })
        return GridFixture(
            process: process,
            registry: registry,
            reader: try await registry.adopt(
                terminal: TBDShared.Terminal(
                    id: process.sessionID, worktreeID: UUID(), tmuxWindowID: "",
                    tmuxPaneID: "", transport: .holder)))
    }

    /// Waits for the job's last line to reach the daemon's screen, so the
    /// attach snapshots all of it.
    func waitForTheLastLine(_ line: String) async throws {
        let reader = self.reader
        let arrived = await pollUntil("the job's last line on the daemon's screen") {
            await reader.renderScreen().contains(line)
        }
        try #require(arrived)
    }

    /// Releases the registry's readers and kills the holder AND its job, by
    /// pid. Holder death is not child death, so both need naming. The release
    /// is waited for, bounded, because the thing being released is a drain
    /// thread and a pty descriptor.
    func tearDown() {
        let registry = self.registry
        let released = DispatchSemaphore(value: 0)
        Task.detached {
            await registry.releaseAll()
            released.signal()
        }
        if released.wait(timeout: .now() + 10) == .timedOut {
            Issue.record("the registry's readers were still releasing 10s after the test ended")
        }
        process.tearDown()
    }
}

// MARK: - Replaying a preamble

/// A terminal that has never seen the session, standing in for the viewer.
///
/// The delegate is retained here because `Terminal.tdel` is weak, and it
/// answers nothing: a replay must never write back.
private final class CursorReplay {
    private let terminal: SwiftTerm.Terminal
    private let delegate = ReplaySilentDelegate()

    init(columns: Int, rows: Int) {
        terminal = SwiftTerm.Terminal(
            delegate: delegate, options: TerminalOptions(cols: columns, rows: rows))
    }

    func feed(_ data: Data) {
        terminal.terminalLock.withLock { terminal.feed(byteArray: [UInt8](data)) }
    }

    /// The cursor's row, counted from the top of the viewport.
    var cursorRow: Int {
        terminal.terminalLock.withLock { terminal.getCursorLocation().y }
    }

    /// The text of viewport row `row`, trailing blanks trimmed; nil off the
    /// screen.
    func line(_ row: Int) -> String? {
        terminal.terminalLock.withLock {
            terminal.getLine(row: row)?.translateToString(trimRight: true)
        }
    }
}

private final class ReplaySilentDelegate: TerminalDelegate {
    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {}
}
