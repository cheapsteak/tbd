import Clocks
import Darwin
import Dispatch
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
/// The rendezvous is not stubbed: `FakeProxyProcess` writes a real
/// `<home>/proxy/proxy.pid` the way the real binary does, and the adoption
/// cases that must be refused corrupt that file rather than a reader — so what
/// the daemon parses is what a proxy would have written.
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

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 4242, home: fixture.home)
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

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 4242, home: fixture.home)
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

    // MARK: - Adoption identity

    /// **The collision the `home` field exists for** (spec, "Adoption
    /// identity"). Two TBD homes on one machine draw their ports from one
    /// ephemeral range, so the kernel can hand a second install the port this
    /// daemon's config row names. Everything else about it matches: a real live
    /// process the table confirms, at a start time that agrees, of this
    /// daemon's own version, with a pid file in *this* home naming exactly that
    /// pid and port. Only the home says it is somebody else's, and that alone
    /// must refuse the adoption.
    @Test("a proxy serving another TBD home is not adopted")
    func doesNotAdoptAProxyServingAnotherHome() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let elsewhere = fixture.root.appendingPathComponent("another-install")
        let proxy = try ForeignHomeProxyProcess(
            version: fixture.ownVersion, pid: 5150, home: elsewhere.path)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 5150, startTime: proxy.processStartTime)
        // Every other check is set up to PASS, so the home is the only thing
        // that can refuse this.
        try fixture.publishPidFile(pid: 5150, port: proxy.port)
        await fixture.spawner.answer(.success(pid: 5151, port: SupervisorFixture.deadPort))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        #expect(await supervisor.current?.pid == 5151, "another home's proxy must not be adopted")
        #expect(await supervisor.current?.adopted == false)
        #expect(await fixture.spawner.calls() == [proxy.port])
    }

    /// A proxy built before the `home` field reports none, and a daemon that
    /// cannot place a process must not take it over.
    @Test("a proxy that reports no home at all is not adopted")
    func doesNotAdoptAProxyWithNoHome() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try ForeignHomeProxyProcess(
            version: fixture.ownVersion, pid: 5160, home: "")
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 5160, startTime: proxy.processStartTime)
        try fixture.publishPidFile(pid: 5160, port: proxy.port)
        await fixture.spawner.answer(.success(pid: 5161, port: SupervisorFixture.deadPort))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        #expect(await supervisor.current?.pid == 5161)
        #expect(await fixture.spawner.calls() == [proxy.port])
    }

    /// The status answer is written by whatever is listening; the pid file is
    /// written by the process that took `proxy.lock` and bound the port. With
    /// no such file there is nothing tying the responder to this home's
    /// rendezvous, so it is not adopted.
    @Test("a responder with no pid file in this home is not adopted")
    func doesNotAdoptWithoutAPidFile() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 5170, home: fixture.home)
        defer { proxy.stop() }
        proxy.unpublishPidFile()
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 5170, startTime: proxy.processStartTime)
        await fixture.spawner.answer(.success(pid: 5171, port: SupervisorFixture.deadPort))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        #expect(await supervisor.current?.pid == 5171)
        #expect(await supervisor.current?.adopted == false)
        #expect(await fixture.spawner.calls() == [proxy.port])
    }

    /// The pid file names one process and the responder claims to be another.
    /// One of the two is lying and there is no way to tell which, so neither is
    /// adopted.
    @Test("a pid file naming a different process refuses the adoption")
    func doesNotAdoptOnAPidFileMismatch() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 5180, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 5180, startTime: proxy.processStartTime)
        // The rendezvous names somebody else — a predecessor mid-retirement, or
        // a file from an install that is no longer the one answering.
        try fixture.publishPidFile(pid: 5181, port: proxy.port)
        await fixture.spawner.answer(.success(pid: 5182, port: SupervisorFixture.deadPort))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        #expect(await supervisor.current?.pid == 5182)
        #expect(await fixture.spawner.calls() == [proxy.port])
    }

    /// The pid file agrees about the process and disagrees about the port. The
    /// rendezvous has moved on; adopting here would send every later control
    /// call to a port this home's file does not vouch for.
    @Test("a pid file naming a different port refuses the adoption")
    func doesNotAdoptOnAPidFilePortMismatch() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 5190, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 5190, startTime: proxy.processStartTime)
        try fixture.publishPidFile(pid: 5190, port: SupervisorFixture.otherDeadPort)
        await fixture.spawner.answer(.success(pid: 5191, port: SupervisorFixture.deadPort))

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        #expect(await supervisor.current?.pid == 5191)
        #expect(await fixture.spawner.calls() == [proxy.port])
    }

    /// The positive of the four above, stated once as one assertion rather than
    /// inferred from `adoptsMatchingProxyAtStartup`: home, process table, pid
    /// and port all agree, and the proxy is taken over.
    @Test("a proxy whose home, process table entry and pid file all agree is adopted")
    func adoptsWhenEveryIdentityCheckAgrees() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 5200, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 5200, startTime: proxy.processStartTime)
        #expect(
            fixture.readPidFile() == ModelProxyPIDFileRecord(pid: 5200, port: proxy.port),
            "the fixture must publish a pid file, or the refusals above prove nothing")

        let supervisor = fixture.supervisor()
        await supervisor.start()
        await supervisor.stop()

        #expect(await supervisor.current?.pid == 5200)
        #expect(await supervisor.current?.adopted == true)
        #expect(await fixture.spawner.calls().isEmpty)
    }

    // MARK: - The flag gate and the drain

    /// The gate (spec, "The daemon" → "Supervisor" → Gate). `model_proxy_enabled`
    /// is default-off and shipped that way, so a daemon that booted without it
    /// — on a fresh install, where nothing has ever been routed — must not
    /// start a proxy: not spawn one, not adopt one, not even probe.
    ///
    /// The flag-off boot that *does* start something is the drain, and it needs
    /// a routed session alive to reach it; see
    /// `aFlagOffBootDrainsForRoutedSessions` and its discriminating half.
    @Test("with the flag off the supervisor starts nothing")
    func theFlagOffStartsNothing() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        // A spawn is queued so the refusal cannot pass by there being nothing
        // to take.
        await fixture.spawner.answer(.success(pid: 6100, port: SupervisorFixture.deadPort))
        #expect(try await fixture.db.config.get().modelProxyEnabled == false)

        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        await supervisor.stop()

        #expect(await fixture.spawner.calls().isEmpty, "a disabled flag must not spawn a proxy")
        #expect(await supervisor.current == nil)
        #expect(
            try await fixture.db.config.get().modelProxyPort == nil,
            "a disabled flag must not mint a port either")
    }

    /// The other half, which is what makes the test above discriminating: with
    /// the flag on, the same call spawns.
    @Test("with the flag on the supervisor starts")
    func theFlagOnStarts() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        try await fixture.db.config.setModelProxyEnabled(true)
        await fixture.spawner.answer(.success(pid: 6110, port: SupervisorFixture.deadPort))

        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        await supervisor.stop()

        #expect(await fixture.spawner.calls() == [0])
        #expect(await supervisor.current?.pid == 6110)
    }

    /// The flag going off ends routing for **new** sessions and nothing else.
    /// With nothing routed there is nothing to protect, so the proxy is retired
    /// on the spot: it holds `proxy.lock` and would otherwise self-retire only
    /// after 24 hours.
    @Test("the flag going off retires a proxy that serves no routes")
    func drainingRetiresAProxyWithNoRoutes() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 6120, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        try await fixture.db.config.setModelProxyEnabled(true)
        fixture.identity.admit(pid: 6120, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        #expect(await supervisor.current?.pid == 6120)

        // The column first and the supervisor second, exactly as the RPC does
        // it: the write is what stops new spawns being routed, and this call is
        // what decides the fate of the proxy already running.
        try await fixture.db.config.setModelProxyEnabled(false)
        await supervisor.beginDraining()

        #expect(
            proxy.requests().contains { $0.method == "POST" && $0.path == "/tbd/retire" },
            "a proxy nobody is routed through has nothing to drain")
        #expect(await supervisor.current == nil, "a retired proxy is no longer this daemon's")
    }

    /// **The finding this behaviour exists for.** A session spawned while the
    /// flag was on carries `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>/r/<token>`
    /// in its environment for the rest of its life, so retiring the proxy when
    /// the toggle goes off would not un-route it — it would break it mid-task,
    /// on its next turn, with a connection error to a closed loopback port. The
    /// toggle's help text promises the flag applies to sessions started after
    /// the change, and this is that promise in the off direction.
    @Test("the flag going off keeps a proxy that still serves routes")
    func drainingKeepsAProxyThatStillServesRoutes() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(
            version: fixture.ownVersion, pid: 6140, home: fixture.home, routeCount: 1)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        try await fixture.db.config.setModelProxyEnabled(true)
        fixture.identity.admit(pid: 6140, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        #expect(await supervisor.current?.pid == 6140)

        try await fixture.db.config.setModelProxyEnabled(false)
        await supervisor.beginDraining()
        await supervisor.stop()

        #expect(
            proxy.requests().allSatisfy { $0.path != "/tbd/retire" },
            "a route still in flight must keep its proxy listening")
        #expect(await supervisor.current?.pid == 6140)
    }

    /// A draining supervisor is not a stopped one: it keeps every duty it had,
    /// because the sessions it is draining for still need a proxy on that port.
    /// A proxy that dies mid-drain is respawned exactly as it would have been
    /// with the flag on — the successor rebuilds its table from `routes/`, so
    /// the routes survive it.
    ///
    /// The spawned proxy has no listener, so every status poll fails and the
    /// drain never reads a route count: what is observed here is only the
    /// respawn, which the old retire-on-off behaviour could not have produced —
    /// it stopped the watch and dropped the proxy before any of this.
    @Test("a proxy that dies while draining is still respawned")
    func drainingStillRespawnsAProxyThatDies() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        try await fixture.db.config.setModelProxyEnabled(true)
        await fixture.spawner.answer(.success(pid: 6150, port: SupervisorFixture.deadPort))
        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        #expect(await supervisor.current?.pid == 6150)

        try await fixture.db.config.setModelProxyEnabled(false)
        await supervisor.beginDraining()
        #expect(await supervisor.current?.pid == 6150, "an unanswered drain check keeps the proxy")

        await fixture.spawner.reap(pid: 6150, status: 0)
        await fixture.spawner.answer(.success(pid: 6151, port: SupervisorFixture.deadPort))
        let respawned = await fixture.clock.advanceUntil(
            "the draining proxy to be respawned", by: fixture.watchInterval,
            { await supervisor.current?.pid == 6151 })
        await supervisor.stop()

        #expect(respawned)
        #expect(
            await fixture.spawner.calls()
                == [0, SupervisorFixture.deadPort],
            "the successor takes the port the dead one held")
    }

    /// The end of the drain, and the only thing that ends it: the proxy itself
    /// reporting that no route is left. Every routed terminal retires its own
    /// route as it exits, so the count reaching zero is the last of them
    /// finishing — at which point the proxy is retired and the supervisor
    /// stops.
    @Test("the last route retiring retires the proxy and stops the watch")
    func drainingEndsWhenTheLastRouteGoes() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(
            version: fixture.ownVersion, pid: 6160, home: fixture.home, routeCount: 2)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        try await fixture.db.config.setModelProxyEnabled(true)
        fixture.identity.admit(pid: 6160, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        try await fixture.db.config.setModelProxyEnabled(false)
        await supervisor.beginDraining()
        #expect(await supervisor.current?.pid == 6160, "two routes in flight keep it")

        proxy.setRouteCount(0)
        let retired = await fixture.clock.advanceUntil(
            "the drained proxy to be retired", by: fixture.watchInterval,
            { await supervisor.current == nil })
        await supervisor.stop()

        #expect(retired)
        #expect(proxy.requests().contains { $0.method == "POST" && $0.path == "/tbd/retire" })
    }

    /// Turning the flag back on while a drain is under way is simply a return
    /// to normal service. Nothing is respawned and nothing is re-adopted — the
    /// watch never stopped and the proxy was never dropped — and the route
    /// count falling to zero afterwards no longer means anything, because the
    /// supervisor is not draining any more.
    ///
    /// The zero route count is the discriminating half: it is exactly the input
    /// that retires the proxy in `drainingEndsWhenTheLastRouteGoes`, and here it
    /// must not.
    @Test("turning the flag back on while draining keeps the proxy")
    func drainingIsClearedByTheFlagComingBackOn() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(
            version: fixture.ownVersion, pid: 6170, home: fixture.home, routeCount: 1)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        try await fixture.db.config.setModelProxyEnabled(true)
        fixture.identity.admit(pid: 6170, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        try await fixture.db.config.setModelProxyEnabled(false)
        await supervisor.beginDraining()

        // The user changes their mind, and then the last route retires anyway.
        try await fixture.db.config.setModelProxyEnabled(true)
        await supervisor.startIfEnabled()
        proxy.setRouteCount(0)

        let pollsBefore = proxy.requests().filter { $0.path == "/tbd/status" }.count
        let polled = await fixture.clock.advanceUntil(
            "a watch poll after the flag came back on", by: fixture.watchInterval,
            { proxy.requests().filter { $0.path == "/tbd/status" }.count > pollsBefore })
        await supervisor.stop()

        #expect(polled)
        #expect(
            proxy.requests().allSatisfy { $0.path != "/tbd/retire" },
            "a supervisor that is no longer draining must not retire on an empty route table")
        #expect(await supervisor.current?.pid == 6170)
    }

    /// The `catch` around `/tbd/retire` (Minor 2 of the B2.5 review). A proxy
    /// that refuses to retire is still dropped: there is nothing to escalate to
    /// — an adopted proxy is not this daemon's to signal, and killing a spawned
    /// one would cut whatever is still in flight — and it self-retires after
    /// its own idle window. What must not happen is the supervisor going on
    /// believing it holds a proxy it has told itself it retired, which is what
    /// a future refactor moving `dropLive()` inside the `do` would produce.
    @Test("a proxy that refuses to retire is dropped anyway")
    func aFailedRetireStillDropsTheProxy() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(
            version: fixture.ownVersion, pid: 6180, home: fixture.home, retireStatus: 500)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        try await fixture.db.config.setModelProxyEnabled(true)
        fixture.identity.admit(pid: 6180, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        #expect(await supervisor.current?.pid == 6180)

        try await fixture.db.config.setModelProxyEnabled(false)
        await supervisor.beginDraining()

        #expect(
            proxy.requests().contains { $0.method == "POST" && $0.path == "/tbd/retire" },
            "the refusal has to come from a retire that was actually attempted")
        #expect(
            await supervisor.current == nil,
            "a proxy the supervisor believes it retired must not stay current")
    }

    // MARK: - The drain's own races

    /// **The window Important 1 of the final review found.** The immediate
    /// drain check the toggle makes suspends on its own `/tbd/status` poll, and
    /// everything it decided before that poll can be false when it resumes.
    ///
    /// Here the user re-ticks the toggle while the poll is in flight. The count
    /// that comes back is zero — the same input that retires the proxy in
    /// `drainingRetiresAProxyWithNoRoutes` — and it must decide nothing,
    /// because the supervisor is no longer draining by the time it arrives.
    /// Retiring on it would leave the flag on with no proxy for a whole watch
    /// interval, and every session spawned in that gap unproxied.
    @Test("the flag coming back on during the drain's poll keeps the proxy")
    func theFlagComingBackOnDuringTheDrainPollKeepsTheProxy() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 6210, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        try await fixture.db.config.setModelProxyEnabled(true)
        fixture.identity.admit(pid: 6210, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        try await fixture.db.config.setModelProxyEnabled(false)

        let config = fixture.db.config
        proxy.onNextStatus {
            runBlocking("the flag coming back on mid-poll") {
                try? await config.setModelProxyEnabled(true)
                await supervisor.startIfEnabled()
            }
        }
        // Driven off the cooperative pool as well: the hook blocks until the
        // flip lands, and both sides of that hand-off have to be able to run
        // while a sibling suite is deliberately saturating the pool.
        await gateHoldingTask { await supervisor.beginDraining() }.value
        await supervisor.stop()

        #expect(
            proxy.requests().allSatisfy { $0.path != "/tbd/retire" },
            "a route count read before the flag came back on must not retire the proxy")
        #expect(await supervisor.current?.pid == 6210)
    }

    /// The other half of the same window, and the one that costs a session: a
    /// spawn racing the toggle. The RPC writes the column and asks for the
    /// drain; the spawn was already past its own read of that column, and its
    /// `POST /tbd/routes` lands while the drain's poll is in flight. The poll
    /// answered zero and the answer was already stale.
    ///
    /// A retire here would not un-route that session — its
    /// `ANTHROPIC_BASE_URL` names this port for the rest of its life — it would
    /// break it on its first turn against a closed loopback port.
    @Test("a route minted during the drain's poll keeps the proxy")
    func aRouteMintedDuringTheDrainPollKeepsTheProxy() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 6220, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        try await fixture.db.config.setModelProxyEnabled(true)
        fixture.identity.admit(pid: 6220, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        try await fixture.db.config.setModelProxyEnabled(false)

        // The document already composed says zero; the route lands immediately
        // behind it, so every later read says one.
        proxy.onNextStatus { proxy.setRouteCount(1) }
        await supervisor.beginDraining()
        await supervisor.stop()

        #expect(
            proxy.requests().allSatisfy { $0.path != "/tbd/retire" },
            "the count is re-read immediately before the retire, and it is no longer zero")
        #expect(await supervisor.current?.pid == 6220)
    }

    /// The proxy the drain decided about is not necessarily the proxy it would
    /// retire. While the poll is in flight the supervisor is free to service
    /// anything else — here a restart that adopts a *different* proxy onto
    /// `live` — and a retire that read `live` at the point of use would send
    /// `POST /tbd/retire` to the successor, which has drained nothing and may be
    /// serving routes of its own.
    @Test("a proxy replaced during the drain's poll is not the one retired")
    func aProxyReplacedDuringTheDrainPollIsNotRetired() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let first = try FakeProxyProcess(version: fixture.ownVersion, pid: 6230, home: fixture.home)
        defer { first.stop() }
        try await fixture.db.config.setModelProxyPort(first.port)
        try await fixture.db.config.setModelProxyEnabled(true)
        fixture.identity.admit(pid: 6230, startTime: first.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        #expect(await supervisor.current?.pid == 6230)
        try await fixture.db.config.setModelProxyEnabled(false)

        // A second proxy, on its own port, publishing its own pid file — the
        // rendezvous a successor writes after binding.
        let second = try FakeProxyProcess(version: fixture.ownVersion, pid: 6231, home: fixture.home)
        defer { second.stop() }
        fixture.identity.admit(pid: 6231, startTime: second.processStartTime)

        let config = fixture.db.config
        first.onNextStatus {
            runBlocking("the successor being adopted mid-poll") {
                await supervisor.stop()
                try? await config.setModelProxyPort(second.port)
                await supervisor.start()
            }
        }
        await gateHoldingTask { await supervisor.beginDraining() }.value
        await supervisor.stop()

        #expect(await supervisor.current?.pid == 6231, "the successor was adopted mid-poll")
        #expect(
            second.requests().allSatisfy { $0.path != "/tbd/retire" },
            "the successor must not be retired on its predecessor's route count")
        #expect(first.requests().allSatisfy { $0.path != "/tbd/retire" })
    }

    /// **The one status read whose verdict is a `POST /tbd/retire`**, and until
    /// this fix the only one acted on with no identity check at all. A proxy
    /// that died and left its port to a stranger — another home's proxy, or a
    /// pid the table no longer confirms — answers with a route count of its
    /// own, and a daemon that believed it would retire on a stranger's word.
    ///
    /// Nothing is retired, and nothing is adopted either: an answer that fails
    /// the check decides nothing at all.
    @Test("a drain check from a process the daemon cannot confirm is ignored")
    func aDrainCheckFromAnUnconfirmedProcessIsIgnored() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 6240, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        try await fixture.db.config.setModelProxyEnabled(true)
        fixture.identity.admit(pid: 6240, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        #expect(await supervisor.current?.pid == 6240)

        // The proxy this daemon adopted is gone from the process table; what
        // answers on that port now is not something it can confirm. Everything
        // else — the route count of zero, the flag going off — is exactly
        // `drainingRetiresAProxyWithNoRoutes`, which retires.
        fixture.identity.forget(pid: 6240)
        try await fixture.db.config.setModelProxyEnabled(false)
        await supervisor.beginDraining()
        await supervisor.stop()

        #expect(
            proxy.requests().allSatisfy { $0.path != "/tbd/retire" },
            "a route count from an unconfirmed responder must not retire anything")
        #expect(
            await supervisor.current?.pid == 6240,
            "and it must not drop or re-adopt anything either")
    }

    /// A fifth window the count-based drain must survive, alongside the four
    /// above: `makeRoute` writes the route file, then suspends on `addRoute`
    /// to tell the running proxy about it. Because the supervisor is an
    /// actor, a `beginDraining()` triggered by a concurrent flag flip can run
    /// in exactly that suspension, and the `/tbd/status` poll it makes does
    /// not yet reflect a registration the proxy has not been told about —
    /// both read `routeCount == 0`. Retiring here would not un-route the
    /// session `makeRoute` was just called for; it would break it, mid-task,
    /// against a port that has just gone away.
    ///
    /// `holdNextRouteRegistration` is what opens the window without wedging
    /// the fake server: it answers nothing for the registration (the
    /// `aSilentProxyTimesOut` mechanism), which frees the accept loop rather
    /// than blocking it, so the drain's own `/tbd/status` poll lands and
    /// answers for real — a route count of zero the drain must not act on
    /// alone.
    ///
    /// Discriminates against the pre-fix code: without
    /// `routeRegistrationsInFlight`, the drain's poll answering zero is the
    /// whole of what the pre-fix `finishDrainingIfNoRoutesRemain` needed to
    /// retire. `beginDraining` and the watch's `tick` both funnel through
    /// that one function and its one guard, so driving it through the
    /// immediate path exercises the same check `tick`'s "known" count takes
    /// and the re-read `finishDraining` makes right before the retire. What
    /// happens once a registration is confirmed, and once the route it named
    /// is later removed, is exactly `aRouteMintedDuringTheDrainPollKeepsTheProxy`
    /// and `drainingRetiresAProxyWithNoRoutes` — not re-proven here.
    @Test("a drain that begins while a route registration is in flight keeps the proxy")
    func aDrainDuringAnInFlightRegistrationKeepsTheProxy() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 6250, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        try await fixture.db.config.setModelProxyEnabled(true)
        fixture.identity.admit(pid: 6250, startTime: proxy.processStartTime)

        // A held registration's connection is never answered, so left at the
        // client's default two-second budget it is `addRoute`'s own timeout —
        // not the drain — that eventually clears the in-flight count, and on
        // a saturated runner that budget itself can balloon far past its
        // nominal length (`ModelProxyClientTests`' own silent-proxy case
        // measured 32s against a 0.4s budget) but is still bounded. A long
        // client timeout here is what keeps the registration in flight for
        // the whole of this test's real-time budget regardless.
        let supervisor = fixture.supervisor(clientFactory: { port in
            ModelProxyClient(
                port: port, session: ModelProxyClient.makeSession(requestTimeout: 120),
                requestTimeout: 120)
        })
        await supervisor.startIfEnabled()
        #expect(await supervisor.current?.pid == 6250)

        proxy.holdNextRouteRegistration()
        let makeRouteTask = Task {
            try await supervisor.makeRoute(
                terminalID: UUID(), upstream: "https://api.anthropic.com", streamingEnabled: false)
        }

        // Confirms `addRoute` has been sent — and so, since `makeRoute`
        // increments the in-flight count synchronously before that call,
        // that the count is already 1 — without needing to reach into the
        // actor.
        try await waitFor(
            "the route registration to reach the proxy",
            observed: { "requests \(proxy.requests().map(\.path))" }
        ) {
            proxy.requests().contains { $0.method == "POST" && $0.path == "/tbd/routes" }
        }

        try await fixture.db.config.setModelProxyEnabled(false)
        await supervisor.beginDraining()
        #expect(
            proxy.requests().allSatisfy { $0.path != "/tbd/retire" },
            "a registration still in flight must not be read as a route count of zero")
        #expect(await supervisor.current?.pid == 6250)

        await supervisor.stop()
        makeRouteTask.cancel()
        _ = try? await makeRouteTask.value
    }

    /// The boot half of the drain. A daemon that restarts after the flag went
    /// off — or that was never running when it went off — still has to keep the
    /// port answering for sessions spawned while it was on, because their base
    /// URL is fixed in their environment. So a flag-off boot with a routed
    /// session alive starts, adopts, and drains.
    @Test("a flag-off boot with a routed session still alive starts draining")
    func aFlagOffBootDrainsForRoutedSessions() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(
            version: fixture.ownVersion, pid: 6190, home: fixture.home, routeCount: 1)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        #expect(try await fixture.db.config.get().modelProxyEnabled == false)
        fixture.identity.admit(pid: 6190, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor(routedSessionsAlive: { true })
        await supervisor.startIfEnabled()
        await supervisor.stop()

        #expect(
            await supervisor.current?.pid == 6190,
            "a routed session's proxy is adopted even with the flag off")
        #expect(proxy.requests().allSatisfy { $0.path != "/tbd/retire" })
    }

    /// **The discriminating half of the boot drain**, and the one that keeps
    /// the success criterion honest: with the flag off and no session routed
    /// through the proxy, the supervisor starts nothing — not even against a
    /// proxy that is sitting there, adoptable, on the persisted port. This is
    /// `aFlagOffBootDrainsForRoutedSessions` with exactly one input changed.
    @Test("a flag-off boot with nothing routed adopts nothing")
    func aFlagOffBootWithNothingRoutedStartsNothing() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(
            version: fixture.ownVersion, pid: 6200, home: fixture.home, routeCount: 1)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 6200, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor(routedSessionsAlive: { false })
        await supervisor.startIfEnabled()
        await supervisor.stop()

        #expect(await supervisor.current == nil)
        #expect(proxy.requests().isEmpty, "nothing was even probed")
        #expect(await fixture.spawner.calls().isEmpty)
    }

    /// **The discriminating half.** `stop()` is shutdown, and a proxy outliving
    /// its daemon is the point of a separate process: the next daemon adopts it
    /// back through the port in the config row. A `stop()` that retired would
    /// end every session's route on every daemon restart.
    @Test("stop leaves the proxy running")
    func stopDoesNotRetire() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 6130, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        try await fixture.db.config.setModelProxyEnabled(true)
        fixture.identity.admit(pid: 6130, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor()
        await supervisor.startIfEnabled()
        await supervisor.stop()

        #expect(proxy.requests().allSatisfy { $0.path != "/tbd/retire" })
        #expect(await supervisor.current?.pid == 6130, "shutdown keeps the proxy it adopted")
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
    ///
    /// This is the **nobody-routed** branch of the port wait's gate, which is
    /// why it still mints at once: `routedSessionsAlive` defaults to "none", so
    /// a fresh port strands nothing. `refusedBindIsRetriedWhileASessionIsRouted`
    /// is the other branch, where the same refused bind is waited out instead.
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

    // MARK: - The port wait

    /// **The port wait's whole reason** (spec, "Port"): a port a routed session
    /// carries in its `ANTHROPIC_BASE_URL` is not this daemon's to give up
    /// while something transient holds it.
    ///
    /// Before this behaviour existed the sequence below spawned twice — once on
    /// the persisted port, then immediately on zero — and rewrote the column, so
    /// every session already routed against the old port spent Claude's
    /// 183-second retry budget on a refused connect and failed its turn. The
    /// discriminating observable is therefore the spawner's call list: it must
    /// read `[deadPort, deadPort, deadPort]` and never contain a zero, and the
    /// column must still name the port it named at the start.
    ///
    /// `deadPort` is a privileged number, so the production `LoopbackPortProbe`
    /// the fixture delegates to answers `.refused` there through the real
    /// syscalls — a transient holder, which is what the wait is for.
    ///
    /// **The clock handshake.** `start()` does not return until the wait does,
    /// so it runs in a task of its own and each hop is a
    /// `requireAdvanceWhenArmed`. Exactly one sleeper can be in the ledger at
    /// each hop: `start()` has not created the watch yet, and the wait's own
    /// `clock.sleep` is the only one on this path.
    @Test("a bind refused on the persisted port is retried on the clock and the port kept")
    func refusedBindIsRetriedWhileASessionIsRouted() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }
        let clock = EventDrivenTestClock()

        try await fixture.db.config.setModelProxyPort(SupervisorFixture.deadPort)
        await fixture.spawner.answer(.failure(.bindFailed(port: SupervisorFixture.deadPort)))
        await fixture.spawner.answer(.failure(.bindFailed(port: SupervisorFixture.deadPort)))
        await fixture.spawner.answer(.success(pid: 7301, port: SupervisorFixture.deadPort))

        let supervisor = fixture.supervisor(routedSessionsAlive: { true }, clock: clock)
        let starting = Task { await supervisor.start() }
        defer { starting.cancel() }
        try await clock.requireAdvanceWhenArmed(by: ModelProxySupervisor.defaultPortRetryInterval)
        try await clock.requireAdvanceWhenArmed(by: ModelProxySupervisor.defaultPortRetryInterval)
        await starting.value
        await supervisor.stop()

        #expect(
            await fixture.spawner.calls() == [
                SupervisorFixture.deadPort, SupervisorFixture.deadPort, SupervisorFixture.deadPort,
            ],
            "every attempt asks for the port the routed sessions already carry")
        let current = await supervisor.current
        #expect(current?.port == SupervisorFixture.deadPort)
        #expect(current?.pid == 7301)
        #expect(
            try await fixture.db.config.get().modelProxyPort == SupervisorFixture.deadPort,
            "a port that was waited out and taken back is never rewritten")
    }

    /// The wait is bounded, and the bound is the other half of the claim: a
    /// holder that never lets go must not keep this home unproxied forever.
    ///
    /// A short `portRetryAttempts` so the budget is reached in three hops
    /// rather than fifteen. The verdict is that the mint happens **once** —
    /// a give-up that fell back into the retry loop, or a loop that minted on
    /// every pass, would show more than one zero in the call list.
    @Test("a refusal that never clears mints after the budget and rewrites the column once")
    func refusedBindGivesUpAfterTheBudget() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }
        let clock = EventDrivenTestClock()

        try await fixture.db.config.setModelProxyPort(SupervisorFixture.deadPort)
        for _ in 0..<4 {
            await fixture.spawner.answer(.failure(.bindFailed(port: SupervisorFixture.deadPort)))
        }
        await fixture.spawner.answer(.success(pid: 7311, port: SupervisorFixture.otherDeadPort))

        let supervisor = fixture.supervisor(
            routedSessionsAlive: { true }, portRetryAttempts: 3, clock: clock)
        let starting = Task { await supervisor.start() }
        defer { starting.cancel() }
        for _ in 0..<3 {
            try await clock.requireAdvanceWhenArmed(
                by: ModelProxySupervisor.defaultPortRetryInterval)
        }
        await starting.value
        await supervisor.stop()

        let calls = await fixture.spawner.calls()
        #expect(
            calls == [
                SupervisorFixture.deadPort, SupervisorFixture.deadPort,
                SupervisorFixture.deadPort, SupervisorFixture.deadPort, 0,
            ],
            "the budgeted attempts all ask for the old port, and only the last mints")
        #expect(calls.filter { $0 == 0 }.count == 1, "the mint happens once, not once per pass")
        #expect(
            try await fixture.db.config.get().modelProxyPort == SupervisorFixture.otherDeadPort,
            "giving up overwrites the column with the port that was actually taken")
    }

    /// The shipped window, pinned because its **product** is what has to sit
    /// between two other numbers.
    ///
    /// 2 s × 15 = 30 s. Claude retries a refused base URL for 183 s (spec,
    /// "Failure semantics"), and the worst path that reaches a respawn is the
    /// hang ladder — four missed polls (60 s), `hangSignalKillDelay` ticks
    /// (30 s), one more tick to notice the kill (15 s) = 105 s, which
    /// `hungProxyEscalatesToSignalsThenRespawns` pins from the other end.
    /// 105 + 30 = 135 s, leaving roughly 45 s for the spawn itself and a watch
    /// tick. Widening either constant without redoing that arithmetic is how
    /// the wait starts outliving the budget it exists to fit inside.
    @Test("the shipped port wait fits inside Claude's retry budget")
    func portWaitDefaultsFitTheRetryBudget() {
        #expect(ModelProxySupervisor.defaultPortRetryInterval == .seconds(2))
        #expect(ModelProxySupervisor.defaultPortRetryAttempts == 15)
    }

    /// A listener is not a transient, and the wait must not spend its whole
    /// window on one.
    ///
    /// The occupant here is a real HTTP listener that answers a real status
    /// document naming **another TBD home** — every other field is a live,
    /// same-version proxy, so only the identity check refuses it. It accepts
    /// connections, so it will still be there in thirty seconds.
    ///
    /// Two observables discriminate. Before this behaviour the call list read
    /// `[proxy.port, 0]` with no wait at all; a wait that could not tell a
    /// listener from a transient would need fifteen hops and thirty seconds of
    /// virtual time. This takes exactly one interval and one extra attempt.
    @Test("a foreign listener is given up after two sightings, not the whole budget")
    func foreignListenerIsGivenUpAfterTwoSightings() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }
        let clock = EventDrivenTestClock()

        let elsewhere = fixture.root.appendingPathComponent("another-install")
        let proxy = try ForeignHomeProxyProcess(
            version: fixture.ownVersion, pid: 7320, home: elsewhere.path)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        await fixture.spawner.answer(.failure(.bindFailed(port: proxy.port)))
        await fixture.spawner.answer(.failure(.bindFailed(port: proxy.port)))
        await fixture.spawner.answer(.success(pid: 7321, port: SupervisorFixture.otherDeadPort))

        let supervisor = fixture.supervisor(routedSessionsAlive: { true }, clock: clock)
        let starting = Task { await supervisor.start() }
        defer { starting.cancel() }
        try await clock.requireAdvanceWhenArmed(by: ModelProxySupervisor.defaultPortRetryInterval)
        await starting.value
        await supervisor.stop()

        #expect(
            await fixture.spawner.calls() == [proxy.port, proxy.port, 0],
            "two sightings, then the mint")
        #expect(
            try await fixture.db.config.get().modelProxyPort == SupervisorFixture.otherDeadPort)
        #expect(
            clock.now.offset == ModelProxySupervisor.defaultPortRetryInterval,
            "one interval of virtual time, not the whole window")
    }

    /// **Adoption keeps the first word.** A refused bind whose occupant passes
    /// the identity check is this home's own proxy — one that came up between
    /// the failed bind and the probe — and it is taken over with no wait and no
    /// mint.
    ///
    /// The startup probe is denied once so the spawn is reached at all, exactly
    /// as `lockHeldProbesAndAdopts` does; the second check admits. This
    /// discriminates against a wait that concluded "foreign listener" from an
    /// accepted connect without letting adoption answer first: that shape would
    /// count the daemon's own proxy as a stranger and eventually mint past it.
    ///
    /// That there is no wait is not asserted through the clock but through the
    /// call itself: `start()` returns without the test ever advancing virtual
    /// time, and a wait would have parked it on this clock indefinitely.
    @Test("an occupant that passes identity is adopted without a wait")
    func refusedBindAdoptsAnOccupantThatPassesIdentity() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }
        let clock = EventDrivenTestClock()

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 7330, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.denyOnce()
        fixture.identity.admit(pid: 7330, startTime: proxy.processStartTime)
        await fixture.spawner.answer(.failure(.bindFailed(port: proxy.port)))

        let supervisor = fixture.supervisor(routedSessionsAlive: { true }, clock: clock)
        await supervisor.start()
        await supervisor.stop()

        let current = await supervisor.current
        #expect(current?.pid == 7330)
        #expect(current?.adopted == true)
        #expect(await fixture.spawner.calls() == [proxy.port], "no second spawn, and no mint")
        #expect(try await fixture.db.config.get().modelProxyPort == proxy.port)
    }

    /// The other branch of the wait's gate: with nothing routed against the
    /// port, nothing is stranded by a fresh one, so the wait is not paid at all.
    ///
    /// This is `remintsPortWhenHeldByStranger` said the other way round — that
    /// one takes the default `routedSessionsAlive`, this one is explicit about
    /// which fact does the work — and it is what keeps the wait from delaying
    /// every boot and every Settings toggle on an install with no proxied
    /// session running. `start()` returning with virtual time never advanced is
    /// the proof that nothing slept.
    @Test("with no session routed a refused bind mints at once")
    func refusedBindMintsAtOnceWithNothingRouted() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }
        let clock = EventDrivenTestClock()

        try await fixture.db.config.setModelProxyPort(SupervisorFixture.deadPort)
        await fixture.spawner.answer(.failure(.bindFailed(port: SupervisorFixture.deadPort)))
        await fixture.spawner.answer(.success(pid: 7351, port: SupervisorFixture.otherDeadPort))

        let supervisor = fixture.supervisor(routedSessionsAlive: { false }, clock: clock)
        await supervisor.start()
        await supervisor.stop()

        #expect(await fixture.spawner.calls() == [SupervisorFixture.deadPort, 0])
        #expect(
            try await fixture.db.config.get().modelProxyPort == SupervisorFixture.otherDeadPort)
        #expect(clock.now.offset == .zero, "no interval was waited")
    }

    /// A probe that cannot say who holds the port — a listener whose backlog is
    /// full, or an errno that is neither success nor `ECONNREFUSED` — is
    /// treated as a transient and waited out.
    ///
    /// The conservative direction is the claim: waiting out a listener costs a
    /// delayed mint, while minting past a transient strands live sessions. A
    /// classification that folded `.undetermined` in with `.accepted` would
    /// give the port up after two probes instead of keeping it.
    @Test("an undetermined probe is waited out like a refusal")
    func undeterminedProbeIsWaitedOut() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }
        let clock = EventDrivenTestClock()
        fixture.portProbe.force(.undetermined("no answer within 1s"))

        try await fixture.db.config.setModelProxyPort(SupervisorFixture.deadPort)
        await fixture.spawner.answer(.failure(.bindFailed(port: SupervisorFixture.deadPort)))
        await fixture.spawner.answer(.success(pid: 7361, port: SupervisorFixture.deadPort))

        let supervisor = fixture.supervisor(routedSessionsAlive: { true }, clock: clock)
        let starting = Task { await supervisor.start() }
        defer { starting.cancel() }
        try await clock.requireAdvanceWhenArmed(by: ModelProxySupervisor.defaultPortRetryInterval)
        await starting.value
        await supervisor.stop()

        #expect(
            await fixture.spawner.calls()
                == [SupervisorFixture.deadPort, SupervisorFixture.deadPort])
        #expect(await supervisor.current?.pid == 7361)
        #expect(try await fixture.db.config.get().modelProxyPort == SupervisorFixture.deadPort)
    }

    /// **A version replacement goes through the wait too.** `POST /tbd/retire`
    /// answers the moment the listener is closed and the lock is released, and
    /// the successor binds right behind it — which is precisely the gap in
    /// which the freed ephemeral number can be handed to an unrelated client
    /// socket. Minting there would strand every session the retiring proxy was
    /// serving, which is the population this whole path exists for.
    ///
    /// The fake keeps listening after the retire (it is an HTTP server, not a
    /// proxy), so the port probe is forced to `.refused` to stand in for the
    /// closed listener; a refused connect never reaches the status endpoint, so
    /// the still-listening fake cannot be re-adopted behind the failed bind.
    @Test("a version replace goes through the port wait")
    func versionReplaceWaitsForThePort() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }
        let clock = EventDrivenTestClock()
        fixture.portProbe.force(.refused)

        let proxy = try FakeProxyProcess(version: "9999-1", pid: 7340, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 7340, startTime: proxy.processStartTime)
        await fixture.spawner.answer(.failure(.bindFailed(port: proxy.port)))
        await fixture.spawner.answer(.success(pid: 7341, port: proxy.port))

        let supervisor = fixture.supervisor(routedSessionsAlive: { true }, clock: clock)
        let starting = Task { await supervisor.start() }
        defer { starting.cancel() }
        try await clock.requireAdvanceWhenArmed(by: ModelProxySupervisor.defaultPortRetryInterval)
        await starting.value
        await supervisor.stop()

        #expect(
            proxy.requests().contains { $0.method == "POST" && $0.path == "/tbd/retire" },
            "the mismatched proxy is still asked to retire")
        #expect(
            await fixture.spawner.calls() == [proxy.port, proxy.port],
            "the successor waits for the port rather than minting past it")
        #expect(await supervisor.current?.pid == 7341)
        #expect(try await fixture.db.config.get().modelProxyPort == proxy.port)
    }

    /// `.lockHeld` says a live proxy owns this rendezvous. The supervisor
    /// probes rather than replaces — and it must never unlink the lock.
    @Test("a held lock sends the supervisor to probe the port, and it adopts what answers")
    func lockHeldProbesAndAdopts() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 6060, home: fixture.home)
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

        let proxy = try FakeProxyProcess(version: "9999-1", pid: 7070, home: fixture.home)
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

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 7080, home: fixture.home)
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
    ///
    /// **It is also the suite's only two-hop test, and that is why it runs on
    /// `EventDrivenTestClock` while its siblings stay on `TestClock`.** The
    /// second sleep is armed *inside* `respawn`, after a spawn attempt that has
    /// already failed — a fire-then-re-arm, which `Tests/CLAUDE.md`
    /// ("Re-arming") names as the sharp edge of every clock handshake. On
    /// `TestClock` the re-arm can only be observed by polling
    /// `checkSuspension()`, whose `megaYield` is 20 serially-awaited
    /// background-QoS tasks; under the fast parallel pass that probe competes
    /// with the very task it is waiting for, and this test reddened three
    /// consecutive CI dispatches of one SHA having observed exactly **one**
    /// clock advance in 170 s — the first hop landed and the second never found
    /// the re-armed sleeper. `EventDrivenTestClock` signals arming from inside
    /// the critical section that registers the sleeper, so
    /// `requireAdvanceWhenArmed` parks on a continuation instead of racing a
    /// probe loop, and each hop advances only once the sleep it is meant to fire
    /// is provably in the ledger. Strict (`require`) rather than soft, because
    /// the chain is only sound step by step: a missed arming throws before
    /// virtual time moves, instead of desyncing the ledger and hanging later
    /// with no attribution.
    ///
    /// The verdict is the spawn count and the ports it was asked for. Advancing
    /// on this clock does not run the resumed task's code, so the assertion
    /// waits on the observable — never on elapsed time.
    ///
    /// **What hop 2 relies on, for whoever changes `tick` next.** The second
    /// advance is sound only because exactly one sleeper can be in the ledger
    /// when it fires: the watch loop does not re-arm its interval until `tick`
    /// returns, `tick` does not return until `respawn` does, and `respawn`'s
    /// backoff is the only `clock.sleep` on that path. So "a sleep was armed"
    /// and "the first respawn attempt has happened" are the same fact here, and
    /// the advance cannot land on the wrong sleeper. Add a second `clock.sleep`
    /// anywhere reachable from `tick` — a poll, a debounce, a settle — and that
    /// stops being true: `requireAdvanceWhenArmed` would fire on whichever
    /// sleeper armed first, and this test would start passing or hanging for
    /// reasons that have nothing to do with the backoff.
    @Test("a proxy that exits is reaped and respawned after the backoff")
    func respawnsAfterDeath() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }
        let clock = EventDrivenTestClock()
        let spawner = fixture.spawner

        await spawner.answer(.success(pid: 800, port: SupervisorFixture.deadPort))
        let supervisor = fixture.supervisor(clock: clock)
        await supervisor.start()
        #expect(await supervisor.current?.pid == 800)

        // The child exits; the first respawn attempt fails transiently and the
        // second succeeds.
        await spawner.reap(pid: 800, status: 0)
        await spawner.answer(.failure(.launchFailed(errno: EAGAIN)))
        await spawner.answer(.success(pid: 801, port: SupervisorFixture.deadPort))

        // Hop 1: the watch interval. The tick it fires collects the dead child
        // and burns the immediate respawn attempt.
        try await clock.requireAdvanceWhenArmed(by: fixture.watchInterval)
        // Hop 2: the backoff sleep `respawn` arms after that attempt failed.
        // Nothing else can be in the ledger here — the watch does not re-arm
        // its interval until `tick` returns, and `tick` does not return until
        // `respawn` does — so the wait landing is itself the proof that the
        // first attempt happened.
        try await clock.requireAdvanceWhenArmed(by: fixture.firstBackoff)

        let landed = try await waitFor(
            "the successor to be recorded",
            observed: { "spawn calls \(await spawner.calls())" },
            { await supervisor.current?.pid == 801 })
        await supervisor.stop()

        #expect(landed)
        #expect(
            await spawner.calls()
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

    // MARK: - Hang detection

    /// The discriminating half of the ladder below: three consecutive misses
    /// is one short of `hangSignalThreshold`, and a poll that then succeeds
    /// must reset the count rather than let it carry into a later hang
    /// episode.
    ///
    /// On `EventDrivenTestClock` for the reason the ladder below spells out:
    /// this is a re-arming poller chain, and every advance after the first has
    /// to wait for the sleep the previous tick armed on its way out.
    @Test("three misses then a successful poll sends no signal")
    func threeMissesThenASuccessSendsNoSignal() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }
        let clock = EventDrivenTestClock()

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 6300, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 6300, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor(clock: clock)
        await supervisor.start()
        #expect(await supervisor.current?.pid == 6300)

        // Three misses, and no more: three is below the threshold on any
        // reading, so there is no positive outcome to converge on here — the
        // count is fixed and each step waits for the arming that makes it
        // sound.
        proxy.failNextStatusResponses(3)
        for _ in 1...3 {
            try await clock.requireAdvanceWhenArmed(by: fixture.watchInterval)
        }
        // The re-arm after the third tick is the proof that tick finished, so
        // the absence below is an observation rather than a guess about
        // whether the tick had run yet.
        try await clock.requireSleeperArmed()
        #expect(
            fixture.signaller.terminated().isEmpty,
            "three misses is one short of the four-poll threshold")

        // The fourth poll succeeds (the fake's fail count is exhausted). A
        // signal now would be the count carrying across the reset rather than
        // restarting from it.
        try await clock.requireAdvanceWhenArmed(by: fixture.watchInterval)
        try await clock.requireSleeperArmed()
        #expect(fixture.signaller.terminated().isEmpty)
        #expect(fixture.signaller.killed().isEmpty)
        #expect(await supervisor.current?.pid == 6300)

        await supervisor.stop()
    }

    /// The full ladder the fix adds: a proxy the process table still
    /// confirms but that stops answering is SIGTERMed once four consecutive
    /// polls miss, SIGKILLed if it is still alive two ticks after that, and
    /// respawned on the same port once it is actually gone — the same
    /// "gone" path a pid the process table no longer confirms always took.
    ///
    /// Discriminates against the pre-fix code, which had no path from
    /// "alive but unresponsive" to a signal at all: `tick`'s poll-failure
    /// branch only ever consulted the process table, so a merely-hung proxy
    /// (as opposed to one truly gone) was kept forever.
    ///
    /// **Why this runs on `EventDrivenTestClock`, and what the mechanism was.**
    /// The watch is a fire-then-re-arm loop — `tick` runs, returns, and only
    /// then does `watch` arm the next `clock.sleep(for: watchInterval)` — so
    /// every advance in this ladder past the first is a re-arm, the shape
    /// `Tests/CLAUDE.md` ("Re-arming") names as the sharp edge of every clock
    /// handshake. On `TestClock` the only way to observe a re-arm is
    /// `checkSuspension()`, whose `megaYield` is 20 serially-awaited
    /// background-QoS tasks; the `advanceUntil` loop this test used ran that
    /// probe every 25 ms, so under the saturated fast pass it flooded the
    /// cooperative pool with exactly the low-priority work the watch task
    /// needed a turn from, and starved the thing it was waiting for. Field
    /// signature: this test reddened on a rerun of an unrelated PR (run
    /// 34279779589 attempt 3) having observed **one** clock advance in 45 s —
    /// the first tick landed and the second re-arm was never seen. Nothing
    /// about the ladder was slow: the fake answers a miss with a prompt 500,
    /// and `ModelProxyClient`'s two-second budget is a `URLSession` deadline
    /// that no test clock touches.
    ///
    /// So each step here advances only once the sleep it is meant to fire is
    /// provably in the ledger, and `EventDrivenTestClock` signals that arming
    /// from inside the critical section that registers the sleeper rather than
    /// racing a probe loop. Strict (`require`) rather than soft, because the
    /// chain is sound only step by step: a missed arming throws before virtual
    /// time moves, instead of desyncing the ledger and hanging later with no
    /// attribution — and one throw ends the chain, so a failing run pays one
    /// hang guard rather than one per wait.
    ///
    /// **Advancing on this clock does not run the resumed task's post-sleep
    /// code**, so every assertion below is preceded by the wait that proves the
    /// tick it is about has finished: the re-arm. `requireSleeperArmed` after
    /// the last advance of a group is that proof, and the verdict is always
    /// what the signaller recorded and what the spawner was asked for — never
    /// elapsed real time.
    ///
    /// **What the chain relies on, for whoever changes `tick` next**: exactly
    /// one sleeper can be in the ledger at each step. `watch` does not re-arm
    /// until `tick` returns, and no path this test walks reaches a second
    /// `clock.sleep` — the respawn at the end succeeds on its immediate
    /// attempt, so `respawn`'s backoff never arms. Add another sleep reachable
    /// from `tick` and these waits could land on the wrong sleeper.
    @Test("a hung proxy is SIGTERMed at four misses, SIGKILLed two ticks later, and respawned once gone")
    func hungProxyEscalatesToSignalsThenRespawns() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }
        let clock = EventDrivenTestClock()

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 6302, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 6302, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor(clock: clock)
        await supervisor.start()
        #expect(await supervisor.current?.pid == 6302)

        // Wide enough to cover every tick below without exhausting — this
        // proxy never recovers in this test.
        proxy.failNextStatusResponses(20)

        // Four ticks, four consecutive misses: the fourth crosses
        // `hangSignalThreshold` and sends SIGTERM from inside `tick`.
        for _ in 1...4 {
            try await clock.requireAdvanceWhenArmed(by: fixture.watchInterval)
        }
        try await clock.requireSleeperArmed()
        #expect(
            fixture.signaller.terminated() == [6302],
            "the fourth consecutive miss crosses hangSignalThreshold")
        #expect(fixture.signaller.killed().isEmpty, "SIGKILL waits for hangSignalKillDelay more ticks")
        #expect(
            await supervisor.current?.pid == 6302,
            "still the same live proxy — sending a signal does not itself drop it")

        // `hangSignalKillDelay` more misses, and the second of them escalates.
        for _ in 1...2 {
            try await clock.requireAdvanceWhenArmed(by: fixture.watchInterval)
        }
        try await clock.requireSleeperArmed()
        #expect(fixture.signaller.killed() == [6302])
        #expect(fixture.signaller.terminated() == [6302], "still exactly one SIGTERM, never repeated")
        #expect(
            await supervisor.current?.pid == 6302,
            "the process table still confirms it; nothing respawns until it is actually gone")

        // The kill lands: the process is now gone from the table, which is
        // the same fact that drives the ordinary death path.
        fixture.identity.forget(pid: 6302)
        await fixture.spawner.answer(.success(pid: 6303, port: proxy.port))
        try await clock.requireAdvanceWhenArmed(by: fixture.watchInterval)
        try await clock.requireSleeperArmed()
        #expect(
            await supervisor.current?.pid == 6303,
            "the hung proxy is respawned once the process table stops confirming it")
        #expect(
            await fixture.spawner.calls() == [proxy.port],
            "the respawn targets the port the hung proxy held")

        await supervisor.stop()
    }

    /// **The end of the hang ladder is the case the port wait was written
    /// for.** A SIGKILLed proxy frees its port abruptly, and macOS hands
    /// ephemeral numbers out sequentially from one counter, so the number is
    /// routinely re-handed to a short-lived client socket before the successor
    /// binds. Minting there strands every session the killed proxy was serving
    /// — the population the ladder took 105 seconds to reach.
    ///
    /// The ladder above is walked verbatim up to the kill landing; from there
    /// the respawn meets a refused bind. The port probe is *forced* to
    /// `.refused` rather than the fake being stopped: the fake's port is an
    /// ephemeral number and a suite running in parallel could be handed it,
    /// which would make the real probe answer `.accepted` for a stranger's
    /// listener and turn this into the foreign-listener case.
    ///
    /// Two hops, and only one sleeper can be in the ledger at each. The first
    /// is the watch interval, whose tick notices the kill and burns the refused
    /// bind; the second is the wait's own sleep, and the watch cannot have
    /// re-armed because it does not do so until `tick` returns. Before this
    /// behaviour the call list read `[proxy.port, 0]`.
    @Test("the hang ladder's respawn goes through the port wait")
    func hangLadderRespawnWaitsForThePort() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }
        let clock = EventDrivenTestClock()
        // Named here rather than reached through `fixture` below: the
        // `observed:` closure is `@Sendable`, and the actor is what it needs.
        let spawner = fixture.spawner

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 6310, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 6310, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor(routedSessionsAlive: { true }, clock: clock)
        await supervisor.start()
        #expect(await supervisor.current?.pid == 6310)

        proxy.failNextStatusResponses(20)
        // Four misses to SIGTERM, `hangSignalKillDelay` more to SIGKILL.
        for _ in 1...6 {
            try await clock.requireAdvanceWhenArmed(by: fixture.watchInterval)
        }
        try await clock.requireSleeperArmed()
        #expect(fixture.signaller.killed() == [6310], "the ladder reached SIGKILL")

        // The kill lands: the process leaves the table, its listener is gone,
        // and something transient has the number.
        fixture.portProbe.force(.refused)
        fixture.identity.forget(pid: 6310)
        await fixture.spawner.answer(.failure(.bindFailed(port: proxy.port)))
        await fixture.spawner.answer(.success(pid: 6311, port: proxy.port))

        // Hop 1: the tick that notices the kill and burns the refused bind.
        try await clock.requireAdvanceWhenArmed(by: fixture.watchInterval)
        // Hop 2: the port wait's own sleep, the only sleeper on this path.
        try await clock.requireAdvanceWhenArmed(by: ModelProxySupervisor.defaultPortRetryInterval)

        let landed = try await waitFor(
            "the successor to take the port back",
            observed: { "spawn calls \(await spawner.calls())" },
            { await supervisor.current?.pid == 6311 })
        await supervisor.stop()

        #expect(landed)
        #expect(
            await fixture.spawner.calls() == [proxy.port, proxy.port],
            "the killed proxy's port is waited out, never minted past")
        #expect(try await fixture.db.config.get().modelProxyPort == proxy.port)
    }

    /// The identity re-check right before every signal is what this pins: a
    /// pid the kernel has recycled to an unrelated process — a different
    /// start time answering where the daemon's anchor expects the old one —
    /// must never be signalled, whatever `consecutiveHungPolls` says. It is
    /// the ordinary "gone" path (`processIdentity.matches` failing against
    /// the poll-failure branch's anchor) that respawns it, immediately, with
    /// no signal in between.
    ///
    /// One tick, but on `EventDrivenTestClock` with the ladder above: the
    /// replacement happens *inside* that tick, so the re-arm after it is what
    /// makes the assertions below readable off the observables rather than off
    /// a real-time poll.
    @Test("a recycled pid takes the immediate respawn path, never a signal")
    func recycledPidRespawnsWithoutSignalling() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }
        let clock = EventDrivenTestClock()

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 6304, home: fixture.home)
        defer { proxy.stop() }
        try await fixture.db.config.setModelProxyPort(proxy.port)
        fixture.identity.admit(pid: 6304, startTime: proxy.processStartTime)

        let supervisor = fixture.supervisor(clock: clock)
        await supervisor.start()
        #expect(await supervisor.current?.pid == 6304)

        // The poll fails, and by the time the process table is consulted for
        // the pid this daemon remembers, the kernel has recycled it to an
        // unrelated process with a different start time.
        proxy.failNextStatusResponses(1)
        fixture.identity.admit(pid: 6304, startTime: proxy.processStartTime.addingTimeInterval(500))
        await fixture.spawner.answer(.success(pid: 6305, port: proxy.port))

        try await clock.requireAdvanceWhenArmed(by: fixture.watchInterval)
        try await clock.requireSleeperArmed()
        #expect(
            await supervisor.current?.pid == 6305,
            "the recycled pid is replaced on the tick that noticed it")
        #expect(fixture.signaller.terminated().isEmpty, "a recycled pid must never be signalled")
        #expect(fixture.signaller.killed().isEmpty)
        #expect(
            await fixture.spawner.calls() == [proxy.port],
            "the mismatch takes the immediate respawn path, not the hang ladder")

        await supervisor.stop()
    }

    /// An **adopted** proxy is not this daemon's child, so `waitpid` can never
    /// collect it: its death is read off the process table instead. The
    /// supervisor spawns a replacement on the port it held.
    @Test("an adopted proxy that leaves the process table is replaced")
    func replacesAnAdoptedProxyThatDied() async throws {
        let fixture = try SupervisorFixture.make()
        defer { fixture.tearDown() }

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 9090, home: fixture.home)
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

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 8080, home: fixture.home)
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
        let proxy = try FakeProxyProcess(version: "9999-1", pid: 7075, home: fixture.home)
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

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 9100, home: fixture.home)
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

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 4040, home: fixture.home)
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

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 3030, home: fixture.home)
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

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 3031, home: fixture.home, routeStatus: 500)
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

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 3032, home: fixture.home)
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

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 3033, home: fixture.home)
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

        let proxy = try FakeProxyProcess(version: fixture.ownVersion, pid: 3034, home: fixture.home)
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
    let signaller: StubSignaller
    let portProbe: StubPortProbe
    let clock: TestClock<Duration>
    let ownVersion = "12345-1700000000"
    let watchInterval: Duration = .seconds(15)
    /// The first step of the respawn backoff, named rather than repeated so a
    /// test that has to advance THROUGH it cannot pick a different number from
    /// the one the supervisor sleeps on.
    let firstBackoff: Duration = .seconds(1)

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
            signaller: StubSignaller(),
            portProbe: StubPortProbe(),
            clock: TestClock())
    }

    /// The control client is the **real** one, on whatever port the supervisor
    /// asks for: a fake proxy binds a real loopback port and the config row
    /// names it, so nothing has to be redirected for the client to reach it —
    /// and a probe of a port with no listener fails for the real reason.
    ///
    /// `clock` defaults to this fixture's `TestClock`; a test whose handshake
    /// with the watch is more than one hop passes an `EventDrivenTestClock`
    /// instead — see `respawnsAfterDeath` for why that is not a blanket
    /// migration.
    /// `routedSessionsAlive` answers "no session is routed" unless a case says
    /// otherwise, which is the answer that makes a flag-off boot run nothing —
    /// the shipped install.
    func supervisor(
        routedSessionsAlive: @escaping @Sendable () async -> Bool = { false },
        clientFactory: @escaping @Sendable (Int) -> ModelProxyClient = {
            ModelProxyClient(port: $0)
        },
        portRetryAttempts: Int = ModelProxySupervisor.defaultPortRetryAttempts,
        clock overrideClock: (any Clock<Duration>)? = nil
    ) -> ModelProxySupervisor {
        ModelProxySupervisor(
            config: db.config,
            home: home,
            spawner: spawner,
            ownVersion: ownVersion,
            processIdentity: identity,
            signaller: signaller,
            portProbe: portProbe,
            routedSessionsAlive: routedSessionsAlive,
            clientFactory: clientFactory,
            watchInterval: watchInterval,
            respawnBackoff: [firstBackoff, .seconds(5)],
            portRetryAttempts: portRetryAttempts,
            clock: overrideClock ?? clock)
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

    /// Overwrites `<home>/proxy/proxy.pid` with a record of this test's
    /// choosing — the rendezvous half of adoption, for the cases that must be
    /// refused because it disagrees with what answered.
    func publishPidFile(pid: Int32, port: Int) throws {
        try FileManager.default.createDirectory(
            at: paths.proxyDir, withIntermediateDirectories: true)
        try Data("\(pid)\n\(port)\n".utf8)
            .write(to: URL(fileURLWithPath: paths.pidPath), options: [.atomic])
    }

    /// What that file currently says, read through the production parser.
    func readPidFile() -> ModelProxyPIDFileRecord? {
        ModelProxyPIDFile().read(path: paths.pidPath)
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

/// The port probe, **real by default**.
///
/// Delegating to the production `LoopbackPortProbe` is what keeps the ordinary
/// cases honest: `SupervisorFixture.deadPort` is a privileged number nothing in
/// a test runner can be listening on, so it is a prompt `ECONNREFUSED` through
/// the same syscalls the daemon makes, and a `FakeProxyProcess` is a real
/// listener on a real loopback port that answers `.accepted` for the same
/// reason a stranger's proxy would.
///
/// A forced answer is for the one shape that cannot be arranged honestly: a
/// case whose port is an *ephemeral* number a fake has just released, which a
/// suite running in parallel could be handed in the meantime. There the port's
/// real occupancy is nobody's to predict, and the fact under test is what the
/// supervisor does with the answer rather than how it obtained it.
private final class StubPortProbe: LoopbackPortProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var forced: LoopbackPortOccupancy?

    func force(_ occupancy: LoopbackPortOccupancy) {
        lock.withLock { forced = occupancy }
    }

    func occupancy(port: Int) -> LoopbackPortOccupancy {
        if let answer = lock.withLock({ forced }) { return answer }
        return LoopbackPortProbe().occupancy(port: port)
    }
}

/// A `ProcessSignaller` that records what it was asked to signal instead of
/// touching a real process — the hang-detection tests' way of observing
/// `considerSignallingHungProxy` without sending a real `kill(2)`.
///
/// Only `terminateProcessOnly`/`forceKillProcessOnly` are implemented for
/// real: `ModelProxySupervisor` calls exactly those two, never the
/// process-group forms, so recording under the other names would observe a
/// call the supervisor never makes. Everything else this protocol requires
/// but the supervisor never calls (`isAlive`, `children`, `commandLine`,
/// `stat`, `startTime`) is a harmless stub.
private final class StubSignaller: ProcessSignaller, @unchecked Sendable {
    private let lock = NSLock()
    private var terminatedPids: [Int32] = []
    private var killedPids: [Int32] = []

    func terminated() -> [Int32] { lock.withLock { terminatedPids } }
    func killed() -> [Int32] { lock.withLock { killedPids } }

    func isAlive(_ pid: Int32) -> Bool { true }
    func terminate(_ pid: Int32) {}
    func forceKill(_ pid: Int32) {}
    func terminateProcessOnly(_ pid: Int32) { lock.withLock { terminatedPids.append(pid) } }
    func forceKillProcessOnly(_ pid: Int32) { lock.withLock { killedPids.append(pid) } }
    func children(ofServerPID serverPID: Int32) -> [Int32] { [] }
    func commandLine(_ pid: Int32) -> String? { nil }
    func stat(_ pid: Int32) -> String? { nil }
    func startTime(_ pid: Int32) -> Date? { nil }
}

/// A `TBDModelProxy`'s control endpoint and nothing else: it answers
/// `/tbd/status` with a document the daemon's decoder accepts, takes a retire
/// and both route verbs, and records everything that arrived.
///
/// **It also publishes a pid file**, because a real proxy does and adoption now
/// requires the two to agree (spec, "Adoption identity"). Publishing it here
/// rather than in each test keeps every existing adoption case describing one
/// honest proxy; the cases that must be *refused* corrupt the file on purpose,
/// through `publishPidFile`/`unpublishPidFile`.
private final class FakeProxyProcess: @unchecked Sendable {
    /// Sub-second on purpose: the status document carries microseconds, and a
    /// coder that rounded them away would make every adoption fail.
    private static let startedAt = Date(timeIntervalSince1970: 1_700_000_000.123_456)

    private let server: LoopbackHTTPTestServer
    private let pidBox: PidBox
    private let routeCountBox: IntBox
    private let statusHook: StatusHookBox
    private let holdRouteRegistration: IntBox
    private let failStatusResponses: IntBox
    private let paths: ProxyHomePaths
    let processStartTime = FakeProxyProcess.startedAt

    var port: Int { server.port }

    /// How many routes this proxy says it is serving.
    ///
    /// Mutable because the drain turns on exactly this number falling to zero
    /// while the supervisor watches, and the number belongs to the proxy: the
    /// daemon never counts routes itself, it asks.
    func setRouteCount(_ count: Int) { routeCountBox.value = count }

    /// Fires **once**, on the server thread, after the next `/tbd/status`
    /// document has been composed and before it is written back.
    ///
    /// It is how a test opens the window every drain race lives in. The
    /// supervisor is suspended awaiting exactly this response, so the actor is
    /// free to service anything else, and whatever this closure does — the flag
    /// coming back on, a route being minted, the proxy being replaced — lands
    /// strictly between the poll and the decision the answer feeds. A blocking
    /// hand-off rather than a detached `Task`, because a race arranged by
    /// scheduling luck is not a test.
    func onNextStatus(_ body: @escaping @Sendable () -> Void) { statusHook.arm(body) }

    /// Holds the next `POST /tbd/routes` open and unanswered, **without**
    /// blocking the accept loop — the handler returns `nil` for it, which
    /// `LoopbackHTTPTestServer` treats as "keep this connection, answer
    /// nothing", the same mechanism `aSilentProxyTimesOut` uses for a wedged
    /// proxy. That is what makes it useful here and not merely another hold:
    /// the server is free to accept and answer a concurrent `/tbd/status`
    /// poll while this connection sits open, which is exactly the window a
    /// `makeRoute` suspended on `addRoute` leaves for a concurrent drain
    /// check to run in. One-shot, like `onNextStatus`.
    func holdNextRouteRegistration() { holdRouteRegistration.value = 1 }

    /// Makes the next `count` `/tbd/status` requests answer with a 500
    /// instead of a status document — a fast, deterministic stand-in for a
    /// proxy that is alive but not answering usefully (a hang), without the
    /// real-time uncertainty of a connection that genuinely times out. A
    /// count rather than a one-shot hook: the hang-detection ladder is driven
    /// by *consecutive* failures, so a test walking it sets a count wide
    /// enough to cover every tick it advances through.
    func failNextStatusResponses(_ count: Int) { failStatusResponses.value = count }

    /// Makes the listener answer for another process from now on — one port
    /// changing hands, which is what another daemon's replacement looks like
    /// from the supervisor's side. The pid file moves with it, as it does in
    /// life: the successor writes its own after binding.
    func becomePid(_ pid: Int32) {
        pidBox.value = pid
        try? publishPidFile(pid: pid, port: server.port)
    }

    /// Writes `<home>/proxy/proxy.pid` naming `pid` and `port`.
    func publishPidFile(pid: Int32, port: Int) throws {
        try FileManager.default.createDirectory(
            at: paths.proxyDir, withIntermediateDirectories: true)
        try Data("\(pid)\n\(port)\n".utf8)
            .write(to: URL(fileURLWithPath: paths.pidPath), options: [.atomic])
    }

    /// Removes it — a home whose proxy died without unlinking, or one that
    /// never wrote a file at all.
    func unpublishPidFile() {
        try? FileManager.default.removeItem(atPath: paths.pidPath)
    }

    init(
        version: String, pid: Int32, home: URL, routeStatus: Int = 200,
        routeCount: Int = 0, retireStatus: Int = 200
    ) throws {
        // The listener's port is not known until it is bound, so the status
        // document is composed per request out of a box the initializer fills
        // afterwards rather than baked into the handler.
        let portBox = IntBox()
        let pidBox = PidBox(pid)
        let routeCountBox = IntBox()
        routeCountBox.value = routeCount
        let statusHook = StatusHookBox()
        let holdRouteRegistration = IntBox()
        let failStatusResponses = IntBox()
        self.pidBox = pidBox
        self.routeCountBox = routeCountBox
        self.statusHook = statusHook
        self.holdRouteRegistration = holdRouteRegistration
        self.failStatusResponses = failStatusResponses
        self.paths = ProxyHomePaths(home: home)
        // Canonical, exactly as the real proxy reports it: the daemon compares
        // canonical forms, and a fake that echoed a raw path would make the
        // home check pass or fail for the wrong reason under a symlinked
        // scratch root (`/var` versus `/private/var` on Darwin).
        let servedHome = ModelProxyStatus.canonicalHome(home.path)
        let started = FakeProxyProcess.startedAt
        self.server = try LoopbackHTTPTestServer { request in
            if request.method == "DELETE", request.path.hasPrefix("/tbd/routes/") {
                return .ok("{}")
            }
            switch (request.method, request.path) {
            case ("GET", "/tbd/status"):
                if failStatusResponses.value > 0 {
                    failStatusResponses.value -= 1
                    return LoopbackHTTPTestServer.Reply(status: 500, body: "{}")
                }
                let document = ModelProxyStatus(
                    version: version, pid: pidBox.value, processStartTime: started,
                    port: portBox.value, streamsInFlight: 0,
                    routeCount: routeCountBox.value,
                    home: servedHome)
                guard let data = try? document.encodedForStatusResponse() else {
                    return LoopbackHTTPTestServer.Reply(status: 500, body: "{}")
                }
                // After the document is composed and before it is answered:
                // the world the supervisor is about to decide against moves
                // here, and only here.
                statusHook.fire()
                return .ok(String(decoding: data, as: UTF8.self))
            case ("POST", "/tbd/retire"):
                return LoopbackHTTPTestServer.Reply(status: retireStatus, body: "{}")
            case ("POST", "/tbd/routes"):
                if holdRouteRegistration.value == 1 {
                    holdRouteRegistration.value = 0
                    return nil
                }
                return LoopbackHTTPTestServer.Reply(status: routeStatus, body: "{}")
            default:
                return LoopbackHTTPTestServer.Reply(status: 404, body: "{}")
            }
        }
        portBox.value = server.port
        try publishPidFile(pid: pid, port: server.port)
    }

    func requests() -> [LoopbackHTTPTestServer.Request] { server.requests() }
    func stop() { server.stop() }
}

/// A `FakeProxyProcess` that reports somebody else's TBD home.
///
/// A separate listener rather than a flag on the one above, because the case it
/// exists for is a *different install* answering on this home's port: every
/// other field of its status is a real, live, same-version TBD proxy, and only
/// the home says otherwise.
private final class ForeignHomeProxyProcess: @unchecked Sendable {
    private let server: LoopbackHTTPTestServer
    let processStartTime = Date(timeIntervalSince1970: 1_700_000_000.123_456)

    var port: Int { server.port }

    init(version: String, pid: Int32, home: String) throws {
        let portBox = IntBox()
        let started = processStartTime
        // The empty string passes through uncanonicalized on purpose: it is
        // what an image older than the `home` field decodes to, and running it
        // through `canonicalHome` would turn "said nothing" into the process's
        // working directory — a different case with a different branch.
        let servedHome = home.isEmpty ? "" : ModelProxyStatus.canonicalHome(home)
        self.server = try LoopbackHTTPTestServer { request in
            guard request.method == "GET", request.path == "/tbd/status" else {
                return LoopbackHTTPTestServer.Reply(status: 404, body: "{}")
            }
            let document = ModelProxyStatus(
                version: version, pid: pid, processStartTime: started,
                port: portBox.value, streamsInFlight: 0, routeCount: 0, home: servedHome)
            guard let data = try? document.encodedForStatusResponse() else {
                return LoopbackHTTPTestServer.Reply(status: 500, body: "{}")
            }
            return .ok(String(decoding: data, as: UTF8.self))
        }
        portBox.value = server.port
    }

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

/// A one-shot closure the fake proxy runs from inside its status handler.
private final class StatusHookBox: @unchecked Sendable {
    private let lock = NSLock()
    private var body: (@Sendable () -> Void)?

    func arm(_ body: @escaping @Sendable () -> Void) {
        lock.withLock { self.body = body }
    }

    /// Runs the armed closure and disarms it, so a hook set for one poll cannot
    /// fire on the watch tick behind it.
    func fire() {
        let armed: (@Sendable () -> Void)? = lock.withLock {
            let armed = body
            body = nil
            return armed
        }
        armed?()
    }
}

/// Runs `body` and blocks the calling thread until it finishes.
///
/// Only ever called from a `FakeProxyProcess` status hook, and the thread it
/// blocks is the fake server's own accept thread — never a cooperative one, so
/// the *holding* side needs nothing (`Tests/CLAUDE.md`, "Thread-blocking gates
/// run off the cooperative pool"). The actor `body` talks to is suspended
/// awaiting the very response this hook precedes, which is what makes the
/// hand-off deterministic rather than lucky.
///
/// **The releasing side is pinned too, and that is not belt-and-braces.** The
/// usual advice — hold off the pool, release on it — assumes the pool can be
/// reached. This suite shares a process with `BoundedGateWaitTests`, whose
/// whole subject is a deliberately saturated pool: with every cooperative
/// thread parked for 120 s, a release scheduled on the pool does not run, and
/// this gate expired for reasons that had nothing to do with the drain it was
/// arranging. `gateHoldingTask` puts `body` and every default-actor hop it
/// makes (SE-0417) on threads these tests own, so the hand-off completes
/// whatever the pool is doing.
///
/// `waitForGate` bounds it regardless: a future change that broke the
/// arrangement reports a named gate and lets the test's own assertions fail,
/// rather than hanging the suite.
private func runBlocking(_ gate: String, _ body: @escaping @Sendable () async -> Void) {
    let finished = DispatchSemaphore(value: 0)
    _ = gateHoldingTask {
        await body()
        finished.signal()
    }
    finished.waitForGate(gate)
}

/// A box for a number the request handler reads but the test writes: the
/// listener's own port, which is not known until after the closure is built,
/// and the route count, which a draining test moves while the supervisor
/// watches.
private final class IntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
