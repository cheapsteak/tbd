import Darwin
import Foundation
import os

/// Owns a single `tmux -CC attach` control-mode connection to one tmux server.
///
/// tmux's control client only emits its protocol stream when stdout is a tty,
/// and refuses to attach unless stdin is a tty — so the subprocess is driven
/// over a pty pair, not plain pipes. The child gets the pty replica as its
/// stdin/stdout; this object keeps the primary and drains it on a dedicated
/// `Thread` (not a Swift actor task) so a burst of `%output` cannot starve the
/// cooperative thread pool. Decoded events are delivered through `events`.
///
/// Thread-safety: this type is `@unchecked Sendable`. `start()` and `stop()`
/// are called only from the owning `TmuxControlSupervisor` actor, so they are
/// serialized. `parser` is touched exclusively by the reader thread. `primaryFD`
/// is guarded by `ioLock`. `process` is fully configured in `start()` before
/// `run()`; afterwards only `terminate()`/`isRunning` are used.
/// `AsyncStream.Continuation` is itself thread-safe. `outputSink` must be set
/// once BEFORE `start()` and is read only by the reader thread afterwards.
final class TmuxControlConnection: @unchecked Sendable {
    let serverName: String
    private let tmuxBinary: String
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")

    private let process = Process()
    private let parser = TmuxControlParser()
    private let ioLock = NSLock()
    /// pty primary fd; bidirectional (write = tmux stdin, read = tmux stdout).
    /// -1 before `start()` and after `stop()`.
    private var primaryFD: Int32 = -1
    /// Signaled by the reader thread once `read()` has returned EOF/error and
    /// the thread is about to exit. `stop()` waits on this before closing the
    /// primary fd: on Darwin, `close()`ing a fd out from under a thread blocked
    /// in `read()` does NOT wake that thread, so the fd must only be closed
    /// after the reader has already left the syscall.
    private let readerExited = DispatchSemaphore(value: 0)

    /// Fast-path consumer for render output. When set (BEFORE `start()`),
    /// `.output`/`.extendedOutput` events are delivered synchronously on the
    /// reader thread and NOT yielded into `events` — render bytes must not
    /// queue behind the logging actor in an unbounded AsyncStream, and Phase
    /// 6's EAGAIN-driven flow control needs writes to hit the pipe the moment
    /// they are decoded.
    var outputSink: (@Sendable (TmuxControlEvent) -> Void)?

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

    /// Spawn `tmux -CC attach` over a pty and begin draining its output.
    /// Throws if the pty cannot be allocated or the process fails to launch.
    func start() throws {
        var primary: Int32 = -1
        var replica: Int32 = -1
        var term = termios()
        cfmakeraw(&term)  // no echo / no canonical editing: feed tmux exact bytes
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &replica, nil, &term, &size) == 0 else {
            throw TmuxControlConnectionError.ptyAllocationFailed(errno)
        }

        let replicaHandle = FileHandle(fileDescriptor: replica, closeOnDealloc: false)
        process.executableURL = URL(fileURLWithPath: tmuxBinary)
        process.arguments = ["-L", serverName, "-CC", "attach", "-t", "main"]
        process.standardInput = replicaHandle
        process.standardOutput = replicaHandle
        process.standardError = FileHandle.nullDevice

        let server = serverName
        process.terminationHandler = { [weak self] proc in
            self?.logger.info(
                "tmux -CC connection for \(server, privacy: .public) exited, status \(proc.terminationStatus)")
            // Do NOT finish() the event stream here — the reader thread finishes
            // it after draining the final read() so no trailing %output is lost.
        }

        do {
            try process.run()
        } catch {
            Darwin.close(primary)
            Darwin.close(replica)
            throw error
        }
        // The child now holds the replica; close the parent's copy so the
        // primary sees EOF when the child exits.
        Darwin.close(replica)

        ioLock.lock()
        primaryFD = primary
        ioLock.unlock()

        logger.info("started tmux -CC connection for server \(server, privacy: .public)")

        let readFD = primary
        let thread = Thread { [weak self] in self?.readLoop(readFD) }
        thread.name = "tmux-control-\(serverName)"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// Stop the connection: escalate SIGTERM → SIGKILL so the child always
    /// releases the pty slave, then wait for the reader to observe EOF before
    /// closing the primary fd.
    ///
    /// Order matters. Terminating tmux first makes the child release the pty
    /// slave, which delivers EOF to the primary and lets the reader's blocked
    /// `read()` return cleanly. Only then is it safe to `close()` the primary —
    /// closing it while the reader is still parked in `read()` would leak the
    /// reader thread on Darwin. If tmux ignores SIGTERM for 500 ms, escalate to
    /// SIGKILL (uncatchable — the child cannot resist it), then wait up to a
    /// further 1.5 s for the reader to exit. `eventContinuation.finish()` is
    /// called only by the reader thread at the end of `readLoop`, so any
    /// trailing bytes decoded from the final `read()` are delivered first.
    func stop() {
        ioLock.lock()
        let fd = primaryFD
        primaryFD = -1
        ioLock.unlock()

        if process.isRunning {
            process.terminate()
            if readerExited.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
                if process.isRunning {
                    let pid = process.processIdentifier
                    if pid > 0 {
                        logger.info("escalating tmux -CC for \(self.serverName, privacy: .public) to SIGKILL after 500ms")
                        kill(pid, SIGKILL)
                    }
                }
                // Wait again even when the child exited during the first
                // window: exit delivers EOF, but the reader may not have left
                // `read()` yet, and closing the fd under a still-blocked
                // reader is exactly the leak this dance avoids.
                _ = readerExited.wait(timeout: .now() + .milliseconds(1500))
            }
        }

        if fd >= 0 { Darwin.close(fd) }
    }

    /// Write a raw tmux command line to the control client's stdin.
    /// Phase 1 has no production callers; exercising the path here keeps later
    /// phases (resize, send-keys) on a working writer.
    func sendCommand(_ command: String) {
        let bytes = Array((command.hasSuffix("\n") ? command : command + "\n").utf8)
        ioLock.lock()
        defer { ioLock.unlock() }
        guard primaryFD >= 0 else { return }
        _ = bytes.withUnsafeBytes { Darwin.write(primaryFD, $0.baseAddress, $0.count) }
    }

    private func readLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }  // 0 = EOF, <0 = error (EIO when the child exits)
            for event in parser.feed(Data(buffer[0..<count])) {
                switch event {
                case .output, .extendedOutput:
                    if let sink = outputSink { sink(event) } else { eventContinuation.yield(event) }
                default:
                    eventContinuation.yield(event)
                }
            }
        }
        // Unblock `stop()`: the reader has left `read()`, so the primary fd can
        // now be closed safely.
        readerExited.signal()
        eventContinuation.finish()
    }
}

/// Failure modes for `TmuxControlConnection.start()`.
enum TmuxControlConnectionError: Error {
    case ptyAllocationFailed(Int32)
}
