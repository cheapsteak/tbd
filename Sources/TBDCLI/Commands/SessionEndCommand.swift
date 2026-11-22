import ArgumentParser
import Foundation
import os
import TBDShared

private let sessionEndLogger = Logger(subsystem: "com.tbd.cli", category: "sessionEnd")

/// Bridges Claude Code's `SessionEnd` hook into TBD so the daemon knows the
/// session's process is gone: it resolves the session's open prompts and, when
/// the process itself is leaving, stamps the terminal exited.
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

    /// The payload's `session_id`, decoded on its own, so a payload whose
    /// `reason` is malformed still names its session, and the other way round.
    private struct HookSessionPayload: Decodable {
        let sessionID: String?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
        }
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

    /// Lift `session_id` out of a hook payload, under the same cap as
    /// `hookReason`. Nil when the payload is empty, oversized, not the object
    /// this expects, or names no session; the daemon then judges the report by
    /// its incarnation alone.
    static func hookSessionID(from data: Data) -> String? {
        guard !data.isEmpty, data.count <= 1 << 20,
              let payload = try? JSONDecoder().decode(HookSessionPayload.self, from: data),
              let sessionID = payload.sessionID, !sessionID.isEmpty
        else { return nil }
        return sessionID
    }

    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment

        // Read stdin BEFORE any early return, including the terminal-ID guard
        // below: Claude Code pipes the payload and waits on the write, so a
        // command that exits without draining it can leave the hook's writer
        // blocked on a full pipe until its timeout.
        let payload = FileHandle.standardInput.readDataToEndOfFile()
        let reason = Self.hookReason(from: payload)
        let sessionID = Self.hookSessionID(from: payload)

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
                    sessionIncarnationID: Self.sessionIncarnationID(environment: environment),
                    reason: reason,
                    sessionID: sessionID)
            )
        } catch {
            sessionEndLogger.debug(
                "suppressed reason=rpcFailed err=\(error.localizedDescription, privacy: .public)")
        }
    }
}
