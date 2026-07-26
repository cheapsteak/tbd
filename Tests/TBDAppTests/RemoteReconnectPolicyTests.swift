import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests for `RemoteReconnectPolicy` — the pure backoff/eligibility decision
/// behind automatic remote-attach reconnection after an UNEXPECTED exit
/// (transport failure, not a user detach). No AppState/AppKit dependency —
/// mirrors `RemoteAttachLifecycleTests`'s "pure policy" shape.
@Suite("RemoteReconnectPolicy")
struct RemoteReconnectPolicyTests {

    // MARK: - backoffInterval(attempts:)

    @Test func backoffInterval_zeroOrNegativeAttemptsIsZero() {
        #expect(RemoteReconnectPolicy.backoffInterval(attempts: 0) == 0)
        #expect(RemoteReconnectPolicy.backoffInterval(attempts: -1) == 0)
    }

    @Test func backoffInterval_firstAttemptIsTheBaseDelay() {
        #expect(RemoteReconnectPolicy.backoffInterval(attempts: 1) == RemoteReconnectPolicy.baseBackoff)
    }

    @Test func backoffInterval_doublesEachConsecutiveFailure() {
        #expect(RemoteReconnectPolicy.backoffInterval(attempts: 2) == RemoteReconnectPolicy.baseBackoff * 2)
        #expect(RemoteReconnectPolicy.backoffInterval(attempts: 3) == RemoteReconnectPolicy.baseBackoff * 4)
        #expect(RemoteReconnectPolicy.backoffInterval(attempts: 4) == RemoteReconnectPolicy.baseBackoff * 8)
    }

    @Test func backoffInterval_capsAtMaxBackoff() {
        #expect(RemoteReconnectPolicy.backoffInterval(attempts: 100) == RemoteReconnectPolicy.maxBackoff)
    }

    // MARK: - isBlocked(_:providerHealth:now:)

    @Test func isBlocked_trueWhenProviderIsNotOkRegardlessOfElapsedTime() {
        let pending = RemotePendingReconnect(exitCode: 1, attempts: 1, nextEligibleAt: Date(timeIntervalSince1970: 0))
        // `now` is WAY past `nextEligibleAt` — still blocked, since a
        // reconnect must be driven by provider health, never by elapsed
        // time alone.
        let farFuture = Date(timeIntervalSince1970: 1_000_000)
        #expect(RemoteReconnectPolicy.isBlocked(pending, providerHealth: .stale, now: farFuture))
        #expect(RemoteReconnectPolicy.isBlocked(pending, providerHealth: .error, now: farFuture))
        #expect(RemoteReconnectPolicy.isBlocked(pending, providerHealth: .needsAuth, now: farFuture))
    }

    @Test func isBlocked_trueWhenHealthyButBackoffWindowNotYetElapsed() {
        let now = Date(timeIntervalSince1970: 1_000)
        let pending = RemotePendingReconnect(exitCode: 1, attempts: 1, nextEligibleAt: now.addingTimeInterval(5))
        #expect(RemoteReconnectPolicy.isBlocked(pending, providerHealth: .ok, now: now))
    }

    @Test func isBlocked_falseWhenHealthyAndBackoffWindowElapsed() {
        let now = Date(timeIntervalSince1970: 1_000)
        let pending = RemotePendingReconnect(exitCode: 1, attempts: 1, nextEligibleAt: now.addingTimeInterval(-1))
        #expect(!RemoteReconnectPolicy.isBlocked(pending, providerHealth: .ok, now: now))
    }

    @Test func isBlocked_falseAtExactlyTheEligibleInstant() {
        let now = Date(timeIntervalSince1970: 1_000)
        let pending = RemotePendingReconnect(exitCode: 1, attempts: 1, nextEligibleAt: now)
        #expect(!RemoteReconnectPolicy.isBlocked(pending, providerHealth: .ok, now: now))
    }

    // MARK: - nextPending(exitCode:previous:now:)

    @Test func nextPending_firstFailureStartsAtAttemptOne() {
        let now = Date(timeIntervalSince1970: 1_000)
        let pending = RemoteReconnectPolicy.nextPending(exitCode: 137, previous: nil, now: now)
        #expect(pending.attempts == 1)
        #expect(pending.exitCode == 137)
        #expect(pending.nextEligibleAt == now.addingTimeInterval(RemoteReconnectPolicy.baseBackoff))
    }

    @Test func nextPending_incrementsAttemptsOnTopOfAnExistingEntry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let previous = RemotePendingReconnect(exitCode: 1, attempts: 2, nextEligibleAt: now)
        let pending = RemoteReconnectPolicy.nextPending(exitCode: 1, previous: previous, now: now)
        #expect(pending.attempts == 3)
        #expect(pending.nextEligibleAt == now.addingTimeInterval(RemoteReconnectPolicy.baseBackoff * 4))
    }

    @Test func nextPending_capturesTheLatestExitCode() {
        let now = Date(timeIntervalSince1970: 1_000)
        let previous = RemotePendingReconnect(exitCode: 1, attempts: 1, nextEligibleAt: now)
        let pending = RemoteReconnectPolicy.nextPending(exitCode: 255, previous: previous, now: now)
        #expect(pending.exitCode == 255)
    }
}
