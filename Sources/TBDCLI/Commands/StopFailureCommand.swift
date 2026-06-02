import ArgumentParser
import Foundation

/// `tbd hooks stop-failure` — handler for Claude Code's StopFailure hook,
/// which fires (unlike Stop) when a turn ends due to an API error. It reads
/// the verbatim error text Claude wrote to the transcript so the notification
/// distinguishes a session limit ("You've hit your session limit · resets
/// 3pm") from a transient rate limit ("Server is temporarily limiting
/// requests") — both of which arrive as error_type=rate_limit, so the type
/// alone is not enough.
///
/// Prints the message to stdout; the overlay pipes it into `tbd notify
/// --type error`. Prints nothing when stdin can't be parsed. Every failure is
/// a silent no-op so the agent is never wedged.
struct StopFailureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop-failure",
        abstract: "StopFailure-hook handler: emit a notification message for an API-error turn death"
    )

    mutating func run() async throws {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        if let message = StopFailureMessage.compute(
            stdinData: stdin,
            readFile: { path in try? Data(contentsOf: URL(fileURLWithPath: path)) }
        ) {
            print(message)
        }
    }
}

// MARK: - Pure core (testable)

/// Pure message-construction logic for `stop-failure`. Factored out so unit
/// tests exercise every branch without touching the filesystem.
enum StopFailureMessage {

    /// Build the notification message for a StopFailure payload.
    /// - Returns: the verbatim API-error text from the transcript when
    ///   available; else a generic fallback naming the `error_type`; else nil
    ///   when the stdin payload can't be parsed (caller prints nothing).
    static func compute(stdinData: Data, readFile: (String) -> Data?) -> String? {
        guard
            let payload = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any]
        else {
            return nil
        }

        let errorType = (payload["error_type"] as? String) ?? "unknown"
        let fallback = "Claude stopped: API error (\(errorType))"

        guard
            let transcriptPath = payload["transcript_path"] as? String,
            let data = readFile(transcriptPath),
            let text = lastApiErrorText(in: data)
        else {
            return fallback
        }
        return text
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
