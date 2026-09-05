import Foundation

/// Runs an `async` shutdown exactly once, and lets every caller await that one
/// run.
///
/// Nothing serializes daemon shutdown: SIGTERM and SIGINT each fire an
/// independent, undeduplicated `Task { await daemon.stop() }` in `main.swift`,
/// and a supervisor escalating signals sends both. Both reach every server's
/// `stop()` through `Daemon.stop()`.
///
/// For a NIO-backed server, running the shutdown body twice does not merely
/// repeat work — it hangs. The body's first act is `channel.close()`, which off
/// the event loop is `eventLoop.execute { ... }` fulfilling a promise, and a
/// `SelectableEventLoop` whose group has already shut down *discards* submitted
/// work: `_schedule0` takes the `!validExternalStateToScheduleTasks` branch,
/// prints "Cannot schedule tasks on an EventLoop that has already shut down"
/// and returns without enqueuing anything. The promise is never fulfilled, so
/// `try await channel.close()` suspends for good — and the event-loop threads
/// have already exited, so the wedged task leaves a process at 0% CPU with
/// nothing to see.
///
/// (`MultiThreadedEventLoopGroup.shutdownGracefully()` itself is *not* the
/// problem, and it is worth saying so because it looks like the culprit: it
/// documents that a repeat call is safe and its handler still runs, and its
/// implementation switches on `runState` under a lock — `.closing` appends the
/// handler to the pending list, `.closed` dispatches it immediately — so
/// repeated and concurrent calls both complete. Once the body runs once,
/// though, the question stops arising at all.)
///
/// Callers `await` the one run rather than returning early, so `stop()` still
/// means "the shutdown has finished" for everyone who called it. The task is
/// unstructured on purpose: it does not inherit its creator's cancellation, so
/// a cancelled signal handler cannot abandon a shutdown other callers are
/// waiting on.
final class ShutdownLatch: Sendable {
    private nonisolated(unsafe) var task: Task<Void, Never>?
    private let lock = NSLock()

    /// Run `body` if this is the first call; otherwise await the run the first
    /// call started. Later `body` arguments are never invoked — every caller of
    /// a given latch passes the same shutdown.
    func run(_ body: @escaping @Sendable () async -> Void) async {
        await started(body).value
    }

    /// Hand back the single run, starting it if this is the first call.
    /// Synchronous and lock-held so two callers arriving together cannot both
    /// start one.
    private func started(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let task { return task }
        let created = Task { await body() }
        task = created
        return created
    }
}
