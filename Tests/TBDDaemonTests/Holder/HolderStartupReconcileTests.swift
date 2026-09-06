import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// What startup reconciliation does with a PARKED holder-backed row.
///
/// `reconcileOnStartup` runs before `HolderRegistry.adoptAll`, so this arm must
/// reach a verdict without the registry: at that moment it holds no readers and
/// remembers no statuses, and asking it would answer "gone" for every session on
/// the machine while looking authoritative. The recorded child pid, read through
/// `ProcessIdentityCheck`, is the only ground truth available that early — which
/// is why every case here is scripted on a `FakeProcessSignaller` rather than
/// arranged with real processes.
///
/// Tier 1: no tmux server, no spawned process, no `~/tbd`.
@Suite("Parked holder rows at startup")
struct HolderStartupReconcileTests {

    /// The shape a holder's job presents: the login shell the holder forked, or
    /// the agent binary that shell `exec`d itself into.
    private static let holderChildCommand = "/bin/zsh -i -l -c claude"

    private func seedWorktree(_ db: TBDDatabase) async throws -> (Worktree, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-holderstartup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = try await db.repos.create(
            path: dir.path, displayName: "acme", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: dir.path,
            tmuxServer: "tbd-holderstartup")
        return (wt, dir)
    }

    private func coordinator(
        _ db: TBDDatabase, signaller: FakeProcessSignaller
    ) -> HibernationCoordinator {
        HibernationCoordinator(
            db: db,
            // Every window dead, which is what a holder row's empty coordinate
            // gets from a real server. The holder branch must not consult it at
            // all, and the tmux parity test below relies on this answer.
            tmux: TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true }),
            signaller: signaller,
            actuationLog: makeTestActuationLog())
    }

    /// A parked holder row that names a child pid, with the identity anchor an
    /// hour behind the row's own `createdAt` — the shape a woken session has,
    /// and the one that tells the two anchors apart.
    private func seedParkedHolderRow(
        _ db: TBDDatabase, worktreeID: UUID, childStartedAt: Date?, childPID: Int32
    ) async throws -> Terminal {
        let terminal = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-startup",
            kind: .claude, transport: .holder,
            holderPID: 8101, childPID: childPID,
            holderChildStartedAt: childStartedAt)
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-startup", reason: .auto)
        return try #require(try await db.terminals.get(id: terminal.id))
    }

    /// The daemon died mid-park: the intent landed, the child never went. The
    /// row is un-parked so adoption can pick the live session up.
    @Test("a parked row whose child is verifiably alive is un-parked")
    func aLiveChildUnparksItsRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }

        let childStartedAt = Date().addingTimeInterval(-3600)
        let signaller = FakeProcessSignaller()
        signaller.behaviors[8102] = .init(aliveInitially: true)
        signaller.startTimes[8102] = childStartedAt
        signaller.cmdlines[8102] = Self.holderChildCommand

        let terminal = try await seedParkedHolderRow(
            db, worktreeID: wt.id, childStartedAt: childStartedAt, childPID: 8102)
        #expect(terminal.isParked)

        await coordinator(db, signaller: signaller).reconcileOnStartup()

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(!after.isParked, "a parked row whose child is alive was left parked")
        #expect(after.childPID == 8102, "un-parking must not forget the live child")
        #expect(after.holderPID == 8101)
    }

    /// The anchor is the child's start, not the row's birthday — and an hour of
    /// park is far outside `defaultHolderIdentityWindow`, so a reconciler that
    /// still anchored on `createdAt` would read this same live child as a
    /// stranger and leave the row parked over it.
    @Test("the identity anchor is the recorded child start, not the row's createdAt")
    func theAnchorIsTheChildStart() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }

        let childStartedAt = Date().addingTimeInterval(-3600)
        let signaller = FakeProcessSignaller()
        signaller.behaviors[8102] = .init(aliveInitially: true)
        signaller.startTimes[8102] = childStartedAt
        signaller.cmdlines[8102] = Self.holderChildCommand

        // Same scripted process, same row — except the row records no anchor,
        // so `createdAt` (now) is used and the hour-old child reads as a
        // different process.
        let anchored = try await seedParkedHolderRow(
            db, worktreeID: wt.id, childStartedAt: childStartedAt, childPID: 8102)
        let unanchored = try await seedParkedHolderRow(
            db, worktreeID: wt.id, childStartedAt: nil, childPID: 8102)

        await coordinator(db, signaller: signaller).reconcileOnStartup()

        #expect(try await db.terminals.get(id: anchored.id)?.isParked == false)
        #expect(
            try await db.terminals.get(id: unanchored.id)?.isParked == true,
            "a start-time mismatch is an uncertain identity and must move nothing")
    }

    /// The child is gone but the row still names it. Clear the pids so nothing
    /// later signals a number the kernel has already handed to somebody else.
    @Test("a parked row whose child is gone keeps its park and loses its pids")
    func aDeadChildLosesItsPids() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }

        let signaller = FakeProcessSignaller()
        signaller.behaviors[8102] = .init(aliveInitially: false)

        let terminal = try await seedParkedHolderRow(
            db, worktreeID: wt.id, childStartedAt: Date().addingTimeInterval(-3600),
            childPID: 8102)

        await coordinator(db, signaller: signaller).reconcileOnStartup()

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.isParked, "a parked row whose child is gone was un-parked")
        #expect(after.childPID == nil)
        #expect(after.holderPID == nil)
        #expect(after.holderChildStartedAt == nil)
    }

    /// Every verdict but `.same` and `.notRunning` is an uncertain identity,
    /// and an uncertain identity is not evidence in either direction. A missing
    /// start time is how that case is stated.
    @Test("an unreadable child identity moves nothing")
    func anUncertainIdentityMovesNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }

        let signaller = FakeProcessSignaller()
        signaller.behaviors[8102] = .init(aliveInitially: true)
        // No `startTimes` entry: the start time could not be read.

        let terminal = try await seedParkedHolderRow(
            db, worktreeID: wt.id, childStartedAt: Date(), childPID: 8102)

        await coordinator(db, signaller: signaller).reconcileOnStartup()

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.isParked)
        #expect(after.childPID == 8102)
        #expect(after.holderPID == 8101)
    }

    /// The tmux branch is untouched: its evidence is the window and the pane,
    /// and a dead window leaves a parked row exactly as it found it — whatever
    /// the process table says about pids the row does not carry.
    @Test("a parked tmux row is judged by tmux, not by the process table")
    func aParkedTmuxRowIsUnaffected() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (wt, dir) = try await seedWorktree(db)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Scripted as alive with a perfect identity. If the holder branch ever
        // stopped discriminating on transport, this row would be un-parked.
        let signaller = FakeProcessSignaller()
        signaller.behaviors[8102] = .init(aliveInitially: true)
        signaller.startTimes[8102] = Date()
        signaller.cmdlines[8102] = Self.holderChildCommand

        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@7", tmuxPaneID: "%7",
            label: TerminalLabel.claudeCode, claudeSessionID: "sess-tmux", kind: .claude)
        try await db.terminals.setHibernated(
            id: terminal.id, sessionID: "sess-tmux", reason: .auto)

        await coordinator(db, signaller: signaller).reconcileOnStartup()

        #expect(
            try await db.terminals.get(id: terminal.id)?.isParked == true,
            "the holder branch judged a tmux row")
    }
}
