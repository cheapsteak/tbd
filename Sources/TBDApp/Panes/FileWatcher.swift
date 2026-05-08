import Foundation
import Darwin
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "fileWatcher")

/// Observes a single file on disk and bumps `revision` (debounced ~150ms)
/// whenever the file changes. Survives atomic saves (rename/delete) by
/// re-opening the watcher on the same path after a small delay.
///
/// Lifecycle invariants:
/// 1. The file descriptor is closed exactly once, by the dispatch source's
///    cancel handler. `cancel()` is invoked from `stop()` (path change /
///    explicit stop) and from `deinit` (view teardown). No path leaks an
///    FD; no path double-closes.
/// 2. All event/cancel/Task closures capture `self` weakly — the source's
///    handlers and the in-flight `Task`s never keep the watcher alive past
///    its owning view.
/// 3. `observe(path:)` is idempotent on the same path; on a different path
///    it calls `stop()` first.
///
/// Hosted as a `@StateObject` on `FilePreviewView` so SwiftUI manages its
/// lifetime deterministically — when the pane is closed (or the displayed
/// path changes such that the view's identity flips), `deinit` runs and
/// the source is cancelled.
@MainActor
final class FileWatcher: ObservableObject {

    /// Bumped each time the file changes (after debouncing). Views key
    /// their `.task(id:)` on `"\(path)#\(revision)"` to trigger reloads.
    @Published private(set) var revision: Int = 0

    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var debounceTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?

    /// DEBUG-only counter for lifecycle balance assertions in tests.
    /// Backed by an unfair lock so init/deinit can read and mutate from
    /// any isolation context (deinit may run off the main actor).
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
        // its dispatch queue and closes the FD exactly once.
        debounceTask?.cancel()
        reopenTask?.cancel()
        source?.cancel()
        #if DEBUG
        Self._liveCountLock.withLock { $0 -= 1 }
        #endif
    }

    func observe(_ path: String) {
        guard path != watchedPath else { return }
        stop()
        startWatching(path)
    }

    func stop() {
        debounceTask?.cancel(); debounceTask = nil
        reopenTask?.cancel(); reopenTask = nil
        source?.cancel()           // triggers cancel handler → close(fd)
        source = nil
        watchedPath = nil
    }

    // MARK: - Private

    private func startWatching(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist (or we can't open it). Remember the intent
            // anyway so a later observe(samePath) is still a no-op; the
            // existing one-shot loaders in the leaf views will surface the
            // read error.
            watchedPath = path
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
            // Capture the mask while we're on the dispatch queue; hop to
            // the main actor to mutate watcher state.
            let mask = src.data
            Task { @MainActor [weak self] in
                self?.handleEvent(mask: mask, path: path)
            }
        }

        src.setCancelHandler {
            // FD closed exactly once, here, regardless of who triggered
            // cancellation (stop / deinit / re-open).
            close(fd)
        }

        self.source = src
        self.watchedPath = path
        src.resume()
    }

    private func handleEvent(mask: DispatchSource.FileSystemEvent, path: String) {
        // Atomic save: vim/VS Code/Prettier write a temp file then rename
        // it over the original. The original inode is now gone even though
        // the path still resolves to a file.
        if mask.contains(.delete) || mask.contains(.rename) || mask.contains(.revoke) {
            reopenTask?.cancel()
            reopenTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled,
                      let self,
                      self.watchedPath == path
                else { return }
                self.stop()
                self.startWatching(path)
                self.revision &+= 1
            }
            return
        }

        // Write/extend: trailing-edge debounce a revision bump.
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.revision &+= 1
        }
    }
}
