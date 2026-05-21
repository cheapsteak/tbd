import Foundation
import os

/// Owns a single `tmux -CC attach` control-mode connection to one tmux server.
///
/// stdout is drained on a dedicated `Thread` so a burst of `%output` cannot
/// starve the cooperative thread pool. Decoded events are delivered through
/// `events`, an `AsyncStream` the caller iterates. `start()` then `stop()` is
/// the expected lifecycle; both are safe to call once.
///
/// Thread-safety: this type is `@unchecked Sendable`. `start()` and `stop()`
/// are called only from the owning `TmuxControlSupervisor` actor, so they are
/// serialized. `parser` is touched exclusively by the reader thread.
/// `stdinHandle` is guarded by `stdinLock`. `process` is fully configured in
/// `start()` before `run()`; afterwards only `terminate()`/`isRunning` are
/// used. `AsyncStream.Continuation` is itself thread-safe.
final class TmuxControlConnection: @unchecked Sendable {
    let serverName: String
    private let tmuxBinary: String
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")

    private let process = Process()
    private let parser = TmuxControlParser()
    private let stdinLock = NSLock()
    private var stdinHandle: FileHandle?

    /// Stream of decoded protocol events. Finishes when the connection stops
    /// or the tmux process exits.
    let events: AsyncStream<TmuxControlEvent>
    private let eventContinuation: AsyncStream<TmuxControlEvent>.Continuation

    init(serverName: String, tmuxBinary: String = TmuxManager.tmuxPath()) {
        self.serverName = serverName
        self.tmuxBinary = tmuxBinary
        var continuation: AsyncStream<TmuxControlEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    /// Spawn `tmux -CC attach` and begin draining its output. Throws if the
    /// process fails to launch.
    func start() throws {
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tmuxBinary)
        process.arguments = ["-L", serverName, "-CC", "attach", "-t", "main"]
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe
        process.standardError = FileHandle.nullDevice
        stdinHandle = stdinPipe.fileHandleForWriting

        let server = serverName
        process.terminationHandler = { [weak self] proc in
            self?.logger.info(
                "tmux -CC connection for \(server, privacy: .public) exited, status \(proc.terminationStatus)")
            self?.eventContinuation.finish()
        }

        try process.run()
        logger.info("started tmux -CC connection for server \(server, privacy: .public)")

        let readHandle = stdoutPipe.fileHandleForReading
        let thread = Thread { [weak self] in self?.readLoop(readHandle) }
        thread.name = "tmux-control-\(serverName)"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Stop the connection: close stdin, terminate tmux, finish the stream.
    func stop() {
        stdinLock.lock()
        try? stdinHandle?.close()
        stdinHandle = nil
        stdinLock.unlock()
        if process.isRunning { process.terminate() }
        eventContinuation.finish()
    }

    /// Write a raw tmux command line to the control client's stdin.
    /// Phase 1 has no production callers; exercising the path here keeps later
    /// phases (resize, send-keys) on a working writer.
    func sendCommand(_ command: String) {
        stdinLock.lock()
        defer { stdinLock.unlock() }
        guard let handle = stdinHandle else { return }
        let line = command.hasSuffix("\n") ? command : command + "\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private func readLoop(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // EOF
            for event in parser.feed(chunk) {
                eventContinuation.yield(event)
            }
        }
        eventContinuation.finish()
    }
}
