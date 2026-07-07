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

/// Locked snapshot of one pane's flow-control counters (Phase B M1/M3) —
/// test visibility plus diagnostics. `droppedEvents`/`droppedBytes` count
/// ONLY fenced-overflow, not-ready, and mid-repair drops; plain EAGAIN no
/// longer drops (it queues), and a steady-state overflow enters the repair
/// cycle instead of dropping.
struct PaneFlowStats: Equatable {
    let queuedBytes: Int
    let droppedBytes: Int
    let droppedEvents: Int
    let overflowEvents: Int
    let queuedHighWater: Int
    /// An M3 overflow-repair cycle is underway for this sink.
    let repairing: Bool
    /// Completed (endRepair'd) repair cycles on this sink.
    let repairs: Int
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
    /// The sink is ALREADY acknowledged at this same generation (R5-4): a
    /// prior `attach.ready` sequence owns (or has completed) the replay. A
    /// duplicate ack must be refused — two orchestration sequences would
    /// otherwise `writeReplay` concurrently into one pipe. Treated by the
    /// orchestrator like `superseded`: benign, send nothing.
    case alreadyAcknowledged
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
        /// the pipe. Output routed while not ready is dropped — unless the
        /// M2 attach fence (`fenced`) is armed, which queues it instead for
        /// the post-replay flush.
        var ready = false
        /// Attach-boundary fence (Phase B M2, issue #376): armed by the
        /// attach orchestrator once the pane is provably silent (the pause
        /// reply completed). While set — the gate is necessarily still
        /// closed — routed output QUEUES (M1 machinery, drain deliberately
        /// unarmed) instead of dropping; `markReady` clears it and arms the
        /// drain, flushing the parked bytes strictly after the replay.
        var fenced = false
        /// The app's `attach.ready` ack arrived (M4.3). Since M4.3, `ready`
        /// flips only after the replay lands — so the ready-timeout (whose
        /// purpose is "app never acked") keys off THIS flag instead: a slow
        /// capture must not let the stale timer kill a live, acked attach.
        var acknowledged = false
        /// Overflow + not-ready drops only (Phase B M1): plain EAGAIN no
        /// longer drops — the unwritten remainder is queued instead.
        var droppedEvents = 0
        var droppedBytes = 0
        var lastDropLog = Date.distantPast
        /// Backpressure queue (Phase B M1): bytes the pipe could not accept
        /// yet, delivered IN ORDER by the async drain task. Bounded by
        /// `PaneFanout.queueCap`; scoped to this (key, generation) — a
        /// superseded sink's queued bytes die with it.
        var queue: [Data] = []
        var queuedBytes = 0
        /// A drain task is live for this (key, generation).
        var drainArmed = false
        /// Chunks dropped whole because the queue was at its cap.
        var overflowEvents = 0
        /// Highest `queuedBytes` ever observed on this sink.
        var queuedHighWater = 0
        /// Cumulative bytes that were queued and later delivered by the
        /// drain (telemetry for the recovery log only).
        var queuedDeliveredBytes = 0
        /// Rate limiter for the backpressure-enter / drain-recovery logs
        /// (`lastDropLog` covers the drop logs).
        var lastFlowLog = Date.distantPast
        /// An M3 overflow-repair cycle is underway (Phase B M3, issue #376):
        /// the queue was cleared at overflow (its content is already in pane
        /// history; the repair's capture supersedes it) and the repair
        /// coordinator owns the pane's pause state until `endRepair` /
        /// `abortRepair`. While set (and not fenced), routed output is
        /// dropped with counters — pre-pause bytes the capture will include.
        var repairing = false
        /// Completed repair cycles (telemetry + the live heal test).
        var repairs = 0
    }

    /// Per-pane backpressure queue cap. Beyond this, a steady-state sink
    /// enters the M3 pause+repair cycle (see `enqueueLocked`); a fenced or
    /// already-repairing sink still drops incoming chunks whole.
    static let queueCap = 128 * 1024

    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")
    private let lock = NSLock()
    private var sinks: [PaneKey: Sink] = [:]
    private var nextGeneration: UInt64 = 0
    /// %output events dropped because no attach was registered for their pane.
    private var unattachedDrops = 0
    private var _onOverflowRepair: (@Sendable (PaneKey, UInt64) -> Void)?

    /// M3 overflow-repair signal — fired (strictly OUTSIDE the lock, from
    /// `route()`'s tail) when a steady-state queue overflow flips a sink into
    /// `repairing`. Installed ONCE at bridge init, BEFORE any connection
    /// starts (the same guarantee the supervisor's layout filter relies on);
    /// lock-protected like the filter's box so the reader threads see it.
    var onOverflowRepair: (@Sendable (PaneKey, UInt64) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onOverflowRepair }
        set { lock.lock(); _onOverflowRepair = newValue; lock.unlock() }
    }

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
        // reader thread. EAGAIN → queue-and-drain (Phase B M1): the unwritten
        // remainder is queued per pane (cap `queueCap`) and an async drain
        // task delivers it as the reader catches up.
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
    ///
    /// Generation-checked like every other sink mutation (R6-H1): the replay
    /// write and this gate-open are two separate steps, and a concurrent
    /// re-attach can swap the sink between them. A stale markReady must not
    /// open the gate on the successor's UN-REPLAYED sink — live `%output`
    /// would land before the successor's own replay, breaking the core M4
    /// ordering invariant. Mismatch or missing sink → no-op, returns `false`
    /// (the caller treats it like `superseded`: benign, the successor's own
    /// sequence opens its gate).
    @discardableResult
    func markReady(key: PaneKey, generation: UInt64) -> Bool {
        lock.lock()
        guard var sink = sinks[key], sink.generation == generation else {
            lock.unlock()
            logger.info(
                "fanout stale ready refused \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation)")
            return false
        }
        sink.ready = true
        sink.acknowledged = true
        // Clear the M2 attach fence and flush what it parked: the replay
        // bytes are already in the pipe (`writeReplay` precedes markReady),
        // so arming the drain NOW delivers the fenced bytes strictly after
        // the replay — and `route()`'s queue-nonempty ordering folds live
        // output in behind them. Zero loss at the attach seam.
        sink.fenced = false
        armDrainIfNeededLocked(&sink, key: key)
        sinks[key] = sink
        lock.unlock()
        logger.info(
            "fanout ready \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation)")
        return true
    }

    /// Arm the attach-boundary fence for `key` (Phase B M2) — generation-
    /// checked like every other sink mutation: mismatch or missing sink →
    /// `false`, nothing touched (the caller treats it like a superseded
    /// attach). Call ONLY at a moment the pane is provably silent (the
    /// orchestrator's pause reply): `%output` is routed synchronously on the
    /// reader thread while command replies hop actors, so arming at any
    /// noisier moment could fence pre-pause output the capture already holds.
    @discardableResult
    func armFence(key: PaneKey, generation: UInt64) -> Bool {
        lock.lock()
        guard let sink = sinks[key], sink.generation == generation else {
            lock.unlock()
            logger.info(
                "fanout stale fence refused \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation)")
            return false
        }
        sinks[key]?.fenced = true
        lock.unlock()
        logger.debug(
            "fanout fence armed \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation)")
        return true
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
        // A second attach.ready for the SAME generation must not acknowledge
        // again (R5-4): the first ack's sequence owns the replay, and handing
        // out a second `.acknowledged` would let two sequences writeReplay
        // concurrently into one pipe. The sink itself is left untouched.
        if sink.acknowledged { return .alreadyAcknowledged }
        sinks[key]?.acknowledged = true
        return .acknowledged(generation: sink.generation)
    }

    func isReady(key: PaneKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sinks[key]?.ready ?? false
    }

    /// Read-only generation lookup (R10-3): lets the orchestrator re-check
    /// ownership after its provider hop without touching `acknowledged`
    /// state. `nil` when no sink exists.
    func currentGeneration(key: PaneKey) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return sinks[key]?.generation
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
    /// still in flight when the timer fires must survive. The timer's purpose
    /// is strictly "app never acked" — post-ack, only the replay WRITE is
    /// deadline-bounded (`writeReplay`, 5 s); the capture wait has no timeout,
    /// so a mute-but-alive tmux stalls the attach (Phase B owns that).
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
    /// (live output routed meanwhile is dropped, or PARKED in the fence
    /// queue once the M2 fence is armed — the drain is never live while
    /// fenced, so this direct write cannot be interleaved), and the
    /// orchestrator opens the gate only after this returns, so live bytes
    /// follow the replay in order (addendum §3).
    ///
    /// Unlike `route()` (hot path — queues on EAGAIN and drains
    /// asynchronously), a replay must arrive
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

    /// Locked snapshot of `key`'s flow-control counters. `nil` when no sink
    /// exists (never attached, detached, or superseded-and-gone).
    func flowStats(key: PaneKey) -> PaneFlowStats? {
        lock.lock()
        defer { lock.unlock() }
        guard let sink = sinks[key] else { return nil }
        return PaneFlowStats(
            queuedBytes: sink.queuedBytes,
            droppedBytes: sink.droppedBytes,
            droppedEvents: sink.droppedEvents,
            overflowEvents: sink.overflowEvents,
            queuedHighWater: sink.queuedHighWater,
            repairing: sink.repairing,
            repairs: sink.repairs)
    }

    // MARK: - M3 repair cycle (Phase B)

    /// Arm the REPAIR fence — the repair cycle's twin of `armFence`:
    /// generation-checked, and additionally requires the sink to be
    /// mid-repair (`repairing`): the fence parks post-continue output behind
    /// the repair replay exactly like the attach fence, and arming it on a
    /// non-repairing sink would freeze a healthy stream behind a flush that
    /// never comes. Call ONLY at a provably-silent moment — the repair's
    /// pause reply is in hand and the pane delivers nothing while paused.
    /// Mismatch / missing / not-repairing → `false`, nothing touched.
    @discardableResult
    func beginRepairFence(key: PaneKey, generation: UInt64) -> Bool {
        lock.lock()
        guard let sink = sinks[key], sink.generation == generation, sink.repairing else {
            lock.unlock()
            logger.info(
                "fanout repair fence refused \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation)")
            return false
        }
        sinks[key]?.fenced = true
        lock.unlock()
        logger.debug(
            "fanout repair fence armed \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation)")
        return true
    }

    /// Complete a repair cycle: clear the fence and `repairing`, count the
    /// repair, and arm the drain so the fenced bytes (everything the pane
    /// emitted since the atomic batch's continue) flush strictly after the
    /// repair replay `writeReplay` already put in the pipe — the same
    /// zero-seam flush as `markReady`'s. Generation-checked: mismatch or
    /// missing sink → `false`, nothing touched (the successor owns itself).
    @discardableResult
    func endRepair(key: PaneKey, generation: UInt64) -> Bool {
        lock.lock()
        guard var sink = sinks[key], sink.generation == generation else {
            lock.unlock()
            return false
        }
        sink.fenced = false
        sink.repairing = false
        sink.repairs += 1
        armDrainIfNeededLocked(&sink, key: key)
        sinks[key] = sink
        lock.unlock()
        logger.debug(
            "fanout repair complete \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation)")
        return true
    }

    /// Failure-path exit from a repair cycle the caller still owns: clear
    /// `repairing` (and the fence if armed), keep whatever is queued (likely
    /// nothing — the overflow cleared it) and arm the drain for it. The
    /// stream resumes with a possible hole; a pane frozen forever behind a
    /// fence that never flushes is worse than a hole. Generation-checked
    /// no-op on mismatch/missing.
    func abortRepair(key: PaneKey, generation: UInt64) {
        lock.lock()
        guard var sink = sinks[key], sink.generation == generation else {
            lock.unlock()
            return
        }
        sink.fenced = false
        sink.repairing = false
        armDrainIfNeededLocked(&sink, key: key)
        sinks[key] = sink
        lock.unlock()
        logger.info(
            "fanout repair aborted \(key.server, privacy: .public)/\(key.paneID, privacy: .public) gen=\(generation)")
    }

    /// Nonblocking writability probe of `key`'s pipe (`poll` POLLOUT,
    /// timeout 0) — the repair coordinator's reader-catch-up gate: the
    /// recapture+continue must not run until the app has drained the pipe,
    /// or the repair replay would just re-overflow it. Held under the lock
    /// (same fd-close safety discipline as every write path). `nil` when the
    /// sink is gone or superseded — the repair must abort silently.
    func isPipeWritable(key: PaneKey, generation: UInt64) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let sink = sinks[key], sink.generation == generation else { return nil }
        var pollFD = pollfd(fd: sink.writeFD, events: Int16(POLLOUT), revents: 0)
        let result = Darwin.poll(&pollFD, 1, 0)
        return result > 0 && (pollFD.revents & Int16(POLLOUT)) != 0
    }

    /// Hot path — called on the reader thread for every output event.
    ///
    /// Phase B M1 backpressure: a chunk the pipe cannot accept whole is no
    /// longer truncated (issue #376 — every dropped byte leaves permanently
    /// wrong cells on a differential renderer). The unwritten remainder is
    /// queued (bounded by `queueCap`) and an async drain task delivers it in
    /// order; while ANY bytes are queued, new chunks go straight to the queue
    /// so live bytes can never overtake queued ones.
    ///
    /// Behavior table (M1 queue + M2 fence + M3 repair):
    ///  - no sink → count an unattached drop.
    ///  - fenced (ANY ready state) → enqueue, NEVER arm the drain: a fence
    ///    (attach M2, or repair M3) parks bytes behind a replay-in-flight;
    ///    `markReady` / `endRepair` clears it and arms the flush.
    ///  - !ready && !fenced → drop (pre-fence attach window: the bytes are
    ///    in the attach's capture; delivering them too would duplicate).
    ///  - ready && repairing && !fenced → drop with counters, no per-chunk
    ///    log: pre-pause bytes of the repair cycle — the repair's capture
    ///    includes them, so nothing is lost.
    ///  - ready && queue non-empty → enqueue + arm drain (M1 ordering).
    ///  - ready && queue empty → direct write; EAGAIN remainder → enqueue +
    ///    arm drain (M1).
    /// A steady-state queue overflow (ready, unfenced, not repairing) enters
    /// the M3 repair cycle instead of dropping — see `enqueueLocked`; the
    /// `onOverflowRepair` signal fires AFTER the lock is released (the
    /// handler hops onto the repair coordinator, and callbacks under a hot
    /// lock are a deadlock invitation).
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

        // Generation to fire `onOverflowRepair` for, collected under the
        // lock and fired at function end OUTSIDE it.
        var repairSignal: UInt64?
        lock.lock()
        if var sink = sinks[key] {
            if sink.fenced {
                // Fence window (attach M2 or repair M3): the pane's sequence
                // owns the seam up to markReady/endRepair — queue (M1 cap +
                // overflow telemetry apply unchanged) WITHOUT arming the
                // drain. The queue must stay parked behind the replay:
                // `writeReplay` writes the pipe directly, and a live drain
                // would interleave fenced bytes into the replay.
                // (`enqueueLocked` can never enter repair here — its repair
                // branch requires an UNFENCED sink.)
                _ = enqueueLocked(bytes, into: &sink, key: key)
                sinks[key] = sink
            } else if !sink.ready {
                // Pre-fence not-ready window (attach → pause reply): dropped
                // — those bytes are in the attach's capture, not lost;
                // delivering them too would duplicate them.
                sink.droppedEvents += 1
                sinks[key] = sink
            } else if sink.repairing {
                // Repair window before the repair fence arms (overflow →
                // pause reply): these bytes are pre-pause — already in the
                // pane's history, so the repair's capture includes them.
                // Counted, never logged per-chunk, never re-signaled.
                sink.droppedEvents += 1
                sink.droppedBytes += bytes.count
                sinks[key] = sink
            } else {
                if sink.queuedBytes > 0 {
                    // Order preservation: bytes must NEVER overtake queued
                    // bytes — while the queue is non-empty, everything goes
                    // through it.
                    if enqueueLocked(bytes, into: &sink, key: key) {
                        repairSignal = sink.generation
                    }
                } else {
                    // Partial-write loop: nonblocking write() may legally
                    // return a short count. On EAGAIN (or a short write) the
                    // UNWRITTEN remainder is queued — the delivered prefix
                    // stays intact and the queued continuation follows it in
                    // order.
                    let buf = [UInt8](bytes)
                    var offset = 0
                    while offset < buf.count {
                        let written = buf[offset...].withUnsafeBytes {
                            Darwin.write(sink.writeFD, $0.baseAddress, $0.count)
                        }
                        if written > 0 {
                            offset += written
                            continue
                        }
                        if written < 0 && errno == EINTR { continue }
                        if written < 0 && errno == EAGAIN {
                            if enqueueLocked(Data(buf[offset...]), into: &sink, key: key) {
                                repairSignal = sink.generation
                            }
                        } else {
                            logger.error(
                                "fanout \(key.server, privacy: .public)/\(key.paneID, privacy: .public) write errno=\(errno)")
                        }
                        break
                    }
                }
                armDrainIfNeededLocked(&sink, key: key)
                sinks[key] = sink
            }
        } else {
            unattachedDrops += 1
        }
        lock.unlock()
        if let generation = repairSignal {
            // Property getter re-takes the lock briefly; the callback itself
            // runs with NO fanout lock held.
            onOverflowRepair?(key, generation)
        }
    }

    /// Append `data` to the sink's backpressure queue — MUST be called with
    /// `lock` held. Chunks are enqueued (and, on overflow, dropped) WHOLE:
    /// splitting what we enqueue would put a fragment mid-queue whose
    /// continuation is lost, corrupting escape sequences.
    ///
    /// Overflow (Phase B M3, issue #376):
    ///  - STEADY STATE (ready, unfenced, not repairing): enter the repair
    ///    cycle instead of dropping — clear the queue (everything queued is
    ///    already in the pane's history; the repair's capture supersedes it,
    ///    so NOTHING counts as dropped), flip `repairing`, and return `true`
    ///    so `route()` fires `onOverflowRepair` once the lock is released.
    ///  - FENCED or already REPAIRING: keep the M1 whole-chunk drop +
    ///    telemetry — a bounded residual: a repair started during a fence
    ///    would race the in-flight attach/repair sequence on the same pane's
    ///    pause state, so the fenced window accepts the (rare) hole instead.
    ///
    /// Returns whether the sink just ENTERED the repair cycle.
    private func enqueueLocked(_ data: Data, into sink: inout Sink, key: PaneKey) -> Bool {
        guard !data.isEmpty else { return false }
        if sink.queuedBytes + data.count > Self.queueCap {
            if sink.ready && !sink.fenced && !sink.repairing {
                sink.repairing = true
                sink.queue.removeAll()
                sink.queuedBytes = 0
                if Date().timeIntervalSince(sink.lastFlowLog) > 1 {
                    sink.lastFlowLog = Date()
                    logger.info(
                        "fanout \(key.server, privacy: .public)/\(key.paneID, privacy: .public) queue overflow — entering repair")
                }
                return true
            }
            sink.overflowEvents += 1
            sink.droppedEvents += 1
            sink.droppedBytes += data.count
            if Date().timeIntervalSince(sink.lastDropLog) > 1 {
                sink.lastDropLog = Date()
                let (dropped, events, overflows) = (sink.droppedBytes, sink.droppedEvents, sink.overflowEvents)
                logger.info(
                    "fanout \(key.server, privacy: .public)/\(key.paneID, privacy: .public) queue overflow — dropped \(dropped) bytes total (\(events) events, \(overflows) overflows)")
            }
            return false
        }
        let wasEmpty = sink.queuedBytes == 0
        sink.queue.append(data)
        sink.queuedBytes += data.count
        sink.queuedHighWater = max(sink.queuedHighWater, sink.queuedBytes)
        if wasEmpty, Date().timeIntervalSince(sink.lastFlowLog) > 1 {
            sink.lastFlowLog = Date()
            let queued = sink.queuedBytes
            logger.info(
                "fanout \(key.server, privacy: .public)/\(key.paneID, privacy: .public) backpressure — pipe full, queued \(queued) bytes")
        }
        return false
    }

    /// Spawn the drain task for `sink` if its queue is non-empty and no drain
    /// is live yet — MUST be called with `lock` held. The task captures only
    /// (key, generation): it re-validates the sink on every pass, so a
    /// superseded or detached sink's queue simply dies with it.
    private func armDrainIfNeededLocked(_ sink: inout Sink, key: PaneKey) {
        guard sink.queuedBytes > 0, !sink.drainArmed else { return }
        sink.drainArmed = true
        let generation = sink.generation
        Task.detached { [weak self] in
            await self?.drainQueue(key: key, generation: generation)
        }
    }

    /// Async drain for one (key, generation)'s backpressure queue. Writes
    /// with the same nonblocking write-under-lock discipline as `route()` /
    /// `writeReplay` (every fd use re-validates the sink under the lock, so
    /// a write into a closed-and-recycled fd cannot happen). On EAGAIN it
    /// sleeps OFF the lock (10 ms — the sleep IS the pacing) and retries.
    ///
    /// Generation-scoped, the invariant everything here protects: a
    /// superseded attach's queued bytes must NEVER flush into a successor's
    /// pipe. On generation mismatch or missing sink this exits touching
    /// NOTHING — the successor manages its own `drainArmed`.
    private func drainQueue(key: PaneKey, generation: UInt64) async {
        while true {
            // The pass itself is synchronous (NSLock is `noasync`); this
            // loop only paces between passes, never holding the lock across
            // a suspension.
            if drainPass(key: key, generation: generation) == .finished { return }
            // Pipe still full: pace OFF the lock, then re-validate and retry.
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum DrainPassResult {
        /// The drain task is done: queue emptied, sink gone/superseded, or a
        /// hard write error abandoned the queue.
        case finished
        /// EAGAIN — the pipe is still full; sleep and run another pass.
        case pipeFull
    }

    /// One locked drain pass — the synchronous half of `drainQueue`.
    private func drainPass(key: PaneKey, generation: UInt64) -> DrainPassResult {
        lock.lock()
        guard var sink = sinks[key], sink.generation == generation, sink.ready, !sink.fenced else {
            // Only a still-live sink at OUR generation gets its flag cleared
            // (`ready` never reverts once set — that arm is defensive only).
            // FENCED stands the drain down too (M3): the repair fence arms on
            // a READY sink, and a straggler drain task from pre-overflow
            // backpressure would otherwise flush fence-parked bytes into the
            // pipe AHEAD of the repair replay. `endRepair`/`markReady` clears
            // the fence and re-arms the drain for the ordered flush.
            if let current = sinks[key], current.generation == generation {
                sinks[key]!.drainArmed = false
            }
            lock.unlock()
            return .finished
        }

        var sawHardError = false
        var pipeFull = false
        while let head = sink.queue.first, !pipeFull, !sawHardError {
            let buf = [UInt8](head)
            var offset = 0
            while offset < buf.count {
                let written = buf[offset...].withUnsafeBytes {
                    Darwin.write(sink.writeFD, $0.baseAddress, $0.count)
                }
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                if written < 0 && errno == EAGAIN {
                    pipeFull = true
                } else {
                    sawHardError = true
                }
                break
            }
            if offset > 0 {
                sink.queuedBytes -= offset
                sink.queuedDeliveredBytes += offset
                if offset >= buf.count {
                    sink.queue.removeFirst()
                } else {
                    // Partial write: keep the remainder at the head.
                    sink.queue[0] = Data(buf[offset...])
                }
            }
        }

        if sawHardError {
            // e.g. EPIPE after the app closed the read end — the queue can
            // never deliver; count it dropped and stand down (the detach
            // path closes the fd).
            logger.error(
                "fanout \(key.server, privacy: .public)/\(key.paneID, privacy: .public) drain write errno=\(errno) — abandoning \(sink.queuedBytes) queued bytes")
            sink.droppedEvents += sink.queue.count
            sink.droppedBytes += sink.queuedBytes
            sink.queue.removeAll()
            sink.queuedBytes = 0
            sink.drainArmed = false
            sinks[key] = sink
            lock.unlock()
            return .finished
        }
        if sink.queue.isEmpty {
            sink.drainArmed = false
            if Date().timeIntervalSince(sink.lastFlowLog) > 1 {
                sink.lastFlowLog = Date()
                logger.info(
                    "fanout \(key.server, privacy: .public)/\(key.paneID, privacy: .public) drained — high water \(sink.queuedHighWater) bytes, \(sink.queuedDeliveredBytes) bytes queued-then-delivered total")
            }
            sinks[key] = sink
            lock.unlock()
            return .finished
        }
        sinks[key] = sink
        lock.unlock()
        return .pipeFull
    }
}
