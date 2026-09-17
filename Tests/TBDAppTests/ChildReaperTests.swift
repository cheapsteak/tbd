import Darwin
import Foundation
import Testing
@testable import TBDApp
import TestSupport

/// Tier 2: real forked children, but no external server and no wall-clock
/// assertion — `reapBlocking` is deterministic by construction, and the two
/// bounded polls here observe children that have already been asked to exit.
/// It lives in `TBDAppTests` rather than the tier-3 target because
/// `Tests/TBDDaemonLiveTests` does not link `TBDApp`.
///
/// What these pin: the reaper actually reaps. SwiftTerm's `LocalProcess`
/// cancels its own exit monitor before the child exits, so `waitpid` never
/// runs and every torn-down terminal leaves a permanent `<defunct>` child under
/// TBDApp. `ChildReaper` is the guaranteed `waitpid`; a non-blocking (`WNOHANG`)
/// or event-source implementation fails `reapsAChildThatIsStillRunning` below.
///
/// HOW THESE TESTS WAIT. The background-reap tests await an **event**, not a
/// window: `ChildReaper.drainPendingReaps` fires once every reap already
/// started has *run to completion* (the reaper keeps a ledger of the reaps in
/// flight and calls back from the thread that finishes the last one the drain
/// covers). A child that still exists after that is a reap that did not
/// reap — a contract failure, not a scheduling delay. The single remaining
/// bounded poll, `waitUntilZombie`, waits for a child to **exit**, which is not
/// an in-process event and therefore has nothing to be ordered behind; it is
/// documented as a hang guard at its definition.
///
/// Both waits carry their own bounded hang guard, and that is deliberate:
/// **neither one can be rescued by the suite `.timeLimit`.** Swift Testing
/// cannot cancel a thread parked in a synchronous `waitpid`, nor a
/// `withCheckedContinuation` awaiting a barrier callback that never runs — a
/// child that ignored its signals would wedge the whole run rather than redden
/// one test. `drainPendingReaps(within:)` (see `ChildReapDrainSupport.swift`)
/// and `waitUntilZombie` each convert that into a named failure, and each
/// disposes of its child on that path so a stuck reap cannot poison the tests
/// that follow.
///
/// WHY `.fastPassBounded` AND NOT A NUMBER OF ITS OWN. What the limit has to
/// afford is a test that fails through its own guards and still gets to report:
/// the 30 s barrier hang guard plus the ~5 s `waitUntilZombie` budget plus the
/// disposal that follows — 35 s, so the diagnostic lands rather than being
/// truncated. The honest path meanwhile finishes in under a second (the
/// longest-lived child in the process is 0.3 s). This suite arms no `TestClock`,
/// which is why the trait is not spelled `.clockDriven`; but the two are one
/// value, because what sizes them is the fast parallel pass rather than virtual
/// time. The sixty seconds this used to spell out was reasoned as "four minutes
/// of a shared box is not free", and that reasoning was wrong in its premise: a
/// suite limit is wall time only on a failing run, and one minute is *below*
/// the median reported duration of a healthy test in this pass, where duration
/// is mostly suspension behind ~5000 other runnable tests. See
/// `.fastPassBounded` in `Tests/TestSupport/ClockTestSupport.swift`.
///
/// What the limit therefore is, stated rather than glossed: a coarse outer
/// backstop for the ordinary case where a test is merely slow. The two waits
/// above are what actually catch a stuck reap, and both are sized to fire —
/// with their diagnostic — inside this limit rather than be truncated by it.
@Suite("ChildReaper", .fastPassBounded)
struct ChildReaperTests {

    // MARK: - Helpers

    private enum SpawnError: Error, CustomStringConvertible {
        case posixSpawnFailed(Int32)
        case pipeFailed(Int32)
        var description: String {
            switch self {
            case .posixSpawnFailed(let code): return "posix_spawn failed with code \(code)"
            case .pipeFailed(let code): return "pipe() failed with errno \(code)"
            }
        }
    }

    private struct StillZombie: Error, CustomStringConvertible {
        let pid: pid_t
        let state: String
        var description: String {
            "pid \(pid) still existed after ChildReaper's queue drained — observed \(state). "
                + "The barrier means the reap block already ran to completion, so this is a "
                + "reap that did not reap, not a reap that has not been scheduled yet."
        }
    }

    /// Why the outcome is an enum rather than a thrown error at the point of
    /// failure: the caller has a child to dispose of before it may fail, so
    /// `waitUntilZombie` reports and the caller decides when to throw.
    private enum ZombieWaitOutcome {
        case becameZombie
        case budgetExhausted(polls: Int)
        /// The surrounding task was cancelled — in this suite that means the
        /// suite `.timeLimit` fired. Named separately because the alternative
        /// is a lie: a swallowed `CancellationError` makes every remaining
        /// `Task.sleep` return instantly, the loop burns its whole budget in
        /// microseconds, and the resulting "never became a zombie after N
        /// polls" points at production for a harness event.
        case cancelled(polls: Int)

        func diagnostic(pid: pid_t) -> (any Error)? {
            switch self {
            case .becameZombie:
                return nil
            case .budgetExhausted(let polls):
                return NeverExited(pid: pid, polls: polls)
            case .cancelled(let polls):
                return WaitCancelled(pid: pid, polls: polls)
            }
        }
    }

    private struct NeverExited: Error, CustomStringConvertible {
        let pid: pid_t
        let polls: Int
        var description: String {
            "pid \(pid) never became a reapable zombie within \(polls) polls "
                + "(it exited and something else reaped it, or it never exited)"
        }
    }

    private struct WaitCancelled: Error, CustomStringConvertible {
        let pid: pid_t
        let polls: Int
        var description: String {
            "waiting for pid \(pid) to exit was CANCELLED after \(polls) polls — the suite "
                + "time limit fired. This says nothing about whether ChildReaper is correct."
        }
    }

    /// Spawns a child with `posix_spawn` so nothing else in-process reaps it.
    /// (`Foundation.Process` installs its own `waitpid`, which would mask the
    /// behavior under test.)
    private func spawn(_ path: String, _ args: [String]) throws -> pid_t {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) }
        argv.append(nil)
        defer { for arg in argv { free(arg) } }
        let code = posix_spawn(&pid, path, nil, nil, &argv, nil)
        guard code == 0 else { throw SpawnError.posixSpawnFailed(code) }
        return pid
    }

    /// Spawns a child that exits exactly when the returned write end is
    /// closed, and not before: a `/bin/cat` whose stdin is a pipe this test
    /// owns, which sees EOF and exits when the last copy of the write end is
    /// gone. `/bin/sleep` cannot serve here — an interleaving test has to
    /// *schedule* a child's exit rather than race it against a timer.
    ///
    /// **Both ends are close-on-exec from the moment they exist**, which is
    /// load-bearing rather than tidy. A pipe is inheritable by default, this
    /// target's sibling suites spawn children that close nothing
    /// (`posix_spawn` with no attributes, SwiftTerm's `forkpty`), and a child
    /// that inherited a copy of the write end would hold the pipe open after
    /// this test closed its own — so the `read` would never see EOF, the child
    /// would never exit, and the reap would never finish. The residual is the
    /// few microseconds between `pipe` and the two `fcntl`s, the same window
    /// PR #872 left open between `socket` and its `fcntl` for the same reason:
    /// there is no atomic `pipe2` with `O_CLOEXEC` on darwin.
    ///
    /// The `adddup2` is what deliberately un-sets the flag for the child's own
    /// stdin: a duplicated descriptor does not carry `FD_CLOEXEC`, so fd 0
    /// survives the `exec` while the original does not.
    private func spawnWaitingForEOF() throws -> (pid: pid_t, writeEnd: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SpawnError.pipeFailed(errno) }
        let readEnd = fds[0]
        let writeEnd = fds[1]
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, readEnd, 0)

        let path = "/bin/cat"
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { for arg in argv { free(arg) } }
        let code = posix_spawn(&pid, path, &actions, nil, &argv, nil)
        // The child has its own copy of the read end; ours would keep the pipe
        // open and defeat the EOF this helper exists to deliver.
        close(readEnd)
        guard code == 0 else {
            close(writeEnd)
            throw SpawnError.posixSpawnFailed(code)
        }
        return (pid, writeEnd)
    }

    /// `true` while the pid still names a process this process can signal —
    /// which includes a zombie, since an unreaped child still exists.
    private func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// `true` once the child has exited and is *still waitable* — i.e. it is an
    /// unreaped zombie. `WNOWAIT` is what makes this a probe rather than a
    /// reap: it leaves the child in exactly the state it found it, so a test
    /// can assert "nobody reaped this" without doing the reaping itself.
    private func isUnreapedZombie(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG) == 0 && info.si_pid == pid
    }

    /// Describes what `pid` currently is, for a diagnostic. `WNOWAIT` keeps
    /// this a probe: it leaves the child in exactly the state it found it.
    private func describeState(_ pid: pid_t) -> String {
        if isUnreapedZombie(pid) { return "an unreaped zombie (exited, still waitable)" }
        return processExists(pid) ? "a live process (never exited)" : "gone"
    }

    /// Runs the blocking reap off the cooperative pool. Parking a concurrency
    /// worker for the child's lifetime would tax every other suite in this
    /// process (Swift Testing runs them all in one).
    ///
    /// A `Thread` rather than a global dispatch queue, for the reason
    /// `ChildReaper` itself gives: a global-queue block parks one of the
    /// process's ~64 constrained workers, and when other suites have that pool
    /// full the block never starts — a hang this test would then be reporting
    /// about libdispatch, not about the reaper.
    private func reapOffPool(_ pid: pid_t) async -> pid_t {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: ChildReaper.reapBlocking(pid: pid))
            }
            thread.name = "com.tbd.tests.reap-off-pool"
            thread.start()
        }
    }

    /// Ends and reaps a child this test deliberately left unreaped, given the
    /// state that was just observed for it.
    ///
    /// Two hazards this navigates. A pid that was already reaped must not be
    /// signalled — it is free and the OS may have recycled it. And a child that
    /// never exited must be SIGKILLed first, or the `waitpid` parks forever on
    /// a thread Swift Testing cannot cancel.
    ///
    /// **Call only after a `drainPendingReaps` that returned `.drained`.**
    /// Committing a `waitpid` while one of `ChildReaper`'s own blocks may still
    /// be parked on the same pid is the two-waiter pid-recycling hazard its doc
    /// comment forbids; the barrier is what guarantees the reaper is no longer
    /// a waiter.
    ///
    /// The one exception is the stalled-barrier path, where there is no such
    /// guarantee and disposing anyway is still right: the alternative is
    /// leaving a live child and an unreaped pid for the rest of the run. The
    /// `SIGKILL` keeps our own `waitpid` bounded there (an exiting child either
    /// gets reaped by us or returns `ECHILD` at once), and the residual — both
    /// waiters returning inside the microseconds it takes to recycle a pid into
    /// a *new* child of this process — is the coincidence-on-top-of-a-race
    /// `ChildReaper` already accepts.
    private func disposeChild(_ pid: pid_t, observedZombie: Bool) async {
        if observedZombie {
            _ = await reapOffPool(pid)  // already exited; returns at once
        } else if processExists(pid) {
            kill(pid, SIGKILL)
            _ = await reapOffPool(pid)
        }
    }

    /// A child *exiting* is not an in-process event: no queue drains and no
    /// barrier can be ordered behind it, so there is nothing to await and
    /// bounded polling is the honest instrument (assertion-hygiene rule 3).
    ///
    /// The budget is a **hang guard, not a timing assertion**. Every child
    /// waited on here is `/bin/sleep 0`, which exits in milliseconds, so a run
    /// that consumes any material part of the budget has already found a bug.
    /// It is deliberately *not* described as a wall-clock cap: `Task.sleep` is
    /// a floor, not a ceiling, so `pollBudget × pollInterval` (≈5 s) is the
    /// nominal figure and the real elapsed time is larger under load. The
    /// suite's `.timeLimit` is the outer bound; this budget only keeps a wedged
    /// child from consuming all of it.
    private static let pollBudget = 50
    private static let pollInterval = Duration.milliseconds(100)

    private func waitUntilZombie(_ pid: pid_t) async -> ZombieWaitOutcome {
        var polls = 0
        while !isUnreapedZombie(pid) {
            if polls >= Self.pollBudget { return .budgetExhausted(polls: polls) }
            if Task.isCancelled { return .cancelled(polls: polls) }
            polls += 1
            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                // Cancellation, propagated rather than swallowed — see
                // `ZombieWaitOutcome.cancelled`.
                return .cancelled(polls: polls)
            }
        }
        return .becameZombie
    }

    // MARK: - The teardown decision

    @Test("reaps when SwiftTerm's monitor has not claimed the child")
    func shouldReapUnobservedChild() {
        #expect(ChildReaper.shouldReap(pid: 4242, alreadyObserved: false))
    }

    @Test("skips when SwiftTerm's monitor already reaped the child")
    func shouldNotReapObservedChild() {
        // The monitor's own `waitpid` already ran, so the pid is free and may
        // have been recycled — waiting on it could steal another child's status.
        #expect(!ChildReaper.shouldReap(pid: 4242, alreadyObserved: true))
    }

    @Test("skips non-positive pids on either branch")
    func shouldNotReapNonPositivePids() {
        // waitpid(0, …) waits on the whole process group and waitpid(-1, …) on
        // any child — either would park on, and reap, unrelated processes. A
        // control-mode panel has no LocalProcess and lands here with 0.
        for observed in [false, true] {
            #expect(!ChildReaper.shouldReap(pid: 0, alreadyObserved: observed))
            #expect(!ChildReaper.shouldReap(pid: -1, alreadyObserved: observed))
        }
    }

    @Test("ChildExitObservation records once and stays recorded")
    func observationRecords() {
        let observation = ChildExitObservation()
        #expect(!observation.wasObserved)
        observation.record()
        #expect(observation.wasObserved)
        observation.record()
        #expect(observation.wasObserved)
    }

    // MARK: - Reaping real children

    @Test("blocking reap: waits out a still-running child and leaves no zombie")
    func reapsAChildThatIsStillRunning() async throws {
        // Deliberately still running when the reap starts: a WNOHANG
        // implementation returns 0 here and leaves the zombie behind.
        let pid = try spawn("/bin/sleep", ["0.3"])

        let reaped = await reapOffPool(pid)

        #expect(reaped == pid, "blocking waitpid must return the pid it reaped")
        #expect(!processExists(pid), "reaped child must not linger as a zombie")

        var status: Int32 = 0
        let second = waitpid(pid, &status, WNOHANG)
        #expect(second == -1 && errno == ECHILD,
                "nothing left to wait for once ChildReaper reaped the child")
    }

    @Test("already-reaped pid is a safe, non-hanging no-op")
    func reapingTwiceIsHarmless() async throws {
        let pid = try spawn("/bin/sleep", ["0"])

        let first = await reapOffPool(pid)
        #expect(first == pid)

        // The suite time limit bounds a hang; the assertion pins the contract.
        let second = await reapOffPool(pid)
        #expect(second == -1, "a second reap of the same pid must return -1 (ECHILD)")
    }

    @Test("background reap: fire-and-forget clears the zombie")
    func backgroundReapClearsTheZombie() async throws {
        let pid = try spawn("/bin/sleep", ["0"])
        ChildReaper.reap(pid: pid, unless: ChildExitObservation())

        // The barrier, not a poll: when this returns the reap block has run to
        // completion, so the assertion below is a contract check with no
        // scheduling window in it. Bounded, so a reap parked on a child that
        // never exits reds this test instead of wedging the run.
        let drain = await drainPendingReaps()
        if let diagnostic = drain.diagnostic(pid: pid, observedState: { describeState(pid) }) {
            await disposeChild(pid, observedZombie: isUnreapedZombie(pid))
            throw diagnostic
        }

        let survived = processExists(pid)
        if survived {
            let state = describeState(pid)
            // Dispose before recording, so a failing run cannot leave the child
            // behind. Safe to commit our own waitpid: the barrier above already
            // guarantees ChildReaper is no longer a waiter for this pid.
            await disposeChild(pid, observedZombie: isUnreapedZombie(pid))
            Issue.record(StillZombie(pid: pid, state: state))
        }
    }

    @Test("background reap: an already-observed child is left alone")
    func backgroundReapSkipsObservedChild() async throws {
        let pid = try spawn("/bin/sleep", ["0"])
        let observation = ChildExitObservation()
        observation.record()

        ChildReaper.reap(pid: pid, unless: observation)

        // Let the child actually exit, so "still waitable" means "nobody
        // reaped it" rather than "it had not exited yet".
        let outcome = await waitUntilZombie(pid)

        // `reap` should have early-returned without enqueuing anything, so this
        // normally fires at once. It is here because a regression that enqueued
        // the block anyway would otherwise be *racing* the assertion below —
        // and because it makes this test the sole waiter for the disposal.
        let drain = await drainPendingReaps()

        let survived = isUnreapedZombie(pid)

        // This test owns the zombie it deliberately kept. Disposed before
        // anything can throw or fail: a `defer` registered after a throwing
        // statement never runs at all, which is how a probe escapes to launchd.
        await disposeChild(pid, observedZombie: survived)

        if let diagnostic = outcome.diagnostic(pid: pid) { throw diagnostic }
        // Reported after the wait's own outcome (which happened first) and
        // before the assertion, which a stalled barrier would make unsound:
        // an enqueued reap could still be pending.
        if let diagnostic = drain.diagnostic(pid: pid, observedState: { "already disposed" }) {
            throw diagnostic
        }
        #expect(survived,
                "an observed child must be left for its real waiter, not reaped here")
    }

    // MARK: - What a drain covers

    /// **The interleaving, and why no other test in either suite constructs
    /// it.** Every other test here spawns, reaps, and drains in sequence, so by
    /// the time its drain is decided nothing is in flight — and with nothing in
    /// flight the ledger's threshold is compared against the `UInt64.max` of an
    /// empty set, where `<=` and `<` answer alike. The comparison only decides
    /// anything in the one shape below: a drain is already waiting on a reap
    /// that has not finished, a *further* reap registers while it waits, and
    /// then the reap it was waiting for finishes. The drain must fire on that
    /// last step, because the later reap is not one it covers.
    ///
    /// Tightening `Ledger.takeSatisfiedWaiters` to `<` leaves the drain waiting
    /// for that later reap instead, which here means waiting for a child whose
    /// pipe this test has not closed yet — so the wait runs out its hang guard
    /// and this test reddens. Measured one test at a time against that
    /// mutation, this is the test that catches it: it failed on its 30 s guard
    /// while `backgroundReapClearsTheZombie` and
    /// `reapsWhileTheConstrainedWorkerPoolIsExhausted` both passed. Run as a
    /// whole suite the mutation reddens all of them, because with tests in
    /// parallel some sibling's reap is nearly always in flight — worth knowing
    /// when reading such a failure, but it is overlap doing the work rather
    /// than those tests asserting anything about what a drain covers.
    ///
    /// Nothing about the ordering is raced: `reap` registers its sequence
    /// synchronously before it returns, and so does `requestDrain`, so the
    /// statements below *are* the ledger's order. What the two children buy is
    /// control over the one event that is genuinely asynchronous — a child
    /// exiting — by making each exit wait for a `close` this test performs.
    @Test("a drain fires when the reaps it covers finish, without waiting for one registered after it")
    func drainIgnoresAReapRegisteredAfterIt() async throws {
        let covered = try spawnWaitingForEOF()
        let later = try spawnWaitingForEOF()

        ChildReaper.reap(pid: covered.pid, unless: ChildExitObservation())
        let drain = requestDrain()
        ChildReaper.reap(pid: later.pid, unless: ChildExitObservation())

        // The only reap this drain covers can now finish. The other cannot:
        // its child's pipe stays open until the disposal below.
        close(covered.writeEnd)
        let outcome = await drain.wait()
        // Read before the disposal, because it is the claim this test makes:
        // a drain that had waited for the later reap could not have returned
        // while that reap's child was still running.
        let laterStillRunning = processExists(later.pid)

        // Dispose before asserting — see the suite comment. Closing the pipe
        // ends the child, and the reap already parked on it does the `waitpid`;
        // the second drain is how this test knows that thread finished rather
        // than outliving the run.
        close(later.writeEnd)
        let disposal = await drainPendingReaps()

        // The stalled diagnostic names the later child on purpose: on that
        // path it is the reap still parked, and therefore the one a reader
        // needs to see.
        if let diagnostic = outcome.diagnostic(pid: later.pid, observedState: { describeState(later.pid) }) {
            throw diagnostic
        }
        if let diagnostic = disposal.diagnostic(pid: later.pid, observedState: { describeState(later.pid) }) {
            throw diagnostic
        }
        // Vacuity guard: had the later child already exited, the drain could
        // have waited for its reap and still returned, and this test would be
        // asserting nothing about what a drain covers.
        #expect(laterStillRunning, "the later reap must still have been parked when the drain fired")
        #expect(!processExists(covered.pid), "the covered reap must have reaped its child")
        #expect(!processExists(later.pid), "the disposal must have reaped the later child")
    }

    // MARK: - The worker pool the reaper must not depend on

    /// Holds libdispatch's constrained (non-overcommit) worker pool full for
    /// as long as it lives: one block per worker slot, each parked in a `read`
    /// on a pipe nobody writes to, plus a margin so the pool stays full while
    /// the kernel is still spinning workers up. `release()` closes the write
    /// ends, every read returns 0, and the workers go back to the pool.
    ///
    /// The cap is `kern.wq_max_constrained_threads` (64 on a stock install),
    /// read from the kernel so the test exhausts *this* box's pool rather
    /// than a remembered number. Every `DispatchQueue.global()` block and every
    /// private concurrent queue draws from that pool, which is what makes it a
    /// process-wide hazard: while it is full, nothing dispatched to any of
    /// those queues starts, at any QoS.
    ///
    /// Held for milliseconds on the healthy path — the reap and drain it
    /// brackets — because for that window it also starves any sibling test's
    /// global-queue work in this process.
    ///
    /// `parked` counts the blocks that have actually reached their `read`. The
    /// kernel spins workers up one at a time over several milliseconds, so a
    /// caller that reaps the instant this returns races the fill and proves
    /// nothing — the first revision of the test below passed in 3 ms against
    /// the very queue it was written to fail on. Give `parked` a moment to
    /// reach `cap` first: from then on the margin's blocks are queued with no
    /// worker to run them, which is what "full" means.
    ///
    /// `parked` can legitimately stop short of `cap`, and that is the pool
    /// being full *by somebody else*: in the fast pass, three whole-pass runs
    /// on a 14-core box each saw only 64–67 of this kernel's 70 slots go to
    /// these blockers, because sibling suites' subprocess reads already held
    /// the rest — the very condition the reaper has to survive. So the wait is
    /// short and its expiry is not a failure; a long wait would hold every
    /// sibling's global-queue work hostage for its whole duration.
    private final class ConstrainedPoolExhaustion: @unchecked Sendable {
        private let lock = NSLock()
        private var writeEnds: [Int32] = []
        private var parkedCount = 0
        /// `kern.wq_max_constrained_threads` as this kernel reports it.
        let cap: Int
        let workers: Int

        var parked: Int { lock.lock(); defer { lock.unlock() }; return parkedCount }

        init() {
            var value: Int32 = 64
            var size = MemoryLayout<Int32>.size
            if sysctlbyname("kern.wq_max_constrained_threads", &value, &size, nil, 0) != 0 { value = 64 }
            cap = Int(value)
            workers = cap + 16
            for _ in 0..<workers {
                var fds: [Int32] = [-1, -1]
                guard pipe(&fds) == 0 else { break }
                let readEnd = fds[0]
                writeEnds.append(fds[1])
                DispatchQueue.global().async { [self] in
                    lock.lock(); parkedCount += 1; lock.unlock()
                    var byte: UInt8 = 0
                    _ = read(readEnd, &byte, 1)
                    close(readEnd)
                }
            }
        }

        func release() {
            lock.lock()
            let ends = writeEnds
            writeEnds.removeAll()
            lock.unlock()
            for fd in ends { close(fd) }
        }

        deinit { release() }
    }

    /// The failure this pins was measured with the reaper on a private
    /// concurrent queue: once the process had ~64 global-queue workers parked
    /// (the fast pass parks one per in-flight subprocess read), no reap ever
    /// started and no drain ever fired, and every drain-awaiting test here and
    /// in `TerminalTeardownReapTests` went red together with nothing to say
    /// but "did not fire within 30 s". A reaper on threads of its own is
    /// indifferent to that pool.
    ///
    /// Against the old reaper this fails through the drain's 30 s guard with
    /// the child "observed an unreaped zombie" — the reap never started — and
    /// takes every concurrently running drain-awaiting test in the suite down
    /// with it, which is the ledger's exact shape.
    @Test("a reap runs and drains while libdispatch's constrained worker pool is full")
    func reapsWhileTheConstrainedWorkerPoolIsExhausted() async throws {
        let exhaustion = ConstrainedPoolExhaustion()
        defer { exhaustion.release() }
        // Two seconds is ~100x the fill on an idle box and, in the pass, the
        // pool is already nearly full before this starts. Expiry is not a
        // failure — see the fixture — so no diagnostic is thrown here.
        _ = await pollUntilTrue(timeout: .seconds(2), pollInterval: .milliseconds(10)) {
            exhaustion.parked >= exhaustion.cap
        }

        let pid = try spawn("/bin/sleep", ["0"])
        ChildReaper.reap(pid: pid, unless: ChildExitObservation())

        let drain = await drainPendingReaps()
        if let diagnostic = drain.diagnostic(pid: pid, observedState: { describeState(pid) }) {
            await disposeChild(pid, observedZombie: isUnreapedZombie(pid))
            throw diagnostic
        }
        if processExists(pid) {
            let state = describeState(pid)
            await disposeChild(pid, observedZombie: isUnreapedZombie(pid))
            Issue.record(StillZombie(pid: pid, state: state))
        }
    }

    // MARK: - What is deliberately NOT tested here
    //
    // `reap`'s second `shouldReap` check — the one inside the background block
    // — has no dedicated test, and cannot get an honest one. Driving it means
    // recording the claim after `reap` returns but before that block runs, and
    // the block is already in flight on its own thread: any test that
    // appeared to pin it would be winning a race, not asserting a contract, and
    // would flake the first time the machine was busy. An earlier revision did
    // exactly that by holding the main queue, and it cost four 60 s timeouts
    // under full-suite load.
    //
    // The branch logic is covered instead where it is deterministic: the
    // `shouldReap` tests above pin both of its outcomes directly, and
    // `backgroundReapSkipsObservedChild` covers a claim that is already
    // recorded when `reap` is called. What remains uncovered is only the
    // *timing* of a claim landing mid-dispatch, which is the one part no test
    // can schedule.
}
