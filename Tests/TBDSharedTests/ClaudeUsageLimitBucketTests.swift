import Foundation
import Testing

import TBDShared

/// The one rule for an ended usage window, which the app's usage bars follow,
/// and rankings too for a snapshot whose last fetch succeeded.
@Suite("ClaudeUsageLimitBucket.windowHasEnded")
struct ClaudeUsageLimitBucketWindowTests {
    private let resetAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aResetStillAheadHasNotEnded() {
        let bucket = ClaudeUsageLimitBucket(kind: "session", percent: 95, resetsAt: resetAt)
        #expect(bucket.windowHasEnded(at: resetAt.addingTimeInterval(-1)) == false)
    }

    @Test func aResetExactlyNowHasEnded() {
        let bucket = ClaudeUsageLimitBucket(kind: "session", percent: 95, resetsAt: resetAt)
        #expect(bucket.windowHasEnded(at: resetAt))
    }

    @Test func aResetInThePastHasEnded() {
        let bucket = ClaudeUsageLimitBucket(kind: "weekly_all", percent: 95, resetsAt: resetAt)
        #expect(bucket.windowHasEnded(at: resetAt.addingTimeInterval(60)))
        #expect(bucket.windowHasEnded(at: resetAt.addingTimeInterval(8 * 86_400)))
    }

    @Test func noResetTimeNeverEnds() {
        let bucket = ClaudeUsageLimitBucket(kind: "session", percent: 95, resetsAt: nil)
        #expect(bucket.windowHasEnded(at: resetAt) == false)
        #expect(bucket.windowHasEnded(at: resetAt.addingTimeInterval(8 * 86_400)) == false)
    }
}

/// When a ranking counts an ended window as 0%: only in a snapshot whose last
/// fetch succeeded. A failing snapshot keeps the percent it last read.
@Suite("ProfileUsageSnapshot.countsAsReset")
struct ProfileUsageSnapshotCountsAsResetTests {
    private let resetAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ bucket: ClaudeUsageLimitBucket, status: String,
                          statusKind: ProfileUsageStatusKind) -> ProfileUsageSnapshot {
        ProfileUsageSnapshot(
            buckets: [bucket], fetchedAt: resetAt.addingTimeInterval(-3600),
            lastAttemptAt: resetAt, status: status, statusKind: statusKind)
    }

    @Test func aHealthySnapshotCountsAnEndedWindowAsReset() {
        let bucket = ClaudeUsageLimitBucket(kind: "session", percent: 95, resetsAt: resetAt)
        let ok = snapshot(bucket, status: "ok", statusKind: .ok)
        #expect(ok.countsAsReset(bucket, at: resetAt.addingTimeInterval(-1)) == false)
        #expect(ok.countsAsReset(bucket, at: resetAt))
        #expect(ok.countsAsReset(bucket, at: resetAt.addingTimeInterval(8 * 86_400)))
    }

    @Test(arguments: [ProfileUsageStatusKind.needsLogin, .noCredentials, .rateLimited,
                      .networkError, .decodeError, .unknown])
    func aFailingSnapshotNeverCountsAWindowAsReset(statusKind: ProfileUsageStatusKind) {
        let bucket = ClaudeUsageLimitBucket(kind: "session", percent: 95, resetsAt: resetAt)
        let failing = snapshot(bucket, status: "fetch failed: HTTP 401", statusKind: statusKind)
        #expect(failing.countsAsReset(bucket, at: resetAt) == false)
        #expect(failing.countsAsReset(bucket, at: resetAt.addingTimeInterval(8 * 86_400)) == false)
    }

    @Test func aBucketWithNoResetTimeNeverCountsAsReset() {
        let bucket = ClaudeUsageLimitBucket(kind: "session", percent: 95, resetsAt: nil)
        let ok = snapshot(bucket, status: "ok", statusKind: .ok)
        #expect(ok.countsAsReset(bucket, at: resetAt.addingTimeInterval(8 * 86_400)) == false)
    }
}
