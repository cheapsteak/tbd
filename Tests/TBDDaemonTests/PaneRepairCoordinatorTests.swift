import Clocks
import Darwin
import Foundation
import TestSupport
import Testing

@testable import TBDDaemonLib

/// Phase B M3 — the overflow repair cycle (issue #376, the queue-overflow
/// residual M1/M2 left behind). When a ready, unfenced pane's backpressure
/// queue overflows, the fanout clears the queue, marks the sink `repairing`,
/// and signals the `PaneRepairCoordinator`, which pauses the pane server-side
/// (a paused pane delivers NOTHING — live-probed, tmux 3.6a), waits for the
/// app reader to catch up (pipe writability), then recaptures + continues in
/// ONE atomic list (seam gap exactly zero — live-probed) and replays behind
/// the repair fence. Zero-loss heal of the overflow hole.
///
/// Same seam as `AttachReplayFenceTests`: a real `TmuxControlCommandClient`
/// with recorded stream writes, reply blocks fed by hand, and a real
/// supervisor + fanout so the gate/generation/fence/repair semantics under
/// test are the production ones.
@Suite("PaneRepairCoordinator", .clockDriven)
struct PaneRepairCoordinatorTests {
    private let server = "tbd-repair-unit"

    /// The reader-catch-up pacing the coordinator actually ships with. Under
    /// virtual time there is nothing to gain from shrinking them, so these
    /// tests run the PRODUCTION constants and advance the `TestClock` by them.
    private let checkInterval: Duration = .milliseconds(50)
    private let slowInterval: Duration = .milliseconds(500)

    /// Thread-safe overflow-signal counter.
    private final class SignalCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func increment() { lock.lock(); _count += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    }

    private func makeHarness() -> (
        TmuxControlSupervisor, PaneRepairCoordinator, LineRecorder,
        TmuxControlCommandClient, SignalCounter, TestClock<Duration>
    ) {
        let (client, recorder) = makeFakeClient()
        let supervisor = TmuxControlSupervisor()
        let clock = TestClock()
        let coordinator = PaneRepairCoordinator(
            supervisor: supervisor,
            commandProvider: { [server] in $0 == server ? client : nil },
            clock: clock)
        // Wire the signal exactly as the bridge does, plus a call counter.
        let signals = SignalCounter()
        supervisor.fanout.onOverflowRepair = { key, generation in
            signals.increment()
            Task { await coordinator.repairIfNeeded(key: key, generation: generation) }
        }
        return (supervisor, coordinator, recorder, client, signals, clock)
    }

    /// A 22-field primary-screen state line for `paneID` at 80x24 with the
    /// cursor at (x=2, y=1) — the replay's final CUP must be `ESC[2;3H`.
    private func stateLine(paneID: String) -> String {
        "\(paneID) 2 1 0 4294967295 4294967295 0 23 1 0 0 0 1 0 0 0 0 0 0 80 24 1"
    }

    /// The happy-path capture replies (scrollback, screen, saved, combined,
    /// state, pending) + the batched continue's reply.
    private func captureAndContinueReplies(paneID: String) -> [[String]] {
        [["hist-one"], ["hist-two"], [], ["hist-one", "hist-two"],
         [stateLine(paneID: paneID)], [], []]
    }

    private func setNonblocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Route 32 KB chunks into an unread pipe until the sink flips into
    /// `repairing` (64 KB pipe + 128 KB queue → the 7th chunk overflows).
    private func overflowIntoRepair(
        _ fanout: PaneFanout, paneID: String, key: PaneKey,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let chunk = Data(repeating: 0x41, count: 32 * 1024)
        for _ in 0..<32 {
            fanout.route(server: server, event: .output(paneID: paneID, bytes: chunk))
            if fanout.flowStats(key: key)?.repairing == true { return }
        }
        Issue.record("sink never entered repairing", sourceLocation: sourceLocation)
    }

    /// Read `fd` until EAGAIN — the "app reader caught up" simulation.
    private func drainPipe(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
        }
    }

    /// Complete the next `lines.count` pending commands with `%end`.
    private func succeed(_ client: TmuxControlCommandClient, _ lines: [[String]]) async {
        for reply in lines {
            await client.handle(.commandSucceeded(number: 0, fromClient: true, lines: reply))
        }
    }

    /// Poll-read `fd` (nonblocking) until `condition` holds on the
    /// accumulated text or the deadline passes.
    private func readUntil(
        fd: Int32, deadline: Duration = ciSafeDeadline,
        _ condition: @Sendable (String) -> Bool
    ) async -> String {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                out.append(contentsOf: buffer[0..<n])
                if condition(String(decoding: out, as: UTF8.self)) { break }
                continue
            }
            if n == 0 { break }  // EOF
            try? await Task.sleep(for: .milliseconds(10))
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - The headline: full repair happy path

    @Test("full repair: pause alone → wait for reader → captures+continue atomically → replay → fence flush → streaming resumes")
    func fullRepairHappyPath() async throws {
        let (supervisor, coordinator, recorder, client, signals, clock) = makeHarness()
        _ = coordinator
        let paneID = "%1"
        let key = PaneKey(server: server, paneID: paneID)
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        supervisor.fanout.markReady(key: key, generation: generation)

        // Steady-state overflow on the unread pipe: enters repairing and
        // fires the signal, which starts the repair.
        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        #expect(signals.count == 1)

        // Batch 1 must be the pause ALONE.
        try await waitFor("pause write") { recorder.writes.count >= 1 }
        try #require(recorder.writes.first == "refresh-client -A '%1:pause'",
                     "M3: batch 1 must be the pause ALONE")
        await succeed(client, [[]])  // pause reply — the pane is now silent

        // The reader has NOT caught up (pipe still full): batch 2 must wait.
        // Parking on the reader-wait sleep PROVES the loop is waiting —
        // strictly stronger than inferring it from elapsed wall time.
        await clock.waitForSuspension()
        #expect(recorder.writes.count == 1,
                "captures+continue must not be sent while the reader is behind")

        // The app catches up — the pipe becomes writable.
        drainPipe(readFD)
        await clock.advanceWhenSuspended(by: checkInterval)
        try await waitFor("captures+continue write") { recorder.writes.count >= 2 }
        try #require(recorder.writes.count >= 2, "the captures+continue batch was never sent")
        #expect(recorder.writes[1] == """
            capture-pane -peqJN -S -50000 -E -1 -q -t %1
            capture-pane -peqJN -t %1
            capture-pane -peqJN -a -q -t %1
            capture-pane -peqJN -S -50000 -t %1
            list-panes -t %1 -F '\(PaneStateCapture.format)'
            capture-pane -p -P -C -t %1
            refresh-client -A '%1:continue'
            """,
            "batch 2 must be ONE atomic list: 6 captures with the continue LAST")

        // Post-continue output routed while the repair fence is armed: it
        // must queue behind the replay-in-flight, not drop.
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("FENCED-X".utf8)))

        // Captures + continue complete: replay assembles, lands, endRepair
        // flushes the fence.
        await succeed(client, captureAndContinueReplies(paneID: paneID))

        // Pipe order, byte-exact: replay (ends with the CUP for cursor
        // x=2,y=1), then the fenced bytes — the overflow hole is healed.
        let text = await readUntil(fd: readFD) { $0.hasSuffix("FENCED-X") }
        #expect(text.hasPrefix(ReplayWriter.resetPrelude),
                "repair replay must start with the reset prelude")
        #expect(text.hasSuffix("\u{1b}[2;3HFENCED-X"),
                "expected replay ⊕ fenced, contiguous; tail \(text.suffix(40).debugDescription)")

        // Sink back to steady streaming: repairing cleared, repair counted,
        // direct writes resume.
        try await waitFor("repair completion") {
            let stats = supervisor.fanout.flowStats(key: key)
            return stats?.repairing == false && stats?.queuedBytes == 0
        }
        let stats = try #require(supervisor.fanout.flowStats(key: key))
        #expect(stats.repairs == 1)
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("LIVE-Y".utf8)))
        let live = await readUntil(fd: readFD) { $0.hasSuffix("LIVE-Y") }
        #expect(live == "LIVE-Y", "direct writes must resume after the repair")
        #expect(signals.count == 1, "the whole cycle must ride ONE overflow signal")
    }

    // MARK: - Supersession

    @Test("superseded between batch 1 and batch 2: nothing more sent, no unpause, successor untouched")
    func supersededMidRepairAbortsSilently() async throws {
        let (supervisor, coordinator, recorder, client, _, _) = makeHarness()
        _ = coordinator
        let paneID = "%2"
        let key = PaneKey(server: server, paneID: paneID)
        let (read1, gen1) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read1) }
        setNonblocking(read1)
        supervisor.fanout.markReady(key: key, generation: gen1)

        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("pause write") { recorder.writes.count >= 1 }
        try #require(recorder.writes.first == "refresh-client -A '%2:pause'")

        // A successor attaches while batch 1's reply is in flight: the repair
        // is superseded and must send NOTHING more — in particular NO unpause
        // (R11: the successor's own attach sequence owns the pane's pause
        // state; a stale continue could land inside its pause window).
        let (read2, gen2) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read2) }
        await succeed(client, [[]])  // pause reply → post-pause re-check fires

        // The repair task has provably EXITED (nothing is parked on the
        // clock — the supersession is decided before the reader-wait), so the
        // exit itself is the bound: no later write can appear.
        try await waitFor("repair exit") {
            await coordinator.isInFlight(key) == false
        }
        #expect(recorder.writes.count == 1, "a superseded repair must send NOTHING after the pause")
        #expect(!recorder.writes.contains { $0.contains("capture-pane") })
        #expect(!recorder.writes.contains { $0.contains(":continue'") })

        // Successor untouched: gate closed, nothing queued (a routed chunk
        // drops via the not-ready path, it is not fenced), still ackable.
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("STALE-PROBE".utf8)))
        let stats = try #require(supervisor.fanout.flowStats(key: key))
        #expect(stats.queuedBytes == 0, "the stale repair must not have fenced the successor's sink")
        #expect(stats.repairing == false, "the successor's sink must not inherit the repair state")
        #expect(await supervisor.acknowledgeAttach(
            server: server, paneID: paneID, expectedGeneration: gen2)
            == .acknowledged(generation: gen2),
            "successor must still be acknowledgeable — the stale repair touched nothing")
    }

    // MARK: - Capture failure

    @Test("capture %error: unpause sent, repair aborted, pane not frozen")
    func captureFailureUnpausesAndAborts() async throws {
        let (supervisor, coordinator, recorder, client, _, _) = makeHarness()
        _ = coordinator
        let paneID = "%3"
        let key = PaneKey(server: server, paneID: paneID)
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        supervisor.fanout.markReady(key: key, generation: generation)

        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("pause write") { recorder.writes.count >= 1 }
        drainPipe(readFD)            // reader catches up before the wait starts
        await succeed(client, [[]])  // pause reply → writable on the first check
        try await waitFor("captures+continue write") { recorder.writes.count >= 2 }

        // Scrollback capture %errors (tolerated at the correlator level);
        // the remaining captures and the batched continue succeed.
        await client.handle(.commandFailed(number: 0, fromClient: true, lines: ["no such pane"]))
        await succeed(client, [[], [], [], [stateLine(paneID: paneID)], [], []])

        // The failure path must still unpause (covers "the pause ran but
        // batch 2's continue may not have") and abort the repair — a pane
        // frozen forever is worse than a hole.
        try await waitFor("trailing unpause write") { recorder.writes.count >= 3 }
        #expect(recorder.writes.last == "refresh-client -A '%3:continue'")
        try await waitFor("repair aborted") {
            supervisor.fanout.flowStats(key: key)?.repairing == false
        }
        let stats = try #require(supervisor.fanout.flowStats(key: key))
        #expect(stats.repairs == 0, "a failed repair must not count as completed")

        // Not frozen: live output streams again.
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("LIVE-AFTER-ABORT".utf8)))
        let live = await readUntil(fd: readFD) { $0.hasSuffix("LIVE-AFTER-ABORT") }
        #expect(live.hasSuffix("LIVE-AFTER-ABORT"), "the pane must stream again after an aborted repair")
    }

    // MARK: - Wedged reader

    @Test("wedged reader: NO deadline — no continue, pane stays paused+repairing, and the SAME repair completes when the reader drains")
    func wedgedReaderWaitsOutTheStallThenHeals() async throws {
        // Injected pacing, for the same reason as
        // `readerWaitEscalatesToTheSlowInterval` — but sized to span BOTH
        // thresholds rather than just the escalation one. "NO deadline" is a
        // claim about surviving an arbitrarily long stall, and the production
        // 50 ms / 5 s / 30 s constants cannot express that in a short advance
        // chain: 3 advances of 50 ms reach 150 ms and never leave the fast
        // band, which proves far less than this test's name claims. With
        // 2 s / 4 s / 15 s, FOUR advances reach 34 s of virtual wait — past
        // the escalation threshold AND past the fixed 30 s
        // `readerStallLogThreshold`, so the loop exercises the escalated
        // pacing and the one-shot stall-log branch (nothing else covers the
        // latter). Same short chain, strictly stronger claim.
        let (client, recorder) = makeFakeClient()
        let supervisor = TmuxControlSupervisor()
        let clock = TestClock<Duration>()
        let fast: Duration = .seconds(2)
        let slow: Duration = .seconds(15)
        let coordinator = PaneRepairCoordinator(
            supervisor: supervisor,
            commandProvider: { [server] in $0 == server ? client : nil },
            writableCheckInterval: fast,
            writableSlowInterval: slow,
            writableEscalationThreshold: .seconds(4),
            clock: clock)
        let signals = SignalCounter()
        supervisor.fanout.onOverflowRepair = { key, generation in
            signals.increment()
            Task { await coordinator.repairIfNeeded(key: key, generation: generation) }
        }
        let paneID = "%4"
        let key = PaneKey(server: server, paneID: paneID)
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        supervisor.fanout.markReady(key: key, generation: generation)

        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("pause write") { recorder.writes.count >= 1 }
        await succeed(client, [[]])  // pause reply — reader stays wedged

        // A TRANSIENTLY wedged reader (e.g. a long app main-thread hitch)
        // must not kill the repair: across many poll intervals with the pipe
        // still full, the repair must NOT abort and must NOT send a continue
        // — a continue would just re-overflow. It stays in flight; the pane
        // stays paused (tmux buffers it server-side) and the sink stays
        // `repairing`. Each advance drives exactly one more wait iteration:
        // two fast (2 s + 2 s = the 4 s escalation threshold, so the loop
        // switches to the slow interval) then two slow (+30 s = 34 s), which
        // carries the wait past the fixed 30 s `readerStallLogThreshold` — so
        // the stall-log branch runs exactly once and the loop keeps waiting
        // rather than giving up. Four advances, 34 s of virtual stall. Do NOT
        // lengthen this chain to "prove" more: a long chain of advances is
        // itself a load-sensitivity hazard (see
        // `readerWaitEscalatesToTheSlowInterval`) — reach further thresholds
        // by injecting larger pacing, never by advancing more times.
        for _ in 0..<2 { await clock.advanceWhenSuspended(by: fast) }
        for _ in 0..<2 { await clock.advanceWhenSuspended(by: slow) }
        await clock.waitForSuspension()  // re-armed on the slow interval, pipe still full
        #expect(recorder.writes.count == 1, "no captures and NO continue while the reader is wedged")
        #expect(await coordinator.isInFlight(key) == true, "the repair must keep waiting, not give up")
        let stats = try #require(supervisor.fanout.flowStats(key: key))
        #expect(stats.repairing == true, "the sink must stay repairing — the pane is still paused")
        #expect(stats.repairs == 0)

        // Further overflow-scale routing while repairing: dropped with
        // counters, and NO second overflow signal (the repairing flag gates
        // re-signaling).
        #expect(signals.count == 1)
        let chunk = Data(repeating: 0x42, count: 32 * 1024)
        for _ in 0..<8 {
            supervisor.fanout.route(server: server, event: .output(paneID: paneID, bytes: chunk))
        }
        #expect(signals.count == 1, "a repairing sink must not re-signal")
        let after = try #require(supervisor.fanout.flowStats(key: key))
        #expect(after.droppedEvents >= 8, "routed bytes while repairing are counted drops")

        // The reader unwedges (drains the pipe): the SAME in-flight repair
        // proceeds — batch 2 (captures + continue), replay behind the fence,
        // endRepair, streaming resumed. No new attach needed.
        drainPipe(readFD)
        await clock.advanceWhenSuspended(by: slow)
        try await waitFor("captures+continue write") { recorder.writes.count >= 2 }
        try #require(recorder.writes.count >= 2, "the captures+continue batch was never sent")
        #expect(recorder.writes[1].hasSuffix("refresh-client -A '%4:continue'"),
                "the same repair must send batch 2 once the reader drains")
        await succeed(client, captureAndContinueReplies(paneID: paneID))

        try await waitFor("repair completion") {
            let stats = supervisor.fanout.flowStats(key: key)
            return stats?.repairing == false && stats?.repairs == 1
        }
        let replay = await readUntil(fd: readFD) { $0.hasSuffix("\u{1b}[2;3H") }
        #expect(replay.hasPrefix(ReplayWriter.resetPrelude),
                "the recovered repair must have written the recapture replay")
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("LIVE-AFTER-WEDGE".utf8)))
        let live = await readUntil(fd: readFD) { $0.hasSuffix("LIVE-AFTER-WEDGE") }
        #expect(live.hasSuffix("LIVE-AFTER-WEDGE"), "streaming must resume after the recovered repair")
    }

    // MARK: - Pacing escalation

    @Test("escalation: past the threshold the reader-wait paces on the SLOW interval, not the fast one")
    func readerWaitEscalatesToTheSlowInterval() async throws {
        // The `waited >= writableEscalationThreshold` branch was untestable on
        // the real clock (5 s of wall time per run). Under virtual time it is
        // free, and the root CLAUDE.md gated-branch rule applies.
        //
        // This is the ONE test that injects pacing values instead of running
        // the production 50 ms / 5 s pair (every other test here keeps the
        // production constants). Reason: that ratio needs 100 advances to
        // accumulate the threshold, and a long chain of advances is itself a
        // load-sensitivity hazard — `advanceWhenSuspended` gives the code
        // under test 20 yields to re-park, and is non-throwing, so under load
        // one missed re-park advances a sleeper-less clock and the test hangs
        // forever (the failure mode ClockTestSupport's doc comment names).
        // 100 draws makes that near-certain. A 1 s / 2 s / 10 s pacing proves
        // exactly the same branch in THREE advances. Do not reintroduce a
        // long advance chain here.
        let (client, recorder) = makeFakeClient()
        let supervisor = TmuxControlSupervisor()
        let clock = TestClock<Duration>()
        let fast: Duration = .seconds(1)
        let slow: Duration = .seconds(10)
        let coordinator = PaneRepairCoordinator(
            supervisor: supervisor,
            commandProvider: { [server] in $0 == server ? client : nil },
            writableCheckInterval: fast,
            writableSlowInterval: slow,
            writableEscalationThreshold: .seconds(2),
            clock: clock)
        supervisor.fanout.onOverflowRepair = { key, generation in
            Task { await coordinator.repairIfNeeded(key: key, generation: generation) }
        }
        let paneID = "%13"
        let key = PaneKey(server: server, paneID: paneID)
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        supervisor.fanout.markReady(key: key, generation: generation)

        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("pause write") { recorder.writes.count >= 1 }
        await succeed(client, [[]])  // pause reply — the reader stays wedged

        // Two fast intervals accumulate exactly the escalation threshold, so
        // the interval the loop picks NEXT is the slow one.
        await clock.advanceWhenSuspended(by: fast)
        await clock.advanceWhenSuspended(by: fast)
        await clock.waitForSuspension()  // re-armed — on the slow interval now
        #expect(await coordinator.isInFlight(key) == true, "the wait must still be running")

        // The reader catches up, but the loop is parked on the SLOW interval:
        // a fast-interval advance is not enough to wake it, so batch 2 stays
        // unsent. (Before escalation, this same advance would have sent it —
        // that is `fullRepairHappyPath`.)
        drainPipe(readFD)
        await clock.advanceWhenSuspended(by: fast)
        #expect(recorder.writes.count == 1,
                "past the escalation threshold the wait must sleep the SLOW interval")

        // The rest of the slow interval does wake it, and the repair proceeds.
        await clock.advanceWhenSuspended(by: slow - fast)
        try await waitFor("captures+continue write after escalation") { recorder.writes.count >= 2 }
        try #require(recorder.writes.count >= 2, "the escalated wait never sent batch 2")
        #expect(recorder.writes[1].hasSuffix("refresh-client -A '%13:continue'"))
    }

    // MARK: - Broken pipe

    @Test("broken pipe mid-wait: read end closed → continue sent, abortRepair, repairing cleared")
    func brokenPipeMidWaitUnpausesAndAborts() async throws {
        let (supervisor, coordinator, recorder, client, _, clock) = makeHarness()
        _ = coordinator
        let paneID = "%5"
        let key = PaneKey(server: server, paneID: paneID)
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        var readClosed = false
        defer { if !readClosed { Darwin.close(readFD) } }
        setNonblocking(readFD)
        supervisor.fanout.markReady(key: key, generation: generation)

        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("pause write") { recorder.writes.count >= 1 }
        await succeed(client, [[]])  // pause reply — the reader wait begins

        // A merely-full pipe keeps the repair parked in the reader-wait…
        await clock.waitForSuspension()
        #expect(recorder.writes.count == 1, "still waiting while the pipe is merely full")

        // …then the viewer dies: the READ end closes mid-wait. The pipe can
        // never drain — instead of waiting forever, the repair must unpause
        // (tolerate-errors continue) and abort: the app-death detach path
        // finishes the job, and an unpaused pane stays healthy for the next
        // attach.
        Darwin.close(readFD)
        readClosed = true

        await clock.advanceWhenSuspended(by: checkInterval)
        try await waitFor("trailing continue write") { recorder.writes.count >= 2 }
        #expect(recorder.writes.last == "refresh-client -A '%5:continue'",
                "a broken pipe must unpause the pane")
        #expect(!recorder.writes.contains { $0.contains("capture-pane") },
                "a broken-pipe abort must not run the captures")
        try await waitFor("repair aborted") {
            supervisor.fanout.flowStats(key: key)?.repairing == false
        }
        let stats = try #require(supervisor.fanout.flowStats(key: key))
        #expect(stats.repairs == 0, "a broken-pipe abort must not count as a completed repair")
        try await waitFor("repair exit (in-flight cleared)") {
            await coordinator.isInFlight(key) == false
        }
    }

    // MARK: - No command client (review round 2, S2)

    @Test("no command client: repair aborts — repairing cleared, stream resumes, nothing sent")
    func noCommandClientAbortsRepair() async throws {
        // Bespoke harness: the provider finds no correlator (connection torn
        // down). There is nothing to pause and nothing paused — the repair
        // must abort so the sink unfreezes.
        let supervisor = TmuxControlSupervisor()
        let coordinator = PaneRepairCoordinator(
            supervisor: supervisor,
            commandProvider: { _ in nil })
        supervisor.fanout.onOverflowRepair = { key, generation in
            Task { await coordinator.repairIfNeeded(key: key, generation: generation) }
        }
        let paneID = "%8"
        let key = PaneKey(server: server, paneID: paneID)
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        supervisor.fanout.markReady(key: key, generation: generation)

        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("repair aborted") {
            supervisor.fanout.flowStats(key: key)?.repairing == false
        }
        let stats = try #require(supervisor.fanout.flowStats(key: key))
        #expect(stats.repairs == 0, "a client-less abort must not count as a completed repair")
        try await waitFor("repair exit (in-flight cleared)") {
            await coordinator.isInFlight(key) == false
        }

        // Not frozen: live output streams again once the reader drains.
        drainPipe(readFD)
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("LIVE-NO-CLIENT".utf8)))
        let live = await readUntil(fd: readFD) { $0.hasSuffix("LIVE-NO-CLIENT") }
        #expect(live.hasSuffix("LIVE-NO-CLIENT"), "the stream must resume after a client-less abort")
    }

    // MARK: - Supersession before/at repair start (review round 2, S2)

    @Test("superseded before the repair starts: nothing sent — not even the pause — successor untouched")
    func supersededBeforeRepairStartSendsNothing() async throws {
        let (supervisor, coordinator, recorder, _, _, _) = makeHarness()
        let paneID = "%9"
        let key = PaneKey(server: server, paneID: paneID)
        // Capture-only wiring: the test dispatches the stale signal BY HAND
        // after superseding the generation, pinning the window between the
        // overflow signal and the repair start.
        supervisor.fanout.onOverflowRepair = { _, _ in }

        let (read1, gen1) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read1) }
        setNonblocking(read1)
        supervisor.fanout.markReady(key: key, generation: gen1)
        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)

        // A successor replaces the sink before the (stale) signal's repair
        // ever runs.
        let (read2, gen2) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read2) }

        await coordinator.repairIfNeeded(key: key, generation: gen1)
        #expect(recorder.writes.isEmpty, "a stale repair must send NOTHING — not even the pause")
        #expect(await coordinator.isInFlight(key) == false)
        let stats = try #require(supervisor.fanout.flowStats(key: key))
        #expect(stats.repairing == false, "the successor's sink must not inherit the repair state")
        #expect(stats.queuedBytes == 0, "the stale repair must not have fenced the successor's sink")
        #expect(await supervisor.acknowledgeAttach(
            server: server, paneID: paneID, expectedGeneration: gen2)
            == .acknowledged(generation: gen2),
            "successor must still be acknowledgeable — the stale repair touched nothing")
    }

    /// Thread-safe fd box for the provider-hop test below.
    private final class FDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _fd: Int32 = -1
        func set(_ fd: Int32) { lock.lock(); _fd = fd; lock.unlock() }
        var fd: Int32 { lock.lock(); defer { lock.unlock() }; return _fd }
    }

    @Test("superseded across the provider hop: the post-hop checkpoint refuses — nothing sent")
    func supersededAcrossProviderHopSendsNothing() async throws {
        // Bespoke harness: the provider ITSELF re-attaches the pane before
        // returning the client, superseding the repair generation exactly
        // inside the provider hop — the entry guard has already passed, so
        // this pins the post-hop ownership re-check (R10-3).
        let (client, recorder) = makeFakeClient()
        let supervisor = TmuxControlSupervisor()
        let paneID = "%10"
        let key = PaneKey(server: server, paneID: paneID)
        let successorRead = FDBox()
        let coordinator = PaneRepairCoordinator(
            supervisor: supervisor,
            commandProvider: { [server] requested in
                guard requested == server else { return nil }
                if let (fd, _) = try? await supervisor.attach(server: server, paneID: paneID) {
                    successorRead.set(fd)
                }
                return client
            })
        supervisor.fanout.onOverflowRepair = { _, _ in }
        defer { if successorRead.fd >= 0 { Darwin.close(successorRead.fd) } }

        let (read1, gen1) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read1) }
        setNonblocking(read1)
        supervisor.fanout.markReady(key: key, generation: gen1)
        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)

        await coordinator.repairIfNeeded(key: key, generation: gen1)
        #expect(recorder.writes.isEmpty,
                "a repair superseded across the provider hop must send NOTHING — not even the pause")
        #expect(await coordinator.isInFlight(key) == false)
        let stats = try #require(supervisor.fanout.flowStats(key: key))
        #expect(stats.repairing == false, "the successor's sink must not inherit the repair state")
        #expect(stats.queuedBytes == 0)
    }

    // MARK: - Supersession mid reader-wait (review round 2, S2)

    @Test("superseded mid reader-wait: sink replaced while the pipe is full → silent exit, no continue, successor untouched")
    func supersededMidReaderWaitExitsSilently() async throws {
        let (supervisor, coordinator, recorder, client, _, clock) = makeHarness()
        let paneID = "%11"
        let key = PaneKey(server: server, paneID: paneID)
        let (read1, gen1) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read1) }
        setNonblocking(read1)
        supervisor.fanout.markReady(key: key, generation: gen1)
        _ = gen1

        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("pause write") { recorder.writes.count >= 1 }
        // The pause reply lands while gen-1 still owns the pane: the repair
        // enters the reader-wait (the pipe is full — read1 is never drained).
        await succeed(client, [[]])
        await clock.waitForSuspension()
        #expect(recorder.writes.count == 1, "still waiting while the pipe is merely full")
        #expect(await coordinator.isInFlight(key) == true, "the repair must be parked in the reader-wait")

        // A successor replaces the sink mid-wait: isPipeWritable(gen-1) now
        // returns nil and the repair must exit silently — NO continue (R11:
        // the successor owns the pane's pause state) and no abortRepair on
        // the successor.
        let (read2, gen2) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read2) }
        // Wake the parked wait loop so it re-checks writability and observes
        // the supersession (`nil`). The exit itself then bounds the negative
        // assertions below — the repair task is gone, so no later write can
        // appear.
        await clock.advanceWhenSuspended(by: checkInterval)
        try await waitFor("repair exit") {
            await coordinator.isInFlight(key) == false
        }
        #expect(recorder.writes.count == 1, "a mid-wait supersession must send NOTHING after the pause")
        #expect(!recorder.writes.contains { $0.contains("capture-pane") })
        #expect(!recorder.writes.contains { $0.contains(":continue'") })
        let stats = try #require(supervisor.fanout.flowStats(key: key))
        #expect(stats.repairing == false, "the successor's sink must not inherit the repair state")
        #expect(stats.queuedBytes == 0, "the stale repair must not have fenced the successor's sink")
        #expect(await supervisor.acknowledgeAttach(
            server: server, paneID: paneID, expectedGeneration: gen2)
            == .acknowledged(generation: gen2),
            "successor must still be acknowledgeable — the stale repair touched nothing")
    }

    // MARK: - Bridge wiring (review round 2, S2)

    @Test("bridge wiring: a route() overflow on a bridge-owned fanout drives the default coordinator end-to-end")
    func bridgeWiredCoordinatorRunsRepair() async throws {
        // A REAL TmuxControlModeBridge with its DEFAULT repair coordinator:
        // only the command provider is faked. This drives the production
        // `onOverflowRepair` closure installed in the bridge's init.
        let (client, recorder) = makeFakeClient()
        let supervisor = TmuxControlSupervisor()
        let clock = TestClock<Duration>()
        let bridge = TmuxControlModeBridge(
            supervisor: supervisor,
            tmuxVersion: TmuxVersion(major: 3, minor: 6),
            environment: [:],
            fdVending: FDVendingServer(),
            commandProvider: { [server] in $0 == server ? client : nil },
            clock: clock)
        let paneID = "%12"
        let key = PaneKey(server: server, paneID: paneID)
        let (readFD, generation) = try await bridge.supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        bridge.supervisor.fanout.markReady(key: key, generation: generation)

        // Blast past the cap through route(): the bridge-wired signal must
        // start the repair — the fake client sees the pause.
        overflowIntoRepair(bridge.supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("bridge-wired pause write") { recorder.writes.count >= 1 }
        #expect(recorder.writes.first == "refresh-client -A '%12:pause'",
                "the bridge's default coordinator must run the repair")

        // Complete the cycle so the repair task doesn't outlive the test.
        await succeed(client, [[]])
        // The default coordinator parks on the BRIDGE's clock — proof the
        // bridge threaded its clock into the coordinator it constructed.
        await clock.waitForSuspension()
        drainPipe(readFD)
        await clock.advanceWhenSuspended(by: checkInterval)
        try await waitFor("captures+continue write") { recorder.writes.count >= 2 }
        await succeed(client, captureAndContinueReplies(paneID: paneID))
        try await waitFor("repair completion") {
            let stats = bridge.supervisor.fanout.flowStats(key: key)
            return stats?.repairing == false && stats?.repairs == 1
        }
    }

    // MARK: - Swallowed successor overflow (review round 2, S1)

    @Test("swallowed successor overflow: gen-2's signal deduped while gen-1 is parked → exit re-dispatch heals gen-2")
    func swallowedSuccessorOverflowIsReDispatched() async throws {
        let (supervisor, coordinator, recorder, client, _, _) = makeHarness()
        let paneID = "%6"
        let key = PaneKey(server: server, paneID: paneID)

        // Custom wiring — the bridge's shape plus a completion counter: a
        // SWALLOWED repairIfNeeded returns immediately (dedupe guard), so
        // `returns` lets the test prove gen-2's signal really was deduped
        // while gen-1's repair still held the in-flight slot.
        let returns = SignalCounter()
        supervisor.fanout.onOverflowRepair = { key, generation in
            Task {
                await coordinator.repairIfNeeded(key: key, generation: generation)
                returns.increment()
            }
        }

        // Gen-1 attaches, goes ready, overflows: its repair parks awaiting
        // the pause reply (held by the test — stands in for ANY long await,
        // e.g. the indefinite reader-wait).
        let (read1, gen1) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read1) }
        setNonblocking(read1)
        supervisor.fanout.markReady(key: key, generation: gen1)
        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("gen-1 pause write") { recorder.writes.count >= 1 }
        try #require(recorder.writes.first == "refresh-client -A '%6:pause'")
        _ = gen1

        // The user re-attaches (gen-2 sink), the new sink goes ready and
        // ALSO overflows: its onOverflowRepair signal lands while gen-1's
        // repair is still in flight for the same key — deduped (swallowed).
        let (read2, gen2) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read2) }
        setNonblocking(read2)
        supervisor.fanout.markReady(key: key, generation: gen2)
        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("gen-2 signal swallowed") {
            if returns.count != 1 { return false }
            return await coordinator.isInFlight(key)
        }
        #expect(supervisor.fanout.flowStats(key: key)?.repairing == true)

        // Release gen-1: its pause reply lands and the post-pause generation
        // check supersedes it. WITHOUT the exit re-dispatch, gen-2's sink
        // would stay `repairing` forever — route() drops all its output and
        // enqueueLocked never re-signals: a permanently blank pane.
        await succeed(client, [[]])

        // The coordinator must re-dispatch for the CURRENT generation:
        // gen-2's repair runs to completion.
        try await waitFor("gen-2 pause write (re-dispatch)") { recorder.writes.count >= 2 }
        try #require(recorder.writes.count >= 2, "the swallowed gen-2 repair was never re-dispatched")
        #expect(recorder.writes[1] == "refresh-client -A '%6:pause'")
        drainPipe(read2)             // the reader catches up before the wait starts
        await succeed(client, [[]])  // gen-2 pause reply → writable on the first check
        try await waitFor("gen-2 captures+continue write") { recorder.writes.count >= 3 }
        try #require(recorder.writes.count >= 3, "gen-2's captures+continue were never sent")
        #expect(recorder.writes[2].hasSuffix("refresh-client -A '%6:continue'"))
        await succeed(client, captureAndContinueReplies(paneID: paneID))

        try await waitFor("gen-2 repair completion") {
            let stats = supervisor.fanout.flowStats(key: key)
            return stats?.repairing == false && stats?.repairs == 1
        }
        // The healed gen-2 sink got the replay and streams again.
        let replay = await readUntil(fd: read2) { $0.hasSuffix("\u{1b}[2;3H") }
        #expect(replay.hasPrefix(ReplayWriter.resetPrelude),
                "gen-2's repair must have written the recapture replay")
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("LIVE-GEN2".utf8)))
        let live = await readUntil(fd: read2) { $0.hasSuffix("LIVE-GEN2") }
        #expect(live.hasSuffix("LIVE-GEN2"), "streaming must resume on the healed successor")
        try await waitFor("gen-1 dispatch returns") { returns.count == 2 }
    }

    // MARK: - %error'd batched continue (review round 2, M3)

    @Test("%error'd batched continue: the repair completes AND retries one tolerate-errors continue")
    func erroredBatchedContinueRetriesAfterEndRepair() async throws {
        let (supervisor, coordinator, recorder, client, _, _) = makeHarness()
        _ = coordinator
        let paneID = "%7"
        let key = PaneKey(server: server, paneID: paneID)
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        supervisor.fanout.markReady(key: key, generation: generation)

        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("pause write") { recorder.writes.count >= 1 }
        drainPipe(readFD)            // reader catches up before the wait starts
        await succeed(client, [[]])  // pause reply → writable on the first check
        try await waitFor("captures+continue write") { recorder.writes.count >= 2 }

        // All six captures succeed; the batched continue %errors (tolerated
        // at the correlator level — NOT a connection close, which would fail
        // the captures too and abort the repair on its own).
        await succeed(client, [["hist-one"], ["hist-two"], [], ["hist-one", "hist-two"],
                               [stateLine(paneID: paneID)], []])
        await client.handle(.commandFailed(number: 0, fromClient: true, lines: ["unknown flag"]))

        // The repair still completes (replay lands, fence flushes)…
        try await waitFor("repair completion") {
            let stats = supervisor.fanout.flowStats(key: key)
            return stats?.repairing == false && stats?.repairs == 1
        }
        // …and a retry continue goes out: without it the pane LOOKS healthy
        // (repair counted, stream resumed) but stays PAUSED server-side.
        try await waitFor("retry continue write") { recorder.writes.count >= 3 }
        #expect(recorder.writes.last == "refresh-client -A '%7:continue'",
                "an %error'd batched continue must be retried once, tolerate-errors")
    }
}
