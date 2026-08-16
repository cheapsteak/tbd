import Foundation
import Testing
@testable import TBDDaemonLib

/// Tier 1. The tracker is fed by the sweep's existing `for-each-ref` map, so
/// its whole job is remembering when a tip first arrived — no git, no
/// subprocess, and none of these tests spawns one.
@Suite("BranchTipTracker")
struct BranchTipTrackerTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func anUnchangedTipKeepsItsOriginalStamp() async {
        let tracker = BranchTipTracker()
        let repo = UUID()
        let wt = UUID()
        let firstStill = t0.addingTimeInterval(600)

        await tracker.record(repoID: repo, worktreeID: wt, branchTip: "abc123", at: t0)
        await tracker.record(repoID: repo, worktreeID: wt, branchTip: "abc123", at: firstStill)
        await tracker.record(
            repoID: repo, worktreeID: wt, branchTip: "abc123", at: t0.addingTimeInterval(5_400))

        // Refreshing the stamp on every sweep would report every still branch
        // as having just moved — the one bug this type exists to avoid.
        #expect(await tracker.unchangedSince(repoID: repo, worktreeID: wt) == firstStill)
    }

    /// The **first** sighting establishes what the tip is, not how long it has
    /// been that. Stamping it with the read would tell a supervisor that a
    /// branch untouched for three days has been unchanged only since thirty
    /// seconds after the daemon restarted — which disarms every stall threshold
    /// in the fleet for hours after every restart, while looking like an answer.
    @Test func aFirstSightingEstablishesNoStillnessAtAll() async {
        let tracker = BranchTipTracker()
        let repo = UUID()
        let wt = UUID()

        await tracker.record(repoID: repo, worktreeID: wt, branchTip: "abc123", at: t0)

        #expect(await tracker.unchangedSince(repoID: repo, worktreeID: wt) == nil,
                "one sample cannot measure a duration, and must not pretend to")
    }

    @Test func stillnessIsStampedAtTheSecondSighting() async {
        let tracker = BranchTipTracker()
        let repo = UUID()
        let wt = UUID()
        let secondSweep = t0.addingTimeInterval(30)

        await tracker.record(repoID: repo, worktreeID: wt, branchTip: "abc123", at: t0)
        await tracker.record(repoID: repo, worktreeID: wt, branchTip: "abc123", at: secondSweep)

        // Understated by one sweep interval, deliberately: understating costs a
        // late stall report, overstating disarms the detector.
        #expect(await tracker.unchangedSince(repoID: repo, worktreeID: wt) == secondSweep)
    }

    @Test func aNewTipRestartsUnestablished() async {
        let tracker = BranchTipTracker()
        let repo = UUID()
        let wt = UUID()
        await tracker.record(repoID: repo, worktreeID: wt, branchTip: "abc123", at: t0)
        await tracker.record(
            repoID: repo, worktreeID: wt, branchTip: "abc123", at: t0.addingTimeInterval(30))
        let committedAt = t0.addingTimeInterval(900)
        await tracker.record(repoID: repo, worktreeID: wt, branchTip: "def456", at: committedAt)

        // A tip that just moved is not still; it is a first sighting again.
        #expect(await tracker.unchangedSince(repoID: repo, worktreeID: wt) == nil)

        let nextSweep = committedAt.addingTimeInterval(30)
        await tracker.record(repoID: repo, worktreeID: wt, branchTip: "def456", at: nextSweep)
        #expect(await tracker.unchangedSince(repoID: repo, worktreeID: wt) == nextSweep)
    }

    @Test func anUnobservedWorktreeIsNilNotUnchanged() async {
        let tracker = BranchTipTracker()
        // Ignorance must not be able to look like stillness.
        #expect(await tracker.unchangedSince(repoID: UUID(), worktreeID: UUID()) == nil)
    }

    @Test func retainIsScopedToOneRepo() async {
        let tracker = BranchTipTracker()
        let repoA = UUID()
        let repoB = UUID()
        let wtA = UUID()
        let wtB = UUID()
        for at in [t0, t0.addingTimeInterval(30)] {
            await tracker.record(repoID: repoA, worktreeID: wtA, branchTip: "a", at: at)
            await tracker.record(repoID: repoB, worktreeID: wtB, branchTip: "b", at: at)
        }

        // Repo B's sweep must not evict repo A's entries — otherwise the stamps
        // would restart on every sweep of a multi-repo install.
        await tracker.retain(repoID: repoB, worktreeIDs: [])
        #expect(await tracker.unchangedSince(repoID: repoA, worktreeID: wtA)
                == t0.addingTimeInterval(30))
        #expect(await tracker.unchangedSince(repoID: repoB, worktreeID: wtB) == nil)
    }

    @Test func retainDropsWorktreesNoLongerInTheSweep() async {
        let tracker = BranchTipTracker()
        let repo = UUID()
        let kept = UUID()
        let dropped = UUID()
        for at in [t0, t0.addingTimeInterval(30)] {
            await tracker.record(repoID: repo, worktreeID: kept, branchTip: "a", at: at)
            await tracker.record(repoID: repo, worktreeID: dropped, branchTip: "b", at: at)
        }
        await tracker.retain(repoID: repo, worktreeIDs: [kept])
        #expect(await tracker.unchangedSince(repoID: repo, worktreeID: kept)
                == t0.addingTimeInterval(30))
        #expect(await tracker.unchangedSince(repoID: repo, worktreeID: dropped) == nil)
    }
}
