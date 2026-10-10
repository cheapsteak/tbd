import ArgumentParser
import Foundation
import os
import TBDShared

private let promptLogger = Logger(subsystem: "com.tbd.cli", category: "prompt")

/// Bridges Claude Code's `PreToolUse` / `PostToolUse` / `PostToolUseFailure`
/// (`note`) and `PermissionRequest` (`wait`) hooks into TBD, so a permission
/// dialog can be answered from the transcript
/// (`docs/specs/2026-10-09-transcript-prompt-answer-design.md`, "Hooks").
///
/// Every failure path prints nothing and exits 0. Stdout carries at most one
/// thing: the decision JSON the daemon handed back. Claude Code treats any
/// other stdout from a hook as a decision or an error, so silence is how the
/// terminal stays in charge.
struct PromptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prompt",
        abstract: "Internal: answer Claude Code prompts from the TBD transcript",
        shouldDisplay: false,
        subcommands: [NoteSubcommand.self, WaitSubcommand.self]
    )

    struct NoteSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "note", shouldDisplay: false)

        /// Fallback when the payload carries no `hook_event_name`; the payload
        /// wins when it does.
        @Option(name: .long, help: "pre or post (used only when the payload names no hook event)")
        var phase: String = "pre"

        mutating func run() async throws {
            let fallback: PromptNotePhase = phase == "post" ? .post : .pre
            await PromptCommand.runNote(fallbackPhase: fallback)
        }
    }

    struct WaitSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "wait", shouldDisplay: false)
        mutating func run() async throws {
            await PromptCommand.runWait()
        }
    }

    private static func terminalID() -> UUID? {
        ProcessInfo.processInfo.environment["TBD_TERMINAL_ID"].flatMap { UUID(uuidString: $0) }
    }

    private static func readStdin() -> Data? {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty, data.count <= 1 << 20 else { return nil }
        return data
    }

    static func runNote(fallbackPhase: PromptNotePhase) async {
        guard let terminalID = terminalID(), let data = readStdin(),
              let event = PromptHookPayloadParser.toolEvent(data, fallbackPhase: fallbackPhase) else {
            promptLogger.debug("note suppressed reason=noTerminalOrPayload")
            return
        }
        let client = SocketClient()
        guard client.isDaemonRunning else { return }
        do {
            try client.callVoid(
                method: RPCMethod.promptNote,
                params: PromptNoteParams(
                    terminalID: terminalID, sessionID: event.sessionID, phase: event.phase,
                    toolUseID: event.toolUseID, toolName: event.toolName, inputHash: event.inputHash))
        } catch {
            promptLogger.debug("note suppressed reason=rpcFailed err=\(error.localizedDescription, privacy: .public)")
        }
    }

    static func runWait() async {
        // A closed stdout must fail the write, not kill the process before it
        // can tell the daemon the decision never landed.
        signal(SIGPIPE, SIG_IGN)
        guard let terminalID = terminalID(), let data = readStdin(),
              let request = PromptHookPayloadParser.permissionRequest(data) else {
            promptLogger.debug("wait suppressed reason=noTerminalOrPayload")
            return
        }
        let waiter = PromptWaiter(
            transport: SocketPromptWaitTransport(client: SocketClient()),
            clock: ContinuousClock(),
            write: { text in
                do {
                    try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
                    return true
                } catch {
                    return false
                }
            })
        await waiter.run(terminalID: terminalID, request: request)
    }
}

// MARK: - Transport

/// What `prompt wait` needs from the daemon, so tests run without a socket.
protocol PromptWaitTransport: Sendable {
    var isDaemonRunning: Bool { get }
    func register(_ params: PromptRegisterParams) throws -> PromptRegisterResult
    /// Blocks until the daemon replies or the connection drops (throws).
    func awaitResolution(_ params: PromptAwaitParams) throws -> PromptAwaitReply
    func ack(_ params: PromptAckParams) throws
}

struct SocketPromptWaitTransport: PromptWaitTransport {
    let client: SocketClient

    var isDaemonRunning: Bool { client.isDaemonRunning }

    func register(_ params: PromptRegisterParams) throws -> PromptRegisterResult {
        try client.call(method: RPCMethod.promptRegister, params: params, resultType: PromptRegisterResult.self)
    }

    func awaitResolution(_ params: PromptAwaitParams) throws -> PromptAwaitReply {
        try client.call(method: RPCMethod.promptAwait, params: params, resultType: PromptAwaitReply.self)
    }

    func ack(_ params: PromptAckParams) throws {
        try client.callVoid(method: RPCMethod.promptAck, params: params)
    }
}

// MARK: - Payload parsing

enum PromptHookPayloadParser {
    struct PermissionRequest: Equatable {
        let sessionID: String
        let toolName: String
        let toolInputJSON: String
        let suggestionsJSON: String?
        let inputHash: String
        let transcriptPath: String?
    }

    struct ToolEvent: Equatable {
        let sessionID: String
        let toolUseID: String
        let toolName: String
        let phase: PromptNotePhase
        /// `PromptInputHash` of `tool_input`, on `pre` and `post` alike: a
        /// `post` closes an unpaired prompt by it.
        let inputHash: String?
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func sortedJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil on anything malformed.
    static func permissionRequest(_ data: Data) -> PermissionRequest? {
        guard let obj = object(data),
              let sessionID = obj["session_id"] as? String, !sessionID.isEmpty,
              let toolName = obj["tool_name"] as? String, !toolName.isEmpty else { return nil }
        let toolInput = obj["tool_input"] ?? [String: Any]()
        guard let toolInputJSON = sortedJSON(toolInput) else { return nil }
        let suggestionsJSON = obj["permission_suggestions"].flatMap { sortedJSON($0) }
        return PermissionRequest(
            sessionID: sessionID, toolName: toolName, toolInputJSON: toolInputJSON,
            suggestionsJSON: suggestionsJSON,
            inputHash: PromptInputHash.of(toolName: toolName, toolInput: toolInput),
            transcriptPath: obj["transcript_path"] as? String)
    }

    /// `hook_event_name` picks the phase; `fallbackPhase` applies only when the
    /// payload names no recognised event. nil on anything malformed.
    static func toolEvent(_ data: Data, fallbackPhase: PromptNotePhase = .pre) -> ToolEvent? {
        guard let obj = object(data),
              let sessionID = obj["session_id"] as? String, !sessionID.isEmpty,
              let toolUseID = obj["tool_use_id"] as? String, !toolUseID.isEmpty,
              let toolName = obj["tool_name"] as? String, !toolName.isEmpty else { return nil }
        let phase: PromptNotePhase
        switch obj["hook_event_name"] as? String {
        case "PreToolUse": phase = .pre
        case "PostToolUse", "PostToolUseFailure": phase = .post
        default: phase = fallbackPhase
        }
        let hash = PromptInputHash.of(toolName: toolName, toolInput: obj["tool_input"] ?? [String: Any]())
        return ToolEvent(sessionID: sessionID, toolUseID: toolUseID, toolName: toolName,
                         phase: phase, inputHash: hash)
    }
}

// MARK: - Waiter

struct PromptWaiter {
    let transport: any PromptWaitTransport
    let clock: any Clock<Duration>
    /// Writes the decision to stdout and flushes; false when that failed.
    let write: @Sendable (String) -> Bool
    /// Total time spent retrying against a daemon that dropped the wait.
    var reconnectBudget: Duration = .seconds(180)
    var reconnectInitialInterval: Duration = .milliseconds(500)
    var reconnectMaxInterval: Duration = .seconds(5)

    /// Registers, awaits, and prints. Never throws, and prints only a decision.
    func run(terminalID: UUID, request: PromptHookPayloadParser.PermissionRequest) async {
        guard transport.isDaemonRunning else {
            promptLogger.debug("wait suppressed reason=daemonDown")
            return
        }
        var promptID: String?
        var toolUseID: String?
        var interval = reconnectInitialInterval
        var spent = Duration.zero
        while true {
            do {
                let registered = try transport.register(PromptRegisterParams(
                    terminalID: terminalID, sessionID: request.sessionID, toolName: request.toolName,
                    toolInputJSON: request.toolInputJSON, suggestionsJSON: request.suggestionsJSON,
                    inputHash: request.inputHash, knownPromptID: promptID, knownToolUseID: toolUseID))
                switch registered {
                case .disabled:
                    return
                case .registered(let id, let pairedToolUseID):
                    promptID = id
                    // Keep a pairing already learned if a later reply lacks it.
                    toolUseID = pairedToolUseID ?? toolUseID
                }
                let reply = try transport.awaitResolution(PromptAwaitParams(promptID: promptID ?? ""))
                switch reply.result {
                case .resolvedElsewhere:
                    return
                case .answered(let hookOutput):
                    let delivered = write(hookOutput)
                    if let token = reply.deliveryToken {
                        try? transport.ack(PromptAckParams(token: token, delivered: delivered))
                    }
                    return
                }
            } catch {
                promptLogger.debug("wait retry err=\(error.localizedDescription, privacy: .public)")
            }
            // First register failing means the daemon never took the prompt:
            // nothing to resume, so stay silent rather than retry.
            guard promptID != nil, spent < reconnectBudget else { return }
            do { try await clock.sleep(for: interval) } catch { return }
            spent += interval
            interval = min(interval * 2, reconnectMaxInterval)
        }
    }
}
