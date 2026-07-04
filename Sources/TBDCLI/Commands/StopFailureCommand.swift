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
        let outcome = StopFailureMessage.computeOutcome(
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
    static func computeOutcome(
        stdinData: Data,
        readFile: (String) -> Data?,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> Outcome {
        guard
            let payload = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any]
        else {
            return Outcome(message: nil, detectedLimit: nil)
        }

        let errorType = (payload["error_type"] as? String) ?? "unknown"
        let fallback = "Claude stopped: API error (\(errorType))"

        guard
            let transcriptPath = payload["transcript_path"] as? String,
            let data = readFile(transcriptPath)
        else {
            return Outcome(message: fallback, detectedLimit: nil)
        }

        let detected = RateLimitDetection.detect(
            transcriptData: data, now: now, timeZone: timeZone)
        let text = lastApiErrorText(in: data)
        return Outcome(message: text ?? fallback, detectedLimit: detected)
    }

    /// Legacy entry point — existing tests exercise this shape.
    static func compute(stdinData: Data, readFile: (String) -> Data?) -> String? {
        computeOutcome(stdinData: stdinData, readFile: readFile).message
    }

    /// Scan transcript JSONL lines from the end; return the first
    /// `isApiErrorMessage == true` entry's first non-empty text block.
    static func lastApiErrorText(in data: Data) -> String? {
        guard let contents = String(data: data, encoding: .utf8) else { return nil }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard
                let lineData = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                obj["isApiErrorMessage"] as? Bool == true,
                let message = obj["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else {
                continue
            }
            for block in content where block["type"] as? String == "text" {
                if let text = block["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        return nil
    }
}
