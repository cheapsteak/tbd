import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Who issues `TIOCSWINSZ` for a holder-backed session, and what the daemon
/// still owes its own emulator when it is not the one issuing it.
///
/// **While a viewer holds the pty, the viewer owns the tty's size.** It has a
/// writable duplicate of the master and sets the size on it directly, so a
/// daemon that also issued the ioctl would signal the child twice for one
/// resize, and — in the window where the two disagree — signal it to a size
/// nobody is painting at. While no viewer holds it the daemon owns both halves,
/// because nothing else can.
///
/// **The grid is not the other half of that trade.** The daemon's emulator is
/// what a re-adoption and `terminal.output` render, and a grid left at the size
/// the viewer arrived at wraps every later line at the wrong width. It is the
/// same defect the adoption path was fixed for once already — a job laying out
/// 123 columns into an 80-column grid — approached from the opposite direction,
/// so it tracks the viewer whether or not the daemon touched the tty.
///
/// The attached state used here is the one where the question is *observable*:
/// an attach that was vended and never acknowledged. A confirmed attach
/// releases the daemon's reader outright, so there is no emulator left to ask.
/// This state is not contrived — it is the timed-out attach, where the viewer
/// may already be live on its duplicate and the daemon is deliberately kept off
/// the pty.
///
/// **Tier 3.** A real `TBDHolder`, a real pty, and a real job.
@Suite(.serialized)
struct HolderResizeRoutingTests {

    /// Answers lines and is otherwise silent — a job writing on its own would
    /// fill the terminal queue during the windows this suite spends suspended.
    private static let echoJob = "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done"

    /// The size every fixture starts at, from `HolderProcessFixture.launch`.
    private static let launched = (columns: 80, rows: 24)
    private static let requested = (columns: 123, rows: 41)

    @Test func aDetachedSessionIsResizedByTheDaemon() async throws {
        let fixture = try await ResizeFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let before = try #require(await fixture.reader.ptyWindowSize)
        #expect(before == Self.launched, "the fixture should start at its launch geometry")

        await fixture.registry.applyViewerResize(
            terminalID: fixture.terminalID,
            columns: Self.requested.columns,
            rows: Self.requested.rows)

        let onTheTTY = try #require(await fixture.reader.ptyWindowSize)
        #expect(
            onTheTTY == Self.requested,
            """
            nobody holds this pty, so the daemon is the only thing that can size it — the child \
            is still laying itself out at \(onTheTTY.columns)x\(onTheTTY.rows)
            """)
        #expect(await fixture.reader.gridSize == Self.requested)
    }

    @Test func anAttachedSessionsTTYIsLeftToItsViewer() async throws {
        let fixture = try await ResizeFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }
        try await fixture.vendToAViewerThatNeverAcknowledges()

        await fixture.registry.applyViewerResize(
            terminalID: fixture.terminalID,
            columns: Self.requested.columns,
            rows: Self.requested.rows)

        let onTheTTY = try #require(await fixture.reader.ptyWindowSize)
        #expect(
            onTheTTY == Self.launched,
            """
            a viewer holds this pty and drives TIOCSWINSZ on its own duplicate; the daemon issued \
            one as well and moved the tty to \(onTheTTY.columns)x\(onTheTTY.rows), signalling the \
            child twice for one resize
            """)
    }

    @Test func anAttachedSessionsGridStillTracksItsViewer() async throws {
        let fixture = try await ResizeFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }
        try await fixture.vendToAViewerThatNeverAcknowledges()

        await fixture.registry.applyViewerResize(
            terminalID: fixture.terminalID,
            columns: Self.requested.columns,
            rows: Self.requested.rows)

        let grid = await fixture.reader.gridSize
        #expect(
            grid == Self.requested,
            """
            the daemon's emulator is still at \(grid.columns)x\(grid.rows) — the size the viewer \
            arrived at — so everything this session prints from here is wrapped at a width nobody \
            is painting, and the next re-adoption or `terminal.output` renders it that way
            """)
    }
}

// MARK: - Fixture

/// A live holder, the registry that adopted it, and its reader.
///
/// Deliberately its own copy rather than a share of `HolderAttachHandoffTests`'
/// fixture, which is `private` to that file; the two are worth extracting once
/// the milestone's attach and detach halves have both landed.
private struct ResizeFixture {
    let process: HolderProcessFixture
    let registry: HolderRegistry
    let reader: HolderReader

    var terminalID: UUID { process.sessionID }

    static func start(command: String) async throws -> ResizeFixture {
        let process = try await HolderProcessFixture.start(
            launch: HolderProcessFixture.launch(command: command))
        // The spawner's handshake connection has to go first: a holder serves
        // one client at a time and the adoption below opens its own.
        await process.client.close()
        let registry = HolderRegistry(
            owner: process.owner,
            environment: HolderProcessFixture.environment(home: process.home),
            listTerminals: { [] })
        return ResizeFixture(
            process: process,
            registry: registry,
            reader: try await registry.adopt(
                terminal: TBDShared.Terminal(
                    id: process.sessionID, worktreeID: UUID(), tmuxWindowID: "",
                    tmuxPaneID: "", transport: .holder)))
    }

    /// Puts the session into the state a viewer owns it in, and the only one
    /// that leaves the daemon anything to observe: the descriptor is vended and
    /// the acknowledgement never comes.
    ///
    /// `.unacknowledged` is what makes it the viewer's — a lost ack and a lost
    /// app are indistinguishable, so the daemon records the claim, stays off the
    /// pty, and keeps the suspended reader it may not read.
    func vendToAViewerThatNeverAcknowledges() async throws {
        let vend = try await registry.beginAttach(terminalID: terminalID)
        // The viewer's copy. Closed here because no viewer exists to hold it;
        // the claim it created is what the test is about.
        close(vend.ptyFD)
        await registry.cancelPendingAttach(
            terminalID: terminalID, generation: vend.generation, reason: .unacknowledged)
        let claim = await registry.viewerAttachment(for: terminalID)
        #expect(claim == vend.generation, "the session should now read as the viewer's")
        #expect(
            await registry.reader(for: terminalID) != nil,
            "an unacknowledged attach keeps the daemon's reader; without one there is nothing here to test")
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
