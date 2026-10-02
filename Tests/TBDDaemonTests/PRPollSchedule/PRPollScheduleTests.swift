import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("PRPollSchedule")
struct PRPollScheduleTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let run1 = PRPollGovernor.Decision.run(stretch: 1)
    private func key(_ n: Int) -> PRPollKey { PRPollKey(host: "github.com", owner: "acme", repo: "acme-prod", number: n) }
    private func wt(_ id: UUID, active: Bool = true, discoverable: Bool = true,
                    _ bindings: [(Int, PRMergeableState?)] = []) -> PRPollWorktreeFacts {
        PRPollWorktreeFacts(worktreeID: id, active: active, discoverable: discoverable,
                            bindings: bindings.map { PRPollBindingFact(key: key($0.0), state: $0.1) })
    }
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func everythingOpenIsDueAtStartAndMergedNever() {
        let a = UUID(), b = UUID(), c = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(1, .blocked)]), wt(b, [(2, .merged)]), wt(c)], now: t0)
        let due = s.due(at: t0, decision: run1)
        #expect(due.track == [key(1)])
        #expect(due.discover == [c])
        #expect(s.tier(of: .track(key(2))) == nil)
        #expect(s.tier(of: .discover(b)) == nil)
    }

    @Test func itemsFireAtTheirDueTimes() {
        let a = UUID(), b = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(1, .pending)]), wt(b, [(2, .blocked)])], now: t0)
        s.markRan(s.due(at: t0, decision: run1), at: t0)
        #expect(s.due(at: at(59), decision: run1).isEmpty)
        #expect(s.due(at: at(60), decision: run1).track == [key(1)])
        #expect(s.due(at: at(120), decision: run1).track == [key(1), key(2)])
        #expect(s.nextDue(decision: run1) == at(60))
    }

    @Test func aTriggerMovesOneWorktreesItemsWithoutTouchingOthers() {
        let a = UUID(), b = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(1, .blocked)]), wt(b, [(2, .blocked)])], now: t0)
        s.markRan(s.due(at: t0, decision: run1), at: t0)
        s.trigger(worktreeID: a, now: at(10))
        #expect(s.due(at: at(10), decision: run1).track == [key(1)])
    }

    @Test func coincidentItemsAreDueTogether() {
        let a = UUID(), b = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(1, .blocked), (3, .draft)]), wt(b, [(2, .blocked)])], now: t0)
        #expect(s.due(at: t0, decision: run1).track == [key(1), key(2), key(3)])
    }

    @Test func aMergedResultRemovesTheItem() {
        let a = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(1, .pending)])], now: t0)
        s.markRan(s.due(at: t0, decision: run1), at: t0)
        s.reconcile([wt(a, [(1, .merged)])], now: at(60))
        #expect(s.tier(of: .track(key(1))) == nil)
        #expect(s.nextDue(decision: run1) == nil)
    }

    @Test func aClosedResultReturnsTheBranchToDiscoveryAtThirtyMinutesWhileActive() {
        let a = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(1, .blocked)])], now: t0)
        s.markRan(s.due(at: t0, decision: run1), at: t0)
        s.reconcile([wt(a, [(1, .closed)])], now: at(120))
        #expect(s.tier(of: .track(key(1))) == nil)
        #expect(s.tier(of: .discover(a)) == .closedDiscovery)
        #expect(s.nextDue(decision: run1) == at(1800))   // inherits the track item's lastRun (t0)
    }

    @Test func aClosedPRInAnIdleWorktreeIsNotCheckedAtAll() {
        let a = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, active: false, [(1, .closed)])], now: t0)
        #expect(s.due(at: t0, decision: run1).isEmpty)
        #expect(s.nextDue(decision: run1) == nil)
    }

    @Test func idleToActiveMakesThatWorktreeDueAtOnce() {
        let a = UUID(), b = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, active: false, [(1, .closed)]), wt(b, active: false, [(2, .blocked)])], now: t0)
        s.markRan(s.due(at: t0, decision: run1), at: t0)
        s.reconcile([wt(a, active: true, [(1, .closed)]), wt(b, active: true, [(2, .blocked)])], now: at(30))
        let due = s.due(at: at(30), decision: run1)
        #expect(due.discover == [a])
        #expect(due.track == [key(2)])
    }

    @Test func twoWorktreesOnOnePRAreOneItemWithTwoOwners() {
        let a = UUID(), b = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(7, .pending)]), wt(b, [(7, .pending)])], now: t0)
        #expect(s.due(at: t0, decision: run1).track == [key(7)])
        #expect(s.owners(of: key(7)) == [a, b])
    }

    // Review Focus 3
    @Test func losingOneOwnerKeepsTheItemAndItsDueTime() {
        let a = UUID(), b = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(7, .blocked)]), wt(b, [(7, .blocked)])], now: t0)
        s.markRan(s.due(at: t0, decision: run1), at: t0)
        s.reconcile([wt(a, [(7, .blocked)])], now: at(10))
        #expect(s.owners(of: key(7)) == [a])
        #expect(s.due(at: at(10), decision: run1).isEmpty)
        #expect(s.nextDue(decision: run1) == at(120))
    }

    // Review Focus 4
    @Test func aNeverObservedBindingIsTrackedAtOnceOnTheWaitingTier() {
        let a = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(5, nil)])], now: t0)
        #expect(s.tier(of: .track(key(5))) == .waiting)
        #expect(s.due(at: t0, decision: run1).track == [key(5)])
        #expect(s.tier(of: .discover(a)) == nil)
    }

    // Review Focus 5
    @Test func aRunWhateverItsOutcomeWaitsAFullInterval() {
        let a = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(1, .blocked)])], now: t0)
        s.markRan(s.due(at: t0, decision: run1), at: t0)   // the caller marks failures too
        s.reconcile([wt(a, [(1, .blocked)])], now: at(1))
        #expect(s.due(at: at(119), decision: run1).isEmpty)
    }

    @Test func fastTierHoldsTenAndTheOldestWaiterMovesUp() {
        var s = PRPollSchedule()
        let ids = (0..<12).map { _ in UUID() }
        // PRs 0...11 enter pending at t0+i, so the order is unambiguous.
        for i in 0..<12 {
            s.reconcile((0...i).map { j in wt(ids[j], [(j, .pending)]) }, now: at(TimeInterval(i)))
        }
        #expect(s.interval(of: .track(key(9)), decision: run1) == .seconds(60))
        #expect(s.interval(of: .track(key(10)), decision: run1) == .seconds(120))
        #expect(s.interval(of: .track(key(11)), decision: run1) == .seconds(120))
        // PR 0 finishes (goes green): PR 10, the oldest waiter, takes its slot.
        var facts = (0..<12).map { j in wt(ids[j], [(j, .pending)]) }
        facts[0] = wt(ids[0], [(0, .mergeable)])
        s.reconcile(facts, now: at(100))
        #expect(s.interval(of: .track(key(10)), decision: run1) == .seconds(60))
        #expect(s.interval(of: .track(key(11)), decision: run1) == .seconds(120))
    }

    @Test func brakeLeavesOnlyFastTierDue() {
        let a = UUID(), b = UUID(), c = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(1, .pending)]), wt(b, [(2, .blocked)]), wt(c)], now: t0)
        let due = s.due(at: t0, decision: .brake)
        #expect(due.track == [key(1)])
        #expect(due.discover.isEmpty)
    }

    @Test func stretchAppliesToWaitingAndDiscoveryOnly() {
        let a = UUID(), b = UUID(), c = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(1, .pending)]), wt(b, [(2, .blocked)]), wt(c)], now: t0)
        let d = PRPollGovernor.Decision.run(stretch: 2)
        #expect(s.interval(of: .track(key(1)), decision: d) == .seconds(60))
        #expect(s.interval(of: .track(key(2)), decision: d) == .seconds(240))
        #expect(s.interval(of: .discover(c), decision: d) == .seconds(1200))
    }

    @Test func loadsReflectTiersAndCosts() {
        let a = UUID(), c = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(1, .pending)]), wt(c, active: false)], now: t0)
        let loads = s.loads().sorted { $0.interval < $1.interval }
        #expect(loads == [
            PRPollGovernor.Load(interval: .seconds(60), points: 1, stretchable: false),
            PRPollGovernor.Load(interval: .seconds(3600), points: 1, stretchable: true),
        ])
    }

    /// Eleven PRs enter checksRunning one second apart: 0...9 hold the fast
    /// slots and 10 overflows.
    private func elevenPending(_ ids: [UUID], _ s: inout PRPollSchedule) {
        for i in 0..<11 {
            s.reconcile((0...i).map { j in wt(ids[j], [(j, .pending)]) }, now: at(TimeInterval(i)))
        }
    }

    @Test func aPRThatLeavesChecksRunningAndReentersGoesToTheBackOfTheFastQueue() {
        var s = PRPollSchedule()
        let ids = (0..<11).map { _ in UUID() }
        elevenPending(ids, &s)
        var facts = (0..<11).map { j in wt(ids[j], [(j, .pending)]) }
        // PR 0 goes green: PR 10 takes its slot.
        facts[0] = wt(ids[0], [(0, .mergeable)])
        s.reconcile(facts, now: at(100))
        #expect(s.interval(of: .track(key(10)), decision: run1) == .seconds(60))
        // PR 0 starts checks again: it is now the newest waiter, not the oldest.
        facts[0] = wt(ids[0], [(0, .pending)])
        s.reconcile(facts, now: at(200))
        #expect(s.interval(of: .track(key(0)), decision: run1) == .seconds(120))
        #expect(s.interval(of: .track(key(10)), decision: run1) == .seconds(60))
    }

    @Test func anOverflowItemsIntervalIsStretched() {
        var s = PRPollSchedule()
        let ids = (0..<11).map { _ in UUID() }
        elevenPending(ids, &s)
        let d = PRPollGovernor.Decision.run(stretch: 2)
        #expect(s.interval(of: .track(key(10)), decision: d) == .seconds(240))
        #expect(s.interval(of: .track(key(9)), decision: d) == .seconds(60))
    }

    @Test func underABrakeWithNoFastItemsNothingIsEverDue() {
        let a = UUID(), c = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(1, .blocked)]), wt(c)], now: t0)
        #expect(s.nextDue(decision: .brake) == nil)
        #expect(s.nextDue(decision: run1) != nil)
    }

    @Test func aClosedPRInAnActiveWorktreeAtStartIsDueAtOnce() {
        let a = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, active: true, [(1, .closed)])], now: t0)
        #expect(s.tier(of: .discover(a)) == .closedDiscovery)
        #expect(s.due(at: t0, decision: run1).discover == [a])
    }

    @Test func aWorktreeWithAnOpenAndAClosedBindingIsTrackedOnly() {
        let a = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, [(1, .blocked), (2, .closed)])], now: t0)
        #expect(s.tier(of: .track(key(1))) == .waiting)
        #expect(s.tier(of: .track(key(2))) == nil)
        #expect(s.tier(of: .discover(a)) == nil)
    }

    @Test func undiscoverableWorktreeWithNoBindingsHasNoItem() {
        let a = UUID()
        var s = PRPollSchedule()
        s.reconcile([wt(a, discoverable: false)], now: t0)
        #expect(s.nextDue(decision: run1) == nil)
    }
}
