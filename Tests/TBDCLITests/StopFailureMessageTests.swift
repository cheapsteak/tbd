import Foundation
import Testing
import TBDShared

@testable import TBDCLI

@Suite("StopFailureMessage")
struct StopFailureMessageTests {

    /// ISO8601 (with fractional seconds) string for `date`, matching the
    /// `timestamp` format real transcript records carry.
    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Build a one-line transcript JSONL containing a single API-error
    /// assistant entry with the given text. `timestamp` defaults to "right
    /// now" — fine for tests that pass `now: Date()`; tests pinning `now` to
    /// a fixed instant must pass a matching `timestamp` explicitly, since the
    /// retry/detection path is recency-gated (records must be newer than
    /// `now - 10s`).
    private static func transcript(text: String, timestamp: Date = Date(), error: String = "rate_limit") -> Data {
        let line = """
        {"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"error":"\(error)","timestamp":"\(Self.iso(timestamp))","message":{"role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
        """
        return Data((line + "\n").utf8)
    }

    /// Two-line transcript: an OLD record (stale, from a prior resolved
    /// rate-limit incident) followed by a NEW one — used to prove the
    /// recency floor rejects the old record and only the new one is parsed.
    private static func transcript(old oldText: String, oldTimestamp: Date, new newText: String, newTimestamp: Date) -> Data {
        let oldLine = """
        {"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"error":"rate_limit","timestamp":"\(Self.iso(oldTimestamp))","message":{"role":"assistant","content":[{"type":"text","text":"\(oldText)"}]}}
        """
        let newLine = """
        {"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"error":"rate_limit","timestamp":"\(Self.iso(newTimestamp))","message":{"role":"assistant","content":[{"type":"text","text":"\(newText)"}]}}
        """
        return Data((oldLine + "\n" + newLine + "\n").utf8)
    }

    /// Transcript containing only a single OLD (stale) record — nothing new
    /// ever arrives.
    private static func staleOnlyTranscript(text: String, timestamp: Date) -> Data {
        transcript(text: text, timestamp: timestamp)
    }

    private static func stdin(errorType: String, transcriptPath: String?) -> Data {
        var obj: [String: Any] = ["error_type": errorType, "hook_event_name": "StopFailure"]
        if let transcriptPath { obj["transcript_path"] = transcriptPath }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    /// Build stdin using the real StopFailure hook's `error` key (not the
    /// legacy `error_type` this test file's other helper uses), optionally
    /// with `last_assistant_message` / `error_details` for payload-first
    /// detection tests.
    private static func stdinWithExtras(
        error: String? = nil,
        transcriptPath: String? = nil,
        lastAssistantMessage: String? = nil,
        errorDetails: String? = nil
    ) -> Data {
        var obj: [String: Any] = ["hook_event_name": "StopFailure"]
        if let error { obj["error"] = error }
        if let transcriptPath { obj["transcript_path"] = transcriptPath }
        if let lastAssistantMessage { obj["last_assistant_message"] = lastAssistantMessage }
        if let errorDetails { obj["error_details"] = errorDetails }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    /// Simple call-counting box for closures captured in synchronous test bodies.
    private final class CallCounter {
        var count = 0
    }

    @Test func sessionLimitReturnsVerbatimText() {
        let text = "You've hit your session limit · resets 3pm (America/Toronto)"
        let result = StopFailureMessage.compute(
            stdinData: Self.stdin(errorType: "rate_limit", transcriptPath: "/x.jsonl"),
            readFile: { _ in Self.transcript(text: text) }
        )
        #expect(result == text)
    }

    @Test func serverRateLimitReturnsVerbatimText() {
        let text = "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited"
        let result = StopFailureMessage.compute(
            stdinData: Self.stdin(errorType: "rate_limit", transcriptPath: "/x.jsonl"),
            readFile: { _ in Self.transcript(text: text) }
        )
        #expect(result == text)
    }

    @Test func unreadableTranscriptFallsBackToErrorType() {
        let result = StopFailureMessage.compute(
            stdinData: Self.stdin(errorType: "rate_limit", transcriptPath: "/missing.jsonl"),
            readFile: { _ in nil }
        )
        #expect(result == "Claude stopped: API error (rate_limit)")
    }

    @Test func noApiErrorLineFallsBackToErrorType() {
        let plain = Data(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#.utf8)
        let result = StopFailureMessage.compute(
            stdinData: Self.stdin(errorType: "server_error", transcriptPath: "/x.jsonl"),
            readFile: { _ in plain }
        )
        #expect(result == "Claude stopped: API error (server_error)")
    }

    @Test func missingErrorTypeFallsBackToUnknown() {
        let obj: [String: Any] = ["hook_event_name": "StopFailure"]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        let result = StopFailureMessage.compute(stdinData: data, readFile: { _ in nil })
        #expect(result == "Claude stopped: API error (unknown)")
    }

    @Test func unparseableStdinReturnsNil() {
        let result = StopFailureMessage.compute(
            stdinData: Data("not json".utf8),
            readFile: { _ in nil }
        )
        #expect(result == nil)
    }

    // MARK: - computeOutcome (auto-resume detection)

    @Test func hardLimitProducesDetectedLimitAndMessage() {
        let text = "You've hit your session limit · resets 3pm (UTC)"
        let now = Date(timeIntervalSince1970: 1_783_173_600)  // 14:00 UTC
        let outcome = StopFailureMessage.computeOutcome(
            stdinData: Self.stdin(errorType: "rate_limit", transcriptPath: "/x.jsonl"),
            readFile: { _ in Self.transcript(text: text, timestamp: now) },
            now: now,
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(outcome.message == text)
        #expect(outcome.detectedLimit != nil)
        #expect(outcome.detectedLimit!.rawMessage == text)
        #expect(outcome.detectedLimit!.resetsAt > Date(timeIntervalSince1970: 1_783_173_600))
    }

    @Test func transientProducesMessageButNoDetection() {
        let text = "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited"
        let outcome = StopFailureMessage.computeOutcome(
            stdinData: Self.stdin(errorType: "rate_limit", transcriptPath: "/x.jsonl"),
            readFile: { _ in Self.transcript(text: text) },
            now: Date(), timeZone: TimeZone(identifier: "UTC")!)
        #expect(outcome.message == text)         // existing behavior preserved
        #expect(outcome.detectedLimit == nil)
    }

    @Test func unparseableResetKeepsErrorNotificationPath() {
        let text = "You've hit your session limit"
        let outcome = StopFailureMessage.computeOutcome(
            stdinData: Self.stdin(errorType: "rate_limit", transcriptPath: "/x.jsonl"),
            readFile: { _ in Self.transcript(text: text) },
            now: Date(), timeZone: TimeZone(identifier: "UTC")!)
        #expect(outcome.message == text)          // notify only, never schedule
        #expect(outcome.detectedLimit == nil)
    }

    @Test func missingTranscriptHasFallbackMessageNoDetection() {
        let outcome = StopFailureMessage.computeOutcome(
            stdinData: Self.stdin(errorType: "rate_limit", transcriptPath: "/missing.jsonl"),
            readFile: { _ in nil },
            now: Date(), timeZone: TimeZone(identifier: "UTC")!)
        #expect(outcome.message == "Claude stopped: API error (rate_limit)")
        #expect(outcome.detectedLimit == nil)
    }

    // MARK: - Payload-first detection (race-free, no transcript read)

    @Test func payloadFirstViaLastAssistantMessageSkipsTranscriptRead() {
        let text = "You've hit your session limit · resets 3pm (UTC)"
        let counter = CallCounter()
        let outcome = StopFailureMessage.computeOutcomeWithRetry(
            stdinData: Self.stdinWithExtras(
                error: "rate_limit",
                transcriptPath: "/irrelevant.jsonl",
                lastAssistantMessage: text),
            readFile: { (_: String) -> Data? in counter.count += 1; return nil },
            now: Date(timeIntervalSince1970: 1_783_173_600),
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(counter.count == 0)
        #expect(outcome.message == text)
        #expect(outcome.detectedLimit != nil)
        #expect(outcome.detectedLimit!.rawMessage == text)
    }

    @Test func payloadFirstViaErrorDetailsSkipsTranscriptRead() {
        let text = "You've hit your session limit · resets 3pm (UTC)"
        let counter = CallCounter()
        let outcome = StopFailureMessage.computeOutcomeWithRetry(
            stdinData: Self.stdinWithExtras(
                error: "rate_limit",
                transcriptPath: "/irrelevant.jsonl",
                lastAssistantMessage: "just a plain non-matching message",
                errorDetails: text),
            readFile: { (_: String) -> Data? in counter.count += 1; return nil },
            now: Date(timeIntervalSince1970: 1_783_173_600),
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(counter.count == 0)
        #expect(outcome.message == text)
        #expect(outcome.detectedLimit != nil)
        #expect(outcome.detectedLimit!.rawMessage == text)
    }

    // MARK: - Retry backstop (transcript-append race)

    @Test func retryCatchesLateArrivingApiErrorRecord() {
        let text = "You've hit your session limit · resets 3pm (UTC)"
        let now = Date(timeIntervalSince1970: 1_783_173_600)
        let staleData = Data((#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"# + "\n").utf8)
        let readyData = Self.transcript(text: text, timestamp: now)
        let counter = CallCounter()
        let outcome = StopFailureMessage.computeOutcomeWithRetry(
            stdinData: Self.stdinWithExtras(error: "rate_limit", transcriptPath: "/x.jsonl"),
            readFile: { _ in
                counter.count += 1
                return counter.count < 3 ? staleData : readyData
            },
            now: now,
            timeZone: TimeZone(identifier: "UTC")!,
            waiter: { _ in },
            maxRetries: 6,
            retryInterval: 0.001)
        #expect(counter.count == 3)
        #expect(outcome.message == text)
        #expect(outcome.detectedLimit != nil)
        #expect(outcome.detectedLimit!.rawMessage == text)
    }

    // MARK: - Stale-record recency floor (review round 1: PR #375)

    /// A session's 2nd+ rate-limit hit: the transcript already carries an OLD
    /// resolved `isApiErrorMessage` record (minutes in the past) from a prior
    /// incident. The NEW record for THIS hit only lands on the 3rd read. The
    /// retry loop must genuinely wait for it — an existence-only gate would
    /// have satisfied on read 1 against the stale record and returned its
    /// (already-past) reset time.
    @Test func retryWaitsForNewRecordDespiteStaleOldRecordAlreadyPresent() {
        let now = Date(timeIntervalSince1970: 1_783_173_600)  // 14:00 UTC
        let oldText = "You've hit your session limit · resets 1pm (UTC)"
        let newText = "You've hit your session limit · resets 3pm (UTC)"
        let staleOnly = Self.staleOnlyTranscript(text: oldText, timestamp: now.addingTimeInterval(-300))
        let withNewRecord = Self.transcript(
            old: oldText, oldTimestamp: now.addingTimeInterval(-300),
            new: newText, newTimestamp: now)
        let counter = CallCounter()
        let outcome = StopFailureMessage.computeOutcomeWithRetry(
            stdinData: Self.stdinWithExtras(error: "rate_limit", transcriptPath: "/x.jsonl"),
            readFile: { _ in
                counter.count += 1
                return counter.count < 3 ? staleOnly : withNewRecord
            },
            now: now,
            timeZone: TimeZone(identifier: "UTC")!,
            waiter: { _ in },
            maxRetries: 6,
            retryInterval: 0.001)
        #expect(counter.count == 3)
        #expect(outcome.message == newText)
        #expect(outcome.detectedLimit != nil)
        #expect(outcome.detectedLimit!.rawMessage == newText)
        let expectedResetsAt = RateLimitDetection.parseResetTime(
            from: newText, now: now, defaultTimeZone: TimeZone(identifier: "UTC")!)
        #expect(expectedResetsAt != nil)
        #expect(outcome.detectedLimit!.resetsAt == expectedResetsAt)
        // Never the OLD record's (different, already-past-relative-to-`now`) reset time.
        let oldResetsAt = RateLimitDetection.parseResetTime(
            from: oldText, now: now, defaultTimeZone: TimeZone(identifier: "UTC")!)
        #expect(outcome.detectedLimit!.resetsAt != oldResetsAt)
    }

    /// Only the OLD stale record ever exists — no new record arrives before
    /// retries exhaust. Must fall back to the legacy message with no detected
    /// limit; the stale record must never be parsed.
    @Test func retryExhaustionNeverParsesStaleOldRecord() {
        let now = Date(timeIntervalSince1970: 1_783_173_600)
        let oldText = "You've hit your session limit · resets 1pm (UTC)"
        let staleOnly = Self.staleOnlyTranscript(text: oldText, timestamp: now.addingTimeInterval(-300))
        let counter = CallCounter()
        let outcome = StopFailureMessage.computeOutcomeWithRetry(
            stdinData: Self.stdinWithExtras(error: "rate_limit", transcriptPath: "/x.jsonl"),
            readFile: { _ in counter.count += 1; return staleOnly },
            now: now,
            timeZone: TimeZone(identifier: "UTC")!,
            waiter: { _ in },
            maxRetries: 6,
            retryInterval: 0.001)
        #expect(outcome.message == "Claude stopped: API error (rate_limit)")
        #expect(outcome.detectedLimit == nil)
        #expect(counter.count == 7)  // 1 initial + 6 retries
    }

    @Test func retryExhaustionFallsBackToLegacyMessage() {
        let staleData = Data((#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"# + "\n").utf8)
        let counter = CallCounter()
        let outcome = StopFailureMessage.computeOutcomeWithRetry(
            stdinData: Self.stdinWithExtras(error: "rate_limit", transcriptPath: "/x.jsonl"),
            readFile: { _ in counter.count += 1; return staleData },
            now: Date(),
            timeZone: TimeZone(identifier: "UTC")!,
            waiter: { _ in },
            maxRetries: 6,
            retryInterval: 0.001)
        #expect(outcome.message == "Claude stopped: API error (rate_limit)")
        #expect(outcome.detectedLimit == nil)
        #expect(counter.count == 7)  // 1 initial + 6 retries
    }

    // MARK: - `error` key fallback (real StopFailure payload key)

    @Test func errorKeyIsUsedWhenErrorTypeAbsent() {
        let outcome = StopFailureMessage.computeOutcome(
            stdinData: Self.stdinWithExtras(error: "rate_limit", transcriptPath: "/missing.jsonl"),
            readFile: { _ in nil },
            now: Date(), timeZone: TimeZone(identifier: "UTC")!)
        #expect(outcome.message == "Claude stopped: API error (rate_limit)")
        #expect(outcome.detectedLimit == nil)
    }

    // MARK: - Transient API-error detection (Task 6)

    /// Payload-first transient: a connection-closed `last_assistant_message`
    /// classifies as `connection_closed`, keeps the verbatim text, and never
    /// touches the transcript file.
    @Test func payloadFirstTransientViaLastAssistantMessageSkipsTranscriptRead() {
        let text = "API Error: Connection closed mid-response"
        let counter = CallCounter()
        let outcome = StopFailureMessage.computeOutcomeWithRetry(
            stdinData: Self.stdinWithExtras(
                error: "server_error",
                transcriptPath: "/irrelevant.jsonl",
                lastAssistantMessage: text),
            readFile: { (_: String) -> Data? in counter.count += 1; return nil },
            now: Date(timeIntervalSince1970: 1_783_173_600),
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(counter.count == 0)
        #expect(outcome.message == text)
        #expect(outcome.detectedLimit == nil)
        #expect(outcome.detectedTransient?.errorClass == "connection_closed")
        #expect(outcome.detectedTransient?.rawMessage == text)
    }

    /// Hard-limit precedence: a session-limit `last_assistant_message` with a
    /// parseable reset must be a detected LIMIT, never a transient — the
    /// payload-first hard-limit loop runs before the transient loop.
    @Test func hardLimitPayloadPrecedesTransient() {
        let text = "You've hit your session limit · resets 3pm (UTC)"
        let outcome = StopFailureMessage.computeOutcomeWithRetry(
            stdinData: Self.stdinWithExtras(
                error: "rate_limit",
                transcriptPath: "/irrelevant.jsonl",
                lastAssistantMessage: text),
            readFile: { (_: String) -> Data? in nil },
            now: Date(timeIntervalSince1970: 1_783_173_600),
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(outcome.detectedLimit != nil)
        #expect(outcome.detectedTransient == nil)
    }

    /// Transcript transient: no payload text keys, but the recent transcript
    /// record carries connection-closed text + `"error":"server_error"` — the
    /// transient is detected after passing the recency retry gate.
    @Test func transcriptTransientDetectedAfterRetryGate() {
        let text = "API Error: Connection closed mid-response"
        let now = Date(timeIntervalSince1970: 1_783_173_600)
        let outcome = StopFailureMessage.computeOutcome(
            stdinData: Self.stdinWithExtras(error: "server_error", transcriptPath: "/x.jsonl"),
            readFile: { _ in Self.transcript(text: text, timestamp: now, error: "server_error") },
            now: now,
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(outcome.detectedLimit == nil)
        #expect(outcome.detectedTransient?.errorClass == "connection_closed")
        #expect(outcome.message == text)
    }

    /// ErrorField-only on exhaustion: payload `error: "server_error"`, no text
    /// keys, and the transcript never gains a recent record before retries
    /// exhaust — the `server_error` field alone still counts as transient, and
    /// the message is the synthesized fallback.
    @Test func errorFieldOnlyTransientOnRetryExhaustion() {
        let counter = CallCounter()
        let outcome = StopFailureMessage.computeOutcomeWithRetry(
            stdinData: Self.stdinWithExtras(error: "server_error", transcriptPath: "/x.jsonl"),
            readFile: { _ in counter.count += 1; return nil },
            now: Date(timeIntervalSince1970: 1_783_173_600),
            timeZone: TimeZone(identifier: "UTC")!,
            waiter: { _ in },
            maxRetries: 2,
            retryInterval: 0.001)
        #expect(outcome.detectedLimit == nil)
        #expect(outcome.detectedTransient?.errorClass == "server_error")
        #expect(outcome.message == "Claude stopped: API error (server_error)")
    }

    /// Negative: an unknown error field with no text is neither a limit nor a
    /// transient — the legacy fallback message is byte-identical.
    @Test func unknownErrorNoTextIsNotTransient() {
        let outcome = StopFailureMessage.computeOutcome(
            stdinData: Self.stdinWithExtras(error: "unknown"),
            readFile: { _ in nil },
            now: Date(timeIntervalSince1970: 1_783_173_600),
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(outcome.detectedLimit == nil)
        #expect(outcome.detectedTransient == nil)
        #expect(outcome.message == "Claude stopped: API error (unknown)")
    }

    /// Negative: an OAuth/401 wording in `last_assistant_message` is a
    /// permanent auth failure — the exclusion guard wins even though the text
    /// also contains a connection-closed phrase, so both detections are nil and
    /// the message falls through to the legacy fallback.
    @Test func oauthTextIsExcludedFromTransient() {
        let text = "OAuth token expired · connection closed mid-response"
        let outcome = StopFailureMessage.computeOutcome(
            stdinData: Self.stdinWithExtras(error: "authentication_error", lastAssistantMessage: text),
            readFile: { _ in nil },
            now: Date(timeIntervalSince1970: 1_783_173_600),
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(outcome.detectedLimit == nil)
        #expect(outcome.detectedTransient == nil)
        #expect(outcome.message == "Claude stopped: API error (authentication_error)")
    }
}
