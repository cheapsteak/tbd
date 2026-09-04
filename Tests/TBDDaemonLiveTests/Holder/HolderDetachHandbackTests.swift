import Darwin
import Foundation
import SwiftTerm
import TBDTerminalSerialization
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Taking a session back from a viewer: the mirror of the attach, and the
/// reason a closed tab does not brick its session.
///
/// **What was broken before this existed.** `viewerAttachments` was written by
/// `confirmAttach` and cleared by nothing except `release`. So a viewer that
/// went away left a claim behind: `adopt` refused on it, `beginAttach` refused
/// on it, and the injection courier read it as "a viewer holds this pty" — so
/// the session was undrained, unwritable and un-reattachable for the daemon's
/// whole life. A job that exits with unread output cannot even finish exiting.
/// Every test here is about that claim being released, and about what has to be
/// true before it is.
///
/// **The handback is O(1) per reader change, not per byte** — it is not the
/// rejected streaming design. Without it a detach from a plain shell leaves the
/// daemon's model frozen at the instant the viewer arrived, because the jiggle
/// heals only programs that repaint and a shell repaints essentially nothing.
///
/// **Tier 3.** A real `TBDHolder`, a real pty, a real job.
@Suite(.serialized)
struct HolderDetachHandbackTests {

    /// A job that answers every line it is given and speaks only when spoken
    /// to — the same shape `HolderAttachHandoffTests` uses, for its reason: a
    /// job writing on its own would fill the terminal queue during the windows
    /// this suite spends with nobody reading.
    private static let echoJob = "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done"

    // MARK: - The screen out, and back

    @Test func aHandbackClearsTheClaimAndPutsTheDaemonBackOnThePty() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        // Something only the daemon ever saw...
        try await fixture.reader.write(Data("BEFORE-ATTACH\n".utf8))
        #expect(await pollUntil("the job's answer before the attach") {
            await fixture.reader.renderScreen().contains("GOT:BEFORE-ATTACH")
        })

        let viewer = try await fixture.attachAViewer()
        // ...and something only the viewer ever saw. The daemon is off the pty
        // from the vend, so these bytes reach its emulator through nothing but
        // the handback.
        try writePTY(fd: viewer.ptyFD, "WHILE-ATTACHED\n")
        let seen = readPTYUntil(fd: viewer.ptyFD, contains: "GOT:WHILE-ATTACHED")
        #expect(seen != nil, "the viewer never saw its own job's answer")
        viewer.terminal.feed(Data((seen ?? "").utf8))
        #expect(await fixture.registry.reader(for: fixture.terminalID) == nil,
                "an acknowledged attach releases the daemon's reader for good")

        // The order the app keeps, and the reason it keeps it: nothing may read
        // this pty between the close and the daemon's resume.
        viewer.close()
        try await fixture.registry.acceptHandback(
            terminal: fixture.terminalRow, generation: viewer.generation,
            preamble: viewer.terminal.snapshot())

        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == nil,
                "the viewer claim survived the handback, so this session is still bricked")
        let resumed = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(await resumed.isDraining, "the daemon took the session back without reading it")

        let screen = await resumed.renderScreen()
        #expect(screen.contains("GOT:BEFORE-ATTACH"), """
            the history the daemon handed out at the attach did not come back: \(screen)
            """)
        #expect(screen.contains("GOT:WHILE-ATTACHED"), """
            what the session did while the viewer owned it did not come back: \(screen)
            """)

        // And the session is genuinely live again, not merely claimed: the
        // daemon writes, the job answers, and the answer lands on the screen.
        try await resumed.write(Data("AFTER-DETACH\n".utf8))
        #expect(await pollUntil("the job's answer after the handback") {
            await resumed.renderScreen().contains("GOT:AFTER-DETACH")
        })
    }

    // MARK: - The unacknowledged attach, which kept its reader

    /// An attach that timed out unacknowledged keeps the claim *and* its
    /// suspended reader (`AttachCancelReason.unacknowledged`), because a lost
    /// ack and a lost app are indistinguishable. A detach is the evidence that
    /// settles it — the viewer was there all along — so the handback puts that
    /// same reader back on the pty rather than opening a second hand-over.
    @Test func aHandbackAfterAnUnacknowledgedAttachResumesTheSuspendedReader() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let vend = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        let held = try #require(await fixture.registry.reader(for: fixture.terminalID))
        await fixture.registry.cancelPendingAttach(
            terminalID: fixture.terminalID, generation: vend.generation,
            reason: .unacknowledged)
        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == vend.generation)
        #expect(await held.isDraining == false, "an unacknowledged attach leaves its reader suspended")

        let viewer = ViewerTerminal(columns: 80, rows: 24)
        viewer.feed(vend.snapshotPreamble)
        viewer.feed(Data("HANDED-BACK-BY-A-TIMED-OUT-VIEWER\r\n".utf8))
        Darwin.close(vend.ptyFD)

        try await fixture.registry.acceptHandback(
            terminal: fixture.terminalRow, generation: vend.generation,
            preamble: viewer.snapshot())

        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == nil)
        let resumed = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(resumed === held, """
            the handback opened a second hand-over for a session whose own reader had never left \
            the descriptor
            """)
        #expect(await resumed.isDraining, "the suspended reader was not put back on the pty")
        #expect(await resumed.renderScreen().contains("HANDED-BACK-BY-A-TIMED-OUT-VIEWER"))
    }

    // MARK: - What a handback must refuse

    /// A closing viewer's detach can arrive after a successor's attach owns the
    /// pty. Applying it would clear the successor's claim and put a drain on a
    /// descriptor another process is reading — the double read this whole path
    /// exists to prevent, reached by a plain sequence with no race in it.
    @Test func aStaleHandbackLeavesTheCurrentAttachAlone() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let viewer = try await fixture.attachAViewer()
        defer { viewer.close() }

        await #expect(throws: HolderRegistry.Error.self) {
            try await fixture.registry.acceptHandback(
                terminal: fixture.terminalRow, generation: viewer.generation &+ 1,
                preamble: Data("STALE".utf8))
        }
        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == viewer.generation,
                "a stale detach took the pty from the attach that holds it")
        #expect(await fixture.registry.reader(for: fixture.terminalID) == nil,
                "a stale detach put the daemon back on a pty a viewer is reading")
    }

    /// The negative that scopes this task: **an app that dies mid-detach needs
    /// no special handling here.** Its descriptors close with the process,
    /// which is the same evidence a completed detach carries — but the evidence
    /// is not *available* here, because a closed fd in another process is
    /// invisible to this one. So the claim stands until an app-liveness verdict
    /// releases it, which is Task 13's arbitration and deliberately not this
    /// path's job. Asserted rather than built for.
    @Test func aViewerThatVanishesWithoutDetachingIsLeftToAppLiveness() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let viewer = try await fixture.attachAViewer()
        // Exactly what a dying app does, and nothing else: no detach follows.
        viewer.close()

        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == viewer.generation,
                "a closed descriptor is not evidence this daemon can see")
        #expect(await fixture.registry.reader(for: fixture.terminalID) == nil)
        await #expect(throws: HolderRegistry.Error.attachedToViewer(terminalID: fixture.terminalID)) {
            try await fixture.registry.adopt(terminal: fixture.terminalRow)
        }
    }
}

// MARK: - Fixture

/// A live holder, a registry that has adopted it, and everything needed to play
/// a viewer against it.
private struct HandbackFixture {
    let process: HolderProcessFixture
    let registry: HolderRegistry
    let reader: HolderReader

    var terminalID: UUID { process.sessionID }

    var terminalRow: TBDShared.Terminal {
        TBDShared.Terminal(
            id: process.sessionID, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)
    }

    static func start(command: String) async throws -> HandbackFixture {
        let process = try await HolderProcessFixture.start(
            launch: HolderProcessFixture.launch(command: command))
        // The spawner's handshake connection has to go before anything else can
        // be served: a holder serves one client at a time.
        await process.client.close()
        let registry = HolderRegistry(
            owner: process.owner,
            environment: HolderProcessFixture.environment(home: process.home),
            listTerminals: { [] })
        let row = TBDShared.Terminal(
            id: process.sessionID, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)
        return HandbackFixture(
            process: process, registry: registry,
            reader: try await registry.adopt(terminal: row))
    }

    /// Runs the whole attach handshake and hands back a viewer holding the
    /// vended descriptor, with the daemon's preamble already on its screen —
    /// which is what a real panel does before it acks.
    func attachAViewer() async throws -> Viewer {
        let vend = try await registry.beginAttach(terminalID: terminalID)
        let terminal = ViewerTerminal(columns: 80, rows: 24)
        terminal.feed(vend.snapshotPreamble)
        try await registry.confirmAttach(terminalID: terminalID, generation: vend.generation)
        return Viewer(ptyFD: vend.ptyFD, generation: vend.generation, terminal: terminal)
    }

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

/// The viewer's side of an attach: the descriptor it reads, the generation that
/// names it, and the terminal it paints into.
private final class Viewer {
    let ptyFD: Int32
    let generation: UInt64
    let terminal: ViewerTerminal
    private var closed = false

    init(ptyFD: Int32, generation: UInt64, terminal: ViewerTerminal) {
        self.ptyFD = ptyFD
        self.generation = generation
        self.terminal = terminal
    }

    /// What the app does first, and what the daemon's resume must strictly
    /// follow: this process leaves the pty.
    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(ptyFD)
    }
}

/// A terminal that has never seen the session, standing in for the viewer's
/// SwiftTerm — fed the daemon's preamble on the way in, serialized back on the
/// way out through the same `TerminalSnapshotWriter` the app uses.
///
/// Its delegate answers `DECRQM` **synchronously**, which a headless `Terminal`
/// allows and a `TerminalView` does not: a view hops every reply through
/// `onMain`. That difference is why the app carries `RecordedModeReplies` and a
/// main-queue turn, and it is the one thing this stand-in does not model.
private final class ViewerTerminal {
    private let terminal: SwiftTerm.Terminal
    private let delegate = CollectingDelegate()

    init(columns: Int, rows: Int) {
        terminal = SwiftTerm.Terminal(
            delegate: delegate, options: TerminalOptions(cols: columns, rows: rows))
        delegate.terminal = terminal
    }

    func feed(_ data: Data) {
        terminal.terminalLock.withLock { terminal.feed(byteArray: [UInt8](data)) }
    }

    func snapshot(maxScrollbackLines: Int = 5_000) -> Data {
        terminal.terminalLock.withLock {
            TerminalSnapshotWriter.snapshot(
                of: terminal, reply: delegate, maxScrollbackLines: maxScrollbackLines)
        }
    }
}

private final class CollectingDelegate: TerminalDelegate, ModeReplyReader {
    weak var terminal: SwiftTerm.Terminal?
    private var bytes: [UInt8] = []

    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {
        bytes.append(contentsOf: data)
    }

    func requestMode(_ mode: Int, decPrivate: Bool) -> Int? {
        guard let terminal else { return nil }
        bytes.removeAll()
        let prefix = decPrivate ? "?" : ""
        terminal.feed(text: "\u{1b}[\(prefix)\(mode)$p")
        let reply = String(bytes: bytes, encoding: .utf8) ?? ""
        guard let head = reply.range(of: "\u{1b}[\(prefix)\(mode);"),
              let tail = reply[head.upperBound...].range(of: "$y") else { return nil }
        return Int(reply[head.upperBound..<tail.lowerBound])
    }
}
