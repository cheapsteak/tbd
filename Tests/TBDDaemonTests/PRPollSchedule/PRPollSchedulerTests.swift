import Clocks
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 1: in-process, the scheduler's sleep runs on a `TestClock` and its
// "now" on a `TestDateSource`. The only real waiting is `pollUntilTrue`
// observing the loop task, which is scheduling, not behaviour under test.
@Suite("PRPollScheduler", .clockDriven, .serialized)
struct PRPollSchedulerTests {
    private func key(_ n: Int) -> PRPollKey { PRPollKey(host: "github.com", owner: "acme", repo: "acme-prod", number: n) }

    actor Runs {
        var dues: [PRPollDue] = []
        func add(_ d: PRPollDue) { dues.append(d) }
    }
    actor Facts {
        var value: [PRPollWorktreeFacts]
        init(_ v: [PRPollWorktreeFacts]) { value = v }
        func set(_ v: [PRPollWorktreeFacts]) { value = v }
    }
    /// Lets a runner reach the scheduler that calls it.
    actor SchedulerBox {
        var scheduler: PRPollScheduler?
        func set(_ s: PRPollScheduler) { scheduler = s }
    }
    actor Counter {
        var count = 0
        func bump() { count += 1 }
    }

    private func blockedFacts(_ a: UUID) -> Facts {
        Facts([PRPollWorktreeFacts(worktreeID: a, active: true, discoverable: true,
                                   bindings: [PRPollBindingFact(key: key(1), state: .blocked)])])
    }

    @Test func runOnceRunsWhatIsDueAndNothingElse() async {
        let dates = TestDateSource()
        let a = UUID()
        let facts = blockedFacts(a)
        let runs = Runs()
        let s = PRPollScheduler(facts: { await facts.value }, run: { await runs.add($0) },
                                now: dates.provider, clock: TestClock<Duration>())
        await s.runOnce()
        dates.advance(by: 60)
        await s.runOnce()
        dates.advance(by: 60)
        await s.runOnce()
        #expect(await runs.dues.map(\.track) == [[key(1)], [key(1)]])
    }

    @Test func rateLimitErrorBrakesEverythingButTheFastTier() async {
        let dates = TestDateSource()
        let a = UUID(), b = UUID()
        let facts = Facts([
            PRPollWorktreeFacts(worktreeID: a, active: true, discoverable: true,
                                bindings: [PRPollBindingFact(key: key(1), state: .pending)]),
            PRPollWorktreeFacts(worktreeID: b, active: true, discoverable: true,
                                bindings: [PRPollBindingFact(key: key(2), state: .blocked)]),
        ])
        let runs = Runs()
        let s = PRPollScheduler(facts: { await facts.value }, run: { await runs.add($0) },
                                now: dates.provider, clock: TestClock<Duration>())
        await s.recordRateLimitSignal(.limited)
        await s.runOnce()
        #expect(await runs.dues.map(\.track) == [[key(1)]])
    }

    @Test func withoutABrakeBothTiersRun() async {
        // The other branch of the brake test: no rate-limit signal, both items run.
        let dates = TestDateSource()
        let a = UUID(), b = UUID()
        let facts = Facts([
            PRPollWorktreeFacts(worktreeID: a, active: true, discoverable: true,
                                bindings: [PRPollBindingFact(key: key(1), state: .pending)]),
            PRPollWorktreeFacts(worktreeID: b, active: true, discoverable: true,
                                bindings: [PRPollBindingFact(key: key(2), state: .blocked)]),
        ])
        let runs = Runs()
        let s = PRPollScheduler(facts: { await facts.value }, run: { await runs.add($0) },
                                now: dates.provider, clock: TestClock<Duration>())
        await s.runOnce()
        #expect(await runs.dues.map(\.track) == [[key(1), key(2)]])
    }

    @Test func loopSleepsUntilNextDueAndAKickWakesItEarly() async {
        let clock = TestClock<Duration>()
        let dates = TestDateSource()
        let a = UUID()
        let facts = blockedFacts(a)
        let runs = Runs()
        let s = PRPollScheduler(facts: { await facts.value }, run: { await runs.add($0) },
                                now: dates.provider, maxSleep: .seconds(60), clock: clock)
        await s.start()
        #expect(await s.isRunning)
        #expect(await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { await runs.dues.count == 1 } == .satisfied)
        // A trigger makes item 1 due now and wakes the sleeping loop with no clock advance.
        await s.trigger(worktreeID: a)
        #expect(await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { await runs.dues.count == 2 } == .satisfied)
        await s.stop()
        #expect(await s.isRunning == false)
    }

    @Test func undeterminedRunsDoNotRetrySooner() async {
        // The runner "fails" (does nothing); the scheduler still marks the item ran.
        let dates = TestDateSource()
        let a = UUID()
        let facts = blockedFacts(a)
        let runs = Runs()
        let s = PRPollScheduler(facts: { await facts.value }, run: { await runs.add($0) },
                                now: dates.provider, clock: TestClock<Duration>())
        await s.runOnce()
        dates.advance(by: 30)
        await s.runOnce()
        #expect(await runs.dues.count == 1)
    }

    @Test func aTriggerThatLandsMidRunIsNotLost() async {
        // `markRan` clears forced due times; a trigger arriving while the runner
        // is busy must still make the item due again afterwards.
        let dates = TestDateSource()
        let a = UUID()
        let facts = blockedFacts(a)
        let runs = Runs()
        let box = SchedulerBox()
        let s = PRPollScheduler(
            facts: { await facts.value },
            run: { due in
                await runs.add(due)
                if await runs.dues.count == 1 {
                    await box.scheduler?.trigger(worktreeID: a)
                }
            },
            now: dates.provider, clock: TestClock<Duration>())
        await box.set(s)
        await s.runOnce()
        await s.runOnce()   // same instant: due only because the mid-run trigger survived
        #expect(await runs.dues.map(\.track) == [[key(1)], [key(1)]])
    }

    @Test func aTriggerBetweenRunsMakesTheItemDueAtOnce() async {
        let dates = TestDateSource()
        let a = UUID()
        let facts = blockedFacts(a)
        let runs = Runs()
        let s = PRPollScheduler(facts: { await facts.value }, run: { await runs.add($0) },
                                now: dates.provider, clock: TestClock<Duration>())
        await s.runOnce()
        await s.runOnce()
        #expect(await runs.dues.count == 1)
        await s.trigger(worktreeID: a)
        await s.runOnce()
        #expect(await runs.dues.count == 2)
    }

    @Test func kickCallsTheProbe() async {
        let kicks = Counter()
        let s = PRPollScheduler(facts: { [] }, run: { _ in }, clock: TestClock<Duration>())
        await s.setKickProbeForTests { await kicks.bump() }
        await s.kick()
        await s.trigger(worktreeID: UUID())
        #expect(await kicks.count == 2)
    }

    @Test func startIsIdempotentAndStopEndsTheLoop() async {
        let clock = TestClock<Duration>()
        let runs = Runs()
        let a = UUID()
        let facts = blockedFacts(a)
        let s = PRPollScheduler(facts: { await facts.value }, run: { await runs.add($0) },
                                now: TestDateSource().provider, clock: clock)
        await s.start()
        await s.start()
        #expect(await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { await runs.dues.count == 1 } == .satisfied)
        await clock.waitForSuspension()
        await s.stop()
        #expect(await s.isRunning == false)
        // Only one loop ran: a second could have run the item a second time.
        #expect(await runs.dues.count == 1)
    }
}
