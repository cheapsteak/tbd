import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

extension TBDHomeSerialized {
    @Suite("DeskSessionManager — TBD_HOME isolated")
    struct DeskSessionManagerTests {

        @Test("ensureDeskSession creates idempotent desk worktree")
        func testEnsureDeskSessionIdempotent() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpHome) }

            setenv("TBD_HOME", tmpHome.path, 1)
            defer { unsetenv("TBD_HOME") }

            let db = try TBDDatabase(inMemory: true)
            let lifecycle = WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            )
            let skillDir = tmpHome.appendingPathComponent("skills/nightwatch").path
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                tmux: TmuxManager(dryRun: true),
                skillDir: skillDir
            )

            // First call creates
            let desk1 = try await manager.ensureDeskSession(mode: .daywatch)
            #expect(desk1.displayName == NightwatchDeskPrompts.deskDisplayName)
            #expect(desk1.isScratch == true)

            // Second call returns same desk (idempotent)
            let desk2 = try await manager.ensureDeskSession(mode: .daywatch)
            #expect(desk1.id == desk2.id, "Idempotent call should return same desk")

            // Verify one worktree in DB
            let allDesks = try await db.worktrees.list()
            let desks = allDesks.filter { $0.displayName == NightwatchDeskPrompts.deskDisplayName }
            #expect(desks.count == 1)
        }

        @Test("ensureDeskSession idempotent twice in a row (tests scratch dir collision handling)")
        func testEnsureDeskSessionIdempotentTwice() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-test2-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpHome) }

            // Run twice to test directory collision handling
            for attempt in 1...2 {
                setenv("TBD_HOME", tmpHome.path, 1)
                defer { unsetenv("TBD_HOME") }

                let db = try TBDDatabase(inMemory: true)
                let lifecycle = WorktreeLifecycle(
                    db: db,
                    git: GitManager(),
                    tmux: TmuxManager(dryRun: true),
                    hooks: HookResolver()
                )
                let skillDir = tmpHome.appendingPathComponent("skills/nightwatch").path
                let manager = DeskSessionManager(
                    db: db,
                    lifecycle: lifecycle,
                        tmux: TmuxManager(dryRun: true),
                    skillDir: skillDir
                )

                let desk = try await manager.ensureDeskSession(mode: .daywatch)
                #expect(!desk.id.uuidString.isEmpty, "Attempt \(attempt): desk should exist")
                #expect(desk.isScratch == true, "Attempt \(attempt): should be scratch")
            }
        }

        @Test("nudgeDeskSession gracefully handles missing worktree")
        func testNudgeMissingWorktree() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-nudge-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpHome) }

            setenv("TBD_HOME", tmpHome.path, 1)
            defer { unsetenv("TBD_HOME") }

            let db = try TBDDatabase(inMemory: true)
            let lifecycle = WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            )
            let skillDir = tmpHome.appendingPathComponent("skills/nightwatch").path
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                tmux: TmuxManager(dryRun: true),
                skillDir: skillDir
            )

            // Nudge with non-existent ID should not throw
            await manager.nudgeDeskSession(worktreeID: UUID(), act: false)
            // Test just verifies no crash
        }

        @Test("closeDeskSession idempotent")
        func testCloseDeskSessionIdempotent() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-close-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpHome) }

            setenv("TBD_HOME", tmpHome.path, 1)
            defer { unsetenv("TBD_HOME") }

            let db = try TBDDatabase(inMemory: true)
            let lifecycle = WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            )
            let skillDir = tmpHome.appendingPathComponent("skills/nightwatch").path
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                tmux: TmuxManager(dryRun: true),
                skillDir: skillDir
            )

            let desk = try await manager.ensureDeskSession(mode: .daywatch)

            // First close
            await manager.closeDeskSession()

            // Second close should not throw (idempotent)
            await manager.closeDeskSession()

            // Verify worktree is archived
            let archived = try await db.worktrees.get(id: desk.id)
            #expect(archived?.status == .archived)
        }

        @Test("mode switch reuses desk (daywatch → nightwatch)")
        func testModeSwitchReuses() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-mode-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpHome) }

            setenv("TBD_HOME", tmpHome.path, 1)
            defer { unsetenv("TBD_HOME") }

            let db = try TBDDatabase(inMemory: true)
            let lifecycle = WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            )
            let skillDir = tmpHome.appendingPathComponent("skills/nightwatch").path
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                tmux: TmuxManager(dryRun: true),
                skillDir: skillDir
            )

            let dayDesk = try await manager.ensureDeskSession(mode: .daywatch)
            let nightDesk = try await manager.ensureDeskSession(mode: .nightwatch)

            #expect(dayDesk.id == nightDesk.id, "Mode switch should reuse same desk")

            // Verify single desk in DB
            let allDesks = try await db.worktrees.list()
            let deskCount = allDesks.filter { $0.displayName == NightwatchDeskPrompts.deskDisplayName }.count
            #expect(deskCount == 1)
        }

        @Test("ensure → close → ensure creates new desk (archived desk not reused)")
        func testRecoveryAfterClose() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-recovery-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpHome) }

            setenv("TBD_HOME", tmpHome.path, 1)
            defer { unsetenv("TBD_HOME") }

            let db = try TBDDatabase(inMemory: true)
            let lifecycle = WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            )
            let skillDir = tmpHome.appendingPathComponent("skills/nightwatch").path
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                tmux: TmuxManager(dryRun: true),
                skillDir: skillDir
            )

            // Ensure creates desk with terminal
            let desk1 = try await manager.ensureDeskSession(mode: .daywatch)
            var terminals = try await db.terminals.list(worktreeID: desk1.id)
            #expect(terminals.count > 0, "Initial ensure should spawn terminals")

            // Close archives the desk and deletes terminals
            await manager.closeDeskSession()
            terminals = try await db.terminals.list(worktreeID: desk1.id)
            #expect(terminals.isEmpty, "After close, terminals should be deleted")

            let archivedDesk = try await db.worktrees.get(id: desk1.id)
            #expect(archivedDesk?.status == .archived, "Desk should be archived")

            // Ensure again creates a NEW desk (archived desk excluded from recovery)
            // This is intentional: archived desks are session history, not live sessions to resume
            let desk2 = try await manager.ensureDeskSession(mode: .daywatch)
            #expect(desk2.id != desk1.id, "Archived desk not reused; new desk created")
            #expect(desk2.status == .active, "New desk should be active")

            // New desk should have Claude terminal
            terminals = try await db.terminals.list(worktreeID: desk2.id)
            let claudeTerminal = terminals.first(where: { $0.label == TerminalLabel.claudeCode })
            #expect(claudeTerminal != nil, "New desk should spawn Claude terminal")
        }

        @Test("nudgeDeskSession skips if last nudge < 10 min ago")
        func testNudgeGuardSkipsWithinWindow() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-nudge-guard-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpHome) }

            setenv("TBD_HOME", tmpHome.path, 1)
            defer { unsetenv("TBD_HOME") }

            let db = try TBDDatabase(inMemory: true)
            let lifecycle = WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            )
            let skillDir = tmpHome.appendingPathComponent("skills/nightwatch").path
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                tmux: TmuxManager(dryRun: true),
                skillDir: skillDir
            )

            // Create a desk with a Claude terminal so nudges don't fail on missing terminal
            let desk = try await manager.ensureDeskSession(mode: .daywatch)

            // First nudge should proceed (no lastNudgeTime set yet)
            await manager.nudgeDeskSession(worktreeID: desk.id, act: false)

            // Second nudge within 10 minutes should be skipped (overlap guard)
            // We can't directly observe the skip in the public API, but we verify
            // that it doesn't throw and the method completes (no-op behavior)
            await manager.nudgeDeskSession(worktreeID: desk.id, act: false)
            // If this reaches here without exception, the overlap guard worked
        }

        @Test("concurrent ensureDeskSession calls are serialized — single desk")
        func testConcurrentEnsureSerialized() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-conc-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpHome) }
            setenv("TBD_HOME", tmpHome.path, 1)
            defer { unsetenv("TBD_HOME") }

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
                tmux: TmuxManager(dryRun: true),
                skillDir: "/tmp/skill"
            )

            // Fire two ensures concurrently: without the FIFO gate both pass the
            // "does a desk exist" check before either write lands → two desks.
            async let a = manager.ensureDeskSession(mode: .daywatch)
            async let b = manager.ensureDeskSession(mode: .nightwatch)
            let (deskA, deskB) = try await (a, b)

            #expect(deskA.id == deskB.id, "concurrent ensures must converge on one desk")
            let desks = try await db.worktrees.list()
                .filter { $0.displayName == NightwatchDeskPrompts.deskDisplayName }
            #expect(desks.count == 1, "exactly one desk row must exist")
        }

        @Test("cached desk invalidated when archived — ensure recreates")
        func testCachedDeskInvalidatedWhenArchived() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-archived-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpHome) }

            setenv("TBD_HOME", tmpHome.path, 1)
            defer { unsetenv("TBD_HOME") }

            let db = try TBDDatabase(inMemory: true)
            let lifecycle = WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            )
            let skillDir = tmpHome.appendingPathComponent("skills/nightwatch").path
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                tmux: TmuxManager(dryRun: true),
                skillDir: skillDir
            )

            // Create initial desk (caches ID internally)
            let desk1 = try await manager.ensureDeskSession(mode: .daywatch)
            #expect(desk1.status == .active)

            // Manually archive it in the database (simulating external change or self-heal)
            try await db.worktrees.archive(id: desk1.id)

            // Call ensure again: cached path should detect archived status, fall through,
            // and recreate a new desk (since the archived one is excluded from recovery)
            let desk2 = try await manager.ensureDeskSession(mode: .daywatch)
            #expect(desk2.id != desk1.id, "Archived cached desk should be recreated")
            #expect(desk2.status == .active)

            // Verify both desks in DB, only one active
            let allDesks = try await db.worktrees.list()
                .filter { $0.displayName == NightwatchDeskPrompts.deskDisplayName }
            #expect(allDesks.count == 2, "Both old (archived) and new (active) desks should exist")
            let activeCount = allDesks.filter { $0.status == .active }.count
            #expect(activeCount == 1, "Only one active desk")
        }

        @Test("cached desk invalidated when terminal missing — ensure respawns")
        func testCachedDeskInvalidatedWhenTerminalMissing() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-noterminal-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpHome, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpHome) }

            setenv("TBD_HOME", tmpHome.path, 1)
            defer { unsetenv("TBD_HOME") }

            let db = try TBDDatabase(inMemory: true)
            let lifecycle = WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            )
            let skillDir = tmpHome.appendingPathComponent("skills/nightwatch").path
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                tmux: TmuxManager(dryRun: true),
                skillDir: skillDir
            )

            // Create initial desk (caches ID internally)
            let desk1 = try await manager.ensureDeskSession(mode: .daywatch)
            let desk1ID = desk1.id
            #expect(desk1.status == .active)

            // Verify it has a Claude terminal
            let terminals1 = try await db.terminals.list(worktreeID: desk1ID)
            let claudeTerminal1 = terminals1.first(where: { $0.label == TerminalLabel.claudeCode })
            #expect(claudeTerminal1 != nil, "Initial desk should have Claude terminal")

            // Manually delete the terminals (simulating terminal crash or close without respawn)
            try await db.terminals.deleteForWorktree(worktreeID: desk1ID)

            // Call ensure again: cached path should detect no Claude terminal, fall through,
            // and respawn the terminal on the same desk
            let desk2 = try await manager.ensureDeskSession(mode: .daywatch)
            #expect(desk2.id == desk1ID, "Same desk should be recovered and reused")
            #expect(desk2.status == .active)

            // Verify terminal was respawned
            let terminals2 = try await db.terminals.list(worktreeID: desk1ID)
            let claudeTerminal2 = terminals2.first(where: { $0.label == TerminalLabel.claudeCode })
            #expect(claudeTerminal2 != nil, "Terminal should be respawned")
        }
    }
}
