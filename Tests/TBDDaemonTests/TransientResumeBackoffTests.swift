import Testing
@testable import TBDDaemonLib
import TBDShared

/// Spec 2026-07-08 §Backoff: fixed 4-step ladder (60s/2m/5m/10m), then give
/// up. No jitter — see `LimitResumeScheduler.scheduleTransient` doc comment
/// for why.
@Suite struct TransientResumeBackoffTests {

    @Test func delayReturnsLadderStepsInOrder() {
        #expect(TransientResumeBackoff.delay(consecutiveAttempts: 0) == 60)
        #expect(TransientResumeBackoff.delay(consecutiveAttempts: 1) == 120)
        #expect(TransientResumeBackoff.delay(consecutiveAttempts: 2) == 300)
        #expect(TransientResumeBackoff.delay(consecutiveAttempts: 3) == 600)
    }

    @Test func delayReturnsNilAtAndBeyondCap() {
        #expect(TransientResumeBackoff.delay(consecutiveAttempts: 4) == nil)
        #expect(TransientResumeBackoff.delay(consecutiveAttempts: 40) == nil)
    }

    @Test func copyForDelayMatchesNotificationStrings() {
        #expect(TransientResumeBackoff.copy(forDelay: 60) == "60s")
        #expect(TransientResumeBackoff.copy(forDelay: 120) == "2m")
        #expect(TransientResumeBackoff.copy(forDelay: 300) == "5m")
        #expect(TransientResumeBackoff.copy(forDelay: 600) == "10m")
    }

    @Test func constantsMatchBrief() {
        #expect(TransientResumeBackoff.steps == [60, 120, 300, 600])
        #expect(TransientResumeBackoff.maxAttempts == TransientResumeBackoff.steps.count)
        #expect(TransientResumeBackoff.lookback == 30 * 60)
    }
}
