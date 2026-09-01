import Darwin
import Foundation
import GRDB
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

    // MARK: - A release that races the adoption it is releasing

    /// A `release` that runs while an adoption is between its attach and its
    /// publish must not be undone by that adoption.
    ///
    /// The registry is an actor, and an actor's methods are **not** atomic
    /// across `await`. `release` clears the slot and then suspends inside
    /// `reader.stop()`; the adoption it just cancelled can resume in that window
    /// and — before this fix — wrote its result into the slot regardless. The
    /// registry was then holding a reader whose drain thread had already exited
    /// and whose pty descriptor was closed: a session with a screen that never
    /// updates again and a job that can no longer finish exiting, because
    /// nothing is draining its terminal.
    ///
    /// The interleaving is **forced, not waited for.** `ReentryBarrier` parks
    /// the adoption at exactly the suspension point that matters, so the
    /// ordering is a property of the test rather than of the scheduler.
    @Test func aReleaseIsNotUndoneByTheAdoptionItRaced() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }
        let barrier = ReentryBarrier()
        await registry.setPublishBarrier(barrier.hook())
        let terminal = holderTerminal(id: fixture.sessionID)

        let racing = Task { try await registry.adopt(terminal: terminal) }
        let parked = await pollUntil("the adoption to reach its publish step") {
            await barrier.hasParked
        }
        #expect(parked)

        // Runs to completion — slot cleared, reader stopped — while the
        // adoption sits parked between its attach and its publish.
        await registry.release(terminalID: fixture.sessionID)
        await barrier.release()

        await #expect(throws: HolderRegistry.Error.superseded(terminalID: fixture.sessionID)) {
            try await racing.value
        }
        let stored = await registry.reader(for: fixture.sessionID)
        #expect(stored == nil, "the registry kept a reader the release had already stopped")
        let loopsAfterTheRace = await registry.drainLoopsStarted
        #expect(loopsAfterTheRace == 0, "a superseded adoption was published as a live reader")

        // And the session is still adoptable, which is the whole point: the
        // discarded reader neither survived in the slot nor left a drain loop
        // behind to take bytes from this one. Asserting on output the job
        // produced *after* this adoption is what distinguishes a reader that is
        // really draining from one that merely exists.
        let reader = try await registry.adopt(terminal: terminal)
        try await reader.write(Data("AFTER\n".utf8))
        let sawAfter = await pollUntil("output the job produced after the re-adoption") {
            await reader.renderScreen().contains("GOT:AFTER")
        }
        let screen = await reader.renderScreen()
        #expect(sawAfter, "screen was: \(screen.debugDescription)")
        let loops = await registry.drainLoopsStarted
        #expect(loops == 1, "the registry started \(loops) drain loops on one pty")
    }

    /// The other half of the same race: a *later* adoption takes the slot while
    /// an earlier one is parked, and the earlier one must not clobber it.
    ///
    /// This is the escalation, and it is worse than the case above. Before the
    /// fix the parked adoption overwrote the slot with its own stopped reader,
    /// which both resurrected a dead reader **and** orphaned the live one — a
    /// reader nothing owns any more, still draining the pty master, still owed a
    /// `stop()` nobody will ever call. Two drain loops on one master is silent
    /// byte theft: each `read` takes bytes the other will never see.
    @Test func aLaterAdoptionIsNotClobberedByTheOneItSuperseded() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }
        let barrier = ReentryBarrier()
        await registry.setPublishBarrier(barrier.hook())
        let terminal = holderTerminal(id: fixture.sessionID)

        let superseded = Task { try await registry.adopt(terminal: terminal) }
        let parked = await pollUntil("the first adoption to reach its publish step") {
            await barrier.hasParked
        }
        #expect(parked)

        // The slot is freed and then claimed by a second adoption, which runs
        // to completion — the barrier holds only the first arrival.
        await registry.release(terminalID: fixture.sessionID)
        let live = try await registry.adopt(terminal: terminal)
        await barrier.release()

        await #expect(throws: HolderRegistry.Error.superseded(terminalID: fixture.sessionID)) {
            try await superseded.value
        }
        let stored = await registry.reader(for: fixture.sessionID)
        #expect(
            stored === live,
            "the superseded adoption overwrote the live one, orphaning its drain loop")
        let loops = await registry.drainLoopsStarted
        #expect(loops == 1, "the registry published \(loops) readers for one pty")

        // Still the session's only reader, and still genuinely draining.
        try await live.write(Data("AFTER\n".utf8))
        let sawAfter = await pollUntil("output the surviving reader drained after the race") {
            await live.renderScreen().contains("GOT:AFTER")
        }
        let screen = await live.renderScreen()
        #expect(sawAfter, "screen was: \(screen.debugDescription)")
    }

    /// The third member of the family, and the one a targeted guard would have
    /// missed: a **fresh** adoption arriving while a published reader is being
    /// stopped.
    ///
    /// `release` spends nearly all of its time suspended inside `reader.stop()`,
    /// waiting for the drain thread to acknowledge its wake and close the pty
    /// dup. If the slot is vacated before that suspension, an `adopt` landing in
    /// the window reads "nobody is on this master", opens its own `handOverPTY`
    /// round trip, and takes a second `dup` of a pty a live drain loop is still
    /// reading. That is the byte theft this registry exists to prevent — each
    /// `read` takes bytes the other will never see, and nothing reports it.
    ///
    /// **The interleaving is forced, not waited for**, in both directions:
    ///
    ///   - `ReentryBarrier` parks the release at exactly the stop step, so the
    ///     window is open for as long as the test wants it.
    ///   - `adoptionCallsEntered` pins the instant to assert at. An actor runs
    ///     one job at a time, so observing that counter go to two proves the
    ///     racing `adopt` has already run its entire synchronous prefix — up to
    ///     and including whichever slot decision it made. Whether it opened a
    ///     round trip is therefore decided, not pending, and reading
    ///     `attachRoundTripsStarted` next is reading a settled fact rather than
    ///     racing one.
    @Test func aFreshAdoptionWaitsForAReaderThatIsStillDraining() async throws {
        let fixture = try await HolderProcessFixture.start(
            command: "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = makeRegistry(owner: fixture.owner, home: fixture.home)
        defer { releaseInBackground(registry) }
        let terminal = holderTerminal(id: fixture.sessionID)

        let first = try await registry.adopt(terminal: terminal)
        let adopted = await registry.drainLoopsStarted
        #expect(adopted == 1)

        let barrier = ReentryBarrier()
        await registry.setReleaseBarrier(barrier.hook())
        // Hoisted: capturing `fixture` itself in a `Task` would send a
        // non-Sendable class across an isolation boundary.
        let sessionID = fixture.sessionID
        let releasing = Task { await registry.release(terminalID: sessionID) }
        let parked = await pollUntil("the release to reach its stop step") {
            await barrier.hasParked
        }
        #expect(parked)
        let stillDraining = await first.isDraining
        #expect(
            stillDraining,
            "the released reader had already stopped, so the window this test forces never existed")

        // The whole point: a fresh adoption, arriving with the outgoing reader
        // still on the pty.
        let racing = Task { try await registry.adopt(terminal: terminal) }
        let entered = await pollUntil("the racing adoption to consult the slot") {
            await registry.adoptionCallsEntered == 2
        }
        #expect(entered)

        let roundTrips = await registry.attachRoundTripsStarted
        #expect(
            roundTrips == 1,
            """
            a fresh adoption opened a second handOverPTY round trip against a reader that was \
            still draining: \(roundTrips) round trips for one session
            """)
        let overlapped = await first.isDraining
        #expect(overlapped, "the release finished on its own, so nothing was raced")

        await barrier.release()
        let fresh = try await racing.value
        await releasing.value

        let peak = await registry.peakLiveDrainLoops
        #expect(peak == 1, "\(peak) drain loops were live at once on one pty master")
        let stopped = await first.isDraining
        #expect(!stopped, "the released reader was still draining after its release returned")
        let stored = await registry.reader(for: fixture.sessionID)
        #expect(stored === fresh, "the registry did not keep the reader that waited its turn")
        let loops = await registry.drainLoopsStarted
        #expect(loops == 2, "the re-adoption did not start a drain loop of its own")

        // And it is genuinely draining, not merely published: only a live loop
        // can show output the job produced after the re-adoption.
        try await fresh.write(Data("AFTER\n".utf8))
        let sawAfter = await pollUntil("output the job produced after the re-adoption") {
            await fresh.renderScreen().contains("GOT:AFTER")
        }
        let screen = await fresh.renderScreen()
        #expect(sawAfter, "screen was: \(screen.debugDescription)")
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
    ///
    /// A second `TBDDatabase` is a second installation, which is what makes the
    /// last assertion mean anything: the token has to be per-`TBD_HOME`, not a
    /// constant every checkout on the machine would share.
    @Test func theInstallationOwnerTokenSurvivesARestart() async throws {
        let database = try TBDDatabase(inMemory: true)
        let elsewhere = try TBDDatabase(inMemory: true)

        let minted = await HolderRegistry.installationOwner(config: database.config)
        #expect(!minted.rawValue.isEmpty)
        #expect(!minted.rawValue.hasPrefix("tbd-home:"), "the mint fell back instead of persisting")

        // The restart: a second daemon, reading the row the first one wrote.
        let reread = await HolderRegistry.installationOwner(config: database.config)
        #expect(
            reread == minted,
            "the token was re-minted, so a restarted daemon would disown its own holders")

        let other = await HolderRegistry.installationOwner(config: elsewhere.config)
        #expect(other != minted, "two installations share one token")
    }

    /// The column is genuinely NULL until somebody mints, and the mint is what
    /// fills it.
    ///
    /// If the migration ever grows a `DEFAULT` clause this goes red, which is
    /// its only job — and the failure it prevents is not a lost preference but a
    /// shared identity: every checkout on the machine would carry the same
    /// literal token and claim every other checkout's holder sessions.
    @Test func theOwnerTokenColumnIsNullUntilItIsMinted() async throws {
        let database = try TBDDatabase(inMemory: true)

        let before = try await database.config.get().holderOwnerToken
        #expect(
            before == nil,
            """
            config.holder_owner_token must be NULL until a daemon mints one — read back \
            \(String(describing: before)). A non-nil value here means \
            20260831200151_config_holder_owner_token grew a DEFAULT clause; remove it.
            """)

        let minted = await HolderRegistry.installationOwner(config: database.config)
        let after = try await database.config.get().holderOwnerToken
        #expect(after == minted.rawValue, "the minted token did not reach the config row")
    }

    /// Two daemons starting at once mint one token between them.
    ///
    /// This is the property the file-backed store got from `O_EXCL` and the
    /// `config` row gets from a conditional UPDATE: whoever loses the race reads
    /// back the winner's value instead of keeping its own. Two tokens here would
    /// mean two daemons that each disown the other's holders — and, because a
    /// foreign holder is deliberately left strictly alone, sessions neither of
    /// them ever drains.
    @Test func concurrentMintsAgreeOnOneToken() async throws {
        let database = try TBDDatabase(inMemory: true)

        async let first = HolderRegistry.installationOwner(config: database.config)
        async let second = HolderRegistry.installationOwner(config: database.config)
        async let third = HolderRegistry.installationOwner(config: database.config)
        let tokens = await [first, second, third].map(\.rawValue)

        #expect(
            Set(tokens).count == 1,
            "concurrent mints produced \(Set(tokens).count) tokens: \(tokens)")
        let stored = try await database.config.get().holderOwnerToken
        #expect(stored == tokens[0], "the row holds a token nobody was handed")
    }

    /// A daemon whose database cannot be written still starts, and says what
    /// that costs.
    ///
    /// The fallback is path-derived rather than random on purpose: it is stable
    /// for as long as the outage lasts, where an ephemeral token would disown
    /// this daemon's own holders on its very next boot. What it still costs is
    /// real, and is the reason the log line exists — holders stamped with it
    /// read as foreign the moment a real token is minted.
    @Test func anUnwritableStoreFallsBackToAStableToken() async throws {
        // A database with no `config` table at all: every write against it
        // throws, which is the shape of an unwritable store.
        let store = ConfigStore(writer: try DatabaseQueue())
        let home = HolderProcessFixture.scratchHome()
        let environment = HolderProcessFixture.environment(home: home)

        let first = await HolderRegistry.installationOwner(config: store, environment: environment)
        #expect(!first.rawValue.isEmpty, "a daemon that cannot persist a token must still start")
        let second = await HolderRegistry.installationOwner(config: store, environment: environment)
        #expect(first == second, "the fallback token changed between two calls in one outage")
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

/// Holds the **first** caller that reaches the seam it is installed on, and
/// waves through every one after it.
///
/// It exists so these races are properties of the tests rather than of the
/// scheduler. Each of them is a continuation-ordering accident inside an actor:
/// reproducing one by timing would pass by luck, stop reproducing the day the
/// scheduler changed, and prove nothing on the day it went green. Installed with
/// `setPublishBarrier` it parks an adoption between its attach and its publish;
/// installed with `setReleaseBarrier` it parks a release with the outgoing
/// reader still draining. Either way the interleaving is forced.
///
/// Nothing here sleeps to *create* the interleaving. The polling is only how
/// each side observes a state the other has definitely reached, and it is
/// bounded through `pollUntil`, so a barrier nobody releases fails its test with
/// a named diagnostic instead of hanging the suite.
private actor ReentryBarrier {
    private var parked = false
    private var released = false

    /// Whether a caller is being held. The test waits for this before doing
    /// whatever must interleave.
    var hasParked: Bool { parked }

    /// Lets the parked caller finish.
    func release() { released = true }

    private var isReleased: Bool { released }

    /// True for the first caller only; every later one is waved through.
    private func claimPark() -> Bool {
        guard !parked else { return false }
        parked = true
        return true
    }

    nonisolated func hook() -> @Sendable () async -> Void {
        { [self] in
            guard await claimPark() else { return }
            await pollUntil("the test to release the parked adoption") { await self.isReleased }
        }
    }
}
