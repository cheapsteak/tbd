import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `ModelProxySupervisor` against the **real** `TBDModelProxy`.
///
/// The unit suite drives a `StubSpawner` and a `FakeProxyProcess`, which can
/// produce any answer on demand but cannot show that the three facts adoption
/// now turns on are the ones the real binary actually publishes: the `home` in
/// its status document, the `<pid>\n<port>\n` in the file it writes after its
/// bind, and its own entry in the process table. Each of those crosses a
/// process boundary between two independently-built targets, and each fails
/// *silently* if the two sides disagree — a daemon that cannot adopt mints a
/// fresh port and orphans a live proxy rather than erroring.
///
/// Tier 3 (`docs/specs/2026-07-24-test-hardening-design.md` §3): it spawns
/// children that bind real ports. Everything under `fencedScratchRoot`, so the
/// wrapper's EXIT trap reclaims the home even if the run is killed, and every
/// proxy it starts is accounted for before the test returns.
@Suite("Model proxy supervisor (live)", .serialized)
struct ModelProxyLiveTests {

    /// One run through the whole supervisor lifecycle, on one home, because
    /// each hop is the setup for the next: a spawn produces the proxy the
    /// second supervisor has to adopt, and that adoption produces the live
    /// proxy a version replacement has to retire and take the port from.
    /// Splitting them would mean three homes and three spawns to reach the same
    /// three assertions.
    @Test("the supervisor spawns the real proxy, a second adopts it, and a replacement takes its port")
    func theSupervisorDrivesTheRealBinary() async throws {
        let executable = try #require(
            LiveProxyExecutable.locate(), "TBDModelProxy was not built into the products directory")
        let ownVersion = try #require(
            ModelProxyVersion.identity(of: executable),
            "the daemon could not compute an identity for the binary it would spawn")

        let root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdmpsup"))
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Every proxy this test starts, minus the ones it has collected. The
        // `defer` is the backstop for a failed expectation part-way through:
        // a proxy left behind here holds a lock, binds a port, and self-retires
        // only after 24 hours, so an escaped one outlives the whole test run.
        // The happy path empties this list politely, through `/tbd/retire`.
        var outstanding: [pid_t] = []
        defer {
            for pid in outstanding {
                kill(pid, SIGKILL)
                var ignored: Int32 = 0
                _ = waitpid(pid, &ignored, 0)
            }
        }

        let db = try TBDDatabase(inMemory: true)
        // Explicit and rc-free, carrying no `TBD_HOME`: a proxy that found its
        // home in the environment rather than on the `--home` this spawner
        // passes would make the whole suite pass for the wrong reason, and
        // against the developer's real `~/tbd`.
        let spawner = ModelProxySpawner(
            executableURL: executable, environment: ["PATH": "/usr/bin:/bin"])
        let paths = ProxyHomePaths(home: home)
        let canonicalHome = ModelProxyStatus.canonicalHome(home.path)

        // A supervisor whose watch will never fire on its own. Every hop below
        // is driven by an explicit `start()`, so the assertions describe what
        // the startup algorithm decided rather than racing a timer; the
        // respawn backoff is real time and short, because a bind that has to
        // wait for a predecessor's listener to close is the one wait here that
        // genuinely happens.
        func makeSupervisor(version: String) -> ModelProxySupervisor {
            ModelProxySupervisor(
                config: db.config,
                home: home,
                spawner: spawner,
                ownVersion: version,
                watchInterval: .seconds(3600),
                respawnBackoff: [.milliseconds(200), .seconds(1), .seconds(2)])
        }

        // MARK: Hop 1 — a spawn, and the rendezvous it publishes

        let first = makeSupervisor(version: ownVersion)
        await first.start()
        await first.stop()

        let spawned = try #require(await first.current, "the supervisor started no proxy")
        outstanding.append(spawned.pid)
        #expect(spawned.adopted == false, "a proxy this supervisor spawned is not an adopted one")
        #expect(spawned.port > 0)

        let status = try await ModelProxyClient(port: spawned.port).status()
        #expect(status.pid == spawned.pid)
        #expect(status.port == spawned.port)
        // **The Part A hand-off.** The proxy reports the home it was started
        // for, canonicalized on its side, and the daemon compares it against
        // its own canonicalized home. A scratch root under `/var` that is
        // really `/private/var` is exactly the shape that makes a naive string
        // comparison fail, so this is asserted against the canonical form and
        // not against `home.path`.
        #expect(status.home == canonicalHome)
        #expect(status.version == ownVersion, "the proxy's version is the one the daemon computed")

        // The other half of the hand-off: the file the real binary writes is
        // the one the daemon's parser reads, in the shape adoption requires.
        #expect(
            ModelProxyPIDFile().read(path: paths.pidPath)
                == ModelProxyPIDFileRecord(pid: spawned.pid, port: spawned.port),
            "the pid file the real proxy wrote is not what the daemon parses out of it")
        #expect(try await db.config.get().modelProxyPort == spawned.port)

        // MARK: Hop 2 — a second daemon adopts it

        // This is the restart path: a fresh supervisor on the same home reads
        // the persisted port, probes it, and must take the running proxy over
        // rather than spawn a second one. All four identity checks are live
        // here — the home off the wire, the process table, and the pid file's
        // pid and port — so any one of them disagreeing with what the real
        // binary publishes lands us with `current == nil` (the lock refuses the
        // spawn, and the probe behind it refuses the adoption too).
        let second = makeSupervisor(version: ownVersion)
        await second.start()
        await second.stop()

        let adopted = try #require(
            await second.current,
            "a second supervisor neither adopted the running proxy nor started one")
        #expect(adopted.pid == spawned.pid, "the second supervisor must adopt, not replace")
        #expect(adopted.port == spawned.port)
        #expect(adopted.adopted == true, "a proxy this process did not spawn is an adopted one")

        // MARK: Hop 3 — a version replacement takes the same port

        // The one thing that retires a healthy proxy: a daemon that would spawn
        // a different build. `retire()` returns once the listener is closed and
        // the lock released, which is the moment the successor may bind — so
        // this hop is also the live proof that the predecessor really does let
        // go of both, rather than holding the port until it has finished
        // draining.
        let replacer = makeSupervisor(version: "0000000-0000000000")
        await replacer.start()
        await replacer.stop()

        let successor = try #require(
            await replacer.current, "the version replacement left this home with no proxy")
        outstanding.append(successor.pid)
        #expect(successor.pid != spawned.pid, "a replacement is a new process, not a relabelling")
        #expect(successor.port == spawned.port, "the successor takes the port its predecessor held")
        #expect(successor.adopted == false, "the successor is this process's own child")

        // The predecessor was asked to go and has no streams to drain, so it
        // exits. It is this process's child — `posix_spawn` ran here — so
        // collecting it is this test's job, and an uncollected one is a zombie
        // for the rest of the run.
        let predecessorExited = await pollUntilTrue(timeout: .seconds(20)) {
            Self.reap(pid: spawned.pid)
        }
        #expect(predecessorExited == .satisfied, "the replaced proxy never exited")
        if predecessorExited == .satisfied { outstanding.removeAll { $0 == spawned.pid } }

        // The successor's own rendezvous replaced the predecessor's, which is
        // the fact `ProxyPIDFile.removeIfOwned` exists to protect: the
        // predecessor exits *after* the successor has written its file, and an
        // unconditional unlink on the way out would leave a live proxy with no
        // rendezvous at all.
        let rendezvousMoved = await pollUntilTrue(timeout: .seconds(20)) {
            ModelProxyPIDFile().read(path: paths.pidPath)
                == ModelProxyPIDFileRecord(pid: successor.pid, port: successor.port)
        }
        #expect(rendezvousMoved == .satisfied, "the successor's pid file did not survive its predecessor's exit")

        // MARK: Teardown — nothing this test started is left running

        try await ModelProxyClient(port: successor.port).retire()
        let successorExited = await pollUntilTrue(timeout: .seconds(20)) {
            Self.reap(pid: successor.pid)
        }
        #expect(successorExited == .satisfied, "the proxy never exited after answering /tbd/retire")
        if successorExited == .satisfied { outstanding.removeAll { $0 == successor.pid } }

        #expect(outstanding.isEmpty, "this test left \(outstanding.count) proxy process(es) running")
        #expect(
            !FileManager.default.fileExists(atPath: paths.pidPath),
            "the last proxy left its pid file behind")
    }

    /// True once `pid` has been collected. Reaping inside the poll is
    /// deliberate: these children were spawned by this process, so somebody
    /// here has to.
    private static func reap(pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == pid
    }
}
