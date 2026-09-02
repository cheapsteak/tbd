import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Letting go of a session that has ended.
///
/// A `HolderReader` is expensive — a dedicated thread with a 1 MB stack, a
/// 64 KB read buffer, an emulator holding thousands of lines of scrollback, and
/// a dup of the pty master — and after end of file its drain thread parks on
/// its wake pipe rather than exiting, so nothing but a `release` unwinds any of
/// it. Without a reclaimer the daemon's memory tracks sessions *adopted since
/// it started* rather than sessions alive, and a long-lived daemon on a busy
/// fleet grows without bound.
///
/// The two conditions are what these tests pin, and each has a failure of its
/// own:
///
///   - Releasing on the exit alone would throw away output. A holder hands its
///     master over even after its child has exited, precisely so that what the
///     job wrote and nobody read can still be drained;
///     `drainsAFinishedJobsOutputBeforeReleasingIt` asserts the bytes reached
///     the emulator before the release did.
///   - Releasing on end of file alone would drop a live session. A job may
///     close its terminal and keep running, and
///     `keepsTheReaderForAJobThatIsStillRunning` is the other polarity.
@Suite(.serialized)
struct HolderReclaimTests {

    // MARK: - A job that ended before the daemon adopted it

    /// A job that ran out during an outage has its reader released as soon as
    /// the restarted daemon has adopted and drained it.
    ///
    /// The job writes nothing, deliberately: a job that wrote would still be
    /// half-exited in `ttywait` behind its own unread output, and this test
    /// would be measuring that instead. Here the exit is complete before
    /// adoption, so the status rides the hand-over and no probe is needed —
    /// which makes this the leg that proves the reclaimer does not depend on
    /// one.
    @Test func releasesTheReaderForAJobThatEndedDuringTheOutage() async throws {
        let fixture = try await HolderProcessFixture.start(command: "sleep 1; exit 7")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let ended = await pollUntil("the job to finish exiting") {
            !holderProcessIsAlive(fixture.handle.childPID)
        }
        #expect(ended)

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }

        _ = try await registry.adopt(terminal: holderTerminal(id: fixture.sessionID))
        let released = await pollUntil("the registry to release the finished session's reader") {
            await registry.reader(for: fixture.sessionID) == nil
        }
        #expect(
            released,
            "the reader for a job that had already exited was never released")
        let status = await registry.lastKnownStatus(for: fixture.sessionID)
        #expect(
            status == .exited(code: 7),
            "releasing the reader lost the exit status: \(String(describing: status))")
    }

    // MARK: - Output the job left behind

    /// A finished job's queued output reaches the emulator before its reader is
    /// released.
    ///
    /// The setup is the wedge this transport exists to survive: the job wrote a
    /// line and exited while nobody was reading, so it is **not** finished — it
    /// is stopped inside `proc_exit`, in `ttywait`, behind its own output. The
    /// holder hands the master over anyway, precisely so an adopter can rescue
    /// those bytes, and a reclaimer that let go on the exit alone would throw
    /// away exactly what that rule rescues.
    ///
    /// The reader object is held here, so its emulator outlives the release and
    /// the screen can be read afterwards. The order of the assertions is the
    /// point: the release is waited for first, and the bytes must already be
    /// there when it has happened.
    @Test func drainsAFinishedJobsOutputBeforeReleasingIt() async throws {
        let fixture = try await HolderProcessFixture.start(command: "printf 'LAST\\n'; exit 7")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }

        let reader = try await registry.adopt(
            terminal: holderTerminal(id: fixture.sessionID))
        let released = await pollUntil("the registry to release the finished session's reader") {
            await registry.reader(for: fixture.sessionID) == nil
        }
        #expect(
            released,
            "the reader for a job that has exited and been drained was never released")

        let screen = await reader.renderScreen()
        #expect(
            screen.contains("LAST"),
            """
            the reader was released before the job's queued output reached the emulator: \
            \(screen.debugDescription)
            """)
        let status = await registry.lastKnownStatus(for: fixture.sessionID)
        #expect(
            status == .exited(code: 7),
            "releasing the reader lost the exit status: \(String(describing: status))")
        // The drain is what let the job finish exiting at all.
        let gone = await pollUntil("the drained job to finish exiting") {
            !holderProcessIsAlive(fixture.handle.childPID)
        }
        #expect(gone)
    }

    // MARK: - A job that ends while the daemon is watching

    /// A job that exits *after* it was adopted is reclaimed too.
    ///
    /// This is the case the leak was actually made of. The status recorded at
    /// adoption says `.alive` and nothing ever updates it on its own — the
    /// daemon closes its connection after the hand-over, so the holder has
    /// nobody to push the exit at. The reclaimer asks, over a fresh connection,
    /// on the one edge where asking is free: past end of file there is no
    /// queued output left for the holder's wind-down to take with it.
    ///
    /// The job is ended by closing its stdin (`EOT` on a canonical-mode pty),
    /// so nothing here signals or kills anything: the shell's read loop simply
    /// runs out of input and the script exits 0.
    @Test func reclaimsAReaderWhoseJobExitsWhileItIsAdopted() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }

        let reader = try await registry.adopt(
            terminal: holderTerminal(id: fixture.sessionID))
        try await reader.write(Data("HELLO\n".utf8))
        let answered = await pollUntil("the job's answer") {
            await reader.renderScreen().contains("GOT:HELLO")
        }
        #expect(answered)

        // Still running, still adopted: the reclaimer must not have fired on a
        // session that is merely quiet.
        let whileAlive = await registry.reader(for: fixture.sessionID)
        #expect(whileAlive === reader, "a live session's reader was released")

        try await reader.write(Data([0x04]))

        let released = await pollUntil("the registry to release the ended session's reader") {
            await registry.reader(for: fixture.sessionID) == nil
        }
        #expect(released, "the reader for a job that exited under the daemon was never released")

        let status = await registry.lastKnownStatus(for: fixture.sessionID)
        #expect(
            status == .exited(code: 0),
            """
            the reclaimer released the reader without establishing how the job ended: \
            \(String(describing: status))
            """)
    }

    // MARK: - The other polarity

    /// A reader whose job is still running is kept, however quiet the session
    /// is.
    ///
    /// The gate is end of file on the pty master, not idleness: a reclaimer that
    /// reached for "no output lately" would stop draining a live job's terminal,
    /// which is the wedge the whole transport is built to avoid.
    @Test func keepsTheReaderForAJobThatIsStillRunning() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "printf 'ALIVE\\n'; sleep 30")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }

        let reader = try await registry.adopt(
            terminal: holderTerminal(id: fixture.sessionID))
        let spoke = await pollUntil("the job's first line") {
            await reader.renderScreen().contains("ALIVE")
        }
        #expect(spoke)

        // Long enough to outlast the reclaimer's own confirmation budget, so a
        // registry that released on quiet rather than on end of file has had
        // every chance to do so.
        try await Task.sleep(for: HolderRegistry.exitConfirmationBudget)

        let stored = await registry.reader(for: fixture.sessionID)
        #expect(stored === reader, "the reader for a running job was released")
        let draining = await reader.isDraining
        #expect(draining, "the reader for a running job stopped draining its pty")
        #expect(holderProcessIsAlive(fixture.handle.childPID))
    }

    // MARK: - A holder that cannot be reached

    /// A probe that could not reach the holder is not a confirmed exit, and
    /// does not license a release.
    ///
    /// This is the failure the two-condition policy exists to prevent, seen
    /// from the one angle that makes it look harmless: end of file has been
    /// reached, so the first condition holds, and the only thing standing
    /// between a live session and a discarded reader is whether the second one
    /// takes an *answer* or merely an attempt. A holder killed between the
    /// accept and its reply — which is what the stranger on the rendezvous here
    /// imitates — makes every probe fail without ever saying anything about the
    /// child, and a reclaimer that read that as "exited" would release a reader
    /// whose session row is still live and lose its scrollback for good.
    ///
    /// The real holder is taken down first, and taking it down does **not**
    /// take the job with it: the reader holds its own dup of the pty master, so
    /// nothing hangs the foreground group up. That is what lets this test put a
    /// stranger on the rendezvous path while the session underneath is still a
    /// perfectly ordinary live one.
    @Test func keepsTheReaderWhenTheExitProbeCannotReachTheHolder() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }

        let reader = try await registry.adopt(
            terminal: holderTerminal(id: fixture.sessionID))
        try await reader.write(Data("HELLO\n".utf8))
        let answered = await pollUntil("the job's answer") {
            await reader.renderScreen().contains("GOT:HELLO")
        }
        #expect(answered)

        let socketPath = try HolderRendezvous.socketPath(
            sessionID: fixture.sessionID,
            environment: HolderProcessFixture.environment(home: fixture.home))
        killAndReapHolder(fixture)
        let stranger = try #require(
            HangUpListener.bind(replacing: socketPath),
            "the stranger could not take over the rendezvous path")
        defer { stranger.shutDown() }

        // Closing the job's stdin is what drives the pty to end of file, which
        // is the edge the reclaimer fires on.
        try await reader.write(Data([0x04]))
        let drained = await pollUntil("the reader to reach the end of the session's output") {
            await reader.hasReachedEndOfOutput
        }
        #expect(drained)

        // Longer than the confirmation budget, so a registry that released on a
        // failed probe has had every chance to do so.
        try await Task.sleep(for: HolderRegistry.exitConfirmationBudget + .seconds(1))

        let stored = await registry.reader(for: fixture.sessionID)
        #expect(
            stored === reader,
            """
            a holder that never answered was read as a confirmed exit, and the reader — with \
            everything the session had printed — was released
            """)
        let status = await registry.lastKnownStatus(for: fixture.sessionID)
        #expect(
            status == .alive,
            """
            a failed probe was recorded as a terminal status: \
            \(String(describing: status))
            """)
    }

    /// Nothing listening at the rendezvous *is* an answer, and the reader is
    /// released.
    ///
    /// The other branch of the same decision, and the reason the fix above is a
    /// classification rather than a blanket "keep on any error". A holder that
    /// has gone cannot unlink its own socket when it is killed, so the file
    /// stays and the connect is refused — and that refusal is evidence of
    /// absence rather than of this daemon failing to reach something. Nothing
    /// will ever be learned about this session again, so keeping its reader
    /// would be the unbounded leak the reclaimer exists to close.
    @Test func releasesTheReaderWhenNothingIsListeningAtTheRendezvous() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }

        let reader = try await registry.adopt(
            terminal: holderTerminal(id: fixture.sessionID))
        try await reader.write(Data("HELLO\n".utf8))
        let answered = await pollUntil("the job's answer") {
            await reader.renderScreen().contains("GOT:HELLO")
        }
        #expect(answered)

        // The socket file is deliberately left where it is: a SIGKILLed holder
        // cannot unlink it, so a bound path with nobody behind it is what
        // production actually leaves behind.
        killAndReapHolder(fixture)

        try await reader.write(Data([0x04]))

        let released = await pollUntil("the registry to release the ended session's reader") {
            await registry.reader(for: fixture.sessionID) == nil
        }
        #expect(released, "a session whose holder is gone kept its reader forever")
        let status = await registry.lastKnownStatus(for: fixture.sessionID)
        #expect(
            status == .exitedStatusUnknown,
            """
            releasing a session whose holder had gone should record that nobody collected its \
            status, not a fabricated one: \(String(describing: status))
            """)
    }

    // MARK: - Support

    /// A holder-transport row; the same shape `HolderAdoptionTests` uses, and
    /// for the same reason — `tmuxWindowID`/`tmuxPaneID` are NOT NULL from the
    /// v1 schema and a holder row has no tmux coordinate to put in them.
    private func holderTerminal(id: UUID) -> Terminal {
        Terminal(
            id: id, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder)
    }

    /// A registry whose rendezvous paths come from an explicit environment, so
    /// nothing here can reach the developer's real `~/tbd` even for an instant.
    private func makeRegistry(owner: HolderOwnerToken, home: String) -> HolderRegistry {
        HolderRegistry(
            owner: owner,
            environment: HolderProcessFixture.environment(home: home),
            listTerminals: { [] })
    }
}

/// Releases a registry's readers from a `defer`, which cannot `await`.
/// Idempotent, and needed on every exit path: see the note in
/// `HolderAdoptionTests`.
private func releaseInBackground(_ registry: HolderRegistry) {
    Task.detached { await registry.releaseAll() }
}

/// Kills a fixture's holder and collects its corpse, leaving the job running.
///
/// **Holder death is not job death**, and that is what this leans on: the
/// registry's reader holds its own dup of the pty master, so closing the
/// holder's copy hangs nothing up and the session underneath stays exactly as
/// live as it was. The reap is owed to this process — the spawner
/// `posix_spawn`s the holder directly, so nobody else can collect it — and
/// `noteHolderReaped` is what stops the fixture signalling a pid number the
/// kernel has already handed to somebody else.
private func killAndReapHolder(_ fixture: HolderProcessFixture) {
    kill(fixture.handle.holderPID, SIGKILL)
    var ignored: Int32 = 0
    _ = waitpid(fixture.handle.holderPID, &ignored, 0)
    fixture.noteHolderReaped()
}

/// A stranger bound to a holder's rendezvous path that accepts every
/// connection and immediately hangs up.
///
/// It stands for every way a round trip can fail without establishing
/// anything: the path is reachable, so nothing here says the holder is *gone*,
/// and the probe fails all the same. Whether the client reports the hang-up as
/// `peerClosed` or as a broken pipe on the way out is decided by microseconds,
/// and the reclaimer must reach the same conclusion either way — so the test
/// that uses this asserts on the outcome rather than on which of the two
/// arrived.
///
/// The accept loop owns the descriptor and closes it itself, rather than being
/// woken by a close from another thread: closing a descriptor out from under a
/// blocked `accept` is not a documented wake-up on Darwin, and a test helper
/// that parked a pooled thread forever would be a worse bug than the one it is
/// here to catch.
private final class HangUpListener: @unchecked Sendable {
    private let listenFD: Int32
    private let path: String
    private let lock = NSLock()
    private var stopping = false

    private init(listenFD: Int32, path: String) {
        self.listenFD = listenFD
        self.path = path
    }

    /// Unlinks whatever is at `path` and binds there instead.
    static func bind(replacing path: String) -> HangUpListener? {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                UnsafeMutableRawPointer(destination)
                    .copyMemory(from: source, byteCount: strlen(source) + 1)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            return nil
        }
        let listener = HangUpListener(listenFD: fd, path: path)
        DispatchQueue.global().async { listener.run() }
        return listener
    }

    /// Asks the accept loop to stop. It closes the descriptor and unlinks the
    /// path on its way out, within one poll slice.
    func shutDown() {
        lock.lock()
        stopping = true
        lock.unlock()
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func run() {
        // A ceiling, so a helper that somehow outlived its test cannot poll for
        // the life of the process.
        let deadline = Date().addingTimeInterval(120)
        while !isStopping, Date() < deadline {
            var descriptor = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) > 0 else { continue }
            let accepted = accept(listenFD, nil, nil)
            if accepted >= 0 { Darwin.close(accepted) }
        }
        Darwin.close(listenFD)
        unlink(path)
    }
}
