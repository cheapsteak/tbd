import ArgumentParser
import Foundation
import os
import TBDShared

private let sessionEndLogger = Logger(subsystem: "com.tbd.cli", category: "sessionEnd")

/// Bridges Claude Code's `SessionEnd` hook into TBD so a session that exits
/// while background agents are live cannot leave a standing delegation claim,
/// and so the daemon knows the session's process is gone.
///
/// Every failure is silent, like every other hook bridge: a hook must never
/// wedge or redden the agent it observes.
struct SessionEndCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-end",
        abstract: "Internal: report that an agent session ended",
        shouldDisplay: false
    )

    /// The fields this command reads out of Claude Code's `SessionEnd` payload.
    /// Everything optional, everything else ignored — payload extensions are
    /// additive and must not break the bridge.
    private struct HookPayload: Decodable {
        let reason: String?
    }

    static func sessionIncarnationID(environment: [String: String]) -> UUID? {
        environment["TBD_TERMINAL_INCARNATION_ID"].flatMap(UUID.init(uuidString:))
    }

    /// Lift `reason` out of a hook payload. Static and pure so the parse is
    /// testable without a pipe. The 1 MiB cap bounds *processing*, matching
    /// `SessionEventCommand`; a payload that is empty, oversized, or not the
    /// object this expects yields nil, which the daemon reads as "we do not know".
    static func hookReason(from data: Data) -> String? {
        guard !data.isEmpty, data.count <= 1 << 20,
              let payload = try? JSONDecoder().decode(HookPayload.self, from: data)
        else { return nil }
        return payload.reason
    }

    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let terminalIDString = environment["TBD_TERMINAL_ID"],
              let terminalID = UUID(uuidString: terminalIDString) else {
            sessionEndLogger.debug("suppressed reason=noTerminalID")
            return
        }

        // Read stdin BEFORE the daemon check: Claude Code pipes the payload and
        // waits on the write, so a command that exits without draining it can
        // leave the hook's writer blocked on a full pipe until its timeout.
        let reason = Self.hookReason(from: FileHandle.standardInput.readDataToEndOfFile())

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
                    sessionIncarnationID: Self.sessionIncarnationID(environment: environment),
                    reason: reason)
            )
        } catch {
            sessionEndLogger.debug(
                "suppressed reason=rpcFailed err=\(error.localizedDescription, privacy: .public)")
        }
    }
}
