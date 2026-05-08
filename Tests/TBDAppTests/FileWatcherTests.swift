import Foundation
import os
import Testing

@testable import TBDApp

@Suite("FileWatcher")
struct FileWatcherTests {

    /// Construct many watchers without ever calling `changes(for:)`.
    /// `FileWatcher` itself is now a stateless factory, so this should be
    /// trivially balanced — no FDs opened, no streams alive.
    @MainActor
    @Test func factoryConstructionIsStateless() async {
        let baseline = FileWatcher.liveStreamCount
        do {
            var watchers: [FileWatcher] = []
            for _ in 0..<50 {
                watchers.append(FileWatcher())
            }
            // Constructing a FileWatcher must not start any stream.
            #expect(FileWatcher.liveStreamCount == baseline)
            watchers.removeAll()
        }
        await Task.yield()
        #expect(FileWatcher.liveStreamCount == baseline)
    }

    /// Start a stream against a real temp file, drop the iterator, and
    /// confirm the stream's `onTermination` ran (live count returns to
    /// baseline). This covers the core invariant: any path that drops the
    /// iterator must drive cleanup, including the dispatch source's cancel
    /// handler closing the FD.
    @MainActor
    @Test func liveStreamCountReturnsToBaselineAfterIteratorDrops() async {
        let baseline = FileWatcher.liveStreamCount

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("filewatcher-test-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmpURL.path, contents: Data("hi".utf8))
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            let w = FileWatcher()
            var iterator = w.changes(for: tmpURL.path).makeAsyncIterator()
            #expect(FileWatcher.liveStreamCount == baseline + 1)
            // Dropping `iterator` here triggers continuation.onTermination
            // (no consumer left to receive yields).
            _ = iterator
        }

        // Give GCD a moment to run the cancel handler and the
        // onTermination callback.
        for _ in 0..<10 {
            if FileWatcher.liveStreamCount == baseline { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileWatcher.liveStreamCount == baseline)
    }

    /// Cancelling the consuming `Task` (the SwiftUI `.task` analogue) must
    /// also drive the stream's onTermination — that's the most common
    /// real-world cleanup path.
    @MainActor
    @Test func cancellingConsumingTaskTerminatesStream() async {
        let baseline = FileWatcher.liveStreamCount

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("filewatcher-test-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmpURL.path, contents: Data("hi".utf8))
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let w = FileWatcher()
        let path = tmpURL.path
        let task = Task {
            for await _ in w.changes(for: path) {
                // Nothing to do — we just need a live consumer.
            }
        }
        // Yield to let the Task actually start iterating.
        await Task.yield()
        #expect(FileWatcher.liveStreamCount >= baseline + 1)

        task.cancel()
        _ = await task.value

        for _ in 0..<10 {
            if FileWatcher.liveStreamCount == baseline { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileWatcher.liveStreamCount == baseline)
    }

    /// Opening a non-existent path must finish the stream cleanly — no
    /// hang, no leak. The for-await loop should exit immediately.
    @MainActor
    @Test func nonExistentPathFinishesStreamImmediately() async {
        let baseline = FileWatcher.liveStreamCount
        let w = FileWatcher()
        let bogus = "/definitely/does/not/exist/\(UUID().uuidString)"

        var receivedAny = false
        for await _ in w.changes(for: bogus) {
            receivedAny = true
        }
        #expect(receivedAny == false)

        for _ in 0..<10 {
            if FileWatcher.liveStreamCount == baseline { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileWatcher.liveStreamCount == baseline)
    }
}
