import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// Records the argv TmuxManager *would* have run in dry-run mode, so a test can assert
/// which pane a nudge actually targeted rather than merely that it didn't throw.
private final class DeskTmuxRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []

    func record(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(args)
    }

    /// Target panes of every `paste-buffer` call, in order. `pasteBufferCommand` renders
    /// `["-L", server, "paste-buffer", "-d", "-p", "-b", buffer, "-t", paneID]`.
    var pastedPanes: [String] {
        lock.lock(); defer { lock.unlock() }
        return _calls.compactMap { args in
            guard args.contains("paste-buffer"), let t = args.lastIndex(of: "-t"),
                  args.index(after: t) < args.endIndex else { return nil }
            return args[args.index(after: t)]
        }
    }
}

/// Mutable set of tmux windows that `windowExists` should report as gone. Mutable rather
/// than a fixed closure because one test has to *revive* a desk mid-flight to prove a
/// failed nudge didn't start the overlap cooldown.
private final class DeadWindows: @unchecked Sendable {
    private let lock = NSLock()
    private var dead: Set<String> = []

    func markDead(_ windowID: String) {
        lock.lock(); defer { lock.unlock() }
        dead.insert(windowID)
    }

    func isDead(_ windowID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return dead.contains(windowID)
    }
}

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

        /// The ~5 KB judge instructions must land on disk, not in the session.
        ///
        /// Asserted on the file's *content*, not just its existence: the failure
        /// this guards against is a pointer to a file that is empty, stale, or
        /// written for the other mode — all of which leave the desk pointed at
        /// something, which is exactly as bad as pointing at nothing while looking
        /// healthier.
        @Test("nudgeDeskSession writes mode-correct judge instructions into the desk")
        func testNudgeWritesInstructionsFile() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-instr-\(UUID().uuidString)", isDirectory: true)
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

            let desk = try await manager.ensureDeskSession(mode: .nightwatch)
            let instructions = URL(fileURLWithPath: desk.path)
                .appendingPathComponent(NightwatchDeskPrompts.judgeInstructionsFileName)

            // Written at spawn, before any tick fires.
            #expect(FileManager.default.fileExists(atPath: instructions.path),
                    "desk spawn did not lay down \(NightwatchDeskPrompts.judgeInstructionsFileName)")

            await manager.nudgeDeskSession(worktreeID: desk.id, act: true)

            let written = try String(contentsOf: instructions, encoding: .utf8)
            #expect(written == NightwatchDeskPrompts.judgePrompt(mode: .nightwatch, skillDir: skillDir),
                    "instructions file does not match the nightwatch judge prompt the pointer promises")
            #expect(written.contains("you MAY run `gh pr merge"),
                    "act=true wrote the daywatch body; the judge would be told it may not merge")
        }

        /// The overlap guard previously had no observable — the old test could only
        /// assert "doesn't throw", which passes just as well if the guard is gone.
        /// The instructions write gives it one: a skipped nudge should touch
        /// nothing, so a deleted file stays deleted.
        @Test("a nudge skipped by the overlap guard does no work at all")
        func testSkippedNudgeWritesNothing() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-skip-\(UUID().uuidString)", isDirectory: true)
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
            let instructions = URL(fileURLWithPath: desk.path)
                .appendingPathComponent(NightwatchDeskPrompts.judgeInstructionsFileName)

            await manager.nudgeDeskSession(worktreeID: desk.id, act: false)
            #expect(FileManager.default.fileExists(atPath: instructions.path))

            try FileManager.default.removeItem(at: instructions)

            // Second nudge inside the 10-minute window: guarded, so it must not
            // reach the write.
            await manager.nudgeDeskSession(worktreeID: desk.id, act: false)
            #expect(!FileManager.default.fileExists(atPath: instructions.path),
                    "the overlap guard let a second nudge through inside its window")
        }

        /// The finding that rejected PR #551's first head: the desk is reused
        /// across a daywatch ↔ nightwatch flip without respawning, while the judge
        /// is told to read `JUDGE-INSTRUCTIONS.md` once. Nothing on the judge's
        /// side can observe the file being rewritten underneath it, so the daemon
        /// has to track which mode it last nudged with and say when that changes.
        ///
        /// Every previous test here nudged exactly once, which is why the gap
        /// survived: a single-tick test cannot see a transition by construction.
        /// The injected clock is what makes a second tick reachable past the
        /// 10-minute overlap guard.
        @Test("a mode flip between ticks is tracked, and only the flip is a change")
        func testModeFlipBetweenTicksIsTracked() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-flip-\(UUID().uuidString)", isDirectory: true)
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

            // Walk the clock forward past the overlap guard between ticks.
            let clock = TestDateSource(Date(timeIntervalSince1970: 1_000_000))
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                tmux: TmuxManager(dryRun: true),
                skillDir: skillDir,
                now: clock.provider
            )

            let desk = try await manager.ensureDeskSession(mode: .daywatch)
            let instructions = URL(fileURLWithPath: desk.path)
                .appendingPathComponent(NightwatchDeskPrompts.judgeInstructionsFileName)

            // Nothing nudged yet: a judge that has read nothing must read.
            #expect(await manager.lastNudgedMode == nil)

            await manager.nudgeDeskSession(worktreeID: desk.id, act: false)
            #expect(await manager.lastNudgedMode == .daywatch)
            var body = try String(contentsOf: instructions, encoding: .utf8)
            #expect(!body.contains("you MAY run `gh pr merge"),
                    "daywatch tick wrote an authorization daywatch does not grant")

            // Same mode, a tick later: steady state, nothing changed.
            clock.advance(by: 11 * 60)
            await manager.nudgeDeskSession(worktreeID: desk.id, act: false)
            #expect(await manager.lastNudgedMode == .daywatch)

            // The flip. The body on disk must now grant the merge, and the manager
            // must know the judge's memorized copy predates it.
            clock.advance(by: 11 * 60)
            await manager.nudgeDeskSession(worktreeID: desk.id, act: true)
            #expect(await manager.lastNudgedMode == .nightwatch,
                    "manager did not record the flip; the next tick would claim nothing changed")
            body = try String(contentsOf: instructions, encoding: .utf8)
            #expect(body.contains("you MAY run `gh pr merge"),
                    "nightwatch tick left the daywatch body on disk")
        }

        /// A nudge that never reached the session must not count as "the judge has
        /// seen this mode" — otherwise the next tick reports no change across a
        /// flip the judge never learned about. Exercised via the overlap guard,
        /// which is the reachable way to make a nudge return without pasting.
        @Test("a skipped nudge does not advance the recorded mode")
        func testSkippedNudgeDoesNotRecordMode() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-skipmode-\(UUID().uuidString)", isDirectory: true)
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
            let clock = TestDateSource(Date(timeIntervalSince1970: 2_000_000))
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                tmux: TmuxManager(dryRun: true),
                skillDir: skillDir,
                now: clock.provider
            )

            let desk = try await manager.ensureDeskSession(mode: .daywatch)
            await manager.nudgeDeskSession(worktreeID: desk.id, act: false)
            #expect(await manager.lastNudgedMode == .daywatch)

            // Inside the window: guarded, so the flip never reaches the session.
            await manager.nudgeDeskSession(worktreeID: desk.id, act: true)
            #expect(await manager.lastNudgedMode == .daywatch,
                    "a nudge the guard dropped still recorded its mode; the judge would never be told it changed")
        }

        /// A respawned judge has read nothing, so it must be told to read.
        ///
        /// `lastNudgedMode` is keyed on the mode, not on which session is running
        /// — so a crash-respawn that does NOT change mode leaves it matching, and
        /// the next nudge tells a session that has opened no files "don't
        /// re-read". The mode-flip guard was necessary but not sufficient: it
        /// answered "did the instructions change under the reader" and missed
        /// "did the reader change under the instructions".
        ///
        /// The pre-existing respawn test never nudged afterward, which is why
        /// this was invisible to it.
        @Test("respawning the desk terminal makes the next nudge demand a re-read")
        func testRespawnClearsTheReadMemory() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-respawn-\(UUID().uuidString)", isDirectory: true)
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
            let clock = TestDateSource(Date(timeIntervalSince1970: 3_000_000))
            let manager = DeskSessionManager(
                db: db,
                lifecycle: lifecycle,
                tmux: TmuxManager(dryRun: true),
                skillDir: skillDir,
                now: clock.provider
            )

            let desk = try await manager.ensureDeskSession(mode: .nightwatch)
            await manager.nudgeDeskSession(worktreeID: desk.id, act: true)
            #expect(await manager.lastNudgedMode == .nightwatch)

            // The judge's terminal dies; ensure respawns a fresh session into the
            // same worktree, with the mode unchanged — the exact case where a
            // mode-only guard reports "nothing changed".
            try await db.terminals.deleteForWorktree(worktreeID: desk.id)
            let recovered = try await manager.ensureDeskSession(mode: .nightwatch)
            #expect(recovered.id == desk.id, "expected the same desk to be recovered, not a new one")

            #expect(await manager.lastNudgedMode == nil,
                    "respawned judge would be told 'don't re-read' despite having read nothing")

            // And the dead session's rate-limit window must not silence the new
            // session's first tick: this nudge lands immediately, without the
            // clock having moved past the 10-minute guard.
            await manager.nudgeDeskSession(worktreeID: desk.id, act: true)
            #expect(await manager.lastNudgedMode == .nightwatch,
                    "first nudge to the respawned session was suppressed by the dead session's window")
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

        @Test("postShiftWrapUp sends prompt and fires notification (non-destructive)")
        func testPostShiftWrapUpNonDestructive() async throws {
            let tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-wrapup-\(UUID().uuidString)", isDirectory: true)
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

            // Create a desk
            let desk = try await manager.ensureDeskSession(mode: .daywatch)
            let deskID = desk.id

            // Verify desk is active and has a terminal
            let desks = try await db.worktrees.get(id: deskID)
            #expect(desks?.status == .active, "Desk should be active before wrap-up")
            let terminals = try await db.terminals.list(worktreeID: deskID)
            #expect(terminals.count > 0, "Desk should have terminals before wrap-up")

            // Post shift wrap-up
            await manager.postShiftWrapUp(worktreeID: deskID)

            // Verify desk is STILL active (not archived)
            let deskAfter = try await db.worktrees.get(id: deskID)
            #expect(deskAfter?.status == .active, "Desk should remain active after wrap-up")

            // Verify terminals are STILL there (not deleted)
            let terminalsAfter = try await db.terminals.list(worktreeID: deskID)
            #expect(terminalsAfter.count > 0, "Terminals should remain after wrap-up")

            // Verify a notification was created
            let notifications = try await db.notifications.unread(worktreeID: deskID)
            #expect(notifications.count > 0, "Notification should be created")
            let wrapUpNotif = notifications.first(where: { $0.type == .taskComplete })
            #expect(wrapUpNotif != nil, "Should have a taskComplete notification")
            #expect(wrapUpNotif?.message?.contains("Daywatch ended") ?? false, "Notification message should mention Daywatch")
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

        // MARK: - Live-terminal resolution (stale desk rows)

        /// Temp TBD_HOME + in-memory DB + a DeskSessionManager whose own tmux records argv
        /// and consults a mutable dead-window set. The lifecycle gets a separate dry-run
        /// tmux so desk *creation* never lands in the recorder the assertions read.
        /// Caller owns cleanup of `home` and TBD_HOME.
        private func makeDeskFixture(tag: String) throws -> (
            db: TBDDatabase, manager: DeskSessionManager,
            recorder: DeskTmuxRecorder, dead: DeadWindows, home: URL
        ) {
            let home = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-\(tag)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            setenv("TBD_HOME", home.path, 1)

            let db = try TBDDatabase(inMemory: true)
            let recorder = DeskTmuxRecorder()
            let dead = DeadWindows()
            let manager = DeskSessionManager(
                db: db,
                lifecycle: WorktreeLifecycle(
                    db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()
                ),
                tmux: TmuxManager(
                    dryRun: true,
                    dryRunRecorder: { recorder.record($0) },
                    dryRunWindowIsDead: { dead.isDead($0) }
                ),
                skillDir: home.appendingPathComponent("skills/nightwatch").path
            )
            return (db, manager, recorder, dead, home)
        }

        /// The regression: `TerminalStore.list` orders createdAt ASC, so resolving the desk
        /// terminal with `first(where:)` always picked the OLDEST row. Judge handoffs kill
        /// the predecessor's window out-of-band and leave its row behind, so the oldest row
        /// is the likeliest corpse — in production three rows accumulated and every nudge
        /// for hours was pasted at a pane that no longer existed.
        @Test("nudgeDeskSession targets the newest Claude terminal, not the oldest")
        func testNudgeTargetsNewestClaudeTerminal() async throws {
            let f = try makeDeskFixture(tag: "nudge-newest")
            defer { unsetenv("TBD_HOME"); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let oldest = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            // A later Claude row on the same desk — the live session after a handoff.
            let newest = try await f.db.terminals.create(
                worktreeID: desk.id, tmuxWindowID: "@9", tmuxPaneID: "%9",
                label: TerminalLabel.claudeCode)

            // Asserted, not assumed: if the clock ever ties these two, the recency
            // assertion below proves nothing, so fail where the cause is legible.
            #expect(newest.createdAt > oldest.createdAt, "fixture must yield distinct createdAt")

            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: false)

            let targets = Array(f.recorder.pastedPanes.dropFirst(before))
            #expect(targets == ["%9"], "nudge must reach the newest Claude terminal, got \(targets)")
        }

        /// Recency alone is not enough. tmux recycles pane IDs per server, so a stale row
        /// can start resolving to a live pane owned by an unrelated session, which would
        /// then be handed a judge prompt plus Enter (#384). The window-liveness check is
        /// what makes that unreachable.
        @Test("nudgeDeskSession skips a newer terminal whose tmux window is gone")
        func testNudgeSkipsStaleTerminal() async throws {
            let f = try makeDeskFixture(tag: "nudge-stale")
            defer { unsetenv("TBD_HOME"); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let live = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            // Newer by createdAt, but its window is dead — exactly the orphan a handoff leaves.
            _ = try await f.db.terminals.create(
                worktreeID: desk.id, tmuxWindowID: "@dead", tmuxPaneID: "%dead",
                label: TerminalLabel.claudeCode)
            f.dead.markDead("@dead")

            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: false)

            let targets = Array(f.recorder.pastedPanes.dropFirst(before))
            #expect(targets == [live.tmuxPaneID], "must fall through to the live row, got \(targets)")
            #expect(!targets.contains("%dead"), "a dead window must never be pasted into")
        }

        /// A nudge that reached nothing must not start the 10-minute overlap cooldown, or a
        /// single dead desk would suppress the very retry that recovers it — which is how a
        /// transient gap becomes a silent all-night outage.
        @Test("a nudge with no live terminal sends nothing and does not start the cooldown")
        func testFailedNudgeDoesNotStartCooldown() async throws {
            let f = try makeDeskFixture(tag: "nudge-cooldown")
            defer { unsetenv("TBD_HOME"); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let original = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))
            f.dead.markDead(original.tmuxWindowID)

            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)
            #expect(
                Array(f.recorder.pastedPanes.dropFirst(before)).isEmpty,
                "no live terminal means nothing should be pasted anywhere")

            // Desk comes back; the next nudge must fire immediately.
            _ = try await f.db.terminals.create(
                worktreeID: desk.id, tmuxWindowID: "@revived", tmuxPaneID: "%7",
                label: TerminalLabel.claudeCode)
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)

            #expect(
                Array(f.recorder.pastedPanes.dropFirst(before)) == ["%7"],
                "the failed attempt must not have armed the overlap guard")
        }

        /// `postShiftWrapUp` resolved its target the same broken way, and failed the same
        /// way in production ("Failed to post shift wrap-up: TmuxError error 0").
        @Test("postShiftWrapUp targets the newest live terminal")
        func testWrapUpTargetsNewestLiveTerminal() async throws {
            let f = try makeDeskFixture(tag: "wrapup-live")
            defer { unsetenv("TBD_HOME"); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let original = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))
            f.dead.markDead(original.tmuxWindowID)

            _ = try await f.db.terminals.create(
                worktreeID: desk.id, tmuxWindowID: "@live", tmuxPaneID: "%5",
                label: TerminalLabel.claudeCode)

            let before = f.recorder.pastedPanes.count
            await f.manager.postShiftWrapUp(worktreeID: desk.id)

            #expect(
                Array(f.recorder.pastedPanes.dropFirst(before)) == ["%5"],
                "wrap-up must reach the live terminal, not the dead original")

            let notifications = try await f.db.notifications.unread(worktreeID: desk.id)
            #expect(
                notifications.contains(where: { $0.type == .taskComplete }),
                "wrap-up should still fire its completion notification")
        }
    }
}
