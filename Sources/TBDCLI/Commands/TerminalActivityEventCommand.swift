import ArgumentParser
import Foundation
import os
import TBDShared

private let activityLogger = Logger(subsystem: "com.tbd.cli", category: "terminalActivity")

/// Bridges agent hook events into TBD's terminal activity model. The command
/// is intentionally generic so Codex hooks can publish explicit lifecycle
/// changes without the app scraping tmux pane titles.
struct TerminalActivityEventCommand: AsyncParsableCommand {
    private static let hookPayloadByteLimit = 1 << 20

    static let configuration = CommandConfiguration(
        commandName: "terminal-activity",
        abstract: "Internal: bridge terminal activity state changes into TBD",
        shouldDisplay: false
    )

    enum ActivityArgument: String, ExpressibleByArgument {
        case unknown
        case working
        case idle
        case waitingForUser = "waiting_for_user"

        var activityState: TerminalActivityState {
            switch self {
            case .unknown: return .unknown
            case .working: return .working
            case .idle: return .idle
            case .waitingForUser: return .waitingForUser
            }
        }
    }

    @Argument(help: "Activity state to publish")
    var state: ActivityArgument

    @Flag(help: "Read Codex hook identity from stdin")
    var readHookPayload = false

    /// Set by the Claude `UserPromptSubmit` hook only. Asks the daemon for the
    /// session's title and, when one comes back, prints the hook output that
    /// sets it.
    @Flag(help: "Print a UserPromptSubmit sessionTitle hook output when the daemon returns one")
    var sessionTitle = false

    private struct HookPayload: Decodable {
        let session_id: String?
    }

    static func readBoundedHookPayload(from handle: FileHandle) -> Data? {
        var data = Data()
        while data.count <= hookPayloadByteLimit {
            let remaining = hookPayloadByteLimit + 1 - data.count
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: remaining) else { return data }
                chunk = next
            } catch {
                return nil
            }
            guard !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        return nil
    }

    static func sessionID(fromHookPayload data: Data) -> String? {
        guard !data.isEmpty, data.count <= hookPayloadByteLimit,
              let sessionID = try? JSONDecoder().decode(HookPayload.self, from: data).session_id,
              !sessionID.isEmpty else { return nil }
        return sessionID
    }

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

    /// The title carried by a `terminal.activityEvent` response, or nil for an
    /// empty success, a failure, or a result that does not decode.
    static func title(from response: RPCResponse) -> String? {
        guard response.success else { return nil }
        return (try? response.decodeResult(TerminalActivityEventResult.self))?.sessionTitle
    }

    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let terminalIDString = environment["TBD_TERMINAL_ID"],
              let terminalID = UUID(uuidString: terminalIDString) else {
            activityLogger.debug("suppressed reason=noTerminalID")
            return
        }

        let client = SocketClient()
        guard client.isDaemonRunning else {
            activityLogger.debug("suppressed reason=daemonDown")
            return
        }

        do {
            let sessionID = readHookPayload
                ? Self.readBoundedHookPayload(from: FileHandle.standardInput)
                    .flatMap(Self.sessionID(fromHookPayload:))
                : nil
            let params = TerminalActivityEventParams(
                terminalID: terminalID,
                activityState: state.activityState,
                sessionID: sessionID,
                sessionIncarnationID: Self.sessionIncarnationID(environment: environment),
                wantsSessionTitle: sessionTitle ? true : nil
            )
            guard sessionTitle else {
                try client.callVoid(method: RPCMethod.terminalActivityEvent, params: params)
                return
            }
            // A hook's stdout is read as its output, so nothing but the hook
            // JSON may reach it, and only when there is a title to set. Every
            // failure stays silent and exits 0: a title must never cost the
            // user their prompt.
            let response = try client.send(
                RPCRequest(method: RPCMethod.terminalActivityEvent, params: params))
            if !response.success {
                activityLogger.debug("suppressed reason=rpcFailed err=\(response.error ?? "unknown", privacy: .public)")
            }
            if let output = Self.hookOutput(sessionTitle: Self.title(from: response)) {
                print(output)
            }
        } catch {
            activityLogger.debug("suppressed reason=rpcFailed err=\(error.localizedDescription, privacy: .public)")
        }
    }
}
