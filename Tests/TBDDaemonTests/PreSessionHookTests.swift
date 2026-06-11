import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: these tests mutate the process-global
// `TBD_HOME` env var to isolate the hooks/default and runtime/presession
// directories from the developer's real ~/tbd. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite("Pre-session hook")
struct PreSessionHookTests {

    // MARK: - Helpers

    /// Creates a unique temp TBD_HOME and points the process at it.
    /// Caller must call the returned cleanup closure (idempotent).
    private func isolateTBDHome() -> (home: URL, cleanup: () -> Void) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-presession-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("TBD_HOME", home.path, 1)
        return (home, {
            unsetenv("TBD_HOME")
            try? FileManager.default.removeItem(at: home)
        })
    }

    /// Writes an executable `.worktree-hooks/preSession` into the repo and
    /// commits it so fresh worktree checkouts contain it.
    @discardableResult
    private func installPreSessionHook(
        repoDir: URL, script: String = "#!/bin/sh\nexit 0\n"
    ) async throws -> String {
        let hooksDir = repoDir.appendingPathComponent(".worktree-hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let hookPath = hooksDir.appendingPathComponent("preSession")
        try script.write(to: hookPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hookPath.path
        )
        try await shell("git add -A && git commit -m 'add preSession hook'", at: repoDir)
        return hookPath.path
    }

    private func makeLifecycle(
        db: TBDDatabase,
        recorder: RecordedCommands? = nil,
        subscriptions: StateSubscriptionManager? = nil,
        timeout: TimeInterval = WorktreeLifecycle.defaultPreSessionTimeout
    ) -> WorktreeLifecycle {
        var dryRunRecorder: (@Sendable ([String]) -> Void)?
        if let recorder {
            dryRunRecorder = { args in recorder.append(args) }
        }
        return WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true, dryRunRecorder: dryRunRecorder),
            hooks: HookResolver(),
            subscriptions: subscriptions,
            preSessionTimeout: timeout,
            preSessionPollInterval: 0.05
        )
    }

    /// Writes the completion marker the wrapped hook command would write.
    private func writeMarker(worktreeID: UUID, exitCode: Int) throws {
        let path = WorktreeLifecycle.preSessionMarkerPath(worktreeID: worktreeID)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "\(exitCode)\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - HookEvent + resolution

    @Test func preSessionEventNames() {
        #expect(HookEvent.preSession.rawValue == "preSession")
        #expect(HookEvent.preSession.conductorKey == "preSession")
        #expect(HookEvent.preSession.dmuxHookName == "pre_session")
    }

    @Test func resolvesFromWorktreeHooksDir() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let hookPath = try await installPreSessionHook(repoDir: repoDir)

        let resolved = HookResolver().resolve(
            event: .preSession, repoPath: repoDir.path, appHookPath: nil
        )
        #expect(resolved == hookPath)
    }

    @Test func resolvesFromAppPerRepoPath() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repoID = UUID()
        let appPath = TBDConstants.hookPath(
            repoID: repoID, eventName: HookEvent.preSession.rawValue
        )
        try FileManager.default.createDirectory(
            atPath: (appPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(toFile: appPath, atomically: true, encoding: .utf8)

        #expect(appPath.hasPrefix(TBDConstants.configDir.path),
                "app per-repo hook path must live under TBD_HOME")
        let resolved = HookResolver().resolve(
            event: .preSession, repoPath: repoDir.path, appHookPath: appPath
        )
        #expect(resolved == appPath)
    }

    @Test func resolvesFromGlobalDefault() async throws {
        let (home, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let globalDir = home.appendingPathComponent("hooks/default")
        try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
        let globalHook = globalDir.appendingPathComponent("preSession")
        try "#!/bin/sh\nexit 0\n".write(to: globalHook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: globalHook.path
        )

        let resolved = HookResolver().resolve(
            event: .preSession, repoPath: repoDir.path, appHookPath: nil
        )
        #expect(resolved == globalHook.path)
    }

    @Test func absentHookResolvesNil() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let resolved = HookResolver().resolve(
            event: .preSession, repoPath: repoDir.path, appHookPath: nil
        )
        #expect(resolved == nil)
    }

    // MARK: - Marker plumbing

    @Test func markerPathRespectsTBDHome() {
        let (home, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let id = UUID()
        let path = WorktreeLifecycle.preSessionMarkerPath(worktreeID: id)
        #expect(path.hasPrefix(home.path))
        #expect(path.contains("runtime/presession"))
        #expect(path.hasSuffix(id.uuidString))
    }

    @Test func preSessionCommandEscapesAndChains() {
        let cmd = WorktreeLifecycle.preSessionCommand(
            hookPath: "/tmp/it's here/preSession",
            runtimeDir: "/r/dir",
            markerPath: "/r/dir/marker",
            shell: "/bin/zsh"
        )
        #expect(cmd.contains("'/tmp/it'\\''s here/preSession'"))
        #expect(cmd.contains("__tbd_rc=$?"))
        #expect(cmd.contains("/bin/mkdir -p '/r/dir'"))
        #expect(cmd.contains("/bin/echo $__tbd_rc > '/r/dir/marker'"))
        #expect(cmd.hasSuffix("exec /bin/zsh"))
    }

    // MARK: - No hook: behavior identical to today (gating off-branch)

    @Test func noHookSpawnsClaudeFirstThenSetup() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let recorder = RecordedCommands()
        let lifecycle = makeLifecycle(db: db, recorder: recorder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
        #expect(wt.status == .active)

        // Exactly the two historical terminals, no pre-session tab.
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 2)
        #expect(!terminals.contains { $0.label == "pre-session" })
        let claude = try #require(terminals.first { $0.label == "Claude Code" })
        let setup = try #require(terminals.first { $0.label == "setup" })

        // Window creation order: claude window first, setup window second.
        let windowCalls = recorder.snapshot().filter { $0.contains("new-window") }
        #expect(windowCalls.count == 2)
        #expect(windowCalls[0].last?.contains("claude --session-id") == true,
                "first window must be the primary agent")
        #expect(windowCalls[1].last?.contains("claude --session-id") == false,
                "second window must be the setup hook/shell")

        // Tab order [claude, setup], active = claude.
        #expect(try await db.worktrees.getTabOrder(worktreeID: wt.id) == [claude.id, setup.id])
        #expect(try await db.worktrees.getActiveTabID(worktreeID: wt.id) == claude.id)
        #expect(try await db.notifications.unread(worktreeID: wt.id).isEmpty)
    }

    @Test func noHookCreateFailureStillDeletesRow() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // Occupy the branch, then force a user-specified-folder collision —
        // phase 2 fails and must delete the DB row (today's behavior).
        _ = try await lifecycle.createWorktree(
            repoID: repo.id, folder: "first", branch: "feat/clash", skipClaude: true
        )
        let pending = try await lifecycle.beginCreateWorktree(
            repoID: repo.id, folder: "second", branch: "feat/clash", skipClaude: true
        )
        await #expect(throws: WorktreeLifecycleError.self) {
            try await lifecycle.completeCreateWorktree(
                worktreeID: pending.id, skipClaude: true,
                userSpecifiedFolder: true, userSpecifiedBranch: true
            )
        }
        #expect(try await db.worktrees.get(id: pending.id) == nil,
                "phase-2 failure must delete the DB row")
    }

    // MARK: - With hook: gated spawn

    @Test func hookGatesPrimarySpawnUntilMarker() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let recorder = RecordedCommands()
        let lifecycle = makeLifecycle(db: db, recorder: recorder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)
        let completion = try await lifecycle.completeCreateWorktree(worktreeID: pending.id)
        guard case .preSessionPending(let phase3) = completion else {
            Issue.record("expected .preSessionPending when a preSession hook resolves")
            return
        }

        // Pre-session terminal created FIRST — and it's the only one so far.
        var terminals = try await db.terminals.list(worktreeID: pending.id)
        #expect(terminals.count == 1)
        let pre = try #require(terminals.first)
        #expect(pre.label == "pre-session")
        #expect(pre.kind == .shell)
        #expect(try await db.worktrees.get(id: pending.id)?.status == .creating)
        #expect(try await db.worktrees.getTabOrder(worktreeID: pending.id) == [pre.id])
        #expect(try await db.worktrees.getActiveTabID(worktreeID: pending.id) == pre.id)

        // The single window so far runs the wrapped hook command.
        let windowCalls = recorder.snapshot().filter { $0.contains("new-window") }
        #expect(windowCalls.count == 1)
        let body = windowCalls[0].last ?? ""
        #expect(body.contains(".worktree-hooks/preSession"))
        #expect(body.contains("runtime/presession"))
        // Hook env present on the window (exported in the command body).
        #expect(body.contains("export TBD_EVENT='preSession'"))

        // Still gated while the marker is absent.
        try await Task.sleep(nanoseconds: 200_000_000)
        terminals = try await db.terminals.list(worktreeID: pending.id)
        #expect(terminals.count == 1, "primary terminals must not spawn before the marker")

        // Hook "finishes" with exit 0.
        try writeMarker(worktreeID: pending.id, exitCode: 0)
        await phase3.value

        terminals = try await db.terminals.list(worktreeID: pending.id)
        #expect(terminals.count == 3)
        let claude = try #require(terminals.first { $0.label == "Claude Code" })
        let setup = try #require(terminals.first { $0.label == "setup" })
        #expect(try await db.worktrees.getTabOrder(worktreeID: pending.id)
                == [claude.id, pre.id, setup.id],
                "tab order must be [claude, preSession, setup]")
        #expect(try await db.worktrees.getActiveTabID(worktreeID: pending.id) == claude.id)
        #expect(try await db.worktrees.get(id: pending.id)?.status == .active)
        // Exit 0 → no notification.
        #expect(try await db.notifications.unread(worktreeID: pending.id).isEmpty)
        // Marker consumed.
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: pending.id)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
    }

    @Test func hookNonZeroExitStillSpawnsAndNotifies() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)
        let completion = try await lifecycle.completeCreateWorktree(worktreeID: pending.id)
        guard case .preSessionPending(let phase3) = completion else {
            Issue.record("expected .preSessionPending")
            return
        }

        try writeMarker(worktreeID: pending.id, exitCode: 1)
        await phase3.value

        let terminals = try await db.terminals.list(worktreeID: pending.id)
        #expect(terminals.count == 3, "non-zero exit must still spawn primary terminals")
        #expect(try await db.worktrees.get(id: pending.id)?.status == .active)

        let notifications = try await db.notifications.unread(worktreeID: pending.id)
        #expect(notifications.count == 1)
        #expect(notifications.first?.type == .error)
        #expect(notifications.first?.message?.contains("exit 1") == true)
    }

    @Test func hookTimeoutStillSpawnsAndNotifies() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        // Short injected timeout; the marker is never written. (The killed-pane
        // short-circuit can't fire under dryRun tmux — windowExists is always
        // true — so the timeout path covers the no-completion case here.)
        let lifecycle = makeLifecycle(db: db, timeout: 0.3)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)
        let completion = try await lifecycle.completeCreateWorktree(worktreeID: pending.id)
        guard case .preSessionPending(let phase3) = completion else {
            Issue.record("expected .preSessionPending")
            return
        }
        await phase3.value

        // Phase-3 problems must never delete the worktree row.
        let wt = try await db.worktrees.get(id: pending.id)
        #expect(wt != nil, "timeout must not delete the worktree row")
        #expect(wt?.status == .active, "worktree must not be stuck in .creating")
        let terminals = try await db.terminals.list(worktreeID: pending.id)
        #expect(terminals.count == 3)

        let notifications = try await db.notifications.unread(worktreeID: pending.id)
        #expect(notifications.count == 1)
        #expect(notifications.first?.type == .error)
        #expect(notifications.first?.message?.contains("timed out") == true)
    }

    // MARK: - Legacy sync create + revive

    @Test func legacyCreateWorktreeAwaitsPhase3Inline() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db, timeout: 0.3)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        // dryRun tmux never runs the hook, so phase 3 hits the short timeout;
        // the synchronous method must still return a fully set-up worktree.
        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
        #expect(wt.status == .active)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 3)
        #expect(terminals.contains { $0.label == "pre-session" })
    }

    @Test func reviveWithHookSpawnsGatedTerminals() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db, timeout: 0.3)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

        let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)
        #expect(revived.status == .active)
        let terminals = try await db.terminals.list(worktreeID: revived.id)
        #expect(terminals.count == 3)
        #expect(terminals.contains { $0.label == "pre-session" })
    }

    // MARK: - Broadcasts

    @Test func broadcastsTerminalCreatedAndSingleWorktreeCreated() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let collected = CollectedDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                collected.append(delta)
            }
            return true
        }
        let lifecycle = makeLifecycle(db: db, subscriptions: subs)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)
        let completion = try await lifecycle.completeCreateWorktree(worktreeID: pending.id)
        guard case .preSessionPending(let phase3) = completion else {
            Issue.record("expected .preSessionPending")
            return
        }

        // Early broadcasts: worktreeCreated + terminalCreated(pre-session).
        var snapshot = collected.snapshot()
        #expect(snapshot.contains { if case .worktreeCreated(let d) = $0 { return d.worktreeID == pending.id } else { return false } })
        #expect(snapshot.contains { if case .terminalCreated(let d) = $0 { return d.label == "pre-session" } else { return false } })

        try writeMarker(worktreeID: pending.id, exitCode: 0)
        await phase3.value

        snapshot = collected.snapshot()
        let worktreeCreatedCount = snapshot.filter {
            if case .worktreeCreated = $0 { return true } else { return false }
        }.count
        #expect(worktreeCreatedCount == 1, "worktreeCreated must be broadcast exactly once")
        let terminalLabels = snapshot.compactMap { delta -> String? in
            if case .terminalCreated(let d) = delta { return d.label } else { return nil }
        }
        #expect(terminalLabels.sorted() == ["Claude Code", "pre-session", "setup"],
                "terminalCreated must fire for the pre-session AND each primary terminal")
    }
}
}

// MARK: - Helpers

/// Thread-safe collector for TmuxManager dryRun recorded args.
private final class RecordedCommands: @unchecked Sendable {
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

/// Thread-safe collector for broadcast StateDeltas.
private final class CollectedDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}
