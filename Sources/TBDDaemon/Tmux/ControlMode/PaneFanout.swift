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

/// Failures of `PaneFanout.writeReplay`. `notAttached` and `superseded` are
/// distinct so the attach orchestrator can tell "the pane is gone" from "my
/// attach was replaced by a newer one" (the latter is a normal race, not an
/// error worth surfacing).
enum PaneReplayWriteError: Error, Equatable {
    /// No sink registered for the key (detached, timed out, or never attached).
    case notAttached
    /// A sink exists but belongs to a different attach generation — a
    /// superseded attach's replay must never write into its successor's pipe.
    case superseded
    /// The pipe stayed full past the deadline (app reader wedged or too slow).
    case deadlineExceeded(written: Int, total: Int)
    /// write(2) failed with an errno other than EAGAIN/EINTR (e.g. EPIPE
    /// after the app closed the read end).
    case writeFailed(errno: Int32)
}

/// Outcome of the generation-checked `PaneFanout.acknowledge`.
enum PaneAcknowledgeResult: Equatable {
    /// The ack landed: a sink exists and (when a generation was echoed) it
    /// matched. Carries the sink's generation — the replay sequence is tagged
    /// with it.
    case acknowledged(generation: UInt64)
    /// No sink for the key (detached, timed out, or never attached).
    case noSink
    /// A sink exists but belongs to a NEWER attach than the acknowledging
    /// caller. The stale ack must not touch it — not even the `acknowledged`
    /// flag: disarming the successor's ready-timeout is the successor's own
    /// ready's job.
    case superseded
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
        /// vended) and the end of the attach.ready replay sequence (M4.3):
        /// the orchestrator opens the gate only AFTER the replay bytes are in
        /// the pipe. Output routed while not ready is dropped.
        var ready = false
        /// The app's `attach.ready` ack arrived (M4.3). Since M4.3, `ready`
        /// flips only after the replay lands — so the ready-timeout (whose
        /// purpose is "app never acked") keys off THIS flag instead: a slow
        /// capture must not let the stale timer kill a live, acked attach.
        var acknowledged = false
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

    /// Open the write gate — called by the attach orchestrator AFTER the
    /// replay bytes are in the pipe (M4.3). Also marks the sink acknowledged
    /// (ready implies acked), so direct `markReady` callers — tests, or any
    /// future replay-less path — are equally safe from the ready-timeout.
    func markReady(key: PaneKey) {
        lock.lock()
        sinks[key]?.ready = true
        sinks[key]?.acknowledged = true
        lock.unlock()
        logger.info("fanout ready \(key.server, privacy: .public)/\(key.paneID, privacy: .public)")
    }

    /// Record the app's `attach.ready` ack and return the sink's CURRENT
    /// generation — atomically, so the replay sequence the caller starts is
    /// tagged with exactly the generation it acknowledged. When the app
    /// echoed its attach's generation (`expectedGeneration`), the ack is
    /// generation-checked: a mismatch means a newer attach owns the pane and
    /// the stale ack must leave the sink UNTOUCHED (returning `.superseded`
    /// without setting `acknowledged` — the successor's ready-timeout keeps
    /// standing guard until its OWN ready arrives). Once acknowledged, the
    /// ready-timeout (`detachIfNotReady`) no longer threatens this attach;
    /// from here the only deadline-bounded wait is the replay WRITE's
    /// (`writeReplay`, 5 s) — the capture wait itself has no timeout, so a
    /// mute-but-alive tmux stalls the attach until the stream closes (Phase B
    /// owns that).
    func acknowledge(key: PaneKey, expectedGeneration: UInt64? = nil) -> PaneAcknowledgeResult {
        lock.lock()
        defer { lock.unlock() }
        guard let sink = sinks[key] else { return .noSink }
        if let expected = expectedGeneration, expected != sink.generation {
            return .superseded
        }
        sinks[key]?.acknowledged = true
        return .acknowledged(generation: sink.generation)
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

    /// Failure-path detach — remove + close ONLY if the sink still belongs to
    /// `generation`. A failed attach sequence (capture %error, replay write
    /// failure, vend failure) may surface AFTER a newer attach has replaced
    /// the sink for the same key; its cleanup must not EOF the healthy
    /// successor's pipe. Returns whether a sink was actually detached, so the
    /// caller can scope companion cleanup (e.g. input-route unregistration)
    /// the same way.
    @discardableResult
    func detachIfGeneration(key: PaneKey, generation: UInt64) -> Bool {
        lock.lock()
        guard let sink = sinks[key], sink.generation == generation else {
            lock.unlock()
            return false
        }
        sinks.removeValue(forKey: key)
        lock.unlock()
        Darwin.close(sink.writeFD)
        logger.info(
            "fanout failure detach \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation)")
        return true
    }

    /// Cancel an un-acked attach — but ONLY the attach the timer was armed
    /// for. A stale timer from a superseded attach (same key, older
    /// generation) must not kill a fresh attach still inside its own ready
    /// window. Guards on `acknowledged`, not `ready`: since M4.3 the gate
    /// opens only after the replay lands, so an acked attach whose capture is
    /// still in flight when the timer fires must survive (the timer's purpose
    /// is "app never acked", and the replay has its own deadlines).
    func detachIfNotReady(key: PaneKey, generation: UInt64) {
        lock.lock()
        guard let sink = sinks[key], sink.generation == generation, !sink.acknowledged else {
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

    /// Write the attach replay into `key`'s pipe. Callable while the sink is
    /// NOT ready — that's the point: the replay lands behind the closed gate
    /// (live output routed meanwhile is still dropped), and the orchestrator
    /// acks `attach.ready` only after this returns, so live bytes follow the
    /// replay in order (addendum §3).
    ///
    /// Unlike `route()` (hot path — drops on EAGAIN), a replay must arrive
    /// INTACT: a truncated escape sequence corrupts the terminal. On EAGAIN
    /// this waits for pipe writability in short poll slices under `deadline`,
    /// re-validating the sink between slices. It can therefore block up to
    /// `deadline` — call it from the attach orchestrator's async task only;
    /// NEVER from a connection reader thread, and NEVER on the supervisor
    /// actor (it would stall every attach/detach in the daemon).
    ///
    /// fd-close safety: each write slice re-validates `sinks[key]` (existence
    /// + generation) and issues the nonblocking `write` while HOLDING the
    /// lock — the same discipline as `route()`. Every close path (`attach`
    /// replacing a sink, `detach`, `detachIfNotReady`, `closeAll`) removes
    /// the sink from the map under this lock BEFORE closing the fd, so a
    /// write into a closed-and-recycled fd cannot happen. The only use of a
    /// snapshotted fd outside the lock is `poll` — residual: if the sink is
    /// detached mid-wait, the poll may watch a closed (or recycled) fd for
    /// one slice, but it never writes, and the next slice's re-validation
    /// throws `.notAttached`/`.superseded`.
    func writeReplay(key: PaneKey, generation: UInt64, bytes: Data, deadline: TimeInterval = 5.0) throws {
        let buf = [UInt8](bytes)
        let total = buf.count
        var offset = 0
        let start = DispatchTime.now()

        while offset < total {
            lock.lock()
            guard let sink = sinks[key] else {
                lock.unlock()
                throw PaneReplayWriteError.notAttached
            }
            guard sink.generation == generation else {
                lock.unlock()
                throw PaneReplayWriteError.superseded
            }
            let fd = sink.writeFD
            // Nonblocking write slice under the lock (bounded by the pipe
            // buffer, ~64 KB — the same hold route() takes per chunk).
            var failure: Int32 = EAGAIN
            while offset < total {
                let written = buf[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if written > 0 {
                    offset += written
                    continue
                }
                let err = errno
                if written < 0 && err == EINTR { continue }
                // written == 0 can't happen for count > 0 on a pipe; treat
                // like EAGAIN (retry under the deadline) rather than spin.
                failure = written < 0 ? err : EAGAIN
                break
            }
            lock.unlock()
            if offset >= total { break }
            guard failure == EAGAIN else {
                logger.error(
                    "replay write \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation) errno=\(failure)")
                throw PaneReplayWriteError.writeFailed(errno: failure)
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            let remaining = deadline - elapsed
            if remaining <= 0 {
                logger.error(
                    "replay write \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation) deadline after \(offset)/\(total) bytes")
                throw PaneReplayWriteError.deadlineExceeded(written: offset, total: total)
            }
            // Wait for writability OUTSIDE the lock — reader threads routing
            // other panes must not stall behind this slice.
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let sliceMs = Int32(max(1, min(50, Int(remaining * 1000))))
            _ = Darwin.poll(&pollFD, 1, sliceMs)
        }
        logger.debug(
            "replay write \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation) \(total) bytes delivered")
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
