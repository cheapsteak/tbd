import ArgumentParser
import Foundation
import TBDShared

/// Bridges Claude Code's `SessionStart` hook into TBD. Reads the hook payload
/// from stdin (Claude pipes a JSON object with fields like `session_id`,
/// `transcript_path`, `source`, `cwd`), reads `$TBD_TERMINAL_ID` from the env
/// (set by the daemon at spawn time), and forwards the data to the daemon
/// via the `terminal.sessionEvent` RPC.
///
/// All failure paths are silent and exit 0 — Claude prints stderr from hooks
/// to the user's terminal, so any noise here would be surfaced as a hook
/// error message. The transcript pane simply won't update if the bridge
/// can't deliver the event; we'd rather degrade silently than spam the chat.
struct SessionEventCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-event",
        abstract: "Internal: bridge Claude Code's SessionStart hook into TBD"
    )

    /// JSON payload Claude Code emits to stdin for SessionStart hooks.
    /// We parse only the fields we need, treat all of them as optional,
    /// and ignore anything else. Future Claude payload extensions are
    /// additive — they shouldn't break this command.
    private struct HookPayload: Decodable {
        let session_id: String?
        let transcript_path: String?
        let source: String?
    }

    mutating func run() async throws {
        // 1. Resolve terminal ID from env. Without this, we can't route the
        //    event — silent exit (the hook is also configured globally and
        //    fires for non-TBD-spawned Claude sessions).
        guard let terminalIDString = ProcessInfo.processInfo.environment["TBD_TERMINAL_ID"],
              let terminalID = UUID(uuidString: terminalIDString) else {
            return
        }

        // 2. Read stdin (Claude pipes the hook payload here). Bound the
        //    read at 1 MiB to avoid a runaway hook flooding the CLI process.
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty, data.count <= 1 << 20,
              let payload = try? JSONDecoder().decode(HookPayload.self, from: data),
              let sessionID = payload.session_id, !sessionID.isEmpty else {
            return
        }

        // 3. Daemon-down → silent exit. The hook will fire again on the next
        //    session event after the daemon starts (or, in the worst case,
        //    the legacy fallback in handleTerminalTranscript still works).
        let client = SocketClient()
        guard client.isDaemonRunning else { return }

        // 4. Fire the RPC. Ignore the response — hook is best-effort.
        do {
            try client.callVoid(
                method: RPCMethod.terminalSessionEvent,
                params: TerminalSessionEventParams(
                    terminalID: terminalID,
                    sessionID: sessionID,
                    transcriptPath: payload.transcript_path,
                    source: payload.source
                )
            )
        } catch {
            return
        }
    }
}
