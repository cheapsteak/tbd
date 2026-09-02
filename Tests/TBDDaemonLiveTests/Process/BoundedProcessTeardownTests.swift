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
        try spawn(
            "/bin/zsh", ["-f", "-c", #"trap "" HUP; for _ in {1..1500}; do sleep 0.2; done"#])
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
        // `-f` so zsh reads no user rc file (`/etc/zshenv` is read regardless of
        // `-f`) — without it `.zshenv` is read on every invocation, `-c`
        // included — and an explicit `HOME` inside the fence via
        // `NSHomeDirectory()`, which honours `CFFIXED_USER_HOME` and is how
        // `TestSupport/ShellHelpers.swift` resolves it. An env with no `HOME` at
        // all is not neutral: zsh looks the value up in the password database
        // and lands on the developer's real home.
        //
        // The environment is built by hand rather than passed through because
        // `environ` is linked into the main executable and is not reachable from
        // a test bundle; beyond `HOME`, the fixture needs nothing but a PATH
        // that resolves `sleep`.
        let arguments: [String] = [path, "-f", "-c", script]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        let environment: [String] = ["PATH=/usr/bin:/bin", "HOME=\(NSHomeDirectory())"]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) }
        envp.append(nil)
        defer {
            for arg in argv { free(arg) }
            for entry in envp { free(entry) }
        }

        // No file actions and no attributes: the child inherits this process's
        // stdio (it writes nothing) and its signal mask, which cannot matter
        // because every signal sent to it here is SIGKILL. `POSIX_SPAWN_SETSID`
        // is deliberately omitted too — the only descendant is a `sleep 0.2`,
        // which orphans to launchd for at most 0.2 s when zsh is SIGKILLed, so
        // nothing outlives the test for a reconciler to have to collect.
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
        case EPERM: return "EPERM"
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
    /// common case in practice — the test killed it, or it ended on its own.
    ///
    /// What the one-second assertion discriminates: the helper must not wait out
    /// its bound on an already-exited child. The bound here is the default, 5 s,
    /// so a helper that polled to the deadline regardless would miss by four
    /// seconds. It does **not** pin "returns without sleeping the 20 ms poll
    /// interval" — no assertion that survives a loaded shared box can measure
    /// 20 ms, and one that tried would be a flake rather than a proof.
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
    @Test func awaitExitNeverSignals() throws {
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
    /// t≈0, the child is a zombie well before the 2 s bound, and the
    /// diagnostic probe is the thing that collects it. The bound is 2 s rather
    /// than a few hundred milliseconds because under induced load a zsh and its
    /// `sleep` are not always torn down that fast, and the corpse has to exist
    /// before the probe can find it. That is exactly what
    /// production teardown does when Foundation has lost the exit, which is why
    /// the composed diagnostic is asserted rather than only its pid. And the
    /// bounded wait runs on a dedicated `Thread`, per `Tests/CLAUDE.md`
    /// "Thread-blocking gates run off the cooperative pool": the cooperative
    /// pool is only as wide as the machine has cores, and parking one of its
    /// threads for the whole bound starves every suspended task in the process,
    /// including the ones that would report a failure.
    @Test func theBoundFiresWhenTheExitIsNeverObserved() async throws {
        let pid = try Self.spawnUnownedLongLived()
        let stub = ExitNeverObserved(pid: pid)
        let box = OutcomeBox()
        defer {
            // Only reap once the helper has published an outcome. Until it does,
            // its thread still owns this pid's `waitpid`, and a second waiter
            // here would race it for one corpse. Declining leaks nothing: the
            // helper's own SIGKILL has already landed, and the fixture's counted
            // loop ends on its own regardless. Written as one condition rather
            // than an early `return`, which a `defer` body may not use.
            //
            // The second half: only `0` — "still our child, and not yet
            // collected" — licenses a signal. By the time this runs the
            // diagnostic probe has usually collected the corpse already, and a
            // pid whose corpse is gone may name somebody else's process by now;
            // `pid` (a zombie we own) and `-1`/`ECHILD` (already collected) both
            // mean there is nothing left to signal. The blocking `waitpid` after
            // the kill is bounded because SIGKILL cannot be blocked — the same
            // shape as `SIGTERMProofJob.tearDown` in the sibling suite.
            var status: Int32 = 0
            if box.value != nil, waitpid(pid, &status, WNOHANG) == 0 {
                kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
            }
        }

        // The premise, in two halves because the cheap half cannot state it: a
        // zombie answers `kill(pid, 0)` with success, so liveness needs `ps` as
        // well. Asking `ps` from a test body is fine — it is the helper's
        // failure path, which must spawn nothing, that cannot.
        #expect(
            Self.kernelView(of: pid) == "alive",
            "the unowned fixture must be running before the bound is exercised")
        #expect(
            ProductionProcessSignaller().stat(pid).map { !$0.hasPrefix("Z") } == true,
            "the unowned fixture was already a corpse before the bound was exercised")

        let clock = ContinuousClock()
        let started = clock.now

        let thread = Thread {
            box.store(BoundedProcessTeardown.killAndReap(stub, within: 2))
        }
        thread.name = "BoundedProcessTeardownTests.bound"
        thread.start()

        let watchdog = Date().addingTimeInterval(10)
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
            Issue.record(BoundNeverReturned(pid: pid, watchdogSeconds: 10))
            return
        }
        guard case .unobserved(let reportedPID, let diagnostic) = delivered else {
            Issue.record(BoundDidNotFire(outcome: delivered))
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
            elapsed >= .seconds(2),
            "the wait returned after \(elapsed), which is short of its own 2 s bound")
    }
}

/// `posix_spawn` refused. Bare `Error` with the raw code, matching
/// `FixtureSpawnFailure` in the sibling suite.
private struct SpawnFailure: Error {
    let code: Int32
}

/// The bound was reported as satisfied against a stub that can never satisfy it.
///
/// An `Error` for the same reason as `BoundNeverReturned`: this is the other
/// half of the mutation check's verdict, and its text is the whole finding.
private struct BoundDidNotFire: Error, CustomStringConvertible {
    let outcome: BoundedProcessTeardown.Outcome

    var description: String {
        "the bound did not fire: the wait reported \(outcome) for a stub whose isRunning never flips"
    }
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
