import ArgumentParser
import Foundation
import os
import TBDShared

private let sessionEndLogger = Logger(subsystem: "com.tbd.cli", category: "sessionEnd")

/// Bridges Claude Code's `SessionEnd` hook into TBD so a session that exits
/// while background agents are live cannot leave a standing delegation claim.
///
/// Every failure is silent, like every other hook bridge: a hook must never
/// wedge or redden the agent it observes.
struct SessionEndCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-end",
        abstract: "Internal: report that an agent session ended",
        shouldDisplay: false
    )

    static func sessionIncarnationID(environment: [String: String]) -> UUID? {
        environment["TBD_TERMINAL_INCARNATION_ID"].flatMap(UUID.init(uuidString:))
    }

    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let terminalIDString = environment["TBD_TERMINAL_ID"],
              let terminalID = UUID(uuidString: terminalIDString) else {
            sessionEndLogger.debug("suppressed reason=noTerminalID")
            return
        }

        let client = SocketClient()
        guard client.isDaemonRunning else {
            sessionEndLogger.debug("suppressed reason=daemonDown")
            return
        }

        do {
            try client.callVoid(
                method: RPCMethod.terminalSessionEnded,
                params: TerminalSessionEndedParams(
                    terminalID: terminalID,
                    sessionIncarnationID: Self.sessionIncarnationID(environment: environment))
            )
        } catch {
            sessionEndLogger.debug(
                "suppressed reason=rpcFailed err=\(error.localizedDescription, privacy: .public)")
        }
    }
}
