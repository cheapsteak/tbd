import Foundation
import Darwin
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "fileWatcher")

/// Observes a single file on disk and invokes `onChange` (debounced ~150ms,
/// hopped onto the main actor) whenever the file changes. Survives atomic
/// saves (rename/delete) by re-opening the watcher on the same path after a
/// small delay.
///
/// ## Why this is *not* `@MainActor` or `ObservableObject`
///
/// An earlier design exposed `@Published var revision: Int` on a
/// `@MainActor`-isolated `ObservableObject` and was hosted as a
/// `@StateObject` on `FilePreviewView`. Closing the code-viewer pane crashed
/// the app with `EXC_BREAKPOINT` (SIGTRAP). The OS log showed
/// `BUG IN CLIENT OF LIBDISPATCH: Block was expected to execute on queue
/// [com.apple.main-thread]` on two non-main worker threads, immediately
/// preceded by SwiftUI's "NSHostingView is being laid out reentrantly while
/// rendering its SwiftUI content" warning. The earliest crash trace pointed
/// straight at `swift_release` inside `AGGraphSetOutputValue` during
/// `GraphHost.updatePreferences()` — the Combine + `@StateObject` teardown
/// was running off the main thread during a failed-layout-pass recovery,
/// tripping `dispatchPrecondition(.onQueue(.main))` inside Combine's
/// internals.
///
/// The fix: keep the watcher a plain reference type with no actor isolation
/// and no Combine publishers. SwiftUI observes a separate `@State var
/// revision: Int` on the host view; the watcher just calls `onChange` on the
/// main actor when the file changes, and the view bumps its own revision.
/// No `@StateObject`, no `@Published`, no Combine subscription teardown
/// during view destruction.
///
/// ## Lifecycle invariants
///
/// 1. The file descriptor is closed exactly once, by the dispatch source's
///    cancel handler. `cancel()` is invoked from `stop()` (path change /
///    explicit stop) and from `deinit` (view teardown). No path leaks an
///    FD; no path double-closes.
/// 2. All event/cancel/Task closures capture `self` weakly — the source's
///    handlers and the in-flight `Task`s never keep the watcher alive past
///    its owning view.
/// 3. `observe(path:)` is idempotent on the same path; on a different path
///    it calls `stop()` first.
/// 4. All mutable state (`source`, `watchedPath`, debounce/reopen tasks,
///    `onChange`) is guarded by `OSAllocatedUnfairLock<State>` so callers
///    may invoke `observe`/`stop` from any isolation context, and `deinit`
///    (which Swift always treats as `nonisolated`) can tear down safely
///    from whatever thread released the last reference.
final class FileWatcher: @unchecked Sendable {

    /// Bundled mutable state, all guarded by `state.withLock { ... }`.
    fileprivate struct State {
        var onChange: (@Sendable () -> Void)?
        var source: DispatchSourceFileSystemObject?
        var watchedPath: String?
        var debounceTask: Task<Void, Never>?
        var reopenTask: Task<Void, Never>?
    }

    /// Invoked on the main actor each time the watched file changes (after
    /// debouncing). Set by the owning view; the watcher hops onto the main
    /// actor before invoking it.
    var onChange: (@Sendable () -> Void)? {
        get { state.withLock { $0.onChange } }
        set { state.withLock { $0.onChange = newValue } }
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// DEBUG-only counter for lifecycle balance assertions in tests.
    #if DEBUG
    nonisolated private static let _liveCountLock = OSAllocatedUnfairLock<Int>(initialState: 0)
    nonisolated static var liveCount: Int { _liveCountLock.withLock { $0 } }
    #endif

    init() {
        #if DEBUG
        Self._liveCountLock.withLock { $0 += 1 }
        #endif
    }

    deinit {
        // `source.cancel()` and `Task.cancel()` are safe to call from any
        // thread / isolation context. The source's cancel handler runs on
        // its dispatch queue and closes the FD exactly once. We grab the
        // lock briefly to hand off ownership of the cancellable resources
        // to local vars, then release the lock before cancelling — that
        // way the dispatch source's release (which can run its cancel
        // handler on the GCD queue) doesn't reenter under our lock.
        let (debounce, reopen, src): (Task<Void, Never>?, Task<Void, Never>?, DispatchSourceFileSystemObject?) =
            state.withLock { s in
                let trio = (s.debounceTask, s.reopenTask, s.source)
                s.debounceTask = nil
                s.reopenTask = nil
                s.source = nil
                s.watchedPath = nil
                s.onChange = nil
                return trio
            }
        debounce?.cancel()
        reopen?.cancel()
        src?.cancel()
        #if DEBUG
        Self._liveCountLock.withLock { $0 -= 1 }
        #endif
    }

    func observe(_ path: String) {
        state.withLock { s in
            guard path != s.watchedPath else { return }
            stopLocked(&s)
            startWatchingLocked(&s, path: path)
        }
    }

    func stop() {
        state.withLock { s in
            stopLocked(&s)
        }
    }

    // MARK: - Private (caller holds the lock)

    private func stopLocked(_ s: inout State) {
        s.debounceTask?.cancel(); s.debounceTask = nil
        s.reopenTask?.cancel(); s.reopenTask = nil
        s.source?.cancel()           // triggers cancel handler → close(fd)
        s.source = nil
        s.watchedPath = nil
    }

    private func startWatchingLocked(_ s: inout State, path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist (or we can't open it). Remember the intent
            // anyway so a later observe(samePath) is still a no-op; the
            // existing one-shot loaders in the leaf views will surface the
            // read error.
            s.watchedPath = path
            logger.debug("FileWatcher: open(\(path, privacy: .public)) failed errno=\(errno)")
            return
        }

        let queue = DispatchQueue.global(qos: .utility)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            // Capture the mask while we're on the dispatch queue; hop into
            // the watcher (under its lock) on whichever queue we're on.
            let mask = src.data
            self?.handleEvent(mask: mask, path: path)
        }

        src.setCancelHandler {
            // FD closed exactly once, here, regardless of who triggered
            // cancellation (stop / deinit / re-open).
            close(fd)
        }

        s.source = src
        s.watchedPath = path
        src.resume()
    }

    private func handleEvent(mask: DispatchSource.FileSystemEvent, path: String) {
        // Atomic save: vim/VS Code/Prettier write a temp file then rename
        // it over the original. The original inode is now gone even though
        // the path still resolves to a file.
        if mask.contains(.delete) || mask.contains(.rename) || mask.contains(.revoke) {
            scheduleReopen(path: path)
            return
        }

        // Write/extend: trailing-edge debounce a notification.
        scheduleDebouncedNotify()
    }

    private func scheduleReopen(path: String) {
        let newTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            let cb: (@Sendable () -> Void)? = self.state.withLock { s in
                guard s.watchedPath == path else { return nil }
                self.stopLocked(&s)
                self.startWatchingLocked(&s, path: path)
                return s.onChange
            }
            if let cb {
                await MainActor.run { cb() }
            }
        }
        state.withLock { s in
            // If we're racing with a `stop()` that already happened, the
            // path won't match in the body above — the task will be a
            // benign no-op. We still record it so that a subsequent
            // `stop()`/deinit cancels it promptly.
            guard s.watchedPath == path else {
                newTask.cancel()
                return
            }
            s.reopenTask?.cancel()
            s.reopenTask = newTask
        }
    }

    private func scheduleDebouncedNotify() {
        let newTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let cb: (@Sendable () -> Void)? = self.state.withLock { $0.onChange }
            if let cb {
                await MainActor.run { cb() }
            }
        }
        state.withLock { s in
            s.debounceTask?.cancel()
            s.debounceTask = newTask
        }
    }
}
