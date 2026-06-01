import ArgumentParser
import Foundation
import os
import TBDShared

private let activityLogger = Logger(subsystem: "com.tbd.cli", category: "terminalActivity")

/// Bridges agent hook events into TBD's terminal activity model. The command
/// is intentionally generic so Codex hooks can publish explicit lifecycle
/// changes without the app scraping tmux pane titles.
struct TerminalActivityEventCommand: AsyncParsableCommand {
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
            try client.callVoid(
                method: RPCMethod.terminalActivityEvent,
                params: TerminalActivityEventParams(
                    terminalID: terminalID,
                    activityState: state.activityState
                )
            )
        } catch {
            activityLogger.debug("suppressed reason=rpcFailed err=\(error.localizedDescription, privacy: .public)")
        }
    }
}
