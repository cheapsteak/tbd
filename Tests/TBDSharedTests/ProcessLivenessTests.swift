import Foundation
import Testing
@testable import TBDShared

@Suite struct ProcessLivenessTests {
    // Seams let both branches run without real processes.
    private func check(pid: pid_t, alive: Bool, path: String?) -> Bool {
        ProcessLiveness.isLiveNamedProcess(
            pid: pid,
            name: ProcessLiveness.daemonExecutableName,
            isAlive: { _ in alive },
            executablePath: { _ in path }
        )
    }

    @Test func nonPositivePidIsNotLive() {
        #expect(check(pid: 0, alive: true, path: "/x/TBDDaemon") == false)
        #expect(check(pid: -1, alive: true, path: "/x/TBDDaemon") == false)
    }

    @Test func deadPidIsNotLive() {
        #expect(check(pid: 42, alive: false, path: "/x/TBDDaemon") == false)
    }

    @Test func aliveWithNoResolvablePathIsNotLive() {
        #expect(check(pid: 42, alive: true, path: nil) == false)
        #expect(check(pid: 42, alive: true, path: "") == false)
    }

    // The reboot recycled-pid case: some OTHER live process now holds the pid.
    @Test func aliveButDifferentExecutableIsNotLive() {
        #expect(check(pid: 42, alive: true, path: "/usr/bin/login") == false)
        #expect(check(pid: 42, alive: true, path: "/x/TBDDaemonHelper") == false)
    }

    @Test func aliveTBDDaemonIsLive() {
        #expect(check(pid: 42, alive: true, path: "/Users/x/.build/debug/TBDDaemon") == true)
        #expect(check(pid: 42, alive: true, path: "/Applications/TBD.app/Contents/MacOS/TBDDaemon") == true)
    }
}
