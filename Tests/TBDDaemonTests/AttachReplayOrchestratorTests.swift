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

    /// Parks the FIRST `commandProvider` call until `release()`; every later
    /// call passes straight through. Models a stale attach.ready task
    /// preempted at the provider hop while a successor's sequence runs.
    private final class ProviderGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private var firstCallTaken = false
        private var parkedArrived = false

        var hasParkedCaller: Bool {
            lock.lock(); defer { lock.unlock() }
            return parkedArrived
        }

        /// Synchronous claim: returns whether the caller is the FIRST (the
        /// one that must park). NSLock is barred from async contexts, so the
        /// locking happens in sync helpers.
        private func claimFirstCall() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if firstCallTaken { return false }
            firstCallTaken = true
            return true
        }

        /// Synchronous park attempt: records arrival and either parks `cont`
        /// (returns nil) or hands it back for an immediate resume (already
        /// released).
        private func parkOrPassThrough(
            _ cont: CheckedContinuation<Void, Never>
        ) -> CheckedContinuation<Void, Never>? {
            lock.lock()
            defer { lock.unlock() }
            parkedArrived = true
            if released { return cont }
            continuation = cont
            return nil
        }

        func parkIfFirstCall() async {
            guard claimFirstCall() else { return }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                parkOrPassThrough(cont)?.resume()
            }
        }

        func release() {
            lock.lock()
            released = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume()
        }
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
        onHistoryTruncation: (@Sendable (Int) -> Void)? = nil,
        onPauseFailure: (@Sendable (String) -> Void)? = nil
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
            onHistoryTruncation: onHistoryTruncation,
            onPauseFailure: onPauseFailure)
        return (supervisor, orchestrator, recorder, client)
    }

    /// A 22-field primary-screen state line for `paneID` at 80x24 with the
    /// cursor at (x=2, y=1) — final CUP must be `ESC[2;3H`. `historySize`
    /// gates the pure-scrollback leg (review H1): > 0 keeps it, 0 discards.
    private func stateLine(paneID: String, historySize: Int = 1) -> String {
        "\(paneID) 2 1 0 4294967295 4294967295 0 23 1 0 0 0 1 0 0 0 0 0 0 80 24 \(historySize)"
    }

    /// A 22-field ALT-SCREEN state line for `paneID` at 80x24 (saved cursor
    /// 0,0; current cursor x=2, y=1).
    private func altStateLine(paneID: String, historySize: Int = 1) -> String {
        "\(paneID) 2 1 1 0 0 0 23 1 0 0 0 1 0 0 0 0 0 0 80 24 \(historySize)"
    }

    /// Poll until `condition`, failing after `deadline` (async work — the
    /// orchestrator's batch write — lands on other tasks).
    private func waitFor(
        _ what: String, deadline: Duration = .seconds(60),
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

        // ONE atomic stream write: pause FIRST, then the 6-command capture
        // (four legs: pure scrollback / current screen / saved primary /
        // combined history+screen — R8-M3).
        #expect(recorder.writes.count == 1)
        let batch = try #require(recorder.writes.first)
        #expect(batch == """
            refresh-client -A '%1:pause'
            capture-pane -peqJN -S -50000 -E -1 -q -t %1
            capture-pane -peqJN -t %1
            capture-pane -peqJN -a -q -t %1
            capture-pane -peqJN -S -50000 -t %1
            list-panes -t %1 -F '\(PaneStateCapture.format)'
            capture-pane -p -P -C -t %1
            """)

        // Gate still closed during the capture window: a fabricated %output
        // routed mid-sequence must be dropped, not delivered before the replay.
        #expect(await supervisor.isReady(server: server, paneID: paneID) == false)
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("MID-SEQUENCE".utf8)))

        // Reply blocks in FIFO order: pause, scrollback, screen, saved,
        // combined, state, pending. Non-alt uses the combined leg verbatim.
        await succeed(client, [[], ["hist-one"], ["hist-two"], [],
                               ["hist-one", "hist-two"],
                               [stateLine(paneID: paneID)], []])

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
        let text = (String(bytes: replay, encoding: .utf8) ?? "")
        #expect(text.hasPrefix(ReplayWriter.resetPrelude))
        #expect(text.contains("hist-one\r\nhist-two"))
        #expect(text.hasSuffix("\u{1b}[2;3H"))
        #expect(!text.contains("MID-SEQUENCE"))

        // Output routed AFTER the gate opened lands behind the replay.
        supervisor.fanout.route(
            server: server, event: .output(paneID: paneID, bytes: Data("live-after".utf8)))
        #expect((String(bytes: drain(readFD), encoding: .utf8) ?? "") == "live-after")
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

        await succeed(client, [[], ["hist"], [], [], ["hist"],
                               [stateLine(paneID: paneID)], []])
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

    @Test("a duplicate attach.ready for an already-acked generation sends ZERO commands (benign success)")
    func duplicateReadySameGenerationSendsNothing() async throws {
        let (supervisor, orchestrator, recorder, _) = makeHarness()
        let paneID = "%13"
        let (readFD, gen) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        // The first ready's sequence already owns the attach (acked; its
        // replay may still be in flight).
        #expect(await supervisor.acknowledgeAttach(
            server: server, paneID: paneID, expectedGeneration: gen)
            == .acknowledged(generation: gen))

        // A second ready for the SAME generation must not start a second
        // replay sequence into the same pipe: benign success, nothing sent.
        let outcome = try await orchestrator.performAttachReady(
            server: server, paneID: paneID, expectedGeneration: gen)
        #expect(outcome == .superseded)
        #expect(recorder.writes.isEmpty)
    }

    @Test("a capture %error fails the attach but the unpause is still sent")
    func captureErrorFailsAttachUnpauseStillSent() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%3"
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }

        // pause OK, scrollback capture returns %error (tolerated at the
        // correlator level so the connection survives), rest succeed
        // (screen, saved, combined, state, pending).
        await client.handle(.commandSucceeded(number: 0, fromClient: true, lines: []))
        await client.handle(.commandFailed(number: 0, fromClient: true, lines: ["no such pane"]))
        await succeed(client, [[], [], [], [stateLine(paneID: paneID)], []])

        let underlying = await expectFailure(generation: generation) { try await task.value }
        #expect(underlying as? AttachReplayError == .captureFailed(
            command: "capture-pane -peqJN -S -50000 -E -1 -q -t %3"))
        #expect(await supervisor.isReady(server: server, paneID: paneID) == false)
        try await waitFor("unpause write") { recorder.writes.count >= 2 }
        #expect(recorder.writes.last == "refresh-client -A '%3:continue'")
    }

    @Test("a STALE sequence's capture failure sends NO unpause once a successor owns the pane (R11)")
    func staleCaptureFailureSkipsUnpause() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%9"
        let (readFD, generation) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }

        // While gen-1's batch is in flight, a fast re-attach replaces the
        // sink (gen 2). Gen-1's batch then fails with a real capture %error.
        let (successorFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(successorFD) }
        await client.handle(.commandSucceeded(number: 0, fromClient: true, lines: []))   // pause
        await client.handle(.commandFailed(number: 0, fromClient: true, lines: ["gone"]))
        await succeed(client, [[], [], [], [stateLine(paneID: paneID)], []])

        let underlying = await expectFailure(generation: generation) { try await task.value }
        #expect(underlying is AttachReplayError)
        // The stale catch path must NOT unpause: its continue could land
        // between the successor's pause and captures, tearing the successor's
        // capture. The successor's own sequence owns the pane's pause state.
        try await Task.sleep(for: .milliseconds(200))   // bounded negative check
        #expect(!recorder.writes.contains { $0.hasSuffix(":continue'") },
                "stale sequence unpaused a pane a successor now owns")
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
        await succeed(client, [[], ["hist"], [], [], ["hist"],
                               [stateLine(paneID: paneID)], ["bad\\9x"]])

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
            // The injected depth reaches the scrollback capture command too.
            #expect(recorder.writes.first?.contains("capture-pane -peqJN -S -3 -E -1 -q -t %9") == true)

            let history = (0..<lineCount).map { "line-\($0)" }
            // Telemetry keys on the PURE-scrollback leg (index 1), not the
            // combined one — the combined leg always carries screen rows too.
            await succeed(client, [[], history, ["screen"], [],
                                   history + ["screen"],
                                   [stateLine(paneID: paneID, historySize: lineCount)], []])
            let outcome = try await task.value
            #expect(outcome == .ready)
            #expect(truncations.counts == (expectFire ? [lineCount] : []),
                    "depth 3, \(lineCount) lines")
            _ = drain(readFD)
        }
    }

    @Test("history_size == 0 discards the scrollback leg (clamping quirk: it returns a screen row)")
    func historyLegDiscardedWhenHistorySizeZero() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%12"
        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }
        // QUIRK (live-probed, tmux 3.6a): on a pane with history_size == 0
        // the `-S -N -E -1` leg does NOT return empty — it clamps and returns
        // the first visible screen row. Feeding that duplicate here must NOT
        // reach the replay when the state says the scrollback is empty. The
        // COMBINED leg has no such quirk: with no history it is exactly the
        // screen, and the non-alt path uses it verbatim (R8-M3).
        await succeed(client, [[], ["screen-row-one"], ["screen-row-one", "screen-row-two"], [],
                               ["screen-row-one", "screen-row-two"],
                               [stateLine(paneID: paneID, historySize: 0)], []])

        let outcome = try await task.value
        #expect(outcome == .ready)
        let text = (String(bytes: drain(readFD), encoding: .utf8) ?? "")
        #expect(text.contains("screen-row-one\r\nscreen-row-two"))
        // Exactly ONE paint of the clamped row — the discarded leg's copy is gone.
        #expect(text.components(separatedBy: "screen-row-one").count == 2,
                "history-less pane painted the clamped scrollback leg twice")
    }

    @Test("non-alt replay is byte-identical to the legacy single -S capture (scrollback+screen concat)")
    func nonAltReplayByteIdenticalToLegacyConcatenation() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%13"
        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }
        let scrollback = ["h1", "h2"]
        let screen = ["s1", "s2"]
        // The combined leg is what one tmux invocation would return for this
        // pane: the scrollback rows followed by the screen rows — the exact
        // legacy single-capture content.
        await succeed(client, [[], scrollback, screen, [],
                               scrollback + screen,
                               [stateLine(paneID: paneID, historySize: 2)], []])
        let outcome = try await task.value
        #expect(outcome == .ready)

        // The old single `-S -N` capture returned scrollback rows followed by
        // screen rows in one leg; the non-alt assembly (combined leg
        // verbatim, R8-M3) must produce the exact same bytes.
        let state = try #require(try PaneStateCapture.state(
            forPane: paneID, in: [stateLine(paneID: paneID, historySize: 2)]))
        let legacy = try ReplayWriter.assemble(
            history: scrollback + screen, altScreen: nil, pending: [],
            state: state, cols: state.width, rows: state.height)
        #expect(drain(readFD) == legacy,
                "three-leg reassembly diverged from the legacy single-capture bytes")
    }

    @Test("non-alt: a soft wrap across the history/screen seam stays joined via the combined leg (R8-M3)")
    func nonAltSeamSoftWrapStaysJoined() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%17"
        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }
        // The batch carries a COMBINED history+screen capture (one tmux
        // invocation, `-J` joins the seam) as its fourth capture leg.
        let batch = try #require(recorder.writes.first)
        #expect(batch.contains("capture-pane -peqJN -S -50000 -t %17"))

        // A logical line soft-wraps across the scrollback/screen seam: the
        // split legs each see half ("WRAP-HEAD" / "WRAP-TAIL"), so joining
        // them with \r\n would insert a spurious hard break. The combined
        // leg — joined by tmux itself — carries the whole line.
        await succeed(client, [
            [],                              // pause
            ["above", "WRAP-HEAD"],          // pure scrollback (seam-cut)
            ["WRAP-TAIL", "below"],          // current screen (seam-cut)
            [],                              // saved primary (not alt)
            ["above", "WRAP-HEADWRAP-TAIL", "below"],  // combined, tmux-joined
            [stateLine(paneID: paneID, historySize: 2)],
            [],                              // pending
        ])
        let outcome = try await task.value
        #expect(outcome == .ready)

        let text = (String(bytes: drain(readFD), encoding: .utf8) ?? "")
        #expect(text.contains("above\r\nWRAP-HEADWRAP-TAIL\r\nbelow"),
                "the seam-wrapped line must arrive joined (combined leg verbatim)")
        #expect(!text.contains("WRAP-HEAD\r\nWRAP-TAIL"),
                "the split legs' seam-cut halves must not reach a non-alt replay")
    }

    @Test("alt pane: scrollback + saved primary paint the primary screen; current screen paints the alt")
    func altPaneThreeLegMapping() async throws {
        let (supervisor, orchestrator, recorder, client) = makeHarness()
        let paneID = "%14"
        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }
        // While alternate_on: historyLeg reaches the PRIMARY scrollback,
        // screenLeg returns the ALT content, savedLeg the saved primary
        // viewport (the H1 regression: historyLeg used to be dropped). The
        // combined leg is fed a marker line to prove the ALT branch ignores
        // it — it only reaches non-alt replays (R8-M3).
        await succeed(client, [[], ["OLD-SCROLLBACK"], ["ALT-NOW"], ["SAVED-VIEWPORT"],
                               ["COMBINED-UNUSED"],
                               [altStateLine(paneID: paneID)], []])
        let outcome = try await task.value
        #expect(outcome == .ready)

        let text = (String(bytes: drain(readFD), encoding: .utf8) ?? "")
        let altOn = try #require(text.range(of: "\u{1b}[?1049h"))
        let scrollbackRange = try #require(text.range(of: "OLD-SCROLLBACK"),
                                           "primary scrollback lost on an alt-screen attach (H1)")
        let savedRange = try #require(text.range(of: "SAVED-VIEWPORT"))
        let altRange = try #require(text.range(of: "ALT-NOW"))
        // Primary paint (scrollback then saved viewport) precedes 1049h; the
        // alt content follows it.
        #expect(scrollbackRange.upperBound <= savedRange.lowerBound)
        #expect(savedRange.upperBound <= altOn.lowerBound)
        #expect(altOn.upperBound <= altRange.lowerBound)
        // The primary rows are contiguous lines (scrollback \r\n viewport).
        #expect(text.contains("OLD-SCROLLBACK\r\nSAVED-VIEWPORT"))
        // The combined leg must not leak into an alt-screen replay.
        #expect(!text.contains("COMBINED-UNUSED"))
    }

    @Test("pause %error is surfaced but the replay still runs and the gate opens (review M4)")
    func pauseFailureSurfacedReplayProceeds() async throws {
        let failures = Recorder()
        let (supervisor, orchestrator, recorder, client) = makeHarness(
            onPauseFailure: { failures.record($0) })
        let paneID = "%15"
        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }

        // The PAUSE fails; every capture succeeds. The captures therefore ran
        // UNPAUSED — a possibly-torn replay that self-heals — so the sequence
        // must proceed to a ready gate, and the failure must be surfaced.
        await client.handle(.commandFailed(number: 0, fromClient: true, lines: ["bad refresh-client"]))
        await succeed(client, [["hist"], ["screen"], [], ["hist", "screen"],
                               [stateLine(paneID: paneID)], []])

        let outcome = try await task.value
        #expect(outcome == .ready)
        #expect(await supervisor.isReady(server: server, paneID: paneID) == true)
        #expect(failures.writes.count == 1, "the failed pause must be surfaced, not discarded")
        // The replay landed despite the failed pause.
        let text = (String(bytes: drain(readFD), encoding: .utf8) ?? "")
        #expect(text.contains("hist\r\nscreen"))
    }

    @Test("a successful pause does not trip the pause-failure hook")
    func pauseSuccessDoesNotFireHook() async throws {
        let failures = Recorder()
        let (supervisor, orchestrator, recorder, client) = makeHarness(
            onPauseFailure: { failures.record($0) })
        let paneID = "%16"
        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let task = Task { try await orchestrator.performAttachReady(server: server, paneID: paneID) }
        try await waitFor("capture batch write") { recorder.writes.count >= 1 }
        await succeed(client, [[], ["hist"], ["screen"], [], ["hist", "screen"],
                               [stateLine(paneID: paneID)], []])
        let outcome = try await task.value
        #expect(outcome == .ready)
        #expect(failures.writes.isEmpty)
        _ = drain(readFD)
    }

    @Test("stale task parked at the provider hop sends ZERO commands once a successor's FULL sequence completed (R10-3)")
    func staleTaskParkedAtProviderHopSendsNothing() async throws {
        let gate = ProviderGate()
        let recorder = Recorder()
        let client = TmuxControlCommandClient(
            writeLine: { recorder.record($0) },
            onFatalError: {})
        let supervisor = TmuxControlSupervisor()
        let orchestrator = AttachReplayOrchestrator(
            supervisor: supervisor,
            commandProvider: { [server] requested in
                guard requested == server else { return nil }
                await gate.parkIfFirstCall()
                return client
            })
        let paneID = "%18"
        let (read1, gen1) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read1) }

        // The stale sequence acknowledges gen1, then is preempted at the
        // `await commandProvider(server)` hop (parked in the gate).
        let staleDone = Recorder()
        let staleTask = Task { () throws -> AttachReplayOrchestrator.Outcome in
            defer { staleDone.record("done") }
            return try await orchestrator.performAttachReady(
                server: server, paneID: paneID, expectedGeneration: gen1)
        }
        try await waitFor("stale task parked at the provider hop") { gate.hasParkedCaller }

        // A successor attaches and runs its ENTIRE pause → captures → replay
        // → unpause sequence to completion while the stale task is parked.
        let (read2, gen2) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(read2) }
        let successorTask = Task {
            try await orchestrator.performAttachReady(
                server: server, paneID: paneID, expectedGeneration: gen2)
        }
        try await waitFor("successor batch write") { recorder.writes.count >= 1 }
        await succeed(client, [[], ["hist"], ["screen"], [], ["hist", "screen"],
                               [stateLine(paneID: paneID)], []])
        #expect(try await successorTask.value == .ready)
        try await waitFor("successor unpause write") { recorder.writes.count >= 2 }
        #expect(await supervisor.isReady(server: server, paneID: paneID) == true)

        // Release the stale task. Its pause landing NOW would re-freeze the
        // live pane with nothing left to unpause it (the supersession rule
        // skips ITS unpause, and the successor's already ran) — the post-hop
        // re-check must return .superseded having sent NOTHING.
        gate.release()
        try await waitFor("stale sequence resolution") {
            staleDone.writes.count == 1 || recorder.writes.count > 2
        }
        if recorder.writes.count > 2 {
            // Regression path only: the stale batch WAS sent — feed its
            // replies so the test fails on the assertions below instead of
            // hanging on `staleTask.value`.
            await succeed(client, [[], [], [], [], [],
                                   [stateLine(paneID: paneID)], []])
        }
        #expect(try await staleTask.value == .superseded)
        // Exactly the successor's writes: one batch + one unpause. The stale
        // task contributed ZERO commands — in particular no second pause.
        #expect(recorder.writes.count == 2)
        #expect(recorder.writes.filter { $0.contains(":pause'") }.count == 1)
        #expect(await supervisor.isReady(server: server, paneID: paneID) == true)
        _ = drain(read2)
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
        await succeed(client, [[], ["hist"], [], [], ["hist"],
                               [stateLine(paneID: "%99")], []])

        let underlying = await expectFailure(generation: generation) { try await task.value }
        #expect(underlying as? AttachReplayError == .paneStateMissing)
        try await waitFor("unpause write") { recorder.writes.count >= 2 }
        #expect(recorder.writes.last == "refresh-client -A '%10:continue'")
    }
}
