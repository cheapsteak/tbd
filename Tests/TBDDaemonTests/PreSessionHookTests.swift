import Foundation
import GRDB
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel

// Nested under TBDHomeSerialized: these tests mutate the process-global
// `TBD_HOME` env var to isolate the hooks/default and runtime/presession
// directories from the developer's real ~/tbd. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite("Pre-session hook")
struct PreSessionHookTests {

    // MARK: - Helpers
    //
    // isolateTBDHome / installHook / installPreSessionHook / makeLifecycle /
    // makeWorktreeFixture / writeMarker / PreSessionRecordedCommands live in
    // PreSessionTestSupport.swift, shared with PreSessionRerunTests.

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

    @Test func noHookSpawnsOnlyThePrimary() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let holder = FakeHolderLaunch()
        let lifecycle = makeLifecycle(db: db, holder: holder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
        #expect(wt.status == .active)

        // No preSession hook and no setup hook: the primary agent is the only
        // tab. A setup tab is opened only for a setup hook that resolves.
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 1)
        #expect(!terminals.contains { $0.label == "pre-session" })
        #expect(!terminals.contains { $0.label == "setup" })
        let claude = try #require(terminals.first { $0.label == "Claude Code" })

        let launches = holder.launches
        #expect(launches.count == 1)
        let claudeLaunch = try #require(holder.launch(for: claude.id))
        #expect(claudeLaunch.commandLine?.contains("claude --session-id") == true,
                "the only spawn must be the primary agent")
        // A spawned agent command must never block on oh-my-zsh's interactive
        // update prompt, so the suppression is in the job's process env.
        #expect(claudeLaunch.request.environment["DISABLE_AUTO_UPDATE"] == "true",
                "primary agent must suppress the oh-my-zsh update prompt in its process env")

        // Tab order [claude], active = claude; the create makes no note and
        // opens no worktree panel.
        #expect(try await db.notes.list(worktreeID: wt.id).isEmpty)
        #expect(try await db.worktrees.getTabOrder(worktreeID: wt.id) == [claude.id])
        #expect(try await db.panelSurface.worktreePanels(worktreeID: wt.id).isEmpty)
        #expect(try await db.worktrees.getActiveTabID(worktreeID: wt.id) == claude.id)
        #expect(try await db.notifications.unread(worktreeID: wt.id).isEmpty)
    }

    @Test func setupHookWindowSuppressesOmzUpdatePrompt() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        // Auto-close off: this pins the plain setup command, and leaves no
        // 600 s marker watcher running after the test.
        try await db.config.setAutoCloseSetup(enabled: false)
        let holder = FakeHolderLaunch()
        let lifecycle = makeLifecycle(db: db, holder: holder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installHook(named: "setup", repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
        #expect(wt.status == .active)

        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 2)
        #expect(!terminals.contains { $0.label == "pre-session" })
        let claude = try #require(terminals.first { $0.label == "Claude Code" })
        let setup = try #require(terminals.first { $0.label == "setup" })

        // Spawns: [claude, setup]. With a setup hook resolved, the setup job's
        // process environment carries DISABLE_AUTO_UPDATE=true (set before
        // .zshrc runs) so the omz updater prompt can't delay the hook; the
        // primary agent carries it too — a spawned agent command must never
        // block on the interactive update prompt.
        let launchedIDs = holder.launches.map { $0.terminalID }
        #expect(launchedIDs == [claude.id, setup.id],
                "the primary agent must spawn first and the setup hook second")
        let claudeLaunch = try #require(holder.launch(for: claude.id))
        let setupLaunch = try #require(holder.launch(for: setup.id))
        #expect(claudeLaunch.request.environment["DISABLE_AUTO_UPDATE"] == "true",
                "primary agent must suppress the oh-my-zsh update prompt in its process env")
        #expect(setupLaunch.request.environment["DISABLE_AUTO_UPDATE"] == "true",
                "setup hook must suppress the oh-my-zsh update prompt in its process env")
        // The setup tab runs the hook and carries the full documented hook env
        // even with no preSession hook present.
        let setupBody = setupLaunch.commandLine ?? ""
        #expect(setupBody.contains(".worktree-hooks/setup"),
                "the second spawn must run the setup hook")
        #expect(setupBody.contains("export TBD_EVENT='setup'"))
        #expect(setupBody.contains("export TBD_TERMINAL_ID='\(setup.id.uuidString)'"))
        #expect(setupBody.contains("export TBD_WORKTREE_NAME='\(wt.name)'"))
        #expect(setupBody.contains("export TBD_WORKTREE_PATH='\(wt.localPath)'"))
        #expect(setupBody.contains("export TBD_REPO_PATH='\(repo.path)'"))
        #expect(setupBody.contains("export TBD_BRANCH='\(wt.branch)'"))

        // Tab order [claude, setup], active = claude.
        #expect(try await db.worktrees.getTabOrder(worktreeID: wt.id) == [claude.id, setup.id])
        #expect(try await db.worktrees.getActiveTabID(worktreeID: wt.id) == claude.id)
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
            repoID: repo.id, folder: "second", branch: "feat/clash"
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
        // Auto-close off: the setup hook below then runs the plain command, and
        // no 600 s setup marker watcher is left running after the test.
        try await db.config.setAutoCloseSetup(enabled: false)
        let holder = FakeHolderLaunch()
        let lifecycle = makeLifecycle(db: db, holder: holder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)
        try await installHook(named: "setup", repoDir: repoDir)

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
        #expect(pre.transport == .holder)
        #expect(try await db.worktrees.get(id: pending.id)?.status == .creating)
        #expect(try await db.worktrees.getTabOrder(worktreeID: pending.id) == [pre.id])
        #expect(try await db.worktrees.getActiveTabID(worktreeID: pending.id) == pre.id)

        // The single spawn so far runs the wrapped hook command.
        #expect(holder.launches.count == 1)
        let preLaunch = try #require(holder.launch(for: pre.id))
        let body = preLaunch.commandLine ?? ""
        #expect(body.contains(".worktree-hooks/preSession"))
        #expect(body.contains("runtime/presession"))
        // Full documented hook env present on the spawn (exported in the
        // command line) — docs/worktree-hooks.md promises all of these.
        let createdWtRow = try await db.worktrees.get(id: pending.id)
        let createdWt = try #require(createdWtRow)
        #expect(body.contains("export TBD_EVENT='preSession'"))
        #expect(body.contains("export TBD_WORKTREE_ID='\(createdWt.id.uuidString)'"))
        #expect(body.contains("export TBD_WORKTREE_NAME='\(createdWt.name)'"))
        #expect(body.contains("export TBD_WORKTREE_PATH='\(createdWt.localPath)'"))
        #expect(body.contains("export TBD_REPO_PATH='\(repo.path)'"))
        #expect(body.contains("export TBD_BRANCH='\(createdWt.branch)'"))
        // The pre-session job's process environment must carry
        // DISABLE_AUTO_UPDATE=true so oh-my-zsh's updater prompt (fired by
        // .zshrc, BEFORE the command and its export prefix run) can't block
        // the hook.
        #expect(preLaunch.request.environment["DISABLE_AUTO_UPDATE"] == "true",
                "pre-session hook must suppress the oh-my-zsh update prompt in its process env")

        // Still gated while the marker is absent.
        try await Task.sleep(nanoseconds: 200_000_000)
        terminals = try await db.terminals.list(worktreeID: pending.id)
        #expect(terminals.count == 1, "primary terminals must not spawn before the marker")

        // Hook "finishes" with exit 0.
        try writeMarker(worktreeID: pending.id, exitCode: 0)
        await phase3.value

        terminals = try await db.terminals.list(worktreeID: pending.id)
        // Exit 0 closes the pre-session tab: only the two primaries remain.
        #expect(terminals.count == 2)
        #expect(try await db.terminals.get(id: pre.id) == nil,
                "a clean hook run must delete its own terminal row")
        let claude = try #require(terminals.first { $0.label == "Claude Code" })
        let setup = try #require(terminals.first { $0.label == "setup" })
        #expect(try await db.notes.list(worktreeID: pending.id).isEmpty)
        #expect(try await db.worktrees.getTabOrder(worktreeID: pending.id)
                == [claude.id, setup.id],
                "tab order must be [claude, setup] once the pre-session tab is closed")
        #expect(try await db.panelSurface.worktreePanels(worktreeID: pending.id).isEmpty,
                "the create opens no worktree panel")
        #expect(try await db.worktrees.getActiveTabID(worktreeID: pending.id) == claude.id)
        #expect(try await db.worktrees.get(id: pending.id)?.status == .active)
        // Exit 0 → no notification.
        #expect(try await db.notifications.unread(worktreeID: pending.id).isEmpty)
        // Marker consumed.
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: pending.id)
        #expect(!FileManager.default.fileExists(atPath: markerPath))

        // The parallel `setup` hook gets the same documented env
        // (TBD_EVENT=setup) — spawns are [pre-session, claude, setup].
        let launchedIDs = holder.launches.map { $0.terminalID }
        #expect(launchedIDs == [pre.id, claude.id, setup.id])
        // Hook tabs and agent tabs suppress the omz updater.
        let claudeLaunch = try #require(holder.launch(for: claude.id))
        let setupLaunch = try #require(holder.launch(for: setup.id))
        #expect(claudeLaunch.request.environment["DISABLE_AUTO_UPDATE"] == "true",
                "primary agent must suppress the oh-my-zsh update prompt in its process env")
        #expect(setupLaunch.request.environment["DISABLE_AUTO_UPDATE"] == "true",
                "setup hook must suppress the oh-my-zsh update prompt in its process env")
        let setupBody = setupLaunch.commandLine ?? ""
        #expect(setupBody.contains("export TBD_EVENT='setup'"))
        #expect(setupBody.contains("export TBD_TERMINAL_ID='\(setup.id.uuidString)'"))
        #expect(setupBody.contains("export TBD_WORKTREE_NAME='\(createdWt.name)'"))
        #expect(setupBody.contains("export TBD_WORKTREE_PATH='\(createdWt.localPath)'"))
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

        // A failed hook keeps its tab beside the primary.
        let terminals = try await db.terminals.list(worktreeID: pending.id)
        #expect(terminals.count == 2, "non-zero exit must still spawn the primary terminal")
        #expect(terminals.contains { $0.label == "Claude Code" })
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
        // Short injected timeout; the marker is never written, and the hook's
        // job reads as still running (`makeLifecycle`'s default liveness), so
        // the timeout path covers the no-completion case here.
        // 0.1 s leaves room for two polls at `makeLifecycle`'s 0.05 s interval,
        // and the outcome is `.timedOut` however many run, since nothing ever
        // writes the marker.
        let lifecycle = makeLifecycle(db: db, timeout: 0.1)
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
        // The timed-out hook keeps its tab beside the primary.
        let terminals = try await db.terminals.list(worktreeID: pending.id)
        #expect(terminals.count == 2)
        #expect(terminals.contains { $0.label == "Claude Code" })

        let notifications = try await db.notifications.unread(worktreeID: pending.id)
        #expect(notifications.count == 1)
        #expect(notifications.first?.type == .error)
        #expect(notifications.first?.message?.contains("timed out") == true)
        // No marker may remain after a timeout outcome.
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: pending.id)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
    }

    // MARK: - Ephemeral hook tab: close on success, keep on failure

    @Test("exit 0 closes the pre-session tab and broadcasts terminalRemoved")
    func successfulHookClosesItsTab() async throws {
        let (_, cleanupHome) = isolateTBDHome()
        defer { cleanupHome() }
        let (db, repoDir, worktree, repo) = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: repoDir)

        let subscriptions = StateSubscriptionManager()
        let lifecycle = makeLifecycle(db: db, subscriptions: subscriptions, timeout: 2)
        let spawn = try #require(try await lifecycle.spawnPreSessionTerminal(
            worktree: worktree, repo: repo, worktreePath: worktree.localPath
        ))
        #expect(spawn.tmuxServer == worktree.tmuxServer)
        // The holder double runs nothing, so the hook never really runs. Stand
        // in for its clean exit. Must come AFTER the spawn, which deletes any stale
        // marker for this worktree ID.
        try writeMarker(worktreeID: worktree.id, exitCode: 0)

        await lifecycle.runPreSessionPhase3(
            preSession: spawn, worktree: worktree, repo: repo,
            worktreePath: worktree.localPath, skipClaude: true,
            completionAction: .markActive
        )

        #expect(try await db.terminals.get(id: spawn.terminalID) == nil)
        let order = try await db.worktrees.getTabOrder(worktreeID: worktree.id)
        #expect(!order.contains(spawn.terminalID))
    }

    @Test("non-zero exit keeps the pre-session tab and records an error notification")
    func failingHookKeepsItsTab() async throws {
        let (_, cleanupHome) = isolateTBDHome()
        defer { cleanupHome() }
        let (db, repoDir, worktree, repo) = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: repoDir)

        let lifecycle = makeLifecycle(db: db, timeout: 2)
        let spawn = try #require(try await lifecycle.spawnPreSessionTerminal(
            worktree: worktree, repo: repo, worktreePath: worktree.localPath
        ))
        try writeMarker(worktreeID: worktree.id, exitCode: 3)

        await lifecycle.runPreSessionPhase3(
            preSession: spawn, worktree: worktree, repo: repo,
            worktreePath: worktree.localPath, skipClaude: true,
            completionAction: .markActive
        )

        #expect(try await db.terminals.get(id: spawn.terminalID) != nil)
        let notifications = try await db.notifications.unread(worktreeID: worktree.id)
        #expect(notifications.contains { $0.type == .error })
    }

    @Test("create path still spawns primaries and marks active on both outcomes",
          arguments: [0, 7])
    func primariesSpawnRegardlessOfOutcome(exitCode: Int) async throws {
        let (_, cleanupHome) = isolateTBDHome()
        defer { cleanupHome() }
        let (db, repoDir, worktree, repo) = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: repoDir)

        let lifecycle = makeLifecycle(db: db, timeout: 2)
        let spawn = try #require(try await lifecycle.spawnPreSessionTerminal(
            worktree: worktree, repo: repo, worktreePath: worktree.localPath
        ))
        try writeMarker(worktreeID: worktree.id, exitCode: exitCode)

        await lifecycle.runPreSessionPhase3(
            preSession: spawn, worktree: worktree, repo: repo,
            worktreePath: worktree.localPath, skipClaude: true,
            completionAction: .markActive
        )

        let refreshed = try #require(try await db.worktrees.get(id: worktree.id))
        #expect(refreshed.status == .active)
        let terminals = try await db.terminals.list(worktreeID: worktree.id)
        // Primaries spawn either way.
        #expect(terminals.contains { $0.label != TerminalLabel.preSession })
        // And the hook tab's survival tracks the exit code exactly.
        #expect((try await db.terminals.get(id: spawn.terminalID) != nil) == (exitCode != 0))
    }

    // MARK: - Reusable spawn (claimsFocus / optional repo)

    @Test("claimsFocus: false appends the tab and leaves activeTabID alone")
    func rerunSpawnDoesNotStealFocus() async throws {
        let (_, cleanupHome) = isolateTBDHome()
        defer { cleanupHome() }
        let (db, repoDir, worktree, repo) = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: repoDir)

        let existing = UUID()
        _ = try await db.terminals.create(
            id: existing, worktreeID: worktree.id,
            tmuxWindowID: "@99", tmuxPaneID: "%99",
            label: TerminalLabel.claudeCode, kind: .claude
        )
        try await db.worktrees.setTabOrder(worktreeID: worktree.id, tabIDs: [existing])
        try await db.worktrees.setActiveTabID(worktreeID: worktree.id, tabID: existing)

        let lifecycle = makeLifecycle(db: db, timeout: 2)
        let spawn = try #require(try await lifecycle.spawnPreSessionTerminal(
            worktree: worktree, repo: repo, worktreePath: worktree.localPath,
            claimsFocus: false
        ))

        let order = try await db.worktrees.getTabOrder(worktreeID: worktree.id)
        #expect(order == [existing, spawn.terminalID])
        #expect(try await db.worktrees.getActiveTabID(worktreeID: worktree.id) == existing)
    }

    @Test("claimsFocus: false broadcasts terminalCreated for the new tab")
    func rerunSpawnBroadcastsTerminalCreated() async throws {
        let (_, cleanupHome) = isolateTBDHome()
        defer { cleanupHome() }
        let (db, repoDir, worktree, repo) = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: repoDir)

        let collected = CollectedDeltas()
        let subscriptions = StateSubscriptionManager()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                collected.append(delta)
            }
            return true
        }
        let lifecycle = makeLifecycle(db: db, subscriptions: subscriptions, timeout: 2)
        let spawn = try #require(try await lifecycle.spawnPreSessionTerminal(
            worktree: worktree, repo: repo, worktreePath: worktree.localPath,
            claimsFocus: false
        ))

        let snapshot = collected.snapshot()
        #expect(snapshot.contains {
            if case .terminalCreated(let d) = $0 {
                return d.terminalID == spawn.terminalID && d.label == TerminalLabel.preSession
            }
            return false
        })
    }

    @Test("claimsFocus: true (default) keeps the original single-tab behavior")
    func defaultClaimsFocusStillClaimsTheTab() async throws {
        let (_, cleanupHome) = isolateTBDHome()
        defer { cleanupHome() }
        let (db, repoDir, worktree, repo) = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: repoDir)

        let lifecycle = makeLifecycle(db: db, timeout: 2)
        let spawn = try #require(try await lifecycle.spawnPreSessionTerminal(
            worktree: worktree, repo: repo, worktreePath: worktree.localPath
        ))

        let order = try await db.worktrees.getTabOrder(worktreeID: worktree.id)
        #expect(order == [spawn.terminalID])
        #expect(try await db.worktrees.getActiveTabID(worktreeID: worktree.id) == spawn.terminalID)
    }

    @Test("repo: nil resolves TBD_REPO_PATH to the worktree path")
    func nilRepoFallsBackToWorktreePath() async throws {
        let (_, cleanupHome) = isolateTBDHome()
        defer { cleanupHome() }
        let (db, repoDir, worktree, _) = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: repoDir)

        let holder = FakeHolderLaunch()
        let lifecycle = makeLifecycle(db: db, timeout: 2, holder: holder)
        let spawn = try #require(try await lifecycle.spawnPreSessionTerminal(
            worktree: worktree, repo: nil, worktreePath: worktree.localPath
        ))
        #expect(try await db.terminals.get(id: spawn.terminalID) != nil)

        let body = holder.launch(for: spawn.terminalID)?.commandLine ?? ""
        #expect(body.contains("export TBD_REPO_PATH='\(worktree.localPath)'"),
                "with no repo, TBD_REPO_PATH must fall back to the worktree's own path")
    }

    // MARK: - Wait outcome races (marker vs. dead hook job / deadline)

    @Test func markerWinsWhenPaneDiesInSameIteration() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }

        // The hook job's liveness probe fires AFTER the marker check in each
        // poll iteration. Simulate the race deterministically: the probe
        // itself writes the marker (hook finished and its job exited between
        // the two checks) and reports the job gone. The wait must re-check the
        // marker and honor its exit code instead of returning .paneKilled.
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: fx.worktree.id)
        let lifecycle = makeLifecycle(
            db: fx.db,
            processSignaller: ScriptedLivenessSignaller(probe: { _ in
                try? FileManager.default.createDirectory(
                    atPath: (markerPath as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try? "0\n".write(toFile: markerPath, atomically: true, encoding: .utf8)
                return false
            }))
        // The probe reads the job's pid only while the hook tab's row exists.
        let terminal = try await fx.db.terminals.create(
            worktreeID: fx.worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.preSession, kind: .shell,
            transport: .holder, holderPID: 1_000_001, childPID: 1_000_002)
        let spawn = PreSessionSpawn(
            terminalID: terminal.id, tmuxServer: fx.worktree.tmuxServer,
            windowID: "", paneID: "",
            markerPath: markerPath, hookPath: "/dev/null",
            transport: .holder, holderPID: 1_000_001, childPID: 1_000_002
        )
        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: spawn, tmuxServer: fx.worktree.tmuxServer
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
            terminalID: UUID(), tmuxServer: "test-server",
            windowID: "@mock-0", paneID: "%mock-0",
            markerPath: markerPath, hookPath: "/dev/null"
        )
        let outcome = await lifecycle.waitForPreSessionCompletion(
            preSession: spawn, tmuxServer: "tbd-test"
        )
        #expect(outcome == .completed(exitCode: 0),
                "a marker present at the deadline must beat .timedOut")
        #expect(!FileManager.default.fileExists(atPath: markerPath))
    }

    // MARK: - Killed pane (end-to-end)

    @Test func paneKilledStillSpawnsAndNotifies() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        // The hook's job reads as gone and no marker is ever written → the wait
        // short-circuits to .paneKilled (user closed the hook terminal).
        let lifecycle = makeLifecycle(
            db: db, processSignaller: ScriptedLivenessSignaller.everyJobGone)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)
        let completion = try await lifecycle.completeCreateWorktree(worktreeID: pending.id)
        guard case .preSessionPending(let phase3) = completion else {
            Issue.record("expected .preSessionPending")
            return
        }
        await phase3.value

        // Killed pane must still spawn the primary terminal and activate; the
        // hook's tab is kept beside it.
        let terminals = try await db.terminals.list(worktreeID: pending.id)
        #expect(terminals.count == 2, "killed pane must still spawn the primary terminal")
        #expect(terminals.contains { $0.label == "Claude Code" })
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
        let fx = try await makeWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fx.repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: fx.repoDir)

        let holder = FakeHolderLaunch()
        let lifecycle = makeLifecycle(db: fx.db, timeout: 2, holder: holder)
        let spawn = try #require(try await lifecycle.spawnPreSessionTerminal(
            worktree: fx.worktree, repo: fx.repo, worktreePath: fx.worktree.localPath
        ))

        // Repo removal mid-wait: deleteForRepo drops the .creating row (the
        // terminal rows cascade), and the hook finishes afterwards. Phase 3 is
        // driven directly so the wait's first poll sees both, in that order.
        // It must notice and never spawn the primary terminals into the void.
        try await fx.db.worktrees.deleteForRepo(repoID: fx.repo.id)
        try writeMarker(worktreeID: fx.worktree.id, exitCode: 0)
        await lifecycle.runPreSessionPhase3(
            preSession: spawn, worktree: fx.worktree, repo: fx.repo,
            worktreePath: fx.worktree.localPath, skipClaude: false,
            completionAction: .markActive
        )

        #expect(try await fx.db.worktrees.get(id: fx.worktree.id) == nil)
        #expect(try await fx.db.terminals.list(worktreeID: fx.worktree.id).isEmpty,
                "no terminal rows may be created for a deleted worktree")
        let launchedIDs = holder.launches.map { $0.terminalID }
        #expect(launchedIDs == [spawn.terminalID],
                "only the pre-session tab may be spawned — no primaries after the row vanished")
        // The hook tab's row went with the worktree, so its holder is reclaimed
        // from the pids the spawn descriptor carries.
        let abandonedIDs = holder.abandonments.map { $0.terminalID }
        #expect(abandonedIDs.contains(spawn.terminalID),
                "the pre-session holder must be reclaimed when its worktree vanished")
        let markerPath = WorktreeLifecycle.preSessionMarkerPath(worktreeID: fx.worktree.id)
        #expect(!FileManager.default.fileExists(atPath: markerPath),
                "the marker removed right after the wait must not reappear on the deleted-row early exit")
    }

    @Test func dbErrorDuringRowCheckDoesNotTearDownPreSessionWindow() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let holder = FakeHolderLaunch()
        let lifecycle = makeLifecycle(db: db, holder: holder)
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
        // not the deleted-row teardown that reclaims the live pre-session
        // holder of a perfectly valid worktree. (The hook tab's own liveness
        // read throws too, and is answered "still there" for the same reason;
        // the spawn attempt itself then fails on the closed DB and is
        // logged/swallowed — what matters here is which branch the guard
        // took.) A non-zero exit keeps the hook "failed", so the separate
        // close-on-success path (which would also reclaim this holder, for an
        // unrelated reason) never fires and can't be confused with the
        // deleted-row teardown this test targets.
        try db.writerForTests.close()
        try writeMarker(worktreeID: pending.id, exitCode: 1)
        await phase3.value

        let abandonedIDs = holder.abandonments.map { $0.terminalID }
        #expect(!abandonedIDs.contains(preTerminal.id),
                "a transient DB error on the existence check must not tear down the pre-session holder")
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
        let lifecycle = makeLifecycle(db: db, timeout: 0.1)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        // The holder double never runs the hook, so phase 3 hits the short
        // timeout; the synchronous method must still return a fully set-up
        // worktree: the primary, beside the timed-out hook's tab.
        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
        #expect(wt.status == .active)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 2)
        #expect(terminals.contains { $0.label == "pre-session" })
        #expect(terminals.contains { $0.label == "Claude Code" })
    }

    @Test func legacyReviveWithHookAwaitsPhase3Inline() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db, timeout: 0.1)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

        // Legacy synchronous contract: fully set up on return (the inline
        // await rides the short timeout since the holder double never runs the
        // hook): the primary, beside the timed-out hook's tab.
        let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)
        #expect(revived.status == .active)
        let terminals = try await db.terminals.list(worktreeID: revived.id)
        #expect(terminals.count == 2)
        #expect(terminals.contains { $0.label == "pre-session" })
    }

    /// Creates a worktree gated on the preSession hook, completes the hook via
    /// marker, and archives it — leaving an `.archived` row ready to revive.
    private func makeArchivedWorktree(
        lifecycle: WorktreeLifecycle, db: TBDDatabase, repo: Repo
    ) async throws -> Worktree {
        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)
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
        // Exit 0 closes the pre-session tab: only the primary remains (no
        // setup hook, so no setup tab).
        #expect(terminals.count == 1)
        #expect(!terminals.contains { $0.label == "pre-session" })
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
        try await db.worktrees.setArchivedAgentTabs(id: wt.id, tabs: [
            ArchivedAgentTab(identity: .init(agentKind: .claude, sessionID: sessionID), ordinal: 0, isPrimary: true)
        ])

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
        #expect(terminalLabels.sorted() == ["Claude Code", "pre-session"],
                "terminalCreated must fire for the pre-session AND the primary terminal")
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
        // Exit 0 closes the resumed pre-session tab: only the primary remains
        // (no setup hook, so no setup tab).
        #expect(terminals.count == 1,
                "resumed phase 3 must spawn the primary terminal")
        #expect(terminals.contains { $0.label == "Claude Code" })
        #expect(!terminals.contains { $0.label == "pre-session" })
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

    // MARK: - A create's Claude values ride the hook's row

    /// A plugin folder and a settings overlay for the create's primary Claude,
    /// with the folder made under `tempDir`, never under `~`.
    private func makeSpawnExtras(tempDir: URL) throws -> (extras: ClaudeSpawnExtras, pluginDir: String) {
        let plug = tempDir.appendingPathComponent("plugins/plug", isDirectory: true)
        try FileManager.default.createDirectory(at: plug, withIntermediateDirectories: true)
        return (
            ClaudeSpawnExtras(claudeSettingsOverlay: #"{"acmeSetting":"on"}"#, pluginDirs: [plug.path]),
            plug.path
        )
    }

    /// The primary Claude row keeps `extras`, its command passes the plugin
    /// folder, and its settings file carries the overlay beside TBD's hooks.
    private func expectPrimaryStarted(
        with extras: ClaudeSpawnExtras, pluginDir: String,
        worktreeID: UUID, db: TBDDatabase, holder: FakeHolderLaunch
    ) async throws {
        let terminals = try await db.terminals.list(worktreeID: worktreeID)
        let primary = try #require(terminals.first { $0.kind == .claude })
        #expect(primary.claudeSpawnExtras == extras)
        #expect(terminals.filter { $0.id != primary.id }.allSatisfy { $0.claudeSpawnExtras == nil })

        let command = try #require(holder.launch(for: primary.id)?.commandLine)
        #expect(command.contains("claude --session-id"), "\(command)")
        #expect(command.contains(" --plugin-dir \(shellEscape(pluginDir))"),
                "\(command)")

        let settingsPath = ClaudeHookOverlay.perSessionOverlayPath(sessionKey: primary.id.uuidString)
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let settings = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(settings["acmeSetting"] as? String == "on")
        #expect(settings["hooks"] != nil)
    }

    @Test func preSessionPhase3PrimaryGetsExtras() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let (extras, pluginDir) = try makeSpawnExtras(tempDir: tempDir)

        let db = try TBDDatabase(inMemory: true)
        let holder = FakeHolderLaunch()
        let lifecycle = makeLifecycle(db: db, holder: holder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)
        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id, claudeSpawnExtras: extras)
        guard case .preSessionPending(let phase3) = completion else {
            Issue.record("expected .preSessionPending when a preSession hook resolves")
            return
        }

        // Until phase 3 starts the primary, the hook's row carries the values.
        let hook = try #require(try await db.terminals.list(worktreeID: pending.id).first)
        #expect(hook.label == TerminalLabel.preSession)
        #expect(hook.claudeSpawnExtras == extras)

        try writeMarker(worktreeID: pending.id, exitCode: 0)
        await phase3.value

        #expect(try await db.worktrees.get(id: pending.id)?.status == .active)
        try await expectPrimaryStarted(
            with: extras, pluginDir: pluginDir, worktreeID: pending.id, db: db, holder: holder)
    }

    /// Recovery after a daemon restart resumes the wait from rows alone and
    /// passes no values to `runPreSessionPhase3`; the primary still gets the
    /// ones stored on the hook's row.
    @Test func recoveredPhase3ReadsPreSessionRowExtras() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let (extras, pluginDir) = try makeSpawnExtras(tempDir: tempDir)

        let db = try TBDDatabase(inMemory: true)
        let holder = FakeHolderLaunch()
        let lifecycle = makeLifecycle(db: db, holder: holder)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // A daemon that died mid-wait: a .creating row whose checkout exists
        // and whose only terminal is the hook's, carrying the create's values.
        let checkout = tempDir.appendingPathComponent("orphan-checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "orphan", branch: "tbd/orphan",
            path: checkout.path, tmuxServer: "tbd-test", status: .creating
        )
        _ = try await db.terminals.create(
            id: UUID(), worktreeID: wt.id,
            tmuxWindowID: "@mock-98", tmuxPaneID: "%mock-98",
            label: TerminalLabel.preSession, kind: .shell,
            claudeSpawnExtras: extras
        )

        let resumed = await lifecycle.recoverCreatingWorktrees()
        #expect(resumed.count == 1, "the stranded wait must be resumed")
        try writeMarker(worktreeID: wt.id, exitCode: 0)
        for task in resumed { await task.value }

        #expect(try await db.worktrees.get(id: wt.id)?.status == .active)
        try await expectPrimaryStarted(
            with: extras, pluginDir: pluginDir, worktreeID: wt.id, db: db, holder: holder)
    }

    // MARK: - Reconcile must not kill live `.creating` windows

    @Test func reconcileSparesCreatingWorktreePreSessionWindow() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let recorder = PreSessionRecordedCommands()
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

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

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
        let recorder = PreSessionRecordedCommands()
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

        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

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
        let recorder = PreSessionRecordedCommands()
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
        try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

        #expect(!recorder.snapshot().contains { $0.contains("kill-window") && $0.contains("@mock-pre") },
                "the just-resumed pre-session window must survive the startup reconcile")
        #expect(!recorder.snapshot().contains { $0.contains("kill-server") })
        #expect(try await db.worktrees.get(id: wt.id)?.status == .creating,
                "the resumed wait must still be in flight after reconcile")

        // The hook finishes after reconcile — the resumed wait completes.
        try writeMarker(worktreeID: wt.id, exitCode: 0)
        for task in resumed { await task.value }

        #expect(try await db.worktrees.get(id: wt.id)?.status == .active)
        // Exit 0 closes the resumed pre-session tab: only the primary remains
        // (no setup hook, so no setup tab).
        #expect(try await db.terminals.list(worktreeID: wt.id).count == 1)
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

    @Test func recoveryActivatesCreatingRowWithNoTerminals() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        // Daemon died after `git worktree add` but before any tmux spawn:
        // a real checkout registered with git, zero terminals. TBD made this
        // tree, so recovery keeps its row and activates it.
        let base = try #require(repo.worktreeRoot)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let checkoutPath = (base as NSString).appendingPathComponent("bare")
        try await shell("git worktree add -b tbd/bare '\(checkoutPath)'", at: repoDir)
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "bare", branch: "tbd/bare",
            path: checkoutPath, tmuxServer: "tbd-test", status: .creating
        )
        // A tab row (user-set label) belongs to the kept row and stays with it.
        try await db.tabs.setLabel(tabID: UUID(), worktreeID: wt.id, label: "kept")

        let resumed = await lifecycle.recoverCreatingWorktrees()
        #expect(resumed.isEmpty)
        let activated = try #require(try await db.worktrees.get(id: wt.id),
                                     "a terminal-less .creating row with a checkout must be kept")
        #expect(activated.status == .active)
        #expect(activated.localPath == checkoutPath)
        #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty)
        #expect(try await db.tabs.listForWorktree(worktreeID: wt.id).count == 1,
                "the kept row's tab records are not touched")

        // The startup sequence continues into reconcile: it must leave exactly
        // this one row on the path, active, with the checkout in place.
        try await lifecycle.reconcile(
            repoID: repo.id, actuationLog: makeTestActuationLog(),
            reapSharedScratchTmuxResources: true)
        let rows = try await db.worktrees.list().filter { $0.localPath == checkoutPath }
        #expect(rows.count == 1)
        #expect(rows.first?.id == wt.id)
        #expect(rows.first?.status == .active)
        #expect(FileManager.default.fileExists(atPath: checkoutPath))
    }

    /// A terminal-less `.creating` row whose path holds a directory git does not
    /// list as a worktree is not a checkout TBD can vouch for: the row is
    /// deleted, not activated, and the directory is not touched.
    @Test(arguments: [false, true])
    func recoveryDeletesTerminalLessRowWhosePathIsAPlainDirectory(pendingRestore: Bool) async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let base = try #require(repo.worktreeRoot)
        let plain = (base as NSString).appendingPathComponent("plain")
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let keep = (plain as NSString).appendingPathComponent("keep.txt")
        try "someone's work".write(toFile: keep, atomically: true, encoding: .utf8)
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "plain", branch: "tbd/plain",
            path: plain, tmuxServer: "tbd-test", status: .creating
        )

        if pendingRestore {
            try await db.worktrees.setArchivedAgentTabs(id: wt.id, tabs: [
                .init(identity: .init(agentKind: .claude, sessionID: "unfinished"), ordinal: 0, isPrimary: true)
            ])
        }
        let resumed = await lifecycle.recoverCreatingWorktrees()
        for task in resumed { await task.value }
        #expect(resumed.isEmpty)
        #expect(try await db.worktrees.get(id: wt.id) == nil,
                "a row whose path git does not list must not be activated")
        #expect(try String(contentsOfFile: keep, encoding: .utf8) == "someone's work",
                "the directory and its files must be untouched")
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

    /// A daemon restart during a remote create must leave a resolvable row.
    /// This sweep and reconcile are the only things that resolve a `.creating`
    /// row, reconcile is fenced from remote rows, and a remote row has no
    /// checkout to inspect — so skipping it here would spin the lane forever.
    /// It gets the terminal state the creation flow already defines instead,
    /// and is not deleted: a vanished row cannot be told apart from a create
    /// that never ran.
    @Test func recoveryMarksARemoteCreatingRowFailed() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let remote = try await db.worktrees.createRemote(
            repoID: repo.id, name: "lane", branch: "tbd/lane",
            provider: "agentbox", sessionID: "s-1", status: .creating)

        let resumed = await lifecycle.recoverCreatingWorktrees()
        #expect(resumed.isEmpty, "a remote row has no pre-session wait to resume")
        let after = try #require(try await db.worktrees.get(id: remote.id))
        #expect(after.status == .failed,
                "a remote .creating row must reach a terminal state, not be skipped forever")
    }
    // The local arms are unchanged and stay covered by the tests above —
    // `recoveryResumesOrphanedPreSessionWait` in particular proves a local
    // `.creating` row still resumes rather than being caught by the new guard.
}
}

// MARK: - Helpers

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
