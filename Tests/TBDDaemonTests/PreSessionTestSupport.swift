import Foundation
import GRDB
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Shared fixtures for the pre-session hook suites (`PreSessionHookTests`,
// `PreSessionRerunTests`). Both are nested under `extension TBDHomeSerialized`
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

func makeLifecycle(
    db: TBDDatabase,
    recorder: PreSessionRecordedCommands? = nil,
    subscriptions: StateSubscriptionManager? = nil,
    timeout: TimeInterval = WorktreeLifecycle.defaultPreSessionTimeout,
    windowIsDead: (@Sendable (String) -> Bool)? = nil,
    listWindows: (@Sendable (String, String) -> [(windowID: String, paneID: String)])? = nil
) -> WorktreeLifecycle {
    var dryRunRecorder: (@Sendable ([String]) -> Void)?
    if let recorder {
        dryRunRecorder = { args in recorder.append(args) }
    }
    return WorktreeLifecycle(
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
        preSessionPollInterval: 0.05
    )
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
/// both pre-session suites assert on window-creation call order/content.
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
