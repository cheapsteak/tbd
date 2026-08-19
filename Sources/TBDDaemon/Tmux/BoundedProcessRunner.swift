import Darwin
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

/// Bridges the calling `Task`'s cancellation into the deadline mechanism as a
/// THIRD, independent trigger alongside the watchdog-thread and clock armers
/// (see `Deadline` above). `runBoundedProcess` runs as part of its caller's
/// own task rather than a detached one, so a caller whose enclosing task is
/// cancelled (e.g. daemon shutdown cancelling an in-flight `describe`) needs
/// a way to interrupt an already-suspended continuation — `Task.isCancelled`
/// alone is not observed while parked in `withCheckedThrowingContinuation`.
///
/// `register(action:)` and `requestCancel()` may arrive in either order —
/// `withTaskCancellationHandler`'s `onCancel` can fire before `operation` has
/// even created the `Deadline` it wants to trigger. Whichever call arrives
/// second performs (or triggers) the action; both are idempotent past the
/// first outcome, matching `Deadline.disarm()`'s own guarantee.
private final class CancellationRelay: @unchecked Sendable {
    private struct State {
        var action: (@Sendable () -> Void)?
        var requested = false
        var consumed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func register(action: @escaping @Sendable () -> Void) {
        let fireNow = state.withLock { s -> Bool in
            guard !s.consumed else { return false }
            if s.requested {
                s.consumed = true
                return true
            }
            s.action = action
            return false
        }
        if fireNow { action() }
    }

    func requestCancel() {
        let pending = state.withLock { s -> (@Sendable () -> Void)? in
            guard !s.consumed else { return nil }
            s.consumed = true
            s.requested = true
            return s.action
        }
        pending?()
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

/// How the child's standard streams are wired.
///
/// `.pipes` is the default and what every pre-existing call site gets.
/// `.pseudoTerminal` substitutes one `openpty(3)` pair for both pipes and hands
/// the replica to the child as stdin, stdout and stderr — the same allocation
/// `TmuxControlConnection.start()` performs, including the detail that matters:
/// the parent closes its copy of the replica after spawn so the primary sees
/// EOF when the child exits.
///
/// **PTY mode is opt-in per invocation, not a property of a caller, and the
/// reason is a real loss.** A pseudo-terminal is one file descriptor, so the
/// child's stdout and stderr merge on it. Any verb that returns a control
/// record in a stderr envelope cannot survive that separation collapsing, so
/// only a caller that returns no envelope may set it.
enum BoundedProcessStdio: Sendable {
    case pipes
    case pseudoTerminal
}

/// The `winsize` reported to a `.pseudoTerminal` child via `TIOCGWINSZ`.
///
/// **This is a capture surface, not a display surface — do NOT "restore" it to
/// the 24x80 that `TmuxControlConnection` uses.** That site is not a precedent:
/// what crosses its pty is tmux's `-CC` control protocol, which is not
/// width-formatted at all, so the reported width cannot affect its bytes.
///
/// Here it can, and does. The pty itself never wraps — `winsize` is advisory
/// metadata and the kernel line discipline inserts nothing — but a child that
/// ASKS will format to it, and the CLIs this mode exists for do exactly that:
/// an ANSI-rendering layer formats to `process.stdout.columns` and inserts REAL
/// newlines at the wrap, which then land in the captured bytes and corrupt any
/// downstream parse. The measured headroom at 80 was six columns: a reference
/// output's longest line is 74 characters, and a `Created cloud session: `
/// prefix (23 characters) leaves 57 for a title that a parser reads with no
/// cross-check. Reporting a width no realistic output reaches removes the whole
/// class of failure; the cost of an over-wide report is nil, because nothing
/// pads to the full width.
private enum PseudoTerminalGeometry {
    static let columns: UInt16 = 400
    static let rows: UInt16 = 200
}

/// Refusals that belong to the runner itself rather than to the child.
enum BoundedProcessRunnerError: Error, Equatable, LocalizedError {
    /// A `stdin` payload was supplied under `.pseudoTerminal`. The replica is
    /// the child's stdin AND its stdout on one descriptor, so there is no write
    /// end to close and a child that waits for EOF would hang until the
    /// deadline. Refusing is louder than hanging.
    case stdinUnsupportedOnPseudoTerminal

    var errorDescription: String? {
        switch self {
        case .stdinUnsupportedOnPseudoTerminal:
            return "a stdin payload cannot be delivered under the pseudo-terminal stdio mode: "
                + "the pty replica is the child's stdin and stdout on one descriptor, so there "
                + "is no write end to close and a child waiting for EOF would hang"
        }
    }
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
/// `stdio` defaults to `.pipes`, which is exactly what every call site got
/// before the parameter existed. `.pseudoTerminal` swaps the two pipes for one
/// `openpty(3)` pair — for a child that refuses to run unless its stdout is a
/// terminal — and is deliberately opt-in per invocation: the two output streams
/// merge onto that single descriptor, so the reported `stderr` is always empty
/// and a `stdin` payload is REFUSED rather than silently hanging (there is no
/// separate write end to close). See `BoundedProcessStdio`.
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
/// `[shell, "-ilc", cmd]`, and startup files (profile and rc) can fork
/// background grandchildren that inherit the write ends, so EOF may never
/// arrive after the direct child dies.
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
    stdio: BoundedProcessStdio = .pipes,
    clock: any Clock<Duration> = ContinuousClock()
) async throws -> BoundedProcessOutcome {
    if stdio == .pseudoTerminal, stdin != nil {
        throw BoundedProcessRunnerError.stdinUnsupportedOnPseudoTerminal
    }
    // Single-resume guard shared by the watchdog fire path, the termination
    // handler, and the spawn-failure path. Whichever fires first wins; the
    // losers are no-ops.
    let state = ContinuationGuard()
    // Monotonic start instant for the authoritative deadline decision below.
    let start = ContinuousClock.now
    // Armer 3 — outer-task cancellation (see `CancellationRelay`'s doc
    // comment). Created here, outside the continuation closure, so
    // `onCancel` always has somewhere to register with even if the calling
    // task is already cancelled before `operation` runs.
    let cancellationRelay = CancellationRelay()

    return try await withTaskCancellationHandler(operation: {
    try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        let stdoutAccumulator = PipeDataAccumulator()
        let stderrAccumulator = PipeDataAccumulator()

        // Under `.pseudoTerminal` there is ONE descriptor: the parent reads the
        // primary and the child holds the replica as all three standard
        // streams, so `stderrHandle` stays nil and the reported stderr is
        // always empty.
        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle?
        var replicaToClose: Int32 = -1

        switch stdio {
        case .pipes:
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            stdoutHandle = stdoutPipe.fileHandleForReading
            stderrHandle = stderrPipe.fileHandleForReading
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
        case .pseudoTerminal:
            var primary: Int32 = -1
            var replica: Int32 = -1
            var term = termios()
            // Raw: no echo, no canonical editing, no CR translation, so the
            // bytes the parent reads are the bytes the child wrote.
            cfmakeraw(&term)
            // See `PseudoTerminalGeometry`: wide on purpose, because the child
            // formats its output to whatever width it is told.
            var size = winsize(
                ws_row: PseudoTerminalGeometry.rows,
                ws_col: PseudoTerminalGeometry.columns,
                ws_xpixel: 0,
                ws_ypixel: 0)
            guard openpty(&primary, &replica, nil, &term, &size) == 0 else {
                continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                return
            }
            // Non-blocking primary. `readAvailableRaw` runs on a GCD worker and
            // holds the accumulator lock across its `read(2)`, so a spurious
            // readability wakeup on a BLOCKING descriptor would park that worker
            // holding the lock — and `finish()`, which the watchdog thread calls
            // on the deadline path, would then block behind it. That thread is
            // the one this file promises never blocks. `EAGAIN` is already a
            // "keep draining" return, and `finish()` sets this flag itself, so
            // the pattern is unchanged, only earlier.
            let flags = fcntl(primary, F_GETFL)
            if flags >= 0 {
                _ = fcntl(primary, F_SETFL, flags | O_NONBLOCK)
            }
            let replicaHandle = FileHandle(fileDescriptor: replica, closeOnDealloc: false)
            stdoutHandle = FileHandle(fileDescriptor: primary, closeOnDealloc: false)
            stderrHandle = nil
            replicaToClose = replica
            process.standardInput = replicaHandle
            process.standardOutput = replicaHandle
            process.standardError = replicaHandle
        }

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        if let environment {
            process.environment = environment
        }
        // Only wire up a stdin pipe when the caller actually has bytes to
        // send — otherwise leave `standardInput` unset so the child inherits
        // the parent's stdin, exactly as it did before this parameter existed.
        // Refused outright under `.pseudoTerminal` (guarded above).
        let stdinPipe = stdin.map { _ in Pipe() }
        if let stdinPipe {
            process.standardInput = stdinPipe
        }

        // Drain incrementally as chunks arrive: no thread parks for the
        // subprocess's lifetime, and a child emitting more than the buffer
        // never deadlocks against an undrained reader.
        switch stdio {
        case .pipes:
            stdoutHandle.readabilityHandler = { handle in
                if !stdoutAccumulator.readAvailable(from: handle) { handle.readabilityHandler = nil }
            }
            stderrHandle?.readabilityHandler = { handle in
                if !stderrAccumulator.readAvailable(from: handle) { handle.readabilityHandler = nil }
            }
        case .pseudoTerminal:
            stdoutHandle.readabilityHandler = { handle in
                if !stdoutAccumulator.readAvailableRaw(from: handle) { handle.readabilityHandler = nil }
            }
        }

        // Detach the drain handlers and snapshot WITHOUT waiting for EOF — EOF
        // is NOT guaranteed (grandchildren may still hold the write ends, and a
        // pty primary reports EIO rather than EOF) — then close the parent read
        // ends. Idempotent and thread-safe; shared by every resume path.
        @Sendable func snapshot() -> (Data, Data) {
            stdoutHandle.readabilityHandler = nil
            stderrHandle?.readabilityHandler = nil
            let out = stdoutAccumulator.finish(handle: stdoutHandle)
            let err = stderrHandle.map { stderrAccumulator.finish(handle: $0) } ?? Data()
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

        // Armer 3 — outer-task cancellation. Registered before `run()`, same
        // as the other two armers and for the same "KILL ON ARRIVAL" reason:
        // `onCancel` can fire the instant this registers (or already have
        // fired before `deadline` even existed — `CancellationRelay` handles
        // that ordering), and `deadline.fire()`'s own `state.claim()` guard
        // plus the post-`run()` claimed-but-not-yet-running check below cover
        // a cancellation that lands before `processIdentifier` is valid.
        cancellationRelay.register {
            deadline.fire()
            deadline.disarm()
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
            // The child now holds the replica; close the parent's copy so the
            // primary sees EOF when the child exits. Same discipline as
            // `TmuxControlConnection.start()`.
            if replicaToClose >= 0 {
                Darwin.close(replicaToClose)
                replicaToClose = -1
            }
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
            if replicaToClose >= 0 {
                Darwin.close(replicaToClose)
                replicaToClose = -1
            }
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
    }, onCancel: {
        // Runs concurrently with `operation`, possibly on a different
        // thread, and possibly before `operation` has created `deadline` —
        // `CancellationRelay` is exactly the seam that makes that ordering
        // safe. Only fires the process's kill/resume path; it never itself
        // touches `process`, `continuation`, or any other state local to the
        // continuation closure.
        cancellationRelay.requestCancel()
    })
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
