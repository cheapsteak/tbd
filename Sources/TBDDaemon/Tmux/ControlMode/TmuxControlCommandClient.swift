import Foundation
import os

/// Error surfaced to command senders.
enum TmuxCommandError: Error, Equatable {
    case commandFailed(lines: [String])   // %error block
    case connectionClosed                  // stream ended / client torn down with commands pending
    case invalidCommand                    // command text contained a newline (would desync the FIFO)
}

/// A single command queued on the control stream.
struct TmuxCommand: Sendable {
    let text: String
    var tolerateErrors: Bool = false
    let completion: @Sendable (Result<[String], TmuxCommandError>) -> Void
}

/// FIFO correlation layer over a `TmuxControlConnection`'s command stream
/// (addendum §1). Commands are written to the control client's stdin and their
/// `%begin`…`%end`/`%error` reply blocks are matched back to callers **by order**,
/// mirroring iTerm2's `commandQueue_`/`currentCommand_` design.
///
/// Order-based correlation is sound because of two protocol invariants, both
/// verified against live tmux by the Phase 1 integration test:
///   1. tmux processes commands written to the stream strictly in order, and
///      emits exactly one reply block per command in that same order.
///   2. tmux never interleaves `%output` *inside* a `%begin`…`%end` block, so a
///      reply block is delivered whole with nothing else between its markers.
/// The `%begin` sequence number is therefore validated/logged for diagnostics,
/// not used for matching — the queue head IS the command being replied to.
///
/// A desynced FIFO would deliver wrong responses to wrong callers, so any
/// protocol violation (a client-originated reply arriving with an empty queue)
/// tears the connection down via `onFatalError` rather than limping along; the
/// supervisor's stream-ended path then reconciles and calls `connectionClosed()`.
actor TmuxControlCommandClient {
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")

    /// Writes one command line (a single stream write, `\n`-terminated by the caller).
    private let writeLine: @Sendable (String) -> Void
    /// Invoked on an unrecoverable protocol violation to tear the connection down.
    private let onFatalError: @Sendable () -> Void

    /// Commands awaiting a reply, in the order they were written to the stream.
    private var pending: [TmuxCommand] = []
    /// Once closed, all sends fail fast with `.connectionClosed`.
    private var closed = false

    init(writeLine: @escaping @Sendable (String) -> Void,
         onFatalError: @escaping @Sendable () -> Void) {
        self.writeLine = writeLine
        self.onFatalError = onFatalError
    }

    /// Send one command and await its response lines. Throws `.commandFailed`
    /// on a `%error` reply (unless `tolerateErrors`), `.connectionClosed` if the
    /// connection is or becomes closed, or `.invalidCommand` if `command`
    /// contains a newline.
    func send(_ command: String, tolerateErrors: Bool = false) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(TmuxCommand(text: command, tolerateErrors: tolerateErrors) { result in
                continuation.resume(with: result)
            })
        }
    }

    /// Queue a batch of commands as ONE stream write so the group is atomic in
    /// the FIFO (addendum: command lists). Per-command completions still fire
    /// individually as each reply block arrives, in order.
    func sendList(_ commands: [TmuxCommand]) {
        guard !commands.isEmpty else { return }
        guard !closed else {
            for command in commands { command.completion(.failure(.connectionClosed)) }
            return
        }
        // Reject the whole batch if any text contains a newline — one entry
        // producing multiple blocks would desync every later entry's matching.
        if let bad = commands.first(where: { $0.text.contains("\n") }) {
            logger.fault("rejecting command list: entry contains a newline: \(bad.text, privacy: .public)")
            for command in commands { command.completion(.failure(.invalidCommand)) }
            return
        }
        pending.append(contentsOf: commands)
        writeLine(commands.map(\.text).joined(separator: "\n"))
    }

    /// Consume a parser event. Only client-originated command reply blocks touch
    /// the queue; everything else (server-originated blocks, `%output`, etc.) is
    /// ignored so the supervisor keeps its own logging for those.
    func handle(_ event: TmuxControlEvent) {
        switch event {
        case .commandSucceeded(let number, let fromClient, let lines):
            complete(number: number, fromClient: fromClient, result: .success(lines))
        case .commandFailed(let number, let fromClient, let lines):
            complete(number: number, fromClient: fromClient, result: .failure(.commandFailed(lines: lines)))
        default:
            break
        }
    }

    /// Fail every pending command in order with `.connectionClosed` and refuse
    /// further sends. Called by the supervisor when the event stream ends.
    func connectionClosed() {
        closed = true
        let drained = pending
        pending.removeAll()
        for command in drained { command.completion(.failure(.connectionClosed)) }
    }

    // MARK: - Internals

    private func enqueue(_ command: TmuxCommand) {
        guard !closed else {
            command.completion(.failure(.connectionClosed))
            return
        }
        // A newline would split into multiple reply blocks and desync the FIFO.
        if command.text.contains("\n") {
            logger.fault("rejecting command with embedded newline: \(command.text, privacy: .public)")
            command.completion(.failure(.invalidCommand))
            return
        }
        // Append THEN write with no suspension between: actor isolation makes
        // this atomic with respect to `handle`, so the queue head is in place
        // before any reply can be processed.
        pending.append(command)
        writeLine(command.text)
    }

    private func complete(number: Int, fromClient: Bool,
                          result: Result<[String], TmuxCommandError>) {
        // Not ours: the attach greeting or any server-originated block. This is
        // how the greeting (flags 0, arriving before we write anything) is absorbed.
        guard fromClient else {
            logger.debug("ignoring server-originated command block #\(number, privacy: .public)")
            return
        }
        // A client-originated reply with an empty queue means we've lost sync
        // with the stream — tear the connection down rather than mis-deliver.
        guard !pending.isEmpty else {
            logger.error("protocol violation: client reply #\(number, privacy: .public) with empty queue; tearing down")
            closed = true
            onFatalError()
            return
        }
        let command = pending.removeFirst()
        switch result {
        case .success:
            command.completion(result)
        case .failure:
            command.completion(result)
            // A `%error` is fatal (iTerm2 semantics) unless the caller opted to
            // tolerate it — the tolerate flag exists precisely so a failure
            // completes the command without killing the connection.
            if !command.tolerateErrors {
                logger.error("command #\(number, privacy: .public) failed without tolerateErrors; tearing down")
                closed = true
                onFatalError()
            }
        }
    }
}
