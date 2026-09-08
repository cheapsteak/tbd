import Clocks
import Darwin
import Foundation
import TestSupport
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// `ModelProxySupervisor` — adoption, spawning, retirement and routes — with
/// every collaborator it has replaced by something a test can steer.
///
/// Four seams, and each exists because the real thing cannot be *made* to
/// answer the way a branch needs:
///
///   - **the spawner** is a `StubSpawner` that records the ports it was asked
///     for and answers from a queue, including the `ModelProxySpawner.Error`s
///     a real spawn only produces by racing something;
///   - **the proxy** is a `FakeProxyProcess` — a real HTTP listener on a real
///     loopback port — so `ModelProxyClient` is exercised over a socket rather
///     than mocked away. A status document that decodes and a retire that
///     answers are the two facts adoption turns on;
///   - **the process table** is a `StubIdentity` that can admit a pid, deny
///     one, or forget one between polls, which is what a proxy dying looks
///     like from the supervisor's side;
///   - **the clock** is a `TestClock`, so the watch interval and the respawn
///     backoff are advanced rather than waited out.
///
/// Every path is under `TBD_TEST_SCRATCH_ROOT` via `fencedScratchRoot`, and
/// every `TBDConstants` lookup takes an explicit `["TBD_HOME": …]` — no
/// `setenv`, so nothing here needs `TBDHomeSerialized` and nothing can reach
/// the developer's real `~/tbd`.
@Suite("Model proxy supervisor", .clockDriven)
struct ModelProxySupervisorTests {

    // MARK: - Startup: adopt

    /// The first branch of the startup algorithm (spec, "Supervisor"): a
    /// persisted port whose proxy answers `status` with a pid and start time
    /// the process table confirms is **adopted**, not replaced. Nothing is
    /// spawned, and the port is not re-minted.
    @Test("a proxy already holding the persisted port is adopted, not replaced")
    func adoptsMatchingProxyAtStartup() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 4242)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 4242, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        let current = await supervisor.current
        #expect(current?.pid == 4242)
        #expect(current?.port == proxy.port)
        #expect(current?.adopted == true)
        #expect(current?.version == fixture.ownVersion)
        #expect(await fixture.spawner.calls().isEmpty, "an adoptable proxy must not be replaced")
        #expect(try await fixture.db.config.get().modelProxyPort == proxy.port)
    }

    /// Adoption is an **identity** check, not a liveness one. A process
    /// answering `/tbd/status` on the persisted port whose pid and start time
    /// the process table does not confirm is a stranger — a reused pid, or a
    /// fabricated answer — and the supervisor spawns its own rather than
    /// adopting it.
    @Test("a status answer the process table does not confirm is not adopted")
    func doesNotAdoptOnAnIdentityMismatch() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 4242)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        // Deliberately nothing admitted: the process table denies pid 4242.

        await fixture.spawner.answer(.success(pid: 77, port: proxy.port))
        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        let current = await supervisor.current
        #expect(current?.adopted == false)
        #expect(current?.pid == 77)
        #expect(await fixture.spawner.calls() == [proxy.port])
    }

    // MARK: - Startup: spawn

    /// Nothing persisted, nothing running: spawn on port 0, and persist what
    /// the kernel handed back through `ensureModelProxyPort` (spec, "Port").
    @Test("with no persisted port the proxy is spawned on zero and the port persisted")
    func spawnsWhenNoneAndPersistsPort() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        await fixture.spawner.answer(.success(pid: 900, port: SupervisorFixture.deadPort))
        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        #expect(await fixture.spawner.calls() == [0], "a first spawn asks the kernel for a port")
        let current = await supervisor.current
        #expect(current?.pid == 900)
        #expect(current?.port == SupervisorFixture.deadPort)
        #expect(current?.adopted == false)
        #expect(try await fixture.db.config.get().modelProxyPort == SupervisorFixture.deadPort)
    }

    /// The re-mint path (spec, "Port"): the persisted port is taken, and the
    /// thing holding it is not a TBD proxy. The supervisor must spawn on zero
    /// and **overwrite** the stored port — `ensureModelProxyPort` is
    /// conditional and would leave the stale value in place.
    @Test("a persisted port held by a stranger is re-minted")
    func remintsPortWhenHeldByStranger() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        try await fixture.db.config.setModelProxyPort(SupervisorFixture.deadPort)
        await fixture.spawner.answer(.failure(.bindFailed(port: SupervisorFixture.deadPort)))
        await fixture.spawner.answer(.success(pid: 901, port: SupervisorFixture.otherDeadPort))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        #expect(await fixture.spawner.calls() == [SupervisorFixture.deadPort, 0])
        #expect(await supervisor.current?.port == SupervisorFixture.otherDeadPort)
        #expect(
            try await fixture.db.config.get().modelProxyPort == SupervisorFixture.otherDeadPort,
            "the re-mint must overwrite the stale port, not leave it")
    }

    /// `.lockHeld` says a live proxy owns this rendezvous. The supervisor
    /// probes rather than replaces — and it must never unlink the lock.
    @Test("a held lock sends the supervisor to probe the port, and it adopts what answers")
    func lockHeldProbesAndAdopts() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 6060)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        // The startup probe would adopt on its own, so the identity is
        // withheld for exactly one check: this case is about the *spawn*
        // failing with `.lockHeld` and the supervisor recovering from there.
        fixture.identity.denyOnce()
        fixture.identity.admit(pid: 6060, startTime: proxy.processStartTime)
        await fixture.spawner.answer(.failure(.lockHeld))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        #expect(await fixture.spawner.calls() == [proxy.port])
        let current = await supervisor.current
        #expect(current?.adopted == true)
        #expect(current?.pid == 6060)
        #expect(
            FileManager.default.fileExists(atPath: fixture.paths.lockPath) == false,
            "nothing in this test creates a lock file; the supervisor must not either")
    }

    /// `homeUnusable` is a broken filesystem, not a transient. Respawning on a
    /// backoff would spin forever, so the supervisor logs and stays down —
    /// even after the watch interval elapses.
    @Test("a home that cannot be used is never respawned")
    func doesNotRespawnOnHomeUnusable() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        await fixture.spawner.answer(.failure(.homeUnusable))
        await fixture.spawner.answer(.success(pid: 5, port: SupervisorFixture.deadPort))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        #expect(await supervisor.current == nil)

        // Several watch intervals. A supervisor that treated this as transient
        // would take the second stubbed answer.
        for _ in 0..<3 {
            await fixture.clock.advanceWhenSuspended(by: fixture.watchInterval)
        }
        await supervisor.stop()

        #expect(
            await fixture.spawner.calls() == [0],
            "a configuration defect must not be retried by the watch")
        #expect(await supervisor.current == nil)
    }

    /// A command line this daemon composed wrong — the proxy's exit 2 — is the
    /// same kind of defect and gets the same answer.
    @Test("a proxy that refuses its own command line is never respawned")
    func doesNotRespawnOnBadArguments() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        await fixture.spawner.answer(.failure(.childExited(status: 2)))
        await fixture.spawner.answer(.success(pid: 6, port: SupervisorFixture.deadPort))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        for _ in 0..<2 {
            await fixture.clock.advanceWhenSuspended(by: fixture.watchInterval)
        }
        await supervisor.stop()

        #expect(await fixture.spawner.calls() == [0])
        #expect(await supervisor.current == nil)
    }

    /// A crash, by contrast, *is* transient: the watch reconciles from nothing
    /// on its next tick. This is the discriminating half of the two tests
    /// above — without it, a supervisor that gave up on every failed spawn
    /// would pass them both.
    @Test("a spawn that failed for a transient reason is retried by the watch")
    func retriesATransientSpawnFailure() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        await fixture.spawner.answer(.failure(.childExited(status: -9)))
        await fixture.spawner.answer(.success(pid: 7, port: SupervisorFixture.deadPort))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        #expect(await supervisor.current == nil)

        let landed = await fixture.clock.advanceUntil(
            "the watch to retry the spawn", by: fixture.watchInterval,
            { await supervisor.current?.pid == 7 })
        await supervisor.stop()

        #expect(landed)
    }

    /// No binary beside the daemon means no proxy, and that is a supported
    /// state rather than an error: `start()` never throws, `canSpawn` is
    /// false, and `current` stays nil so capabilities report unsupported.
    @Test("a supervisor with no spawner starts, stays empty and never throws")
    func startNeverThrowsWithoutSpawner() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let supervisor = fixture.supervisorWithoutSpawner()
        #expect(await supervisor.canSpawn == false)
        await supervisor.start()
        await supervisor.stop()
        #expect(await supervisor.current == nil)
    }

    // MARK: - Version replacement

    /// A proxy whose reported version differs from the binary this daemon
    /// would spawn is retired and replaced (spec, "Supervisor") — *different*,
    /// not older, because `tbd update` keeps a rollback route.
    ///
    /// The sequencing is the claim: the retire is seen, and the successor is
    /// spawned on the **same port**, without waiting for the predecessor's
    /// exit. The fake proxy here never exits, and the test still passes.
    @Test("a proxy of a different version is retired and replaced on the same port")
    func retiresOnVersionMismatch() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: "9999-1", pid: 7070)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 7070, startTime: proxy.processStartTime)
        await fixture.spawner.answer(.success(pid: 7071, port: proxy.port))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        #expect(
            proxy.requests().contains { $0.method == "POST" && $0.path == "/tbd/retire" },
            "the mismatched proxy must be asked to retire")
        #expect(await fixture.spawner.calls() == [proxy.port], "the successor takes the same port")
        let current = await supervisor.current
        #expect(current?.pid == 7071)
        #expect(current?.adopted == false)
        #expect(current?.version == fixture.ownVersion)
    }

    /// A proxy whose version matches is left alone, which is the half the
    /// previous test cannot show on its own: a supervisor that retired *every*
    /// proxy it adopted would pass that one.
    @Test("a proxy of the same version is not retired")
    func doesNotRetireOnAVersionMatch() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 7080)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 7080, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        #expect(proxy.requests().allSatisfy { $0.path != "/tbd/retire" })
        #expect(await fixture.spawner.calls().isEmpty)
    }

    // MARK: - Watch

    /// The watch's whole job: a proxy that died is noticed and replaced.
    ///
    /// Death arrives the way the daemon really learns it — `reapIfExited`
    /// collecting the child it spawned — and the first respawn attempt fails
    /// transiently, so the test must advance through the first backoff step for
    /// the second attempt to land. That is what makes the backoff part of the
    /// assertion rather than an unexercised parameter.
    @Test("a proxy that exits is reaped and respawned after the backoff")
    func respawnsAfterDeath() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        await fixture.spawner.answer(.success(pid: 800, port: SupervisorFixture.deadPort))
        let supervisor = fixture.supervisor()
        await supervisor.start()
        #expect(await supervisor.current?.pid == 800)

        // The child exits; the first respawn attempt fails transiently and the
        // second succeeds.
        await fixture.spawner.reap(pid: 800, status: 0)
        await fixture.spawner.answer(.failure(.launchFailed(errno: EAGAIN)))
        await fixture.spawner.answer(.success(pid: 801, port: SupervisorFixture.deadPort))

        let landed = await fixture.clock.advanceUntil(
            "the proxy to be respawned", by: fixture.watchInterval,
            { await supervisor.current?.pid == 801 })
        await supervisor.stop()

        #expect(landed)
        #expect(
            await fixture.spawner.calls()
                == [0, SupervisorFixture.deadPort, SupervisorFixture.deadPort],
            "the successor is spawned on the port the dead one held")
    }

    /// A proxy that is alive but slow to answer must not be replaced. This is
    /// the discriminating half of `respawnsAfterDeath`: the status probe fails
    /// in both, and only the process table tells them apart.
    @Test("a live proxy that misses a status poll is kept, not replaced")
    func doesNotRespawnAProxyThatIsStillAlive() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        await fixture.spawner.answer(.success(pid: 810, port: SupervisorFixture.deadPort))
        let supervisor = fixture.supervisor()  // no listener: every status poll fails
        await supervisor.start()
        #expect(await supervisor.current?.pid == 810)

        // `reapIfExited` reports nothing, so the child is still running.
        for _ in 0..<3 {
            await fixture.clock.advanceWhenSuspended(by: fixture.watchInterval)
        }
        await supervisor.stop()

        #expect(await supervisor.current?.pid == 810)
        #expect(await fixture.spawner.calls() == [0], "an unanswered poll is not a death")
    }

    /// An **adopted** proxy is not this daemon's child, so `waitpid` can never
    /// collect it: its death is read off the process table instead. The
    /// supervisor spawns a replacement on the port it held.
    @Test("an adopted proxy that leaves the process table is replaced")
    func replacesAnAdoptedProxyThatDied() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 9090)
        // Stopped again below, on purpose; the defer is for the paths where an
        // expectation fails before that and the listener would otherwise leak.
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 9090, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.start()
        #expect(await supervisor.current?.adopted == true)

        let adoptedPort = proxy.port
        proxy.stop()
        fixture.identity.forget(pid: 9090)
        await fixture.spawner.answer(.success(pid: 9091, port: adoptedPort))

        let landed = await fixture.clock.advanceUntil(
            "the dead adopted proxy to be replaced", by: fixture.watchInterval,
            { await supervisor.current?.pid == 9091 })
        await supervisor.stop()

        #expect(landed)
        #expect(await fixture.spawner.calls() == [adoptedPort])
    }

    /// A **spawned** proxy that dies in the one way `waitpid` cannot report.
    ///
    /// `reapIfExited` answers nil for two different facts — "still running"
    /// and "not this process's to collect", which is what `waitpid` returns
    /// `ECHILD` for once an exit has gone somewhere else. A supervisor that
    /// consulted only `waitpid` for its own children would read the second as
    /// the first and keep a dead proxy forever, with `current` naming a port
    /// nothing is listening on. The process table is what tells them apart,
    /// for a child exactly as for an adopted proxy.
    @Test("a spawned proxy that leaves the process table is replaced, waitpid or not")
    func replacesASpawnedProxyWaitpidCannotCollect() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 8080)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        // Denied once so the startup probe does not adopt: this case is about
        // a proxy this daemon *spawned*.
        fixture.identity.denyOnce()
        fixture.identity.admit(pid: 8080, startTime: proxy.processStartTime)
        await fixture.spawner.answer(.success(pid: 8080, port: proxy.port))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        #expect(await supervisor.current?.adopted == false)

        // One quiet poll, which is where a spawned proxy gets the identity
        // anchor the death check reads: the start time it answered with.
        await fixture.clock.advanceWhenSuspended(by: fixture.watchInterval)
        #expect(await supervisor.current?.pid == 8080)

        let heldPort = proxy.port
        proxy.stop()
        fixture.identity.forget(pid: 8080)
        // Deliberately no `spawner.reap(pid: 8080, …)`: the exit is one this
        // process cannot collect, so `reapIfExited` keeps answering nothing.
        await fixture.spawner.answer(.success(pid: 8081, port: heldPort))

        let landed = await fixture.clock.advanceUntil(
            "the lost child to be replaced", by: fixture.watchInterval,
            { await supervisor.current?.pid == 8081 })
        await supervisor.stop()

        #expect(landed, "a child waitpid cannot collect must not collapse into keep-forever")
        #expect(await fixture.spawner.calls() == [heldPort, heldPort])
    }

    /// The zombie rule, and the adoption rule that falls out of it.
    ///
    /// A proxy this process spawned and then dropped — here by replacing it
    /// for its version — is still its child until somebody calls `waitpid`.
    /// Two things must happen. It has to be *collected*, and `stop()` has to
    /// be one of the places that tries, because `stop()` takes the watch away
    /// and B2.3's runtime toggle is a `stop()`/`start()` pair. And it must
    /// never be adopted back: `kill(pid, 0)` succeeds on a zombie and `ps`
    /// still prints its command line, so the identity check confirms it and
    /// `current` would end up naming a dead port that no later branch revises.
    ///
    /// Both abandonments in the run are covered, because they are abandoned by
    /// different code: the first child is dropped by the version replacement,
    /// the second by the spawn the restart performs when adoption refuses the
    /// corpse. A supervisor that queued only on the first path leaks the
    /// second, and it leaks it on exactly the toggle path B2.3 will use.
    @Test("a proxy this daemon replaced is collected, and a restart never adopts it back")
    func replacedProxyIsReapedAndNeverAdoptedBack() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        // The fake answers for pid 7075 throughout — a listener that outlives
        // the process it claims to be is exactly what a corpse looks like from
        // the supervisor's side, and it is what makes the wrong adoption
        // possible at all.
        let proxy = try FakeProxyProcess(version: "9999-1", pid: 7075)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.denyOnce()
        fixture.identity.admit(pid: 7075, startTime: proxy.processStartTime)
        await fixture.spawner.answer(.success(pid: 7075, port: proxy.port))
        await fixture.spawner.answer(.success(pid: 7076, port: proxy.port))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        #expect(await supervisor.current?.pid == 7075)
        #expect(await supervisor.current?.adopted == false, "a child of ours is never adopted")

        // The first poll reads the version the proxy actually reports, which
        // differs, so this daemon retires and replaces its own child.
        let replaced = await fixture.clock.advanceUntil(
            "the mismatched child to be replaced", by: fixture.watchInterval,
            { await supervisor.current?.pid == 7076 })
        #expect(replaced)

        // What the runtime toggle does. Nothing is advanced across it: the
        // whole question is what `start()` decides, not what a watch tick
        // later corrects.
        await supervisor.stop()
        await fixture.spawner.answer(.success(pid: 7077, port: proxy.port))
        await supervisor.start()

        let current = await supervisor.current
        #expect(current?.pid == 7077, "the dropped child must not be adopted back")
        #expect(current?.adopted == false)
        #expect(
            await fixture.spawner.calls() == [proxy.port, proxy.port, proxy.port],
            "each replacement takes the port the last one held")

        // And both are collected rather than left zombies. 7075 was dropped by
        // the version replacement; 7076 was dropped by the spawn on the
        // `start()` above, which is the abandonment a supervisor that only
        // queued on the retire path would miss entirely — the pid stays in
        // `spawnedPids`, never enters `pendingReap`, and nothing ever waits for
        // it. Both exits land after the watch is gone, so `stop()` is the only
        // thing left that can reap.
        await fixture.spawner.reap(pid: 7075, status: 0)
        await fixture.spawner.reap(pid: 7076, status: 0)
        await supervisor.stop()
        #expect(
            await fixture.spawner.collected().sorted() == [7075, 7076],
            "every child this daemon dropped is waited for, not leaked")
    }

    /// A port that starts answering for a different process is a **new**
    /// adoption, not a rename of the old one.
    ///
    /// Two facts in `State` are derived from the pid and from nothing else:
    /// `adopted`, which decides whether a death is read off `waitpid` or off
    /// the process table, and the corpse refusal, which is what keeps a child
    /// this daemon dropped from being taken back. Carrying either across to a
    /// pid it was never derived for is wrong in both directions, so the move
    /// goes through the adoption path. Here the port passes from a proxy this
    /// daemon spawned to one it did not: the successor has to come out
    /// adopted, and the predecessor has to be queued for collection on the way
    /// past rather than dropped on the floor.
    @Test("a port that begins answering for another process is adopted afresh")
    func aMovedPidIsReadoptedRatherThanRenamed() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 9100)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        // Denied once so startup spawns rather than adopts: this case needs the
        // first proxy to be *ours*, which is the half a rename gets wrong.
        fixture.identity.denyOnce()
        fixture.identity.admit(pid: 9100, startTime: proxy.processStartTime)
        fixture.identity.admit(pid: 9101, startTime: proxy.processStartTime)
        await fixture.spawner.answer(.success(pid: 9100, port: proxy.port))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        #expect(await supervisor.current?.pid == 9100)
        #expect(await supervisor.current?.adopted == false, "a child of ours is never adopted")

        // The port changes hands: another daemon replaced the proxy, or ours
        // went and something else bound the port it held.
        proxy.becomePid(9101)
        let moved = await fixture.clock.advanceUntil(
            "the port to be re-adopted for its new process", by: fixture.watchInterval,
            { await supervisor.current?.pid == 9101 })

        #expect(moved, "a status answer naming another pid must not be ignored")
        #expect(
            await supervisor.current?.adopted == true,
            "a pid this daemon never spawned is not its child, whatever the last one was")
        #expect(
            await fixture.spawner.calls() == [proxy.port],
            "a port that is still serving a proxy is adopted, not spawned past")

        // And the child the move abandoned is collected, not left a zombie.
        await fixture.spawner.reap(pid: 9100, status: 0)
        await supervisor.stop()
        #expect(
            await fixture.spawner.collected() == [9100],
            "the predecessor a move abandons is still this daemon's child")
    }

    /// One control client per port, for the life of the supervisor.
    ///
    /// The default factory builds a `ModelProxyClient` around a fresh
    /// ephemeral `URLSession`, and nothing invalidates one. A factory called
    /// per watch tick is a session per watch tick, for as long as the daemon
    /// runs — so the count is the assertion, not the behaviour around it.
    @Test("the control client is built once per port, not once per watch tick")
    func buildsOneClientPerPort() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 4040)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 4040, startTime: proxy.processStartTime)

        let built = ClientBuildCounter()
        let supervisor = fixture.supervisor(clientFactory: { port in
            built.record(port: port)
            return ModelProxyClient(port: port)
        })
        await supervisor.start()

        for _ in 0..<10 {
            await fixture.clock.advanceWhenSuspended(by: fixture.watchInterval)
        }
        await supervisor.stop()

        #expect(await supervisor.current?.pid == 4040, "ten quiet polls change nothing")
        #expect(
            proxy.requests().filter { $0.path == "/tbd/status" }.count >= 10,
            "the polls have to have happened for the count below to mean anything")
        #expect(
            built.counts() == [proxy.port: 1],
            "a client per tick is a URLSession per tick, and nothing invalidates them")
    }

    // MARK: - Routes

    /// A route is a file **and** a registration, in that order: the file is
    /// what a proxy restarting later loads, and the POST is what the running
    /// one needs to serve the very next request.
    @Test("makeRoute writes the route file atomically and registers it with the proxy")
    func makeRouteWritesFileAndRegisters() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 3030)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 3030, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        let terminalID = UUID()
        let route = try await supervisor.makeRoute(
            terminalID: terminalID, upstream: "https://api.anthropic.com",
            streamingEnabled: true)

        #expect(ModelProxyRoute.isValidToken(route.token))
        #expect(route.terminalID == terminalID)
        #expect(route.streamingEnabled)

        let path = TBDConstants.modelProxyRoutePath(
            token: route.token, environment: fixture.environment)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let onDisk = try ModelProxyRoute.decodeRouteFile(data)
        // Field by field rather than `==`: a route file's `createdAt` is
        // ISO-8601, which is whole seconds, so the decoded date is a truncated
        // copy of the one in memory and whole-value equality would fail for a
        // reason that has nothing to do with what is being asserted.
        #expect(onDisk.token == route.token)
        #expect(onDisk.terminalID == route.terminalID)
        #expect(onDisk.upstream == route.upstream)
        #expect(onDisk.streamingEnabled == route.streamingEnabled)
        #expect(onDisk.version == ModelProxyRoute.schemaVersion)

        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o600)

        let registration = proxy.requests().first {
            $0.method == "POST" && $0.path == "/tbd/routes"
        }
        let body = try #require(registration.map(\.body))
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(decoded == ["token": route.token], "the proxy is told the token and nothing else")

        #expect(
            await supervisor.baseURL(for: route)
                == "http://127.0.0.1:\(proxy.port)/r/\(route.token)")
    }

    /// A registration that fails is **not** fatal: the file is on disk, and a
    /// proxy's `loadAll` picks it up on its next start. The route is returned
    /// either way, so a session still gets a base URL.
    @Test("a route survives a proxy that will not accept its registration")
    func makeRouteSurvivesARegistrationFailure() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 3031, routeStatus: 500)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 3031, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        let route = try await supervisor.makeRoute(
            terminalID: UUID(), upstream: "https://api.anthropic.com", streamingEnabled: false)

        let path = TBDConstants.modelProxyRoutePath(
            token: route.token, environment: fixture.environment)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// With no proxy there is no port to name in a base URL, so `makeRoute`
    /// throws rather than writing a route nothing can serve.
    @Test("makeRoute throws when no proxy is current")
    func makeRouteThrowsWithoutAProxy() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let supervisor = fixture.supervisorWithoutSpawner()
        await supervisor.start()
        await supervisor.stop()

        await #expect(throws: ModelProxySupervisor.RouteError.self) {
            _ = try await supervisor.makeRoute(
                terminalID: UUID(), upstream: "https://api.anthropic.com",
                streamingEnabled: true)
        }
    }

    /// Retirement asks the proxy first, because only the proxy can drop the
    /// route from the table it is serving out of. When it cannot be asked, the
    /// files are the daemon's to unlink — both of them, so no stream file is
    /// left naming a terminal that is gone.
    @Test("a retirement the proxy cannot take unlinks the route and stream files here")
    func retireRouteFallsBackToUnlink() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 3032)
        // As above: stopped mid-test, and stopped again here if an expectation
        // fails first.
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 3032, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        let terminalID = UUID()
        let route = try await supervisor.makeRoute(
            terminalID: terminalID, upstream: "https://api.anthropic.com",
            streamingEnabled: true)
        let routePath = TBDConstants.modelProxyRoutePath(
            token: route.token, environment: fixture.environment)
        let streamPath = TBDConstants.streamFilePath(
            terminalID: terminalID, environment: fixture.environment)
        try FileManager.default.createDirectory(
            at: TBDConstants.streamsDir(environment: fixture.environment),
            withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: streamPath))

        // The proxy goes away: nothing answers the DELETE.
        proxy.stop()

        await supervisor.retireRoute(token: route.token, terminalID: terminalID)

        #expect(!FileManager.default.fileExists(atPath: routePath))
        #expect(!FileManager.default.fileExists(atPath: streamPath))
    }

    /// A reachable proxy is asked to drop the route, and the daemon does not
    /// unlink behind it — the proxy owns both files at that point and may
    /// still be appending to the stream one.
    @Test("a retirement the proxy accepts is a DELETE and nothing else")
    func retireRouteAsksTheProxy() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 3033)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 3033, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        let terminalID = UUID()
        let route = try await supervisor.makeRoute(
            terminalID: terminalID, upstream: "https://api.anthropic.com",
            streamingEnabled: true)
        await supervisor.retireRoute(token: route.token, terminalID: terminalID)

        #expect(
            proxy.requests().contains {
                $0.method == "DELETE" && $0.path == "/tbd/routes/\(route.token)"
            })
    }

    /// The lookup a terminal's teardown makes when it holds an id and no
    /// token. One directory listing, and the file that names *this* terminal
    /// wins — the others in the directory must not.
    @Test("routeToken finds the file naming the terminal, among others that do not")
    func routeTokenForTerminalFindsTheRightFile() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 3034)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 3034, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        let wanted = UUID()
        _ = try await supervisor.makeRoute(
            terminalID: UUID(), upstream: "https://api.anthropic.com", streamingEnabled: false)
        let route = try await supervisor.makeRoute(
            terminalID: wanted, upstream: "https://api.anthropic.com", streamingEnabled: true)
        _ = try await supervisor.makeRoute(
            terminalID: UUID(), upstream: "https://api.anthropic.com", streamingEnabled: false)

        #expect(await supervisor.routeToken(forTerminal: wanted) == route.token)
        #expect(await supervisor.routeToken(forTerminal: UUID()) == nil)
    }
}

// MARK: - Fixture

/// Everything one supervisor test needs, wired to a scratch home.
private struct SupervisorFixture {
    /// A port nothing in a test runner can be listening on: binding below 1024
    /// needs root, so a status probe there is a prompt `ECONNREFUSED` rather
    /// than a stranger's listener. Used wherever a case needs the probe to
    /// fail, or needs a port value that no concurrently running suite could
    /// have taken.
    static let deadPort = 1
    static let otherDeadPort = 2

    let root: URL
    let home: URL
    let db: TBDDatabase
    let spawner: StubSpawner
    let identity: StubIdentity
    let clock: TestClock<Duration>
    let ownVersion = "12345-1700000000"
    let watchInterval: Duration = .seconds(15)

    var environment: [String: String] { ["TBD_HOME": home.path] }
    var paths: ProxyHomePaths { ProxyHomePaths(home: home) }

    static func make() throws -> SupervisorFixture {
        let root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdmps"))
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return SupervisorFixture(
            root: root,
            home: home,
            db: try TBDDatabase(inMemory: true),
            spawner: StubSpawner(),
            identity: StubIdentity(),
            clock: TestClock())
    }

    /// The control client is the **real** one, on whatever port the supervisor
    /// asks for: a fake proxy binds a real loopback port and the config row
    /// names it, so nothing has to be redirected for the client to reach it —
    /// and a probe of a port with no listener fails for the real reason.
    func supervisor(
        clientFactory: @escaping @Sendable (Int) -> ModelProxyClient = {
            ModelProxyClient(port: $0)
        }
    ) -> ModelProxySupervisor {
        ModelProxySupervisor(
            config: db.config,
            home: home,
            spawner: spawner,
            ownVersion: ownVersion,
            processIdentity: identity,
            clientFactory: clientFactory,
            watchInterval: watchInterval,
            respawnBackoff: [.seconds(1), .seconds(5)],
            clock: clock)
    }

    func supervisorWithoutSpawner() -> ModelProxySupervisor {
        ModelProxySupervisor(
            config: db.config,
            home: home,
            spawner: nil,
            ownVersion: ownVersion,
            processIdentity: identity,
            clientFactory: { ModelProxyClient(port: $0) },
            watchInterval: watchInterval,
            respawnBackoff: [.seconds(1)],
            clock: clock)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// A spawner that answers from a queue and records what it was asked for.
///
/// A queue rather than one value because half the branches here are two-spawn
/// sequences — a failure and then a recovery — and the *order* of the ports it
/// was asked for is what those cases assert.
private actor StubSpawner: ModelProxySpawning {
    enum Answer {
        case success(pid: pid_t, port: Int)
        case failure(ModelProxySpawner.Error)
    }

    private var answers: [Answer] = []
    private var requested: [Int] = []
    private var exits: [pid_t: Int32] = [:]
    private var collectedPids: [pid_t] = []

    func answer(_ answer: Answer) { answers.append(answer) }
    func calls() -> [Int] { requested }
    /// Makes `reapIfExited` report `pid` as having exited, once.
    func reap(pid: pid_t, status: Int32) { exits[pid] = status }
    /// The pids actually collected, in order — a zombie is a pid that exited
    /// and never appears here.
    func collected() -> [pid_t] { collectedPids }

    func spawn(port: Int, home: URL) async throws -> (pid: pid_t, port: Int) {
        requested.append(port)
        guard !answers.isEmpty else { throw ModelProxySpawner.Error.launchFailed(errno: ENOENT) }
        switch answers.removeFirst() {
        case .success(let pid, let boundPort):
            return (pid, boundPort)
        case .failure(let error):
            throw error
        }
    }

    func reapIfExited(pid: pid_t) async -> Int32? {
        guard let status = exits.removeValue(forKey: pid) else { return nil }
        collectedPids.append(pid)
        return status
    }
}

/// A stand-in process table: a pid is the process it claims to be only if it
/// was admitted with that exact start time.
private final class StubIdentity: ProcessIdentityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var admitted: [Int32: Date] = [:]
    private var denials = 0

    func admit(pid: Int32, startTime: Date) {
        lock.withLock { admitted[pid] = startTime }
    }

    func forget(pid: Int32) {
        lock.withLock { admitted[pid] = nil }
    }

    /// Deny the next check whatever it asks about — for the cases that need a
    /// first probe to fail and a later one to succeed.
    func denyOnce() {
        lock.withLock { denials += 1 }
    }

    func matches(pid: Int32, startTime: Date) -> Bool {
        lock.withLock { () -> Bool in
            if denials > 0 {
                denials -= 1
                return false
            }
            guard let known = admitted[pid] else { return false }
            return abs(known.timeIntervalSince(startTime)) < 0.000_001
        }
    }
}

/// A `TBDModelProxy`'s control endpoint and nothing else: it answers
/// `/tbd/status` with a document the daemon's decoder accepts, takes a retire
/// and both route verbs, and records everything that arrived.
private final class FakeProxyProcess: @unchecked Sendable {
    /// Sub-second on purpose: the status document carries microseconds, and a
    /// coder that rounded them away would make every adoption fail.
    private static let startedAt = Date(timeIntervalSince1970: 1_700_000_000.123_456)

    private let server: LoopbackHTTPTestServer
    private let pidBox: PidBox
    let processStartTime = FakeProxyProcess.startedAt

    var port: Int { server.port }

    /// Makes the listener answer for another process from now on — one port
    /// changing hands, which is what another daemon's replacement looks like
    /// from the supervisor's side.
    func becomePid(_ pid: Int32) { pidBox.value = pid }

    init(version: String, pid: Int32, routeStatus: Int = 200) throws {
        // The listener's port is not known until it is bound, so the status
        // document is composed per request out of a box the initializer fills
        // afterwards rather than baked into the handler.
        let portBox = PortBox()
        let pidBox = PidBox(pid)
        self.pidBox = pidBox
        let started = FakeProxyProcess.startedAt
        self.server = try LoopbackHTTPTestServer { request in
            if request.method == "DELETE", request.path.hasPrefix("/tbd/routes/") {
                return .ok("{}")
            }
            switch (request.method, request.path) {
            case ("GET", "/tbd/status"):
                let document = ModelProxyStatus(
                    version: version, pid: pidBox.value, processStartTime: started,
                    port: portBox.value, streamsInFlight: 0, routeCount: 0)
                guard let data = try? document.encodedForStatusResponse() else {
                    return LoopbackHTTPTestServer.Reply(status: 500, body: "{}")
                }
                return .ok(String(decoding: data, as: UTF8.self))
            case ("POST", "/tbd/retire"):
                return .ok("{}")
            case ("POST", "/tbd/routes"):
                return LoopbackHTTPTestServer.Reply(status: routeStatus, body: "{}")
            default:
                return LoopbackHTTPTestServer.Reply(status: 404, body: "{}")
            }
        }
        portBox.value = server.port
    }

    func requests() -> [LoopbackHTTPTestServer.Request] { server.requests() }
    func stop() { server.stop() }
}

/// Counts how many clients a supervisor asks its factory for, per port.
private final class ClientBuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var built: [Int: Int] = [:]

    func record(port: Int) {
        lock.withLock { built[port, default: 0] += 1 }
    }

    func counts() -> [Int: Int] { lock.withLock { built } }
}

/// A box for the pid the fake reports, so a test can move a port from one
/// process to another while the supervisor is watching it.
private final class PidBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32

    init(_ pid: Int32) { stored = pid }

    var value: Int32 {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A box for the port, because the handler closure is built before the
/// listener has one.
private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
