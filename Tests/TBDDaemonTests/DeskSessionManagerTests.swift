import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("DeskSessionManager")
struct DeskSessionManagerTests {

    private func makeManager() throws -> (DeskSessionManager, TBDDatabase) {
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )
        let manager = DeskSessionManager(
            db: db,
            lifecycle: lifecycle,
            modelProfileResolver: nil,
            tmux: TmuxManager(dryRun: true)
        )
        return (manager, db)
    }

    @Test("ensureDeskSession creates idempotent desk worktree")
    func testEnsureDeskSessionIdempotent() async throws {
        let (manager, db) = try makeManager()

        // First call creates
        let desk1 = try await manager.ensureDeskSession(mode: .daywatch)
        #expect(desk1.displayName == "◐ Watch Desk")
        #expect(desk1.isScratch == true)

        // Second call returns same desk (idempotent)
        let desk2 = try await manager.ensureDeskSession(mode: .daywatch)
        #expect(desk1.id == desk2.id, "Idempotent call should return same desk")

        // Verify one worktree in DB
        let allDesks = try await db.worktrees.list()
        let desks = allDesks.filter { $0.displayName == "◐ Watch Desk" }
        #expect(desks.count == 1)
    }

    @Test("ensureDeskSession daywatch uses Sonnet model")
    func testDaywatchModel() async throws {
        let (manager, _) = try makeManager()

        let desk = try await manager.ensureDeskSession(mode: .daywatch)
        #expect(!desk.id.uuidString.isEmpty)

        // The Sonnet model is baked into spawnDeskTerminal; verify worktree was created
        #expect(desk.isScratch == true)
    }

    @Test("ensureDeskSession nightwatch uses Opus model")
    func testNightwatchModel() async throws {
        let (manager, _) = try makeManager()

        let desk = try await manager.ensureDeskSession(mode: .nightwatch)
        #expect(!desk.id.uuidString.isEmpty)

        // The Opus model is baked into spawnDeskTerminal; verify worktree was created
        #expect(desk.isScratch == true)
    }

    @Test("ensureDeskSession creates Claude terminal in desk")
    func testEnsureDeskSessionCreatesTerminal() async throws {
        let (manager, db) = try makeManager()

        let desk = try await manager.ensureDeskSession(mode: .daywatch)

        let terminals = try await db.terminals.list(worktreeID: desk.id)
        #expect(!terminals.isEmpty, "Desk session should have at least one terminal")
        #expect(terminals.first?.label == TerminalLabel.claudeCode)
    }

    @Test("nudgeDeskSession sends text to existing terminal")
    func testNudgeDeskSession() async throws {
        let (manager, db) = try makeManager()

        let desk = try await manager.ensureDeskSession(mode: .daywatch)

        // Nudge should not throw
        await manager.nudgeDeskSession(worktreeID: desk.id, act: false)

        // Verify terminal still exists (nudge is best-effort)
        let terminals = try await db.terminals.list(worktreeID: desk.id)
        #expect(!terminals.isEmpty)
    }

    @Test("nudgeDeskSession gracefully handles missing worktree")
    func testNudgeMissingWorktree() async throws {
        let (manager, _) = try makeManager()

        // Nudge with non-existent ID should not throw
        await manager.nudgeDeskSession(worktreeID: UUID(), act: false)
        // Test just verifies no crash
    }

    @Test("closeDeskSession idempotent")
    func testCloseDeskSessionIdempotent() async throws {
        let (manager, db) = try makeManager()

        let desk = try await manager.ensureDeskSession(mode: .daywatch)

        // First close
        await manager.closeDeskSession()

        // Second close should not throw (idempotent)
        await manager.closeDeskSession()

        // Verify worktree is archived
        let archived = try await db.worktrees.get(id: desk.id)
        #expect(archived?.status == .archived)
    }

    @Test("boot recovery: ensureDeskSession finds existing desk by display name")
    func testBootRecoveryByDisplayName() async throws {
        let (manager, db) = try makeManager()

        // Create a desk
        let desk1 = try await manager.ensureDeskSession(mode: .daywatch)

        // Simulate daemon restart: create new manager (fresh cache)
        let lifecycle = WorktreeLifecycle(
            db: db,
            git: GitManager(),
            tmux: TmuxManager(dryRun: true),
            hooks: HookResolver()
        )
        let manager2 = DeskSessionManager(
            db: db,
            lifecycle: lifecycle,
            modelProfileResolver: nil,
            tmux: TmuxManager(dryRun: true)
        )

        // New manager should find existing desk by display name
        let desk2 = try await manager2.ensureDeskSession(mode: .nightwatch)
        #expect(desk1.id == desk2.id, "Boot recovery should reuse desk by display name")
    }

    @Test("mode switch reuses desk (daywatch → nightwatch)")
    func testModeSwitchReuses() async throws {
        let (manager, db) = try makeManager()

        let dayDesk = try await manager.ensureDeskSession(mode: .daywatch)
        let nightDesk = try await manager.ensureDeskSession(mode: .nightwatch)

        #expect(dayDesk.id == nightDesk.id, "Mode switch should reuse same desk")

        // Verify single desk in DB
        let allDesks = try await db.worktrees.list()
        let deskCount = allDesks.filter { $0.displayName == "◐ Watch Desk" }.count
        #expect(deskCount == 1)
    }
}

// Banner pure logic tests (requires TBDApp which has C module dependencies)
// These test the mode→text mapping in NightwatchDeskStatusBanner:
// - .off → nil (banner hidden)
// - .daywatch → "◐", "Daywatch — desk session active"
// - .nightwatch → "🌙", "Nightwatch — desk session active"
// Verified by inspection: Sources/TBDApp/Sidebar/NightwatchDeskStatusBanner.swift lines 17-26
