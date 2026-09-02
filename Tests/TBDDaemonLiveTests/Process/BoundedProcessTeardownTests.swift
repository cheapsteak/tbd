import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// `BoundedProcessTeardown` against real children and the kernel's own answers.
///
/// **Tier 3.** Every process here is real, because the property under test is a
/// property of real reaping: that `isRunning == false` means Foundation has
/// already collected the corpse, and that a bound which fires says so instead of
/// spinning. A fake `Process` could state neither.
///
/// The last test is the mutation check for the deadline itself, and it is the
/// reason `ExitObservableProcess` exists: a stub whose `isRunning` never flips
/// cannot be built out of `Process`.
@Suite(.serialized)
struct BoundedProcessTeardownTests {

    // MARK: - Process helpers

    /// A child that stays alive for as long as any of these tests could need it,
    /// and no longer.
    ///
    /// The loop is **counted**, not `while :`, for the reason the sibling
    /// fixture in `AgentReaperHolderLegLiveTests` gives: a process this test
    /// spawns and can no longer reach — the test host killed mid-run, which
    /// happens on a shared machine — would otherwise spin forever with no
    /// reconciler that can see it. 1500 × 0.2 s is ~5 minutes, two orders of
    /// magnitude past what any assertion here needs.
    private static func spawnLongLived() throws -> Process {
        try spawn("/bin/zsh", ["-c", #"trap "" HUP; for _ in {1..1500}; do sleep 0.2; done"#])
    }

    private static func spawn(_ path: String, _ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// A long-lived child that **Foundation does not own**: `posix_spawn`ed
    /// directly, so no `Process` object is monitoring it and this test is the
    /// only waiter for its corpse.
    ///
    /// The mutation check needs that. A Foundation-launched child has a monitor
    /// racing for the same corpse, and there the bounded wait polls a *stub's*
    /// flag rather than that child's — so the helper's post-bound safety
    /// argument, which is about the process whose own flag was polled, would not
    /// cover the diagnostic's `waitpid`. With nothing else waiting, the probe is
    /// the sole waiter and the outcome is deterministic.
    ///
    /// The loop is counted for the same reason `spawnLongLived`'s is.
    private static func spawnUnownedLongLived() throws -> pid_t {
        let path = "/bin/zsh"
        let script = #"trap "" HUP; for _ in {1..1500}; do sleep 0.2; done"#
        let arguments: [String] = [path, "-c", script]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        // An explicit one-entry environment rather than this process's own:
        // `environ` is linked into the main executable and is not reachable from
        // a test bundle, and the fixture needs nothing but a PATH that resolves
        // `sleep`. No `-l`/`-i` either, so it sources nothing from the
        // developer's shell configuration.
        let environment: [String] = ["PATH=/usr/bin:/bin"]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) }
        envp.append(nil)
        defer {
            for arg in argv { free(arg) }
            for entry in envp { free(entry) }
        }

        // No file actions and no attributes: the child inherits this process's
        // stdio (it writes nothing) and its signal mask, which cannot matter
        // because every signal sent to it here is SIGKILL.
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, nil, nil, &argv, &envp)
        guard rc == 0 else { throw SpawnFailure(code: rc) }
        return pid
    }

    /// What `kill(pid, 0)` says about a pid, as one word, so an assertion can be
    /// made on composed output rather than on a bare `-1`.
    ///
    /// `"alive"` covers a zombie too — an uncollected corpse answers `kill(pid,
    /// 0)` with success — which is exactly why `"ESRCH"` is the interesting
    /// answer: it is the one that only a *collected* process gives.
    private static func kernelView(of pid: Int32) -> String {
        if kill(pid, 0) == 0 { return "alive" }
        switch errno {
        case ESRCH: return "ESRCH"
        case EPERM: return "EPERM (alive, another uid)"
        default: return "errno \(errno)"
        }
    }

    /// Bounded poll of Foundation's own flag. Deliberately not
    /// `BoundedProcessTeardown.awaitExit`, so a test that means to observe the
    /// exit independently is not asserting the helper against itself.
    private static func waitUntilNotRunning(
        _ process: Process, within seconds: Double
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !process.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !process.isRunning
    }

    // MARK: - The ordinary teardown path

    /// The case every `defer` in the live target takes: a child still running
    /// when its test ends. It must be gone *and collected* afterwards — a
    /// teardown that left zombies behind would pass a liveness check built on
    /// `kill(pid, 0)` and quietly fill the process table for the rest of the run.
    @Test func aRunningChildIsKilledAndCollected() throws {
        let child = try Self.spawnLongLived()
        defer { BoundedProcessTeardown.killAndReap(child) }
        let pid = child.processIdentifier
        #expect(Self.kernelView(of: pid) == "alive", "the fixture must be running before the kill")

        #expect(BoundedProcessTeardown.killAndReap(child) == .exited)

        #expect(child.isRunning == false)
        #expect(
            Self.kernelView(of: pid) == "ESRCH",
            "pid \(pid) was not collected; a zombie would still answer kill(pid, 0)")
    }

    /// A child that exited before teardown reached it costs nothing. This is the
    /// common case in practice — the test killed it, or it ended on its own —
    /// and the helper must return on the first check rather than sleeping out a
    /// poll interval per child.
    @Test func aChildThatAlreadyExitedIsReportedWithoutWaiting() async throws {
        let child = try Self.spawn("/usr/bin/true", [])
        defer { BoundedProcessTeardown.killAndReap(child) }

        #expect(
            await Self.waitUntilNotRunning(child, within: 5),
            "/usr/bin/true was still running after 5 seconds")

        let clock = ContinuousClock()
        let started = clock.now
        let outcome = BoundedProcessTeardown.killAndReap(child)
        let elapsed = started.duration(to: clock.now)

        #expect(outcome == .exited)
        #expect(
            elapsed < .seconds(1),
            "teardown of an already-exited child took \(elapsed); it should not have waited at all")
    }

    // MARK: - The bound

    /// `awaitExit` observes and never actuates. That split is the API's contract
    /// — `killAndReap` is the only actuator, and the observe-only half is named
    /// for what it does not do — and a contract nothing pins is one a later
    /// "signal just to be sure" edit can quietly break, under a name that still
    /// reads as harmless at every call site.
    @Test func awaitExitNeverSignals() async throws {
        let child = try Self.spawnLongLived()
        defer { BoundedProcessTeardown.killAndReap(child) }
        let pid = child.processIdentifier

        let outcome = BoundedProcessTeardown.awaitExit(child, within: 0.3)
        guard case .unobserved(let reportedPID, let diagnostic) = outcome else {
            Issue.record("awaitExit reported \(outcome) for a child that is still running")
            return
        }
        #expect(reportedPID == pid)
        #expect(
            diagnostic.contains("still running"),
            "the diagnostic did not name what the kernel saw: \(diagnostic)")

        let psStat = ProductionProcessSignaller().stat(pid) ?? ""
        #expect(
            !psStat.isEmpty && !psStat.hasPrefix("Z"),
            "awaitExit signalled pid \(pid); ps stat is now '\(psStat)'")

        #expect(BoundedProcessTeardown.killAndReap(child) == .exited)
    }

    /// **The mutation check.** A process whose exit is never observed must end
    /// the wait at the deadline and report it, not spin.
    ///
    /// What it discriminates: delete the deadline from `awaitExit` and the
    /// helper polls a flag that never flips, so no outcome is ever published and
    /// the watchdog below reds the test with a named diagnostic. Change the
    /// helper's parameter type back to `Process` and this test no longer
    /// compiles at all, because the stub cannot be a `Process`.
    ///
    /// Two details keep it honest. The stub carries the pid of a **real**
    /// long-lived child this test spawned and owns, so the SIGKILL
    /// `killAndReap` sends lands on something the test is responsible for rather
    /// than on a made-up number that may belong to anybody — and because that
    /// child is `posix_spawn`ed rather than Foundation-launched, this test is
    /// its only waiter. So the sequence is deterministic: the SIGKILL lands at
    /// t≈0, the child is a zombie well before the 0.3 s bound, and the
    /// diagnostic probe is the thing that collects it. That is exactly what
    /// production teardown does when Foundation has lost the exit, which is why
    /// the composed diagnostic is asserted rather than only its pid. And the
    /// bounded wait runs on a dedicated `Thread`, per `Tests/CLAUDE.md`
    /// "Thread-blocking gates run off the cooperative pool": the cooperative
    /// pool is only as wide as the machine has cores, and parking one of its
    /// threads for the whole bound starves every suspended task in the process,
    /// including the ones that would report a failure.
    @Test func theBoundFiresWhenTheExitIsNeverObserved() async throws {
        let pid = try Self.spawnUnownedLongLived()
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            // SIGKILL cannot be blocked, so this is bounded; it returns
            // immediately with ECHILD when the diagnostic probe already
            // collected the corpse. Same shape as `SIGTERMProofJob.tearDown` in
            // the sibling suite.
            _ = waitpid(pid, &status, 0)
        }

        let stub = ExitNeverObserved(pid: pid)
        let box = OutcomeBox()
        let clock = ContinuousClock()
        let started = clock.now

        let thread = Thread {
            box.store(BoundedProcessTeardown.killAndReap(stub, within: 0.3))
        }
        thread.name = "BoundedProcessTeardownTests.bound"
        thread.start()

        let watchdog = Date().addingTimeInterval(5)
        var collected: BoundedProcessTeardown.Outcome?
        while Date() < watchdog {
            if let value = box.value {
                collected = value
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let elapsed = started.duration(to: clock.now)

        // The watchdog diagnostic is recorded as an `Error`, not as a `#require`
        // comment: this is the failure a deleted deadline produces, and only
        // `Issue.record(_: some Error)` puts its text where a CI summary keeps
        // it (`Tests/CLAUDE.md`, "Assertion hygiene" rule 4).
        guard let delivered = collected else {
            Issue.record(BoundNeverReturned(pid: pid, watchdogSeconds: 5))
            return
        }
        guard case .unobserved(let reportedPID, let diagnostic) = delivered else {
            Issue.record("the bound did not fire; the wait reported \(delivered)")
            return
        }
        #expect(reportedPID == pid)
        // Composed, not just the pid: with this test the sole waiter, the probe
        // must find and collect the corpse, so the branch it reports is itself
        // part of the contract.
        #expect(
            diagnostic.contains("\(pid)")
                && diagnostic.contains("zombie collected by the teardown diagnostic"),
            "the diagnostic did not report the corpse it collected: \(diagnostic)")
        #expect(
            elapsed >= .milliseconds(300),
            "the wait returned after \(elapsed), which is short of its own 0.3 s bound")
    }
}

/// `posix_spawn` refused. Bare `Error` with the raw code, matching
/// `FixtureSpawnFailure` in the sibling suite.
private struct SpawnFailure: Error {
    let code: Int32
}

/// The watchdog in the mutation check fired: the bounded wait published no
/// outcome at all, which is what a deleted deadline looks like from outside.
///
/// An `Error` rather than a string for the reason `Tests/CLAUDE.md` gives under
/// "Assertion hygiene" rule 4: `Issue.record(_: some Error)` is the only shape
/// whose text lands on the primary failure line that CI summaries keep.
private struct BoundNeverReturned: Error, CustomStringConvertible {
    let pid: Int32
    let watchdogSeconds: Int

    var description: String {
        """
        the bounded wait never returned: no outcome was published within the \
        \(watchdogSeconds) s watchdog for pid \(pid), whose isRunning never flips
        """
    }
}

/// A process that is forever about to exit: `isRunning` never flips, which is
/// precisely the state `Process.waitUntilExit()` cannot escape and the deadline
/// exists for.
private final class ExitNeverObserved: ExitObservableProcess, @unchecked Sendable {
    let processIdentifier: Int32
    var isRunning: Bool { true }

    init(pid: Int32) { processIdentifier = pid }
}

/// Publishes the outcome from the dedicated thread back to the test body.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BoundedProcessTeardown.Outcome?

    var value: BoundedProcessTeardown.Outcome? { lock.withLock { stored } }

    func store(_ outcome: BoundedProcessTeardown.Outcome) { lock.withLock { stored = outcome } }
}
