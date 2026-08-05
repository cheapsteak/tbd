import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// A `ClaudeProfileConfigDirManager` pointed at fresh temp dirs so nothing
/// touches the developer's real `~/.claude` (mirrors HibernationCoordinatorTests).
private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-authib-claude-\(UUID().uuidString)", isDirectory: true)
    return ClaudeProfileConfigDirManager(
        baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
        hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true)
    )
}

@Suite("AutoHibernateOnMergeCoordinator")
struct AutoHibernateOnMergeCoordinatorTests {

    /// In-memory DB + coordinator + a repo + one active worktree with a single
    /// idle Claude terminal. Returns the pieces each test flips.
    private func makeDeps(
        activityState: TerminalActivityState = .idle,
        keepWarm: Bool = false,
        sessionID: String? = "sess-1",
        kind: TerminalKind? = .claude,
        status: WorktreeStatus = .active
    ) async throws -> (AutoHibernateOnMergeCoordinator, TBDDatabase, wtID: UUID, terminalID: UUID) {
        let db = try TBDDatabase(inMemory: true)
        let subs = StateSubscriptionManager()
        let hibernation = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            subscriptions: subs, configDirManager: isolatedConfigDirManager(), actuationLog: makeTestActuationLog())
        let coord = AutoHibernateOnMergeCoordinator(
            db: db, hibernation: hibernation, subscriptions: subs)

        let repo = try await db.repos.create(
            path: "/tmp/repoAH-\(UUID().uuidString)", displayName: "repoAH", defaultBranch: "main")
        let wt = try await db.worktrees.create(repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/repoAH/w-\(UUID().uuidString)", tmuxServer: "s")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", claudeSessionID: sessionID, kind: kind)
        if activityState != .unknown {
            try await db.terminals.setActivityState(id: terminal.id, activityState: activityState)
        }
        if keepWarm {
            try await db.terminals.setKeepWarm(id: terminal.id, keepWarm: true)
        }
        if status != .active {
            try await db.worktrees.updateStatus(id: wt.id, status: status)
        }
        return (coord, db, wt.id, terminal.id)
    }

    // MARK: - Feature off / on matrix

    @Test func featureOffDoesNotPark() async throws {
        // worktree override nil + global default false → not armed → no park.
        let (coord, db, wtID, terminalID) = try await makeDeps()
        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 1)
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    @Test func globalDefaultTrueOverrideNilParks() async throws {
        let (coord, db, wtID, terminalID) = try await makeDeps()
        try await db.config.setAutoHibernateOnMergeDefault(true)
        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 2)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt != nil)
        #expect(after?.hibernateReason == .merged)
    }

    @Test func overrideFalseBeatsGlobalTrue() async throws {
        let (coord, db, wtID, terminalID) = try await makeDeps()
        try await db.config.setAutoHibernateOnMergeDefault(true)
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: false)
        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 3)
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    @Test func overrideTrueBeatsGlobalFalse() async throws {
        let (coord, db, wtID, terminalID) = try await makeDeps()
        // global default stays false; worktree override on.
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)
        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 4)
        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt != nil)
        #expect(after?.hibernateReason == .merged)
    }

    // MARK: - Safety rails hold even when armed

    @Test func keepWarmNotParkedWhenArmed() async throws {
        // Merge-park HONORS keep-warm (unlike manual hibernate).
        let (coord, db, wtID, terminalID) = try await makeDeps(keepWarm: true)
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)
        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 5)
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    @Test func workingTerminalNotParkedWhenArmed() async throws {
        let (coord, db, wtID, terminalID) = try await makeDeps(activityState: .working)
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)
        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 6)
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    // MARK: - Worktree status gate

    @Test func nonActiveWorktreeIsNoOp() async throws {
        let (coord, db, wtID, terminalID) = try await makeDeps(status: .archived)
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)
        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 7)
        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    // MARK: - Notification only when something parked

    @Test func notificationCreatedWhenAtLeastOneParked() async throws {
        let (coord, db, wtID, _) = try await makeDeps()
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)
        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 8)
        let notifications = try await db.notifications.unread(worktreeID: wtID)
        #expect(notifications.count == 1)
        #expect(notifications.first?.type == .taskComplete)
        #expect(notifications.first?.message?.contains("#8") == true)
        // Singular "session" for exactly one parked terminal.
        #expect(notifications.first?.message?.contains("1 session") == true)
    }

    @Test func noNotificationWhenZeroParked() async throws {
        // Armed, but the single terminal is keep-warm → 0 parked → no notification.
        let (coord, db, wtID, _) = try await makeDeps(keepWarm: true)
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)
        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 9)
        let notifications = try await db.notifications.unread(worktreeID: wtID)
        #expect(notifications.isEmpty)
    }

    // MARK: - Already-parked terminal is untouched (idempotent late/repeat merge)

    /// A merged transition fired against a worktree whose terminal is ALREADY
    /// parked must be a silent no-op: `hibernateForMerge` returns
    /// `.alreadyHibernated`, so the existing `hibernatedAt` / `hibernateReason`
    /// are NOT overwritten and — because `parked == 0` — no notification is
    /// created. This pins the "a repeat/late merge event can't stomp a manual
    /// park" property: merged transitions re-fire after every daemon restart
    /// while the PR stays merged.
    @Test func alreadyParkedTerminalNotOverwrittenAndNoNotification() async throws {
        let (coord, db, wtID, terminalID) = try await makeDeps()
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)

        // Park the terminal FIRST with a distinctive manual reason + old stamp.
        let originalStamp = Date(timeIntervalSince1970: 1_000_000)
        try await db.terminals.setHibernated(
            id: terminalID, sessionID: "sess-1", snapshot: nil,
            reason: .manual, at: originalStamp)

        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 10)

        let after = try await db.terminals.get(id: terminalID)
        // The manual park survives — reason and timestamp are both unchanged
        // (NOT re-stamped to `.merged` / now).
        #expect(after?.hibernateReason == .manual)
        #expect(after?.hibernatedAt == originalStamp)
        // parked == 0 → no summary notification.
        let notifications = try await db.notifications.unread(worktreeID: wtID)
        #expect(notifications.isEmpty)
    }

    // MARK: - Notification pluralization (plural branch)

    /// Two parkable Claude terminals on one armed worktree → BOTH park with
    /// `.merged`, and exactly ONE summary notification is created whose message
    /// uses the plural "sessions" ("Hibernated 2 sessions …"). Every other test
    /// parks a single terminal, so this is the only cover for the
    /// `parked == 1 ? "session" : "sessions"` plural arm.
    @Test func twoParkedTerminalsPluralNotification() async throws {
        let (coord, db, wtID, terminalID1) = try await makeDeps()
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)

        // Add a SECOND idle Claude terminal on the same worktree.
        let terminal2 = try await db.terminals.create(
            worktreeID: wtID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude2", claudeSessionID: "sess-2", kind: .claude)
        try await db.terminals.setActivityState(id: terminal2.id, activityState: .idle)

        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 11)

        // Both terminals parked with the merge reason.
        let after1 = try await db.terminals.get(id: terminalID1)
        let after2 = try await db.terminals.get(id: terminal2.id)
        #expect(after1?.hibernatedAt != nil)
        #expect(after1?.hibernateReason == .merged)
        #expect(after2?.hibernatedAt != nil)
        #expect(after2?.hibernateReason == .merged)

        // Exactly one summary notification, using the plural wording.
        let notifications = try await db.notifications.unread(worktreeID: wtID)
        #expect(notifications.count == 1)
        #expect(notifications.first?.type == .taskComplete)
        #expect(notifications.first?.message?.contains("2 sessions") == true)
        #expect(notifications.first?.message?.contains("#11") == true)
    }
}
