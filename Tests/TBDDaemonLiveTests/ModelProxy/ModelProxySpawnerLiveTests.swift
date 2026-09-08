import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The spawner and the client against the **real** `TBDModelProxy`.
///
/// The unit suites use a shell script, which can produce any exit status on
/// demand but cannot show that the real binary still produces them, that the
/// pid file it writes is the one this spawner parses, or that the version it
/// reports is the string the daemon computes for the same file. Those three
/// are the whole hand-off between Part A and Part B, and none of them is
/// checkable without spawning the thing.
///
/// Tier 3 (`docs/specs/2026-07-24-test-hardening-design.md` §3): it spawns a
/// child that binds a real port.
@Suite("Model proxy spawner (live)", .serialized)
struct ModelProxySpawnerLiveTests {

    /// One spawn, end to end: the port comes back, `status` names the child we
    /// were handed, the version matches what the daemon computes for the
    /// binary it spawned, and `retire` ends the process.
    @Test("the real proxy publishes a port, answers status, and retires on request")
    func aRealProxySpawnsAnswersAndRetires() async throws {
        let executable = try #require(
            LiveProxyExecutable.locate(), "TBDModelProxy was not built into the products directory")

        let root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdmpl"))
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Explicit and rc-free, carrying no `TBD_HOME`: a proxy that found its
        // home in the environment rather than on the command line would make
        // this suite pass for the wrong reason — and against the developer's
        // real `~/tbd`.
        let spawner = ModelProxySpawner(
            executableURL: executable, environment: ["PATH": "/usr/bin:/bin"])

        let spawned = try await spawner.spawn(port: 0, home: home)
        var collected = false
        defer {
            if !collected {
                kill(spawned.pid, SIGKILL)
                var ignored: Int32 = 0
                _ = waitpid(spawned.pid, &ignored, 0)
            }
        }

        #expect(spawned.port > 0, "a kernel-assigned port came back as \(spawned.port)")

        let client = ModelProxyClient(port: spawned.port)
        let status = try await client.status()
        #expect(status.pid == spawned.pid)
        #expect(status.port == spawned.port)
        #expect(status.streamsInFlight == 0)
        #expect(status.routeCount == 0)

        // The daemon's side of the version comparison, computed here exactly
        // as `ModelProxySupervisor` will compute it: on the sibling binary it
        // would spawn. A proxy reporting `unknown` compares unequal to every
        // real identity, which is why that leg is asserted separately — it
        // would otherwise pass by both sides failing to read the file.
        #expect(status.version != ModelProxyVersion.unknown)
        #expect(status.version == ModelProxyVersion.identity(of: executable))

        // A second spawn against a live proxy's home is refused by the lock,
        // without touching the running proxy's rendezvous.
        //
        // do/catch rather than `#expect(throws:)` because the branch that must
        // not happen leaves a **real proxy** behind: bound to a port, holding
        // a lock, and self-retiring only after 24 hours. `#expect` discards
        // what the closure returned, so the pid would be unrecoverable; here
        // it is killed and reaped before the failure is recorded.
        do {
            let unexpected = try await spawner.spawn(port: spawned.port, home: home)
            kill(unexpected.pid, SIGKILL)
            var ignored: Int32 = 0
            _ = waitpid(unexpected.pid, &ignored, 0)
            Issue.record(
                """
                a second spawn on a live proxy's home succeeded as pid \(unexpected.pid) \
                on port \(unexpected.port); it was killed
                """)
        } catch ModelProxySpawner.Error.lockHeld {
            // Expected: the running proxy holds `proxy.lock`.
        }

        try await client.retire()
        let exited = await pollUntilTrue(timeout: .seconds(20)) {
            Self.reap(pid: spawned.pid)
        }
        if exited == .satisfied { collected = true }
        #expect(exited != .timedOut, "the proxy never exited after answering /tbd/retire")

        // The pid file is reclaimed on the way out, and only because the file
        // still named this process — which is also the pid the spawner parsed
        // out of it. One assertion, both halves of that agreement.
        #expect(
            !FileManager.default.fileExists(atPath: ProxyHomePaths(home: home).pidPath),
            "the retired proxy left its pid file behind")
    }

    /// True once `pid` has been collected. Reaping inside the poll is
    /// deliberate: the daemon is this child's parent, so somebody has to.
    private static func reap(pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == pid
    }
}

/// `TBDModelProxy` as SwiftPM staged it beside this test bundle.
///
/// The product is a declared dependency of this target, so it is built and
/// lands in the same products directory; the search is over the two shapes
/// that directory takes rather than over `PATH`.
enum LiveProxyExecutable {
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
