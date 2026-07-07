import ArgumentParser
import Foundation
import TBDShared

/// `tbd hooks stop-failure` — handler for Claude Code's StopFailure hook.
///
/// Two jobs:
/// 1. (existing) Print the verbatim API-error text so the overlay can pipe
///    it into `tbd notify --type error`.
/// 2. (auto-resume) When the error is a HARD usage limit, report it to the
///    daemon via `claude.rateLimitDetected` and print NOTHING — the daemon
///    emits the richer `limit_reached` notification instead, so the user
///    never sees a duplicate generic error banner. If the RPC cannot be
///    delivered (daemon down, no TBD_TERMINAL_ID), fall back to printing —
///    behavior is then identical to the pre-feature CLI.
struct StopFailureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop-failure",
        abstract: "StopFailure-hook handler: emit a notification message for an API-error turn death"
    )

    mutating func run() async throws {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let outcome = StopFailureMessage.computeOutcomeWithRetry(
            stdinData: stdin,
            readFile: { path in try? Data(contentsOf: URL(fileURLWithPath: path)) }
        )

        if let detected = outcome.detectedLimit, reportToDaemon(detected) {
            return  // daemon owns the limit_reached notification
        }
        if let message = outcome.message {
            print(message)
        }
    }

    /// Fire the rateLimitDetected RPC. Returns true only when the daemon
    /// accepted it. Silent on every failure — the hook must never wedge Claude.
    private func reportToDaemon(_ detected: DetectedRateLimit) -> Bool {
        guard let terminalIDString = ProcessInfo.processInfo.environment["TBD_TERMINAL_ID"],
              let terminalID = UUID(uuidString: terminalIDString) else {
            return false
        }
        let client = SocketClient()
        guard client.isDaemonRunning else { return false }
        do {
            try client.callVoid(
                method: RPCMethod.claudeRateLimitDetected,
                params: RateLimitDetectedParams(
                    terminalID: terminalID,
                    resetsAt: detected.resetsAt,
                    limitType: detected.limitType,
                    rawMessage: detected.rawMessage))
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Pure core (testable)

enum StopFailureMessage {

    struct Outcome {
        /// Text for the legacy `tbd notify --type error` pipe (nil = print nothing).
        let message: String?
        /// Non-nil when the transcript's last API error is a schedulable hard limit.
        let detectedLimit: DetectedRateLimit?
    }

    /// Pure detection + message construction; every branch unit-testable.
    ///
    /// Zero-retry entry point onto `computeOutcomeWithRetry` — with
    /// `maxRetries: 0` the retry loop body never executes and `waiter` is
    /// never invoked, so this stays synchronous and fast (no sleeping),
    /// giving byte-identical behavior to the pre-retry implementation for
    /// every existing caller/test, while still picking up the payload-key
    /// fix and payload-first detection (both pure, no retries needed).
    static func computeOutcome(
        stdinData: Data,
        readFile: (String) -> Data?,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> Outcome {
        computeOutcomeWithRetry(
            stdinData: stdinData,
            readFile: readFile,
            now: now,
            timeZone: timeZone,
            maxRetries: 0
        )
    }

    /// Full detection with a bounded retry backstop for the transcript-append
    /// race: Claude Code's StopFailure hook fires ~0.28-0.5s before the
    /// API-error record lands in the transcript JSONL, so a single read can
    /// miss it. Order:
    /// 1. Payload-first (race-free, no file I/O): `last_assistant_message`
    ///    then `error_details`, whichever first yields a hard-limit hit.
    /// 2. Transcript read, retried up to `maxRetries` times (`retryInterval`
    ///    apart) until `RateLimitDetection.hasApiErrorRecord(in:newerThan:)`
    ///    sees a record newer than `recencyFloor` (see below) — NOT merely
    ///    "a record exists", since the transcript is one continuously-growing
    ///    JSONL per terminal across resumes: an old, already-resolved
    ///    `isApiErrorMessage` record from a PRIOR hit would otherwise
    ///    permanently satisfy an existence-only gate on every hit after the
    ///    first, making the retry backstop a no-op.
    static func computeOutcomeWithRetry(
        stdinData: Data,
        readFile: (String) -> Data?,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        waiter: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        maxRetries: Int = 6,
        retryInterval: TimeInterval = 0.25
    ) -> Outcome {
        guard
            let payload = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any]
        else {
            return Outcome(message: nil, detectedLimit: nil)
        }

        let errorType = (payload["error"] as? String) ?? (payload["error_type"] as? String) ?? "unknown"
        let fallback = "Claude stopped: API error (\(errorType))"

        // Payload-first: race-free, never touches the transcript file.
        for key in ["last_assistant_message", "error_details"] {
            if let candidate = payload[key] as? String,
               let detected = RateLimitDetection.detect(messageText: candidate, now: now, timeZone: timeZone) {
                return Outcome(message: detected.rawMessage, detectedLimit: detected)
            }
        }

        guard let transcriptPath = payload["transcript_path"] as? String else {
            return Outcome(message: fallback, detectedLimit: nil)
        }

        // Recency floor for the transcript-append race: the StopFailure hook
        // fires ~0.28-0.5s before the API-error record lands in the
        // transcript, so a legitimate NEW record can appear slightly BEFORE
        // `now`. 10s is a generous backward tolerance for that — stale
        // records left over from a prior, already-resolved rate-limit
        // incident on this same continuously-growing transcript file are
        // minutes+ old, well outside this window, and must never be parsed
        // as the current detection.
        let recencyFloor = now.addingTimeInterval(-10)

        var data = readFile(transcriptPath)
        var attempts = 0
        while attempts < maxRetries
            && !(data.map { RateLimitDetection.hasApiErrorRecord(in: $0, newerThan: recencyFloor) } ?? false) {
            waiter(retryInterval)
            attempts += 1
            data = readFile(transcriptPath)
        }

        guard let data else {
            return Outcome(message: fallback, detectedLimit: nil)
        }

        // Single scan: derive both the detected limit and the display
        // message from the SAME floor-gated record — one parse of `data`
        // instead of two independent full-file scans for the same result.
        guard let scan = RateLimitDetection.detectWithText(
            transcriptData: data, now: now, timeZone: timeZone, newerThan: recencyFloor
        ) else {
            return Outcome(message: fallback, detectedLimit: nil)
        }
        return Outcome(message: scan.text ?? fallback, detectedLimit: scan.detectedLimit)
    }

    /// Legacy entry point — existing tests exercise this shape.
    static func compute(stdinData: Data, readFile: (String) -> Data?) -> String? {
        computeOutcome(stdinData: stdinData, readFile: readFile).message
    }
}
