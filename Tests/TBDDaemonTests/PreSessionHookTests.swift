import Foundation
import GRDB
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
        // Setup window carries the full documented hook env even with no
        // preSession hook present.
        let setupBody = windowCalls[1].last ?? ""
        #expect(setupBody.contains("export TBD_EVENT='setup'"))
        #expect(setupBody.contains("export TBD_WORKTREE_NAME='\(wt.name)'"))
        #expect(setupBody.contains("export TBD_WORKTREE_PATH='\(wt.path)'"))
        #expect(setupBody.contains("export TBD_REPO_PATH='\(repo.path)'"))
        #expect(setupBody.contains("export TBD_BRANCH='\(wt.branch)'"))

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
        // Full documented hook env present on the window (exported in the
        // command body) — docs/worktree-hooks.md promises all of these.
        let createdWtRow = try await db.worktrees.get(id: pending.id)
        let createdWt = try #require(createdWtRow)
        #expect(body.contains("export TBD_EVENT='preSession'"))
        #expect(body.contains("export TBD_WORKTREE_ID='\(createdWt.id.uuidString)'"))
        #expect(body.contains("export TBD_WORKTREE_NAME='\(createdWt.name)'"))
        #expect(body.contains("export TBD_WORKTREE_PATH='\(createdWt.path)'"))
        #expect(body.contains("export TBD_REPO_PATH='\(repo.path)'"))
        #expect(body.contains("export TBD_BRANCH='\(createdWt.branch)'"))

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

        // The parallel `setup` hook window gets the same documented env
        // (TBD_EVENT=setup) — windows are [pre-session, claude, setup].
        let allWindowCalls = recorder.snapshot().filter { $0.contains("new-window") }
        #expect(allWindowCalls.count == 3)
        let setupBody = allWindowCalls[2].last ?? ""
        #expect(setupBody.contains("export TBD_EVENT='setup'"))
        #expect(setupBody.contains("export TBD_TERMINAL_ID='\(setup.id.uuidString)'"))
        #expect(setupBody.contains("export TBD_WORKTREE_NAME='\(createdWt.name)'"))
        #expect(setupBody.contains("export TBD_WORKTREE_PATH='\(createdWt.path)'"))
        #expect(setupBody.contains("export TBD_REPO_PATH='\(repo.path)'"))
        #expect(setupBody.contains("export TBD_BRANCH='\(createdWt.branch)'"))
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
        // No marker may remain after a timeout outcome.
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: pending.id)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
    }

    // MARK: - Wait outcome races (marker vs. dead pane / deadline)

    @Test func markerWinsWhenPaneDiesInSameIteration() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)

        // The dead-window check fires AFTER the marker check in each poll
        // iteration. Simulate the race deterministically: the windowExists
        // probe itself writes the marker (hook finished + pane closed between
        // the two checks) and reports the window dead. The wait must re-check
        // the marker and honor its exit code instead of returning .paneKilled.
        let worktreeID = UUID()
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: worktreeID)
        let lifecycle = makeLifecycle(db: db, windowIsDead: { _ in
            try? FileManager.default.createDirectory(
                atPath: (markerPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try? "0\n".write(toFile: markerPath, atomically: true, encoding: .utf8)
            return true
        })
        let spawn = PreSessionSpawn(
            terminalID: UUID(), windowID: "@mock-0", paneID: "%mock-0",
            markerPath: markerPath, hookPath: "/dev/null"
        )
        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: spawn, tmuxServer: "tbd-test"
        )
        #expect(outcome == .completed(exitCode: 0),
                "a marker written in the same iteration must beat .paneKilled")
        #expect(!FileManager.default.fileExists(atPath: markerPath))
    }

    @Test func markerPresentAtDeadlineBeatsTimeout() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)

        // Deadline already expired (timeout 0) but the marker exists — the
        // hook finished during the final poll sleep. The wait must consume
        // the marker (no leak) and report .completed, not .timedOut.
        let worktreeID = UUID()
        try writeMarker(worktreeID: worktreeID, exitCode: 0)
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: worktreeID)
        let lifecycle = makeLifecycle(db: db, timeout: 0)
        let spawn = PreSessionSpawn(
            terminalID: UUID(), windowID: "@mock-0", paneID: "%mock-0",
            markerPath: markerPath, hookPath: "/dev/null"
        )
        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: spawn, tmuxServer: "tbd-test"
        )
        #expect(outcome == .completed(exitCode: 0),
                "a marker present at the deadline must beat .timedOut")
        #expect(!FileManager.default.fileExists(atPath: markerPath))
    }

    @Test func deadPaneWithoutMarkerIsPaneKilled() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)

        let worktreeID = UUID()
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: worktreeID)
        let lifecycle = makeLifecycle(db: db, windowIsDead: { _ in true })
        let spawn = PreSessionSpawn(
            terminalID: UUID(), windowID: "@mock-0", paneID: "%mock-0",
            markerPath: markerPath, hookPath: "/dev/null"
        )
        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: spawn, tmuxServer: "tbd-test"
        )
        #expect(outcome == .paneKilled)
    }

    // MARK: - Killed pane (end-to-end)

    @Test func paneKilledStillSpawnsAndNotifies() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        // Every window reports dead and no marker is ever written → the wait
        // short-circuits to .paneKilled (user closed the hook terminal).
        let lifecycle = makeLifecycle(db: db, windowIsDead: { _ in true })
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)
        let completion = try await lifecycle.completeCreateWorktree(worktreeID: pending.id)
        guard case .preSessionPending(let phase3) = completion else {
            Issue.record("expected .preSessionPending")
            return
        }
        await phase3.value

        // Killed pane must still spawn the primary terminals and activate.
        let terminals = try await db.terminals.list(worktreeID: pending.id)
        #expect(terminals.count == 3, "killed pane must still spawn primary terminals")
        #expect(try await db.worktrees.get(id: pending.id)?.status == .active)

        let notifications = try await db.notifications.unread(worktreeID: pending.id)
        #expect(notifications.count == 1)
        #expect(notifications.first?.type == .error)
        #expect(notifications.first?.message?.contains("closed") == true)
        // No marker may remain after a paneKilled outcome.
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: pending.id)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
    }

    // MARK: - Worktree row deleted mid-wait (repo remove)

    @Test func rowDeletedMidWaitSkipsPrimarySpawnAndCleansUp() async throws {
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
            Issue.record("expected .preSessionPending")
            return
        }

        // Repo removal mid-wait: deleteForRepo drops the .creating row (the
        // terminal rows cascade). Phase 3 must notice and never spawn the
        // primary terminals into the void.
        try await db.worktrees.deleteForRepo(repoID: repo.id)
        try writeMarker(worktreeID: pending.id, exitCode: 0)
        await phase3.value

        #expect(try await db.worktrees.get(id: pending.id) == nil)
        #expect(try await db.terminals.list(worktreeID: pending.id).isEmpty,
                "no terminal rows may be created for a deleted worktree")
        let windowCalls = recorder.snapshot().filter { $0.contains("new-window") }
        #expect(windowCalls.count == 1,
                "only the pre-session window may exist — no primary windows after the row vanished")
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: pending.id)
        #expect(!FileManager.default.fileExists(atPath: markerPath),
                "the marker removed right after the wait must not reappear on the deleted-row early exit")
    }

    @Test func dbErrorDuringRowCheckDoesNotTearDownPreSessionWindow() async throws {
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
            Issue.record("expected .preSessionPending")
            return
        }
        let terminalsBefore = try await db.terminals.list(worktreeID: pending.id)
        let preTerminal = try #require(terminalsBefore.first)

        // Close the underlying GRDB connection mid-wait so the phase-3 row
        // existence check THROWS instead of returning nil. A thrown DB error
        // is not proof the row is gone — phase 3 must take the spawn path,
        // not the deleted-row teardown that kills the live pre-session
        // window of a perfectly valid worktree. (The spawn attempt itself
        // then fails on the closed DB and is logged/swallowed — what matters
        // here is which branch the guard took.)
        try db.writerForTests.close()
        try writeMarker(worktreeID: pending.id, exitCode: 0)
        await phase3.value

        let kills = recorder.snapshot().filter { $0.contains("kill-window") }
        #expect(!kills.contains { $0.contains(preTerminal.tmuxWindowID) },
                "a transient DB error on the existence check must not kill the pre-session window")
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: pending.id)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
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

    @Test func legacyReviveWithHookAwaitsPhase3Inline() async throws {
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

        // Legacy synchronous contract: fully set up on return (the inline
        // await rides the short timeout since dryRun tmux never runs the hook).
        let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)
        #expect(revived.status == .active)
        let terminals = try await db.terminals.list(worktreeID: revived.id)
        #expect(terminals.count == 3)
        #expect(terminals.contains { $0.label == "pre-session" })
    }

    /// Creates a worktree gated on the preSession hook, completes the hook via
    /// marker, and archives it — leaving an `.archived` row ready to revive.
    private func makeArchivedWorktree(
        lifecycle: WorktreeLifecycle, db: TBDDatabase, repo: Repo
    ) async throws -> Worktree {
        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id, skipClaude: true)
        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id, skipClaude: true
        )
        if case .preSessionPending(let phase3) = completion {
            try writeMarker(worktreeID: pending.id, exitCode: 0)
            await phase3.value
        }
        try await lifecycle.archiveWorktree(worktreeID: pending.id, force: true)
        let archived = try await db.worktrees.get(id: pending.id)
        return try #require(archived)
    }

    @Test func reviveWithHookReturnsPendingAndGatesPrimaries() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)
        let wt = try await makeArchivedWorktree(lifecycle: lifecycle, db: db, repo: repo)
        // Sessions stored on the archived row; skipClaude revive must keep them.
        try await db.worktrees.setArchivedClaudeSessions(id: wt.id, sessions: ["aaaa-session"])

        let completion = try await lifecycle.beginReviveWorktree(
            worktreeID: wt.id, skipClaude: true
        )
        guard case .preSessionPending(let pendingWt, let phase3) = completion else {
            Issue.record("expected .preSessionPending when a preSession hook resolves")
            return
        }
        // RPC-visible state: returned promptly, row gating the app UI on .creating.
        #expect(pendingWt.status == .creating)
        var terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 1)
        #expect(terminals.first?.label == "pre-session")

        // Hook finishes → primaries spawn, revive semantics applied.
        try writeMarker(worktreeID: wt.id, exitCode: 0)
        await phase3.value

        let revived = try await db.worktrees.get(id: wt.id)
        #expect(revived?.status == .active)
        #expect(revived?.archivedAt == nil, "revive must clear archivedAt")
        #expect(revived?.archivedClaudeSessions == ["aaaa-session"],
                "skipClaude revive must preserve archived sessions for a later revive")
        terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 3)
        #expect(terminals.contains { $0.label == "pre-session" })
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: wt.id)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
    }

    @Test func reviveWithHookRestoresAndClearsSessions() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)
        let wt = try await makeArchivedWorktree(lifecycle: lifecycle, db: db, repo: repo)
        let sessionID = UUID().uuidString
        try await db.worktrees.setArchivedClaudeSessions(id: wt.id, sessions: [sessionID])

        let completion = try await lifecycle.beginReviveWorktree(
            worktreeID: wt.id, skipClaude: false
        )
        guard case .preSessionPending(let pendingWt, let phase3) = completion else {
            Issue.record("expected .preSessionPending")
            return
        }
        #expect(pendingWt.status == .creating)
        try writeMarker(worktreeID: wt.id, exitCode: 0)
        await phase3.value

        let revived = try await db.worktrees.get(id: wt.id)
        #expect(revived?.status == .active)
        #expect(revived?.archivedClaudeSessions == nil,
                "restoring Claude must clear the archived session list")
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        let claude = terminals.first { $0.label == "Claude Code" }
        #expect(claude?.claudeSessionID == sessionID,
                "primary Claude terminal must resume the archived session")
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

    // MARK: - Startup recovery of `.creating` rows

    @Test func recoveryResumesOrphanedPreSessionWait() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // Simulate a daemon that died mid-pre-session-wait: a .creating row
        // whose checkout exists on disk and whose only terminal is the
        // pre-session one (the tmux window + hook survive daemon restarts).
        let checkout = tempDir.appendingPathComponent("orphan-checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "orphan", branch: "tbd/orphan",
            path: checkout.path, tmuxServer: "tbd-test", status: .creating
        )
        _ = try await db.terminals.create(
            id: UUID(), worktreeID: wt.id,
            tmuxWindowID: "@mock-99", tmuxPaneID: "%mock-99",
            label: "pre-session", kind: .shell
        )

        let resumed = await lifecycle.recoverCreatingWorktrees()
        #expect(resumed.count == 1, "the stranded wait must be resumed")
        // Row must still be .creating while the resumed wait runs.
        #expect(try await db.worktrees.get(id: wt.id)?.status == .creating)

        // Hook finishes → primaries spawn and the row activates.
        try writeMarker(worktreeID: wt.id, exitCode: 0)
        for task in resumed { await task.value }

        // Mid-CREATE branch: no archived sessions, so recovery uses
        // `.markActive` — plain status flip, no archive fields involved.
        let after = try await db.worktrees.get(id: wt.id)
        #expect(after?.status == .active)
        #expect(after?.archivedAt == nil)
        #expect(after?.archivedClaudeSessions == nil)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 3,
                "resumed phase 3 must spawn the primary terminals")
        #expect(terminals.contains { $0.label == "Claude Code" })
        #expect(terminals.contains { $0.label == "setup" })
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: wt.id)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
    }

    @Test func recoveryMidReviveRestoresAndClearsArchivedSessions() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // Simulate a daemon that died mid-REVIVE-wait: beginReviveWorktree
        // re-added the checkout, spawned the pre-session terminal, and flipped
        // the row .archived → .creating — but its archive fields (archivedAt,
        // archivedClaudeSessions) are only cleared in phase 3, so they're
        // still set when the daemon dies.
        let sessionID = UUID().uuidString
        let checkout = tempDir.appendingPathComponent("revive-orphan")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "revorph", branch: "tbd/revorph",
            path: checkout.path, tmuxServer: "tbd-test"
        )
        try await db.worktrees.archive(id: wt.id, claudeSessionIDs: [sessionID])
        try await db.worktrees.updateStatus(id: wt.id, status: .creating)
        _ = try await db.terminals.create(
            id: UUID(), worktreeID: wt.id,
            tmuxWindowID: "@mock-rev", tmuxPaneID: "%mock-rev",
            label: "pre-session", kind: .shell
        )

        let resumed = await lifecycle.recoverCreatingWorktrees()
        #expect(resumed.count == 1, "the stranded mid-revive wait must be resumed")

        try writeMarker(worktreeID: wt.id, exitCode: 0)
        for task in resumed { await task.value }

        // Mid-REVIVE branch: recovery must finish with revive semantics —
        // restore the archived session into the primary terminal, clear
        // archivedAt, and clear archivedClaudeSessions so the next archive
        // can't silently orphan the old transcript.
        let after = try await db.worktrees.get(id: wt.id)
        #expect(after?.status == .active)
        #expect(after?.archivedAt == nil, "revive semantics must clear archivedAt")
        #expect(after?.archivedClaudeSessions == nil,
                "restored sessions must be cleared, not left to be overwritten on the next archive")
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        let claude = terminals.first { $0.label == "Claude Code" }
        #expect(claude?.claudeSessionID == sessionID,
                "the primary Claude terminal must resume the archived transcript, not start fresh")
    }

    // MARK: - Reconcile must not kill live `.creating` windows

    @Test func reconcileSparesCreatingWorktreePreSessionWindow() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let recorder = RecordedCommands()
        // The tmux server reports the active agent window, the .creating
        // worktree's pre-session window, and one genuinely orphaned window.
        let lifecycle = makeLifecycle(db: db, recorder: recorder, listWindows: { _, _ in
            [
                (windowID: "@mock-agent", paneID: "%mock-agent"),
                (windowID: "@mock-pre", paneID: "%mock-pre"),
                (windowID: "@mock-orphan", paneID: "%mock-orphan"),
            ]
        })
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let server = TmuxManager.serverName(forRepoPath: repo.path)

        // Active worktree at the main checkout path so `git worktree list`
        // reports it and reconcile doesn't archive it as missing.
        let active = try await db.worktrees.create(
            repoID: repo.id, name: "main-wt", branch: "main",
            path: repoDir.path, tmuxServer: server
        )
        _ = try await db.terminals.create(
            id: UUID(), worktreeID: active.id,
            tmuxWindowID: "@mock-agent", tmuxPaneID: "%mock-agent",
            label: "Claude Code", kind: .claude
        )
        // A .creating worktree mid-pre-session-hook (e.g. a running npm
        // install) — its window must survive the orphan cleanup pass.
        let creating = try await db.worktrees.create(
            repoID: repo.id, name: "hooked", branch: "tbd/hooked",
            path: tempDir.appendingPathComponent("hooked").path,
            tmuxServer: server, status: .creating
        )
        let preTerminal = try await db.terminals.create(
            id: UUID(), worktreeID: creating.id,
            tmuxWindowID: "@mock-pre", tmuxPaneID: "%mock-pre",
            label: "pre-session", kind: .shell
        )

        try await lifecycle.reconcile(repoID: repo.id)

        let kills = recorder.snapshot().filter { $0.contains("kill-window") }
        #expect(!kills.contains { $0.contains("@mock-pre") },
                "reconcile must not kill a .creating worktree's live pre-session window")
        #expect(!kills.contains { $0.contains("@mock-agent") },
                "tracked active windows must survive")
        #expect(kills.contains { $0.contains("@mock-orphan") },
                "genuinely untracked windows must still be cleaned up")
        #expect(!recorder.snapshot().contains { $0.contains("kill-server") })
        // The .creating row and its terminal are untouched.
        #expect(try await db.worktrees.get(id: creating.id)?.status == .creating)
        #expect(try await db.terminals.get(id: preTerminal.id) != nil)
    }

    @Test func reconcileKeepsServerWhenOnlyLiveRowIsCreating() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let recorder = RecordedCommands()
        let lifecycle = makeLifecycle(db: db, recorder: recorder, listWindows: { _, _ in
            [(windowID: "@mock-pre", paneID: "%mock-pre")]
        })
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let server = TmuxManager.serverName(forRepoPath: repo.path)

        // The repo's ONLY live row is .creating — the kill-server branch must
        // not fire (it would take the running hook's window down with it).
        let creating = try await db.worktrees.create(
            repoID: repo.id, name: "solo-hooked", branch: "tbd/solo-hooked",
            path: tempDir.appendingPathComponent("solo-hooked").path,
            tmuxServer: server, status: .creating
        )
        _ = try await db.terminals.create(
            id: UUID(), worktreeID: creating.id,
            tmuxWindowID: "@mock-pre", tmuxPaneID: "%mock-pre",
            label: "pre-session", kind: .shell
        )

        try await lifecycle.reconcile(repoID: repo.id)

        #expect(!recorder.snapshot().contains { $0.contains("kill-server") },
                "a repo whose only live worktree is .creating must keep its tmux server")
        #expect(!recorder.snapshot().contains { $0.contains("kill-window") && $0.contains("@mock-pre") },
                "the pre-session window must not be treated as an orphan")
    }

    @Test func recoveryThenReconcileLeavesResumedWaitIntact() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let recorder = RecordedCommands()
        let lifecycle = makeLifecycle(db: db, recorder: recorder, listWindows: { _, _ in
            [(windowID: "@mock-pre", paneID: "%mock-pre")]
        })
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let server = TmuxManager.serverName(forRepoPath: repo.path)

        // Daemon restarted mid-pre-session-wait: .creating row, checkout on
        // disk, only the pre-session terminal.
        let checkout = tempDir.appendingPathComponent("restart-survivor")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "survivor", branch: "tbd/survivor",
            path: checkout.path, tmuxServer: server, status: .creating
        )
        _ = try await db.terminals.create(
            id: UUID(), worktreeID: wt.id,
            tmuxWindowID: "@mock-pre", tmuxPaneID: "%mock-pre",
            label: "pre-session", kind: .shell
        )

        // Startup sequence: recovery sweep first, then per-repo reconcile —
        // exactly what Daemon.start() runs.
        let resumed = await lifecycle.recoverCreatingWorktrees()
        #expect(resumed.count == 1)
        try await lifecycle.reconcile(repoID: repo.id)

        #expect(!recorder.snapshot().contains { $0.contains("kill-window") && $0.contains("@mock-pre") },
                "the just-resumed pre-session window must survive the startup reconcile")
        #expect(!recorder.snapshot().contains { $0.contains("kill-server") })
        #expect(try await db.worktrees.get(id: wt.id)?.status == .creating,
                "the resumed wait must still be in flight after reconcile")

        // The hook finishes after reconcile — the resumed wait completes.
        try writeMarker(worktreeID: wt.id, exitCode: 0)
        for task in resumed { await task.value }

        #expect(try await db.worktrees.get(id: wt.id)?.status == .active)
        #expect(try await db.terminals.list(worktreeID: wt.id).count == 3)
        #expect(try await db.notifications.unread(worktreeID: wt.id).isEmpty,
                "no spurious paneKilled notification may be recorded")
    }

    @Test func recoveryDeletesCreatingRowWithoutCheckout() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // Creation never completed: no checkout on disk.
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "ghost", branch: "tbd/ghost",
            path: tempDir.appendingPathComponent("never-created").path,
            tmuxServer: "tbd-test", status: .creating
        )
        _ = try await db.terminals.create(
            id: UUID(), worktreeID: wt.id,
            tmuxWindowID: "@mock-98", tmuxPaneID: "%mock-98",
            label: "pre-session", kind: .shell
        )

        let resumed = await lifecycle.recoverCreatingWorktrees()
        #expect(resumed.isEmpty)
        #expect(try await db.worktrees.get(id: wt.id) == nil,
                "a .creating row without a checkout must be deleted")
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
    }

    @Test func recoveryActivatesCreatingRowWithPrimaries() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // Daemon died between the primary spawn and the final status flip:
        // checkout + pre-session + primary terminals all exist.
        let checkout = tempDir.appendingPathComponent("almost-done")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "almost", branch: "tbd/almost",
            path: checkout.path, tmuxServer: "tbd-test", status: .creating
        )
        for (label, kind) in [("pre-session", TerminalKind.shell),
                              ("Claude Code", .claude), ("setup", .shell)] {
            _ = try await db.terminals.create(
                id: UUID(), worktreeID: wt.id,
                tmuxWindowID: "@mock-\(label)", tmuxPaneID: "%mock-\(label)",
                label: label, kind: kind
            )
        }

        let resumed = await lifecycle.recoverCreatingWorktrees()
        #expect(resumed.isEmpty, "nothing to wait for — only the status flip was lost")
        #expect(try await db.worktrees.get(id: wt.id)?.status == .active)
        #expect(try await db.terminals.list(worktreeID: wt.id).count == 3,
                "existing terminals must be left untouched")
    }

    @Test func recoveryDeletesCreatingRowWithNoTerminals() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // Daemon died after `git worktree add` but before any tmux spawn:
        // checkout exists, zero terminals. Reconcile re-adopts the checkout.
        let checkout = tempDir.appendingPathComponent("bare-checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "bare", branch: "tbd/bare",
            path: checkout.path, tmuxServer: "tbd-test", status: .creating
        )
        // A stray tab row (user-set label) must be cleaned up alongside the row.
        try await db.tabs.setLabel(tabID: UUID(), worktreeID: wt.id, label: "stray")

        let resumed = await lifecycle.recoverCreatingWorktrees()
        #expect(resumed.isEmpty)
        #expect(try await db.worktrees.get(id: wt.id) == nil,
                "a terminal-less .creating row must be deleted for reconcile to re-adopt")
        #expect(try await db.tabs.listForWorktree(worktreeID: wt.id).isEmpty,
                "tab rows must be deleted with the worktree row")
    }

    @Test func recoveryDeletesCreatingRowWhoseRepoVanished() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // A .creating row with a checkout on disk and a pre-session terminal,
        // so recovery reaches the repo lookup (past the checkout-missing and
        // no-terminals guards). Then orphan it: the repoID FK would either
        // reject a made-up repoID or cascade-delete the worktree on
        // `repos.remove`, so delete the repo row with foreign keys off —
        // simulating a DB left inconsistent by an older daemon.
        let checkout = tempDir.appendingPathComponent("repo-less")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "repoless", branch: "tbd/repoless",
            path: checkout.path, tmuxServer: "tbd-test", status: .creating
        )
        _ = try await db.terminals.create(
            id: UUID(), worktreeID: wt.id,
            tmuxWindowID: "@mock-97", tmuxPaneID: "%mock-97",
            label: "pre-session", kind: .shell
        )
        try await db.writerForTests.writeWithoutTransaction { sqlDB in
            try sqlDB.execute(sql: "PRAGMA foreign_keys = OFF")
            try sqlDB.execute(sql: "DELETE FROM repo WHERE id = ?", arguments: [repo.id.uuidString])
            try sqlDB.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let resumed = await lifecycle.recoverCreatingWorktrees()
        #expect(resumed.isEmpty, "a repo-less .creating row cannot be resumed")
        #expect(try await db.worktrees.get(id: wt.id) == nil,
                "the stranded row must be deleted, not skipped forever")
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty,
                "its terminal rows must be deleted with it")
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
