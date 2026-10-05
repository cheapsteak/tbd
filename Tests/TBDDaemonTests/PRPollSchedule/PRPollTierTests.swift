import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("PRPollTier")
struct PRPollTierTests {
    private func interval(_ s: PRPollSubject, active: Bool) -> Duration? {
        PRPollTiers.slot(for: s, active: active)?.interval
    }
    private func tier(_ s: PRPollSubject, active: Bool) -> PRPollTier? {
        PRPollTiers.slot(for: s, active: active)?.tier
    }

    @Test func checksRunningIgnoresActivity() {
        #expect(interval(.pr(.pending), active: true) == .seconds(60))
        #expect(interval(.pr(.pending), active: false) == .seconds(60))
        #expect(tier(.pr(.pending), active: false) == .checksRunning)
    }

    @Test(arguments: [PRMergeableState.blocked, .changesRequested, .draft, .checksFailed, .mergeable])
    func waitingOnPeopleFollowsActivity(_ state: PRMergeableState) {
        #expect(interval(.pr(state), active: true) == .seconds(120))
        #expect(interval(.pr(state), active: false) == .seconds(360))
        #expect(tier(.pr(state), active: true) == .waiting)
    }

    @Test func neverObservedBindingIsTrackedOnTheWaitingTier() {
        #expect(tier(.pr(nil), active: false) == .waiting)
        #expect(interval(.pr(nil), active: false) == .seconds(360))
    }

    @Test func mergedYieldsNoInterval() {
        #expect(PRPollTiers.slot(for: .pr(.merged), active: true) == nil)
        #expect(PRPollTiers.slot(for: .pr(.merged), active: false) == nil)
    }

    @Test func closedYieldsAnIntervalOnlyWhenActive() {
        #expect(PRPollTiers.slot(for: .pr(.closed), active: true)
                == PRPollSlot(tier: .closedDiscovery, interval: .seconds(1800)))
        #expect(PRPollTiers.slot(for: .pr(.closed), active: false) == nil)
    }

    @Test func discoveryFollowsActivity() {
        #expect(PRPollTiers.slot(for: .noPR, active: true)
                == PRPollSlot(tier: .discovery, interval: .seconds(600)))
        #expect(PRPollTiers.slot(for: .noPR, active: false)
                == PRPollSlot(tier: .discovery, interval: .seconds(3600)))
    }

    @Test func onlyWaitingAndDiscoveryTiersStretch() {
        #expect(!PRPollTiers.isStretchable(.checksRunning))
        #expect(PRPollTiers.isStretchable(.waiting))
        #expect(PRPollTiers.isStretchable(.closedDiscovery))
        #expect(PRPollTiers.isStretchable(.discovery))
    }

    @Test func pointsPerTier() {
        for tier in [PRPollTier.checksRunning, .waiting, .discovery, .closedDiscovery] {
            #expect(PRPollTiers.points(for: tier) == 1)   // spec: 1 point per item, an upper bound
        }
    }

    @Test func boundsMatchTheSpec() {
        #expect(PRPollTiers.fastTierCapacity == 10)
        #expect(PRPollTiers.fastTierOverflowInterval == .seconds(120))
        #expect(PRPollTiers.maxStretchedInterval == .seconds(3600))
        #expect(PRPollTiers.activityWindow == 1800)
    }
}
