import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// Unit tests for the attach orchestration v2 (M4.3): pause → capture →
/// replay → gate → unpause. No tmux — same seam as the resize-coordinator
/// tests: a real `TmuxControlCommandClient` whose `writeLine` records stream
/// writes synchronously, with reply blocks fed by hand through
/// `client.handle(...)`. The supervisor (and its fanout) are real, so the
/// gate/generation semantics under test are the production ones.
@Suite("AttachReplayOrchestrator")
struct AttachReplayOrchestratorTests {
    private let server = "tbd-orch-unit"

    /// Thread-safe, synchronous recorder of stream writes in call order.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [String] = []
        func record(_ line: String) { lock.lock(); _writes.append(line); lock.unlock() }
        var writes: [String] { lock.lock(); defer { lock.unlock() }; return _writes }
    }

    /// Thread-safe truncation-hook recorder.
    private final class TruncationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _counts: [Int] = []
        func record(_ count: Int) { lock.lock(); _counts.append(count); lock.unlock() }
        var counts: [Int] { lock.lock(); defer { lock.unlock() }; return _counts }
    }

    private func makeHarness(
        historyDepth: Int = 50_000,
        onHistoryTruncation: (@Sendable (Int) -> Void)? = nil
    ) -> (TmuxControlSupervisor, AttachReplayOrchestrator, Recorder, TmuxControlCommandClient) {
        let recorder = Recorder()
        let client = TmuxControlCommandClient(
            writeLine: { recorder.record($0) },
            onFatalError: {})
        let supervisor = TmuxControlSupervisor()
        let orchestrator = AttachReplayOrchestrator(
            supervisor: supervisor,
            commandProvider: { [server] in $0 == server ? client : nil },
            historyDepth: historyDepth,
            onHistoryTruncation: onHistoryTruncation)
        return (supervisor, orchestrator, recorder, client)
    }

    /// A 21-field primary-screen state line for `paneID` at 80x24 with the
    /// cursor at (x=2, y=1) — final CUP must be `ESC[2;3H`.
    private func stateLine(paneID: String) -> String {
        "\(paneID) 2 1 0 4294967295 4294967295 0 23 1 0 0 0 1 0 0 0 0 0 0 80 24"
    }

    /// Poll until `condition`, failing after `deadline` (async work — the
    /// orchestrator's batch write — lands on other tasks).
    private func waitFor(
        _ what: String, deadline: Duration = .seconds(5),
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

    /// Complete the next `count` pending commands with `%end`, per-command lines.
    private func succeed(_ client: TmuxControlCommandClient, _ lines: [[String]]) async {
        for reply in lines {
            await client.handle(.commandSucceeded(number: 0, fromClient: true, lines: reply))
        }
    }

    /// Await `body` expecting an `AttachReplayFailure` whose generation is
    /// `generation`; returns its underlying error for case matching. Records
    /// an issue (and returns nil) on success or a bare/unwrapped error.
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

    /// Drain everything currently readable from `fd` (made nonblocking).
    private func drain(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }

    @Test("happy path: pause+captures in ONE write, gate opens only after replay, unpause last")
    func happyPathOrder() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%1"
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        // Echo the generation like the app does (M2 review fix): a MATCHING
        // echo must run the sequence exactly like a generation-less ready.
        let task = Task {
            try await orchestrator.performAttachReady(
                server: server, paneID: paneID, expectedGeneration: generation)
        }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }

        // ONE atomic stream write: pause FIRST, then the 4-command capture.
        #expect(recorder.writes.count == 1)
        let batch = try #require(recorder.writes.first)
        #expect(batch == """
            refresh-client -A '%1:pause'
            capture-pane -peqJN -S -50000 -t %1
            capture-pane -peqJN -a -q -t %1
            list-panes -t %1 -F '\(PaneStateCapture.format)'
            capture-pane -p -P -C -t %1
            """)

        // Gate still closed during the capture window: a fabricated %output
        // routed mid-sequence must be dropped, not delivered before the replay.
        #expect(await supervisor.isReady(server: server, paneID: paneID) == false)
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("MID-SEQUENCE".utf8)))

        // Reply blocks in FIFO order: pause, history, alt, state, pending.
        await succeed(client, [[], ["hist-one", "hist-two"], [], [stateLine(paneID: paneID)], []])

        let outcome = try await task.value
        #expect(outcome == .ready)
        #expect(await supervisor.isReady(server: server, paneID: paneID) == true)

        // Unpause is the LAST command, sent after markReady.
        try await waitFor("unpause write") { recorder.writes.count >= 2 }
        #expect(recorder.writes.count == 2)
        #expect(recorder.writes.last == "refresh-client -A '%1:continue'")

        // The pipe holds the replay: prelude first, history present, final
        // bytes are the CUP for cursor (x=2, y=1) — and no mid-sequence leak.
        let replay = drain(readFD)
        let text = String(decoding: replay, as: UTF8.self)
        #expect(text.hasPrefix(ReplayWriter.resetPrelude))
        #expect(text.contains("hist-one\r\nhist-two"))
        #expect(text.hasSuffix("\u{1b}[2;3H"))
        #expect(!text.contains("MID-SEQUENCE"))

        // Output routed AFTER the gate opened lands behind the replay.
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("live-after".utf8)))
        #expect(String(decoding: drain(readFD), as: UTF8.self) == "live-after")
    }

    @Test("superseded mid-sequence: outcome success-shaped, successor's gate untouched, NO unpause")
    func supersededMidSequence() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%2"
        let (read1, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read1) }

        let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }

        // A newer attach replaces the sink before the replies arrive.
        let (read2, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read2) }

        await succeed(client, [[], ["hist"], [], [stateLine(paneID: paneID)], []])
        let outcome = try await task.value
        #expect(outcome == .superseded)

        // This task must NOT open the successor's gate — its own sequence does.
        #expect(await supervisor.isReady(server: server, paneID: paneID) == false)

        // And it must NOT unpause either (M2 review fix): pause state is per
        // PANE on the shared correlator, and the successor's own sequence —
        // FIFO-behind ours — pauses and unpauses it. A stale `continue` here
        // could land while the successor is mid-capture with its gate still
        // closed, resuming live output into a closed gate. The sequence ended
        // (task.value returned), so the write log is final: batch only.
        #expect(recorder.writes.count == 1)
        #expect(!recorder.writes.contains { $0.contains(":continue'") })
    }

    @Test("stale ready (echoed generation != current attach) sends ZERO commands, successor stays un-acked")
    func staleReadyMismatchedGenerationSendsNothing() async throws {
        let (supervisor, orchestrator, recorder, _) = makeHarness()
        let paneID = "%11"
        let (read1, gen1) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read1) }
        // A newer attach owns the pane before the stale ready is processed
        // (the worst interleaving: the stale ready would otherwise PAUSE the
        // pane after the successor's full sequence and leave it paused).
        let (read2, gen2) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read2) }

        let outcome = try await orchestrator.performAttachReady(
            server: server, paneID: paneID, expectedGeneration: gen1)
        #expect(outcome == .superseded)
        // NOTHING on the shared correlator: no pause, no captures, no continue.
        #expect(recorder.writes.isEmpty)

        // The stale ready must not have ACKED the successor's sink either —
        // its ready-timeout still stands guard, so a gen-2 timer still fires.
        await supervisor.detachIfNotReady(server: server, paneID: paneID, generation: gen2)
        let flags = fcntl(read2, F_GETFL)
        _ = fcntl(read2, F_SETFL, flags | O_NONBLOCK)
        var probe = [UInt8](repeating: 0, count: 8)
        let n = probe.withUnsafeMutableBytes { Darwin.read(read2, $0.baseAddress, $0.count) }
        #expect(n == 0, "successor must still be un-acked (timer detach EOFs it)")
    }

    @Test("a capture %error fails the attach but the unpause is still sent")
    func captureErrorFailsAttachUnpauseStillSent() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%3"
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }

        // pause OK, main-history capture returns %error (tolerated at the
        // correlator level so the connection survives), rest succeed.
        await client.handle(.commandSucceeded(number: 0, fromClient: true, lines: []))
        await client.handle(.commandFailed(number: 0, fromClient: true, lines: ["no such pane"]))
        await succeed(client, [[], [stateLine(paneID: paneID)], []])

        let underlying = await expectFailure(generation: generation) { try await task.value }
        #expect(underlying as? AttachReplayError == .captureFailed(
            command: "capture-pane -peqJN -S -50000 -t %3"))
        #expect(await supervisor.isReady(server: server, paneID: paneID) == false)
        try await waitFor("unpause write") { recorder.writes.count >= 2 }
        #expect(recorder.writes.last == "refresh-client -A '%3:continue'")
    }

    @Test("a malformed pending-output escape fails the attach; unpause still sent")
    func malformedPendingFailsAttach() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%4"
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }

        // Pending line with `\` not followed by three octal digits.
        await succeed(client, [[], ["hist"], [], [stateLine(paneID: paneID)], ["bad\\9x"]])

        let underlying = await expectFailure(generation: generation) { try await task.value }
        #expect(underlying is ReplayWriterError)
        #expect(await supervisor.isReady(server: server, paneID: paneID) == false)
        try await waitFor("unpause write") { recorder.writes.count >= 2 }
        #expect(recorder.writes.last == "refresh-client -A '%4:continue'")
    }

    @Test("no live attach for the pane: throws BARE notAttached before any command is sent")
    func notAttachedThrowsBeforePause() async throws {
        let (_, orchestrator, recorder, _) = makeHarness()
        // Deliberately NOT wrapped in AttachReplayFailure: no generation
        // exists yet, and the RPC layer must not detach anything on it.
        await #expect(throws: AttachReplayError.notAttached) {
            try await orchestrator.performAttachReady(server: server, paneID: "%5")
        }
        // No pause was ever written — nothing to unpause.
        #expect(recorder.writes.isEmpty)
    }

    @Test("unknown server (no command client): generation-tagged failure before any command is sent")
    func noCommandClientThrows() async throws {
        let supervisor = TmuxControlSupervisor()
        let orchestrator = AttachReplayOrchestrator(
            supervisor: supervisor, commandProvider: { _ in nil })
        let (readFD, generation) = try await supervisor.attach(server: "other-server", paneID: "%6")
        defer { Darwin.close(readFD) }
        let underlying = await expectFailure(generation: generation) {
            try await orchestrator.performAttachReady(server: "other-server", paneID: "%6")
        }
        #expect(underlying as? AttachReplayError == .noCommandClient)
    }

    @Test("truncation telemetry fires at >= historyDepth lines, not below")
    func truncationTelemetry() async throws {
        for (lineCount, expectFire) in [(3, true), (2, false)] {
            let truncations = TruncationRecorder()
            let (supervisor, orchestrator, recorder, client) = makeHarness(
                historyDepth: 3, onHistoryTruncation: { truncations.record($0) })
            let paneID = "%9"
            let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
            defer { Darwin.close(readFD) }

            let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
            try await waitFor("capture batch write") { recorder.writes.count >= 1 }
            // The injected depth reaches the capture command too.
            #expect(recorder.writes.first?.contains("capture-pane -peqJN -S -3 -t %9") == true)

            let history = (0..<lineCount).map { "line-\($0)" }
            await succeed(client, [[], history, [], [stateLine(paneID: paneID)], []])
            let outcome = try await task.value
            #expect(outcome == .ready)
            #expect(truncations.counts == (expectFire ? [lineCount] : []),
                    "depth 3, \(lineCount) lines")
            _ = drain(readFD)
        }
    }

    @Test("list-panes reply missing the pane fails the attach")
    func paneStateMissingFailsAttach() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%10"
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }
        // The state reply describes a DIFFERENT pane.
        await succeed(client, [[], ["hist"], [], [stateLine(paneID: "%99")], []])

        let underlying = await expectFailure(generation: generation) { try await task.value }
        #expect(underlying as? AttachReplayError == .paneStateMissing)
        try await waitFor("unpause write") { recorder.writes.count >= 2 }
        #expect(recorder.writes.last == "refresh-client -A '%10:continue'")
    }
}
