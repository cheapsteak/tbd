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

/// Supervises one provider's long-running `events` process: spawn, stream
/// NDJSON lines to the manager, watchdog silence, and restart with backoff.
/// Reconnect-and-resnapshot is the entire resync mechanism (no cursors) —
/// every restart just relies on the provider re-emitting `hello`+`snapshot`.
actor ProviderEventsSupervisor {
    private let config: RemoteProviderConfig
    private weak var manager: RemoteProviderManager?
    private var supervision: Task<Void, Never>?
    private var currentProcess: Process?
    private var lastActivity = Date()

    /// Injectable timing so the live test runs in seconds, not minutes.
    let silenceLimit: TimeInterval
    let backoffCap: TimeInterval
    let healthyResetUptime: TimeInterval

    init(config: RemoteProviderConfig, manager: RemoteProviderManager,
         silenceLimit: TimeInterval = 90, backoffCap: TimeInterval = 60,
         healthyResetUptime: TimeInterval = 300) {
        self.config = config
        self.manager = manager
        self.silenceLimit = silenceLimit
        self.backoffCap = backoffCap
        self.healthyResetUptime = healthyResetUptime
    }

    func start() {
        guard supervision == nil else { return }
        supervision = Task { await superviseForever() }
    }

    func stop() {
        supervision?.cancel()
        supervision = nil
        currentProcess?.terminate()
        currentProcess = nil
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
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// One process lifetime: spawn `events`, stream lines concurrently while
    /// racing actual process-exit detection, then tear down without
    /// blocking this actor's executor. Any stream failure just returns —
    /// the outer loop restarts, and the reconnect snapshot resyncs
    /// everything (contract: no cursors).
    private func runOnce() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.exec)
        process.arguments = (config.args ?? []) + ["events"]
        var env = ProcessInfo.processInfo.environment
        env["TBD_CONTRACT_VERSION"] = "1"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let exitGate = ProcessExitGate()
        process.terminationHandler = { _ in exitGate.markExited() }

        do {
            try process.run()
        } catch {
            remoteLogger.error(
                "events spawn failed for \(self.config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        currentProcess = process
        lastActivity = Date()

        let watchdog = startWatchdog()
        defer {
            watchdog.cancel()
            currentProcess = nil
        }

        // Stream lines on a child task, concurrently with waiting for exit
        // below, rather than looping to EOF first: a process whose child
        // forks a background grandchild that inherits the pipe's write end
        // (a documented Foundation Process/Pipe footgun — see the EOF
        // caveat in BoundedProcessRunner.swift) may never close that fd
        // even after the process we spawned and can kill is long dead, so
        // a bare `for try await line in pipe.fileHandleForReading.bytes.lines`
        // can hang forever waiting for an EOF nobody will ever send.
        // (Verified empirically: a stub `events` script that backgrounds a
        // `sleep` as its last line reproduces exactly this hang.)
        let readTask = Task { [weak self, config = config] in
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    guard let self else { return }
                    if Task.isCancelled { return }
                    await self.noteActivity()
                    guard let event = RemoteEventParser.parse(line: line) else { continue }
                    await self.handle(event)
                }
            } catch {
                remoteLogger.debug(
                    "events stream error \(config.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // Wait for the DIRECT child to actually exit — non-blocking, via
        // `terminationHandler` (see `ProcessExitGate`) rather than
        // `Process.waitUntilExit()`, which would block this actor's
        // executor for the child's full lifetime, exactly the starvation
        // class `BoundedProcessRunner`'s dedicated watchdog thread exists
        // to avoid elsewhere in this codebase. Once the child is gone,
        // force-close the pipe's read end so a `readTask` stuck on the
        // grandchild-holds-the-fd scenario above unblocks instead of
        // leaking forever. Losing whatever was still in flight at that
        // instant is fine — reconnect-and-resnapshot is the documented
        // recovery for exactly this kind of gap (no cursors).
        await exitGate.wait()
        try? pipe.fileHandleForReading.close()
        readTask.cancel()
        await readTask.value
    }

    private func noteActivity() {
        lastActivity = Date()
    }

    /// Polls activity roughly three times per silence window and kills the
    /// process (from actor-isolated context, so touching `currentProcess`
    /// stays safe) once the window is exceeded. 90s of stream silence with
    /// no `ping` means the caller must treat the stream as dead.
    private func startWatchdog() -> Task<Void, Never> {
        Task { [weak self, silenceLimit] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(silenceLimit / 3))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.killIfSilent()
            }
        }
    }

    private func killIfSilent() {
        guard Date().timeIntervalSince(lastActivity) > silenceLimit else { return }
        remoteLogger.debug("events \(self.config.name, privacy: .public) silent past \(self.silenceLimit, privacy: .public)s; killing")
        currentProcess?.terminate()
    }

    private func handle(_ event: RemoteEvent) async {
        switch event {
        case .hello, .ping:
            break   // activity timestamp already updated by the caller
        case .snapshot(let sessions):
            try? await manager?.apply(snapshot: sessions, provider: config.name)
        case .session(let session):
            await manager?.applyUpsert(session, provider: config.name)
        case .removed(let id):
            await manager?.applyRemoval(sessionID: id, provider: config.name)
        }
    }
}
