import Clocks
import Darwin
import Foundation
import NIOCore
import NIOHTTP1
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
    @Test("a bad invocation exits 2 with a usage diagnostic and a silent stdout")
    func aBadInvocationExitsTwoWithAUsageDiagnostic() throws {
        let executable = try #require(ProxyExecutable.locate())
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--stream-dir", "/tmp"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == TBDModelProxyExit.badArguments)
        let diagnostic = String(decoding: stderrData, as: UTF8.self)
        #expect(diagnostic.contains("unknown argument --stream-dir"))
        #expect(diagnostic.contains("--lock-fd"), "the usage line must name the descriptor flag")
        #expect(stdoutData.isEmpty, "a proxy must never write to stdout")
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
    /// `Clock`, so a `TestClock` crosses it without a real sleep. The *window*
    /// is a span between two `Date`s, which is what the production check
    /// compares, and the test moves that wall clock by hand. `Duration` is
    /// behavior, `Date` is data.
    @Suite("Proxy retention watch")
    struct ProxyRetentionTests {

        @Test("an idle proxy nobody has contacted for the window retires itself")
        func selfRetireExitsWhenIdleAndUnattended() async throws {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let wall = MovableWallClock(start)
            let retires = TestCounter()
            let clock = TestClock()

            let watch = ProxyRetireWatch(
                lastDaemonContact: { start },
                streamsInFlight: { 0 },
                onRetire: { retires.increment() },
                checkInterval: .seconds(60),
                unattendedAfter: 24 * 60 * 60,
                now: { wall.read() },
                clock: clock)
            let task = Task { await watch.run() }
            defer { task.cancel() }

            // First sample: the contact is fresh, so nothing happens. This is
            // the discriminating leg — a watch that retired on its first tick
            // would satisfy every assertion below and fail here.
            await advanceUntilSampled(clock, wall)
            #expect(retires.value == 0, "the watch retired a proxy contacted a moment ago")

            // A day passes on the wall clock while the daemon says nothing.
            wall.advance(24 * 60 * 60)
            await advanceUntilSampled(clock, wall)
            await waitUntil(
                "the watch retired the unattended proxy", sample: { retires.value },
                isSatisfied: { $0 >= 1 })

            // Once, and then the loop is done: `onRetire` ends the process, and
            // a second call would be a second exit.
            await clock.advance(by: .seconds(600))
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
            let clock = TestClock()

            let watch = ProxyRetireWatch(
                lastDaemonContact: { start },
                streamsInFlight: { inFlight.value },
                onRetire: { retires.increment() },
                checkInterval: .seconds(60),
                unattendedAfter: 24 * 60 * 60,
                now: { wall.read() },
                clock: clock)
            let task = Task { await watch.run() }
            defer { task.cancel() }

            wall.advance(48 * 60 * 60)
            await advanceUntilSampled(clock, wall)
            #expect(retires.value == 0, "a turn in flight was cut by the retention watch")

            // The turn ends; the next sample retires.
            inFlight.set(0)
            await advanceUntilSampled(clock, wall)
            await waitUntil(
                "the watch retired once the last stream ended", sample: { retires.value },
                isSatisfied: { $0 >= 1 })
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

        /// Advances virtual time until the watch has taken one more sample.
        ///
        /// A plain `advance` is not enough on its own: `TestClock.advance` moves
        /// `now` whether or not a sleeper is armed, and an advance that lands
        /// before the watch has parked leaves the clock permanently ahead of a
        /// sleep scheduled afterwards. Retrying is self-healing — a later
        /// advance passes the deadline the sleeper eventually registered — and
        /// the sample count makes "it never ran at all" a named failure rather
        /// than an assertion that passes vacuously.
        ///
        /// The count comes from the wall clock: `run()` reads `now()` exactly
        /// once per iteration, after its sleep returns.
        private func advanceUntilSampled(
            _ clock: TestClock<Duration>, _ wall: MovableWallClock,
            interval: Duration = .seconds(60)
        ) async {
            let before = wall.reads
            for _ in 0..<40 {
                await clock.advance(by: interval)
                if wall.reads > before { return }
            }
            Issue.record("the retention watch never took a sample")
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
                        streamsInFlight: 0, routeCount: 0)
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
            let home = proxyScratchRoot(prefix: "pxrun").path
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

        @Test("a route written before the spawn is servable without a control call")
        func startsWithExistingRoutes() async throws {
            let upstream = FakeUpstream { _, _ in
                FakeUpstream.Script(
                    headers: [("content-type", "application/json")],
                    events: [(delayMs: 0, bytes: Array(#"{"ok":true}"#.utf8))])
            }
            let upstreamPort = try upstream.start()
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

/// A wall clock the test moves by hand, counting reads.
///
/// The count is what makes the retention watch observable: `run()` reads
/// `now()` exactly once per iteration, so a change in `reads` is proof it took
/// a sample rather than an assumption that it did.
final class MovableWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date
    private var readCount = 0

    init(_ start: Date) { self.now = start }

    var reads: Int { lock.withLock { readCount } }

    func read() -> Date {
        lock.withLock {
            readCount += 1
            return now
        }
    }

    func advance(_ interval: TimeInterval) {
        lock.withLock { now = now.addingTimeInterval(interval) }
    }
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
