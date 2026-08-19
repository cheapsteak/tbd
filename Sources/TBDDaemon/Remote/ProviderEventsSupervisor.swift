import Foundation
import os
import TBDShared

private let remoteLogger = Logger(subsystem: "com.tbd.daemon", category: "remote")

/// Single-fire async gate resolved by `Process.terminationHandler`.
///
/// Used in place of `Process.waitUntilExit()`, which blocks the calling
/// thread synchronously until the child exits. Calling that from an actor
/// method blocks the actor's executor for the child's full lifetime — the
/// exact starvation class `BoundedProcessRunner`'s dedicated watchdog thread
/// (see `Sources/TBDDaemon/Tmux/BoundedProcessRunner.swift`) exists to avoid
/// elsewhere in this codebase. `terminationHandler` fires asynchronously off
/// a Foundation-managed queue regardless of whether `waitUntilExit` is ever
/// called, so awaiting this gate observes the same event without blocking.
private final class ProcessExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var exited = false

    func markExited() {
        lock.lock()
        let pending = continuation
        continuation = nil
        exited = true
        lock.unlock()
        pending?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if exited {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

/// Turns a pipe into an ordered stream of complete lines using
/// `readabilityHandler` — the `PipeDataAccumulator` shape from
/// `BoundedProcessRunner`, not `FileHandle.bytes.lines`.
///
/// Why not the simpler async-bytes sequence: teardown of this stream has to be
/// safe at an arbitrary moment (the silence watchdog or `stop()` can fire mid
/// stream), and on Darwin `close()`ing an fd out from under a thread already
/// parked in `read(2)` does NOT wake that thread — it leaks the reader and,
/// worse, frees the fd *number* for reuse by another consumer in this same
/// process (GRDB, NIO) which the parked reader then reads from when it finally
/// wakes. `TmuxControlConnection.stop()` documents that hazard and dances
/// around it with a semaphore; this type sidesteps it entirely, because a
/// `readabilityHandler` only ever reads when bytes (or EOF) are already
/// waiting, so no thread is ever parked at close time.
///
/// Lines are yielded into an `AsyncStream` rather than dispatched as
/// individual `Task`s so ordering is preserved: `session`/`removed` events
/// must be applied in the order the provider emitted them.
private final class PipeLineReader: @unchecked Sendable {
    /// No valid `events` line is anywhere near this long — a newline-free
    /// torrent (or a consumer that can't drain as fast as the provider
    /// emits) would otherwise grow `pending` without bound for the daemon's
    /// whole lifetime, and since any bytes at all count as activity, the
    /// silence watchdog would never notice and kill it.
    private static let maxPendingBytes = 1 << 20  // 1 MB

    private let lock = NSLock()
    private let continuation: AsyncStream<String>.Continuation
    private var pending = Data()
    private var finished = false
    private var loggedOverflow = false

    init(continuation: AsyncStream<String>.Continuation) {
        self.continuation = continuation
    }

    /// `readabilityHandler` body. Returns `false` at EOF or after `finish`, so
    /// the caller detaches itself.
    func readAvailable(from handle: FileHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return false }
        emitLinesLocked(from: chunk)
        return true
    }

    /// Drains whatever is already buffered WITHOUT blocking (so events sitting
    /// in the kernel pipe buffer at exit are still applied rather than
    /// dropped), emits any trailing unterminated line, closes the parent's
    /// read end, and finishes the stream. Idempotent. The caller must detach
    /// the readability handler first; acquiring the lock then blocks until any
    /// in-flight handler call has finished touching the handle.
    func finish(handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                emitLinesLocked(from: Data(chunk.prefix(count)))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                // 0 = EOF; -1/EAGAIN = every buffered byte is drained. Either
                // way there is nothing we are obliged to wait for.
                break
            }
        }
        if !pending.isEmpty, let line = String(data: pending, encoding: .utf8) {
            continuation.yield(line)
        }
        pending.removeAll()
        try? handle.close()
        continuation.finish()
    }

    private func emitLinesLocked(from chunk: Data) {
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            pending = pending[pending.index(after: newline)...]
            if let line = String(data: lineData, encoding: .utf8) {
                continuation.yield(line)
            }
        }
        // Compact so the slice's dropped prefix is actually released.
        pending = Data(pending)
        if pending.count > Self.maxPendingBytes {
            if !loggedOverflow {
                loggedOverflow = true
                remoteLogger.error(
                    "events pipe buffered \(self.pending.count, privacy: .public) bytes with no newline (cap \(Self.maxPendingBytes, privacy: .public)); discarding")
            }
            pending.removeAll()
        }
    }
}

/// Supervises one provider's long-running `events` process: spawn, stream
/// NDJSON lines to the manager, watchdog silence, and restart with backoff.
/// Reconnect-and-resnapshot is the entire resync mechanism (no cursors) —
/// every restart just relies on the provider re-emitting `hello`+`snapshot`.
actor ProviderEventsSupervisor {
    private let config: RemoteProviderConfig
    /// Held STRONGLY on purpose. Ownership runs the other way: the manager
    /// owns its supervisors (`RemoteProviderManager.supervisors`) and breaks
    /// the reference cycle in `stopAll()`, which awaits `stop()` and drops the
    /// dictionary entry. A `weak` manager instead produces the worst failure
    /// available — a supervisor that keeps spawning provider children forever
    /// while every event it parses applies to nobody, silently.
    private let manager: RemoteProviderManager
    /// The contract major `RemoteProviderManager` negotiated for this provider,
    /// captured at construction. The supervisor's whole lifetime belongs to one
    /// `describe`, so re-reading it per spawn would buy nothing.
    private let contractVersion: Int
    private var supervision: Task<Void, Never>?
    private var currentProcess: Process?
    /// Incremented per `runOnce`, so a previous run's teardown can never nil
    /// out or kill the *current* run's process after a `stop()`/`start()`
    /// cycle on the same instance.
    private var generation = 0
    private var lastActivity = Date()
    /// When the current `events` connection was opened. This is the request
    /// start for every `snapshot` event that arrives on it: the provider
    /// composes its reconnect snapshot from what it knew when TBD asked, so a
    /// snapshot on a connection opened before a local filing decision cannot
    /// have accounted for that decision. See
    /// `RemoteProviderManager.syncFilingDecisions`.
    ///
    /// Internal rather than private so a test can read what the date seam
    /// stamped; nothing in production reads it from outside this actor.
    private(set) var connectionOpenedAt: Date

    /// Injectable timing so the live test runs in seconds, not minutes.
    let silenceLimit: TimeInterval
    let backoffCap: TimeInterval
    let healthyResetUptime: TimeInterval
    private let clock: any Clock<Duration>
    /// The date seam. Separate from `clock` on purpose: `connectionOpenedAt`
    /// is persisted-shaped data that gets **compared** against a filing
    /// decision, not a delay — `Duration` is behavior, `Date` is data
    /// (root `CLAUDE.md`, "New delays and timers take an injected clock").
    /// The watchdog's own elapsed-time arithmetic deliberately stays on the
    /// wall clock: it measures how long a child has been silent, which a
    /// frozen date would disable outright.
    private let now: @Sendable () -> Date

    /// Grace between SIGTERM and SIGKILL, and between observing the child's
    /// exit and finishing the line stream (so late bytes still get applied).
    private static let killGrace: Duration = .milliseconds(500)
    private static let drainGrace: Duration = .milliseconds(50)

    /// The environment the `events` child runs under. Pure and static for the
    /// same reason `ProviderRunner.invocationEnvironment` is: the two daemon
    /// emitters agreeing is a property worth asserting without a spawn.
    static func streamEnvironment(
        base: [String: String], contractVersion: Int
    ) -> [String: String] {
        var env = base
        env["TBD_CONTRACT_VERSION"] = String(contractVersion)
        return env
    }

    init(config: RemoteProviderConfig, manager: RemoteProviderManager,
         contractVersion: Int,
         silenceLimit: TimeInterval = 90, backoffCap: TimeInterval = 60,
         healthyResetUptime: TimeInterval = 300,
         clock: any Clock<Duration> = ContinuousClock(),
         now: @Sendable @escaping () -> Date = { Date() }) {
        self.config = config
        self.manager = manager
        self.contractVersion = contractVersion
        self.silenceLimit = silenceLimit
        self.backoffCap = backoffCap
        self.healthyResetUptime = healthyResetUptime
        self.clock = clock
        self.now = now
        self.connectionOpenedAt = now()
    }

    func start() {
        guard supervision == nil else { return }
        supervision = Task { await superviseForever() }
    }

    /// Deterministic teardown: when this returns, the child (and its whole
    /// process group) is dead and the supervision task has finished, so no
    /// respawn can follow. Kill and join in that order — the supervision task
    /// is parked on the line stream, which only ends once the child is gone.
    func stop() async {
        guard let task = supervision else { return }
        supervision = nil
        task.cancel()
        if let process = currentProcess {
            await killTree(process)
        }
        // No unconditional `currentProcess = nil` here: `runOnce`'s own
        // post-run teardown already clears it under the generation guard
        // once the awaited task above actually finishes (cancellation makes
        // `superviseForever` return right after that teardown, with no
        // backoff sleep in between — see its `Task.isCancelled` check). A
        // concurrent `start()` landing in the window between `task.cancel()`
        // and `await task.value` would otherwise have its NEW generation's
        // `currentProcess` wiped by this OLD call, leaving the silence
        // watchdog with no process to kill.
        await task.value
    }

    private func superviseForever() async {
        var attempt = 0
        while !Task.isCancelled {
            let started = Date()
            await runOnce()
            if Task.isCancelled { return }
            if Date().timeIntervalSince(started) > healthyResetUptime { attempt = 0 }
            attempt += 1
            let base = min(backoffCap, pow(2.0, Double(attempt - 1)))
            let jitter = base * Double.random(in: -0.2...0.2)
            let delay = max(0.1, base + jitter)
            remoteLogger.debug(
                "events \(self.config.name, privacy: .public) exited; restart in \(delay, privacy: .public)s")
            try? await clock.sleep(for: .seconds(delay))
        }
    }

    /// One process lifetime: spawn `events`, apply every line the provider
    /// emits, and return once the stream is over. Bounded by construction: the
    /// stream ends at EOF, at child exit, or when the silence watchdog kills
    /// the child — and every kill escalates SIGTERM→SIGKILL against the whole
    /// process group, so there is no path where this parks forever. Any
    /// failure just returns; the outer loop restarts and the reconnect
    /// snapshot resyncs everything (contract: no cursors).
    private func runOnce() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.exec)
        process.arguments = (config.args ?? []) + ["events"]
        let env = Self.streamEnvironment(
            base: ProcessInfo.processInfo.environment, contractVersion: contractVersion)
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        let reader = PipeLineReader(continuation: continuation)
        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            if !reader.readAvailable(from: handle) {
                handle.readabilityHandler = nil
                reader.finish(handle: handle)
            }
        }
        @Sendable func endStream() {
            readHandle.readabilityHandler = nil
            reader.finish(handle: readHandle)
        }

        let exitGate = ProcessExitGate()
        process.terminationHandler = { _ in exitGate.markExited() }

        do {
            connectionOpenedAt = now()
            try process.run()
        } catch {
            remoteLogger.error(
                "events spawn failed for \(self.config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            endStream()
            return
        }
        generation += 1
        let myGeneration = generation
        currentProcess = process
        lastActivity = Date()

        // Teardown is driven by process EXIT, not by pipe EOF. A provider that
        // leaves a grandchild holding the pipe's write end (the stub in the
        // live test does exactly that, and `BoundedProcessRunner` documents
        // the same caveat: any spawned process can fork grandchildren that
        // inherit the write ends) never delivers EOF, so waiting for it would
        // wedge this supervisor permanently. The short grace lets bytes
        // already in the kernel buffer land first.
        let exitWatcher = Task { [clock] in
            await exitGate.wait()
            try? await clock.sleep(for: Self.drainGrace)
            endStream()
        }
        let watchdog = startWatchdog(generation: myGeneration)

        for await line in lines {
            lastActivity = Date()
            guard let event = RemoteEventParser.parse(line: line) else { continue }
            await handle(event)
        }

        watchdog.cancel()
        exitWatcher.cancel()
        // The stream is over, so this run is over: make sure the child tree is
        // actually gone before the outer loop can spawn a replacement (a
        // provider that closes stdout but keeps running would otherwise
        // accumulate one live process per restart).
        if process.isRunning {
            await killTree(process)
        }
        endStream()
        if generation == myGeneration { currentProcess = nil }
    }

    /// SIGTERM the child's whole process GROUP, then SIGKILL it after a grace
    /// period if anything survived — the same escalation `BoundedProcessRunner`
    /// and `TmuxControlConnection` already use, applied to the group rather
    /// than the single pid for two reasons: a `bash` parked in a foreground
    /// `sleep` defers SIGTERM until that command finishes (so pid-only SIGTERM
    /// never kills it), and grandchildren that inherited the pipe's write end
    /// have to die for the stream to end.
    ///
    /// Foundation's `Process` makes the child its own process-group leader on
    /// Darwin (verified: child pgid == child pid), but that is checked with
    /// `getpgid` before signaling a negative pid so we can never signal an
    /// unrelated group if that ever changes.
    private func killTree(_ process: Process) async {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        signalTree(pid, SIGTERM)
        // A cancelled caller (e.g. the supervision task during `stop()`) skips
        // the grace and escalates immediately, which is the right degradation.
        try? await clock.sleep(for: Self.killGrace)
        if process.isRunning {
            remoteLogger.debug(
                "events \(self.config.name, privacy: .public) ignored SIGTERM; escalating to SIGKILL")
            signalTree(pid, SIGKILL)
        }
    }

    private func signalTree(_ pid: pid_t, _ signal: Int32) {
        if getpgid(pid) == pid {
            kill(-pid, signal)
        } else {
            kill(pid, signal)
        }
    }

    /// Polls activity roughly three times per silence window and kills the
    /// process tree once the window is exceeded. 90s of stream silence with no
    /// `ping` means the stream is dead and must be replaced.
    private func startWatchdog(generation: Int) -> Task<Void, Never> {
        Task { [weak self, silenceLimit, clock] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(silenceLimit / 3))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.killIfSilent(generation: generation)
            }
        }
    }

    private func killIfSilent(generation: Int) async {
        guard generation == self.generation, let process = currentProcess,
              Date().timeIntervalSince(lastActivity) > silenceLimit else { return }
        remoteLogger.debug(
            "events \(self.config.name, privacy: .public) silent past \(self.silenceLimit, privacy: .public)s; killing")
        await killTree(process)
    }

    private func handle(_ event: RemoteEvent) async {
        switch event {
        case .hello, .ping:
            break   // activity timestamp already updated by the caller
        case .snapshot(let sessions, let complete):
            try? await manager.apply(
                snapshot: sessions, provider: config.name, complete: complete,
                requestStartedAt: connectionOpenedAt)
        case .session(let session):
            await manager.applyUpsert(session, provider: config.name)
        case .removed(let id):
            await manager.applyRemoval(sessionID: id, provider: config.name)
        }
    }
}
