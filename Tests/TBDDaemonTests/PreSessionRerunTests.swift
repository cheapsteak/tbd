import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: these tests mutate the process-global
// `TBD_HOME` env var via isolateTBDHome() (shared with PreSessionHookTests,
// see PreSessionTestSupport.swift). See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite("Pre-session re-run")
struct PreSessionRerunTests {

    @Test("re-run spawns a hook tab without touching status or agents")
    func rerunIsIsolated() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (db, repoDir, worktree, _) = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: repoDir, script: "#!/bin/sh\nexit 0\n")

        let agent = UUID()
        _ = try await db.terminals.create(
            id: agent, worktreeID: worktree.id,
            tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, kind: .claude
        )
        try await db.worktrees.setTabOrder(worktreeID: worktree.id, tabIDs: [agent])
        try await db.worktrees.setActiveTabID(worktreeID: worktree.id, tabID: agent)

        let lifecycle = makeLifecycle(db: db, timeout: 2)
        try await lifecycle.rerunPreSessionHook(worktreeID: worktree.id)

        let refreshed = try #require(try await db.worktrees.get(id: worktree.id))
        #expect(refreshed.status == .active)          // never flips to .creating
        // `Worktree` has no `activeTabID` property — read it via the store.
        #expect(try await db.worktrees.getActiveTabID(worktreeID: worktree.id) == agent)  // focus untouched
        #expect(try await db.terminals.get(id: agent) != nil)  // agent survives

        let terminals = try await db.terminals.list(worktreeID: worktree.id)
        #expect(terminals.contains { $0.label == TerminalLabel.preSession })
        // Exactly one primary agent terminal — the re-run must not spawn more.
        #expect(terminals.filter { $0.kind == .claude }.count == 1)
    }

    @Test("re-run with no hook configured throws noHookConfigured")
    func rerunWithoutHookThrows() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (db, repoDir, worktree, _) = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        let lifecycle = makeLifecycle(db: db, timeout: 2)

        await #expect(throws: RerunPreSessionError.noHookConfigured) {
            try await lifecycle.rerunPreSessionHook(worktreeID: worktree.id)
        }
    }

    @Test("a second re-run while one is in flight throws alreadyRunning")
    func concurrentRerunRejected() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (db, repoDir, worktree, _) = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        // dryRun tmux never actually runs the hook, so no marker ever appears
        // and the first run's detached wait stays in flight for the full
        // `timeout: 2` — that IS the in-flight window this test needs. No
        // marker write, no sleep script required.
        try await installPreSessionHook(repoDir: repoDir, script: "#!/bin/sh\nexit 0\n")

        let lifecycle = makeLifecycle(db: db, timeout: 2)
        try await lifecycle.rerunPreSessionHook(worktreeID: worktree.id)

        await #expect(throws: RerunPreSessionError.alreadyRunning) {
            try await lifecycle.rerunPreSessionHook(worktreeID: worktree.id)
        }
    }

    @Test("re-run on a .creating worktree throws worktreeBusy")
    func rerunDuringCreateRejected() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (db, repoDir, worktree, _) = try await makeWorktreeFixture(status: .creating)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: repoDir, script: "#!/bin/sh\nexit 0\n")
        let lifecycle = makeLifecycle(db: db, timeout: 2)

        await #expect(throws: RerunPreSessionError.worktreeBusy) {
            try await lifecycle.rerunPreSessionHook(worktreeID: worktree.id)
        }
    }

    @Test("an unknown worktree throws worktreeNotFound")
    func rerunUnknownWorktree() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (db, repoDir, _, _) = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        let lifecycle = makeLifecycle(db: db, timeout: 2)
        let ghost = UUID()

        await #expect(throws: RerunPreSessionError.worktreeNotFound(ghost)) {
            try await lifecycle.rerunPreSessionHook(worktreeID: ghost)
        }
    }

    @Test("RPC handler forwards params.cols/rows to the spawned window's resize-window")
    func rpcForwardsColsAndRows() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (db, repoDir, worktree, _) = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        try await installPreSessionHook(repoDir: repoDir, script: "#!/bin/sh\nexit 0\n")

        let recorder = PreSessionRecordedCommands()
        let lifecycle = makeLifecycle(db: db, recorder: recorder, timeout: 2)
        let router = RPCRouter(db: db, lifecycle: lifecycle, tmux: TmuxManager(dryRun: true))
        let params = try JSONEncoder().encode(
            WorktreeRerunPreSessionParams(worktreeID: worktree.id, cols: 180, rows: 45)
        )

        let response = try await router.handleWorktreeRerunPreSession(params)
        #expect(response.error == nil)

        // createWindow's dry-run records the new-window shape (tmux new-window
        // itself has no -x/-y), then issues an explicit resize-window to lock
        // in the requested size — see TmuxManager.createWindow. That
        // resize-window command is where cols/rows become observable, and
        // going through the RPCRouter (not the lifecycle directly) is what
        // proves handleWorktreeRerunPreSession actually forwards
        // params.cols/params.rows instead of dropping them.
        let resize = try #require(
            recorder.snapshot().first { $0.contains("resize-window") }
        )
        #expect(resize.contains("-x"))
        #expect(resize.contains("180"))
        #expect(resize.contains("-y"))
        #expect(resize.contains("45"))
    }

    @Test("RPC surfaces the rejection message verbatim")
    func rpcReportsAlreadyRunning() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (db, repoDir, worktree, _) = try await makeWorktreeFixture(status: .active)
        defer { try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent()) }
        // dryRun tmux never actually runs the hook, so no marker ever appears
        // and the first run's detached wait stays in flight for the full
        // `timeout: 2` — that IS the in-flight window this test needs.
        try await installPreSessionHook(repoDir: repoDir, script: "#!/bin/sh\nexit 0\n")

        let lifecycle = makeLifecycle(db: db, timeout: 2)
        let router = RPCRouter(db: db, lifecycle: lifecycle, tmux: TmuxManager(dryRun: true))
        let params = try JSONEncoder().encode(
            WorktreeRerunPreSessionParams(worktreeID: worktree.id)
        )

        let first = try await router.handleWorktreeRerunPreSession(params)
        #expect(first.error == nil)

        let second = try await router.handleWorktreeRerunPreSession(params)
        #expect(second.error == "Setup hook is already running for this worktree.")
    }
}
}
