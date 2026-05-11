import ArgumentParser
import Foundation
import os
import TBDShared

private let cliLogger = Logger(subsystem: "com.tbd.cli", category: "askUserQuestion")

/// Bridges Claude Code's `PreToolUse:AskUserQuestion` and
/// `PostToolUse:AskUserQuestion` hooks into TBD. Reads stdin (Claude pipes
/// the hook payload here), extracts `tool_use_id` and `tool_input`, and
/// RPCs the daemon so the transcript pane can render a synthetic
/// "Waiting for response…" card before the assistant message lands in the
/// JSONL.
///
/// All failure paths exit 0 silently — Claude prints hook stderr to the
/// user's terminal, so any noise here would be surfaced as a hook error
/// message. We'd rather degrade silently than spam the chat.
struct AskUserQuestionEventCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask-user-question",
        abstract: "Internal: bridge Claude Code's AskUserQuestion hooks into TBD",
        shouldDisplay: false,
        subcommands: [PreSubcommand.self, PostSubcommand.self]
    )

    struct PreSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "pre", shouldDisplay: false)
        mutating func run() async throws {
            await AskUserQuestionEventCommand.run(mode: .pre)
        }
    }

    struct PostSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "post", shouldDisplay: false)
        mutating func run() async throws {
            await AskUserQuestionEventCommand.run(mode: .post)
        }
    }

    enum Mode { case pre, post }

    static func run(mode: Mode) async {
        guard let terminalIDString = ProcessInfo.processInfo.environment["TBD_TERMINAL_ID"],
              let terminalID = UUID(uuidString: terminalIDString) else {
            cliLogger.debug("\(mode == .pre ? "pre" : "post") suppressed reason=noTerminalID")
            return
        }

        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty, data.count <= 1 << 20 else {
            cliLogger.debug("\(mode == .pre ? "pre" : "post") suppressed reason=emptyOrOversizedStdin bytes=\(data.count, privacy: .public)")
            return
        }

        let parsed: AskUserQuestionPayloadParser.Parsed
        do {
            parsed = try AskUserQuestionPayloadParser.parse(data)
        } catch {
            cliLogger.debug("\(mode == .pre ? "pre" : "post") suppressed reason=decodeFailed err=\(error.localizedDescription, privacy: .public)")
            return
        }

        if AskUserQuestionPayloadParser.isSubagentTranscript(parsed.transcriptPath) {
            cliLogger.debug("\(mode == .pre ? "pre" : "post") suppressed reason=subagent toolUseID=\(parsed.toolUseID, privacy: .public)")
            return
        }

        let client = SocketClient()
        guard client.isDaemonRunning else {
            cliLogger.debug("\(mode == .pre ? "pre" : "post") suppressed reason=daemonDown")
            return
        }

        do {
            switch mode {
            case .pre:
                try client.callVoid(
                    method: RPCMethod.terminalAskUserQuestionPending,
                    params: TerminalAskUserQuestionPendingParams(
                        terminalID: terminalID,
                        toolUseID: parsed.toolUseID,
                        inputJSON: parsed.toolInputJSON,
                        timestampMillis: Int64(Date().timeIntervalSince1970 * 1000)
                    )
                )
                cliLogger.debug("pre delivered toolUseID=\(parsed.toolUseID, privacy: .public) terminalID=\(terminalID.uuidString, privacy: .public)")
            case .post:
                try client.callVoid(
                    method: RPCMethod.terminalAskUserQuestionCleared,
                    params: TerminalAskUserQuestionClearedParams(
                        terminalID: terminalID,
                        toolUseID: parsed.toolUseID
                    )
                )
                cliLogger.debug("post delivered toolUseID=\(parsed.toolUseID, privacy: .public) terminalID=\(terminalID.uuidString, privacy: .public)")
            }
        } catch {
            cliLogger.debug("\(mode == .pre ? "pre" : "post") suppressed reason=rpcFailed err=\(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Pure parsing helpers, factored out so tests don't need stdin/env/RPC.
enum AskUserQuestionPayloadParser {
    struct Parsed: Equatable {
        let toolUseID: String
        let toolInputJSON: String
        let transcriptPath: String?
    }

    enum ParseError: Error { case invalidJSON, missingToolUseID }

    static func parse(_ data: Data) throws -> Parsed {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        guard let toolUseID = obj["tool_use_id"] as? String, !toolUseID.isEmpty else {
            throw ParseError.missingToolUseID
        }
        let toolInputJSON: String
        if let toolInput = obj["tool_input"],
           let toolInputData = try? JSONSerialization.data(withJSONObject: toolInput, options: [.sortedKeys]),
           let str = String(data: toolInputData, encoding: .utf8) {
            toolInputJSON = str
        } else {
            toolInputJSON = "{}"
        }
        let transcriptPath = obj["transcript_path"] as? String
        return Parsed(toolUseID: toolUseID, toolInputJSON: toolInputJSON, transcriptPath: transcriptPath)
    }

    /// Subagent JSONLs live under `.../subagents/<agent-id>.jsonl`. If the
    /// PreToolUse payload's `transcript_path` contains the `/subagents/`
    /// segment we suppress the RPC entirely — the synthetic merge only
    /// renders into the top-level items list, and a top-level synthetic
    /// for a subagent question would render in the wrong place.
    static func isSubagentTranscript(_ transcriptPath: String?) -> Bool {
        guard let path = transcriptPath, !path.isEmpty else { return false }
        return path.contains("/subagents/")
    }
}
