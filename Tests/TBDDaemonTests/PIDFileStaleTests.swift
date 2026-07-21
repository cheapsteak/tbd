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
}
