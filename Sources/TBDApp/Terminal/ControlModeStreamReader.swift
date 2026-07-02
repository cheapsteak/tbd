import Darwin
import Foundation
import os

/// Owns a single vended pipe read fd and drains it on a dedicated `Thread`,
/// delivering each `read()` chunk to a callback. Long-lived — held by
/// `ControlModeReaderRegistry` at app scope, so SwiftUI view destruction does
/// not tear it down (a v1 blocker resolved by keeping state off the view).
///
/// The reader thread OWNS the fd: it closes it when the loop exits. `stop()`
/// only sets a flag — on Darwin, `close()`ing an fd under a thread blocked in
/// `read()` does not wake it and races fd-number reuse (same reasoning as
/// `TmuxControlConnection.stop()` on the daemon side). The loop exits via EOF,
/// which teardown guarantees by always pairing `stop()` with the `pane.detach`
/// RPC (the daemon closes the pipe's write end).
final class ControlModeStreamReader: @unchecked Sendable {
    /// Composite worktreeID/paneID key (matches `FDVendHeader.routingKey`).
    let routingKey: String
    private let fd: Int32
    private let logger = Logger(subsystem: "com.tbd.app", category: "controlModeReader")
    private var thread: Thread?
    private let onChunk: @Sendable (Data) -> Void
    private let stateLock = NSLock()
    private var stopped = false

    private var isStopped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopped
    }

    init(routingKey: String, fd: Int32, onChunk: @escaping @Sendable (Data) -> Void) {
        self.routingKey = routingKey
        self.fd = fd
        self.onChunk = onChunk
    }

    /// Start the reader thread. Safe to call once.
    func start() {
        precondition(thread == nil, "start called twice")
        let thread = Thread { [self] in self.readLoop() }
        thread.name = "controlmode-reader-\(routingKey)"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    /// Ask the reader to stop delivering chunks. Does NOT close the fd (the
    /// reader thread does, on exit). Callers must also send `pane.detach` so
    /// the daemon EOFs the pipe and unblocks the reader.
    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !isStopped {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            if isStopped { break }
            onChunk(Data(buffer[0..<Int(count)]))
        }
        Darwin.close(fd)
        logger.info("reader exited \(self.routingKey, privacy: .public)")
    }
}
