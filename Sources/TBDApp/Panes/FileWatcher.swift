import Foundation
import Darwin
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "fileWatcher")

/// Observes a single file on disk and yields a debounced (~150ms) `Void`
/// each time the file changes. Survives atomic saves (rename/delete) by
/// re-opening the watcher on the same path after a small delay.
///
/// ## Why `AsyncStream` rather than a callback
///
/// An earlier `@StateObject` + `@MainActor ObservableObject` + `@Published`
/// design crashed during view teardown (Combine subscription release on a
/// non-main thread). The fix that shipped in PR #108 reduced the watcher to
/// a plain `Sendable` reference type with an `onChange` callback, owned via
/// `@State` on the host view. That works, but the lifetime story is
/// imperative — the host has to wire `onChange` and call `observe` /
/// `stop` itself, and the watcher stays alive across `.task` cancellations.
///
/// This refinement, modeled on Point-Free's `FileStorage` PersistenceKey
/// pattern, ties the file descriptor's lifetime to a single
/// `AsyncStream<Void>`:
///
/// - Each call to `changes(for:)` opens its own FD, builds its own
///   dispatch source, and returns a fresh stream. No shared state, no
///   `observe`/`stop` API.
/// - When the consuming `.task` is cancelled (path change, view teardown)
///   the stream's iterator is dropped, which fires
///   `continuation.onTermination`. That cancels the dispatch source, whose
///   cancel handler closes the FD exactly once.
/// - Atomic saves (vim `:w`, prettier, etc.) on the watched inode trigger a
///   re-open of the same path after ~50ms. The old source is cancelled
///   (closing its FD) before the new one starts, so we never leak.
///
/// ## Lifecycle invariants
///
/// 1. `open(path, O_EVTONLY)` — read-only event subscription, no other modes.
/// 2. `close(fd)` is called exactly once per opened FD, only from the
///    dispatch source's cancel handler.
/// 3. All exit paths funnel through `continuation.onTermination`:
///    - Consumer drops the iterator (`break` out of `for await`).
///    - Consuming `.task` is cancelled (host view torn down, `.task(id:)`
///      identity changes).
///    - The watcher itself calls `continuation.finish()` (re-open failed).
///    Each of those cancels the current dispatch source, which closes the
///    FD via its cancel handler.
/// 4. The dispatch event handler holds a weak reference to the per-stream
///    `StreamState` box. When the stream terminates, the box is released,
///    and any in-flight handler call becomes a no-op.
final class FileWatcher: Sendable {

    /// Trailing-edge debounce window for `.write` / `.extend` events.
    /// Internal (not private) so tests assert against the production value
    /// instead of duplicating the literal.
    static let debounceInterval: Duration = .milliseconds(150)

    /// Delay before re-opening the watched path after an atomic save
    /// (`.delete` / `.rename` / `.revoke` on the watched inode).
    static let reopenDelay: Duration = .milliseconds(50)

    private let clock: any Clock<Duration>

    /// - Parameter clock: seam for the two delays above (`Duration` is
    ///   behavior). Defaulted, so the single production call site is
    ///   unchanged and the seam is behavior-preserving by construction.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Yields a debounced (~150ms trailing-edge) `Void` each time `path`
    /// changes on disk. The stream's lifetime owns the file descriptor: when
    /// the consuming `.task` is cancelled (or the iterator is dropped), the
    /// continuation's onTermination callback cancels the dispatch source,
    /// which closes the FD via its cancel handler.
    ///
    /// Atomic-save aware: a `.delete` / `.rename` / `.revoke` event on the
    /// watched inode triggers a re-open of the same path after ~50ms. If
    /// the re-open fails (file genuinely gone) the stream is finished.
    func changes(for path: String) -> AsyncStream<Void> {
        AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let box = StreamState(path: path, continuation: continuation, clock: self.clock)

            #if DEBUG
            Self._liveStreamCountLock.withLock { $0 += 1 }
            #endif

            // First open. If it fails, finish the stream right away.
            // (We still register onTermination so the DEBUG counter is
            // balanced and `finish()` is idempotent.)
            continuation.onTermination = { _ in
                box.terminate()
                #if DEBUG
                Self._liveStreamCountLock.withLock { $0 -= 1 }
                #endif
            }

            if !box.startWatching() {
                continuation.finish()
            }
        }
    }

    /// DEBUG-only counter for lifecycle balance assertions in tests.
    /// Increments when a stream is created, decrements when its
    /// `onTermination` fires (consumer dropped iterator or `.task` was
    /// cancelled or `finish()` was called).
    #if DEBUG
    nonisolated private static let _liveStreamCountLock = OSAllocatedUnfairLock<Int>(initialState: 0)
    nonisolated static var liveStreamCount: Int { _liveStreamCountLock.withLock { $0 } }
    #endif
}

// MARK: - StreamState (per-stream lifetime box)

/// Mutable state for a single in-flight `changes(for:)` stream. Guarded by
/// `OSAllocatedUnfairLock` so the dispatch event handler (running on a
/// global utility queue) and the `onTermination` callback (running on
/// whatever thread released the iterator) can both touch it safely.
///
/// The box itself is held strongly by the dispatch source's event handler
/// closure for as long as the source is alive. When `terminate()` cancels
/// the source, the source's GCD-side strong references go away, the cancel
/// handler runs (closing the FD), and the box becomes eligible for
/// deallocation.
private final class StreamState: @unchecked Sendable {
    fileprivate struct Inner {
        var source: DispatchSourceFileSystemObject?
        var debounceTask: Task<Void, Never>?
        var reopenTask: Task<Void, Never>?
        /// Set once `terminate()` has run; further events are ignored.
        var terminated: Bool = false
    }

    private let inner = OSAllocatedUnfairLock<Inner>(initialState: Inner())
    private let path: String
    private let continuation: AsyncStream<Void>.Continuation
    private let clock: any Clock<Duration>

    init(path: String,
         continuation: AsyncStream<Void>.Continuation,
         clock: any Clock<Duration>) {
        self.path = path
        self.continuation = continuation
        self.clock = clock
    }

    /// Open `self.path` and start a dispatch source for it. Returns `false`
    /// if `open()` failed (caller should `continuation.finish()`).
    func startWatching() -> Bool {
        let fd = open(self.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.debug("FileWatcher: open(\(self.path, privacy: .public)) failed errno=\(errno)")
            return false
        }

        let queue = DispatchQueue.global(qos: .utility)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )

        // Capture the source weakly via a local — the source is kept alive
        // by `inner.source` plus its own GCD-side retain. Capture self
        // weakly so the box is not kept alive by the dispatch source past
        // the consumer dropping the stream (after which the source is
        // already cancelled and the handler will not fire again).
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let mask = src.data
            self.handleEvent(mask: mask)
        }

        src.setCancelHandler {
            // FD closed exactly once, here, regardless of who triggered
            // cancellation (terminate / atomic-save reopen / stream
            // consumer dropping the iterator).
            close(fd)
        }

        // Install the new source under the lock, returning either the
        // previous epoch's source (so we can cancel it below) or — if
        // terminate() already ran — the freshly-built `src` itself, so
        // the same teardown step closes its FD.
        let previousSource: DispatchSourceFileSystemObject? = inner.withLock { i -> DispatchSourceFileSystemObject? in
            if i.terminated {
                return src
            }
            let prev = i.source
            i.source = src
            return prev
        }

        // Always cancel any previous epoch's source AND resume `src`. The
        // resume is the load-bearing detail: per GCD docs, "if a source
        // was suspended at the time `dispatch_source_cancel()` was called,
        // the cancellation handler will be submitted after the source is
        // resumed." Without resume() on every path, a path where another
        // thread cancels `src` while it's still suspended (race with
        // terminate(), or the `terminated`-at-install case above) would
        // never run the cancel handler — leaking the FD.
        //
        // Resuming an already-cancelled source is harmless: GCD dispatches
        // the cancel handler and delivers no events.
        previousSource?.cancel()
        src.resume()
        return true
    }

    /// Called by the dispatch source's event handler. The source/queue keep
    /// the box alive long enough to safely touch `inner` here.
    private func handleEvent(mask: DispatchSource.FileSystemEvent) {
        // Atomic save: vim/VS Code/Prettier write a temp file then rename
        // it over the original. The original inode is now gone even though
        // the path still resolves to a file.
        if mask.contains(.delete) || mask.contains(.rename) || mask.contains(.revoke) {
            scheduleReopen()
            return
        }
        // Write/extend: trailing-edge debounce a notification.
        scheduleDebouncedNotify()
    }

    private func scheduleDebouncedNotify() {
        let clock = self.clock
        let task = Task { [weak self] in
            try? await clock.sleep(for: FileWatcher.debounceInterval)
            // The `Task.isCancelled` re-check is load-bearing, not belt-and-braces:
            // `try?` swallows the `CancellationError` and falls through, and a
            // sleep that already *resumed* can no longer throw at all. So
            // cancelling the superseded task is not by itself enough to stop it —
            // this guard is the only thing that keeps a replaced debounce from
            // firing a stale notification. Removing it re-introduces
            // notify-per-write.
            guard !Task.isCancelled, let self else { return }
            self.yieldIfActive()
        }
        // The task is armed BEFORE it is installed below, so under a virtual
        // clock the sleep can resume before this lock is even taken. That is
        // safe only because `yieldIfActive()` re-checks `terminated` under the
        // lock — it stops being safe the moment that re-check is removed or
        // hoisted out of the lock.
        inner.withLock { i in
            if i.terminated {
                task.cancel()
                return
            }
            i.debounceTask?.cancel()
            i.debounceTask = task
        }
    }

    private func scheduleReopen() {
        let clock = self.clock
        let task = Task { [weak self] in
            try? await clock.sleep(for: FileWatcher.reopenDelay)
            // Same reasoning as `scheduleDebouncedNotify`: `try?` swallows
            // cancellation and a resumed sleep cannot throw, so this guard —
            // not `task.cancel()` — is what stops a superseded re-open from
            // opening a second FD for the same stream.
            guard !Task.isCancelled, let self else { return }
            self.performReopen()
        }
        // Armed before installed (see `scheduleDebouncedNotify`): safe only
        // because `performReopen()` re-checks `terminated` under the lock
        // before doing anything, and stops being safe if that check moves.
        inner.withLock { i in
            if i.terminated {
                task.cancel()
                return
            }
            i.reopenTask?.cancel()
            i.reopenTask = task
        }
    }

    private func performReopen() {
        // Bail out fast if the stream is already gone.
        if inner.withLock({ $0.terminated }) { return }

        if startWatching() {
            // Successful re-open — surface a single event so consumers
            // (e.g. file viewers) re-load the freshly-saved content.
            yieldIfActive()
        } else {
            // File genuinely gone (or unreadable). Finish the stream.
            // `terminate()` will run via `onTermination` and clean up.
            continuation.finish()
        }
    }

    private func yieldIfActive() {
        let active = inner.withLock { !$0.terminated }
        guard active else { return }
        continuation.yield()
    }

    /// Called from `continuation.onTermination`. Cancels the dispatch
    /// source (which closes the FD via its cancel handler) and any
    /// outstanding tasks. Safe to call from any thread; idempotent.
    func terminate() {
        let (src, debounce, reopen): (DispatchSourceFileSystemObject?, Task<Void, Never>?, Task<Void, Never>?) =
            inner.withLock { i in
                if i.terminated {
                    return (nil, nil, nil)
                }
                i.terminated = true
                let trio = (i.source, i.debounceTask, i.reopenTask)
                i.source = nil
                i.debounceTask = nil
                i.reopenTask = nil
                return trio
            }
        debounce?.cancel()
        reopen?.cancel()
        src?.cancel()
    }
}
