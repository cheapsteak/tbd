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
