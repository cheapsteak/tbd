import Foundation
import Testing

import TBDShared

/// The one rule for an ended usage window, which the app's usage bars and the
/// balancing picker both follow.
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
