import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("PRPollGovernor")
struct PRPollGovernorTests {
    typealias G = PRPollGovernor
    private func stretchOf(_ d: G.Decision) -> Double? {
        if case .run(let s) = d { return s } else { return nil }
    }

    @Test func factorIsOneWhenBothConditionsHold() {
        let loads = [G.Load(interval: .seconds(120), points: 1, stretchable: true)]   // 30/h
        #expect(G.decide(loads: loads, budget: G.Budget(remaining: 4000, secondsUntilReset: 1800)) == .run(stretch: 1))
        #expect(G.decide(loads: loads, budget: nil) == .run(stretch: 1))
    }

    @Test func overTheHourlyCapStretches() throws {
        // 50 waiting PRs at 2 min = 1,500/h; cap 1,000 → factor 1.5.
        let loads = Array(repeating: G.Load(interval: .seconds(120), points: 1, stretchable: true), count: 50)
        let s = try #require(stretchOf(G.decide(loads: loads, budget: nil)))
        #expect(abs(s - 1.5) < 0.01)
    }

    @Test func lowRemainingStretchesEvenUnderTheHourlyCap() throws {
        // 300/h is under the cap, but 30 min left with 50 remaining allows only 100/h.
        let loads = [G.Load(interval: .seconds(60), points: 5, stretchable: true)]
        let s = try #require(stretchOf(G.decide(loads: loads, budget: G.Budget(remaining: 50, secondsUntilReset: 1800))))
        #expect(abs(s - 3) < 0.01)
    }

    @Test func fastTierIsNeverStretched() throws {
        let loads = [G.Load(interval: .seconds(60), points: 1, stretchable: false),
                     G.Load(interval: .seconds(120), points: 100, stretchable: true)]   // 60 + 3,000
        let s = try #require(stretchOf(G.decide(loads: loads, budget: nil)))
        // 60 + 3000/s ≤ 1000 → s ≈ 3.19
        #expect(abs(s - 3000.0 / 940.0) < 0.01)
        #expect(abs(G.projectedHourlySpend(loads, stretch: s) - 1000) < 1)
    }

    @Test func eachStretchedIntervalCapsAtOneHour() {
        #expect(G.stretched(.seconds(120), by: 30) == .seconds(3600))
        #expect(G.stretched(.seconds(120), by: 45) == .seconds(3600))
        #expect(G.stretched(.seconds(3600), by: 2) == .seconds(3600))
        #expect(G.stretched(.seconds(120), by: 1.5) == .seconds(180))
    }

    @Test func brakesWhenEvenMaximumStretchExceedsRemaining() {
        let loads = Array(repeating: G.Load(interval: .seconds(60), points: 1, stretchable: false), count: 10) // 600/h
            + [G.Load(interval: .seconds(120), points: 1, stretchable: true)]
        #expect(G.decide(loads: loads, budget: G.Budget(remaining: 100, secondsUntilReset: 3600)) == .brake)
    }

    @Test func capUnreachableButRemainingFineRunsAtMaximumStretch() throws {
        let loads = [G.Load(interval: .seconds(60), points: 20, stretchable: false),   // 1,200/h fixed
                     G.Load(interval: .seconds(600), points: 1, stretchable: true)]
        let s = try #require(stretchOf(G.decide(loads: loads, budget: nil)))
        #expect(abs(s - 6) < 0.01)   // 600 s × 6 = 1 h, the maximum
    }

    @Test func noLoadsMeansNoStretch() {
        #expect(G.decide(loads: [], budget: G.Budget(remaining: 0, secondsUntilReset: 3600)) == .run(stretch: 1))
    }
}

@Suite("PRPollBudgetState")
struct PRPollBudgetStateTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func readingBecomesABudget() {
        var s = PRPollBudgetState()
        s.recordReading(remaining: 400, resetAt: t0.addingTimeInterval(900), receivedAt: t0)
        #expect(s.budget(at: t0.addingTimeInterval(60)) == PRPollGovernor.Budget(remaining: 400, secondsUntilReset: 840))
    }

    @Test func rateLimitErrorBrakesUntilTheLastKnownReset() {
        var s = PRPollBudgetState()
        s.recordReading(remaining: 10, resetAt: t0.addingTimeInterval(600), receivedAt: t0)
        s.recordRateLimitError(at: t0.addingTimeInterval(30))
        #expect(s.isBraked(at: t0.addingTimeInterval(599)))
        #expect(!s.isBraked(at: t0.addingTimeInterval(601)))
    }

    @Test func rateLimitErrorWithNoReadingBrakesForOneHour() {
        var s = PRPollBudgetState()
        s.recordRateLimitError(at: t0)
        #expect(s.isBraked(at: t0.addingTimeInterval(3599)))
        #expect(!s.isBraked(at: t0.addingTimeInterval(3601)))
    }

    @Test func factorIsRecomputedNotResetWhenResetPasses() {
        var s = PRPollBudgetState()
        let heavy = Array(repeating: PRPollGovernor.Load(interval: .seconds(120), points: 1, stretchable: true), count: 50)
        s.recordReading(remaining: 4000, resetAt: t0.addingTimeInterval(300), receivedAt: t0)
        // After the reset deadline the remaining leg is unknown, but the hourly cap still holds.
        guard case .run(let after) = s.decide(loads: heavy, at: t0.addingTimeInterval(301)) else {
            Issue.record("expected run"); return
        }
        #expect(abs(after - 1.5) < 0.01)
        #expect(s.budget(at: t0.addingTimeInterval(301)) == nil)
    }

    @Test func decideBrakeHoldsUntilTheResetDeadline() {
        var s = PRPollBudgetState()
        let loads = Array(repeating: PRPollGovernor.Load(interval: .seconds(60), points: 1, stretchable: false), count: 10)
        s.recordReading(remaining: 5, resetAt: t0.addingTimeInterval(1200), receivedAt: t0)
        #expect(s.decide(loads: loads, at: t0) == .brake)
        #expect(s.isBraked(at: t0.addingTimeInterval(1199)))
        #expect(!s.isBraked(at: t0.addingTimeInterval(1201)))
    }

    // Review Focus 2: skewed or stale resetAt.
    @Test func resetAtInThePastClampsToZeroAndNeverBrakes() {
        var s = PRPollBudgetState()
        s.recordReading(remaining: 0, resetAt: t0.addingTimeInterval(-500), receivedAt: t0)
        #expect(s.budget(at: t0) == nil)
        #expect(s.decide(loads: [PRPollGovernor.Load(interval: .seconds(60), points: 1, stretchable: false)], at: t0)
                == .run(stretch: 1))
    }

    @Test func resetAtFarInTheFutureClampsToOneHour() {
        var s = PRPollBudgetState()
        s.recordReading(remaining: 100, resetAt: t0.addingTimeInterval(86_400 * 3), receivedAt: t0)
        #expect(s.budget(at: t0)?.secondsUntilReset == 3600)
        s.recordRateLimitError(at: t0)
        #expect(!s.isBraked(at: t0.addingTimeInterval(3601)))
    }
}
