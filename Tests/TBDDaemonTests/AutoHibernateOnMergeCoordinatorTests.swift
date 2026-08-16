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
        status: WorktreeStatus = .active,
        logPath: String? = nil,
        activityObservedAt: Date? = nil,
        inputTracker: InputActivityTracker? = nil
    ) async throws -> (AutoHibernateOnMergeCoordinator, TBDDatabase, wtID: UUID, terminalID: UUID) {
        let db = try TBDDatabase(inMemory: true)
        let subs = StateSubscriptionManager()
        let hibernation = HibernationCoordinator(
            db: db, tmux: TmuxManager(dryRun: true),
            subscriptions: subs, configDirManager: isolatedConfigDirManager(),
            actuationLog: logPath.map { ActuationLog(path: $0) } ?? makeTestActuationLog())
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
            try await db.terminals.setActivityState(
                id: terminal.id, activityState: activityState, source: .derived,
                observedAt: activityObservedAt ?? Date())
        }
        if let inputTracker {
            // The daemon wires the input router's shared tracker into the
            // coordinator post-construction; tests do the same so keystrokes
            // can be driven through the merge path.
            await hibernation.setInputActivity(inputTracker)
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
        try await db.terminals.setActivityState(id: terminal2.id, activityState: .idle, source: .derived)

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

    // MARK: - Pending typed input (the input veto) on the MERGE path
    //
    // `TmuxManager(dryRun: true)` has no `dryRunCapturePane`, so the backup TUI
    // scrape in `performHibernate` reads an empty pane and never fires: what
    // these four tests exercise is the gate rail alone. Merge-park runs on the
    // daemon's clock now, so this fires unattended — and a park that eats a
    // half-composed prompt is not undone by reverting a commit.

    /// The at-rest instant these tests pin the terminal's observation to.
    private static let atRest = Date(timeIntervalSince1970: 1_700_000_000)

    /// A tracker whose recorded input lands `after` seconds from `atRest`.
    private func tracker(secondsAfterAtRest after: TimeInterval) -> InputActivityTracker {
        InputActivityTracker(now: { Self.atRest.addingTimeInterval(after) })
    }

    @Test func vetoEnabledDoesNotParkSessionWithTypedInput() async throws {
        // Typed into a minute AFTER it came to rest: the keystrokes never went
        // through a turn, so they are still unsent. Armed merge → no park.
        let input = tracker(secondsAfterAtRest: 60)
        let (coord, db, wtID, terminalID) = try await makeDeps(
            activityObservedAt: Self.atRest, inputTracker: input)
        input.recordInput(paneID: "%0")
        try await db.config.setHibernateInputVeto(enabled: true)
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)

        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 20)

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
        // Nothing parked → no summary notification either.
        #expect(try await db.notifications.unread(worktreeID: wtID).isEmpty)
    }

    @Test func vetoEnabledStillParksSessionWithNoPendingInput() async throws {
        // Same flag, input recorded BEFORE the at-rest observation — i.e. it
        // was submitted and the turn that consumed it is what returned the
        // session to rest. Parks exactly as it does today.
        let input = tracker(secondsAfterAtRest: -600)
        let (coord, db, wtID, terminalID) = try await makeDeps(
            activityObservedAt: Self.atRest, inputTracker: input)
        input.recordInput(paneID: "%0")
        try await db.config.setHibernateInputVeto(enabled: true)
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)

        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 21)

        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt != nil)
        #expect(after?.hibernateReason == .merged)
    }

    @Test func vetoDisabledParksDespiteTypedInput() async throws {
        // The flag's OFF branch, with the exact inputs that block above. This
        // is today's behavior, and — since the column defaults to false — what
        // every install that has not opted into the soak still gets.
        let input = tracker(secondsAfterAtRest: 60)
        let (coord, db, wtID, terminalID) = try await makeDeps(
            activityObservedAt: Self.atRest, inputTracker: input)
        input.recordInput(paneID: "%0")
        try await db.config.setHibernateInputVeto(enabled: false)
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)

        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 22)

        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt != nil)
        #expect(after?.hibernateReason == .merged)
    }

    @Test func vetoDisabledParksSessionWithNoPendingInput() async throws {
        // The other half of the OFF branch: no recorded input, flag off. The
        // wiring must not have changed the ordinary merge-park at all.
        let (coord, db, wtID, terminalID) = try await makeDeps(activityObservedAt: Self.atRest)
        try await db.config.setHibernateInputVeto(enabled: false)
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)

        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 23)

        let after = try await db.terminals.get(id: terminalID)
        #expect(after?.hibernatedAt != nil)
        #expect(after?.hibernateReason == .merged)
    }

    @Test func vetoEnabledFailsClosedWhenNoActivityObservationExists() async throws {
        // `.unknown` with no observation stamp (a row written before the
        // provenance columns) plus recorded input: nothing proves the input was
        // ever consumed, so the park is refused rather than guessed.
        let input = tracker(secondsAfterAtRest: 0)
        let (coord, db, wtID, terminalID) = try await makeDeps(
            activityState: .unknown, inputTracker: input)
        input.recordInput(paneID: "%0")
        try await db.config.setHibernateInputVeto(enabled: true)
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)
        #expect(try await db.terminals.get(id: terminalID)?.activityStateObservedAt == nil)

        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 24)

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    @Test func hardRailStillBlocksWithVetoEnabledAndNoPendingInput() async throws {
        // The rails the merge path already had are untouched by the new arm:
        // keep-warm refuses even with the veto on and nothing typed.
        let (coord, db, wtID, terminalID) = try await makeDeps(
            keepWarm: true, activityObservedAt: Self.atRest)
        try await db.config.setHibernateInputVeto(enabled: true)
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)

        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 25)

        #expect(try await db.terminals.get(id: terminalID)?.hibernatedAt == nil)
    }

    // MARK: - The rail's own actuation record

    /// The fan-out is where a per-terminal record can go wrong in both
    /// directions: one row for the whole merge would under-count the sessions
    /// actually acted on, and a row written before the rails would count the
    /// ones that were never touched. So: one request row per PARKED terminal,
    /// each confirmed by exactly one outcome, and none for the refused one.
    @Test func mergeParkWritesOneRequestAndOutcomePerParkedTerminal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-authib-actuation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logPath = directory.appendingPathComponent("actuations.jsonl").path
        defer { try? FileManager.default.removeItem(at: directory) }

        let (coord, db, wtID, parkedID) = try await makeDeps(logPath: logPath)
        try await db.worktrees.setAutoHibernateOnMerge(id: wtID, value: true)

        // A second, keep-warm terminal: armed, but the rails refuse it.
        let keptWarm = try await db.terminals.create(
            worktreeID: wtID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude2", claudeSessionID: "sess-2", kind: .claude)
        try await db.terminals.setActivityState(id: keptWarm.id, activityState: .idle, source: .derived)
        try await db.terminals.setKeepWarm(id: keptWarm.id, keepWarm: true)

        await coord.handleMergedTransition(worktreeID: wtID, prNumber: 12)
        #expect(try await db.terminals.get(id: parkedID)?.hibernatedAt != nil)
        #expect(try await db.terminals.get(id: keptWarm.id)?.hibernatedAt == nil)

        let written = try String(contentsOfFile: logPath, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
        let requests = written.filter { $0["kind"] as? String == "hibernate" }
        #expect(requests.count == 1, "only the terminal the rail actually parked gets a row")
        let request = try #require(requests.first)
        #expect(request["method"] == nil)
        let actor = try #require(request["actor"] as? [String: Any])
        #expect(actor["rail"] as? String == "auto-hibernate-on-merge")
        #expect((request["target"] as? [String: Any])?["terminal"] as? String
            == parkedID.uuidString)

        let outcomes = written.filter { $0["kind"] as? String == "outcome" }
        #expect(outcomes.count == 1)
        #expect(outcomes.first?["confirms"] as? String == request["id"] as? String)
        #expect(outcomes.first?["result"] as? String == "dispatched")
        #expect(written.count == 2, "nothing else is written for a merge fan-out")
    }
}
