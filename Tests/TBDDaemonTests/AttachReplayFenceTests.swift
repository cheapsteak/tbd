import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// Phase B M2 — the attach-boundary fence (issue #376, second bullet).
///
/// Before M2, output a pane emitted between the attach's capture and the
/// trailing unpause (~0.2–0.5 s under load) was dropped by the closed gate
/// and lost to the viewer. M2 closes that seam with two probe-verified tmux
/// facts (3.6a): a PAUSED pane delivers nothing (its output lands in pane
/// history, reachable via capture), and an atomic `[captures…, continue]`
/// command list has a seam gap of exactly zero. The orchestrator therefore
/// runs TWO batches — pause alone (await: the pane is provably silent), then
/// captures + continue as one atomic list — arming a generation-scoped fence
/// between them; fenced output queues behind the closed gate and `markReady`
/// flushes it right after the replay. Zero loss at the attach seam.
///
/// Same seam as `AttachReplayOrchestratorTests`: a real
/// `TmuxControlCommandClient` with recorded stream writes, reply blocks fed
/// by hand, and a real supervisor + fanout so the gate/generation/fence
/// semantics under test are the production ones.
@Suite("AttachReplayFence")
struct AttachReplayFenceTests {
    private let server = "tbd-fence-unit"

    /// Thread-safe, synchronous recorder of stream writes in call order.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [String] = []
        func record(_ line: String) { lock.lock(); _writes.append(line); lock.unlock() }
        var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
    }

    private func makeHarness() -> (
        TmuxControlSupervisor, AttachReplayOrchestrator, Recorder, TmuxControlCommandClient
    ) {
        let recorder = Recorder()
        let client = TmuxControlCommandClient(
            writeLine: { recorder.record($0) },
            onFatalError: {})
        let supervisor = TmuxControlSupervisor()
        let orchestrator = AttachReplayOrchestrator(
            supervisor: supervisor,
            commandProvider: { [server] in $0 == server ? client : nil })
        return (supervisor, orchestrator, recorder, client)
    }

    /// A 22-field primary-screen state line for `paneID` at 80x24 with the
    /// cursor at (x=2, y=1) — the replay's final CUP must be `ESC[2;3H`.
    private func stateLine(paneID: String) -> String {
        "\(paneID) 2 1 0 4294967295 4294967295 0 23 1 0 0 0 1 0 0 0 0 0 0 80 24 1"
    }

    /// Poll until `condition`, failing after `deadline` (async work — the
    /// orchestrator's batch writes — lands on other tasks).
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

    /// The happy-path capture replies (scrollback, screen, saved, combined,
    /// state, pending) + the batched continue's reply.
    private func captureAndContinueReplies(paneID: String) -> [[String]] {
        [["hist-one"], ["hist-two"], [], ["hist-one", "hist-two"],
         [stateLine(paneID: paneID)], [], []]
    }

    /// Await `body` expecting an `AttachReplayFailure` tagged `generation`;
    /// returns its underlying error for case matching.
    private func expectFailure(
        generation: UInt64,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> AttachReplayOrchestrator.Outcome
    ) async -> (any Error)? {
        do {
            _ = try await body()
            Issue.record("expected AttachReplayFailure, got success", sourceLocation: sourceLocation)
        } catch let failure as AttachReplayFailure {
            #expect(failure.generation == generation,
                    "failure must carry the sequence's own generation",
                    sourceLocation: sourceLocation)
            return failure.underlying
        } catch {
            Issue.record(
                "expected AttachReplayFailure, got \(error)", sourceLocation: sourceLocation)
        }
        return nil
    }

    /// Poll-read `fd` (made nonblocking) until `condition` holds on the
    /// accumulated text or the deadline passes — the fence flush arrives via
    /// the async drain task, so a one-shot read snapshot could race it.
    private func readUntil(
        fd: Int32, deadline: Duration = .seconds(15),
        _ condition: @Sendable (String) -> Bool
    ) async -> String {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
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

    // MARK: - The headline: seam closure

    @Test("seam closure: output routed while fenced lands after the replay, before later live bytes — nothing lost")
    func fencedBytesFlushAfterReplayInOrder() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%1"
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task {
            try await orchestrator.performAttachReady(
                server: server, paneID: paneID, expectedGeneration: generation)
        }
        try await waitFor("pause batch write") { recorder.writes.count >= 1 }
        try #require(recorder.writes.first == "refresh-client -A '%1:pause'",
                     "M2: batch 1 must be the pause ALONE")

        // The pause reply lands: the pane is provably silent, the fence arms,
        // and the captures+continue batch goes out.
        await succeed(client, [[]])
        try await waitFor("capture+continue batch write") { recorder.writes.count >= 2 }
        try #require(recorder.writes.count >= 2, "captures+continue batch never sent")

        // X: what the pane emits after the batched continue — routed while
        // the gate is still closed but the fence is armed. Must be QUEUED,
        // not dropped.
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("FENCED-X".utf8)))

        // Captures + the batched continue complete; the replay assembles and
        // lands behind the closed gate, then markReady flushes the fence.
        await succeed(client, captureAndContinueReplies(paneID: paneID))
        #expect(try await task.value == .ready)

        // Y: live output after the sequence returned.
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("LIVE-Y".utf8)))

        // Pipe order, byte-exact: replay (ends with the CUP for cursor
        // x=2,y=1), then X, then Y — the seam is ZERO.
        let text = await readUntil(fd: readFD) { $0.hasSuffix("LIVE-Y") }
        #expect(text.hasPrefix(ReplayWriter.resetPrelude))
        #expect(text.hasSuffix("\u{1b}[2;3HFENCED-XLIVE-Y"),
                "expected replay ⊕ fenced ⊕ live, contiguous; tail \(text.suffix(40).debugDescription)")

        // Nothing was dropped anywhere along the way.
        let stats = try #require(supervisor.fanout.flowStats(
            key: PaneKey(server: server, paneID: paneID)))
        #expect(stats.droppedBytes == 0)
        #expect(stats.droppedEvents == 0)
    }

    @Test("pre-pause output is still dropped (it is in the capture, not lost) and never reaches the pipe")
    func prePauseBytesStillDropped() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%2"
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task {
            try await orchestrator.performAttachReady(
                server: server, paneID: paneID, expectedGeneration: generation)
        }
        try await waitFor("pause batch write") { recorder.writes.count >= 1 }
        try #require(recorder.writes.first == "refresh-client -A '%2:pause'",
                     "M2: batch 1 must be the pause ALONE")

        // Routed BEFORE the pause reply completes: the fence is not armed
        // yet, so this is the pre-M2 drop window — the bytes are part of the
        // capture, and delivering them too would duplicate them.
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("PRE-FENCE-DROPPED".utf8)))

        await succeed(client, [[]])
        try await waitFor("capture+continue batch write") { recorder.writes.count >= 2 }
        try #require(recorder.writes.count >= 2, "captures+continue batch never sent")
        await succeed(client, captureAndContinueReplies(paneID: paneID))
        #expect(try await task.value == .ready)

        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("LIVE-Z".utf8)))
        let text = await readUntil(fd: readFD) { $0.hasSuffix("LIVE-Z") }
        #expect(text.hasSuffix("\u{1b}[2;3HLIVE-Z"),
                "live bytes must directly follow the replay; tail \(text.suffix(40).debugDescription)")
        #expect(!text.contains("PRE-FENCE-DROPPED"),
                "pre-pause output is in the capture — routing it too would duplicate it")
    }

    @Test("two sendLists: batch 1 is the pause alone, batch 2 is the captures with the continue LAST, no separate unpause")
    func twoBatchesContinueLast() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%3"
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task {
            try await orchestrator.performAttachReady(
                server: server, paneID: paneID, expectedGeneration: generation)
        }
        try await waitFor("pause batch write") { recorder.writes.count >= 1 }
        try #require(recorder.writes.first == "refresh-client -A '%3:pause'",
                     "M2: batch 1 must be the pause ALONE")

        await succeed(client, [[]])
        try await waitFor("capture+continue batch write") { recorder.writes.count >= 2 }
        try #require(recorder.writes.count >= 2, "captures+continue batch never sent")
        #expect(recorder.writes[1] == """
            capture-pane -peqJN -S -50000 -E -1 -q -t %3
            capture-pane -peqJN -t %3
            capture-pane -peqJN -a -q -t %3
            capture-pane -peqJN -S -50000 -t %3
            list-panes -t %3 -F '\(PaneStateCapture.format)'
            capture-pane -p -P -C -t %3
            refresh-client -A '%3:continue'
            """,
            "batch 2 must be ONE atomic list: 6 captures with the continue LAST")

        await succeed(client, captureAndContinueReplies(paneID: paneID))
        #expect(try await task.value == .ready)

        // SUCCESS path sends no trailing unpause — the batched continue
        // already ran (bounded negative check; the sequence has returned).
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.writes.count == 2,
                "no separate post-replay unpause may be sent on success")
        _ = await readUntil(fd: readFD) { $0.hasSuffix("H") }
    }

    @Test("superseded between batch 1 and batch 2: captures+continue never sent, no unpause, successor untouched")
    func supersededBetweenBatches() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%4"
        let (read1, gen1) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read1) }

        let task = Task {
            try await orchestrator.performAttachReady(
                server: server, paneID: paneID, expectedGeneration: gen1)
        }
        try await waitFor("pause batch write") { recorder.writes.count >= 1 }
        try #require(recorder.writes.first == "refresh-client -A '%4:pause'",
                     "M2: batch 1 must be the pause ALONE")

        // A successor attaches while batch 1 is in flight (its reply held).
        let (read2, gen2) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read2) }

        // The pause reply lands: the post-pause re-check must see gen2 and
        // stand down — sending NOTHING more (R11: the successor owns the
        // pane's pause state; a stale continue could land inside its pause
        // window).
        await succeed(client, [[]])
        #expect(try await task.value == .superseded)

        try await Task.sleep(for: .milliseconds(200))  // bounded negative check
        #expect(recorder.writes.count == 1, "batch 2 must never be sent by a superseded sequence")
        #expect(!recorder.writes.contains { $0.contains("capture-pane") })
        #expect(!recorder.writes.contains { $0.contains(":continue'") })

        // Successor's sink untouched: gate closed, un-acked (its own ready
        // still owns the sequence), no fence armed (a routed chunk drops
        // rather than queues).
        #expect(await supervisor.isReady(server: server, paneID: paneID) == false)
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("STALE-PROBE".utf8)))
        let stats = try #require(supervisor.fanout.flowStats(
            key: PaneKey(server: server, paneID: paneID)))
        #expect(stats.queuedBytes == 0, "the stale sequence must not have fenced the successor's sink")
        #expect(await supervisor.acknowledgeAttach(
            server: server, paneID: paneID, expectedGeneration: gen2)
            == .acknowledged(generation: gen2),
            "successor must still be acknowledgeable — the stale sequence touched nothing")
    }

    @Test("error path still unpauses: a capture %error in batch 2 sends a trailing generation-checked continue")
    func errorPathUnpauses() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%5"
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task {
            try await orchestrator.performAttachReady(
                server: server, paneID: paneID, expectedGeneration: generation)
        }
        try await waitFor("pause batch write") { recorder.writes.count >= 1 }
        try #require(recorder.writes.first == "refresh-client -A '%5:pause'",
                     "M2: batch 1 must be the pause ALONE")
        await succeed(client, [[]])
        try await waitFor("capture+continue batch write") { recorder.writes.count >= 2 }
        try #require(recorder.writes.count >= 2, "captures+continue batch never sent")

        // Scrollback capture %errors (tolerated at the correlator level);
        // the remaining captures and the batched continue succeed.
        await client.handle(.commandFailed(number: 0, fromClient: true, lines: ["no such pane"]))
        await succeed(client, [[], [], [], [stateLine(paneID: paneID)], [], []])

        let underlying = await expectFailure(generation: generation) { try await task.value }
        #expect(underlying as? AttachReplayError == .captureFailed(
            command: "capture-pane -peqJN -S -50000 -E -1 -q -t %5"))

        // The failure path must still send its own generation-checked
        // continue: it covers "the pause ran but batch 2's continue may not
        // have" (e.g. a connection close mid-batch). Redundant here — a
        // continue on an unpaused pane no-ops via tolerate-errors.
        try await waitFor("trailing unpause write") { recorder.writes.count >= 3 }
        #expect(recorder.writes.last == "refresh-client -A '%5:continue'")
    }
}
