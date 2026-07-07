import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// Positive-wait deadline sized for starved CI runners (PR #379: cooperative-pool
/// starvation stretched sub-second async-drain deliveries past a 5 s poll).
/// Passing runs still complete in milliseconds — only failures wait this long.
private let ciSafeDeadline: TimeInterval = 30

/// Phase B M1 — `PaneFanout.route` backpressure: instead of dropping the
/// unwritten remainder on EAGAIN (issue #376's corruption source), the
/// remainder is queued per (key, generation) and an async drain task delivers
/// it in order as the reader catches up. Pure pipe mechanics — no tmux, no
/// ~/tbd.
@Suite("PaneFanout flow control")
struct PaneFanoutFlowControlTests {
    private let server = "tbd-test-server"

    /// Darwin pipes buffer at most 64 KB; chunks are routed in 32 KB slices.
    private static let chunkSize = 32 * 1024

    private func setNonblocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Position-dependent bytes so a dropped, duplicated, or reordered chunk
    /// cannot go unnoticed.
    private func patterned(count: Int, seed: UInt8 = 0) -> Data {
        var data = Data(capacity: count)
        var counter = seed
        for _ in 0..<count {
            data.append(counter)
            counter &+= 1
        }
        return data
    }

    private func routeChunks(_ fanout: PaneFanout, paneID: String, data: Data) {
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.chunkSize, data.count)
            fanout.route(
                server: server,
                event: .output(paneID: paneID, bytes: data.subdata(in: offset..<end)))
            offset = end
        }
    }

    /// Poll-read a nonblocking fd until `expected` bytes arrived or the
    /// deadline passes. Never a fixed sleep alone — the drain is async.
    private func readAll(fd: Int32, expected: Int, deadline: TimeInterval = ciSafeDeadline) -> Data {
        let start = Date()
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while received.count < expected && Date().timeIntervalSince(start) < deadline {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                received.append(contentsOf: buffer[0..<n])
            } else if n == 0 {
                break  // EOF
            } else {
                usleep(5_000)
            }
        }
        return received
    }

    /// Poll-read a nonblocking fd until the pane's queue is empty AND the
    /// pipe stops yielding data (quiescence), or the deadline passes. For
    /// tests where the delivered byte count is not known up front.
    private func readUntilQuiescent(
        _ fanout: PaneFanout, key: PaneKey, fd: Int32, deadline: TimeInterval = ciSafeDeadline
    ) -> Data {
        let start = Date()
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while Date().timeIntervalSince(start) < deadline {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                received.append(contentsOf: buffer[0..<n])
                continue
            }
            if n == 0 { break }  // EOF
            // Pipe momentarily empty: done only once the queue is drained too.
            if let stats = fanout.flowStats(key: key), stats.queuedBytes == 0 {
                // One more grace poll in case the drain just wrote.
                usleep(20_000)
                let m = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if m > 0 {
                    received.append(contentsOf: buffer[0..<m])
                    continue
                }
                break
            }
            usleep(5_000)
        }
        return received
    }

    @Test("EAGAIN remainder is queued, not dropped — full stream arrives intact and in order")
    func eagainRemainderQueuedNotDropped() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%1")
        let (readFD, gen) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        fanout.markReady(key: key, generation: gen)

        // 160 KB into a ~64 KB pipe with no reader yet: the writes past the
        // pipe buffer must hit EAGAIN and queue, never drop.
        let total = patterned(count: 160 * 1024)
        routeChunks(fanout, paneID: "%1", data: total)

        let stats = try #require(fanout.flowStats(key: key))
        #expect(stats.droppedBytes == 0, "no byte may be dropped below the queue cap")
        #expect(stats.droppedEvents == 0)
        #expect(stats.overflowEvents == 0)
        #expect(stats.queuedBytes > 0, "the pipe cannot hold 160 KB — the remainder must be queued")
        #expect(stats.queuedHighWater >= stats.queuedBytes)

        // Now read everything: the drain task must deliver the queued
        // remainder, byte-for-byte in order.
        let received = readAll(fd: readFD, expected: total.count)
        #expect(received.count == total.count)
        #expect(received == total, "stream must arrive intact and in order across backpressure")

        // Queue must eventually report empty.
        let deadline = Date().addingTimeInterval(ciSafeDeadline)
        while Date() < deadline, (fanout.flowStats(key: key)?.queuedBytes ?? 0) > 0 {
            usleep(5_000)
        }
        #expect(fanout.flowStats(key: key)?.queuedBytes == 0)
    }

    @Test("order preservation: a chunk routed while bytes are queued must not overtake them")
    func orderPreservedAcrossBackpressure() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%2")
        let (readFD, gen) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        fanout.markReady(key: key, generation: gen)

        // Chunk A overfills the pipe (remainder queues); B is small and would
        // fit in the pipe directly — it must still land AFTER A's queued tail.
        let chunkA = patterned(count: 100 * 1024, seed: 7)
        routeChunks(fanout, paneID: "%2", data: chunkA)
        let statsAfterA = try #require(fanout.flowStats(key: key))
        #expect(statsAfterA.queuedBytes > 0, "A's tail must be queued for B to have anything to overtake")
        let chunkB = Data("TAIL-MARKER-B".utf8)
        fanout.route(server: server, event: .output(paneID: "%2", bytes: chunkB))

        let expected = chunkA + chunkB
        let received = readAll(fd: readFD, expected: expected.count)
        #expect(received == expected, "B must arrive strictly after every byte of A")
        #expect(fanout.flowStats(key: key)?.droppedBytes == 0)
    }

    /// Thread-safe recorder of overflow-repair signals.
    private final class SignalRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _signals: [(PaneKey, UInt64)] = []
        func record(_ key: PaneKey, _ generation: UInt64) {
            lock.lock(); _signals.append((key, generation)); lock.unlock()
        }
        var signals: [(PaneKey, UInt64)] { lock.lock(); defer { lock.unlock() }; return _signals }
    }

    @Test("steady-state queue overflow enters repair: queue cleared, nothing counted dropped, signal fired exactly once")
    func steadyStateOverflowEntersRepair() throws {
        let fanout = PaneFanout()
        let signals = SignalRecorder()
        fanout.onOverflowRepair = { key, generation in signals.record(key, generation) }
        let key = PaneKey(server: server, paneID: "%3")
        let (readFD, gen) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        fanout.markReady(key: key, generation: gen)

        // Route 32 KB chunks into the unread pipe until the cap overflows
        // (~64 KB pipe + 128 KB queue → the 7th chunk): the M3 hook must NOT
        // drop — it clears the queue (everything queued is already in pane
        // history; the repair's capture supersedes it), flips `repairing`,
        // and signals the repair coordinator exactly once.
        let chunk = patterned(count: Self.chunkSize)
        var entered = false
        for _ in 0..<32 {
            fanout.route(server: server, event: .output(paneID: "%3", bytes: chunk))
            if fanout.flowStats(key: key)?.repairing == true {
                entered = true
                break
            }
        }
        #expect(entered, "overflow on a ready, unfenced sink must enter repairing")

        let stats = try #require(fanout.flowStats(key: key))
        #expect(stats.queuedBytes == 0, "the queue must be CLEARED at repair entry — the capture supersedes it")
        #expect(stats.droppedBytes == 0, "nothing counts as dropped at repair entry")
        #expect(stats.droppedEvents == 0)
        #expect(signals.signals.count == 1, "exactly one overflow-repair signal")
        #expect(signals.signals.first?.0 == key)
        #expect(signals.signals.first?.1 == gen)

        // While repairing (pre-pause window of the repair cycle): routed
        // bytes are dropped WITH counters — they are in the pane's history,
        // the repair's capture will include them — and never re-signal.
        let probe = Data("WHILE-REPAIRING".utf8)
        fanout.route(server: server, event: .output(paneID: "%3", bytes: probe))
        let after = try #require(fanout.flowStats(key: key))
        #expect(after.droppedEvents == 1)
        #expect(after.droppedBytes == probe.count)
        #expect(after.queuedBytes == 0, "repairing bytes must not queue — the drain is not fence-parked here")
        #expect(signals.signals.count == 1, "a repairing sink must not re-signal")
    }

    @Test("repair fence lifecycle: beginRepairFence requires repairing, endRepair flushes and counts, abortRepair unfreezes")
    func repairFenceLifecycle() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%10")
        let (readFD, gen) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        fanout.markReady(key: key, generation: gen)

        // Not repairing → beginRepairFence refused (arming it on a healthy
        // stream would freeze it).
        #expect(fanout.beginRepairFence(key: key, generation: gen) == false,
                "beginRepairFence must require a repairing sink")

        // Drive the sink into repairing via a steady-state overflow.
        let chunk = patterned(count: Self.chunkSize)
        for _ in 0..<32 where fanout.flowStats(key: key)?.repairing != true {
            fanout.route(server: server, event: .output(paneID: "%10", bytes: chunk))
        }
        try #require(fanout.flowStats(key: key)?.repairing == true)

        // Generation-checked: wrong generation refused, right one arms.
        #expect(fanout.beginRepairFence(key: key, generation: gen + 1) == false)
        #expect(fanout.endRepair(key: key, generation: gen + 1) == false)
        #expect(fanout.beginRepairFence(key: key, generation: gen))

        // Fenced-while-repairing: routed bytes queue (post-continue bytes of
        // the repair), nothing reaches the pipe until endRepair.
        drainPipe(readFD)
        let fenced = Data("REPAIR-FENCED".utf8)
        fanout.route(server: server, event: .output(paneID: "%10", bytes: fenced))
        #expect(try #require(fanout.flowStats(key: key)).queuedBytes == fenced.count)
        usleep(100_000)
        var probe = [UInt8](repeating: 0, count: 64)
        let n = probe.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(n < 0 && errno == EAGAIN, "repair-fenced bytes must stay parked until endRepair")

        // endRepair: clears fence + repairing, counts the repair, flushes.
        #expect(fanout.endRepair(key: key, generation: gen))
        let received = readAll(fd: readFD, expected: fenced.count)
        #expect(received == fenced, "endRepair must flush the fenced bytes intact")
        let stats = try #require(fanout.flowStats(key: key))
        #expect(stats.repairing == false)
        #expect(stats.repairs == 1)

        // Second cycle → abortRepair: clears repairing (failure path), the
        // stream resumes (direct writes work again), no repair counted.
        for _ in 0..<32 where fanout.flowStats(key: key)?.repairing != true {
            fanout.route(server: server, event: .output(paneID: "%10", bytes: chunk))
        }
        try #require(fanout.flowStats(key: key)?.repairing == true)
        fanout.abortRepair(key: key, generation: gen + 1)  // wrong gen: no-op
        #expect(fanout.flowStats(key: key)?.repairing == true)
        fanout.abortRepair(key: key, generation: gen)
        let aborted = try #require(fanout.flowStats(key: key))
        #expect(aborted.repairing == false)
        #expect(aborted.repairs == 1, "an aborted repair must not count as completed")
        drainPipe(readFD)
        fanout.route(server: server, event: .output(paneID: "%10", bytes: Data("POST-ABORT".utf8)))
        let resumed = readAll(fd: readFD, expected: "POST-ABORT".utf8.count)
        #expect(String(decoding: resumed, as: UTF8.self) == "POST-ABORT")
    }

    @Test("isPipeWritable: .full while full, .writable after the reader drains, .broken when the read end closes, nil on stale generation or missing sink")
    func pipeWritableProbe() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%11")
        let (readFD, gen) = try fanout.attach(key: key)
        var readClosed = false
        defer { if !readClosed { Darwin.close(readFD) } }
        setNonblocking(readFD)
        fanout.markReady(key: key, generation: gen)

        #expect(fanout.isPipeWritable(key: key, generation: gen) == .writable,
                "a fresh pipe must be writable")
        // Fill the pipe (direct writes land until EAGAIN queues the rest).
        routeChunks(fanout, paneID: "%11", data: patterned(count: 160 * 1024))
        #expect(fanout.isPipeWritable(key: key, generation: gen) == .full,
                "a full pipe must probe full — healthy, keep waiting")
        // The reader catches up.
        _ = readAll(fd: readFD, expected: 160 * 1024)
        #expect(fanout.isPipeWritable(key: key, generation: gen) == .writable)

        // Stale generation / missing sink → nil (repair must abort silently).
        #expect(fanout.isPipeWritable(key: key, generation: gen + 1) == nil)
        #expect(fanout.isPipeWritable(
            key: PaneKey(server: server, paneID: "%none"), generation: 1) == nil)

        // The reader dies: read end closed → .broken (the pipe can never
        // drain; the repair must unpause + abort instead of waiting forever).
        Darwin.close(readFD)
        readClosed = true
        #expect(fanout.isPipeWritable(key: key, generation: gen) == .broken,
                "a read-end-closed pipe must probe broken")
    }

    /// Read `fd` until EAGAIN.
    private func drainPipe(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
        }
    }

    @Test("generation scoping: a superseded sink's queued bytes die with it")
    func supersededQueueDiesWithSink() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%4")

        // Build a backpressured queue on generation 1.
        let (read1, gen1) = try fanout.attach(key: key)
        defer { Darwin.close(read1) }
        setNonblocking(read1)
        fanout.markReady(key: key, generation: gen1)
        routeChunks(fanout, paneID: "%4", data: patterned(count: 160 * 1024, seed: 1))
        #expect((fanout.flowStats(key: key)?.queuedBytes ?? 0) > 0)

        // Re-attach replaces the sink; the old queue must NEVER flush into
        // the successor's pipe.
        let (read2, gen2) = try fanout.attach(key: key)
        defer { Darwin.close(read2) }
        setNonblocking(read2)
        fanout.markReady(key: key, generation: gen2)

        // Fresh sink starts with clean counters and an empty queue.
        let freshStats = try #require(fanout.flowStats(key: key))
        #expect(freshStats.queuedBytes == 0)
        #expect(freshStats.droppedBytes == 0)

        let newBytes = Data("ONLY-THE-NEW-GENERATION".utf8)
        fanout.route(server: server, event: .output(paneID: "%4", bytes: newBytes))
        let received = readAll(fd: read2, expected: newBytes.count)
        #expect(received == newBytes, "successor pipe must carry ONLY the new generation's bytes")

        // Give the old drain task time to observe the mismatch: whatever it
        // does, nothing further may appear on the successor pipe.
        usleep(100_000)
        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(read2, $0.baseAddress, $0.count) }
        #expect(n < 0 && errno == EAGAIN, "no stale queued bytes may leak into the successor")
    }

    @Test("detach mid-drain does not crash; flowStats returns nil after detach")
    func detachMidDrainIsSafe() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%5")
        let (readFD, gen) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        fanout.markReady(key: key, generation: gen)

        // Backpressure the queue so a drain task is live, then detach.
        routeChunks(fanout, paneID: "%5", data: patterned(count: 160 * 1024))
        #expect((fanout.flowStats(key: key)?.queuedBytes ?? 0) > 0)
        fanout.detach(key: key)

        #expect(fanout.flowStats(key: key) == nil)
        // Drain the pipe to EOF — the write end is closed; the drain task
        // must exit quietly without writing into a recycled fd.
        _ = readUntilQuiescent(fanout, key: key, fd: readFD)
        usleep(100_000)
        #expect(fanout.flowStats(key: key) == nil)
    }

    @Test("fence: routed-while-fenced bytes stay parked (nothing on the pipe) until markReady flushes them")
    func fenceQueueParkedUntilMarkReadyFlushes() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%7")
        let (readFD, gen) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)

        #expect(fanout.armFence(key: key, generation: gen),
                "arming the fence at the live generation must succeed")

        // Routed while fenced (gate still closed): queued whole, not dropped.
        let fenced = Data("FENCED-ATTACH-WINDOW-BYTES".utf8)
        fanout.route(server: server, event: .output(paneID: "%7", bytes: fenced))
        let stats = try #require(fanout.flowStats(key: key))
        #expect(stats.queuedBytes == fenced.count)
        #expect(stats.droppedBytes == 0)
        #expect(stats.droppedEvents == 0)

        // The drain must NOT be armed while fenced: the queue stays parked
        // behind the closed gate so writeReplay's direct pipe write cannot
        // be interleaved. Nothing may appear on the pipe yet.
        usleep(100_000)
        var probe = [UInt8](repeating: 0, count: 64)
        let n = probe.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(n < 0 && errno == EAGAIN, "fenced bytes must stay parked until markReady")
        #expect(try #require(fanout.flowStats(key: key)).queuedBytes == fenced.count)

        // markReady clears the fence and arms the drain: the parked bytes
        // flush.
        #expect(fanout.markReady(key: key, generation: gen))
        let received = readAll(fd: readFD, expected: fenced.count)
        #expect(received == fenced, "markReady must flush the fence queue intact and in order")

        let deadline = Date().addingTimeInterval(ciSafeDeadline)
        while Date() < deadline, (fanout.flowStats(key: key)?.queuedBytes ?? 0) > 0 {
            usleep(5_000)
        }
        #expect(fanout.flowStats(key: key)?.queuedBytes == 0)
    }

    @Test("armFence is generation-checked: stale generation or missing sink → false, sink untouched")
    func armFenceGenerationChecked() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%8")
        let (read1, gen1) = try fanout.attach(key: key)
        defer { Darwin.close(read1) }
        setNonblocking(read1)

        // Wrong generation → refused, and the sink stays UNFENCED: a routed
        // chunk drops (not-ready bookkeeping) instead of queueing.
        #expect(fanout.armFence(key: key, generation: gen1 + 1) == false)
        fanout.route(server: server, event: .output(paneID: "%8", bytes: Data("early".utf8)))
        let stats = try #require(fanout.flowStats(key: key))
        #expect(stats.droppedEvents == 1, "an unfenced not-ready chunk must still drop")
        #expect(stats.queuedBytes == 0, "a refused armFence must not have fenced the sink")

        // Missing sink → refused.
        #expect(fanout.armFence(
            key: PaneKey(server: server, paneID: "%none"), generation: 1) == false)

        // A re-attach supersedes: the old generation is refused, the new one
        // arms.
        let (read2, gen2) = try fanout.attach(key: key)
        defer { Darwin.close(read2) }
        #expect(fanout.armFence(key: key, generation: gen1) == false)
        #expect(fanout.armFence(key: key, generation: gen2))
    }

    @Test("fence overflow: chunks past the queue cap drop whole with overflow telemetry — and do NOT signal repair (M1 semantics)")
    func fenceOverflowDropsWholeChunks() throws {
        let fanout = PaneFanout()
        let signals = SignalRecorder()
        fanout.onOverflowRepair = { key, generation in signals.record(key, generation) }
        let key = PaneKey(server: server, paneID: "%9")
        let (readFD, gen) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        #expect(fanout.armFence(key: key, generation: gen))

        // While fenced NOTHING reaches the pipe, so 5 x 32 KB fills the
        // 128 KB queue exactly; the fifth chunk must overflow-drop whole.
        let total = patterned(count: 160 * 1024)
        routeChunks(fanout, paneID: "%9", data: total)

        let stats = try #require(fanout.flowStats(key: key))
        #expect(stats.queuedBytes == PaneFanout.queueCap, "queue must fill to its cap, never past it")
        #expect(stats.overflowEvents == 1)
        #expect(stats.droppedBytes == 32 * 1024, "the overflowing chunk drops WHOLE")
        // A fenced overflow must NOT enter the repair cycle: a repair-during-
        // fence would race the in-flight attach/repair sequence on the same
        // pane's pause state. Bounded residual, M1 drop preserved.
        #expect(signals.signals.isEmpty, "fenced overflow must not signal repair")
        #expect(stats.repairing == false)

        // markReady flushes the intact prefix; the overflow residual is the
        // M3 repair cycle's to heal.
        #expect(fanout.markReady(key: key, generation: gen))
        let received = readAll(fd: readFD, expected: PaneFanout.queueCap)
        #expect(received == total.prefix(PaneFanout.queueCap),
                "delivered bytes must be an intact prefix — no mid-stream holes")
    }

    @Test("not-ready drop bookkeeping: events AND bytes counted, nothing queued")
    func notReadyDropUnchanged() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%6")
        let (readFD, _) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)

        // Routed before markReady: dropped (the M2 attach fence owns this
        // window), never queued.
        fanout.route(server: server, event: .output(paneID: "%6", bytes: Data("early".utf8)))

        let stats = try #require(fanout.flowStats(key: key))
        #expect(stats.droppedEvents == 1)
        #expect(stats.droppedBytes == 5, "the not-ready drop must count its bytes too")
        #expect(stats.queuedBytes == 0)
        #expect(stats.overflowEvents == 0)

        var buffer = [UInt8](repeating: 0, count: 32)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(n < 0 && errno == EAGAIN, "nothing may reach the pipe before ready")
    }

    @Test("route hard error (EPIPE): the unwritten remainder is counted dropped, mirroring the drain's accounting")
    func routeHardErrorCountsDroppedRemainder() throws {
        // Mirror the daemon's process-wide SIGPIPE stance (main.swift): a
        // write into a pipe whose read end is closed must return EPIPE, not
        // kill the test process.
        signal(SIGPIPE, SIG_IGN)
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%14")
        let (readFD, gen) = try fanout.attach(key: key)
        setNonblocking(readFD)
        #expect(fanout.markReady(key: key, generation: gen))
        // The viewer dies: the read end closes while the sink stays attached.
        Darwin.close(readFD)

        let chunk = patterned(count: 1024)
        fanout.route(server: server, event: .output(paneID: "%14", bytes: chunk))
        let stats = try #require(fanout.flowStats(key: key))
        #expect(stats.droppedEvents == 1, "a hard write error must count a dropped event")
        #expect(stats.droppedBytes == 1024, "the discarded unwritten remainder must be counted")
        #expect(stats.queuedBytes == 0, "a hard error must not queue the remainder")

        // Counters keep accumulating on further chunks (the log is
        // rate-limited; the accounting never is).
        fanout.route(server: server, event: .output(paneID: "%14", bytes: chunk))
        let after = try #require(fanout.flowStats(key: key))
        #expect(after.droppedEvents == 2)
        #expect(after.droppedBytes == 2048)
        fanout.detach(key: key)
    }
}
