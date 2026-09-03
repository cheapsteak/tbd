import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Handing one session's pty from the daemon to a viewer, and the rule that
/// decides every failure on that path.
///
/// **At most one reader per pty, ever.** Two readers is silent byte theft —
/// each `read` takes bytes the other will never see, and nothing anywhere
/// reports it — so every failure here fails toward *nobody* reading. That is
/// not free: a job that exits with unread output cannot finish exiting, so a
/// no-reader window holds jobs open. It is still the right direction, because
/// an absent reader delays and a double reader corrupts.
///
/// The consequence, which most of this suite exists to pin: **the daemon stops
/// reading when it hands the descriptor over, not when the viewer says thank
/// you.** From the moment the `dup` leaves the daemon the viewer may be on it.
/// What the acknowledgement decides is ownership — whether the daemon still
/// holds a reader it could be put back on — and the two cancellations differ in
/// exactly one respect: whether the viewer can possibly have the descriptor.
///
/// It also means the preamble has no hole in it. Everything up to the quiesce
/// is in the snapshot, everything after it is still queued on the tty for the
/// viewer to read, and nothing falls between the two.
///
/// **Tier 3.** A real `TBDHolder`, a real pty, and a real job.
@Suite(.serialized)
struct HolderAttachHandoffTests {

    /// A job that answers every line it is given, and speaks only when spoken
    /// to. Deliberately quiet: a job writing on its own would fill the terminal
    /// queue during the windows this suite spends with nobody reading, and the
    /// test would then be measuring backpressure instead of the hand-over.
    private static let echoJob = "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done"

    // MARK: - The screen goes with the descriptor

    @Test func anAttachingViewerReceivesAPreambleThatReproducesTheScreen() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        try await fixture.reader.write(Data("BEFORE-ATTACH\n".utf8))
        #expect(await pollUntil("the job's answer before the attach") {
            await fixture.reader.renderScreen().contains("GOT:BEFORE-ATTACH")
        })

        let vend = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        defer { close(vend.ptyFD) }

        // Replayed into a terminal that has never seen this session, which is
        // the only honest test of a preamble: it asserts on what a viewer would
        // paint, not on the bytes that were emitted.
        let replay = HeadlessReplay(columns: 80, rows: 24)
        replay.feed(vend.snapshotPreamble)
        let painted = replay.screenText()
        #expect(
            painted.contains("GOT:BEFORE-ATTACH"),
            "the replayed preamble painted: \(painted.debugDescription)")
    }

    /// The quiesce reads everything the descriptor still holds *before* it
    /// serializes the screen, so a byte cannot be stranded in a buffer no
    /// reader will ever look at again.
    ///
    /// Deterministic by construction rather than by timing. The first attach
    /// takes the daemon off the pty and is then abandoned unacknowledged, which
    /// leaves it off; the job's answer therefore sits in the tty queue with
    /// provably nobody reading it. The second attach must pick it up on its way
    /// past. Without the drain-the-remainder step, the emulator has never seen
    /// those bytes and the preamble cannot contain them.
    @Test func theQuiesceStrandsNoByteThatWasAlreadyQueued() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let first = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        close(first.ptyFD)
        await fixture.registry.cancelPendingAttach(
            terminalID: fixture.terminalID, generation: first.generation, reason: .unacknowledged)

        // Nobody is reading this pty now. The job's answer accumulates in the
        // kernel's terminal queue and reaches no emulator at all.
        #expect(await !fixture.reader.isDraining)
        try await fixture.reader.write(Data("STRANDED\n".utf8))
        // Given time to arrive rather than checked the instant after the write:
        // the round trip through the job takes milliseconds, and an assertion
        // made before it could have completed is one that cannot fail.
        #expect(
            await !daemonScreenShows("GOT:STRANDED", on: fixture.reader),
            "the daemon read a pty it had already handed over")

        let second = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        defer { close(second.ptyFD) }
        let replay = HeadlessReplay(columns: 80, rows: 24)
        replay.feed(second.snapshotPreamble)
        let painted = replay.screenText()
        #expect(
            painted.contains("GOT:STRANDED"),
            """
            output that was queued on the pty before the attach never reached the emulator, so \
            the viewer will never see it; the replayed preamble painted: \(painted.debugDescription)
            """)
    }

    // MARK: - Who is reading

    /// The vend is the edge. Once the descriptor exists outside this process
    /// the daemon must be off the pty, because the viewer may already be on it.
    @Test func theDaemonStopsReadingWhenItHandsTheDescriptorOver() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let vend = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        defer { close(vend.ptyFD) }

        #expect(
            await !fixture.reader.isDraining,
            "the daemon still had a drain loop on a pty it had handed to a viewer")

        try await fixture.reader.write(Data("AFTER-VEND\n".utf8))
        // Deliberately not read from the viewer's descriptor yet. Racing the
        // two readers would let this pass on a coin flip; leaving the viewer
        // idle means every byte the daemon takes is a byte the viewer can no
        // longer be given, which the positive control below then catches too.
        #expect(
            await !daemonScreenShows("GOT:AFTER-VEND", on: fixture.reader),
            """
            the daemon was still reading a pty it had already handed to a viewer — two readers on \
            one descriptor, each stealing bytes the other will never see
            """)
        // The positive control, and what makes the negative a statement about
        // ownership rather than about a session that printed nothing: the bytes
        // were there the whole time, waiting for the reader that owns them.
        #expect(
            readUntil(fd: vend.ptyFD, contains: "GOT:AFTER-VEND") != nil,
            "the viewer's descriptor never carried the job's answer")
    }

    /// A lost ack and a lost app are indistinguishable on the wire, and the
    /// viewer has the descriptor either way. So an unacknowledged attach does
    /// **not** license a resume: the daemon stays off the pty until something
    /// establishes that the viewer is gone.
    @Test func anUnacknowledgedAttachDoesNotPutTheDaemonBackOnThePty() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let vend = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        defer { close(vend.ptyFD) }
        await fixture.registry.cancelPendingAttach(
            terminalID: fixture.terminalID, generation: vend.generation, reason: .unacknowledged)

        #expect(
            await !fixture.reader.isDraining,
            """
            the daemon went back on a pty a viewer may still be reading, which is the double read \
            the whole design exists to prevent
            """)

        try await fixture.reader.write(Data("NO-ACK\n".utf8))
        #expect(await !daemonScreenShows("GOT:NO-ACK", on: fixture.reader))
        #expect(
            readUntil(fd: vend.ptyFD, contains: "GOT:NO-ACK") != nil,
            "the viewer's descriptor never carried the job's answer")
    }

    /// The one cancellation that does license a resume: the vend itself failed,
    /// so the descriptor never left this process and nobody else can have it.
    ///
    /// Not an optimisation — a session left unread is a session whose job
    /// cannot finish exiting, so a failure that says nothing about the viewer
    /// must not cost that.
    @Test func aVendThatNeverReachedAViewerPutsTheDaemonBackOnThePty() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let vend = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        close(vend.ptyFD)
        await fixture.registry.cancelPendingAttach(
            terminalID: fixture.terminalID, generation: vend.generation,
            reason: .descriptorNeverDelivered)

        try await fixture.reader.write(Data("RESUMED\n".utf8))
        #expect(
            await pollUntil("the daemon to be draining its session again") {
                await fixture.reader.renderScreen().contains("GOT:RESUMED")
            },
            "the daemon never resumed draining, so this session's job can no longer finish exiting")
        #expect(await fixture.reader.isDraining)
    }

    // MARK: - Ownership

    @Test func acknowledgingAnAttachHandsTheSessionToTheViewer() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let vend = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        defer { close(vend.ptyFD) }

        // An ack for an attach nobody is waiting on is refused rather than
        // allowed to release a reader some other attach is relying on.
        await #expect(throws: HolderRegistry.Error.self) {
            try await fixture.registry.confirmAttach(
                terminalID: fixture.terminalID, generation: vend.generation &+ 41)
        }

        try await fixture.registry.confirmAttach(
            terminalID: fixture.terminalID, generation: vend.generation)

        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == vend.generation)
        #expect(
            await fixture.registry.reader(for: fixture.terminalID) == nil,
            "the daemon kept a reader for a session it no longer reads")
        #expect(await !fixture.reader.isDraining)

        // And the session belongs to the viewer: an adoption must refuse it
        // rather than build the second reader that would steal its bytes.
        await #expect(throws: HolderRegistry.Error.attachedToViewer(terminalID: fixture.terminalID)) {
            try await fixture.registry.adopt(terminal: fixture.terminalRow)
        }

        // The viewer's descriptor is a working pty in both directions: writing
        // to the master is what typing into the session is.
        try writeAll(fd: vend.ptyFD, "AFTER-ACK\n")
        #expect(
            readUntil(fd: vend.ptyFD, contains: "GOT:AFTER-ACK") != nil,
            "the session the viewer was handed does not answer it")
    }

    // MARK: - The capture must not type into the child

    /// Reading the terminal's mode state means asking the terminal, and the
    /// terminal answers by *sending* — which, in the daemon, normally means
    /// writing to the pty. Down that path a `DECRQM` answer arrives at the job
    /// as if somebody had typed it.
    ///
    /// The probe puts its tty in raw mode first, so the only way anything can
    /// reach the screen is the job printing what it actually read. Echo would
    /// otherwise put the same bytes there without the child ever seeing them,
    /// and the assertion could not tell the two apart.
    @Test func capturingModeStateDoesNotTypeIntoTheChild() async throws {
        let interpreter = try #require(
            Self.locateInterpreter(), "no python3 to run the raw-mode probe with")
        let fixture = try await AttachFixture.start(
            launch: HolderProcessFixture.launch(
                executable: interpreter, arguments: ["-u", "-c", Self.rawStdinProbe]))
        defer { fixture.tearDown() }

        #expect(await pollUntil("the probe to put its tty in raw mode") {
            await fixture.reader.renderScreen().contains("RAW-READY|")
        })

        let vend = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        close(vend.ptyFD)
        // Put the daemon back on the pty so anything the capture typed into the
        // child, and the child then reported, reaches the emulator where this
        // test can see it.
        await fixture.registry.cancelPendingAttach(
            terminalID: fixture.terminalID, generation: vend.generation,
            reason: .descriptorNeverDelivered)

        // The fence: a byte this test really did send arrives and is reported,
        // so "no reply reached the child" is a statement about a screen that
        // has finished receiving rather than about one that is merely empty.
        try await fixture.reader.write(Data("PING".utf8))
        #expect(await pollUntil("the probe to report the byte the test sent") {
            await fixture.reader.renderScreen().contains("SAW:PING|")
        })

        let screen = await fixture.reader.renderScreen()
        #expect(
            !screen.contains("SAW:<ESC>"),
            """
            the terminal's own answers were written to the pty and the job read them as input; \
            its screen was: \(screen.debugDescription)
            """)
    }

    /// Reports every byte it reads, with its tty in raw mode so nothing is
    /// echoed and nothing waits for a newline — a `DECRQM` answer carries no
    /// newline, so a canonical-mode probe would never be handed one to report.
    private static let rawStdinProbe = """
        import sys, os, tty
        tty.setraw(0)
        sys.stdout.write("RAW-READY|\\r\\n")
        sys.stdout.flush()
        while True:
            chunk = os.read(0, 1024)
            if not chunk:
                break
            seen = chunk.decode("latin1").replace("\\x1b", "<ESC>")
            sys.stdout.write("SAW:" + seen + "|\\r\\n")
            sys.stdout.flush()
        """

    private static func locateInterpreter() -> String? {
        ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Fixture

/// A live holder, a registry that has adopted it, and the reader that registry
/// published — the daemon's steady state for one session, which is where every
/// attach starts.
private struct AttachFixture {
    let process: HolderProcessFixture
    let registry: HolderRegistry
    let reader: HolderReader

    var terminalID: UUID { process.sessionID }

    /// The row the daemon would resolve for this session. A holder row carries
    /// no tmux coordinates at all — that is what makes `transport` the only
    /// thing that can discriminate it.
    var terminalRow: TBDShared.Terminal {
        TBDShared.Terminal(
            id: process.sessionID, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)
    }

    static func start(command: String) async throws -> AttachFixture {
        try await start(launch: HolderProcessFixture.launch(command: command))
    }

    static func start(launch request: HolderLaunchRequest) async throws -> AttachFixture {
        let process = try await HolderProcessFixture.start(launch: request)
        // The spawner's handshake connection has to go before anything else can
        // be served: a holder serves one client at a time, and the adoption
        // below opens its own.
        await process.client.close()
        let registry = HolderRegistry(
            owner: process.owner,
            environment: HolderProcessFixture.environment(home: process.home),
            listTerminals: { [] })
        let fixture = AttachFixture(
            process: process,
            registry: registry,
            reader: try await registry.adopt(
                terminal: TBDShared.Terminal(
                    id: process.sessionID, worktreeID: UUID(), tmuxWindowID: "",
                    tmuxPaneID: "", transport: .holder)))
        return fixture
    }

    /// Releases the registry's readers and kills the holder AND its job, by
    /// pid. Holder death is not child death, so both need naming; a reader left
    /// running leaks a thread and a pty descriptor for the rest of the suite.
    func tearDown() {
        let registry = self.registry
        Task.detached { await registry.releaseAll() }
        process.tearDown()
    }
}

/// Whether the daemon's own screen shows `needle` within a short budget.
///
/// Reports rather than records, because every use here asserts that it never
/// does — and a negative taken the instant after a write is not an assertion at
/// all: the round trip through the job takes milliseconds, so a daemon that IS
/// reading would not have shown it yet either. The budget is generous against
/// that round trip and bounded against a suite that must not sit on wall time.
/// It errs, under enough load, toward missing a daemon that reads late — a
/// false green rather than a false red.
private func daemonScreenShows(
    _ needle: String, on reader: HolderReader, within budget: TimeInterval = 1.0
) async -> Bool {
    let deadline = Date().addingTimeInterval(budget)
    while Date() < deadline {
        if await reader.renderScreen().contains(needle) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

// MARK: - Reading a vended descriptor

/// Reads a vended pty until `needle` appears, or gives up.
///
/// The descriptor is non-blocking — the flag lives on the open file description
/// the `dup` shares with the daemon's own copy — so this polls rather than
/// blocking, which is also what any real viewer of one of these has to do.
private func readUntil(
    fd: Int32,
    contains needle: String,
    timeout: TimeInterval = 10.0
) -> String? {
    var seen = ""
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&watched, 1, 100) > 0, watched.revents != 0 else { continue }
        let count = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress, raw.count)
        }
        if count > 0 {
            seen += String(decoding: buffer[0..<count], as: UTF8.self)
            if seen.contains(needle) { return seen }
        } else if count == 0 {
            return nil
        } else if errno != EAGAIN && errno != EINTR {
            return nil
        }
    }
    return nil
}

/// Writes to a vended pty, which is what typing into that session is.
private func writeAll(fd: Int32, _ text: String) throws {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        }
        if written > 0 {
            offset += written
            continue
        }
        guard errno == EAGAIN || errno == EINTR else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var watched = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        _ = poll(&watched, 1, 100)
    }
}

// MARK: - Replaying a preamble

/// A terminal that has never seen the session, for replaying a preamble into.
///
/// The delegate is retained here because `Terminal.tdel` is weak, and it
/// answers nothing: a replay must never write back.
private final class HeadlessReplay {
    private let terminal: SwiftTerm.Terminal
    private let delegate = SilentDelegate()

    init(columns: Int, rows: Int) {
        terminal = SwiftTerm.Terminal(
            delegate: delegate, options: TerminalOptions(cols: columns, rows: rows))
    }

    func feed(_ data: Data) {
        terminal.terminalLock.withLock { terminal.feed(byteArray: [UInt8](data)) }
    }

    /// The viewport as text, one line per row, trailing blank rows dropped —
    /// the same shape `HolderReader.renderScreen` produces, so the two are
    /// comparable.
    func screenText() -> String {
        terminal.terminalLock.withLock {
            var lines: [String] = []
            for row in 0..<terminal.rows {
                lines.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
            }
            while let last = lines.last, last.isEmpty { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
    }
}

private final class SilentDelegate: TerminalDelegate {
    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {}
}
