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

private final class PaneCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String: String] = [:]
    private var defaultCommand: String

    init(defaultCommand: String) {
        self.defaultCommand = defaultCommand
    }

    func set(_ command: String, for paneID: String) {
        lock.lock(); defer { lock.unlock() }
        commands[paneID] = command
    }

    func setDefault(_ command: String) {
        lock.lock(); defer { lock.unlock() }
        defaultCommand = command
    }

    func command(for paneID: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return commands[paneID] ?? defaultCommand
    }
}

/// What each pane answers when asked who it belongs to. Empty by default, so
/// every pane reports `.live(terminalID: nil)` — alive, carrying no identity —
/// which is the branch that proceeds, leaving fixtures that predate the
/// consultation behaving exactly as they did.
private final class PaneIdentities: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: PaneSendTarget] = [:]
    private var unreachable: Set<String> = []

    func set(_ target: PaneSendTarget, for paneID: String) {
        lock.lock(); defer { lock.unlock() }
        answers[paneID] = target
    }

    /// Make the consultation itself fail for a pane — a wedged tmux, not an
    /// answer about the pane.
    func markUnreachable(_ paneID: String) {
        lock.lock(); defer { lock.unlock() }
        unreachable.insert(paneID)
    }

    func answer(for paneID: String) throws -> PaneSendTarget {
        lock.lock(); defer { lock.unlock() }
        if unreachable.contains(paneID) {
            throw TmuxError.timedOut(command: "list-panes", timeout: .seconds(15))
        }
        return answers[paneID] ?? .live(terminalID: nil)
    }
}

private final class SpawnFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false

    func setFailing(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        failing = value
    }

    func error() -> Error? {
        lock.lock(); defer { lock.unlock() }
        return failing
            ? TmuxError.commandFailed(
                command: "new-window",
                status: 1,
                output: "simulated desk spawn failure"
            )
            : nil
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                skillDir: skillDir,
                actuationLog: makeTestActuationLog()
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
                let priorTBDHome = setTBDHome(tmpHome.path)
                defer { restoreTBDHome(priorTBDHome) }

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
                    skillDir: skillDir,
                    actuationLog: makeTestActuationLog()
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                skillDir: skillDir,
                actuationLog: makeTestActuationLog()
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                skillDir: skillDir,
                actuationLog: makeTestActuationLog()
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                skillDir: skillDir,
                actuationLog: makeTestActuationLog()
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                skillDir: skillDir,
                actuationLog: makeTestActuationLog()
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                skillDir: skillDir,
                actuationLog: makeTestActuationLog()
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                skillDir: skillDir,
                actuationLog: makeTestActuationLog()
            )

            let desk = try await manager.ensureDeskSession(mode: .nightwatch)
            let instructions = URL(fileURLWithPath: desk.localPath)
                .appendingPathComponent(NightwatchDeskPrompts.judgeInstructionsFileName)

            // Written at spawn, before any tick fires.
            #expect(FileManager.default.fileExists(atPath: instructions.path),
                    "desk spawn did not lay down \(NightwatchDeskPrompts.judgeInstructionsFileName)")

            await manager.nudgeDeskSession(worktreeID: desk.id, act: true)

            let written = try String(contentsOf: instructions, encoding: .utf8)
            #expect(written.hasPrefix(NightwatchDeskPrompts.judgePrompt(mode: .nightwatch, skillDir: skillDir)),
                    "instructions file does not begin with the nightwatch judge prompt the pointer promises")
            #expect(written.contains("## Exclusive judge lease (mandatory)"))
            #expect(written.contains("tbd nightwatch lease renew"))
            let lease = try #require(
                try await db.watchDeskLeases.status(worktreeID: desk.id))
            #expect(!written.contains(lease.token.uuidString),
                    "shared Watch Desk instructions must never disclose the capability")
            let credentialPaths = WatchDeskLeaseCredentialFile.paths(
                terminalID: lease.terminalID)
            #expect(credentialPaths.count == 1)
            let credentialPath = try #require(credentialPaths.first)
            #expect(FileManager.default.fileExists(atPath: credentialPath))
            #expect(!credentialPath.contains(lease.token.uuidString))
            let attributes = try FileManager.default.attributesOfItem(atPath: credentialPath)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                skillDir: skillDir,
                actuationLog: makeTestActuationLog()
            )

            let desk = try await manager.ensureDeskSession(mode: .daywatch)
            let instructions = URL(fileURLWithPath: desk.localPath)
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                now: clock.provider,
                actuationLog: makeTestActuationLog()
            )

            let desk = try await manager.ensureDeskSession(mode: .daywatch)
            let instructions = URL(fileURLWithPath: desk.localPath)
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                now: clock.provider,
                actuationLog: makeTestActuationLog()
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                now: clock.provider,
                actuationLog: makeTestActuationLog()
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
            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                skillDir: "/tmp/skill",
                actuationLog: makeTestActuationLog()
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                skillDir: skillDir,
                actuationLog: makeTestActuationLog()
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                skillDir: skillDir,
                actuationLog: makeTestActuationLog()
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

            let priorTBDHome = setTBDHome(tmpHome.path)
            defer { restoreTBDHome(priorTBDHome) }

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
                skillDir: skillDir,
                actuationLog: makeTestActuationLog()
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
        /// Caller owns cleanup of `home` and TBD_HOME — hence `priorTBDHome` in
        /// the tuple: restoring means putting the caller's value back, so the
        /// fixture has to hand out what it displaced rather than let the caller
        /// guess (guessing `unsetenv` here is what leaked the real `~/tbd`).
        private func makeDeskFixture(tag: String) throws -> (
            db: TBDDatabase, manager: DeskSessionManager,
            recorder: DeskTmuxRecorder, dead: DeadWindows,
            commands: PaneCommands, identities: PaneIdentities,
            spawnFailures: SpawnFailureSwitch, home: URL,
            priorTBDHome: String?
        ) {
            let home = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tbd-desk-\(tag)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let priorTBDHome = setTBDHome(home.path)

            let db = try TBDDatabase(inMemory: true)
            let recorder = DeskTmuxRecorder()
            let dead = DeadWindows()
            let commands = PaneCommands(defaultCommand: "1.2.3")
            let identities = PaneIdentities()
            let spawnFailures = SpawnFailureSwitch()
            let manager = DeskSessionManager(
                db: db,
                lifecycle: WorktreeLifecycle(
                    db: db,
                    git: GitManager(),
                    tmux: TmuxManager(
                        dryRun: true,
                        dryRunCreateWindowError: { _ in spawnFailures.error() }
                    ),
                    hooks: HookResolver()
                ),
                tmux: TmuxManager(
                    dryRun: true,
                    dryRunRecorder: { recorder.record($0) },
                    dryRunWindowIsDead: { dead.isDead($0) },
                    dryRunPaneCurrentCommand: { _, paneID in commands.command(for: paneID) },
                    dryRunPaneSendTarget: { _, paneID in try identities.answer(for: paneID) }
                ),
                skillDir: home.appendingPathComponent("skills/nightwatch").path,
                actuationLog: makeTestActuationLog()
            )
            return (
                db, manager, recorder, dead, commands, identities, spawnFailures, home,
                priorTBDHome)
        }

        /// The regression: `TerminalStore.list` orders createdAt ASC, so resolving the desk
        /// terminal with `first(where:)` always picked the OLDEST row. Judge handoffs kill
        /// the predecessor's window out-of-band and leave its row behind, so the oldest row
        /// is the likeliest corpse — in production three rows accumulated and every nudge
        /// for hours was pasted at a pane that no longer existed.
        @Test("nudgeDeskSession targets the newest Claude terminal, not the oldest")
        func testNudgeTargetsNewestClaudeTerminal() async throws {
            let f = try makeDeskFixture(tag: "nudge-newest")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let oldest = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            // A later Claude row on the same desk — the live session after a handoff.
            let newest = try await f.db.terminals.create(
                worktreeID: desk.id, tmuxWindowID: "@9", tmuxPaneID: "%9",
                label: TerminalLabel.claudeCode)

            // Explicit ownership, not recency, selects the mutable judge when
            // more than one live candidate exists.
            _ = try await f.db.watchDeskLeases.acquire(
                worktreeID: desk.id, terminalID: newest.id)

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
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

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
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let original = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))
            f.dead.markDead(original.tmuxWindowID)
            f.spawnFailures.setFailing(true)

            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)
            #expect(
                Array(f.recorder.pastedPanes.dropFirst(before)).isEmpty,
                "no live terminal means nothing should be pasted anywhere")

            // Desk comes back; the next nudge must fire immediately.
            f.spawnFailures.setFailing(false)
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
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

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

        // MARK: - Pane ownership (#384 on the autonomous rails)

        /// The hazard the window/command guards cannot see. A recycled pane id
        /// resolves to a live window running a live Claude — both existing
        /// checks pass — but the pane belongs to somebody else's session, and
        /// what this rail pastes is a judge prompt an agent will read and act
        /// on. Spawn recovery is switched off so "nothing was pasted" means the
        /// stranger got nothing, not that a replacement absorbed the nudge.
        @Test("a pane owned by another terminal is never nudged")
        func testNudgeSkipsPaneOwnedByAnotherTerminal() async throws {
            let f = try makeDeskFixture(tag: "nudge-stranger")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let claude = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            // Same pane id, different owner — tmux recycled it under the row.
            f.identities.set(.live(terminalID: UUID().uuidString), for: claude.tmuxPaneID)
            f.spawnFailures.setFailing(true)

            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)

            let targets = Array(f.recorder.pastedPanes.dropFirst(before))
            #expect(targets.isEmpty, "a stranger's pane must receive nothing, got \(targets)")
        }

        /// The branch that matters most: absence is not disagreement. A pane
        /// spawned before TBD stamped identities answers with none, and must be
        /// treated exactly as it was before the consultation existed — refusing
        /// on nothing would turn every pre-stamp desk into a silent night.
        @Test("a pane that claims no identity is still nudged")
        func testNudgeStillReachesPaneWithNoIdentity() async throws {
            let f = try makeDeskFixture(tag: "nudge-unstamped")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let claude = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            f.identities.set(.live(terminalID: nil), for: claude.tmuxPaneID)

            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)

            #expect(
                Array(f.recorder.pastedPanes.dropFirst(before)) == [claude.tmuxPaneID],
                "an unstamped pane must be nudged exactly as before")
        }

        @Test("a pane that names its own terminal is nudged")
        func testNudgeReachesPaneThatNamesItsOwnTerminal() async throws {
            let f = try makeDeskFixture(tag: "nudge-owned")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let claude = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            f.identities.set(.live(terminalID: claude.id.uuidString), for: claude.tmuxPaneID)

            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)

            #expect(
                Array(f.recorder.pastedPanes.dropFirst(before)) == [claude.tmuxPaneID],
                "a pane that agrees it is this terminal must be nudged")
        }

        /// A consultation that cannot be RUN at all is not an answer about the
        /// pane. The candidate is dropped, matching how the sibling
        /// `paneCurrentCommand` check already treats a wedged server (`try?` →
        /// skip). Skipping costs one tick; pasting into a pane nobody could
        /// look at is the thing the check exists to stop.
        @Test("a pane whose identity cannot be read is not nudged")
        func testNudgeSkipsPaneWhoseIdentityCannotBeRead() async throws {
            let f = try makeDeskFixture(tag: "nudge-wedged")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let claude = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            f.identities.markUnreachable(claude.tmuxPaneID)
            f.spawnFailures.setFailing(true)

            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)

            let targets = Array(f.recorder.pastedPanes.dropFirst(before))
            #expect(targets.isEmpty, "an unverifiable pane must receive nothing, got \(targets)")
        }

        /// `postShiftWrapUp` reaches the same candidate list on the same timer,
        /// so it inherits the same exclusion — and its completion notification
        /// must not fire for a shift summary that was never posted.
        @Test("a pane owned by another terminal gets no wrap-up prompt")
        func testWrapUpSkipsPaneOwnedByAnotherTerminal() async throws {
            let f = try makeDeskFixture(tag: "wrapup-stranger")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let claude = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            f.identities.set(.live(terminalID: UUID().uuidString), for: claude.tmuxPaneID)

            let before = f.recorder.pastedPanes.count
            await f.manager.postShiftWrapUp(worktreeID: desk.id)

            let targets = Array(f.recorder.pastedPanes.dropFirst(before))
            #expect(targets.isEmpty, "a stranger's pane must receive no wrap-up, got \(targets)")

            let notifications = try await f.db.notifications.unread(worktreeID: desk.id)
            #expect(
                !notifications.contains(where: { $0.type == .taskComplete }),
                "no wrap-up was posted, so nothing should announce that one was")
        }

        /// Dropping a stranger makes the lease logic *more* correct rather than
        /// less. Two live-looking rows with no lease are ambiguous and fail
        /// closed — but one of them is a recycled pane id, not a rival judge.
        /// Excluding it leaves exactly one real candidate, so the desk takes a
        /// lease and gets nudged instead of stalling on a phantom contention.
        @Test("a stranger's pane is not a rival judge candidate")
        func testStrangerPaneDoesNotCreateJudgeContention() async throws {
            let f = try makeDeskFixture(tag: "judge-stranger")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let claude = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            // A newer row whose pane id has since been recycled to someone else.
            _ = try await f.db.terminals.create(
                worktreeID: desk.id, tmuxWindowID: "@9", tmuxPaneID: "%9",
                label: TerminalLabel.claudeCode)
            f.identities.set(.live(terminalID: UUID().uuidString), for: "%9")

            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)

            #expect(
                Array(f.recorder.pastedPanes.dropFirst(before)) == [claude.tmuxPaneID],
                "the one real candidate must be nudged, and the stranger left alone")
            let lease = try await f.db.watchDeskLeases.status(worktreeID: desk.id)
            #expect(lease?.terminalID == claude.id, "the lease must name the real candidate")
        }

        @Test("agent command matching distinguishes Claude, Codex, and a fallen-back shell")
        func agentCommandMatching() {
            #expect(DeskSessionManager.agentCommand("1.2.3", matches: .claude))
            #expect(DeskSessionManager.agentCommand("/usr/local/bin/claude", matches: .claude))
            #expect(DeskSessionManager.agentCommand("/opt/bin/codex", matches: .codex))
            #expect(!DeskSessionManager.agentCommand("zsh", matches: .codex))
            #expect(!DeskSessionManager.agentCommand("codex-helper", matches: .codex))
            #expect(!DeskSessionManager.agentCommand("codex", matches: .claude))
        }

        @Test("Watch Desk creates and nudges a Codex terminal when Codex is preferred")
        func codexDeskCreateAndNudge() async throws {
            let f = try makeDeskFixture(tag: "codex-create")
            let codexHome = f.home.appendingPathComponent("codex-home", isDirectory: true)
            let priorCodexHome = setCodexTestHome(codexHome.path)
            defer {
                restoreCodexTestHome(priorCodexHome)
                restoreTBDHome(f.priorTBDHome)
                try? FileManager.default.removeItem(at: f.home)
            }
            try await f.db.config.setPrimaryAgentPreference(.codex)
            f.commands.setDefault("codex")

            let desk = try await f.manager.ensureDeskSession(mode: .nightwatch)
            let terminals = try await f.db.terminals.list(worktreeID: desk.id)
            let codex = try #require(terminals.first(where: {
                $0.kind == .codex && $0.label == TerminalLabel.codex
            }))
            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)

            #expect(Array(f.recorder.pastedPanes.dropFirst(before)) == [codex.tmuxPaneID])
            #expect(!terminals.contains { $0.kind == .claude })
        }

        @Test("a live Codex row whose process fell back to zsh is respawned before nudge")
        func codexShellFallbackRecoversBeforeNudge() async throws {
            let f = try makeDeskFixture(tag: "codex-retry")
            let codexHome = f.home.appendingPathComponent("codex-home", isDirectory: true)
            let priorCodexHome = setCodexTestHome(codexHome.path)
            defer {
                restoreCodexTestHome(priorCodexHome)
                restoreTBDHome(f.priorTBDHome)
                try? FileManager.default.removeItem(at: f.home)
            }
            try await f.db.config.setPrimaryAgentPreference(.codex)
            f.commands.setDefault("codex")

            let desk = try await f.manager.ensureDeskSession(mode: .nightwatch)
            let initial = try #require(
                try await f.db.terminals.list(worktreeID: desk.id)
                    .first(where: { $0.kind == .codex })
            )
            f.commands.set("zsh", for: initial.tmuxPaneID)

            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)

            let codexRows = try await f.db.terminals.list(worktreeID: desk.id)
                .filter { $0.kind == .codex }
            #expect(codexRows.count == 2, "dead Codex row should be preserved but replaced")
            let replacement = try #require(codexRows.first(where: { $0.id != initial.id }))
            #expect(
                Array(f.recorder.pastedPanes.dropFirst(before)) == [replacement.tmuxPaneID],
                "recovery must nudge the replacement, never the shell-backed stale row"
            )
        }

        @Test("two live unowned judge candidates fail closed and notify once")
        func twoLiveCandidatesFailClosed() async throws {
            let f = try makeDeskFixture(tag: "judge-contention")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .nightwatch)
            _ = try await f.db.terminals.create(
                worktreeID: desk.id, tmuxWindowID: "@other", tmuxPaneID: "%other",
                label: TerminalLabel.claudeCode, kind: .claude)

            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)

            #expect(Array(f.recorder.pastedPanes.dropFirst(before)).isEmpty)
            let notifications = try await f.db.notifications.unread(worktreeID: desk.id)
            #expect(notifications.filter { $0.message?.contains("multiple live judge") == true }.count == 1)
        }

        @Test("successor spawned before transfer stays read-only and predecessor remains judge")
        func spawnBeforeTransferKeepsPredecessor() async throws {
            let f = try makeDeskFixture(tag: "judge-half-handoff")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .nightwatch)
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)
            let lease = try #require(
                try await f.db.watchDeskLeases.status(worktreeID: desk.id))
            let owner = try #require(try await f.db.terminals.get(id: lease.terminalID))
            let successor = try await f.db.terminals.create(
                worktreeID: desk.id, tmuxWindowID: "@half", tmuxPaneID: "%half",
                label: TerminalLabel.codex, kind: .codex)
            f.commands.set("codex", for: successor.tmuxPaneID)

            let laterManager = DeskSessionManager(
                db: f.db,
                lifecycle: WorktreeLifecycle(
                    db: f.db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
                tmux: TmuxManager(
                    dryRun: true,
                    dryRunRecorder: { f.recorder.record($0) },
                    dryRunWindowIsDead: { f.dead.isDead($0) },
                    dryRunPaneCurrentCommand: { _, pane in f.commands.command(for: pane) }),
                skillDir: f.home.appendingPathComponent("skills/nightwatch").path, actuationLog: makeTestActuationLog())
            _ = try await laterManager.ensureDeskSession(mode: .nightwatch)
            let before = f.recorder.pastedPanes.count
            await laterManager.nudgeDeskSession(worktreeID: desk.id, act: true)

            #expect(Array(f.recorder.pastedPanes.dropFirst(before)) == [owner.tmuxPaneID])
            #expect(
                try await f.db.terminals.get(id: successor.id)?.watchDeskRole
                    == .readOnlyCoordinator)
            #expect(
                try await f.db.watchDeskLeases.status(worktreeID: desk.id)?.terminalID
                    == owner.id)
        }

        @Test("dead lease owner is fenced and the sole live successor takes a higher generation")
        func deadOwnerRecovery() async throws {
            let f = try makeDeskFixture(tag: "judge-owner-loss")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .nightwatch)
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: true)
            let first = try #require(try await f.db.watchDeskLeases.status(worktreeID: desk.id))
            let owner = try #require(try await f.db.terminals.get(id: first.terminalID))
            f.dead.markDead(owner.tmuxWindowID)
            let successor = try await f.db.terminals.create(
                worktreeID: desk.id, tmuxWindowID: "@successor", tmuxPaneID: "%successor",
                label: TerminalLabel.claudeCode, kind: .claude)

            // Avoid the ordinary ten-minute nudge overlap hiding owner-loss recovery.
            let laterManager = DeskSessionManager(
                db: f.db,
                lifecycle: WorktreeLifecycle(
                    db: f.db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
                tmux: TmuxManager(
                    dryRun: true,
                    dryRunRecorder: { f.recorder.record($0) },
                    dryRunWindowIsDead: { f.dead.isDead($0) },
                    dryRunPaneCurrentCommand: { _, pane in f.commands.command(for: pane) }),
                skillDir: f.home.appendingPathComponent("skills/nightwatch").path, actuationLog: makeTestActuationLog())
            _ = try await laterManager.ensureDeskSession(mode: .nightwatch)
            await laterManager.nudgeDeskSession(worktreeID: desk.id, act: true)

            let recovered = try #require(try await f.db.watchDeskLeases.status(worktreeID: desk.id))
            #expect(recovered.terminalID == successor.id)
            #expect(recovered.generation == first.generation + 1)
        }

        // MARK: - Spawn rate-limiting (bug fix: duplicate spawn on unverifiable terminal)

        /// The regression: `paneSendTarget` returns `.missing` when the query fails
        /// (correct for "don't paste into a pane I can't verify"), but the spawn
        /// logic reused this to mean "desk is unstaffed" and spawned every tick.
        /// This test drives the exact failure mode: a live pane that the identity
        /// consultation cannot reach (wedged tmux, timeout, etc). The staffing check
        /// must treat "cannot tell" as "staffed for now" and skip the spawn.
        /// Multiple ticks are simulated via `now` advance to pass the rate limit.
        @Test("unverifiable terminal does not trigger spawn — staffing check treats 'cannot tell' as staffed")
        func testUnavailableIdentityConsultationIsNotSpawned() async throws {
            let f = try makeDeskFixture(tag: "staff-unverifiable")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let clock = TestDateSource(Date(timeIntervalSince1970: 1_000_000))
            let manager = DeskSessionManager(
                db: f.db,
                lifecycle: WorktreeLifecycle(
                    db: f.db,
                    git: GitManager(),
                    tmux: TmuxManager(dryRun: true),
                    hooks: HookResolver()
                ),
                tmux: TmuxManager(
                    dryRun: true,
                    dryRunRecorder: { f.recorder.record($0) },
                    dryRunWindowIsDead: { f.dead.isDead($0) },
                    dryRunPaneCurrentCommand: { _, paneID in f.commands.command(for: paneID) },
                    dryRunPaneSendTarget: { _, paneID in try f.identities.answer(for: paneID) }
                ),
                skillDir: f.home.appendingPathComponent("skills/nightwatch").path,
                now: clock.provider,
                actuationLog: makeTestActuationLog()
            )

            let desk = try await manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let original = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            // The pane exists and is running Claude, but the identity check fails
            // (tmux wedged, query timeout, etc).
            f.identities.markUnreachable(original.tmuxPaneID)

            // Multiple iterations simulating ticks passing. Without the fix, each
            // tick would spawn a new terminal. With the fix, the staffing check
            // says "cannot tell if it's alive or not, assume staffed" and skips spawn.
            let terminalCountsBefore = try await f.db.terminals.list(worktreeID: desk.id).count
            for iteration in 0..<3 {
                // Advance the clock past the 2-minute recovery rate limit.
                clock.advance(by: 2 * 60 + 1)

                // Call ensure, which checks staffing and may spawn if genuinely unstaffed.
                // Because the pane is unverifiable (not unresponsive), staffing check
                // returns true and no spawn happens.
                _ = try await manager.ensureDeskSession(mode: .daywatch)

                let terminalCountsAfter = try await f.db.terminals.list(worktreeID: desk.id).count
                #expect(
                    terminalCountsAfter == terminalCountsBefore,
                    "iteration \(iteration): unverifiable pane must not trigger spawn"
                )
            }
        }

        /// Cross-kind incumbent reuse: `ensureDeskSession` must treat a live agent of
        /// EITHER supported kind as the desk's agent, not only the configured preferred
        /// kind. An intentional handoff to Codex while Claude is preferred must not spawn
        /// a Claude replacement.
        @Test("live Codex terminal is reused even when Claude is preferred agent")
        func testLiveCodexTerminalReusedWhenClaudePreferred() async throws {
            let f = try makeDeskFixture(tag: "staff-cross-kind")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            // Prefer Claude (the default), but a Codex session exists.
            try await f.db.config.setPrimaryAgentPreference(.claude)

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)

            // Replace the Claude terminal with a Codex one (simulating handoff).
            let claude = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))
            f.dead.markDead(claude.tmuxWindowID)
            let codex = try await f.db.terminals.create(
                worktreeID: desk.id, tmuxWindowID: "@codex", tmuxPaneID: "%codex",
                label: TerminalLabel.codex, kind: .codex)
            f.commands.set("codex", for: codex.tmuxPaneID)

            // Second ensure: prefer Claude, but a live Codex exists. Must reuse Codex
            // without spawning Claude.
            let terminalsBefore = try await f.db.terminals.list(worktreeID: desk.id).count
            let desk2 = try await f.manager.ensureDeskSession(mode: .daywatch)

            #expect(desk2.id == desk.id, "same desk should be reused")
            let terminalsAfter = try await f.db.terminals.list(worktreeID: desk.id).count
            #expect(
                terminalsAfter == terminalsBefore,
                "live Codex should prevent Claude spawn even when Claude is preferred"
            )
        }

        /// A pane running a Claude version string (e.g. "2.1.229") is live and should
        /// be reused. The `agentCommand` check must recognize it.
        @Test("live agent running version string pane_current_command is reused")
        func testLiveVersionStringCommandIsReused() async throws {
            let f = try makeDeskFixture(tag: "staff-version-string")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let claude = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            // Set the pane's command to a version string, which `agentCommand` should
            // recognize as a Claude process.
            f.commands.set("2.1.229", for: claude.tmuxPaneID)

            // Ensure again: the version-string command should be recognized, and
            // no spawn should happen.
            let terminalsBefore = try await f.db.terminals.list(worktreeID: desk.id).count
            _ = try await f.manager.ensureDeskSession(mode: .daywatch)

            let terminalsAfter = try await f.db.terminals.list(worktreeID: desk.id).count
            #expect(
                terminalsAfter == terminalsBefore,
                "live agent with version-string command must not trigger spawn"
            )
        }

        /// Genuine recovery still works, and is bounded by evidence rather than by a
        /// clock. A desk whose agent is really gone gets exactly one replacement; the
        /// next tick, with that replacement alive, gets none; once the replacement is
        /// itself proven dead, the desk is allowed to try again.
        ///
        /// Before the fix the bound was the absence of any bound: every tick that found
        /// no live candidate spawned another agent.
        @Test("a dead desk is restaffed once per death, not once per tick")
        func testDeadDeskRestaffsOncePerDeath() async throws {
            let f = try makeDeskFixture(tag: "staff-recovery")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let original = try #require(
                try await f.db.terminals.list(worktreeID: desk.id)
                    .first(where: { $0.label == TerminalLabel.claudeCode }))

            // Proven dead: tmux answers that the pane is gone.
            f.identities.set(.missing, for: original.tmuxPaneID)
            f.dead.markDead(original.tmuxWindowID)

            let beforeRecovery = try await f.db.terminals.list(worktreeID: desk.id).count
            _ = try await f.manager.ensureDeskSession(mode: .daywatch)
            let afterRecovery = try await f.db.terminals.list(worktreeID: desk.id)
            #expect(
                afterRecovery.count == beforeRecovery + 1,
                "a proven-dead desk must be restaffed exactly once")

            // The replacement is alive, so further ticks must add nothing.
            for tick in 0..<3 {
                _ = try await f.manager.ensureDeskSession(mode: .daywatch)
                let count = try await f.db.terminals.list(worktreeID: desk.id).count
                #expect(count == afterRecovery.count, "tick \(tick) must not add another agent")
            }

            // Now the replacement dies too. One death, one replacement.
            let replacement = try #require(
                afterRecovery.max(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }))
            f.identities.set(.missing, for: replacement.tmuxPaneID)
            f.dead.markDead(replacement.tmuxWindowID)
            _ = try await f.manager.ensureDeskSession(mode: .daywatch)
            let afterSecondDeath = try await f.db.terminals.list(worktreeID: desk.id).count
            #expect(
                afterSecondDeath == afterRecovery.count + 1,
                "a replacement that dies must itself be replaced")
        }

        /// Kill every terminal the desk currently has — proven gone, both the way
        /// `windowExists` sees it and the way the identity consultation does — then
        /// drive one tick. Returns how many terminal rows exist afterwards, which is
        /// the only externally visible evidence of whether a replacement was spawned.
        private func killAllAndTick(
            _ f: (db: TBDDatabase, manager: DeskSessionManager, recorder: DeskTmuxRecorder,
                  dead: DeadWindows, commands: PaneCommands, identities: PaneIdentities,
                  spawnFailures: SpawnFailureSwitch, home: URL, priorTBDHome: String?),
            desk: UUID
        ) async throws -> Int {
            for terminal in try await f.db.terminals.list(worktreeID: desk) {
                f.identities.set(.missing, for: terminal.tmuxPaneID)
                f.dead.markDead(terminal.tmuxWindowID)
            }
            _ = try await f.manager.ensureDeskSession(mode: .daywatch)
            return try await f.db.terminals.list(worktreeID: desk).count
        }

        /// The backstop has to actually count, and it did not.
        ///
        /// `spawnDeskTerminal` cleared the recovery budget itself, and
        /// `spawnRecoveryTerminalIfWarranted` calls that very function to make its
        /// attempt — so on every attempt the clear ran first and the increment second,
        /// pinning `consecutiveRecoverySpawnsWithoutNudge` at 1 forever. The cap was
        /// unreachable, the give-up notification could never fire, and a desk whose
        /// launches all died went back to spawning one abandoned agent per tick: the
        /// precise unbounded behaviour this rail exists to end.
        ///
        /// Nothing about that is visible from a single attempt, which is why this
        /// walks four. Each tick kills every terminal on the desk before running, so no
        /// nudge ever lands and nothing legitimately clears the budget. Three
        /// replacements must happen, the third must be the last, and the desk must say
        /// so out loud — a Watch Desk that has quietly given up looks exactly like one
        /// that is fine.
        @Test("the recovery budget accumulates, stops at the third spawn, and notifies")
        func testRecoveryBudgetAccumulatesAndCapsAtThree() async throws {
            let f = try makeDeskFixture(tag: "staff-budget")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            var count = try await f.db.terminals.list(worktreeID: desk.id).count

            // maxConsecutiveRecoverySpawnsWithoutNudge attempts, each licensed by a
            // fresh death. Before the fix the counter never left 1, so this loop passed
            // and the one below it did not.
            for attempt in 1...3 {
                let after = try await killAllAndTick(f, desk: desk.id)
                #expect(
                    after == count + 1,
                    "attempt \(attempt) of 3 must still spawn a replacement")
                count = after
            }

            #expect(
                try await f.db.notifications.unread(worktreeID: desk.id)
                    .filter({ $0.type == .error }).isEmpty,
                "the desk must not give up while attempts remain")

            // The budget is spent. Further deaths buy nothing, however many arrive.
            for tick in 0..<2 {
                let after = try await killAllAndTick(f, desk: desk.id)
                #expect(
                    after == count,
                    "tick \(tick) past the cap must not spawn a fourth agent")
            }

            let errors = try await f.db.notifications.unread(worktreeID: desk.id)
                .filter { $0.type == .error }
            #expect(
                errors.count == 1,
                "exhaustion must be announced exactly once per incident, not per tick")
            #expect(
                errors.first?.message?.contains("could not start an agent") == true,
                "the notification must name what stopped: \(errors.first?.message ?? "nil")")
        }

        /// The other side of the counter: it is a budget for one incident, not a
        /// lifetime quota. A nudge that reaches a pane is the proof the desk is staffed
        /// by something that took it, and it must hand the attempts back — otherwise a
        /// desk that had a bad hour in the evening would refuse to restaff itself for
        /// the rest of the night.
        @Test("a delivered nudge hands the recovery budget back")
        func testDeliveredNudgeClearsRecoveryBudget() async throws {
            let f = try makeDeskFixture(tag: "staff-budget-reset")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)

            // Spend the whole budget, leaving the third replacement alive.
            var count = try await f.db.terminals.list(worktreeID: desk.id).count
            for _ in 1...3 {
                count = try await killAllAndTick(f, desk: desk.id)
            }

            let pastesBefore = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: false)
            #expect(
                f.recorder.pastedPanes.count == pastesBefore + 1,
                "the live replacement must have taken a nudge for this test to mean anything")

            // Same fourth death as the test above, which there bought nothing.
            let after = try await killAllAndTick(f, desk: desk.id)
            #expect(
                after == count + 1,
                "a delivered nudge must restore the desk's ability to restaff itself")
        }

        /// The incident, end to end, in the order it was observed in the field: one tick
        /// spawns a replacement desk AND invalidates the live incumbent, ~30 seconds
        /// apart, while that incumbent's lease is renewing on its own timer and has never
        /// missed a renewal. Both halves come from the same tick, through two different
        /// actuators, on the same wrong verdict.
        ///
        /// So this drives the whole tick — `ensureDeskSession` (which spawns),
        /// `maintainJudgeLease` (the ownership heartbeat) and `nudgeDeskSession` (which
        /// revoked) — with the judge renewing between ticks the way a running judge does,
        /// and holds all four invariants across every one of them: no new terminal, the
        /// terminal's persisted role stays `judge`, and the lease keeps its owner, its
        /// generation and its validity.
        ///
        /// Before the fix each tick read an unanswerable tmux consultation as "the
        /// owner's pane is gone", demoted the incumbent in place — same terminal, same
        /// generation, `expiresAt` zeroed, so its next renew came back fenced — and
        /// spawned another agent beside the judge it had just stripped of authority.
        @Test("a live incumbent with a renewing lease survives repeated ticks untouched")
        func testLiveIncumbentSurvivesRepeatedTicks() async throws {
            let f = try makeDeskFixture(tag: "staff-incumbent")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let incumbent = try #require(
                try await f.db.terminals.list(worktreeID: desk.id)
                    .first(where: { $0.label == TerminalLabel.claudeCode }))

            // The incumbent holds the judge lease, as a running judge does.
            var lease = try await f.db.watchDeskLeases.acquire(
                worktreeID: desk.id, terminalID: incumbent.id, now: Date())

            // Its pane is alive and running an agent, but the identity consultation
            // cannot be run — the production fault.
            f.identities.markUnreachable(incumbent.tmuxPaneID)

            let terminalsBefore = try await f.db.terminals.list(worktreeID: desk.id).count
            for tick in 0..<5 {
                // The judge's own renew loop, which never missed a beat in the field.
                lease = try await f.db.watchDeskLeases.renew(
                    worktreeID: desk.id, terminalID: lease.terminalID,
                    token: lease.token, generation: lease.generation, now: Date())

                // One whole tick, in the order the runner drives it.
                _ = try await f.manager.ensureDeskSession(mode: .daywatch)
                await f.manager.maintainJudgeLease(worktreeID: desk.id)
                await f.manager.nudgeDeskSession(worktreeID: desk.id, act: false)

                let terminals = try await f.db.terminals.list(worktreeID: desk.id)
                #expect(
                    terminals.count == terminalsBefore,
                    "tick \(tick): no agent may be spawned beside a live incumbent")

                let row = try #require(terminals.first { $0.id == incumbent.id })
                #expect(
                    row.watchDeskRole == .judge,
                    "tick \(tick): the incumbent was demoted in place")

                let current = try #require(try await f.db.watchDeskLeases.status(worktreeID: desk.id))
                #expect(current.terminalID == lease.terminalID, "tick \(tick): owner changed")
                #expect(current.generation == lease.generation, "tick \(tick): generation changed")
                #expect(
                    current.isValid(at: Date()),
                    "tick \(tick): a lease was revoked on a consultation nobody could run")
            }
        }

        /// The other half of the same rule: when tmux positively answers that the
        /// owner's pane is gone, the lease IS revoked, exactly as before. Refusing to
        /// act on absence of evidence must not become refusing to act on evidence.
        @Test("a lease whose owner is proven gone is still revoked")
        func testProvenGoneOwnerLoosesLease() async throws {
            let f = try makeDeskFixture(tag: "staff-revoke")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let incumbent = try #require(
                try await f.db.terminals.list(worktreeID: desk.id)
                    .first(where: { $0.label == TerminalLabel.claudeCode }))
            let lease = try await f.db.watchDeskLeases.acquire(
                worktreeID: desk.id, terminalID: incumbent.id, now: Date())
            #expect(lease.isValid(at: Date()))

            f.identities.set(.missing, for: incumbent.tmuxPaneID)
            f.dead.markDead(incumbent.tmuxWindowID)

            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: false)

            // Either the lease is now invalid, or a live successor holds a newer
            // one — what must not survive is the gone terminal still holding
            // valid authority.
            let after = try #require(try await f.db.watchDeskLeases.status(worktreeID: desk.id))
            #expect(
                !(after.terminalID == incumbent.id && after.isValid(at: Date())),
                "a proven-gone owner must lose the lease")
        }

        /// Mode switches must reuse the existing desk and terminal without respawning.
        /// This is preserved by the cross-kind check: both modes use the same desk and
        /// terminal, so mode doesn't affect reuse.
        @Test("mode switch daywatch↔nightwatch reuses desk without respawning")
        func testModeFlipReusesDesk() async throws {
            let f = try makeDeskFixture(tag: "mode-reuse")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk1 = try await f.manager.ensureDeskSession(mode: .daywatch)
            let terminalsAfterFirst = try await f.db.terminals.list(worktreeID: desk1.id)

            // Mode switch: nightwatch on the same desk.
            let desk2 = try await f.manager.ensureDeskSession(mode: .nightwatch)

            #expect(desk2.id == desk1.id, "mode switch must reuse the same desk")

            let terminalsAfterSecond = try await f.db.terminals.list(worktreeID: desk1.id)
            #expect(
                terminalsAfterSecond.count == terminalsAfterFirst.count,
                "mode switch must not respawn the terminal"
            )
        }

        // MARK: - Observability: distinguishing "cannot tell" from "genuinely gone"

        /// Failed consultation (unverifiable) is not the same as a genuine
        /// "pane is gone" answer. When the identity consultation fails (tmux
        /// returns non-zero exit or throws), it returns `.unverifiable(error:)`.
        /// This must not license a spawn — "cannot tell" is not "empty".
        @Test("unverifiable identity consultation is not pasted into (differs from send failure)")
        func testUnverifiableIdentityIsNotPastedInto() async throws {
            let f = try makeDeskFixture(tag: "obs-unverifiable")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let desk = try await f.manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let claude = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            // The pane exists and is running Claude, but the identity check fails
            // (tmux query returns non-zero exit).
            f.identities.markUnreachable(claude.tmuxPaneID)

            let before = f.recorder.pastedPanes.count
            await f.manager.nudgeDeskSession(worktreeID: desk.id, act: false)

            let targets = Array(f.recorder.pastedPanes.dropFirst(before))
            #expect(targets.isEmpty, "unverifiable pane must not be pasted into")
        }

        /// Genuine death is still diagnosable: when a pane is truly gone
        /// (window killed, pane dead, no agent process), spawning is triggered.
        /// The `.missing` answer from `paneSendTarget` is the expected failure
        /// mode that should license recovery spawn.
        @Test("genuinely missing pane triggers recovery spawn (verified distinct from unverifiable)")
        func testGenuinelyMissingPaneSpawns() async throws {
            let f = try makeDeskFixture(tag: "obs-missing")
            defer { restoreTBDHome(f.priorTBDHome); try? FileManager.default.removeItem(at: f.home) }

            let clock = TestDateSource(Date(timeIntervalSince1970: 3_000_000))
            let manager = DeskSessionManager(
                db: f.db,
                lifecycle: WorktreeLifecycle(
                    db: f.db,
                    git: GitManager(),
                    tmux: TmuxManager(dryRun: true),
                    hooks: HookResolver()
                ),
                tmux: TmuxManager(
                    dryRun: true,
                    dryRunRecorder: { f.recorder.record($0) },
                    dryRunWindowIsDead: { f.dead.isDead($0) },
                    dryRunPaneCurrentCommand: { _, paneID in f.commands.command(for: paneID) }
                ),
                skillDir: f.home.appendingPathComponent("skills/nightwatch").path,
                now: clock.provider,
                actuationLog: makeTestActuationLog()
            )

            let desk = try await manager.ensureDeskSession(mode: .daywatch)
            let seeded = try await f.db.terminals.list(worktreeID: desk.id)
            let original = try #require(seeded.first(where: { $0.label == TerminalLabel.claudeCode }))

            // Mark the pane as genuinely gone (window killed).
            f.dead.markDead(original.tmuxWindowID)
            try await f.db.terminals.deleteForWorktree(worktreeID: desk.id)

            // Ensure after the genuinely-gone pane: should spawn recovery.
            let terminalsBefore = try await f.db.terminals.list(worktreeID: desk.id).count
            _ = try await manager.ensureDeskSession(mode: .daywatch)
            let terminalsAfter = try await f.db.terminals.list(worktreeID: desk.id).count

            #expect(
                terminalsAfter == terminalsBefore + 1,
                "genuinely-missing pane must trigger recovery spawn (distinct from unverifiable)"
            )
        }
    }
}
