import Foundation
import CoreServices
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "themes")

@MainActor
final class ThemeDirectoryWatcher {
    // nonisolated(unsafe): we only ever read/write this from the main thread
    // (start/stop are @MainActor; deinit also runs synchronously after the last
    // main-thread release). The `nonisolated` annotation lets deinit access it
    // without crossing an actor boundary.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start(directory: URL) {
        stopStream()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ThemeDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in watcher.onChange() }
        }

        let paths = [directory.path] as CFArray
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            logger.warning("ThemeDirectoryWatcher: FSEventStreamCreate failed for \(directory.path, privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        stopStream()
    }

    // nonisolated so deinit can call it directly.
    nonisolated private func stopStream() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    deinit {
        stopStream()
    }
}
