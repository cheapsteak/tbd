import Foundation
import Testing
@testable import TBDApp

// MARK: - isLiveTBDDaemon forwarding

/// `isLiveTBDDaemon` forwards to `ProcessLiveness.isLiveNamedProcess`, whose
/// branches `TBDSharedTests/ProcessLivenessTests` covers. What is left to pin
/// here is the forward itself: the executable name it passes and that both
/// seams arrive intact.
///
/// The first arm is the reboot failure #471 fixed: the pid file survives a
/// reboot, an unrelated process is handed the recorded pid, and a bare
/// `kill(pid, 0)` reports it alive. It must NOT read as a running daemon. The
/// second arm keeps a forward that always answered `false` from passing.
@Test func isLiveTBDDaemon_forwardsTheDaemonNameAndBothSeams() {
    #expect(DaemonLiveness.isLiveTBDDaemon(
        pid: 98251,
        isAlive: { _ in true },
        executablePath: { _ in "/usr/libexec/somethingelsed" }
    ) == false)
    #expect(DaemonLiveness.isLiveTBDDaemon(
        pid: 123,
        isAlive: { _ in true },
        executablePath: { _ in "/some/worktree/.build/debug/TBDDaemon" }
    ) == true)

    // A dead pid short-circuits before its path is resolved...
    var resolverCalled = false
    #expect(DaemonLiveness.isLiveTBDDaemon(
        pid: 98251,
        isAlive: { _ in false },
        executablePath: { _ in
            resolverCalled = true
            return "/some/worktree/.build/debug/TBDDaemon"
        }
    ) == false)
    #expect(resolverCalled == false)

    // ...and a non-positive pid before anything is signalled: pid 0 would
    // address the caller's own process group.
    var aliveCalled = false
    #expect(DaemonLiveness.isLiveTBDDaemon(
        pid: 0,
        isAlive: { _ in
            aliveCalled = true
            return true
        },
        executablePath: { _ in "/x/TBDDaemon" }
    ) == false)
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
