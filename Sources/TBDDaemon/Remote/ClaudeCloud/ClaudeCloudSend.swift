import Foundation
import TBDShared

/// Turning the contract's keystroke bytes into one message.
enum ClaudeCloudSendPayload {
    /// The contract's `send` delivers stdin bytes verbatim to a session as
    /// keystrokes, and requires the caller to append `\r` when it means the
    /// terminal Enter key. TBD sends a cloud session exactly the bytes it
    /// sends any provider; what the contract fixes is the CALLER's side of
    /// the wire, and how a provider delivers those bytes to a session with no
    /// terminal is the provider's business.
    ///
    /// So: decode as UTF-8, strip a SINGLE trailing `\r` or `\n` as the
    /// submit gesture it is, and pass the remainder as one message. A byte
    /// stream carrying interior newlines therefore becomes one multi-line
    /// message rather than several, and a deliberate blank last line survives.
    /// Nil means there is nothing to send.
    static func message(fromStdin stdin: Data) -> String? {
        // swiftlint:disable:next optional_data_string_conversion
        var text = String(decoding: stdin, as: UTF8.self)
        if text.hasSuffix("\r") || text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? nil : text
    }
}

private struct ClaudeCloudSendReply: Decodable {
    let ok: Bool?
    let sessionID: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case ok, url
        case sessionID = "session_id"
    }
}

extension ClaudeCloudInvoker {
    /// `send` posts one message through
    /// `claude -p "<msg>" --cloud <id> --output-format json`. `ok` plus a
    /// `session_id` matching the id sent is the success condition.
    ///
    /// No pseudo-terminal: `--print` is explicitly a non-interactive
    /// invocation and returns JSON on an ordinary pipe, and a pty would merge
    /// stderr into that JSON.
    func send(sessionID: String, stdin: Data?) async throws -> ProviderResult {
        guard let stdin, let message = ClaudeCloudSendPayload.message(fromStdin: stdin) else {
            return Self.errorResult(
                exitCode: 2, code: "invalid_params",
                message: "send received no message bytes")
        }
        let request = ClaudeCloudSpawnRequest(
            arguments: ["-p", message, "--cloud", sessionID, "--output-format", "json"],
            workingDirectory: FileManager.default.temporaryDirectory.path,
            usesPseudoTerminal: false,
            timeout: 30)
        switch try await spawner.spawn(request) {
        case .timedOut:
            return Self.errorResult(
                exitCode: 3, code: "unreachable",
                message: "claude -p --cloud did not answer before its deadline")
        case let .completed(status, output):
            guard status == 0 else {
                return Self.errorResult(
                    exitCode: 1, code: "unreachable",
                    message: "claude -p --cloud exited \(status): \(Self.bounded(output))")
            }
            guard let reply = try? JSONDecoder().decode(
                ClaudeCloudSendReply.self, from: Data(output.utf8))
            else {
                return Self.errorResult(
                    exitCode: 1, code: "unreachable",
                    message: "claude -p --cloud returned unparseable output: \(Self.bounded(output))")
            }
            guard reply.ok == true, reply.sessionID == sessionID else {
                return Self.errorResult(
                    exitCode: 1, code: "unreachable",
                    message: "claude -p --cloud did not accept the message for \(sessionID) "
                        + "(ok=\(String(describing: reply.ok)), "
                        + "session_id=\(reply.sessionID ?? "nil"))")
            }
            // The contract's `send` answers `{}`. Exit 0 keeps its contract
            // meaning: handed to the transport, not acted upon.
            return ProviderResult(exitCode: 0, stdout: Data("{}".utf8), stderr: "")
        }
    }

    static func bounded(_ text: String, limit: Int = 400) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }
}
