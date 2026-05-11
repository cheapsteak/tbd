import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct FileLockTests {

    @Test func acquiresAndReleases() throws {
        let path = NSTemporaryDirectory() + "tbd-flock-\(UUID().uuidString).lock"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let lock = try FileLock.acquire(path: path)
        try lock.release()
    }

    @Test func twoLocksOnSamePathSerialize() async throws {
        let path = NSTemporaryDirectory() + "tbd-flock-\(UUID().uuidString).lock"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try FileLock.acquire(path: path)

        // Kick off a second acquire in a Task. It should block until we
        // release the first. Capture the timestamp at which it actually
        // returns so we can assert it didn't return early.
        let secondAcquireStarted = Date()
        let secondAcquireTask = Task<Date, Error> {
            let second = try FileLock.acquire(path: path)
            let acquiredAt = Date()
            try second.release()
            return acquiredAt
        }

        // Hold the first lock for at least 200ms, then release.
        try await Task.sleep(for: .milliseconds(200))
        let releasedAt = Date()
        try first.release()

        let secondAcquiredAt = try await secondAcquireTask.value

        // The second acquire's completion must happen at-or-after the
        // first release. If `flock` were broken (returned immediately),
        // `secondAcquiredAt` would be earlier than `releasedAt`. Allow a
        // small tolerance for scheduling jitter between the two clocks.
        let secondWaitedFor = secondAcquiredAt.timeIntervalSince(secondAcquireStarted)
        let firstHeldFor = releasedAt.timeIntervalSince(secondAcquireStarted)
        #expect(secondWaitedFor >= firstHeldFor - 0.05,
                "second acquire returned at \(secondAcquiredAt) but first released at \(releasedAt)")
    }

    @Test func createsLockFileIfAbsent() throws {
        let path = NSTemporaryDirectory() + "tbd-flock-\(UUID().uuidString).lock"
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(FileManager.default.fileExists(atPath: path) == false)
        let lock = try FileLock.acquire(path: path)
        #expect(FileManager.default.fileExists(atPath: path) == true)
        try lock.release()
    }
}
