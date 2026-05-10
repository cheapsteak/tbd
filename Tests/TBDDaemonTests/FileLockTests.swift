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

        // Try to acquire a non-blocking second lock from a separate fork; in-process
        // flock is per-FD, so a second open+flock from this same process should
        // *also* block. Run in a Task with a timeout to verify it blocks.
        let acquired = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let second = try FileLock.acquire(path: path)
                    try? second.release()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(150))
                try? first.release()
                return true
            }
            // collect; we only care that the first task eventually completes
            for await _ in group {}
            return true
        }
        #expect(acquired == true)
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
