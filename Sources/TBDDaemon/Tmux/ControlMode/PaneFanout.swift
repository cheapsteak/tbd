import Darwin
import Foundation
import os

/// Composite pane identity. tmux pane IDs ("%0", "%1", …) are only unique
/// within one tmux server, and TBD runs one server per repo — so every
/// control-mode map keys by (server, paneID), never bare paneID.
struct PaneKey: Hashable {
    let server: String
    let paneID: String
}

enum PaneFanoutError: Error {
    case pipeAllocationFailed(Int32)
}

/// Routes decoded `%output`/`%extended-output` bytes into per-pane pipe write
/// ends. `route(server:event:)` is called SYNCHRONOUSLY on each connection's
/// reader thread — the spec's data-flow keeps the render hot path off actors
/// (the v1 starvation blocker) and out of unbounded AsyncStream buffering.
/// The lock makes attach/markReady/detach (called from the supervisor actor)
/// safe against concurrent routing from reader threads.
final class PaneFanout: @unchecked Sendable {
    private struct Sink {
        var writeFD: Int32
        /// Monotonic attach identity. A re-attach for the same key replaces
        /// the sink with a HIGHER generation; stale ready-timeout timers from
        /// an earlier attach compare generations and become no-ops instead of
        /// killing the fresh attach.
        let generation: UInt64
        /// The attach handshake's write gate: false between `attach` (fd
        /// vended) and the app's `attach.ready` ack. Output routed while not
        /// ready is dropped — Phase 2 has no replay/buffering.
        var ready = false
        var droppedEvents = 0
        var droppedBytes = 0
        var lastDropLog = Date.distantPast
    }

    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")
    private let lock = NSLock()
    private var sinks: [PaneKey: Sink] = [:]
    private var nextGeneration: UInt64 = 0
    /// %output events dropped because no attach was registered for their pane.
    private var unattachedDrops = 0

    /// Allocate a pipe for `key`, remember the (nonblocking) write end, and
    /// return the read end (plus this attach's generation) for the caller to
    /// vend. Replaces — and EOFs — any existing attach for the same key; the
    /// fresh sink starts NOT ready.
    func attach(key: PaneKey) throws -> (readFD: Int32, generation: UInt64) {
        var fds: [Int32] = [-1, -1]
        let ok = fds.withUnsafeMutableBufferPointer { buf in pipe(buf.baseAddress) == 0 }
        if !ok { throw PaneFanoutError.pipeAllocationFailed(errno) }
        let (readFD, writeFD) = (fds[0], fds[1])
        // Nonblocking write end: a slow app-side reader must never stall the
        // reader thread. EAGAIN → drop-and-count (Phase 6 adds flow control).
        let flags = fcntl(writeFD, F_GETFL)
        _ = fcntl(writeFD, F_SETFL, flags | O_NONBLOCK)

        lock.lock()
        nextGeneration += 1
        let generation = nextGeneration
        let old = sinks[key]
        sinks[key] = Sink(writeFD: writeFD, generation: generation)
        lock.unlock()
        if let old { Darwin.close(old.writeFD) }

        logger.info(
            "fanout attach \(key.server, privacy: .public)/\(key.paneID, privacy: .public) writeFD=\(writeFD) gen=\(generation)")
        return (readFD, generation)
    }

    /// Open the write gate — called when the app's `attach.ready` ack arrives.
    func markReady(key: PaneKey) {
        lock.lock()
        sinks[key]?.ready = true
        lock.unlock()
        logger.info("fanout ready \(key.server, privacy: .public)/\(key.paneID, privacy: .public)")
    }

    func isReady(key: PaneKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sinks[key]?.ready ?? false
    }

    /// Close and forget the write end for `key`; the app-held read end sees
    /// EOF on its next read.
    func detach(key: PaneKey) {
        lock.lock()
        let sink = sinks.removeValue(forKey: key)
        lock.unlock()
        if let sink { Darwin.close(sink.writeFD) }
        logger.info("fanout detach \(key.server, privacy: .public)/\(key.paneID, privacy: .public)")
    }

    /// Cancel an un-acked attach — but ONLY the attach the timer was armed
    /// for. A stale timer from a superseded attach (same key, older
    /// generation) must not kill a fresh attach still inside its own ready
    /// window.
    func detachIfNotReady(key: PaneKey, generation: UInt64) {
        lock.lock()
        guard let sink = sinks[key], sink.generation == generation, !sink.ready else {
            lock.unlock()
            return
        }
        sinks.removeValue(forKey: key)
        lock.unlock()
        Darwin.close(sink.writeFD)
        logger.info(
            "fanout ready-timeout detach \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation)")
    }

    /// Close every sink (daemon shutdown / supervisor stopAll).
    func closeAll() {
        lock.lock()
        let all = sinks
        sinks.removeAll()
        lock.unlock()
        for sink in all.values { Darwin.close(sink.writeFD) }
    }

    /// Hot path — called on the reader thread for every output event.
    func route(server: String, event: TmuxControlEvent) {
        let paneID: String
        let bytes: Data
        switch event {
        case .output(let pane, let data):
            paneID = pane
            bytes = data
        case .extendedOutput(let pane, _, let data):
            paneID = pane
            bytes = data
        default:
            return
        }
        let key = PaneKey(server: server, paneID: paneID)

        lock.lock()
        defer { lock.unlock() }
        guard var sink = sinks[key], sink.ready else {
            if sinks[key] != nil {
                sinks[key]!.droppedEvents += 1
            } else {
                unattachedDrops += 1
            }
            return
        }

        // Partial-write loop: nonblocking write() may legally return a short
        // count. Stopping mid-chunk and dropping the REMAINDER keeps the
        // delivered prefix intact; skipping bytes in the middle would corrupt
        // the escape-sequence stream.
        let buf = [UInt8](bytes)
        var offset = 0
        while offset < buf.count {
            let written = buf[offset...].withUnsafeBytes { Darwin.write(sink.writeFD, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && errno == EAGAIN {
                sink.droppedEvents += 1
                sink.droppedBytes += buf.count - offset
                if Date().timeIntervalSince(sink.lastDropLog) > 1 {
                    sink.lastDropLog = Date()
                    logger.debug(
                        "fanout \(key.server, privacy: .public)/\(key.paneID, privacy: .public) EAGAIN — dropped \(sink.droppedBytes) bytes total (\(sink.droppedEvents) events)")
                }
            } else {
                logger.error(
                    "fanout \(key.server, privacy: .public)/\(key.paneID, privacy: .public) write errno=\(errno)")
            }
            break
        }
        sinks[key] = sink
    }
}
