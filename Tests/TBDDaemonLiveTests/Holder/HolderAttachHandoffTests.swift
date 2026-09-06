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
    /// Driven against the reader rather than the registry, because the reader
    /// is where the quiesce lives and because the registry — correctly —
    /// refuses to open a second hand-over while a viewer may hold the pty. The
    /// two suspensions here are the two halves of the same production call:
    /// `beginAttach` quiesces and then snapshots, in that order.
    ///
    /// Deterministic by construction rather than by timing. The first
    /// suspension takes the daemon off the pty and nothing puts it back, so the
    /// job's answer sits in the kernel's terminal queue with provably nobody
    /// reading it. The second must pick it up on its way past; without the
    /// drain-the-remainder step the emulator has never seen those bytes and the
    /// preamble cannot contain them.
    @Test func theQuiesceStrandsNoByteThatWasAlreadyQueued() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let first = try await fixture.reader.suspendDraining()
        close(first)
        #expect(await !fixture.reader.isDraining)

        try await fixture.reader.write(Data("STRANDED\n".utf8))
        // Given time to arrive rather than checked the instant after the write:
        // the round trip through the job takes milliseconds, and an assertion
        // made before it could have completed is one that cannot fail.
        #expect(
            await !daemonScreenShows("GOT:STRANDED", on: fixture.reader),
            "the daemon read a pty it had already stepped off")

        let second = try await fixture.reader.suspendDraining()
        close(second)
        let replay = HeadlessReplay(columns: 80, rows: 24)
        replay.feed(await fixture.reader.snapshotPreamble())
        let painted = replay.screenText()
        #expect(
            painted.contains("GOT:STRANDED"),
            """
            output that was queued on the pty before the hand-over never reached the emulator, so \
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
            readPTYUntil(fd: vend.ptyFD, contains: "GOT:AFTER-VEND") != nil,
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
            readPTYUntil(fd: vend.ptyFD, contains: "GOT:NO-ACK") != nil,
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

    /// What an acknowledgement decides, and what it deliberately does not.
    ///
    /// It decides **who reads the pty**: the viewer, and the daemon neither
    /// drains it nor duplicates it again. It does not decide who owns the
    /// *emulator*. That reader stays in the slot, suspended, because it holds
    /// the session's screen as it stood at the attach and is the only store
    /// there is whenever the viewer cannot answer for itself.
    ///
    /// `reader(for:) != nil` is therefore not evidence the daemon is on the
    /// pty, and this suite no longer uses it as such. `isDraining` is the
    /// honest instrument: it reads the drain thread's own flag.
    @Test func acknowledgingAnAttachHandsTheSessionToTheViewer() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        // Something on the screen before the hand-over, so "the emulator was
        // retained" is a claim about content and not only about a pointer.
        try await fixture.reader.write(Data("BEFORE-ATTACH\n".utf8))
        #expect(await pollUntil("the job's answer before the attach") {
            await fixture.reader.renderScreen().contains("GOT:BEFORE-ATTACH")
        })

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
        let retained = try #require(
            await fixture.registry.reader(for: fixture.terminalID),
            """
            the acknowledgement discarded the daemon's emulator, so this session has no screen \
            to answer a machine read with and no modes to compose input against
            """)
        #expect(retained === fixture.reader, "the acknowledgement built a second reader")
        #expect(
            await !retained.isDraining,
            "the daemon is still draining a pty it handed to a viewer")

        // Retained with its contents, not merely retained: the screen the
        // daemon was holding at the attach is still there to answer with.
        let held = await retained.renderScreen()
        #expect(held.contains("GOT:BEFORE-ATTACH"), """
            the retained emulator lost the screen it was holding: \(held)
            """)

        // And the session belongs to the viewer: an adoption must refuse it
        // rather than build the second reader that would steal its bytes.
        await #expect(throws: HolderRegistry.Error.attachedToViewer(terminalID: fixture.terminalID)) {
            try await fixture.registry.adopt(terminal: fixture.terminalRow)
        }

        // The viewer's descriptor is a working pty in both directions: writing
        // to the master is what typing into the session is.
        try writePTY(fd: vend.ptyFD, "AFTER-ACK\n")
        #expect(
            readPTYUntil(fd: vend.ptyFD, contains: "GOT:AFTER-ACK") != nil,
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

    // MARK: - One descriptor at a time

    /// A second attach is refused while one is still in flight, because a
    /// vended descriptor cannot be taken back.
    ///
    /// The interleave is forced through the registry's attach barrier rather
    /// than raced: the real window is a suspension inside `beginAttach`, and a
    /// test that reproduced it by timing would pass by luck and stop
    /// reproducing it the day the scheduler changed.
    @Test func aSecondAttachIsRefusedWhileTheFirstIsStillInFlight() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let barrier = ReentryBarrier()
        await fixture.registry.setAttachBarrier { await barrier.arriveAndWait() }

        // Only Sendable values cross into the task: the fixture itself is a
        // plain struct around a class, and the registry is an actor.
        let registry = fixture.registry
        let terminalID = fixture.terminalID
        let inFlight = Task { try await registry.beginAttach(terminalID: terminalID) }
        #expect(await pollUntil("the first attach to reach the barrier") { await barrier.hasParked })

        // The first call is holding a fresh dup of the pty and has published
        // nothing. A second attach here is the double vend: it would quiesce an
        // already-quiesced reader, dup the same descriptor again, and hand a
        // second live pty to a second viewer.
        await #expect(throws: HolderRegistry.Error.self) {
            try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        }

        await barrier.release()
        let vend = try await inFlight.value
        defer { close(vend.ptyFD) }
        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == nil)
        // And the one descriptor that WAS vended is the working one.
        try writePTY(fd: vend.ptyFD, "ONLY-ONE\n")
        #expect(readPTYUntil(fd: vend.ptyFD, contains: "GOT:ONLY-ONE") != nil)
    }

    /// An attach whose session is acknowledged out from under it while it is in
    /// flight vends nothing at all.
    ///
    /// `confirmAttach` records the viewer's ownership and then suspends — the
    /// jiggle is a deliberate 10 ms sleep — so a `beginAttach` parked between
    /// its quiesce and its guard resumes into a session that now belongs to
    /// somebody else. Handing over its descriptor there would put a second
    /// reader on a pty a confirmed viewer already owns, which is the one
    /// unrecoverable outcome on this path. Forced through the barrier for the
    /// same reason as above; the acknowledgement names the generation the
    /// in-flight call claimed before it suspended.
    @Test func anAttachAcknowledgedWhileInFlightVendsNothing() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let barrier = ReentryBarrier()
        await fixture.registry.setAttachBarrier { await barrier.arriveAndWait() }

        let registry = fixture.registry
        let terminalID = fixture.terminalID
        let inFlight = Task { try await registry.beginAttach(terminalID: terminalID) }
        #expect(await pollUntil("the attach to reach the barrier") { await barrier.hasParked })

        // Generations are minted from 1 for a fresh registry, and this call
        // claimed one before it suspended — which is exactly what lets an
        // acknowledgement land in this window at all.
        let acknowledging = Task { try await registry.confirmAttach(terminalID: terminalID, generation: 1) }

        // Released while the acknowledgement is still *inside* itself, not
        // after it: it records the viewer's ownership and then suspends in the
        // jiggle, so the in-flight attach resumes to find the session already
        // given away while its slot still reads `.adopted`. That is the state
        // only the ownership half of the guard can see — wait until the
        // acknowledgement completes instead and the slot check would cover for
        // it. Missing the window can only weaken what this discriminates; it
        // cannot redden a correct implementation, which refuses either way.
        #expect(await pollUntil("the acknowledgement to record the viewer's ownership") {
            await registry.viewerAttachment(for: terminalID) != nil
        })
        await barrier.release()

        await #expect(throws: HolderRegistry.Error.self) {
            _ = try await inFlight.value
        }
        try await acknowledging.value
        #expect(await registry.viewerAttachment(for: terminalID) == 1)
    }

    /// An attach is refused while a cancelled one is still being put back on
    /// its pty — the resume-side half of the same window.
    ///
    /// The name of the cancellation reason is misleading here, and that is why
    /// this is reachable: the descriptor from the *failed* vend never left the
    /// process, which is what makes resuming safe. It says nothing about the
    /// descriptor a concurrent attach would make. Let one through while the
    /// resume is in flight and the daemon ends up draining a pty the app is
    /// also on.
    ///
    /// Parked through the cancel barrier rather than raced: the window is a
    /// single `await` on an actor.
    @Test func anAttachIsRefusedWhileACancelledOneIsResuming() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }
        let registry = fixture.registry
        let terminalID = fixture.terminalID

        let vend = try await registry.beginAttach(terminalID: terminalID)
        // As if the vend had failed: this process still holds the only copy
        // that was ever made, which is the evidence the resume rests on.
        close(vend.ptyFD)

        let barrier = ReentryBarrier()
        await registry.setCancelBarrier { await barrier.arriveAndWait() }
        let cancelling = Task {
            await registry.cancelPendingAttach(
                terminalID: terminalID, generation: vend.generation,
                reason: .descriptorNeverDelivered)
        }
        #expect(await pollUntil("the cancellation to reach the barrier") {
            await barrier.hasParked
        })

        // The reader is suspended and about to be put back. An attach here
        // would quiesce it, hand out a fresh dup, and then the resume would
        // land underneath: two readers on one pty.
        await #expect(
            throws: HolderRegistry.Error.attachAlreadyPending(
                terminalID: terminalID, generation: vend.generation)
        ) {
            try await registry.beginAttach(terminalID: terminalID)
        }

        await barrier.release()
        await cancelling.value
        #expect(await fixture.reader.isDraining)
        #expect(await registry.viewerAttachment(for: terminalID) == nil)

        // And the refusal was for the duration of the transition, not for good.
        let afterwards = try await registry.beginAttach(terminalID: terminalID)
        close(afterwards.ptyFD)
    }

    /// A session with an attach in flight cannot be adopted, because its reader
    /// has already stepped off the pty.
    ///
    /// `.adopted` stops meaning "draining" the moment an attach quiesces the
    /// reader, so handing that reader back would answer "adopted and reading"
    /// about a session nobody is reading — and, once the attach completes,
    /// about one a viewer owns.
    @Test func adoptingASessionWithAnAttachInFlightIsRefused() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let barrier = ReentryBarrier()
        await fixture.registry.setAttachBarrier { await barrier.arriveAndWait() }
        let registry = fixture.registry
        let terminalID = fixture.terminalID
        let inFlight = Task { try await registry.beginAttach(terminalID: terminalID) }
        #expect(await pollUntil("the attach to reach the barrier") { await barrier.hasParked })

        // The specific case, not merely "some error": generations are minted
        // from 1 for a fresh registry, so the attach parked above holds 1.
        await #expect(
            throws: HolderRegistry.Error.attachAlreadyPending(
                terminalID: terminalID, generation: 1)
        ) {
            try await registry.adopt(terminal: fixture.terminalRow)
        }

        await barrier.release()
        let vend = try await inFlight.value
        close(vend.ptyFD)
    }

    /// After an acknowledgement, a further attach is refused rather than
    /// vending a second descriptor for a pty the viewer owns.
    @Test func attachingAnAlreadyAttachedSessionIsRefused() async throws {
        let fixture = try await AttachFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let vend = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        defer { close(vend.ptyFD) }
        try await fixture.registry.confirmAttach(
            terminalID: fixture.terminalID, generation: vend.generation)

        await #expect(
            throws: HolderRegistry.Error.attachedToViewer(terminalID: fixture.terminalID)
        ) {
            try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        }
    }

    // MARK: - Mode state survives the hand-over

    /// The preamble carries mode state the daemon can only learn by *asking*
    /// its terminal, which is the half of the snapshot that a broken `DECRQM`
    /// round trip would silently drop.
    ///
    /// Mouse tracking rather than, say, cursor visibility: its default is off,
    /// so a capture that answered nothing at all would emit nothing, while the
    /// default-on modes would coincidentally emit the right escape for the
    /// wrong reason.
    @Test func theSnapshotCarriesModeStateItHadToAskTheTerminalFor() async throws {
        let fixture = try await AttachFixture.start(
            command: "printf '\\033[?1000hMOUSE-ON\\n'; " + Self.echoJob)
        defer { fixture.tearDown() }

        #expect(await pollUntil("the job to turn mouse tracking on") {
            await fixture.reader.renderScreen().contains("MOUSE-ON")
        })

        let vend = try await fixture.registry.beginAttach(terminalID: fixture.terminalID)
        defer { close(vend.ptyFD) }
        let preamble = String(decoding: vend.snapshotPreamble, as: UTF8.self)
        #expect(
            preamble.contains("\u{1b}[?1000h"),
            """
            the preamble did not set mouse tracking, so the terminal's answer to the DECRQM query \
            was never read and every mode the daemon cannot see through a public property is being \
            reported as off
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
    /// pid. Holder death is not child death, so both need naming.
    ///
    /// The release is **waited for**, not fired and forgotten. A `defer` cannot
    /// `await`, so the hop is a detached task and a bounded semaphore — bounded
    /// so a wedged release fails the suite slowly rather than hanging it
    /// forever. Waiting matters because the thing being released is a drain
    /// thread and a pty descriptor, and this repo's expensive lessons about
    /// leaked test resources (7,100 dead tmux sockets, 18k orphan profile
    /// directories) were all of the same shape: per-test cleanup that was
    /// started but never observed to finish.
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

// MARK: - Forcing an interleave

/// Holds the **first** caller that reaches the seam it is installed on, and
/// waves through every one after it.
///
/// The same shape `HolderAdoptionTests` uses for the adoption interleavings,
/// and it is here for the same reason: each of these races is a
/// continuation-ordering accident inside an actor, so reproducing one by timing
/// would pass by luck and prove nothing on the day it went green. Nothing here
/// sleeps to *create* the interleave — the polling is only how each side
/// observes a state the other has definitely reached, and it is bounded through
/// `pollUntil`, so a barrier nobody releases fails its test with a named
/// diagnostic instead of hanging the suite.
private actor ReentryBarrier {
    private var parked = false
    private var released = false

    var hasParked: Bool { parked }

    func release() { released = true }

    private var isReleased: Bool { released }

    func arriveAndWait() async {
        guard !parked else { return }
        parked = true
        while !released {
            try? await Task.sleep(for: .milliseconds(5))
        }
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
