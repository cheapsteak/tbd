import Foundation
import Testing
import TBDShared

@testable import TBDDaemonLib

/// The usage reading the daemon's notifications quote (`ProfileUsageSummary`):
/// an open window gives its percent, and one whose reset is at or before `now`
/// says it reset when the last fetch succeeded, because the pool picker then
/// counts it as 0%. A failing fetch's windows keep their percents.
@Suite("ProfileUsageSummary")
struct ProfileUsageSummaryTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func snapshot(_ buckets: [ClaudeUsageLimitBucket]) -> ProfileUsageSnapshot {
        ProfileUsageSnapshot(
            buckets: buckets, fetchedAt: now, lastAttemptAt: now, status: "ok", statusKind: .ok)
    }

    private static func session(_ percent: Double, resetsAt: Date?) -> ClaudeUsageLimitBucket {
        ClaudeUsageLimitBucket(kind: "session", group: "session", percent: percent, resetsAt: resetsAt)
    }

    private static func weekly(_ percent: Double, resetsAt: Date?) -> ClaudeUsageLimitBucket {
        ClaudeUsageLimitBucket(kind: "weekly_all", group: "weekly", percent: percent, resetsAt: resetsAt)
    }

    @Test func openWindowsGiveTheirPercents() {
        let open = Self.snapshot([
            Self.session(61.9, resetsAt: Self.now.addingTimeInterval(3_600)),
            Self.weekly(38, resetsAt: Self.now.addingTimeInterval(86_400)),
        ])
        #expect(ProfileUsageSummary.text(of: open, now: Self.now) == "5h 61% · week 38%")
    }

    @Test func windowsWhoseResetIsNowSayTheyReset() {
        let endedAtNow = Self.snapshot([
            Self.session(95, resetsAt: Self.now),
            Self.weekly(88, resetsAt: Self.now),
        ])
        #expect(ProfileUsageSummary.text(of: endedAtNow, now: Self.now) == "5h reset · week reset")
    }

    @Test func windowsWhoseResetHasPassedSayTheyReset() {
        let endedBeforeNow = Self.snapshot([
            Self.session(95, resetsAt: Self.now.addingTimeInterval(-60)),
            Self.weekly(88, resetsAt: Self.now.addingTimeInterval(-8 * 86_400)),
        ])
        #expect(ProfileUsageSummary.text(of: endedBeforeNow, now: Self.now) == "5h reset · week reset")
    }

    /// A failing fetch's windows quote the percent they last read, however
    /// long ago they reset: the pool picker ranks a failing snapshot by those
    /// percents, so the text must not say "reset". The healthy counterparts
    /// are `windowsWhoseResetIsNowSayTheyReset` and
    /// `windowsWhoseResetHasPassedSayTheyReset`.
    @Test(arguments: [ProfileUsageStatusKind.needsLogin, .rateLimited, .networkError, .unknown])
    func aFailingSnapshotQuotesItsEndedWindowsAtTheirLastPercents(statusKind: ProfileUsageStatusKind) {
        let failing = ProfileUsageSnapshot(
            buckets: [
                Self.session(95, resetsAt: Self.now.addingTimeInterval(-3 * 86_400)),
                Self.weekly(88, resetsAt: Self.now),
            ],
            fetchedAt: Self.now.addingTimeInterval(-3 * 86_400 - 3_600), lastAttemptAt: Self.now,
            status: "fetch failed: HTTP 401", statusKind: statusKind)
        #expect(ProfileUsageSummary.text(of: failing, now: Self.now) == "5h 95% · week 88%")
    }

    @Test func bucketsWithNoResetInstantGiveTheirPercents() {
        let noReset = Self.snapshot([
            Self.session(95, resetsAt: nil),
            Self.weekly(30, resetsAt: nil),
        ])
        #expect(ProfileUsageSummary.text(of: noReset, now: Self.now) == "5h 95% · week 30%")
    }

    @Test func anEndedWindowSaysItResetBesideAnOpenOne() {
        let sessionEnded = Self.snapshot([
            Self.session(95, resetsAt: Self.now.addingTimeInterval(-60)),
            Self.weekly(30, resetsAt: Self.now.addingTimeInterval(86_400)),
        ])
        #expect(ProfileUsageSummary.text(of: sessionEnded, now: Self.now) == "5h reset · week 30%")

        let weeklyEnded = Self.snapshot([
            Self.session(20, resetsAt: Self.now.addingTimeInterval(3_600)),
            Self.weekly(100, resetsAt: Self.now),
        ])
        #expect(ProfileUsageSummary.text(of: weeklyEnded, now: Self.now) == "5h 20% · week reset")
    }

    @Test func aSnapshotWithNeitherBucketHasNoReading() {
        let other = Self.snapshot([
            ClaudeUsageLimitBucket(kind: "weekly_scoped", group: "weekly", percent: 50,
                                   resetsAt: Self.now.addingTimeInterval(86_400)),
        ])
        #expect(ProfileUsageSummary.text(of: other, now: Self.now) == nil)
        #expect(ProfileUsageSummary.text(of: Self.snapshot([]), now: Self.now) == nil)
    }
}
