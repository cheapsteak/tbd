import ArgumentParser
import Foundation
import os
import TBDShared

private let sessionTitleLogger = Logger(subsystem: "com.tbd.cli", category: "sessionTitle")

/// Claude Code's `UserPromptSubmit` hook: asks the daemon for the title the
/// session should take and, when one comes back, prints the hook output that
/// sets it (see `ClaudeSessionTitle` and
/// docs/specs/2026-10-14-session-title-sync-design.md).
///
/// A hook's stdout is read as its output — `UserPromptSubmit`'s becomes model
/// context — so nothing but the hook JSON may reach it, and only when there is
/// a title to set. Every failure stays silent and exits 0: a title must never
/// cost the user their prompt.
struct SessionTitleHookCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-title",
        abstract: "Internal: hand a Claude session the title TBD wants for it",
        shouldDisplay: false
    )

    static func sessionIncarnationID(environment: [String: String]) -> UUID? {
        environment["TBD_TERMINAL_INCARNATION_ID"].flatMap(UUID.init(uuidString:))
    }

    private struct HookOutput: Encodable {
        struct Specific: Encodable {
            let hookEventName: String
            let sessionTitle: String
        }
        let hookSpecificOutput: Specific
    }

    /// The `UserPromptSubmit` hook output that sets the session's title, or
    /// nil when there is no title to set. Encoded rather than interpolated, so
    /// a display name with quotes or backslashes stays valid JSON.
    static func hookOutput(sessionTitle: String?) -> String? {
        guard let sessionTitle, !sessionTitle.isEmpty else { return nil }
        let output = HookOutput(hookSpecificOutput: .init(
            hookEventName: "UserPromptSubmit", sessionTitle: sessionTitle))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(output) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The title carried by a `terminal.sessionTitle` response, or nil for an
    /// empty success, a failure, or a result that does not decode.
    static func title(from response: RPCResponse) -> String? {
        guard response.success else { return nil }
        return (try? response.decodeResult(TerminalSessionTitleResult.self))?.sessionTitle
    }

    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let terminalIDString = environment["TBD_TERMINAL_ID"],
              let terminalID = UUID(uuidString: terminalIDString) else {
            sessionTitleLogger.debug("suppressed reason=noTerminalID")
            return
        }

        let client = SocketClient()
        guard client.isDaemonRunning else {
            sessionTitleLogger.debug("suppressed reason=daemonDown")
            return
        }

        do {
            let response = try client.send(RPCRequest(
                method: RPCMethod.terminalSessionTitle,
                params: TerminalSessionTitleParams(
                    terminalID: terminalID,
                    sessionIncarnationID: Self.sessionIncarnationID(environment: environment))))
            if !response.success {
                sessionTitleLogger.debug("suppressed reason=rpcFailed err=\(response.error ?? "unknown", privacy: .public)")
            }
            if let output = Self.hookOutput(sessionTitle: Self.title(from: response)) {
                print(output)
            }
        } catch {
            sessionTitleLogger.debug("suppressed reason=rpcFailed err=\(error.localizedDescription, privacy: .public)")
        }
    }
}
