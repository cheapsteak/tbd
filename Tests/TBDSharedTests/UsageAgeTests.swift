import Foundation
import Testing

import TBDShared

/// The age wording the app's usage surfaces and `tbd profile list` share:
/// "just now" under a minute, then whole minutes, hours or days.
@Suite("UsageAge")
struct UsageAgeTests {
    /// 2027-01-15 08:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func text(_ secondsAgo: TimeInterval) -> String {
        UsageAge.text(since: now.addingTimeInterval(-secondsAgo), now: now)
    }

    private static func agoText(_ secondsAgo: TimeInterval) -> String {
        UsageAge.agoText(since: now.addingTimeInterval(-secondsAgo), now: now)
    }

    @Test func textRoundsDownToWholeMinutesHoursAndDays() {
        #expect(Self.text(0) == "just now")
        #expect(Self.text(59) == "just now")
        #expect(Self.text(60) == "1m")
        #expect(Self.text(180) == "3m")
        #expect(Self.text(59 * 60 + 59) == "59m")
        #expect(Self.text(3600) == "1h")
        #expect(Self.text(7200) == "2h")
        #expect(Self.text(23 * 3600 + 59 * 60) == "23h")
        #expect(Self.text(86_400) == "1d")
        #expect(Self.text(172_800) == "2d")
    }

    /// An instant after `now` reads as now, never as a negative age.
    @Test func aFutureInstantReadsJustNow() {
        #expect(Self.text(-500) == "just now")
        #expect(Self.agoText(-500) == "just now")
    }

    @Test func agoTextAddsAgoPastAMinute() {
        #expect(Self.agoText(0) == "just now")
        #expect(Self.agoText(59) == "just now")
        #expect(Self.agoText(60) == "1m ago")
        #expect(Self.agoText(40 * 60) == "40m ago")
        #expect(Self.agoText(2 * 3600 + 59) == "2h ago")
        #expect(Self.agoText(49 * 3600) == "2d ago")
    }
}
