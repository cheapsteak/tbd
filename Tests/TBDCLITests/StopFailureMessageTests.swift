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
}
