import Foundation
import Testing

@testable import TBDApp

@Suite("FileWatcher")
struct FileWatcherTests {

    /// Creates and immediately releases many FileWatchers. If any of them
    /// kept an internal retain cycle (e.g. handler closure capturing self
    /// strongly, Task holding self), liveCount would not return to its
    /// starting value.
    @MainActor
    @Test func liveCountReturnsToZeroAfterRelease() async {
        let baseline = FileWatcher.liveCount

        do {
            var watchers: [FileWatcher] = []
            for _ in 0..<50 {
                watchers.append(FileWatcher())
            }
            #expect(FileWatcher.liveCount == baseline + 50)
            watchers.removeAll()
        }

        // Allow any deferred deallocations to settle on the main actor.
        await Task.yield()
        #expect(FileWatcher.liveCount == baseline)
    }

    @MainActor
    @Test func liveCountReturnsToZeroAfterObserveOnTempFile() async {
        let baseline = FileWatcher.liveCount

        // Create a real temp file so observe() actually opens an FD and
        // creates a dispatch source — we want to confirm the source's
        // strong refs to closures don't keep self alive.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("filewatcher-test-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmpURL.path, contents: Data("hi".utf8))
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            let w = FileWatcher()
            w.observe(tmpURL.path)
            #expect(FileWatcher.liveCount == baseline + 1)
            // w goes out of scope here
            _ = w
        }

        // Give GCD a moment to run the cancel handler / release closures.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(FileWatcher.liveCount == baseline)
    }

    @MainActor
    @Test func observeIsIdempotentOnSamePath() {
        // FileWatcher no longer exposes `revision` directly (see doc
        // comment on FileWatcher for why). The observable signal we have
        // here is "did onChange fire?", which it should NOT for a no-op
        // re-observe of the same (non-existent) path.
        var fireCount = 0
        let w = FileWatcher()
        w.onChange = { fireCount += 1 }
        w.observe("/some/path")
        w.observe("/some/path") // same path — should be a no-op
        #expect(fireCount == 0)
    }

    @MainActor
    @Test func stopIsIdempotent() {
        let w = FileWatcher()
        w.observe("/some/path")
        w.stop()
        w.stop() // should not crash
    }
}
