import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("RemoteTipTracker")
struct RemoteTipTrackerTests {
    @Test func firstSightingIsABaselineNotAChange() {
        var w = RemoteTipWatch()
        #expect(w.observe(worktreeID: UUID(), remoteTip: "aaa") == false)
    }

    @Test func aChangeFiresExactlyOnce() {
        var w = RemoteTipWatch(); let id = UUID()
        _ = w.observe(worktreeID: id, remoteTip: "aaa")
        #expect(w.observe(worktreeID: id, remoteTip: "bbb") == true)
        #expect(w.observe(worktreeID: id, remoteTip: "bbb") == false)
        #expect(w.observe(worktreeID: id, remoteTip: "ccc") == true)
    }

    @Test func aLocalCommitWithNoPushDoesNotFire() {
        // The remote-tracking tip is what is observed; a local commit leaves it unchanged.
        var w = RemoteTipWatch(); let id = UUID()
        _ = w.observe(worktreeID: id, remoteTip: "aaa")
        #expect(w.observe(worktreeID: id, remoteTip: "aaa") == false)
    }

    /// No `origin/<branch>` ref (never pushed, or pushes elsewhere).
    @Test func aMissingRemoteTipIsNoSignal() {
        var w = RemoteTipWatch(); let id = UUID()
        #expect(w.observe(worktreeID: id, remoteTip: nil) == false)
        _ = w.observe(worktreeID: id, remoteTip: "aaa")
        #expect(w.observe(worktreeID: id, remoteTip: nil) == false)
        #expect(w.observe(worktreeID: id, remoteTip: "aaa") == false)
    }

    @Test func firstPushAfterNoRemoteRefFires() {
        // A branch's first push creates origin/<branch>: that is a push, so it fires,
        // unless the watch never saw the worktree before (a restart baseline).
        var w = RemoteTipWatch(); let id = UUID()
        _ = w.observe(worktreeID: id, remoteTip: nil)
        #expect(w.observe(worktreeID: id, remoteTip: "aaa") == true)
    }

    @Test func retainForgetsSoAReturningWorktreeIsABaselineAgain() {
        var w = RemoteTipWatch(); let id = UUID()
        _ = w.observe(worktreeID: id, remoteTip: "aaa")
        w.retain([])
        #expect(w.observe(worktreeID: id, remoteTip: "bbb") == false)
    }

    @Test func trackerCallsBackOnMove() async {
        let t = RemoteTipTracker(); let id = UUID()
        let box = MovedBox()
        await t.setOnMoved { await box.add($0) }
        await t.observe(worktreeID: id, remoteTip: "aaa")
        await t.observe(worktreeID: id, remoteTip: "bbb")
        #expect(await box.ids == [id])
    }

    @Test func retainIsScopedPerRepo() async {
        let t = RemoteTipTracker(); let a = UUID(), b = UUID()
        let box = MovedBox()
        await t.setOnMoved { await box.add($0) }
        let repoA = UUID(), repoB = UUID()
        await t.retain(repoID: repoA, worktreeIDs: [a])
        await t.observe(worktreeID: a, remoteTip: "aaa")
        // Repo B's sweep must not evict repo A's baseline.
        await t.retain(repoID: repoB, worktreeIDs: [b])
        await t.observe(worktreeID: b, remoteTip: "xxx")
        await t.observe(worktreeID: a, remoteTip: "bbb")
        #expect(await box.ids == [a])
    }
}

private actor MovedBox { var ids: [UUID] = []; func add(_ id: UUID) { ids.append(id) } }
