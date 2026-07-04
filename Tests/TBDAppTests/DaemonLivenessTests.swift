import Foundation
import Testing
@testable import TBDApp

// MARK: - isLiveTBDDaemon branches

@Test func isLiveTBDDaemon_deadPid_returnsFalse_withoutResolvingPath() {
    var resolverCalled = false
    let result = DaemonLiveness.isLiveTBDDaemon(
        pid: 98251,
        isAlive: { _ in false },
        executablePath: { _ in
            resolverCalled = true
            return "/some/worktree/.build/debug/TBDDaemon"
        }
    )
    #expect(result == false)
    #expect(resolverCalled == false)
}

@Test func isLiveTBDDaemon_alivePidRunningTBDDaemon_returnsTrue() {
    let result = DaemonLiveness.isLiveTBDDaemon(
        pid: 123,
        isAlive: { _ in true },
        executablePath: { _ in "/some/worktree/.build/debug/TBDDaemon" }
    )
    #expect(result == true)
}

@Test func isLiveTBDDaemon_recycledPidRunningOtherBinary_returnsFalse() {
    // The post-reboot failure mode: pid file survives, pid is reused by an
    // unrelated process — must NOT be treated as a running daemon.
    let result = DaemonLiveness.isLiveTBDDaemon(
        pid: 98251,
        isAlive: { _ in true },
        executablePath: { _ in "/usr/libexec/somethingelsed" }
    )
    #expect(result == false)
}

@Test func isLiveTBDDaemon_pathResolutionFails_returnsFalse() {
    // proc_pidpath can fail (e.g. another user's process). Unverifiable pids
    // are treated as stale rather than trusted.
    let result = DaemonLiveness.isLiveTBDDaemon(
        pid: 123,
        isAlive: { _ in true },
        executablePath: { _ in nil }
    )
    #expect(result == false)
}

@Test func isLiveTBDDaemon_emptyResolvedPath_returnsFalse() {
    let result = DaemonLiveness.isLiveTBDDaemon(
        pid: 123,
        isAlive: { _ in true },
        executablePath: { _ in "" }
    )
    #expect(result == false)
}

@Test func isLiveTBDDaemon_similarButDifferentBinaryName_returnsFalse() {
    let result = DaemonLiveness.isLiveTBDDaemon(
        pid: 123,
        isAlive: { _ in true },
        executablePath: { _ in "/some/worktree/.build/debug/TBDDaemonHelper" }
    )
    #expect(result == false)
}

@Test func isLiveTBDDaemon_nonPositivePid_returnsFalse_withoutSignalling() {
    // pid 0 would signal the caller's own process group; must short-circuit.
    var aliveCalled = false
    let result = DaemonLiveness.isLiveTBDDaemon(
        pid: 0,
        isAlive: { _ in
            aliveCalled = true
            return true
        },
        executablePath: { _ in "/x/TBDDaemon" }
    )
    #expect(result == false)
    #expect(aliveCalled == false)
}

// MARK: - pid file parsing

@Test func pidFromPidFileContents_parsesTrimmedInteger() {
    #expect(DaemonLiveness.pid(fromPidFileContents: "  98251\n") == 98251)
}

@Test func pidFromPidFileContents_malformed_returnsNil() {
    #expect(DaemonLiveness.pid(fromPidFileContents: "not-a-pid") == nil)
    #expect(DaemonLiveness.pid(fromPidFileContents: "") == nil)
}

// MARK: - real libproc resolver

@Test func processExecutablePath_ownPid_returnsOwnBinaryPath() {
    // Integration sanity check for the default resolver: our own pid must
    // resolve to a non-empty absolute path (the test runner binary).
    let path = DaemonLiveness.processExecutablePath(pid: getpid())
    #expect(path?.hasPrefix("/") == true)
}

@Test func processExecutablePath_deadPid_returnsNil() {
    // pid_t.max is far above any real pid on macOS (pid ceiling ~99999).
    let path = DaemonLiveness.processExecutablePath(pid: pid_t.max)
    #expect(path == nil)
}

// MARK: - pid-file-level helper (AppState.pidFilePointsAtLiveDaemon)

@Test func pidFilePointsAtLiveDaemon_missingFile_returnsFalse() {
    let bogus = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-liveness-\(UUID().uuidString).pid").path
    #expect(AppState.pidFilePointsAtLiveDaemon(pidFilePath: bogus) == false)
}

@Test func pidFilePointsAtLiveDaemon_pidOfNonDaemonProcess_returnsFalse() throws {
    // Our own live pid is real but is the test runner, not TBDDaemon — the
    // executable-name check must reject it even though kill(pid, 0) == 0.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-liveness-\(UUID().uuidString).pid")
    try "\(getpid())\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(AppState.pidFilePointsAtLiveDaemon(pidFilePath: url.path) == false)
}
