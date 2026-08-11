import Darwin
import Foundation
import Testing
@testable import TBDApp

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
/// WHY AN EXPLICIT `.timeLimit(.minutes(1))` AND NOT `.clockDriven`. Following
/// the precedent of `SubprocessTimeoutTests`, which states its reason rather
/// than inheriting the shared trait: `.clockDriven`'s four minutes is sized for
/// suites that arm a `TestClock` handshake in the ~4500-test parallel pass, and
/// nothing here is clock-driven — the longest child lives 0.3 s and the polls
/// below are capped at 5 s of their own. A limit an order of magnitude above
/// the work is a hang-catcher; four minutes of a shared box is not free.
///
/// The limit's known blind spot, stated rather than glossed: Swift Testing
/// cannot cancel a thread parked in a synchronous `waitpid`, so it would not
/// rescue a test that waits on a child that never exits. None can — every child
/// spawned here is `/bin/sleep` with a bounded argument, which always exits, and
/// the skip-branch test reaps its own deliberately-unreaped child before
/// returning.
@Suite("ChildReaper", .timeLimit(.minutes(1)))
struct ChildReaperTests {

    // MARK: - Helpers

    private enum SpawnError: Error, CustomStringConvertible {
        case posixSpawnFailed(Int32)
        var description: String {
            switch self {
            case .posixSpawnFailed(let code): return "posix_spawn failed with code \(code)"
            }
        }
    }

    private struct StillZombie: Error, CustomStringConvertible {
        let pid: pid_t
        let polls: Int
        var description: String {
            "pid \(pid) was still a live-or-zombie process after \(polls) polls "
                + "(expected ESRCH once ChildReaper reaped it)"
        }
    }

    private struct NeverExited: Error, CustomStringConvertible {
        let pid: pid_t
        let polls: Int
        var description: String {
            "pid \(pid) had not become a reapable zombie after \(polls) polls"
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

    /// Runs the blocking reap off the cooperative pool. Parking a concurrency
    /// worker for the child's lifetime would tax every other suite in this
    /// process (Swift Testing runs them all in one).
    private func reapOffPool(_ pid: pid_t) async -> pid_t {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ChildReaper.reapBlocking(pid: pid))
            }
        }
    }

    private func waitUntilZombie(_ pid: pid_t) async throws {
        var polls = 0
        while !isUnreapedZombie(pid), polls < 200 {
            polls += 1
            try await Task.sleep(for: .milliseconds(25))
        }
        guard isUnreapedZombie(pid) else { throw NeverExited(pid: pid, polls: polls) }
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

        var polls = 0
        while processExists(pid), polls < 200 {
            polls += 1
            try await Task.sleep(for: .milliseconds(25))
        }
        if processExists(pid) {
            Issue.record(StillZombie(pid: pid, polls: polls))
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
        try await waitUntilZombie(pid)
        try await Task.sleep(for: .milliseconds(200))
        #expect(isUnreapedZombie(pid),
                "an observed child must be left for its real waiter, not reaped here")

        // This test owns the zombie it deliberately kept; don't leak it.
        _ = await reapOffPool(pid)
    }
}
