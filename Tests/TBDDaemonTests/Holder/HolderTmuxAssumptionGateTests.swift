import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Every argv the dry-run `TmuxManager` was handed. "Nothing was recorded" is
/// the assertion that a guard sat ahead of the whole tmux mechanic, not merely
/// ahead of the DB write at the end of it.
private final class RecordedTmuxArgs: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []

    func append(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        calls.append(args)
    }

    func snapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

/// The three subsystems that assumed every terminal has a live tmux window,
/// and the refusals that stop them acting on a holder-backed row.
///
/// The shared defect: a holder row carries `tmuxWindowID == ""` and
/// `tmuxPaneID == ""` by construction, and `TmuxManager.windowExists` swallows
/// its errors and answers `false`. So the empty coordinate does not fail — it
/// reads as a window that is definitely gone, and every recovery mechanic built
/// on that reading fires against a session that is perfectly alive.
///
/// Milestone A does not teach recreate or park the holder transport; it refuses
/// them. Each test therefore asserts on the ROW after the call, not only on the
/// returned value: a refusal that still parked the row would be the very bug
/// these gates exist to remove, and the return value alone cannot see it.
///
/// Each gate carries both legs. The tmux leg is not ceremony — every one of
/// these guards is a `transport != .holder` that an inverted comparison would
/// satisfy just as well while disabling recovery for the transport that still
/// needs it.
@Suite("Holder rows and the tmux-window assumption")
struct HolderTmuxAssumptionGateTests {

    // MARK: - Fixtures

    /// Temp profile/host dirs, so `wake()`'s transcript-sync ambient fallback
    /// lists a sandbox rather than the developer's real `~/.claude/projects`.
    private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-holdergate-\(UUID().uuidString)", isDirectory: true)
        return ClaudeProfileConfigDirManager(
            baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true))
    }

    /// In-memory DB plus a worktree whose path exists on disk — both the wake
    /// and the recreate paths refuse to respawn into a missing directory, and
    /// that refusal would mask the one under test.
    private func seedWorktree(_ db: TBDDatabase) async throws -> (Worktree, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-holdergate-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = try await db.repos.create(
            path: dir.path, displayName: "acme", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: dir.path,
            tmuxServer: "tbd-holdergate")
        return (wt, dir)
    }

    /// An idle, resumable Claude row. `transport` is the only thing that varies
    /// between the two legs of every test below — with `.holder` it also takes
    /// the empty tmux coordinates and the holder/child pids the create path
    /// writes, because those are what the unguarded code would act on.
    private func seedClaudeTerminal(
        _ db: TBDDatabase, worktreeID: UUID, transport: TerminalTransport
    ) async throws -> Terminal {
        let holder = transport == .holder
        let terminal = try await db.terminals.create(
            worktreeID: worktreeID,
            tmuxWindowID: holder ? "" : "@7",
            tmuxPaneID: holder ? "" : "%7",
            label: TerminalLabel.claudeCode,
            claudeSessionID: "sess-holdergate",
            kind: .claude,
            transport: transport,
            holderPID: holder ? 9101 : nil,
            childPID: holder ? 9102 : nil)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .idle, source: .derived)
        return try #require(try await db.terminals.get(id: terminal.id))
    }

    private func coordinator(_ db: TBDDatabase, tmux: TmuxManager) -> HibernationCoordinator {
        HibernationCoordinator(
            db: db, tmux: tmux, configDirManager: isolatedConfigDirManager(),
            actuationLog: makeTestActuationLog())
    }

    /// Dry-run tmux that reports every window dead, recording every argv.
    ///
    /// The dead-window answer is not pessimism, it is what a holder row gets
    /// from a real server: `windowExists(windowID: "")` cannot succeed, and
    /// `TmuxManager` swallows the failure and returns `false`. Reaching that
    /// answer through the hook rather than through a real missing server keeps
    /// the fixture off live tmux — and without it the dry-run default reports
    /// the empty window ALIVE, which lets both subsystems short-circuit to a
    /// harmless no-op and hides the corruption these gates prevent.
    private func deadWindowTmux(_ recorded: RecordedTmuxArgs) -> TmuxManager {
        TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorded.append($0) },
            dryRunWindowIsDead: { _ in true })
    }

    private func router(_ db: TBDDatabase, tmux: TmuxManager) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            actuationLog: makeTestActuationLog())
    }

    /// Every column a park, a wake or a recreate would touch. Comparing the
    /// whole set — rather than spot-checking `hibernatedAt` — is what makes
    /// "the row was left alone" an assertion instead of a hope.
    private struct RowFingerprint: Equatable {
        let tmuxWindowID: String
        let tmuxPaneID: String
        let transport: TerminalTransport
        let holderPID: Int32?
        let childPID: Int32?
        let claudeSessionID: String?
        let hibernatedAt: Date?
        let suspendedAt: Date?
        let hibernateReason: HibernateReason?
        let suspendedSnapshot: String?
        let sessionIncarnationID: UUID?

        init(_ t: Terminal) {
            tmuxWindowID = t.tmuxWindowID
            tmuxPaneID = t.tmuxPaneID
            transport = t.transport
            holderPID = t.holderPID
            childPID = t.childPID
            claudeSessionID = t.claudeSessionID
            hibernatedAt = t.hibernatedAt
            suspendedAt = t.suspendedAt
            hibernateReason = t.hibernateReason
            suspendedSnapshot = t.suspendedSnapshot
            sessionIncarnationID = t.sessionIncarnationID
        }
    }

    // MARK: - Gate 1: terminal.recreateWindow

    @Test("recreateWindow refuses a holder row and leaves every column alone")
    func recreateWindowRefusesHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)

        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(!response.success)
        #expect(response.error == RPCRouter.holderRecreateRefusal(terminalID: terminal.id))

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "recreateWindow mutated a holder row it was supposed to refuse")
        // The strongest half: neither branch below the guard ran. The repark
        // branch would have killed a window, the respawn branch created one.
        #expect(recorded.snapshot().isEmpty,
                "recreateWindow reached tmux for a holder row: \(recorded.snapshot())")
    }

    @Test("recreateWindow still recreates a tmux row whose window is gone")
    func recreateWindowStillActsOnTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A shell row, so the handler takes the respawn branch rather than the
        // repark branch — the branch that would have stood up a tmux window
        // under a holder row.
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@old", tmuxPaneID: "%old", kind: .shell)

        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.tmuxWindowID != "@old",
                "the tmux leg must still get a fresh window")
        #expect(recorded.snapshot().contains { $0.contains("new-window") })
    }

    // MARK: - Gate 2: hibernation eligibility

    @Test("a holder row is not manually hibernatable, and manualHibernate refuses it")
    func holderRowIsNotManuallyHibernatable() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)

        // The pure property first: it is what the app's tab menu reads, so a
        // holder tab must not even offer Hibernate.
        #expect(!terminal.isManuallyHibernatable)
        #expect(!terminal.isAutoHibernationEligible)

        let result = await coordinator(db, tmux: TmuxManager(dryRun: true))
            .manualHibernate(terminalID: terminal.id)
        #expect(result == .notEligible(reason: HibernationCoordinator.holderTransportRefusal))

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "a refused manual hibernate still mutated the holder row")
    }

    @Test("an identical tmux row is still manually hibernatable and parks")
    func tmuxRowStillManuallyHibernatable() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)

        #expect(terminal.isManuallyHibernatable)
        #expect(terminal.isAutoHibernationEligible)

        let result = await coordinator(db, tmux: TmuxManager(dryRun: true))
            .manualHibernate(terminalID: terminal.id)
        #expect(result == .ok)
        #expect(try await db.terminals.get(id: terminal.id)?.hibernatedAt != nil)
    }

    @Test("the auto and merge rails both name the holder transport as the blocker")
    func autoAndMergeRailsRefuseHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)

        let now = Date()
        // Idle for an hour with the sweep armed: every other rail passes, so
        // `.eligible` is what this row gets without the transport gate.
        #expect(HibernationGate.decide(
            terminal: terminal, autoHibernateEnabled: true, idleTimeout: 60,
            idleSince: now.addingTimeInterval(-3600), now: now) == .holderTransport)
        #expect(HibernationGate.decideForMerge(
            terminal: terminal, inputVetoEnabled: false,
            lastInputAt: nil) == .holderTransport)
    }

    @Test("the auto and merge rails still elect an identical tmux row")
    func autoAndMergeRailsStillElectTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)

        let now = Date()
        #expect(HibernationGate.decide(
            terminal: terminal, autoHibernateEnabled: true, idleTimeout: 60,
            idleSince: now.addingTimeInterval(-3600), now: now) == .eligible)
        #expect(HibernationGate.decideForMerge(
            terminal: terminal, inputVetoEnabled: false, lastInputAt: nil) == .eligible)
    }

    // MARK: - Gate 3: wake

    @Test("wake refuses a parked holder row without touching tmux or the row")
    func wakeRefusesParkedHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        // Park the row through the store directly. The coordinator now refuses
        // to park it, but a row parked by an older daemon — or by a path this
        // milestone has not yet gated — still has to survive a wake, and the
        // parked branch is where the damage would be done.
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-holdergate", reason: .manual)
        let before = RowFingerprint(try #require(try await db.terminals.get(id: terminal.id)))
        #expect(before.hibernatedAt != nil)

        let result = await coordinator(db, tmux: tmux).wake(terminalID: terminal.id)
        #expect(result == .holderTransport)

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "a refused wake still mutated the holder row")
        #expect(recorded.snapshot().isEmpty,
                "wake reached tmux for a holder row: \(recorded.snapshot())")
    }

    @Test("wake still un-parks an identical tmux row")
    func wakeStillUnparksTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-holdergate", reason: .manual)

        let result = await coordinator(db, tmux: tmux).wake(terminalID: terminal.id)
        #expect(result == .ok)
        #expect(try await db.terminals.get(id: terminal.id)?.isParked == false)
        #expect(!recorded.snapshot().isEmpty, "the tmux leg must still drive tmux")
    }
}
