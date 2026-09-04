import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct PIDFileStaleTests {
    private func tmpPidPath() -> String {
        NSTemporaryDirectory() + "pidfile-stale-\(UUID().uuidString).pid"
    }

    @Test func missingPidFileIsNotStale() {
        // No pid recorded → nothing to clean up → not stale.
        let f = PIDFile(path: tmpPidPath())
        #expect(f.isStale(isLiveDaemon: { _ in false }) == false)
    }

    @Test func liveDaemonPidIsNotStale() throws {
        let path = tmpPidPath()
        try "12345".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let f = PIDFile(path: path)
        #expect(f.isStale(isLiveDaemon: { $0 == 12345 }) == false)
    }

    // Recycled pid: the recorded pid is alive but is NOT a TBDDaemon. The old
    // kill(pid,0) check called this "not stale" and left the dead socket, which
    // wedged a freshly-spawned daemon. It must now read as stale.
    @Test func recycledNonDaemonPidIsStale() throws {
        let path = tmpPidPath()
        try "12345".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let f = PIDFile(path: path)
        #expect(f.isStale(isLiveDaemon: { _ in false }) == true)
    }

    // MARK: - Compare-and-delete

    @Test func removeIfOwnedRemovesOurOwnPidFile() throws {
        let path = tmpPidPath()
        try "12345".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let f = PIDFile(path: path)
        #expect(f.removeIfOwned(pid: 12345) == true)
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    // The handover case: a successor has already written its own pid over the
    // file, and the predecessor is shutting down. An unconditional remove()
    // here deletes the successor's claim and reopens the spawn race the
    // successor-first write closes.
    @Test func removeIfOwnedLeavesASuccessorsPidFile() throws {
        let path = tmpPidPath()
        try "999".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let f = PIDFile(path: path)
        #expect(f.removeIfOwned(pid: 12345) == false)
        #expect(FileManager.default.fileExists(atPath: path) == true)
        #expect(f.read() == 999, "the successor's claim was rewritten")
    }

    @Test func removeIfOwnedOnAMissingFileIsANoOp() {
        let f = PIDFile(path: tmpPidPath())
        #expect(f.removeIfOwned(pid: 12345) == false)
    }

    // A successor whose handover failed hands the file back, so the live
    // predecessor keeps its claim and the app's poller does not read it as
    // absent. `Daemon.start()` is the only caller that passes a pid.
    @Test func writeCanRestoreAnotherProcessesClaim() throws {
        let path = tmpPidPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let f = PIDFile(path: path)
        try f.write(pid: 999)
        #expect(f.read() == 999)
        try f.write(pid: 4242)
        #expect(f.read() == 4242, "a later claim must overwrite the earlier one")
    }
}
