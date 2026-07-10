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
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                modelProfileResolver: nil,
                tmux: TmuxManager(dryRun: true)
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
                let manager = DeskSessionManager(
                    db: db,
                    lifecycle: lifecycle,
                    modelProfileResolver: nil,
                    tmux: TmuxManager(dryRun: true)
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
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                modelProfileResolver: nil,
                tmux: TmuxManager(dryRun: true)
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
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                modelProfileResolver: nil,
                tmux: TmuxManager(dryRun: true)
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
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                modelProfileResolver: nil,
                tmux: TmuxManager(dryRun: true)
            )

            let dayDesk = try await manager.ensureDeskSession(mode: .daywatch)
            let nightDesk = try await manager.ensureDeskSession(mode: .nightwatch)

            #expect(dayDesk.id == nightDesk.id, "Mode switch should reuse same desk")

            // Verify single desk in DB
            let allDesks = try await db.worktrees.list()
            let deskCount = allDesks.filter { $0.displayName == NightwatchDeskPrompts.deskDisplayName }.count
            #expect(deskCount == 1)
        }
    }
}
