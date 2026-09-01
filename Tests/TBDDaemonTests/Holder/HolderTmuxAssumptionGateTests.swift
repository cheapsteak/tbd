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

/// The subsystems that assumed every terminal has a live tmux window, and what
/// each of them now does with a holder-backed row instead.
///
/// The shared defect: a holder row carries `tmuxWindowID == ""` and
/// `tmuxPaneID == ""` by construction, and `TmuxManager.windowExists` swallows
/// its errors and answers `false`. So the empty coordinate does not fail — it
/// reads as a window that is definitely gone, and every mechanic built on that
/// reading fires against a session that is perfectly alive.
///
/// Milestone A does not teach recreate, park or in-place swap the holder
/// transport; it refuses them, because an action the user has to take another
/// way is recoverable and a row that lies about a live process is not. Each
/// test therefore asserts on the ROW after the call, not only on the returned
/// value: a refusal that still parked or re-identified the row would be the
/// very bug these gates exist to remove, and the return value alone cannot see
/// it.
///
/// **`terminal.delete` is the exception, and the reason this suite is not
/// simply a list of refusals.** Its row is going away either way, so refusing
/// would leak the holder process, the job it forked and its rendezvous files
/// rather than protect anything. It does the holder work instead — the shape of
/// the fix follows from what the path is for, not from the family it belongs
/// to.
///
/// Each gate carries both legs. The tmux leg is not ceremony — every one of
/// these branches is a `transport == .holder` comparison that an inverted one
/// would satisfy just as well while disabling the mechanic for the transport
/// that still needs it.
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
    ///
    /// `childPID` is overridable for one reason: the delete gate is the only
    /// test here that reaches code which would `kill()` it, and no fixture on a
    /// shared box may name a pid that could really exist. See
    /// `deleteDisposesHolderInsteadOfKillingAWindow`.
    private func seedClaudeTerminal(
        _ db: TBDDatabase, worktreeID: UUID, transport: TerminalTransport,
        childPID: Int32 = 9102
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
            childPID: holder ? childPID : nil)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .idle, source: .derived)
        return try #require(try await db.terminals.get(id: terminal.id))
    }

    /// A registry whose rendezvous paths come from an explicit environment, so
    /// nothing here can reach the developer's real `~/tbd` even for an instant
    /// — and a short one, because a holder socket path has to fit `sun_path`.
    ///
    /// Nothing is ever created under it. Both callers below only *derive* the
    /// path and then fail to connect to it, which is exactly the state a
    /// session whose holder has already gone is in.
    private func holderRegistry(listing terminals: [Terminal]) -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/tmp/tbd-hg-\(UUID().uuidString.prefix(8))"],
            listTerminals: { terminals })
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

    /// A router with the same sandboxed config dirs the coordinator gets: the
    /// swap path seeds folder trust and writes a settings overlay before it
    /// spawns anything, and neither belongs in the developer's real `~/.claude`.
    private func router(_ db: TBDDatabase, tmux: TmuxManager) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            configDirManager: isolatedConfigDirManager(),
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
        /// The column an in-place profile swap exists to change, and so the one
        /// that makes "the swap was refused" an assertion about the row rather
        /// than about its return value.
        let profileID: UUID?
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
            profileID = t.profileID
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

    // MARK: - Gate 4: terminal.swapProfile, .inPlace

    @Test("an in-place profile swap refuses a holder row and leaves every column alone")
    func inPlaceSwapRefusesHolderRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder)
        let before = RowFingerprint(terminal)

        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id, newProfileID: nil, mode: .inPlace)))

        #expect(!response.success)
        #expect(response.error == RPCRouter.holderInPlaceSwapRefusal(terminalID: terminal.id))

        // The row is the whole point. Unguarded, `inPlaceSwapRespawn` commits
        // the replacement identity — a fresh `sessionIncarnationID`, the new
        // profile — BEFORE it asks tmux for anything, and only then fails
        // against `tmuxWindowID == ""`. A test that read the error string alone
        // would go green against exactly that bug.
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(RowFingerprint(after) == before,
                "a refused in-place swap still committed a new identity to the holder row")
        // The other half a return value cannot see: the graceful interrupt that
        // precedes the respawn addresses `tmuxPaneID == ""`, so the real
        // process is never interrupted while the row is being told it was.
        #expect(recorded.snapshot().isEmpty,
                "the in-place swap reached tmux for a holder row: \(recorded.snapshot())")
    }

    @Test("an in-place profile swap still respawns an identical tmux row")
    func inPlaceSwapStillActsOnTmuxRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        let before = RowFingerprint(terminal)

        let response = await router(db, tmux: tmux).handle(try RPCRequest(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminal.id, newProfileID: nil, mode: .inPlace)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.sessionIncarnationID != before.sessionIncarnationID,
                "the tmux leg must still commit a replacement incarnation")
        #expect(recorded.snapshot().contains { $0.contains("respawn-window") },
                "the tmux leg must still respawn its window: \(recorded.snapshot())")
    }

    // MARK: - Gate 5: terminal.delete — the one that acts

    @Test("delete disposes a holder row's holder instead of killing a tmux window")
    func deleteDisposesHolderInsteadOfKillingAWindow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        // `childPID: 0` deliberately. It is the one value `HolderRegistry`'s
        // disposal refuses to signal, and every other value a fixture could
        // name is a pid this shared box may really be running. What is under
        // test here is that the router hands the row to `abandon` at all; the
        // `forget`-then-kill inside it is the registry's own contract, covered
        // by the suites that run a real holder.
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .holder, childPID: 0)
        let registry = holderRegistry(listing: [terminal])
        // Arm the registry with a fact only `abandon` clears. No holder answers
        // at the derived rendezvous, so the startup sweep records the session as
        // having ended with an unknown status — and that recorded status is what
        // separates "the row went away" from "the holder was disposed of".
        await registry.adoptAll()
        let armed = await registry.lastKnownStatus(for: terminal.id)
        #expect(armed == .exitedStatusUnknown, "the fixture never armed the observable")

        let router = router(db, tmux: tmux)
        router.holderRegistry = registry
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(try await db.terminals.get(id: terminal.id) == nil)
        let disposed = await registry.lastKnownStatus(for: terminal.id)
        #expect(disposed == nil,
                "delete removed the row without disposing of its holder, so the holder, its child and its rendezvous files are now owned by nothing")
        // The mirror of the assertion above: the tmux branch is not merely
        // useless for this row, taking it is what leaves the holder behind.
        #expect(recorded.snapshot().isEmpty,
                "delete reached tmux for a holder row: \(recorded.snapshot())")
    }

    @Test("delete still kills an identical tmux row's window")
    func deleteStillKillsTmuxWindow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let recorded = RecordedTmuxArgs()
        let tmux = deadWindowTmux(recorded)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }
        let terminal = try await seedClaudeTerminal(
            db, worktreeID: wt.id, transport: .tmux)
        // Wired in and listing nothing, so an inverted transport comparison
        // would reach a registry that has never heard of this row rather than a
        // nil that would have made the branch unreachable either way.
        let registry = holderRegistry(listing: [])
        let router = router(db, tmux: tmux)
        router.holderRegistry = registry

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id)))

        #expect(response.success, "error: \(response.error ?? "nil")")
        #expect(try await db.terminals.get(id: terminal.id) == nil)
        let argv = recorded.snapshot()
        #expect(argv.contains { $0.contains("kill-window") && $0.contains("@7") },
                "the tmux leg must still kill its own window: \(argv)")
    }
}
