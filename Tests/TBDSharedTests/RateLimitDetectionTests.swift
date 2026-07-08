import Foundation
import Testing
@testable import TBDShared

@Suite("RateLimitDetection")
struct RateLimitDetectionTests {

    // MARK: - Fixture builders

    /// One JSONL line: an API-error assistant record with `text`, optionally
    /// carrying a top-level `rate_limit_info` object.
    private static func errorLine(text: String, rateLimitInfo: [String: Any]? = nil,
                                  timestamp: String = "2026-07-03T14:00:00.123Z") -> String {
        var obj: [String: Any] = [
            "type": "assistant",
            "isApiErrorMessage": true,
            "timestamp": timestamp,
            "message": ["role": "assistant",
                        "content": [["type": "text", "text": text]]]
        ]
        if let rateLimitInfo { obj["rate_limit_info"] = rateLimitInfo }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    private static func transcript(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Fixed "now": 2026-07-03 14:00:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_783_087_200)
    private static let utc = TimeZone(identifier: "UTC")!

    // MARK: - Structured rate_limit_info

    @Test func structuredRejectedTakesResetsAtVerbatim() {
        let epoch: Double = 1_783_180_800
        let data = Self.transcript([Self.errorLine(
            text: "You've hit your session limit · resets 1pm (America/Toronto)",
            rateLimitInfo: ["status": "rejected", "resetsAt": epoch, "rateLimitType": "session"])])
        let hit = RateLimitDetection.detect(transcriptData: data, now: Self.now, timeZone: Self.utc)
        #expect(hit?.resetsAt == Date(timeIntervalSince1970: epoch))
        #expect(hit?.limitType == "session")
        #expect(hit?.rawMessage == "You've hit your session limit · resets 1pm (America/Toronto)")
    }

    @Test func structuredNonRejectedFallsThroughToTextRules() {
        // status != rejected and the text is transient → nil.
        let data = Self.transcript([Self.errorLine(
            text: "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited",
            rateLimitInfo: ["status": "allowed_warning", "rateLimitType": "session"])])
        #expect(RateLimitDetection.detect(transcriptData: data, now: Self.now, timeZone: Self.utc) == nil)
    }

    // MARK: - Hard-limit wordings (spec fixtures, delimiters · / - / .)

    @Test(arguments: [
        "You've hit your session limit · resets 4:50pm (Asia/Shanghai)",
        "You've hit your weekly limit · resets 9am (Europe/London)",
        "5-hour limit reached - resets 3pm (UTC)",
        "Claude usage limit reached. Resets at 2pm",
        "You're out of extra usage · resets 3pm",
    ])
    func hardLimitWordingsSchedule(text: String) {
        let data = Self.transcript([Self.errorLine(text: text)])
        let hit = RateLimitDetection.detect(transcriptData: data, now: Self.now, timeZone: Self.utc)
        #expect(hit != nil, "should detect: \(text)")
        #expect(hit!.resetsAt > Self.now)
        #expect(hit!.rawMessage == text)
    }

    @Test(arguments: [
        "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited",
        "API Error: 529",
        "API Error: 500 Internal server error",
    ])
    func transientMessagesNeverSchedule(text: String) {
        let data = Self.transcript([Self.errorLine(text: text)])
        #expect(RateLimitDetection.detect(transcriptData: data, now: Self.now, timeZone: Self.utc) == nil)
    }

    @Test func qualifierDriftStillMatches() {
        // "allow a few arbitrary words" between "hit your" and "limit".
        let text = "You've hit your shiny new 5-hour usage limit · resets 3pm (UTC)"
        #expect(RateLimitDetection.isHardLimitMessage(text))
    }

    // MARK: - Text-fallback time math

    @Test func zoneConversionUsesIANAZone() throws {
        let text = "You've hit your session limit · resets 4:50pm (Asia/Shanghai)"
        let hit = try #require(RateLimitDetection.detect(
            transcriptData: Self.transcript([Self.errorLine(text: text)]),
            now: Self.now, timeZone: Self.utc))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let comps = cal.dateComponents([.hour, .minute], from: hit.resetsAt)
        #expect(comps.hour == 16)
        #expect(comps.minute == 50)
        #expect(hit.resetsAt > Self.now)
    }

    @Test func pastInstantRollsToTomorrow() throws {
        // now is 14:00 UTC; "resets 1pm (UTC)" is in the past → tomorrow 13:00.
        let hit = try #require(RateLimitDetection.parseResetTime(
            from: "You've hit your session limit · resets 1pm (UTC)",
            now: Self.now, defaultTimeZone: Self.utc))
        #expect(hit.timeIntervalSince(Self.now) > 22 * 3600)
        #expect(hit.timeIntervalSince(Self.now) < 24 * 3600)
    }

    @Test func missingAmPmPicksNearestFuture() throws {
        // now 14:00 UTC, "resets 9" → 9pm today (21:00) is nearer-future than 9am tomorrow.
        let hit = try #require(RateLimitDetection.parseResetTime(
            from: "resets 9 (UTC)", now: Self.now, defaultTimeZone: Self.utc))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        #expect(cal.component(.hour, from: hit) == 21)
    }

    @Test func twelveAmAndPmParseCorrectly() throws {
        let noon = try #require(RateLimitDetection.parseResetTime(
            from: "resets 12pm (UTC)", now: Self.now, defaultTimeZone: Self.utc))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        #expect(cal.component(.hour, from: noon) == 12)
        let midnight = try #require(RateLimitDetection.parseResetTime(
            from: "resets 12am (UTC)", now: Self.now, defaultTimeZone: Self.utc))
        #expect(cal.component(.hour, from: midnight) == 0)
    }

    @Test func invalidZoneIsUnparseable() {
        #expect(RateLimitDetection.parseResetTime(
            from: "resets 3pm (Mars/Olympus)", now: Self.now, defaultTimeZone: Self.utc) == nil)
    }

    @Test func hardLimitWithoutParseableTimeDetectsNothing() {
        // notify-only path: hard wording but no reset clause → nil (caller keeps
        // the plain error notification).
        let data = Self.transcript([Self.errorLine(text: "You've hit your session limit")])
        #expect(RateLimitDetection.detect(transcriptData: data, now: Self.now, timeZone: Self.utc) == nil)
    }

    @Test func scansFromEndForLastApiError() {
        let old = Self.errorLine(text: "API Error: 529")
        let newer = Self.errorLine(text: "You've hit your session limit · resets 3pm (UTC)")
        let hit = RateLimitDetection.detect(
            transcriptData: Self.transcript([old, newer]), now: Self.now, timeZone: Self.utc)
        #expect(hit != nil)
    }

    // MARK: - hasRecord(newerThan:)

    @Test func hasRecordNewerThanComparesLastTimestamp() {
        let line = Self.errorLine(text: "x", timestamp: "2026-07-03T14:05:00.000Z")
        let data = Self.transcript([line])
        #expect(RateLimitDetection.hasRecord(newerThan: Self.now, in: data))
        #expect(!RateLimitDetection.hasRecord(
            newerThan: Self.now.addingTimeInterval(600), in: data))
    }

    // MARK: - errorClass surfacing

    @Test func detectWithTextSurfacesErrorClassFromRecord() {
        let obj: [String: Any] = [
            "type": "assistant",
            "isApiErrorMessage": true,
            "timestamp": "2026-07-03T14:00:00.123Z",
            "error": "server_error",
            "message": ["role": "assistant",
                        "content": [["type": "text", "text": "API Error: Connection closed mid-response."]]]
        ]
        let lineData = try! JSONSerialization.data(withJSONObject: obj)
        let line = String(data: lineData, encoding: .utf8)!
        let scan = RateLimitDetection.detectWithText(
            transcriptData: Self.transcript([line]), now: Self.now, timeZone: Self.utc)
        #expect(scan?.errorClass == "server_error")
    }

    // MARK: - ResumeTimeFormatter

    @Test func formatterDropsZeroMinutes() {
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents(); comps.year = 2026; comps.month = 7; comps.day = 3
        comps.hour = 13; comps.minute = 0
        var utcCal = cal; utcCal.timeZone = Self.utc
        let onePM = utcCal.date(from: comps)!
        #expect(ResumeTimeFormatter.string(from: onePM, timeZone: Self.utc) == "1pm")
        comps.minute = 1
        let oneOhOne = utcCal.date(from: comps)!
        #expect(ResumeTimeFormatter.string(from: oneOhOne, timeZone: Self.utc) == "1:01pm")
    }
}
