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

    mutating func run() async throws {
        guard let terminalIDString = ProcessInfo.processInfo.environment["TBD_TERMINAL_ID"],
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
            try client.callVoid(
                method: RPCMethod.terminalActivityEvent,
                params: TerminalActivityEventParams(
                    terminalID: terminalID,
                    activityState: state.activityState,
                    sessionID: sessionID
                )
            )
        } catch {
            activityLogger.debug("suppressed reason=rpcFailed err=\(error.localizedDescription, privacy: .public)")
        }
    }
}
