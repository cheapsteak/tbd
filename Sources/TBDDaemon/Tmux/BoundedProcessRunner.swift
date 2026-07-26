import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "BoundedProcessRunner")

/// A single dedicated OS thread that fires subprocess deadlines.
///
/// It replaces the `DispatchSource.makeTimerSource(queue: .global())` timer the
/// bounded runner used to arm. That timer's event handler needed a free thread
/// from the shared default-QoS GCD pool — and a dispatch queue of ANY QoS draws
/// from that same pool, so a "dedicated queue" would not have helped. Under the
/// full test suite (~3000 tests, every target in ONE process, suites running in
/// parallel) the pool's ~64 worker threads all park on subprocesses/pipes/waits;
/// with none free, the 100ms timer handler never ran, a `sleep 3` child ran to
/// natural completion, and the call was reported as a clean success 30x past its
/// deadline. This thread is created explicitly and blocks only in
/// `NSCondition.wait`, so it is always available to run a deadline action on
/// time regardless of pool saturation.
///
/// The thread owns a deadline-ordered set of pending entries; `schedule` appends
/// one (waking the thread), `cancel` removes one. Actions run OFF the condition
/// lock, so an action may re-enter `schedule`/`cancel` — the SIGTERM→SIGKILL
/// escalation does exactly that.
///
/// Scheduling uses wall-clock `Date` (what `NSCondition` offers); a backward
/// clock adjustment could delay a fire. That is a non-issue here: the bounded
/// runner's completion path independently checks a *monotonic* `ContinuousClock`
/// deadline (see `runBoundedProcess`), so a late watchdog can never turn a
/// deadline breach into a false success.
final class SubprocessWatchdog: @unchecked Sendable {
    static let shared = SubprocessWatchdog()

    private struct Entry {
        let token: UInt64
        let fireDate: Date
        let action: () -> Void
    }

    private let condition = NSCondition()
    private var entries: [Entry] = []
    private var nextToken: UInt64 = 0
    private var started = false

    /// Schedules `action` to run on the watchdog thread after `delay`. Returns a
    /// token for `cancel(_:)`. A `delay` far in the future converts to a `Date`
    /// without overflow (the conversion is lossy-but-safe `Double` seconds), so
    /// an arbitrarily large timeout can never trap — this subsumes the old
    /// `min(timeoutNanos, Int.max)` clamp that guarded `DispatchTimeInterval`.
    @discardableResult
    func schedule(after delay: Duration, action: @escaping () -> Void) -> UInt64 {
        condition.lock()
        defer { condition.unlock() }
        startIfNeededLocked()
        let token = nextToken
        nextToken &+= 1
        entries.append(Entry(token: token, fireDate: Date(timeIntervalSinceNow: delay.seconds), action: action))
        condition.signal()
        return token
    }

    /// Removes a pending entry. A no-op if it already fired or never existed.
    func cancel(_ token: UInt64) {
        condition.lock()
        defer { condition.unlock() }
        entries.removeAll { $0.token == token }
    }

    private func startIfNeededLocked() {
        guard !started else { return }
        started = true
        let thread = Thread { [self] in runLoop() }
        thread.name = "com.tbd.daemon.subprocess-watchdog"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func runLoop() {
        condition.lock()
        while true {
            let now = Date()
            if let index = entries.firstIndex(where: { $0.fireDate <= now }) {
                let entry = entries.remove(at: index)
                condition.unlock()
                entry.action()
                condition.lock()
                continue
            }
            if let earliest = entries.map(\.fireDate).min() {
                _ = condition.wait(until: earliest)
            } else {
                condition.wait()
            }
        }
    }
}

/// A subprocess deadline: one action, armed twice.
///
/// The deadline fires on the `SubprocessWatchdog` thread (the production
/// guarantee — see that type; immune to GCD-pool starvation) *and* on the
/// injected `clock` (the test seam, so a `TestClock` can drive the deadline in
/// virtual time). Under `ContinuousClock` both target the same instant and the
/// action is idempotent behind `ContinuationGuard.claim()`, so which one wins is
/// unobservable. Whichever fires first retires the other, because the file's
/// standing invariant is that no thread, FD, or closure outlives the call.
///
/// `@unchecked Sendable` because `fire` captures `Process` and `Pipe`, neither
/// of which is `Sendable`, and `Task.init` demands a `@Sendable` closure. The
/// capture is no less safe than before this box existed: `SubprocessWatchdog`
/// already ran the identical closure on its own thread, and `claim()` still
/// admits exactly one caller past the action's first line.
private final class Deadline: @unchecked Sendable {
    private struct Armers {
        var token: UInt64?
        var task: Task<Void, any Error>?
        /// Sticky: an armer registered *after* `disarm()` is retired on arrival.
        /// The clock armer is registered after `process.run()` returns, and a
        /// fast child can terminate — and disarm — in that window, so
        /// "disarm then arm" is a reachable ordering, not a theoretical one.
        var disarmed = false
    }

    private let armers = OSAllocatedUnfairLock(initialState: Armers())

    /// Runs the deadline action. Callers invoke `disarm()` immediately after.
    let fire: () -> Void

    init(fire: @escaping () -> Void) { self.fire = fire }

    func arm(token: UInt64) {
        let late = armers.withLock { state -> Bool in
            if state.disarmed { return true }
            state.token = token
            return false
        }
        if late { SubprocessWatchdog.shared.cancel(token) }
    }

    func arm(task: Task<Void, any Error>) {
        let late = armers.withLock { state -> Bool in
            if state.disarmed { return true }
            state.task = task
            return false
        }
        if late { task.cancel() }
    }

    /// Retires both armers, and any armer that arrives later. Idempotent, safe
    /// from any thread, and safe to call from inside either armer's own fire
    /// path (cancelling the current task merely sets its cancellation flag).
    func disarm() {
        let pending = armers.withLock { state -> Armers in
            defer { state = Armers(token: nil, task: nil, disarmed: true) }
            return state
        }
        if let token = pending.token { SubprocessWatchdog.shared.cancel(token) }
        pending.task?.cancel()
    }
}

/// Outcome of a bounded subprocess run.
///
/// `.timedOut` means the call exceeded its deadline — either the watchdog fired
/// and killed the child, or the child's exit was only observed after the full
/// deadline had already elapsed. Callers map it to their own timeout error type.
enum BoundedProcessOutcome {
    case completed(status: Int32, stdout: Data, stderr: Data)
    case timedOut
}

/// Runs an external command with a hard timeout, draining stdout/stderr, and
/// resolves to `.completed(status, stdout, stderr)` or `.timedOut` — or throws
/// the spawn error if `Process.run()` fails. Shared by
/// `TmuxManager.runExternalCommand`, `GitManager.run`, and `ProviderRunner.run`,
/// which map the outcome to their own error types (`TmuxError` / `GitError` /
/// `GitTimeoutError` / `ProviderRunError`).
///
/// `environment` and `stdin` are optional and default to `nil`, which
/// preserves the exact behavior existing callers (`GitManager`, `TmuxManager`,
/// `GCDiskUsage`, `OrphanGC`) already depend on: an unset `environment` leaves
/// `Process.environment` untouched (inherits the parent's), and no `stdin`
/// leaves `Process.standardInput` untouched (inherits the parent's), rather
/// than wiring up a pipe. When `environment` IS provided, it REPLACES the
/// parent's environment wholesale (`Process.environment = environment`) —
/// it is not merged, so a caller passing a partial dict gets a child missing
/// everything it didn't list (e.g. no `PATH`).
///
/// `stdin`, when provided, is written synchronously right after `run()`
/// succeeds, blocking the calling executor thread until the write completes.
/// That's fine for this codebase's payloads — provider contract params and
/// keystrokes are at most a few KB, well under the ~64KB pipe buffer — but a
/// hypothetically large `stdin` (bigger than the pipe buffer, with a child
/// that doesn't drain concurrently) would block the CALLING thread until the
/// child reads enough to make room, the same way an undrained large stdout
/// would block the child.
///
/// The deadline is immune to GCD-pool starvation via two independent guarantees:
///
/// 1. SCHEDULING — the deadline AND the SIGTERM→SIGKILL escalation fire on the
///    dedicated `SubprocessWatchdog` thread, never on a GCD queue. The whole
///    fire path (claim guard → detach readability handlers → finish accumulators
///    → SIGTERM → resume) runs on that thread with no GCD hop before the
///    continuation resumes.
/// 2. AUTHORITY — the completion path records a monotonic start instant and, if
///    the child's exit is observed only AFTER the full deadline elapsed, reports
///    `.timedOut` regardless of exit status. The timeout bounds the CALL, not
///    merely the child: a completion delayed past the deadline is a lie if
///    reported as a clean success, so it is reported as a timeout. Production
///    timeouts are >=5s, so this only ever triggers under the extreme starvation
///    that made the report a lie in the first place.
///
/// Both pipes are drained incrementally via `readabilityHandler` while the child
/// runs — a macOS pipe buffer is 64KB, so a child emitting more (e.g. `ps -Ao`
/// on a busy machine, ~72KB) would otherwise block writing to the full pipe
/// while we wait for it to exit — a mutual deadlock resolved only by the
/// timeout. The drain never waits for pipe EOF: real call sites run
/// `[shell, "-ic", cmd]`, and rc files can fork background grandchildren that
/// inherit the write ends, so EOF may never arrive after the direct child dies.
/// Termination, timeout, and spawn-failure all snapshot what has already arrived
/// and close the parent read ends — no thread, FD, or closure outlives the call.
///
/// The continuation is guarded by a `ContinuationGuard` so exactly one of
/// {termination, timeout, spawn-failure} resumes it, satisfying the single-resume
/// contract even when the process exits concurrently with the watchdog.
///
/// `clock` is the standard behavior seam (`Tests/CLAUDE.md`, "Clock and date
/// seams"): it arms the deadline a *second* time so tests can drive it in
/// virtual time, and it deliberately does **not** replace the watchdog. Moving
/// the deadline onto the cooperative executor would reinstate the starvation bug
/// the watchdog exists to fix — `SubprocessTimeoutStarvationTests` is that
/// property's regression guard and passes a real clock on purpose.
///
/// Note the AUTHORITY check below stays on the concrete `ContinuousClock`. A
/// time reference whose job is to detect that the time *mechanism* failed must
/// not be virtualized, or both halves lie in the same direction. It is also the
/// one piece of `Instant` arithmetic here, which `any Clock<Duration>` cannot
/// express — a constraint that costs nothing because this line must not move.
func runBoundedProcess(
    executable: String,
    arguments: [String],
    currentDirectory: String?,
    environment: [String: String]? = nil,
    stdin: Data? = nil,
    timeout: Duration,
    clock: any Clock<Duration> = ContinuousClock()
) async throws -> BoundedProcessOutcome {
    // Single-resume guard shared by the watchdog fire path, the termination
    // handler, and the spawn-failure path. Whichever fires first wins; the
    // losers are no-ops.
    let state = ContinuationGuard()
    // Monotonic start instant for the authoritative deadline decision below.
    let start = ContinuousClock.now

    return try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutAccumulator = PipeDataAccumulator()
        let stderrAccumulator = PipeDataAccumulator()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        if let environment {
            process.environment = environment
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Only wire up a stdin pipe when the caller actually has bytes to
        // send — otherwise leave `standardInput` unset so the child inherits
        // the parent's stdin, exactly as it did before this parameter existed.
        let stdinPipe = stdin.map { _ in Pipe() }
        if let stdinPipe {
            process.standardInput = stdinPipe
        }

        // Drain both pipes incrementally as chunks arrive: no thread parks for
        // the subprocess's lifetime, and a child emitting more than the 64KB
        // pipe buffer never deadlocks against an undrained pipe.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            if !stdoutAccumulator.readAvailable(from: handle) { handle.readabilityHandler = nil }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if !stderrAccumulator.readAvailable(from: handle) { handle.readabilityHandler = nil }
        }

        // Detach the drain handlers and snapshot both pipes WITHOUT waiting for
        // EOF — EOF is NOT guaranteed (grandchildren may still hold the write
        // ends) — then close the parent read ends. Idempotent and thread-safe;
        // shared by every resume path.
        @Sendable func snapshot() -> (Data, Data) {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let out = stdoutAccumulator.finish(handle: stdoutPipe.fileHandleForReading)
            let err = stderrAccumulator.finish(handle: stderrPipe.fileHandleForReading)
            return (out, err)
        }

        // Deadline action. On fire: stop draining, kill the DIRECT child
        // (grandchildren keep their inherited write ends — see above), escalate
        // to SIGKILL on the SAME watchdog thread after a brief grace (a GCD
        // asyncAfter would starve alongside the timer it replaces; the grace is
        // deliberately NOT virtualized, so the kill path under test stays the
        // real kill path), and resume `.timedOut`.
        //
        // `claim()` is the FIRST statement, before any side effect. That is what
        // makes a superseded armer harmless: a deadline task that was cancelled
        // after its sleep had already resumed still reaches here, fails the
        // claim, and returns without snapshotting, signalling, or resuming. If
        // anyone ever moves a side effect above the claim, that stops being true.
        let deadline = Deadline {
            guard state.claim() else { return }
            _ = snapshot()
            let pid = process.processIdentifier
            if pid > 0 {
                kill(pid, SIGTERM)
                SubprocessWatchdog.shared.schedule(after: .milliseconds(500)) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
            continuation.resume(returning: .timedOut)
        }

        // Armer 1 — the watchdog thread. Scheduled before `run()`: as with the
        // old absolute-time DispatchSource, the deadline is measured from here.
        deadline.arm(token: SubprocessWatchdog.shared.schedule(after: timeout) {
            deadline.fire()
            deadline.disarm()
        })

        // Armer 2 — the injected clock. Under `ContinuousClock` this races armer
        // 1 to the same instant and the loser is a no-op; under a `TestClock` it
        // is the only armer that can fire, which is what makes the timeout tests
        // deterministic.
        //
        // Armed HERE, before `Process.run()`, and the ordering is load-bearing in
        // both directions:
        //
        //  - It must not be LATER. A `TestClock` sleeper has to be registered
        //    before the test's bounded `advanceWhenSuspended` wait gives up.
        //    Arming after `run()` puts a real fork/exec in front of that
        //    registration, and on a loaded box the spawn outruns the wait — the
        //    test then advances a clock with nobody sleeping on it, the sleep
        //    registers against the new `now`, and the deadline never fires.
        //    (Measured: 1 failure in 10 whole-target runs at loadavg ~150.)
        //  - It must not be UNGUARDED. A virtual deadline can fire microseconds
        //    from here, while `processIdentifier` is still 0 and the kill below
        //    is skipped — which would resolve `.timedOut` and orphan the child
        //    `run()` is about to create. The post-spawn check handles that case.
        //
        // A plain `try await` rather than `try?`: cancellation before the sleep
        // resumes must end the task, not fall through to the action.
        deadline.arm(task: Task {
            try await clock.sleep(for: timeout)
            deadline.fire()
            deadline.disarm()
        })

        process.terminationHandler = { _ in
            // The direct child exited; everything it wrote is already in the
            // kernel pipe buffers. `snapshot` captures that without waiting for
            // EOF and closes the parent read ends.
            let (outData, errData) = snapshot()
            guard state.claim() else { return }  // deadline already won → timed out
            deadline.disarm()
            // AUTHORITY: a child that outran its deadline — even with status 0 —
            // must never be reported as a clean success, even if every armer was
            // somehow late to fire. Deliberately on the concrete `ContinuousClock`
            // and NOT the injected one: this is the observer that detects the
            // deadline mechanism failing, so virtualizing it would let both halves
            // lie in the same direction.
            if ContinuousClock.now - start >= timeout {
                continuation.resume(returning: .timedOut)
            } else {
                continuation.resume(returning: .completed(
                    status: process.terminationStatus,
                    stdout: outData,
                    stderr: errData
                ))
            }
        }

        do {
            try process.run()
            // KILL ON ARRIVAL. The deadline may have fired *during* the spawn,
            // when `processIdentifier` was still 0 and its own kill was skipped.
            // Whoever claimed the continuation, a child that is still running at
            // this point has nobody left to reap it, so signal it here rather
            // than orphan it. A normal completion leaves `isRunning` false, so
            // this is inert on the happy path.
            if state.isClaimed, process.isRunning {
                let pid = process.processIdentifier
                if pid > 0 {
                    kill(pid, SIGTERM)
                    SubprocessWatchdog.shared.schedule(after: .milliseconds(500)) {
                        if process.isRunning { kill(pid, SIGKILL) }
                    }
                }
            }
        } catch {
            // Spawn failed: no child will ever write — detach the drain handlers
            // and close the read ends so nothing lingers. `run()` fails
            // synchronously and immediately, long before the (>=100ms) watchdog
            // could fire, so this path reliably wins the claim.
            _ = snapshot()
            guard state.claim() else { return }
            deadline.disarm()
            continuation.resume(throwing: error)
            return
        }

        if let stdin, let stdinPipe {
            // MUST be the throwing `write(contentsOf:)` overload, never the
            // older non-throwing `write(_:)` — that one raises an
            // Objective-C `NSFileHandleOperationException` on a write
            // error, which Swift cannot catch, aborting the entire daemon
            // process rather than failing this one call. This is reachable
            // any time a child exits (or simply never reads stdin) before
            // we finish writing — e.g. a bad verb, a missing interpreter, a
            // `set -e` trip in a provider script — which turns into EPIPE
            // because `main.swift` sets `signal(SIGPIPE, SIG_IGN)` (so a
            // broken pipe becomes a write error instead of killing the
            // process outright, which would be worse). A child that exited
            // before reading its stdin is a normal condition, not an error
            // worth propagating: the exit code and stderr already tell the
            // real story, so a failed write here is swallowed (after being
            // logged) rather than thrown.
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
            } catch {
                logger.debug("stdin write failed, child likely exited before reading: \(error, privacy: .public)")
            }
            stdinPipe.fileHandleForWriting.closeFile()
        }
    }
}

extension Duration {
    /// This `Duration` as seconds. Lossy for sub-attosecond precision (there is
    /// none) and for `seconds` beyond `Double`'s 2^53 exact range, but never
    /// traps — used for far-future watchdog deadlines.
    fileprivate var seconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1_000_000_000_000_000_000
    }
}
