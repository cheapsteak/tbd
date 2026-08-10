import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The multi-PR merge rule: auto-archive and auto-hibernate fire when EVERY
/// non-detached binding is terminal and at least one is merged, once per
/// false→true transition.
///
/// Tier 1 — in-memory DB, no git, no `gh`, no tmux, no clock.
@Suite("All-resolved merge trigger")
struct AllResolvedTriggerTests {

    @Test("one binding merged fires the transition")
    func singleMergedFires() async throws {
        let harness = try await MergeTriggerHarness()
        try await harness.bind(412, state: .merged)
        await harness.poll()
        #expect(await harness.firedWorktreeIDs == [harness.worktreeID])
    }

    @Test("one of three merged does not fire")
    func partialDoesNotFire() async throws {
        let harness = try await MergeTriggerHarness()
        try await harness.bind(412, state: .merged)
        try await harness.bind(413, state: .mergeable)
        try await harness.bind(414, state: .draft)
        await harness.poll()
        #expect(await harness.firedWorktreeIDs.isEmpty)
    }

    @Test("all terminal with one merged fires")
    func allTerminalFires() async throws {
        let harness = try await MergeTriggerHarness()
        try await harness.bind(412, state: .merged)
        try await harness.bind(413, state: .closed)
        await harness.poll()
        #expect(await harness.firedWorktreeIDs == [harness.worktreeID])
    }

    @Test("all closed with none merged does not fire")
    func allClosedDoesNotFire() async throws {
        let harness = try await MergeTriggerHarness()
        try await harness.bind(412, state: .closed)
        try await harness.bind(413, state: .closed)
        await harness.poll()
        #expect(await harness.firedWorktreeIDs.isEmpty)
    }

    @Test("detaching the straggler unblocks the trigger")
    func detachUnblocks() async throws {
        let harness = try await MergeTriggerHarness()
        try await harness.bind(412, state: .merged)
        try await harness.bind(413, state: .mergeable)
        await harness.poll()
        #expect(await harness.firedWorktreeIDs.isEmpty)

        try await harness.detach(413)
        await harness.poll()
        #expect(await harness.firedWorktreeIDs == [harness.worktreeID])
    }

    @Test("the transition fires once, not on every subsequent poll")
    func firesOnce() async throws {
        let harness = try await MergeTriggerHarness()
        try await harness.bind(412, state: .merged)
        await harness.poll()
        await harness.poll()
        #expect(await harness.firedWorktreeIDs.count == 1)
    }

    @Test("a merge observed after every binding is detached still fires")
    func observedMergeSurvivesAnEarlierEvaluateFire() async throws {
        // The two entry points used to share one once-only set, so an `evaluate`
        // fire suppressed `observedMerge` forever. Nothing re-armed it: with
        // every binding detached the poll's grouping no longer contains the
        // worktree, so `evaluate` is never called and its re-arm never runs.
        let harness = try await MergeTriggerHarness()
        try await harness.bind(412, state: .merged)
        await harness.poll()
        #expect(await harness.firedPRNumbers == [412])

        try await harness.detach(412)
        await harness.poll()   // no live bindings: production skips evaluate entirely

        await harness.observeMerge(500)
        #expect(await harness.firedPRNumbers == [412, 500])
    }

    @Test("the un-bound fallback fires once per rising edge, not per observation")
    func observedMergeFiresOnce() async throws {
        let harness = try await MergeTriggerHarness()
        await harness.observeMerge(412)
        await harness.observeMerge(412)
        #expect(await harness.firedPRNumbers == [412])
    }

    @Test("the un-bound fallback re-arms once the worktree is bound again")
    func observedMergeReArmsWhenBound() async throws {
        let harness = try await MergeTriggerHarness()
        await harness.observeMerge(412)
        #expect(await harness.firedPRNumbers == [412])

        // A binding exists: `evaluate` owns the worktree now, so the fallback
        // stands down — and is armed again for the day everything is detached.
        try await harness.bind(413, state: .mergeable)
        await harness.observeMerge(413)
        #expect(await harness.firedPRNumbers == [412])

        try await harness.detach(413)
        await harness.observeMerge(414)
        #expect(await harness.firedPRNumbers == [412, 414])
    }

    @Test("a worktree with live bindings is never fired by the un-bound fallback")
    func observedMergeIgnoresBoundWorktrees() async throws {
        let harness = try await MergeTriggerHarness()
        try await harness.bind(412, state: .merged)
        try await harness.bind(413, state: .mergeable)
        await harness.observeMerge(412)
        #expect(await harness.firedWorktreeIDs.isEmpty)
    }
}

/// An in-memory database, one worktree, its binding store, and an
/// `AllResolvedMergeTrigger` whose fan-out is replaced by a recorder — so a test
/// asserts *whether the transition fired*, without archiving or parking
/// anything. The fan-out itself (archive supersedes hibernate) is the subject of
/// `MergedTransitionPrecedenceTests` and is deliberately not re-tested here.
final class MergeTriggerHarness {
    let db: TBDDatabase
    let worktreeID: UUID
    let trigger: AllResolvedMergeTrigger
    private let recorder: FiredTransitionRecorder

    init() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/repoART-\(UUID().uuidString)", displayName: "repoART", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/repoART/w-\(UUID().uuidString)", tmuxServer: "s")
        let recorder = FiredTransitionRecorder()
        self.db = db
        self.worktreeID = worktree.id
        self.recorder = recorder
        self.trigger = AllResolvedMergeTrigger { worktreeID, prNumber in
            await recorder.record(worktreeID: worktreeID, prNumber: prNumber)
        }
    }

    var firedWorktreeIDs: [UUID] {
        get async { await recorder.fired.map(\.worktreeID) }
    }

    var firedPRNumbers: [Int] {
        get async { await recorder.fired.map(\.prNumber) }
    }

    func bind(_ number: Int, state: PRMergeableState) async throws {
        let url = "https://github.com/acme/acme-prod/pull/\(number)"
        _ = try await db.prBindings.upsert(PRBinding(
            worktreeID: worktreeID, owner: "acme", repo: "acme-prod",
            number: number, url: url,
            status: PRStatus(number: number, url: url, state: state),
            source: .hook))
    }

    func detach(_ number: Int) async throws {
        let key = PRBinding(
            worktreeID: worktreeID, owner: "acme", repo: "acme-prod", number: number,
            url: "https://github.com/acme/acme-prod/pull/\(number)", source: .manual).identityKey
        _ = try await db.prBindings.setDetached(
            worktreeID: worktreeID, identityKey: key, detached: true)
    }

    /// One poll: read the worktree's live bindings and evaluate the trigger over
    /// them, exactly as `RPCRouter.refreshBindingStatuses` does after a refresh
    /// — including the early return. A worktree with no live bindings is not in
    /// the poll's grouping at all, so `evaluate` is never called for it, which
    /// is precisely why the fallback's once-only guard cannot be re-armed from
    /// there.
    func poll() async {
        let bindings = (try? await db.prBindings.list(worktreeID: worktreeID)) ?? []
        guard !bindings.isEmpty else { return }
        await trigger.evaluate(worktreeID: worktreeID, bindings: bindings)
    }

    /// The un-bound fallback, driven the way `PRStatusManager.onMergedTransition`
    /// drives it in `Daemon.swift`: the worktree's live bindings are read fresh
    /// and handed along with the observed merge.
    func observeMerge(_ prNumber: Int) async {
        let bindings = (try? await db.prBindings.list(worktreeID: worktreeID)) ?? []
        await trigger.observedMerge(worktreeID: worktreeID, prNumber: prNumber,
                                    bindings: bindings)
    }
}

/// Records every fan-out the trigger performed, in order.
actor FiredTransitionRecorder {
    private(set) var fired: [(worktreeID: UUID, prNumber: Int)] = []

    func record(worktreeID: UUID, prNumber: Int) {
        fired.append((worktreeID, prNumber))
    }
}
