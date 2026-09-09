import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import TestSupport
import Testing

@testable import TBDModelProxy
@testable import TBDShared

/// The half of `TBDModelProxyTests`' dependency on the EXECUTABLE target that
/// `@testable import` does not cover: that depending on `TBDModelProxy` really
/// does build the product into the same products directory as the test bundle.
///
/// It is asserted here, with the target, rather than left to the suites that
/// will need it. Part B2's supervisor tests will spawn this binary through the
/// real spawner; if the products directory were the thing that broke, those
/// suites would look correct and find no binary to spawn. Shaped after
/// `Tests/TBDHolderTests/HolderBinaryTests.swift`, which exists for exactly
/// this reason.
///
/// This suite is deliberately NOT nested under `ModelProxySuites`: nothing in
/// it binds a listener, so nothing in it needs the serialized parent. The suite
/// that spawns a *running* proxy does — `ModelProxySuites.ProxyProcessTests`
/// below.
@Suite("Model proxy binary")
struct ProxyBinaryTests {
    @Test("the binary is built beside the test bundle")
    func binaryIsBuiltBesideTheTestBundle() throws {
        #expect(ProxyExecutable.locate() != nil, "TBDModelProxy was not built into the products directory")
    }

    /// The parser's verdict, observed through the process rather than through
    /// `@testable`: a bad command line has to exit 2 with the usage line on
    /// stderr and nothing at all on stdout.
    ///
    /// Exit 2 is what tells a supervisor not to respawn — the same arguments
    /// will fail the same way forever — and it is only a distinction if the
    /// binary really produces it, which no in-process parse test can show. The
    /// stdout assertion pins the other invariant this target carries: a proxy's
    /// stdout is redirected into `proxy.log`, so ordinary output there would be
    /// indistinguishable from a diagnostic.
    ///
    /// An unknown flag is the safe way to reach that exit: a well-formed
    /// invocation would block on the termination semaphore forever, and this
    /// one refuses before it can touch a home or bind anything. The environment
    /// is explicit and rc-free for the same reason every holder bootstrap is —
    /// nothing here may come from the developer's shell.
    ///
    /// `async` on `collectOutput(of:)` rather than synchronous on two
    /// `readDataToEndOfFile()` calls plus `waitUntilExit()`: each of those
    /// parks the calling thread until the child is done, and in a synchronous
    /// test body that thread belongs to the cooperative pool CI's runner has
    /// three of (`Tests/CLAUDE.md`, "Thread-blocking gates run off the
    /// cooperative pool"). This one test held three of the three, and two runs
    /// went silent for ~30 minutes with no failing test to name.
    @Test("a bad invocation exits 2 with a usage diagnostic and a silent stdout")
    func aBadInvocationExitsTwoWithAUsageDiagnostic() async throws {
        let executable = try #require(ProxyExecutable.locate())
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--stream-dir", "/tmp"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = try await collectOutput(of: process)

        #expect(output.status == TBDModelProxyExit.badArguments)
        let diagnostic = String(decoding: output.stderr, as: UTF8.self)
        #expect(diagnostic.contains("unknown argument --stream-dir"))
        #expect(diagnostic.contains("--lock-fd"), "the usage line must name the descriptor flag")
        #expect(output.stdout.isEmpty, "a proxy must never write to stdout")
    }

    /// The exit taxonomy Part B2's supervisor branches on. Pinned as a set of
    /// distinct values rather than as four separate literals, because the
    /// property that matters is that no two failures share a code: a supervisor
    /// that could not tell "the port is taken" from "another proxy already owns
    /// this home" would respawn against a live proxy forever.
    @Test("every named exit status is distinct, and none is 0 or 1")
    func exitStatusesAreDistinct() {
        let codes: [Int32] = [
            TBDModelProxyExit.badArguments, TBDModelProxyExit.bindFailed,
            TBDModelProxyExit.lockHeld, TBDModelProxyExit.homeUnusable,
        ]
        #expect(Set(codes).count == codes.count)
        // 0 is a clean exit and 1 is what a Swift runtime failure produces, so
        // no named status may take either.
        #expect(codes.allSatisfy { $0 > 1 })
    }

    /// What a SIGTERM means, decided without a process to send one to.
    ///
    /// The three branches are the whole rule (spec, "Signals"), and each one is
    /// a different failure if it is wrong: a signal before the bind that asked
    /// for a retire would sit waiting on a listener that does not exist; a
    /// first signal that exited would truncate every stream the proxy was
    /// carrying; a second signal that joined the drain would leave an operator
    /// with no way short of `SIGKILL` to stop a proxy now.
    @Test("the first signal retires, a second exits, and one before the bind exits")
    func signalDispositionArmsAndCounts() {
        // Nothing has bound yet, so there is nothing to close and nothing to
        // drain: the process ends.
        let unarmed = ProxySignalDisposition()
        guard case .exitNow = unarmed.received() else {
            Issue.record("a signal arriving before the bind asked for a retire")
            return
        }

        let armed = ProxySignalDisposition()
        let retires = TestCounter()
        armed.armRetire { retires.increment() }
        guard case .retire(let retire) = armed.received() else {
            Issue.record("the first signal to a serving proxy did not retire it")
            return
        }
        retire()
        #expect(retires.value == 1)

        // The operator saying they meant now.
        guard case .exitNow = armed.received() else {
            Issue.record("a second signal joined the drain instead of ending it")
            return
        }
        #expect(armed.signalCount == 2)
        #expect(retires.value == 1, "a second signal started a second retire")
    }

    /// The pid file's shape, asserted on the composer, so the two lines and
    /// their order stay pinned independently of how hard the file is to observe
    /// from outside.
    @Test("the pid file is the pid and the port, one per line")
    func pidFileHoldsThePidAndThePort() {
        #expect(ProxyPIDFile.contents(pid: 4321, port: 51234) == "4321\n51234\n")
    }

    /// The unlink is conditional, and the condition is the whole point: a
    /// retiring proxy exits *after* its successor has bound the port and
    /// written its own pid file, so an unconditional unlink on the way out
    /// would leave a live proxy with no rendezvous.
    @Test("a pid file is reclaimed only while it still names us")
    func aPIDFileIsReclaimedOnlyWhileItNamesUs() throws {
        let root = proxyScratchRoot(prefix: "pxpid")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("proxy.pid").path

        try ProxyPIDFile.write(path: path, pid: 4321, port: 51234)
        #expect(ProxyPIDFile.pid(inContentsOf: path) == 4321)

        // A successor's file, from a predecessor's point of view.
        #expect(ProxyPIDFile.removeIfOwned(path: path, pid: 9999) == false)
        #expect(FileManager.default.fileExists(atPath: path))

        #expect(ProxyPIDFile.removeIfOwned(path: path, pid: 4321))
        #expect(!FileManager.default.fileExists(atPath: path))
        // A second pass over a file that is already gone is not a reclaim and
        // must not report one.
        #expect(ProxyPIDFile.removeIfOwned(path: path, pid: 4321) == false)
    }

    /// The formula both sides of the version comparison run. Asserted against a
    /// file whose size and mtime this test sets, so the string is pinned rather
    /// than merely reproduced.
    @Test("a build identity is the file's size and whole-second mtime")
    func buildIdentityIsSizeAndMtime() throws {
        let root = proxyScratchRoot(prefix: "pxver")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("TBDModelProxy")
        try Data(repeating: 0x41, count: 1234).write(to: file)
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)

        #expect(ModelProxyVersion.identity(of: file) == "1234-1800000000")
        // A file nobody can describe has no identity, and the caller that turns
        // that into a version string says so rather than inventing one.
        #expect(ModelProxyVersion.identity(of: root.appendingPathComponent("absent")) == nil)
        #expect(
            ModelProxyVersion.currentExecutable(
                bundleExecutable: nil, argumentZero: root.appendingPathComponent("absent").path)
                == ModelProxyVersion.unknown)
        #expect(
            ModelProxyVersion.currentExecutable(bundleExecutable: nil, argumentZero: file.path)
                == "1234-1800000000")
    }
}

// MARK: - The retention watch

extension ProxyBinaryTests {
    /// The proxy retires itself when nobody has supervised it for 24 hours and
    /// no stream is in flight (spec, "Retention").
    ///
    /// The window is virtual on two axes, and they are different seams on
    /// purpose. The *pacing* — how often the watch wakes — rides the injected
    /// `Clock`, so virtual time crosses it without a real sleep. The *window*
    /// is a span between two `Date`s, which is what the production check
    /// compares, and the test moves that wall clock by hand. `Duration` is
    /// behavior, `Date` is data.
    ///
    /// **The pacing clock is an `EventDrivenTestClock`, because `run()` is a
    /// sleep-then-sample loop.** Every advance past the first is a re-arm, and
    /// on `TestClock` a re-arm can only be observed by polling
    /// `checkSuspension()`, whose `megaYield` is 20 serially-awaited
    /// background-QoS tasks — under the saturated fast pass that probe floods
    /// the cooperative pool with exactly the low-priority work the watch task
    /// needs a turn from. The helper these tests used instead advanced blindly
    /// up to 40 times and re-checked a sample counter, which is 80 megaYields
    /// of the same work; here each advance waits for the arming that makes it
    /// sound, and the arming that follows a sample is what proves the sample
    /// happened.
    @Suite("Proxy retention watch")
    struct ProxyRetentionTests {

        @Test("an idle proxy nobody has contacted for the window retires itself")
        func selfRetireExitsWhenIdleAndUnattended() async throws {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let wall = MovableWallClock(start)
            let retires = TestCounter()
            let clock = EventDrivenTestClock()
            let interval = Duration.seconds(60)

            let watch = ProxyRetireWatch(
                lastDaemonContact: { start },
                streamsInFlight: { 0 },
                onRetire: { retires.increment() },
                checkInterval: interval,
                unattendedAfter: 24 * 60 * 60,
                now: { wall.read() },
                clock: clock)
            let task = Task { await watch.run() }
            defer { task.cancel() }

            // First sample: the contact is fresh, so nothing happens. This is
            // the discriminating leg — a watch that retired on its first tick
            // would satisfy every assertion below and fail here. The re-arm
            // after the advance is what proves the sample was taken.
            try await clock.requireAdvanceWhenArmed(by: interval)
            try await clock.requireSleeperArmed()
            #expect(retires.value == 0, "the watch retired a proxy contacted a moment ago")

            // A day passes on the wall clock while the daemon says nothing. No
            // re-arm follows this sample — `run()` hands over and returns — so
            // the observable is what proves it landed.
            wall.advance(24 * 60 * 60)
            try await clock.requireAdvanceWhenArmed(by: interval)
            await waitUntil(
                "the watch retired the unattended proxy",
                seconds: TestDeadlines.saturatedPassSeconds,
                sample: { retires.value }, isSatisfied: { $0 >= 1 })

            // Once, and then the loop is done: `onRetire` ends the process, and
            // a second call would be a second exit. A watch that kept looping
            // would arm another sleep, which is what this rules out — watched
            // for rather than settled for, so a late arming is still caught.
            #expect(
                await watchForSleeper(on: clock) == false,
                "the retention watch armed another sleep after it had retired")
            #expect(retires.value == 1)
        }

        /// The second condition, on its own. A turn running longer than the
        /// window is exactly what a bare timer would cut, so the stream count —
        /// not the clock — is what protects it.
        @Test("a stream in flight keeps an unattended proxy alive")
        func aStreamInFlightDefersTheRetire() async throws {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let wall = MovableWallClock(start)
            let inFlight = TestCounter()
            inFlight.set(1)
            let retires = TestCounter()
            let clock = EventDrivenTestClock()
            let interval = Duration.seconds(60)

            let watch = ProxyRetireWatch(
                lastDaemonContact: { start },
                streamsInFlight: { inFlight.value },
                onRetire: { retires.increment() },
                checkInterval: interval,
                unattendedAfter: 24 * 60 * 60,
                now: { wall.read() },
                clock: clock)
            let task = Task { await watch.run() }
            defer { task.cancel() }

            wall.advance(48 * 60 * 60)
            try await clock.requireAdvanceWhenArmed(by: interval)
            try await clock.requireSleeperArmed()
            #expect(retires.value == 0, "a turn in flight was cut by the retention watch")

            // The turn ends; the next sample retires, and that sample is the
            // last — `run()` returns rather than re-arming, so the observable
            // is what proves it landed.
            inFlight.set(0)
            try await clock.requireAdvanceWhenArmed(by: interval)
            await waitUntil(
                "the watch retired once the last stream ended",
                seconds: TestDeadlines.saturatedPassSeconds,
                sample: { retires.value }, isSatisfied: { $0 >= 1 })
        }

        /// The predicate without the loop, at the boundary, and against the
        /// production constants so a change to either is visible here.
        @Test("the sample is true only at or past the window with no stream")
        func theSampleIsExactAtTheBoundary() {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let inFlight = TestCounter()
            let watch = ProxyRetireWatch(
                lastDaemonContact: { start },
                streamsInFlight: { inFlight.value },
                onRetire: {})

            #expect(ProxyRetireWatch.defaultUnattendedAfter == 24 * 60 * 60)
            #expect(ProxyRetireWatch.defaultCheckInterval == .seconds(60))

            let window = ProxyRetireWatch.defaultUnattendedAfter
            #expect(!watch.isUnattendedAndIdle(at: start.addingTimeInterval(window - 1)))
            #expect(watch.isUnattendedAndIdle(at: start.addingTimeInterval(window)))

            inFlight.set(1)
            #expect(!watch.isUnattendedAndIdle(at: start.addingTimeInterval(window * 10)))
        }

    }
}

// MARK: - Last daemon contact

extension ProxyBinaryTests {
    /// What the retention watch reads. Every `/tbd/…` verb stamps it, which is
    /// the whole definition of "a daemon is supervising this proxy" — the proxy
    /// has no other way to learn that one exists.
    @Suite("Proxy daemon contact")
    struct ProxyDaemonContactTests {
        @Test("a control call from loopback stamps the contact, and a refused one does not")
        func everyControlVerbStampsTheContact() async throws {
            let root = proxyScratchRoot(prefix: "pxcont")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let wall = MovableWallClock(start)
            let contact = LastDaemonContact(now: { wall.read() })
            let control = ControlEndpoints(
                routes: RouteTable(
                    routesDir: root.appendingPathComponent("proxy/routes"),
                    streamsDir: root.appendingPathComponent("streams")),
                status: {
                    ModelProxyStatus(
                        version: "test", pid: getpid(), processStartTime: Date(), port: 0,
                        streamsInFlight: 0, routeCount: 0,
                        home: ModelProxyStatus.canonicalHome(root.path))
                },
                onRetire: {},
                closeListener: {},
                streamsInFlight: { 0 },
                contact: contact)

            let loopback = try SocketAddress(ipAddress: "127.0.0.1", port: 40000)
            // Seeded at construction, not at the epoch: a proxy nobody has
            // contacted has still only just started, and an epoch seed would
            // make every fresh proxy instantly eligible to retire itself.
            #expect(control.lastDaemonContact == start)

            // A verb this image does not have still means a daemon is there.
            wall.advance(60)
            let unknown = await control.handle(
                method: "GET", path: "/tbd/nonesuch", body: [], remoteAddress: loopback)
            #expect(unknown.status == .notFound)
            #expect(control.lastDaemonContact == start.addingTimeInterval(60))

            wall.advance(60)
            _ = await control.handle(
                method: "GET", path: "/tbd/status", body: [], remoteAddress: loopback)
            #expect(control.lastDaemonContact == start.addingTimeInterval(120))

            // A caller the loopback guard refuses is by definition not the
            // daemon, so it must not be able to keep a proxy alive.
            wall.advance(60)
            let offBox = try SocketAddress(ipAddress: "192.0.2.7", port: 9)
            let refused = await control.handle(
                method: "GET", path: "/tbd/status", body: [], remoteAddress: offBox)
            #expect(refused.status == .forbidden)
            #expect(
                control.lastDaemonContact == start.addingTimeInterval(120),
                "a refused caller stamped the daemon-contact clock")
        }
    }
}

// MARK: - A running proxy

extension ModelProxySuites {
    /// The binary's start-up contract, observed by spawning it.
    ///
    /// Nested under `ModelProxySuites` because every test here binds a real
    /// loopback listener — in a child process, which is if anything heavier
    /// than the in-process suites the serialized parent already covers.
    ///
    /// Everything asserted here is something Part B2's supervisor is written
    /// against: it reads the port out of the pid file when it has none
    /// persisted, adopts a proxy by its `GET /tbd/status` identity, stops one
    /// with a signal, and reads exit 4 as "a proxy for this home is already
    /// running".
    @Suite("Proxy process", .serialized)
    struct ProxyProcessTests {

        @Test("it binds, answers status, and writes a pid file naming that port")
        func bindsAndWritesPidFile() async throws {
            // Launched through a symlink to the real scratch directory, so the
            // path the binary is handed and the path it must report are
            // different strings for one directory. That is the everyday case —
            // `/var` and `/tmp` are symlinks on macOS — and a daemon comparing
            // an uncanonicalized answer against its own home would refuse to
            // adopt its own proxy.
            let real = proxyScratchRoot(prefix: "pxrun")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            let link = real.deletingLastPathComponent()
                .appendingPathComponent(real.lastPathComponent + "-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let home = link.path
            let proxy = try ProxyProcess.start(home: home)
            defer { proxy.terminate() }

            let pidFile = try await proxy.awaitPIDFile()
            #expect(pidFile.pid == proxy.pid)
            #expect(pidFile.port > 0, "the pid file must name the port that was actually bound")

            // Written AFTER the bind, so a reader who finds the file may trust
            // the port in it: the status endpoint on that port has to answer.
            let status = try await ProxyProcess.status(port: pidFile.port)
            #expect(status.pid == proxy.pid)
            #expect(status.port == pidFile.port)
            #expect(status.streamsInFlight == 0)

            // The home the daemon compares against its own before it adopts
            // the process holding its port, canonical rather than echoed back:
            // the `--home` above went in through a symlink, and the answer
            // names the directory it resolves to.
            #expect(status.home == ModelProxyStatus.canonicalHome(real.path))
            #expect(status.home == ModelProxyStatus.canonicalHome(home))
            #expect(
                status.home != home,
                "the proxy echoed its --home back rather than canonicalizing it")

            // The identity the daemon compares against its own sibling binary.
            // "dev" was the placeholder this task replaced; "unknown" is what a
            // proxy that cannot read its own executable reports, and this one
            // can.
            let executable = try #require(ProxyExecutable.locate())
            #expect(status.version != "dev")
            #expect(status.version != ModelProxyVersion.unknown)
            #expect(
                status.version == ModelProxyVersion.identity(of: executable),
                "the proxy reported an identity the daemon's formula cannot reproduce")

            // The directories it is contracted to create, at the mode it is
            // contracted to create them.
            for relative in ["proxy", "proxy/routes", "streams"] {
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: home + "/" + relative)
                #expect(
                    (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                    "\(relative) was not created at 0700")
            }
        }

        @Test("SIGTERM exits zero and reclaims the pid file")
        func sigtermExitsZero() async throws {
            let home = proxyScratchRoot(prefix: "pxterm").path
            let proxy = try ProxyProcess.start(home: home)
            defer { proxy.terminate() }
            _ = try await proxy.awaitPIDFile()

            kill(proxy.pid, SIGTERM)
            let status = await proxy.awaitExit()
            #expect(status == 0, "a TERMed proxy must exit cleanly; log:\n\(proxy.log())")

            // The rendezvous is reclaimed on the way out, so a pid file left
            // behind means a proxy that is running or one that was killed.
            #expect(
                !FileManager.default.fileExists(atPath: home + "/proxy/proxy.pid"),
                "the pid file outlived the proxy")
        }

        /// A signal is a retire, and a retire cuts nothing (spec, "Signals").
        ///
        /// The failure this pins is the one an operator meets by accident: a
        /// `kill` on a proxy carrying turns for every session on the machine.
        /// A proxy that answered a signal by tearing its event loops down would
        /// truncate each of those mid-message, which is precisely the
        /// transcript corruption the feature exists to avoid.
        ///
        /// Discriminating three ways over, and each one fails a different
        /// mistake. The listener has to close — otherwise the signal did
        /// nothing and the stream would survive anyway. The process has to be
        /// alive at that moment — otherwise it exited and the bytes below are
        /// whatever the client had already buffered. And the bytes have to be
        /// the upstream's own, in order, to the end.
        ///
        /// The final frame is allowed to go missing, for the reason
        /// `retireReleasesTheLockBeforeTheDrainEnds` states: the drain samples
        /// the in-flight count *before* the terminating chunk is flushed, so
        /// the process may exit between the two. Everything before it may not.
        @Test("a signal retires the proxy and lets the stream it carries finish")
        func aSignalRetiresRatherThanCuttingTheStream() async throws {
            // Eight events 400 ms apart: over three seconds of stream left to
            // lose after the signal lands, each frame flushed on its own.
            let ticks = (1...8).map { index in
                (delayMs: 400, bytes: Array("event: tick\ndata: {\"n\":\(index)}\n\n".utf8))
            }
            let upstream = FakeUpstream { _, _ in FakeUpstream.Script(events: ticks) }
            let upstreamPort = try await upstream.start()
            defer { upstream.stop() }

            let home = proxyScratchRoot(prefix: "pxsigd").path
            let token = ModelProxyRoute.mintToken()
            let route = ModelProxyRoute(
                token: token, terminalID: UUID(),
                upstream: "http://127.0.0.1:\(upstreamPort)", streamingEnabled: false)
            try FileManager.default.createDirectory(
                atPath: home + "/proxy/routes", withIntermediateDirectories: true)
            try route.encodedForRouteFile().write(
                to: URL(fileURLWithPath: home + "/proxy/routes/" + token + ".json"))

            let proxy = try ProxyProcess.start(home: home)
            defer { proxy.terminate() }
            let pidFile = try await proxy.awaitPIDFile()

            let routeURL = try ProxyProcess.url(port: pidFile.port, path: "/r/\(token)/v1/messages")
            var request = URLRequest(url: routeURL)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"stream":true}"#.utf8)
            let (bytes, response) = try await ProxyProcess.session.bytes(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)

            // The head is on the wire, so the relay is counted in flight and
            // the drain has something to wait for.
            kill(proxy.pid, SIGTERM)

            // A retire closes the listener first, which is how a successor's
            // spawner learns the port is free. Nothing here waits on the
            // process: it must still be running when this holds.
            let closed = await waitUntil(
                "the signalled proxy to close its listener", seconds: 10,
                sample: { connectRefused(port: pidFile.port) }, isSatisfied: { $0 })
            #expect(closed, "the signal never closed the listener; log:\n\(proxy.log())")
            // The pid is still in the process table. A weak check on its own —
            // an exited child stays there as a zombie until it is reaped, and
            // nothing has reaped this one yet — so what actually proves the
            // proxy kept serving is the byte comparison below, which a process
            // that had exited here could not satisfy.
            #expect(kill(proxy.pid, 0) == 0, "the signalled proxy's pid is gone")

            var received: [UInt8] = []
            var readError: (any Error)?
            do {
                for try await byte in bytes { received.append(byte) }
            } catch {
                readError = error
            }

            // Built before the macro, not inside it: `#expect`'s message is a
            // `Comment`, and a `+`-built String is not one.
            let whole = ticks.flatMap { $0.bytes }
            let allButLast = ticks.dropLast().flatMap { $0.bytes }
            let ending = readError.map { "then \($0)" } ?? "then a clean end"
            #expect(
                whole.starts(with: received),
                "the relay delivered bytes the upstream never wrote, \(ending); log:\n\(proxy.log())")
            #expect(
                received.count >= allButLast.count,
                "the signal cut the stream at \(received.count) of \(whole.count) bytes, \(ending); log:\n\(proxy.log())"
            )

            // And it exits by itself once the drain is done, the way a
            // POST /tbd/retire does.
            let status = await proxy.awaitExit()
            #expect(status == 0, "a signalled proxy must exit cleanly; log:\n\(proxy.log())")
            #expect(
                !FileManager.default.fileExists(atPath: home + "/proxy/proxy.pid"),
                "the pid file outlived the proxy")
        }

        /// The way out of a drain that is short of `SIGKILL` (spec, "Signals").
        ///
        /// The first signal starts a drain that would run for the length of the
        /// stream — ten seconds here, and up to ten minutes in production. An
        /// operator who wants the process gone now must not have to reach for a
        /// signal that cannot be handled at all, so the second one exits
        /// without waiting.
        ///
        /// Discriminating on delivered bytes, not the clock: the exit reason
        /// (`"signal N"` versus `"retire"`, `Proxy.swift`) is only ever
        /// written through `os.Logger`, which this binary's own contract
        /// keeps out of `proxy.log` on any path but a cannot-run-at-all
        /// failure (`Proxy.swift`, top-of-file comment) — so it is not a
        /// channel a test can assert on. What a broken proxy that ignored the
        /// second signal actually *does* differently is deliver the whole
        /// ten-second stream instead of a prefix of it: the upstream has only
        /// twenty ticks, so a drain that ran to completion delivers all of
        /// them, and only a drain that was cut short delivers fewer. The
        /// byte-count check below is that proof, and unlike a wall-clock
        /// budget it cannot be fooled by a slow or starved test runner — it
        /// reads the actual outcome of the code path taken, not how long that
        /// path took to run.
        @Test("a second signal during the drain exits without waiting for it")
        func aSecondSignalEndsTheDrain() async throws {
            // Twenty events half a second apart: ten seconds of stream. No
            // wall-clock bound is asserted; a process that exits having
            // delivered fewer than twenty events did not wait for the drain.
            let ticks = (1...20).map { index in
                (delayMs: 500, bytes: Array("event: tick\ndata: {\"n\":\(index)}\n\n".utf8))
            }
            let upstream = FakeUpstream { _, _ in FakeUpstream.Script(events: ticks) }
            let upstreamPort = try await upstream.start()
            defer { upstream.stop() }

            let home = proxyScratchRoot(prefix: "pxsig2").path
            let token = ModelProxyRoute.mintToken()
            let route = ModelProxyRoute(
                token: token, terminalID: UUID(),
                upstream: "http://127.0.0.1:\(upstreamPort)", streamingEnabled: false)
            try FileManager.default.createDirectory(
                atPath: home + "/proxy/routes", withIntermediateDirectories: true)
            try route.encodedForRouteFile().write(
                to: URL(fileURLWithPath: home + "/proxy/routes/" + token + ".json"))

            let proxy = try ProxyProcess.start(home: home)
            defer { proxy.terminate() }
            let pidFile = try await proxy.awaitPIDFile()

            let routeURL = try ProxyProcess.url(port: pidFile.port, path: "/r/\(token)/v1/messages")
            var request = URLRequest(url: routeURL)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"stream":true}"#.utf8)
            let (bytes, response) = try await ProxyProcess.session.bytes(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)

            kill(proxy.pid, SIGTERM)
            let closed = await waitUntil(
                "the signalled proxy to close its listener", seconds: 10,
                sample: { connectRefused(port: pidFile.port) }, isSatisfied: { $0 })
            #expect(closed, "the first signal never closed the listener; log:\n\(proxy.log())")
            // As above, a weak check by itself; what proves the first signal
            // started a drain rather than an exit is the byte-count check
            // below, which only a proxy that was still draining when the
            // second signal landed could satisfy.
            #expect(kill(proxy.pid, 0) == 0, "the signalled proxy's pid is gone")

            kill(proxy.pid, SIGTERM)
            // Generously wide: this bounds a starved CI runner's scheduling
            // delay, not the drain itself. The discriminator below is the
            // delivered byte count, not how long the exit took, so widening
            // this only removes flake risk and cannot mask a proxy that let
            // the drain run to completion.
            let status = await proxy.awaitExit(seconds: 30)
            #expect(status == 0, "the second signal exited \(String(describing: status)); log:\n\(proxy.log())")

            // The stream really was cut, which is the cost the second signal
            // buys and the thing only a `SIGKILL` could otherwise do. A proxy
            // that let the drain run to completion instead would deliver
            // every one of the twenty ticks, which is what the count check
            // below rules out.
            var received: [UInt8] = []
            do {
                for try await byte in bytes { received.append(byte) }
            } catch {
                // A reset connection is the expected ending here.
            }
            let whole = ticks.flatMap { $0.bytes }
            #expect(
                received.count < whole.count,
                "the second signal delivered the whole stream anyway; log:\n\(proxy.log())")
        }

        /// A signal on an idle proxy costs nothing (spec, "Signals").
        ///
        /// The drain samples the in-flight count before its first sleep, so a
        /// proxy carrying no turn retires on that sample. The budget is what
        /// separates "a signal is a retire" from "a signal is now a wait": a
        /// process manager stopping an idle proxy must not sit through a poll
        /// interval, let alone the ten-minute cap.
        @Test("a signal with nothing in flight exits promptly")
        func aSignalWithNothingInFlightExitsPromptly() async throws {
            let home = proxyScratchRoot(prefix: "pxsigi").path
            let proxy = try ProxyProcess.start(home: home)
            defer { proxy.terminate() }
            let pidFile = try await proxy.awaitPIDFile()

            // Discriminating: the proxy is serving, and carrying nothing, when
            // the signal arrives — so the promptness below is a drain that
            // found nothing rather than a process that never bound at all.
            let before = try await ProxyProcess.status(port: pidFile.port)
            #expect(before.streamsInFlight == 0)

            let signalledAt = ContinuousClock().now
            kill(proxy.pid, SIGTERM)
            let status = await proxy.awaitExit(seconds: 20)
            let waited = ContinuousClock().now - signalledAt
            #expect(status == 0, "an idle proxy exited \(String(describing: status)); log:\n\(proxy.log())")
            #expect(
                waited < .seconds(5),
                "an idle proxy took \(waited) to exit after a signal; log:\n\(proxy.log())")
            #expect(
                !FileManager.default.fileExists(atPath: home + "/proxy/proxy.pid"),
                "the pid file outlived the proxy")

            // And the rendezvous is free for a successor, which is the other
            // half of what a retire owes.
            let successor = try? HolderLock.acquire(path: home + "/proxy/proxy.lock")
            #expect(successor != nil, "the exited proxy left its rendezvous lock held")
            successor?.release()
        }

        /// Exit 3, produced rather than asserted (`exitStatusesAreDistinct`
        /// pins only that no two codes collide).
        ///
        /// It is the one exit status the supervisor acts on rather than merely
        /// reports: on a bind failure it probes `GET /tbd/status` on that port,
        /// adopts a TBD proxy that answers, and mints a fresh port for anything
        /// else. A proxy that exited some other way when its port was taken
        /// would send the supervisor down the wrong branch.
        @Test("a port another listener holds exits bindFailed and writes no pid file")
        func aTakenPortExitsBindFailed() async throws {
            // A listener on a kernel-assigned port, still holding it when the
            // proxy is asked for exactly that number. `SO_REUSEADDR` — which
            // the proxy sets so a successor can bind while a predecessor's
            // connections linger — does not let two *listeners* share a port on
            // BSD, which is what makes this reachable at all.
            let squatter = FakeUpstream { _, _ in FakeUpstream.Script(events: []) }
            let takenPort = try await squatter.start()
            defer { squatter.stop() }

            let home = proxyScratchRoot(prefix: "pxbind").path
            let proxy = try ProxyProcess.start(home: home, port: takenPort)
            defer { proxy.terminate() }
            let status = await proxy.awaitExit()
            #expect(
                status == TBDModelProxyExit.bindFailed,
                "a proxy asked for a taken port exited \(String(describing: status)); log:\n\(proxy.log())"
            )
            #expect(
                proxy.log().contains("bind failed"),
                "the diagnostic did not name the bind; log:\n\(proxy.log())")
            // Deliberately no pid file on this path: a reader who finds one is
            // entitled to assume the port in it is bound.
            #expect(
                !FileManager.default.fileExists(atPath: home + "/proxy/proxy.pid"),
                "a proxy that never bound left a pid file naming a port it does not hold")
        }

        @Test("a route written before the spawn is servable without a control call")
        func startsWithExistingRoutes() async throws {
            let upstream = FakeUpstream { _, _ in
                FakeUpstream.Script(
                    headers: [("content-type", "application/json")],
                    events: [(delayMs: 0, bytes: Array(#"{"ok":true}"#.utf8))])
            }
            let upstreamPort = try await upstream.start()
            defer { upstream.stop() }

            let home = proxyScratchRoot(prefix: "pxload").path
            let token = ModelProxyRoute.mintToken()
            let route = ModelProxyRoute(
                token: token, terminalID: UUID(),
                upstream: "http://127.0.0.1:\(upstreamPort)", streamingEnabled: false)
            // Written before the spawn, the way the daemon writes one before
            // the session it serves. `loadAll` at start-up is the only thing
            // that can make it servable, because nobody will POST /tbd/routes.
            try FileManager.default.createDirectory(
                atPath: home + "/proxy/routes", withIntermediateDirectories: true)
            try route.encodedForRouteFile().write(
                to: URL(fileURLWithPath: home + "/proxy/routes/" + token + ".json"))

            let proxy = try ProxyProcess.start(home: home)
            defer { proxy.terminate() }
            let pidFile = try await proxy.awaitPIDFile()

            let routeURL = try ProxyProcess.url(port: pidFile.port, path: "/r/\(token)/v1/messages")
            var request = URLRequest(url: routeURL)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"model":"claude"}"#.utf8)
            let (body, response) = try await ProxyProcess.session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: body, as: UTF8.self) == #"{"ok":true}"#)
            #expect(upstream.requests.count == 1, "the route loaded at start-up forwarded nothing")
            #expect(upstream.requests.first?.head.uri == "/v1/messages")

            // Discriminating: a proxy that served *any* token rather than the
            // one it loaded would satisfy everything above.
            let strangerURL = try ProxyProcess.url(
                port: pidFile.port, path: "/r/\(ModelProxyRoute.mintToken())/v1/messages")
            let (_, refused) = try await ProxyProcess.session.data(from: strangerURL)
            #expect((refused as? HTTPURLResponse)?.statusCode == 404)
            #expect(upstream.requests.count == 1, "an unknown token reached the upstream")
        }

        @Test("a second proxy on one home exits lockHeld rather than starting")
        func secondInstanceExitsLockHeld() async throws {
            let home = proxyScratchRoot(prefix: "pxlock").path
            let first = try ProxyProcess.start(home: home)
            defer { first.terminate() }
            // The lock is taken before the bind and the pid file written after
            // it, so a pid file on disk means the lock is certainly held.
            _ = try await first.awaitPIDFile()

            let second = try ProxyProcess.start(home: home)
            defer { second.terminate() }
            let status = await second.awaitExit()
            #expect(
                status == TBDModelProxyExit.lockHeld,
                "a second proxy on one home exited \(String(describing: status)); log:\n\(second.log())")

            // The loser must not have disturbed the winner's rendezvous.
            #expect(FileManager.default.fileExists(atPath: home + "/proxy/proxy.pid"))
            #expect(kill(first.pid, 0) == 0, "the first proxy died when the second was refused")
        }

        @Test("an inherited lock descriptor is taken as proof and not re-acquired")
        func anInheritedLockDescriptorSkipsTheAcquire() async throws {
            let home = proxyScratchRoot(prefix: "pxinhl").path
            try FileManager.default.createDirectory(
                atPath: home + "/proxy", withIntermediateDirectories: true)
            let lockPath = home + "/proxy/proxy.lock"

            // This process plays the daemon that took the lock before spawning.
            // It KEEPS its own descriptor, so a proxy that ignored `--lock-fd`
            // and acquired for itself would get EWOULDBLOCK and exit 4 — which
            // `secondInstanceExitsLockHeld` shows is exactly what happens. The
            // descriptor handed down is a second, deliberately unlocked open of
            // the same file, so the only thing that can make this test pass is
            // the proxy honouring the flag.
            let held = try HolderLock.acquire(path: lockPath)
            defer { held.release() }
            let inherited = open(lockPath, O_RDWR | O_CLOEXEC, 0o600)
            try #require(inherited >= 0, "could not open a second descriptor on the lock file")
            defer { close(inherited) }

            let proxy = try ProxyProcess.start(home: home, inheritDescriptor: inherited)
            defer { proxy.terminate() }
            let pidFile = try await proxy.awaitPIDFile()
            #expect(pidFile.pid == proxy.pid)
            #expect(pidFile.port > 0)
        }

        /// The lock is a live proxy's claim on the rendezvous, and a retiring
        /// proxy stops being one the moment its listener closes.
        ///
        /// The successor's spawner takes `proxy.lock` before it spawns
        /// anything, the way `HolderSpawner` does. If the predecessor held its
        /// lock until exit, that spawn would fail with `lockHeld` for the whole
        /// drain — up to the ten-minute cap — with nothing listening on the
        /// port and every proxied session losing a turn once Claude's
        /// 183-second retry budget ran out.
        ///
        /// Discriminating twice over: the lock has to come free inside a second
        /// of the answer, and the six-second stream has to keep delivering
        /// afterwards. A proxy that released only at exit could satisfy the
        /// first only by cutting the stream, which the event count then
        /// catches.
        @Test("retire frees the rendezvous lock while the drain is still running")
        func retireReleasesTheLockBeforeTheDrainEnds() async throws {
            // Six events a second apart: long enough that a lock which only
            // came free at exit could not come free inside the budget below.
            let ticks = (1...6).map { index in
                (delayMs: 1000, bytes: Array("event: tick\ndata: {\"n\":\(index)}\n\n".utf8))
            }
            let upstream = FakeUpstream { _, _ in FakeUpstream.Script(events: ticks) }
            let upstreamPort = try await upstream.start()
            defer { upstream.stop() }

            let home = proxyScratchRoot(prefix: "pxrelk").path
            let token = ModelProxyRoute.mintToken()
            let route = ModelProxyRoute(
                token: token, terminalID: UUID(),
                upstream: "http://127.0.0.1:\(upstreamPort)", streamingEnabled: false)
            try FileManager.default.createDirectory(
                atPath: home + "/proxy/routes", withIntermediateDirectories: true)
            try route.encodedForRouteFile().write(
                to: URL(fileURLWithPath: home + "/proxy/routes/" + token + ".json"))

            // No `--lock-fd`, so this proxy takes `proxy.lock` for itself and
            // the release under test is `HolderLock.release()`.
            let proxy = try ProxyProcess.start(home: home)
            defer { proxy.terminate() }
            let pidFile = try await proxy.awaitPIDFile()

            let routeURL = try ProxyProcess.url(
                port: pidFile.port, path: "/r/\(token)/v1/messages")
            var request = URLRequest(url: routeURL)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"stream":true}"#.utf8)
            let (bytes, response) = try await ProxyProcess.session.bytes(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)

            let (retireBody, retireResponse) = try await ProxyProcess.session.data(
                for: controlRequest(port: pidFile.port, method: "POST", path: "/tbd/retire"))
            let answeredAt = ContinuousClock().now
            #expect((retireResponse as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: retireBody, as: UTF8.self) == ControlEndpoints.retiringBody)

            // The successor's spawner, in one line: take the lock, then spawn.
            var taken: HolderLock?
            while ContinuousClock().now - answeredAt < .seconds(1) {
                if let lock = try? HolderLock.acquire(path: home + "/proxy/proxy.lock") {
                    taken = lock
                    break
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            let successorLock = try #require(
                taken,
                "the retiring proxy still held its lock a second after answering; log:\n\(proxy.log())"
            )
            defer { successorLock.release() }

            // …and the predecessor is still carrying the turn it answered
            // over: the events keep arriving for seconds after the lock came
            // free, so nothing was cut to free it.
            //
            // The last frame is allowed to go missing, and the read is allowed
            // to end in an error, because the drain samples the in-flight count
            // *before* the terminating chunk is flushed and the process can
            // exit between the two. What is under test is that the stream kept
            // delivering across the release, which five of six frames after a
            // one-second budget already says.
            var arrived = 0
            var readError: (any Error)?
            do {
                for try await line in bytes.lines where line.hasPrefix("event: ") { arrived += 1 }
            } catch {
                readError = error
            }
            // Built before the macro, not inside it: `#expect`'s message is a
            // `Comment`, and a nested closure interpolated into one is the
            // shape that failed to compile in Task A4.
            let ending = readError.map { "then \($0)" } ?? "then a clean end"
            #expect(
                arrived >= ticks.count - 1,
                "the drain delivered \(arrived) of \(ticks.count) events, \(ending); log:\n\(proxy.log())")

            // And it still exits by itself once the drain is done.
            let status = await proxy.awaitExit()
            #expect(status == 0, "a drained proxy must exit cleanly; log:\n\(proxy.log())")
        }

        /// The inherited descriptor really carries the lock, rather than merely
        /// not being re-acquired.
        ///
        /// `anInheritedLockDescriptorSkipsTheAcquire` above shows the proxy does
        /// not acquire for itself; it cannot show the handed-down descriptor is
        /// open in the child, because the proxy never reads it. This one hands
        /// down the spawner's OWN locked descriptor — the production shape,
        /// where `dup2` gives the child a copy of the same open file
        /// description — and then does what the spawner does next: releases its
        /// copy right after the spawn (`HolderSpawner.swift`). The lock must
        /// survive on the child's copy alone.
        @Test("the inherited descriptor holds the lock after its spawner lets go")
        func anInheritedLockDescriptorIsHeldNotMerelyUnclaimed() async throws {
            let home = proxyScratchRoot(prefix: "pxinhh").path
            try FileManager.default.createDirectory(
                atPath: home + "/proxy", withIntermediateDirectories: true)
            let lockPath = home + "/proxy/proxy.lock"

            let held = try HolderLock.acquire(path: lockPath)
            var spawnerStillHolds = true
            defer { if spawnerStillHolds { held.release() } }

            let proxy = try ProxyProcess.start(
                home: home, inheritDescriptor: held.fileDescriptor)
            defer { proxy.terminate() }
            let pidFile = try await proxy.awaitPIDFile()
            #expect(pidFile.pid == proxy.pid)

            held.release()
            spawnerStillHolds = false

            // The listener is still open, so this proxy still owns the
            // rendezvous. A child that had lost the descriptor at exec, or
            // closed it, would leave the file unlocked and this would succeed.
            let stolen = try? HolderLock.acquire(path: lockPath)
            if let stolen { stolen.release() }
            #expect(
                stolen == nil,
                "the lock was free once the spawner let go; log:\n\(proxy.log())")
        }

        @Test("a home that cannot be created exits homeUnusable without binding")
        func anUnusableHomeExitsWithoutBinding() async throws {
            // A home whose path is a regular file: `mkdir -p` cannot make it,
            // and no amount of respawning will change that — which is why it
            // gets its own status rather than being folded into a bind failure.
            let root = proxyScratchRoot(prefix: "pxbad")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let blocker = root.appendingPathComponent("home")
            try Data("not a directory\n".utf8).write(to: blocker)

            let proxy = try ProxyProcess.start(home: blocker.path)
            defer { proxy.terminate() }
            let status = await proxy.awaitExit()
            #expect(
                status == TBDModelProxyExit.homeUnusable,
                "an unusable home exited \(String(describing: status)); log:\n\(proxy.log())")
        }
    }
}

// MARK: - Test doubles

/// A wall clock the test moves by hand.
///
/// The `Date` half of the retention watch's two seams: the window it compares
/// is a span between two `Date`s, and this is what lets a test cross a
/// twenty-four-hour one without waiting. The pacing half rides the injected
/// `Clock` instead — `Duration` is behavior, `Date` is data.
final class MovableWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(_ start: Date) { self.now = start }

    func read() -> Date {
        lock.withLock { now }
    }

    func advance(_ interval: TimeInterval) {
        lock.withLock { now = now.addingTimeInterval(interval) }
    }
}

/// True when nothing is listening on a loopback port.
///
/// A raw `connect` rather than a request through `URLSession`: what a retire
/// closes is the *listening* socket, and the connections already open on that
/// port keep streaming — so the question is whether a new connect is refused,
/// and a session that reused a live connection would answer a different one. A
/// refused connect on loopback comes back at once with `ECONNREFUSED` rather
/// than waiting out a timeout, so this is safe to poll.
func connectRefused(port: Int) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let outcome = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return outcome != 0
}

/// A counter shared between a test and the closures it hands to a subject.
final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func set(_ new: Int) { lock.withLock { count = new } }
    func increment() { lock.withLock { count += 1 } }
}

// MARK: - Spawning the real binary

/// Where the built `TBDModelProxy` is: a sibling of the test bundle in the
/// products directory, the same lookup `HolderFixture.locateExecutable` does.
enum ProxyExecutable {
    private final class BundleMarker {}

    static func locate() -> URL? {
        let bundleURL = Bundle(for: BundleMarker.self).bundleURL
        var candidates = [bundleURL.deletingLastPathComponent(), bundleURL]
        if let main = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(main)
        }
        for directory in candidates {
            let candidate = directory.appendingPathComponent("TBDModelProxy")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// One spawned `TBDModelProxy`, with its stdio redirected into a log file the
/// failure messages quote.
///
/// `posix_spawn` rather than `Process`, for the reason `HolderFixture` uses it:
/// a file action is the only way to hand a descriptor down on a fixed number,
/// and `--lock-fd` is a descriptor contract. Reaping is `waitpid`, so a test
/// asserts on the exit *status* a supervisor branches on rather than merely on
/// the process being gone.
final class ProxyProcess: @unchecked Sendable {
    let pid: pid_t
    let home: String
    let logPath: String
    private let lock = NSLock()
    private var reapedStatus: Int32?

    /// One session for the whole suite. Ephemeral, so no connection is reused
    /// against a port the kernel has since handed to somebody else.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    private init(pid: pid_t, home: String, logPath: String) {
        self.pid = pid
        self.home = home
        self.logPath = logPath
    }

    enum ProcessError: LocalizedError {
        case noExecutable
        case spawnFailed(Int32)
        case noPIDFile(String)
        case badURL(String)

        var errorDescription: String? {
            switch self {
            case .noExecutable: return "TBDModelProxy was not built beside the test bundle"
            case .spawnFailed(let code): return "posix_spawn failed with \(code)"
            case .noPIDFile(let detail): return "no proxy pid file: \(detail)"
            case .badURL(let text): return "not a URL: \(text)"
            }
        }
    }

    /// Spawns a proxy on `home`.
    ///
    /// - Parameter inheritDescriptor: handed down on descriptor 9 and named by
    ///   `--lock-fd`, the way the daemon's spawner hands the `flock` down.
    static func start(home: String, port: Int = 0, inheritDescriptor: Int32? = nil) throws
        -> ProxyProcess
    {
        guard let executable = ProxyExecutable.locate() else { throw ProcessError.noExecutable }
        // The log lives beside the home rather than inside it, so the test that
        // hands the binary an unusable home still gets its diagnostics.
        let logPath = home + ".log"

        var arguments: [String] = [executable.path, "--home", home, "--port", String(port)]
        if inheritDescriptor != nil { arguments += ["--lock-fd", "9"] }

        // O_CLOEXEC on both: they are dup2'd onto the child's stdio, and the
        // originals must vanish at exec rather than leaking further down.
        let logFD = open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        let nullFD = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer {
            if logFD >= 0 { close(logFD) }
            if nullFD >= 0 { close(nullFD) }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, nullFD, 0)
        posix_spawn_file_actions_adddup2(&actions, logFD, 1)
        posix_spawn_file_actions_adddup2(&actions, logFD, 2)

        var relocated: Int32 = -1
        defer { if relocated >= 0 { close(relocated) } }
        if var source = inheritDescriptor {
            // `dup2(fd, fd)` succeeds WITHOUT clearing FD_CLOEXEC, so a
            // descriptor already sitting on the target number would be closed
            // at exec. `dup` hands back the lowest free number, which cannot be
            // the occupied one.
            if source == 9 {
                relocated = dup(source)
                guard relocated >= 0 else { throw ProcessError.spawnFailed(errno) }
                source = relocated
            }
            posix_spawn_file_actions_adddup2(&actions, source, 9)
        }

        var spawnedPID: pid_t = 0
        var argv = arguments.map { strdup($0) }
        argv.append(nil)
        // Explicit and rc-free, and in particular carrying no `TBD_HOME`: the
        // proxy is given its home on the command line, and a leaked one would
        // let a passing test be the accident of the developer's real config.
        let envpStrings: [String] = ["PATH=/usr/bin:/bin"]
        var envp = envpStrings.map { strdup($0) }
        envp.append(nil)
        defer {
            for entry in argv { free(entry) }
            for entry in envp { free(entry) }
        }

        let result = posix_spawn(&spawnedPID, executable.path, &actions, nil, &argv, &envp)
        guard result == 0 else { throw ProcessError.spawnFailed(result) }
        return ProxyProcess(pid: spawnedPID, home: home, logPath: logPath)
    }

    /// Whatever the proxy wrote to its redirected stdio, for a failure message.
    func log() -> String {
        (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "<no log>"
    }

    var pidFilePath: String { home + "/proxy/proxy.pid" }

    /// Waits for `proxy.pid` and returns what it names.
    func awaitPIDFile(seconds: Double = 30) async throws -> (pid: Int32, port: Int) {
        let path = pidFilePath
        let found = await waitUntil(
            "the proxy to write its pid file", seconds: seconds,
            sample: { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" },
            isSatisfied: { $0.split(separator: "\n").count >= 2 })
        guard found else { throw ProcessError.noPIDFile("\(path); log:\n\(log())") }

        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        guard let pid = Int32(lines[0]), let port = Int(lines[1]) else {
            throw ProcessError.noPIDFile("unreadable at \(path): \(lines)")
        }
        return (pid: pid, port: port)
    }

    /// Reaps the process and returns its exit status, or nil if it never exited
    /// inside the budget. A process killed by a signal reports the negated
    /// signal number, so a crash cannot be mistaken for a clean exit.
    @discardableResult
    func awaitExit(seconds: Double = 30) async -> Int32? {
        if let already = lock.withLock({ reapedStatus }) { return already }
        let target = pid
        let observed = TestCounter()
        let done = await waitUntil(
            "the proxy to exit", seconds: seconds,
            sample: { () -> Bool in
                var raw: Int32 = 0
                guard waitpid(target, &raw, WNOHANG) == target else { return false }
                observed.set(Int(ProxyProcess.exitCode(raw: raw)))
                return true
            },
            isSatisfied: { $0 })
        guard done else { return nil }
        let status = Int32(observed.value)
        lock.withLock { reapedStatus = status }
        return status
    }

    /// TERM, then reap. Called from every test's `defer`, so a failed assertion
    /// never leaves a listener holding a port or a child unreaped.
    func terminate() {
        guard lock.withLock({ reapedStatus }) == nil else { return }
        kill(pid, SIGTERM)
        var raw: Int32 = 0
        var waited = 0
        while waitpid(pid, &raw, WNOHANG) != pid && waited < 300 {
            usleep(10_000)
            waited += 1
        }
        if waited >= 300 {
            kill(pid, SIGKILL)
            _ = waitpid(pid, &raw, 0)
        }
        lock.withLock { reapedStatus = ProxyProcess.exitCode(raw: raw) }
    }

    /// `WEXITSTATUS`, or the negated signal for a process that was killed.
    static func exitCode(raw: Int32) -> Int32 {
        (raw & 0x7f) == 0 ? ((raw >> 8) & 0xff) : -(raw & 0x7f)
    }

    static func url(port: Int, path: String) throws -> URL {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw ProcessError.badURL(path)
        }
        return url
    }

    /// `GET /tbd/status` on a loopback port.
    static func status(port: Int) async throws -> ModelProxyStatus {
        let statusURL = try url(port: port, path: "/tbd/status")
        let (data, response) = try await session.data(from: statusURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return try ModelProxyStatus.decodeStatusResponse(data)
    }
}
