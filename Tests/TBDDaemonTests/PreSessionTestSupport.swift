import Foundation
import GRDB
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Shared fixtures for the pre-session hook suites (`PreSessionHookTests`,
// `PreSessionRerunTests`); `isolateTBDHome()` is target-wide and other suites
// use it too. Every caller is nested under `extension TBDHomeSerialized`
// because `isolateTBDHome()` mutates the process-global `TBD_HOME` env var —
// see TBDHomeSerializedSuites.swift for why that requires serialization.
//
// These are plain (non-private) top-level functions rather than methods on
// `TBDHomeSerialized` itself: none of them touch instance state, and
// `TBDHomeSerialized` is an empty enum used purely as a serialization
// namespace, not a real type to hang methods off of.

/// Creates a unique temp TBD_HOME and points the process at it.
/// Caller must call the returned cleanup closure (idempotent).
func isolateTBDHome() -> (home: URL, cleanup: () -> Void) {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-presession-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let priorTBDHome = setTBDHome(home.path)
    return (home, {
        restoreTBDHome(priorTBDHome)
        try? FileManager.default.removeItem(at: home)
    })
}

/// Writes an executable `.worktree-hooks/<name>` into the repo and commits it
/// so fresh worktree checkouts contain it.
@discardableResult
func installHook(
    named name: String, repoDir: URL, script: String = "#!/bin/sh\nexit 0\n"
) async throws -> String {
    let hooksDir = repoDir.appendingPathComponent(".worktree-hooks")
    try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
    let hookPath = hooksDir.appendingPathComponent(name)
    try script.write(to: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: hookPath.path
    )
    try await shell("git add -A && git commit -m 'add \(name) hook'", at: repoDir)
    return hookPath.path
}

@discardableResult
func installPreSessionHook(
    repoDir: URL, script: String = "#!/bin/sh\nexit 0\n"
) async throws -> String {
    try await installHook(named: "preSession", repoDir: repoDir, script: script)
}

/// A lifecycle over dry-run tmux whose spawns go to the holder spawn double.
///
/// Every session opens on a pty holder, so the lifecycle is wired with a
/// registry built on `holder` (`makeHolderRegistryDouble`): pass your own
/// `FakeHolderLaunch` to read what was spawned (`holder.launches`). A suite
/// that needs the no-registry branch sets `holderRegistry = nil` on the result.
///
/// `processSignaller` is the liveness seam the hook-tab wait reads: a hook tab
/// is a holder tab, so "is the hook still running" is its row plus its job's
/// pid. The double's pids name no process, so the default answers that every
/// job the double started is still running — the hook only ends when the test
/// writes its marker — and every other pid is gone.
func makeLifecycle(
    db: TBDDatabase,
    recorder: PreSessionRecordedCommands? = nil,
    subscriptions: StateSubscriptionManager? = nil,
    timeout: TimeInterval = WorktreeLifecycle.defaultPreSessionTimeout,
    windowIsDead: (@Sendable (String) -> Bool)? = nil,
    listWindows: (@Sendable (String, String) -> [(windowID: String, paneID: String)])? = nil,
    processSignaller: ProcessSignaller = ScriptedLivenessSignaller.doubleJobsRunning,
    holder: FakeHolderLaunch = FakeHolderLaunch()
) -> WorktreeLifecycle {
    var dryRunRecorder: (@Sendable ([String]) -> Void)?
    if let recorder {
        dryRunRecorder = { args in recorder.append(args) }
    }
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(
            dryRun: true,
            dryRunRecorder: dryRunRecorder,
            dryRunWindowIsDead: windowIsDead,
            dryRunListWindows: listWindows
        ),
        hooks: HookResolver(),
        subscriptions: subscriptions,
        preSessionTimeout: timeout,
        preSessionPollInterval: 0.05,
        processSignaller: processSignaller
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: holder)
    return lifecycle
}

/// A `ProcessSignaller` that answers liveness from `probe` and signals nothing.
///
/// The wait for a hook tab's marker reads "is the hook still running" from the
/// job's pid, and the holder spawn double's pids name no process, so a real
/// signaller reads every hook as already gone. This one lets a test say what
/// the job is doing.
struct ScriptedLivenessSignaller: ProcessSignaller {
    let probe: @Sendable (Int32) -> Bool

    /// Every job the holder spawn double started reads as running; every other
    /// pid — including the `0` a dry-run tmux answers for a pane's pid — reads
    /// as gone.
    static let doubleJobsRunning = ScriptedLivenessSignaller(probe: {
        $0 > FakeHolderLaunch.pidFloor
    })

    /// Every pid reads as gone: the hook's job has exited.
    static let everyJobGone = ScriptedLivenessSignaller(probe: { _ in false })

    func isAlive(_ pid: Int32) -> Bool { probe(pid) }
    func terminate(_ pid: Int32) {}
    func forceKill(_ pid: Int32) {}
    func children(ofServerPID serverPID: Int32) -> [Int32] { [] }
    func commandLine(_ pid: Int32) -> String? { nil }
    func stat(_ pid: Int32) -> String? { nil }
    func startTime(_ pid: Int32) -> Date? { nil }
}

/// Builds a DB + repo + worktree fixture whose `path` IS `repoDir` (no real
/// `git worktree add` checkout) — `HookResolver.resolve` only checks the
/// filesystem, so pointing the worktree row straight at the repo checkout
/// lets a hook installed into `repoDir` after this call still resolve.
/// Callers own `repoDir`'s parent temp dir
/// (`repoDir.deletingLastPathComponent()`) and must remove it.
func makeWorktreeFixture(
    status: WorktreeStatus = .creating
) async throws -> (db: TBDDatabase, repoDir: URL, worktree: Worktree, repo: Repo) {
    let (tempDir, repoDir) = try await createTestRepo()
    let db = try TBDDatabase(inMemory: true)
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let worktree = try await db.worktrees.create(
        repoID: repo.id, name: "fixture", branch: "tbd/fixture",
        path: repoDir.path, tmuxServer: "tbd-test", status: status
    )
    return (db, repoDir, worktree, repo)
}

/// Writes the completion marker the wrapped hook command would write.
func writeMarker(worktreeID: UUID, exitCode: Int) throws {
    let path = WorktreeLifecycle.preSessionMarkerPath(worktreeID: worktreeID)
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try "\(exitCode)\n".write(toFile: path, atomically: true, encoding: .utf8)
}

/// Thread-safe collector for TmuxManager dryRun recorded args. Shared because
/// several suites assert that a path issued, or did not issue, a tmux command.
/// Named distinctly from other files' file-private `RecordedCommands` types
/// (e.g. `TBDWorktreeIDLeakTests.swift`) since this one must be visible
/// module-wide to be shared.
final class PreSessionRecordedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []

    func append(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        commands.append(args)
    }

    func snapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return commands
    }
}
