import Foundation
import Testing

@testable import TBDCLI

@Suite("StopFailureMessage")
struct StopFailureMessageTests {

    /// Build a one-line transcript JSONL containing a single API-error
    /// assistant entry with the given text.
    private static func transcript(text: String) -> Data {
        let line = """
        {"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"error":"rate_limit","message":{"role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
        """
        return Data((line + "\n").utf8)
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
        let outcome = StopFailureMessage.computeOutcome(
            stdinData: Self.stdin(errorType: "rate_limit", transcriptPath: "/x.jsonl"),
            readFile: { _ in Self.transcript(text: text) },
            now: Date(timeIntervalSince1970: 1_783_173_600),  // 14:00 UTC
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
        let staleData = Data((#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"# + "\n").utf8)
        let readyData = Self.transcript(text: text)
        let counter = CallCounter()
        let outcome = StopFailureMessage.computeOutcomeWithRetry(
            stdinData: Self.stdinWithExtras(error: "rate_limit", transcriptPath: "/x.jsonl"),
            readFile: { _ in
                counter.count += 1
                return counter.count < 3 ? staleData : readyData
            },
            now: Date(timeIntervalSince1970: 1_783_173_600),
            timeZone: TimeZone(identifier: "UTC")!,
            waiter: { _ in },
            maxRetries: 6,
            retryInterval: 0.001)
        #expect(counter.count == 3)
        #expect(outcome.message == text)
        #expect(outcome.detectedLimit != nil)
        #expect(outcome.detectedLimit!.rawMessage == text)
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
}
