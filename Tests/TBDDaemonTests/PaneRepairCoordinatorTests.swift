import Darwin
import Foundation
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
@Suite("PaneRepairCoordinator")
struct PaneRepairCoordinatorTests {
    private let server = "tbd-repair-unit"

    /// Thread-safe, synchronous recorder of stream writes in call order.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [String] = []
        func record(_ line: String) { lock.lock(); _writes.append(line); lock.unlock() }
        var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
    }

    /// Thread-safe overflow-signal counter.
    private final class SignalCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func increment() { lock.lock(); _count += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    }

    private func makeHarness(
        writableCheckInterval: Duration = .milliseconds(10),
        writableDeadline: Duration = .seconds(15)
    ) -> (TmuxControlSupervisor, PaneRepairCoordinator, Recorder, TmuxControlCommandClient, SignalCounter) {
        let recorder = Recorder()
        let client = TmuxControlCommandClient(
            writeLine: { recorder.record($0) },
            onFatalError: {})
        let supervisor = TmuxControlSupervisor()
        let coordinator = PaneRepairCoordinator(
            supervisor: supervisor,
            commandProvider: { [server] in $0 == server ? client : nil },
            writableCheckInterval: writableCheckInterval,
            writableDeadline: writableDeadline)
        // Wire the signal exactly as the bridge does, plus a call counter.
        let signals = SignalCounter()
        supervisor.fanout.onOverflowRepair = { key, generation in
            signals.increment()
            Task { await coordinator.repairIfNeeded(key: key, generation: generation) }
        }
        return (supervisor, coordinator, recorder, client, signals)
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

    /// Poll until `condition`, failing after `deadline`.
    private func waitFor(
        _ what: String, deadline: Duration = .seconds(15),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
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
        fd: Int32, deadline: Duration = .seconds(15),
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
        let (supervisor, coordinator, recorder, client, signals) = makeHarness()
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
        try await Task.sleep(for: .milliseconds(200))  // bounded negative check
        #expect(recorder.writes.count == 1,
                "captures+continue must not be sent while the reader is behind")

        // The app catches up — the pipe becomes writable.
        drainPipe(readFD)
        try await waitFor("captures+continue write") { recorder.writes.count >= 2 }
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
        let (supervisor, coordinator, recorder, client, _) = makeHarness()
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

        try await waitFor("repair exit") {
            await coordinator.isInFlight(key) == false
        }
        try await Task.sleep(for: .milliseconds(200))  // bounded negative check
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
        let (supervisor, coordinator, recorder, client, _) = makeHarness()
        _ = coordinator
        let paneID = "%3"
        let key = PaneKey(server: server, paneID: paneID)
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        supervisor.fanout.markReady(key: key, generation: generation)

        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("pause write") { recorder.writes.count >= 1 }
        await succeed(client, [[]])  // pause reply
        drainPipe(readFD)            // reader catches up
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

    @Test("wedged reader: deadline exceeded → NO continue, pane stays paused+repairing, no re-signal while repairing")
    func wedgedReaderLeavesPanePaused() async throws {
        // Tiny injected deadline: the pipe is never drained.
        let (supervisor, coordinator, recorder, client, signals) = makeHarness(
            writableCheckInterval: .milliseconds(10),
            writableDeadline: .milliseconds(150))
        let paneID = "%4"
        let key = PaneKey(server: server, paneID: paneID)
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        setNonblocking(readFD)
        supervisor.fanout.markReady(key: key, generation: generation)

        overflowIntoRepair(supervisor.fanout, paneID: paneID, key: key)
        try await waitFor("pause write") { recorder.writes.count >= 1 }
        await succeed(client, [[]])  // pause reply — reader never catches up

        // The repair must exit past its deadline WITHOUT sending a continue:
        // a continue would just re-overflow. The pane stays paused (tmux
        // buffers it server-side in pane history) and the sink stays
        // `repairing`; a later attach re-runs the full capture sequence.
        try await waitFor("repair exit (in-flight cleared)") {
            await coordinator.isInFlight(key) == false
        }
        try await Task.sleep(for: .milliseconds(200))  // bounded negative check
        #expect(recorder.writes.count == 1, "no captures and NO continue on a wedged reader")
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
    }
}
