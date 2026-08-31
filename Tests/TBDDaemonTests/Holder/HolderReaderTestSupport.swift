import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// A holder started the way the daemon starts one — through the real
/// `HolderSpawner`, with a real `posix_spawn` — plus everything needed to take
/// it and its job back down.
///
/// Four rules, each one a bug the suite would otherwise ship:
///
///   1. **Every wait is a bounded poll.** A wedged holder must fail a test with
///      a named diagnostic, not hang the suite with no output.
///   2. **Every bootstrap is rc-free.** `/bin/sh` with an explicit environment,
///      never a login shell — a developer's profile must not decide whether a
///      test passes.
///   3. **Every test kills its holder AND its job.** Holder death is
///      deliberately not child death, so a test that terminates a holder
///      orphans whatever it was supervising.
///   4. **No `setenv`.** The rendezvous paths come from an explicit environment
///      dictionary handed to `spawn`, so nothing here can reach the developer's
///      real `~/tbd` even for an instant.
///
/// It deliberately duplicates the fixture in `HolderClientTests` rather than
/// sharing it: that file belongs to a separate change still under review, and a
/// shared extraction is worth doing once both have landed.
final class HolderProcessFixture {
    let home: String
    let sessionID: UUID
    let owner: HolderOwnerToken
    let handle: HolderHandle
    private var torndown = false
    private var reaped = false

    private final class BundleMarker {}

    /// A short scratch root. Short on purpose: the rendezvous socket lives
    /// under it and `sun_path` is 104 bytes, so a deep `TMPDIR` would fail the
    /// bind rather than the assertion.
    static func scratchHome() -> String {
        "/tmp/tbdh7-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// The environment the rendezvous paths are derived from *and* the holder
    /// process runs under. Explicit and rc-free: nothing here comes from the
    /// developer's shell, and `TBD_HOME` never leaves this dictionary.
    static func environment(home: String) -> [String: String] {
        ["TBD_HOME": home, "PATH": "/usr/bin:/bin"]
    }

    static func launch(command: String) -> HolderLaunchRequest {
        HolderLaunchRequest(
            executable: "/bin/sh",
            arguments: ["-c", command],
            workingDirectory: "/tmp",
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            columns: 80,
            rows: 24)
    }

    static func locateExecutable() -> URL? {
        let bundleURL = Bundle(for: BundleMarker.self).bundleURL
        var candidates = [bundleURL.deletingLastPathComponent(), bundleURL]
        if let main = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(main)
        }
        for directory in candidates {
            let candidate = directory.appendingPathComponent("TBDHolder")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func start(
        command: String,
        owner: String = "acme-installation",
        session: UUID = UUID()
    ) async throws -> HolderProcessFixture {
        let home = scratchHome()
        let token = HolderOwnerToken(rawValue: owner)
        let executable = try #require(
            locateExecutable(), "TBDHolder must be built beside the test bundle")
        let spawner = HolderSpawner(executableURL: executable)
        let handle = try await spawner.spawn(
            sessionID: session,
            launch: launch(command: command),
            owner: token,
            environment: environment(home: home))
        return HolderProcessFixture(home: home, sessionID: session, owner: token, handle: handle)
    }

    private init(home: String, sessionID: UUID, owner: HolderOwnerToken, handle: HolderHandle) {
        self.home = home
        self.sessionID = sessionID
        self.owner = owner
        self.handle = handle
    }

    /// Kills the holder AND the job, in that order, then removes the scratch
    /// root. Holder death is not child death, so both need naming. The holder
    /// is this process's own child — the spawner `posix_spawn`s it directly —
    /// so it must also be reaped, or the corpse outlives the suite.
    func tearDown() {
        guard !torndown else { return }
        torndown = true

        if !reaped {
            kill(handle.holderPID, SIGKILL)
            var ignored: Int32 = 0
            _ = waitpid(handle.holderPID, &ignored, 0)
            reaped = true
        }
        if holderProcessIsAlive(handle.childPID) { kill(handle.childPID, SIGKILL) }
        // The job is the holder's child, not ours, so nothing here can reap it;
        // the kernel reparents and reaps. Confirm it is gone so a leak fails the
        // test that caused it rather than the next run.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline, holderProcessIsAlive(handle.childPID) {
            usleep(20_000)
        }
        try? FileManager.default.removeItem(atPath: home)
    }
}

/// Whether a pid can still be signalled.
///
/// Both a running job and one wedged in `ttywait` — past its last instruction,
/// but blocked inside `proc_exit` behind an undrained terminal — answer yes,
/// and both mean the same thing to these tests: the exit has not completed.
/// Only a job whose exit finished and whose holder reaped it is gone.
func holderProcessIsAlive(_ pid: Int32) -> Bool {
    pid > 0 && kill(pid, 0) == 0
}

/// Polls an async condition until it holds or the budget runs out.
@discardableResult
func pollUntil(
    _ description: String,
    timeout: TimeInterval = 20.0,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("timed out after \(timeout)s waiting for \(description)", sourceLocation: sourceLocation)
    return false
}
