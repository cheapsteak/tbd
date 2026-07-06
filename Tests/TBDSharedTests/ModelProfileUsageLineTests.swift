import Foundation
import Testing
@testable import TBDShared

@Suite("ModelProfileUsage.usageLine")
struct ModelProfileUsageLineTests {

    private let profileID = UUID()

    // Fixed reference "now": 2026-01-01 20:00:00 UTC.
    private var now: Date { Date(timeIntervalSince1970: 1_767_297_600) }

    // MARK: - No data → nil

    @Test("no fetch and no cached numbers → nil (renders nothing)")
    func emptyReturnsNil() {
        let u = ModelProfileUsage(profileID: profileID)
        #expect(u.usageLine(now: now) == nil)
    }

    // MARK: - Fresh "ok" reading

    @Test("fresh ok reading renders 5h % and week %")
    func freshOkFullLine() {
        let u = ModelProfileUsage(
            profileID: profileID,
            fiveHourPct: 27,
            sevenDayPct: 84,
            fiveHourResetsAt: now.addingTimeInterval(20 * 60),
            sevenDayResetsAt: now.addingTimeInterval((2 * 86_400) + (5 * 3_600)),
            fetchedAt: now,
            lastStatus: "ok"
        )
        let line = u.usageLine(now: now)
        #expect(line?.contains("5h 27%") == true)
        #expect(line?.contains("week 84%") == true)
        #expect(line?.contains("resets in 2d 5h") == true)
        // No staleness / retry suffix on a fresh ok reading.
        #expect(line?.contains("ago") == false)
        #expect(line?.contains("retrying") == false)
    }

    @Test("ok reading rounds fractional percentages")
    func okRoundsPercent() {
        let u = ModelProfileUsage(
            profileID: profileID,
            fiveHourPct: 26.6,
            sevenDayPct: nil,
            fetchedAt: now,
            lastStatus: "ok"
        )
        #expect(u.usageLine(now: now) == "5h 27%")
    }

    // MARK: - Staleness

    @Test("stale ok reading is annotated with age")
    func staleOkAnnotatedWithAge() {
        let u = ModelProfileUsage(
            profileID: profileID,
            fiveHourPct: 10,
            sevenDayPct: nil,
            fetchedAt: now.addingTimeInterval(-52 * 60),  // 52m ago > 45m threshold
            lastStatus: "ok"
        )
        #expect(u.usageLine(now: now) == "5h 10% · 52m ago")
    }

    @Test("reading just under the stale threshold is not annotated")
    func freshEnoughNotAnnotated() {
        let u = ModelProfileUsage(
            profileID: profileID,
            fiveHourPct: 10,
            sevenDayPct: nil,
            fetchedAt: now.addingTimeInterval(-40 * 60),  // under 45m
            lastStatus: "ok"
        )
        #expect(u.usageLine(now: now) == "5h 10%")
    }

    // MARK: - Honest fallback states

    @Test("http_401 → needs re-login (even with stale cached numbers)")
    func unauthorizedNeedsRelogin() {
        let u = ModelProfileUsage(
            profileID: profileID,
            fiveHourPct: 10,
            sevenDayPct: 20,
            fetchedAt: now,
            lastStatus: "http_401"
        )
        #expect(u.usageLine(now: now) == "usage unavailable — needs re-login")
    }

    @Test("http_429 with cached numbers → numbers + rate-limited")
    func rateLimitedWithCache() {
        let u = ModelProfileUsage(
            profileID: profileID,
            fiveHourPct: 55,
            sevenDayPct: nil,
            fetchedAt: now,
            lastStatus: "http_429"
        )
        #expect(u.usageLine(now: now) == "5h 55% · rate-limited")
    }

    @Test("http_429 without cached numbers → unavailable, rate-limited")
    func rateLimitedNoCache() {
        let u = ModelProfileUsage(
            profileID: profileID,
            fetchedAt: now,
            lastStatus: "http_429"
        )
        #expect(u.usageLine(now: now) == "usage unavailable — rate-limited, retrying")
    }

    @Test("network_error with cached numbers → numbers + retrying")
    func networkErrorWithCache() {
        let u = ModelProfileUsage(
            profileID: profileID,
            fiveHourPct: 42,
            sevenDayPct: nil,
            fetchedAt: now,
            lastStatus: "network_error"
        )
        #expect(u.usageLine(now: now) == "5h 42% · retrying")
    }

    @Test("network_error without cached numbers → unavailable, retrying")
    func networkErrorNoCache() {
        let u = ModelProfileUsage(
            profileID: profileID,
            fetchedAt: now,
            lastStatus: "network_error"
        )
        #expect(u.usageLine(now: now) == "usage unavailable — retrying")
    }
}
