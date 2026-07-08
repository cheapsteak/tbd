import Foundation

/// A transient (retryable) API error extracted from a Claude Code transcript
/// or hook payload — distinct from a hard usage-limit hit (`DetectedRateLimit`).
public struct DetectedTransientError: Equatable, Sendable {
    /// Coarse category driving backoff policy in later tasks: `connection_closed`,
    /// `transient_429`, `server_5xx`, `timeout`, or `server_error`.
    public let errorClass: String
    /// Verbatim display text when available, else a synthesized fallback.
    public let rawMessage: String

    public init(errorClass: String, rawMessage: String) {
        self.errorClass = errorClass
        self.rawMessage = rawMessage
    }
}

/// Pure detection logic for transient (auto-retryable) API errors — the
/// counterpart to `RateLimitDetection` for hard usage limits.
///
/// Spec: docs/specs/2026-07-08-transient-api-error-auto-continue-design.md §Detection.
public enum TransientErrorDetection {

    /// Classify a candidate error message + the transcript record's
    /// top-level `error` field into a `DetectedTransientError`, or `nil` if
    /// this is not something to auto-retry.
    ///
    /// Order (spec):
    /// 1. Permanent-exclusion wordings (auth/billing) always win — never
    ///    auto-retry those, even if the caller passes a transient-looking
    ///    `errorField` alongside them.
    /// 2. Hard usage-limit wordings defer to `RateLimitDetection` — that
    ///    pipeline schedules its own resume; this classifier must not
    ///    double-schedule the same record (defensive: callers are expected
    ///    to have already checked `RateLimitDetection` first, but this
    ///    guards the contract even if they forgot).
    /// 3. Known transient text wordings, first match wins.
    /// 4. No usable text but a `server_error` error field still counts —
    ///    Claude Code sometimes omits display text on this class.
    /// 5. Otherwise, not a transient error we know how to retry.
    public static func detect(messageText: String?, errorField: String?) -> DetectedTransientError? {
        if let messageText, !messageText.isEmpty {
            if isPermanentExclusion(messageText) { return nil }
            if RateLimitDetection.isHardLimitMessage(messageText) { return nil }
            if let errorClass = classifyText(messageText) {
                return DetectedTransientError(errorClass: errorClass, rawMessage: messageText)
            }
        }

        // No matching text wording — fall back to the structured error field.
        guard errorField == "server_error" else { return nil }
        let rawMessage = (messageText?.isEmpty == false ? messageText! : nil) ?? "API error (server_error)"
        return DetectedTransientError(errorClass: "server_error", rawMessage: rawMessage)
    }

    /// Wordings that indicate an auth/billing failure, never auto-retryable
    /// regardless of any accompanying error field — retrying would just spin
    /// against the same permanent failure.
    private static func isPermanentExclusion(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("oauth") { return true }
        if lower.contains("authentication") { return true }
        if lower.contains("invalid api key") { return true }
        if lower.contains("credit balance") { return true }
        if lower.range(of: #"\b40[13]\b"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Known transient wordings, first match wins (spec: ordered allowlist).
    private static func classifyText(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("connection closed mid-response") { return "connection_closed" }
        if lower.contains("temporarily limiting requests") || lower.contains("not your usage limit") {
            return "transient_429"
        }
        if lower.range(of: #"api error:?\s*5\d\d"#, options: .regularExpression) != nil
            || lower.contains("overloaded") {
            return "server_5xx"
        }
        if lower.range(of: #"api error:?\s*429"#, options: .regularExpression) != nil {
            return "transient_429"
        }
        if lower.contains("timed out") || lower.contains("timeout") { return "timeout" }
        return nil
    }
}
