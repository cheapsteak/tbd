import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Re-adopting live holders after the daemon that spawned them has gone.
///
/// The suite simulates the only interesting failure the transport exists to
/// survive: the daemon dies, its readers die with it, and the holder and its job
/// carry on. Nothing here kills a holder or a job to set that up — a test that
/// did would be testing respawn, not adoption.
///
/// Two of these are load-bearing rather than hygiene:
///
///   - `adoptsALiveHolderAndResumesDraining` asserts on output the job produced
///     **after** the adoption. A reader that was constructed but never started
///     would satisfy any assertion about earlier output, and would leave the
///     session exactly as wedged as no reader at all.
///   - `adoptionIsIdempotent` asserts the **count** of drain loops. Two loops on
///     one pty master is silent byte theft: each `read` takes bytes the other
///     never sees, and object identity alone cannot see the second loop.
@Suite(.serialized)
struct HolderAdoptionTests {

    // MARK: - Adoption resumes the drain

    /// The daemon dies, its reader dies with it, and the session does not.
    ///
    /// The job only speaks when spoken to, deliberately: a job writing on its
    /// own during the outage would wedge in `ttywait` behind its own undrained
    /// output and the test would be measuring that instead. Here the outage is
    /// quiet, and the marker written after the adoption can only reach the
    /// screen if the new reader is genuinely draining.
    @Test func adoptsALiveHolderAndResumesDraining() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done")
        defer { fixture.tearDown() }

        // The daemon that spawned this session had a reader. Stopping it is
        // what a daemon's death looks like from the holder's side: the dup goes
        // away, and the holder, the pty and the job are all untouched.
        let (_, ptyFD) = try await fixture.client.handOverPTY()
        let previous = HolderReader(
            sessionID: fixture.sessionID, ptyFD: ptyFD, columns: 80, rows: 24)
        try await previous.start()
        try await previous.write(Data("BEFORE\n".utf8))
        let sawBefore = await pollUntil("the job's answer before the outage") {
            await previous.renderScreen().contains("GOT:BEFORE")
        }
        #expect(sawBefore)
        await previous.stop()
        // And the client slot goes with it, or the restarted daemon's own
        // connection would be answered with the busy sentinel.
        await fixture.client.close()

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }

        let reader = try await registry.adopt(
            terminal: holderTerminal(id: fixture.sessionID))
        try await reader.write(Data("AFTER\n".utf8))

        let sawAfter = await pollUntil("output the job produced after the adoption") {
            await reader.renderScreen().contains("GOT:AFTER")
        }
        let screen = await reader.renderScreen()
        #expect(sawAfter, "screen was: \(screen.debugDescription)")

        let stored = await registry.reader(for: fixture.sessionID)
        #expect(stored === reader, "the registry did not keep the reader it adopted")
        #expect(holderProcessIsAlive(fixture.handle.childPID))
    }

    // MARK: - One reader, ever

    /// Two adoptions of one session yield one reader and one drain loop.
    ///
    /// The two calls are concurrent on purpose: the guard has to be the actor's
    /// own state, so that a second call arriving mid-adoption *awaits* the first
    /// rather than opening its own connection and taking its own dup. The count
    /// is the assertion that matters — a registry that built a second reader and
    /// then returned the first would pass an identity check while a second drain
    /// loop quietly stole half the session's bytes.
    @Test func adoptionIsIdempotent() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "printf 'DELTA\\n'; sleep 30")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }
        let terminal = holderTerminal(id: fixture.sessionID)

        async let first = registry.adopt(terminal: terminal)
        async let second = registry.adopt(terminal: terminal)
        let readers = try await (first, second)
        #expect(readers.0 === readers.1, "concurrent adoptions produced two readers")

        let third = try await registry.adopt(terminal: terminal)
        #expect(third === readers.0, "a later adoption produced a second reader")

        let loops = await registry.drainLoopsStarted
        #expect(loops == 1, "the registry started \(loops) drain loops on one pty")
    }

    // MARK: - Somebody else's session

    /// A holder that names another installation is left strictly alone.
    ///
    /// `TBD_HOME` is shared by every checkout on a machine, so "reachable and
    /// absent from my database" is exactly what a healthy foreign session looks
    /// like. The assertions are therefore not only that we did not adopt it, but
    /// that it is still *serving* afterwards — alive is not the same as
    /// unharmed.
    @Test func adoptionSkipsForeignOwners() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "printf 'FOREIGN\\n'; sleep 30",
            owner: "another-installation")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = makeRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"), home: fixture.home)
        defer { releaseInBackground(registry) }

        await #expect(
            throws: HolderRegistry.Error.foreignOwner(
                terminalID: fixture.sessionID, holderOwner: "another-installation")
        ) {
            try await registry.adopt(terminal: holderTerminal(id: fixture.sessionID))
        }

        let stored = await registry.reader(for: fixture.sessionID)
        #expect(stored == nil, "a foreign session was adopted")
        let loops = await registry.drainLoopsStarted
        #expect(loops == 0)
        #expect(holderProcessIsAlive(fixture.handle.holderPID))
        #expect(holderProcessIsAlive(fixture.handle.childPID))

        // Still serving, not merely still running.
        let description = try await fixture.client.describe()
        #expect(description.status == .alive)
        #expect(description.owner == HolderOwnerToken(rawValue: "another-installation"))
    }

    /// The other end of the busy-sentinel retry: a holder somebody really is
    /// attached to is reported as refused, not waited on forever.
    ///
    /// The retry exists only to outlast the window in which a holder has not yet
    /// noticed a dead daemon's connection go away. Here the connection is
    /// genuinely alive, so no amount of waiting would help — and a zero budget
    /// says exactly that without spending a second proving it.
    @Test func aBusyHolderIsReportedRatherThanAdopted() async throws {
        let fixture = try await HolderProcessFixture.start(command: "sleep 30")
        defer { fixture.tearDown() }
        // Deliberately left attached: the spawner's handshake connection is the
        // holder's one client slot, and it still holds it.
        _ = try await fixture.client.describe()

        let registry = HolderRegistry(
            owner: fixture.owner,
            environment: HolderProcessFixture.environment(home: fixture.home),
            listTerminals: { [] },
            busyRetryBudget: .zero)
        defer { releaseInBackground(registry) }

        await #expect(
            throws: HolderClient.Error.rejected(version: HolderProtocolVersion.busySentinel)
        ) {
            try await registry.adopt(terminal: holderTerminal(id: fixture.sessionID))
        }
        let stored = await registry.reader(for: fixture.sessionID)
        #expect(stored == nil)
        let loops = await registry.drainLoopsStarted
        #expect(loops == 0)
    }

    // MARK: - The startup sweep

    /// `adoptAll` walks holder rows and nothing else.
    ///
    /// Both branches, because the exemption must not become an excuse: a tmux
    /// row is never probed at all — it has no rendezvous to probe — while a
    /// holder row whose holder has gone is recorded as having ended with an
    /// **unknown** status. Never a fabricated code: downstream could not tell
    /// one of those from a status the job really returned.
    @Test func adoptAllSkipsTmuxRows() async throws {
        let home = HolderProcessFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let tmuxRow = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@7", tmuxPaneID: "%7", transport: .tmux)
        let holderRow = holderTerminal(id: UUID())
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: HolderProcessFixture.environment(home: home),
            listTerminals: { [tmuxRow, holderRow] })
        defer { releaseInBackground(registry) }

        await registry.adoptAll()

        let tmuxReader = await registry.reader(for: tmuxRow.id)
        #expect(tmuxReader == nil)
        let tmuxStatus = await registry.lastKnownStatus(for: tmuxRow.id)
        #expect(tmuxStatus == nil, "a tmux row was probed as though it had a holder")

        let holderStatus = await registry.lastKnownStatus(for: holderRow.id)
        #expect(
            holderStatus == .exitedStatusUnknown,
            "an unreachable holder was reported as \(String(describing: holderStatus))")
        let loops = await registry.drainLoopsStarted
        #expect(loops == 0)
    }

    // MARK: - A job that ended while nobody was listening

    /// The status of a job that finished during the outage reaches the daemon.
    ///
    /// This is the case the holder's exit-report window exists for: it reaps the
    /// child, finds no client, keeps its rendezvous bound, and waits to be
    /// asked. A restarted daemon asks by adopting, and the description riding
    /// the hand-over carries the status — so the job's exit is *reported* rather
    /// than lost with the process that observed it.
    ///
    /// The job sleeps first so the exit lands after the spawner's own connection
    /// is gone. With a client still attached the holder pushes the status at it
    /// and winds down, which is a different path — and one no restarted daemon
    /// can take, because its predecessor's connection died with it.
    @Test func reportsAJobThatFinishedDuringTheOutage() async throws {
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
        let status = await registry.lastKnownStatus(for: fixture.sessionID)
        #expect(
            status == .exited(code: 7),
            "the exit status was lost: \(String(describing: status))")
    }

    // MARK: - Installation identity

    /// The owner token identifies the installation, and must survive a restart.
    ///
    /// This is the property the whole comparison rests on: a token minted per
    /// process would make every holder a daemon spawned unrecognisable to its
    /// own successor, and `adoptAll` would walk away from every live session it
    /// was written to rescue — while still passing a test that only checked two
    /// different installations disagree.
    @Test func theInstallationOwnerTokenSurvivesARestart() throws {
        let home = HolderProcessFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let elsewhere = HolderProcessFixture.scratchHome()
        defer { try? FileManager.default.removeItem(atPath: elsewhere) }

        let minted = HolderRegistry.installationOwner(
            environment: HolderProcessFixture.environment(home: home))
        #expect(!minted.rawValue.isEmpty)

        let reread = HolderRegistry.installationOwner(
            environment: HolderProcessFixture.environment(home: home))
        #expect(
            reread == minted,
            "the token was re-minted, so a restarted daemon would disown its own holders")

        let other = HolderRegistry.installationOwner(
            environment: HolderProcessFixture.environment(home: elsewhere))
        #expect(other != minted, "two installations share one token")
    }

    // MARK: - Support

    /// A holder-transport row. `tmuxWindowID`/`tmuxPaneID` are empty because
    /// those columns are NOT NULL from the v1 schema and a holder row has no
    /// tmux coordinate to put in them — it is discriminated by `transport`
    /// alone, never by those values.
    private func holderTerminal(id: UUID) -> Terminal {
        Terminal(
            id: id, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder)
    }

    /// A registry whose rendezvous paths come from an explicit environment, so
    /// nothing here can reach the developer's real `~/tbd` even for an instant.
    /// `listTerminals` is unused by `adopt` and returns nothing.
    private func makeRegistry(owner: HolderOwnerToken, home: String) -> HolderRegistry {
        HolderRegistry(
            owner: owner,
            environment: HolderProcessFixture.environment(home: home),
            listTerminals: { [] })
    }
}

/// Releases a registry's readers from a `defer`, which cannot `await`.
///
/// Every test needs it on every exit path: a reader left running leaks its drain
/// thread and a pty descriptor for the rest of the suite, because after end of
/// file the thread parks on its wake pipe rather than exiting. Releasing is
/// idempotent.
private func releaseInBackground(_ registry: HolderRegistry) {
    Task.detached { await registry.releaseAll() }
}
