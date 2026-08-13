import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// The M4 live-tmux integration matrix for the attach replay (addendum §3):
/// four scenarios, each through the FULL production path — supervisor `-CC`
/// attach → fd vend → `AttachReplayOrchestrator.performAttachReady` (pause →
/// capture → replay → gate → unpause) → bytes read off the vended pipe.
///
///  1. Scrollback + SGR: known colored lines scrolled into history replay in
///     order with their SGR sequences, CUP-terminated.
///  2. Alt-screen pane: 1049h + alt content in the replay, prelude's 1049l
///     first (full-clear-first invariant), final CUP targets the alt cursor.
///  3. Fullscreen-Claude-shaped stub attached MID-STREAM: the replayed
///     snapshot shows a coherent frame and live output continues from a
///     counter >= the replayed one (replay/live boundary coherence).
///  4. Pending-output race: a monotonic SEQ counter emitting across the
///     attach; history capture + fence flush + live must yield every token
///     EXACTLY ONCE, in order, with a seam gap of ZERO — the Phase B M2
///     fence (pause → arm fence → atomic captures+continue → replay →
///     markReady flush) closes the boundary gap the M4-era matrix had to
///     accept (see the scenario's comment for the probe facts).
///
/// Boundary detection: the replay's final cursor escape is always a
/// PARAMETERIZED CUP (`ESC[<row>;<col>H`, digits — `ReplayWriter.cup`), while
/// the stubs in 3/4 emit only `ESC[H` / `ESC[2K` / plain text. The LAST
/// digit-CUP in the accumulated stream therefore marks the end of the replay;
/// everything after it is live output.
///
/// Token extraction strips CSI escapes first: a token legitimately split
/// between the history capture's tail and the first live bytes has the mode
/// escapes + final CUP interposed — stripping rejoins a cleanly-split token
/// while genuine loss/duplication still surfaces as a sequence violation.
///
/// Live-test discipline (hard-won): unique `-L tbd-replay-<uuid8>` socket per
/// test, rc-free `/bin/sh -c` bootstraps ONLY, 15 s poll deadlines, `defer`
/// kill-server, tolerate parallel-suite load.
@Suite("Replay live integration matrix")
struct ReplayLiveIntegrationMatrixTests {

    // MARK: - tmux CLI harness (same shape as the M4.3 live smoke)

    @discardableResult
    private func tmux(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func tmuxCapture(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Skip guard: nil when tmux is missing or below the control-mode floor.
    private func controlModeTmuxAvailable() async -> Bool {
        guard let version = await TmuxVersion.detect() else { return false }
        return version >= TmuxVersion.controlModeMinimum
    }

    /// Bootstrap a fresh server + one rc-free `/bin/sh -c` pane, returning the
    /// pane id. `extraServerArgs` are chained BEFORE `new-session` in the same
    /// tmux invocation (the TmuxManager trick — e.g. history-limit must be set
    /// before the first pane exists).
    private func bootstrap(server: String, script: String,
                           extraServerArgs: [String] = []) throws -> String {
        var args = ["-L", server] + extraServerArgs
        args += ["new-session", "-d", "-s", "main", "-x", "80", "-y", "24",
                 "/bin/sh", "-c", script]
        try #require(tmux(args), "failed to bootstrap tmux session on \(server)")
        return try #require(
            tmuxCapture(["-L", server, "display-message", "-t", "main", "-p", "#{pane_id}"]),
            "could not resolve pane id")
    }

    /// Poll `condition` under the standard 15 s deadline.
    private func poll(_ what: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MatrixError.pollDeadline(what)
    }

    private func awaitClient(_ supervisor: TmuxControlSupervisor,
                             server: String) async throws -> TmuxControlCommandClient {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let client = await supervisor.command(server: server) { return client }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MatrixError.clientNeverReady
    }

    /// Wait — WITHOUT reading the pane's pipe — until its sink has provably
    /// overflowed and entered the M3 repair cycle.
    ///
    /// `repairing` is the entry signal and `repairs` the completion signal; both
    /// are accepted so a repair that somehow completed between two polls does not
    /// look like one that never started. Note that `overflowEvents` is NOT an
    /// entry signal: `enqueueLocked` increments it only on the fenced /
    /// already-repairing DROP branch, so on the steady-state path the counter
    /// stays at zero while the repair runs. It is reported in the diagnostic
    /// precisely because a non-zero value there means the overflow was seen and
    /// dropped rather than repaired.
    ///
    /// **The completion signal is a DELTA against `baseline`, never an absolute
    /// count — that distinction is the difference between this test proving
    /// something and passing vacuously.** `repairs` is cumulative on the sink,
    /// and the phases before this window read the pipe against a full-blast pane
    /// for up to 30 s; a sink that overflowed and completed a repair in *that*
    /// window would satisfy an absolute `repairs >= 1` on this gate's very first
    /// poll. The deliberate no-reader window would then close instantly without
    /// inducing anything, and phase 3's guard and assertions — cumulative too —
    /// would be satisfied by that same stale repair, so the whole scenario could
    /// go green having never exercised an overflow. `repairing` needs no delta:
    /// `enqueueLocked` is the only thing that sets it, and only on an overflow
    /// entry, so it cannot be a stale free lunch the way a counter can. It is
    /// still cleared on completion, which is why the completion delta is checked
    /// alongside it rather than instead of it.
    ///
    /// On expiry it RETURNS the error rather than throwing it, and the caller
    /// throws only after tearing the supervisor down. That is not ceremony: on
    /// expiry the pane is still blasting into the vended pipe, so unwinding
    /// straight past the test's `defer { Darwin.close(readFD) }` makes the next
    /// fanout write raise SIGPIPE and kill the whole test process. Measured — an
    /// early throw reported `error: Exited with unexpected signal code 13` and no
    /// diagnostic at all. An error is only worth composing if it survives to be
    /// read.
    ///
    /// It is an error rather than an `#expect` for the other half of the same
    /// reason: only a thrown error puts the observed counters on the primary
    /// failure line CI summaries keep (`Tests/CLAUDE.md`, assertion-hygiene rule
    /// 4). The message separates "the firehose never filled the queue" (a harness
    /// problem — the test's own setup did not hold) from "it overflowed and no
    /// repair started" (a production problem), which the previous fixed sleep
    /// collapsed into a misleading `(stats.repairs → 0) >= 1`.
    private func overflowRepairEntryFailure(
        fanout: PaneFanout, key: PaneKey, baseline: PaneFlowStats,
        within budget: Duration = .seconds(30)
    ) async -> MatrixError? {
        let deadline = ContinuousClock.now + budget
        while true {
            let stats = fanout.flowStats(key: key)
            if stats?.repairing == true { return nil }
            if let stats, stats.repairs > baseline.repairs { return nil }
            guard ContinuousClock.now < deadline else {
                return .overflowRepairNeverEntered(
                    stats: stats, baseline: baseline, queueCap: PaneFanout.queueCap,
                    waited: budget)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Vended-fd reading

    private func makeNonblocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Read `fd` (nonblocking) until `condition` holds on the accumulated
    /// bytes, EOF, cancellation, or the deadline. Bursts drain without
    /// waiting; when nothing is ready the read loop parks in `poll(2)`.
    ///
    /// The read loop runs on a DEDICATED `Thread`, not on the Swift
    /// Concurrency cooperative pool, and that placement is load-bearing.
    /// The pane's replay write (attach via `AttachReplayOrchestrator`,
    /// repair via `PaneRepairCoordinator`) runs a synchronous, wall-clock
    /// 5 s-deadlined `poll`/`write` against the ~64 KB vended pipe; if this
    /// reader stalls the pipe stays full and the producer blows its
    /// deadline with `PaneReplayWriteError.deadlineExceeded`. An earlier
    /// version drained on the cooperative executor and yielded on EAGAIN
    /// via `Task.sleep`; under CI CPU oversubscription the executor was
    /// saturated, this reader Task wasn't scheduled promptly, the pipe
    /// overflowed, and the producer's deadline fired — a pure test-harness
    /// flake (the `firehoseOverflowRepairHeals` scenario went red with
    /// `deadlineExceeded`). In production the reader is a real client, and
    /// a genuinely stalled reader SHOULD surface as backpressure, so the
    /// fix belongs here, not in the producer. A dedicated thread is immune
    /// to executor starvation: the kernel schedules it independently of
    /// the concurrency runtime. `withCheckedContinuation` bridges the
    /// blocking loop back to this `async` signature so no caller changes.
    /// Cancellation is honoured cooperatively (a stop flag flipped from the
    /// task-cancellation handler) and, as a backstop, strictly bounded by
    /// `deadline`.
    private func drain(fd: Int32, deadline: Duration = .seconds(15),
                       until condition: @escaping @Sendable (Data) -> Bool) async -> Data {
        let stop = FlagBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                let thread = Thread {
                    var accumulated = Data()
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    let end = ContinuousClock.now + deadline
                    while ContinuousClock.now < end && !stop.get() {
                        // Park up to a 50 ms slice waiting for readable bytes
                        // so the loop neither busy-spins nor oversleeps the
                        // deadline. fd is already nonblocking (see caller).
                        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        _ = withUnsafeMutablePointer(to: &pfd) { Darwin.poll($0, 1, 50) }

                        let n = buffer.withUnsafeMutableBytes {
                            Darwin.read(fd, $0.baseAddress, $0.count)
                        }
                        if n > 0 {
                            accumulated.append(contentsOf: buffer[0..<n])
                            if condition(accumulated) { break }
                        } else if n == 0 {
                            break  // EOF — write end closed
                        }
                        // n < 0: EAGAIN — the poll above already waited; loop
                        // and re-check the deadline.
                    }
                    continuation.resume(returning: accumulated)
                }
                thread.name = "replay-drain"
                thread.stackSize = 512 * 1024
                thread.start()
            }
        } onCancel: {
            stop.set()
        }
    }

    // MARK: - Byte-stream analysis helpers

    /// True when `text` ends with a parameterized CUP `ESC [ <row> ; <col> H`.
    private func endsWithCUP(_ text: String) -> Bool {
        text.range(of: "\u{1b}\\[[0-9]+;[0-9]+H$", options: .regularExpression) != nil
    }

    /// The LAST parameterized CUP in `text` — the replay/live boundary for
    /// stubs that never emit digit-CUPs themselves (see the suite doc).
    private func rangeOfLastDigitCUP(in text: String) -> Range<String.Index>? {
        var result: Range<String.Index>?
        var search = text.startIndex
        while let match = text.range(of: "\u{1b}\\[[0-9]+;[0-9]+H",
                                     options: .regularExpression,
                                     range: search..<text.endIndex) {
            result = match
            search = match.upperBound
        }
        return result
    }

    /// Remove CSI sequences (incl. private-mode `?` params) and the two
    /// keypad escapes (`ESC =` / `ESC >`) the replay synthesizes. Incomplete
    /// trailing escapes (the pending-capture residual) are left as-is.
    private func strippingEscapes(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1b}\\[[0-9;?]*[A-Za-z]|\u{1b}[=>]",
            with: "", options: .regularExpression)
    }

    /// All `<label> <7 digits>` tokens in order. Fixed-width zero-padded
    /// tokens make truncation detectable: a partial token simply fails to
    /// match instead of parsing as a smaller number.
    private func tokens(in text: String, label: String) -> [Int] {
        var values: [Int] = []
        var search = text.startIndex
        while let match = text.range(of: "\(label) [0-9]{7}",
                                     options: .regularExpression,
                                     range: search..<text.endIndex) {
            values.append(Int(text[match].suffix(7)) ?? -1)
            search = match.upperBound
        }
        return values
    }

    /// Human-readable descriptions of every place `values` fails to step by
    /// exactly +1 (a dup is a 0-step, a gap is a >1 step, disorder is
    /// negative). Empty means gapless and duplicate-free.
    private func sequenceViolations(_ values: [Int]) -> [String] {
        var violations: [String] = []
        for index in 1..<max(values.count, 1) {
            let previous = values[index - 1]
            let next = values[index]
            if next != previous + 1 {
                let kind = next == previous ? "DUPLICATE" : (next < previous ? "DISORDER" : "GAP")
                violations.append("\(kind) at #\(index): \(previous) -> \(next)")
            }
        }
        return violations
    }

    /// Bytes (debug-escaped) around `range` in `text`, for loud findings.
    private func context(_ text: String, around range: Range<String.Index>,
                         radius: Int = 240) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -radius,
                               limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: radius,
                               limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lower..<upper]).debugDescription
    }

    // MARK: - Scenario 1: scrollback + SGR

    @Test("scrollback with SGR colors replays in order with escapes, CUP-terminated")
    func scrollbackWithSGR() async throws {
        guard await controlModeTmuxAvailable() else { return }
        let server = "tbd-replay-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        // 30 red lines on a 24-row pane: lines 001–006 scroll into history,
        // so their presence in the replay proves the history capture leg.
        let script = "i=1; while [ $i -le 30 ]; do printf '\\033[31mm4red-%03d\\033[0m\\n' $i; "
            + "i=$((i+1)); done; sleep 60"
        let paneID = try bootstrap(server: server, script: script)
        try await poll("pane painted last red line") {
            tmuxCapture(["-L", server, "capture-pane", "-p", "-t", paneID])?
                .contains("m4red-030") == true
        }

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        _ = try await awaitClient(supervisor, server: server)

        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        makeNonblocking(readFD)
        let orchestrator = AttachReplayOrchestrator(
            supervisor: supervisor,
            commandProvider: { [supervisor] in await supervisor.command(server: $0) })
        let outcome = try await orchestrator.performAttachReady(server: server, paneID: paneID)
        #expect(outcome == .ready)

        // The pane is quiescent (sleep 60): the pre-live prefix IS the replay.
        let replay = await drain(fd: readFD) { [self] in
            endsWithCUP(String(decoding: $0, as: UTF8.self))
        }
        let text = String(decoding: replay, as: UTF8.self)

        #expect(text.hasPrefix(ReplayWriter.resetPrelude), "replay must start with the reset prelude")
        #expect(endsWithCUP(text), "replay must end with a CUP; tail \(text.suffix(24).debugDescription)")

        // SGR survives the capture: a red (SGR 31) sequence appears, and
        // before the first line's text.
        let sgrRange = text.range(of: "\u{1b}\\[[0-9;]*31m", options: .regularExpression)
        let firstLine = text.range(of: "m4red-001")
        #expect(sgrRange != nil, "replay lost the SGR 31 sequences")
        #expect(firstLine != nil, "replay missing the first (scrolled-out) line")
        if let sgrRange, let firstLine {
            #expect(sgrRange.lowerBound < firstLine.lowerBound,
                    "SGR must precede the text it colors")
        }

        // Every line present, in emission order (001–006 live only in history).
        var cursor = text.startIndex
        for lineNumber in 1...30 {
            let needle = String(format: "m4red-%03d", lineNumber)
            let found = text.range(of: needle, range: cursor..<text.endIndex)
            #expect(found != nil, "replay missing or out-of-order line \(needle)")
            guard let found else { break }
            cursor = found.upperBound
        }

        await supervisor.stopAll()
    }

    // MARK: - Scenario 2: alt-screen pane

    @Test("alt-screen pane replays 1049h + content, full-clear-first, primary SCROLLBACK preserved, CUP at alt cursor")
    func altScreenPane() async throws {
        guard await controlModeTmuxAvailable() else { return }
        let server = "tbd-replay-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        // MORE primary lines than the pane is tall (40 on a 24-row pane)
        // BEFORE entering the alt screen: the early lines scroll into the
        // primary HISTORY, which the `-a` saved-viewport leg alone cannot
        // reach — replaying every one of them proves the dedicated
        // scrollback leg (`-S -N -E -1`, review H1). The loop lives in a
        // temp SCRIPT FILE, not an inline `sh -c` body: `$i` does not
        // survive the layered quoting contexts reliably (live-test
        // discipline).
        let primaryLineCount = 40
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-replay-alt-\(UUID().uuidString.prefix(8)).sh")
        let scriptBody = """
            i=1
            while [ $i -le \(primaryLineCount) ]; do
              printf 'PRIMARY-M4-%03d\\n' $i
              i=$((i+1))
            done
            printf '\\033[?1049h\\033[2J\\033[HALT-M4-CONTENT one'
            sleep 60
            """
        try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let paneID = try bootstrap(server: server, script: "/bin/sh '\(scriptURL.path)'")
        try await poll("pane entered alt screen with content") {
            tmuxCapture(["-L", server, "display-message", "-t", "main", "-p",
                         "#{alternate_on}"]) == "1"
                && tmuxCapture(["-L", server, "capture-pane", "-p", "-t", paneID])?
                    .contains("ALT-M4-CONTENT") == true
        }
        // The pane is static — the cursor tmux reports now is what the replay's
        // final CUP must target (alt-screen coordinates).
        let cursorFields = try #require(
            tmuxCapture(["-L", server, "display-message", "-t", "main", "-p",
                         "#{cursor_x} #{cursor_y}"])).split(separator: " ")
        let cursorX = try #require(Int(cursorFields[0]))
        let cursorY = try #require(Int(cursorFields[1]))

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        _ = try await awaitClient(supervisor, server: server)

        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        makeNonblocking(readFD)
        let orchestrator = AttachReplayOrchestrator(
            supervisor: supervisor,
            commandProvider: { [supervisor] in await supervisor.command(server: $0) })
        let outcome = try await orchestrator.performAttachReady(server: server, paneID: paneID)
        #expect(outcome == .ready)

        let replay = await drain(fd: readFD) { [self] in
            endsWithCUP(String(decoding: $0, as: UTF8.self))
        }
        let text = String(decoding: replay, as: UTF8.self)

        let altOn = text.range(of: "\u{1b}[?1049h")
        let altOff = text.range(of: "\u{1b}[?1049l")
        #expect(altOn != nil, "replay must enter the alt screen (1049h)")
        #expect(altOff != nil, "prelude must exit the alt screen first (1049l)")
        if let altOn, let altOff {
            #expect(altOff.lowerBound < altOn.lowerBound,
                    "full-clear-first: the prelude's 1049l must precede the replay's 1049h")
        }

        let content = text.range(of: "ALT-M4-CONTENT one")
        #expect(content != nil, "replay missing the alt-screen content")
        if let altOn, let content {
            #expect(altOn.upperBound <= content.lowerBound,
                    "alt content must be painted after entering the alt screen")
        }
        // EVERY primary line — including the ones that scrolled out of the
        // saved viewport into the primary HISTORY — must be replayed, in
        // order, before the 1049h switch (the H1 regression: the old
        // two-leg capture dropped the scrollback entirely for alt panes).
        var cursor = text.startIndex
        for lineNumber in 1...primaryLineCount {
            let needle = String(format: "PRIMARY-M4-%03d", lineNumber)
            let found = text.range(of: needle, range: cursor..<text.endIndex)
            #expect(found != nil, "replay missing or out-of-order primary line \(needle)")
            guard let found else { break }
            cursor = found.upperBound
        }
        if let altOn {
            #expect(cursor <= altOn.lowerBound,
                    "primary content (scrollback + viewport) must be painted before entering the alt screen")
        }

        // Cursor-last invariant, and it must target the ALT screen's cursor.
        let expectedCUP = "\u{1b}[\(cursorY + 1);\(cursorX + 1)H"
        let cupTail = text.suffix(24).debugDescription
        #expect(text.hasSuffix(expectedCUP),
                "final CUP must target the alt cursor \(expectedCUP.debugDescription); tail \(cupTail)")

        await supervisor.stopAll()
    }

    // MARK: - Scenario 3: fullscreen-Claude-shaped stub, mid-stream attach

    @Test("fullscreen stub attached mid-stream: coherent frame, live continues from >= replayed count")
    func fullscreenStubMidStreamAttach() async throws {
        guard await controlModeTmuxAvailable() else { return }
        let server = "tbd-replay-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        // Alt screen + differential repaints (cursor home + overwrite), the
        // fullscreen-Claude shape. Zero-padded so truncated tokens never
        // parse as smaller numbers. The stub emits NO digit-CUPs (only
        // ESC[H / ESC[2K), so the last digit-CUP marks the replay boundary.
        let script = "printf '\\033[?1049h'; i=0; while :; do "
            + "printf '\\033[H\\033[2KCOUNT %07d ' $i; i=$((i+1)); sleep 0.05; done"
        let paneID = try bootstrap(server: server, script: script)
        try await poll("stub repainting on the alt screen") {
            tmuxCapture(["-L", server, "display-message", "-t", "main", "-p",
                         "#{alternate_on}"]) == "1"
                && tmuxCapture(["-L", server, "capture-pane", "-p", "-t", paneID])?
                    .contains("COUNT ") == true
        }

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        _ = try await awaitClient(supervisor, server: server)

        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        makeNonblocking(readFD)
        let orchestrator = AttachReplayOrchestrator(
            supervisor: supervisor,
            commandProvider: { [supervisor] in await supervisor.command(server: $0) })

        // Reader runs CONCURRENTLY with the attach sequence (as the app does):
        // stop once >= 3 full tokens have arrived past the replay boundary.
        async let collected = drain(fd: readFD) { [self] data in
            let text = String(decoding: data, as: UTF8.self)
            guard let boundary = rangeOfLastDigitCUP(in: text) else { return false }
            let live = strippingEscapes(String(text[boundary.upperBound...]))
            return tokens(in: live, label: "COUNT").count >= 3
        }
        let outcome = try await orchestrator.performAttachReady(server: server, paneID: paneID)
        #expect(outcome == .ready)
        let text = String(decoding: await collected, as: UTF8.self)

        let boundary = try #require(rangeOfLastDigitCUP(in: text),
                                    "replay never produced its final digit-CUP")
        let replayPart = String(text[..<boundary.upperBound])
        let livePart = String(text[boundary.upperBound...])

        // Replay: full-clear-first, alt screen entered, coherent frame.
        let altOn = replayPart.range(of: "\u{1b}[?1049h")
        let altOff = replayPart.range(of: "\u{1b}[?1049l")
        #expect(altOn != nil, "replay must enter the alt screen")
        if let altOn, let altOff {
            #expect(altOff.lowerBound < altOn.lowerBound, "prelude 1049l must precede 1049h")
        }
        let boundaryBytes = context(text, around: boundary)
        let replayTokens = tokens(in: strippingEscapes(replayPart), label: "COUNT")
        #expect(!replayTokens.isEmpty,
                "replayed snapshot must show a coherent COUNT frame; boundary \(boundaryBytes)")

        // Live: continues, monotonically, from >= the replayed frame.
        let liveTokens = tokens(in: strippingEscapes(livePart), label: "COUNT")
        #expect(liveTokens.count >= 3, "live output never continued after the replay")
        let liveViolations = sequenceViolations(liveTokens).joined(separator: "; ")
        #expect(liveViolations.isEmpty,
                "live counter not monotonic: \(liveViolations) — boundary bytes \(boundaryBytes)")
        if let maxReplayed = replayTokens.max(), let firstLive = liveTokens.first {
            #expect(firstLive >= maxReplayed,
                    "live (first \(firstLive)) regressed behind the replayed frame (max \(maxReplayed)) — replay/live boundary incoherent; bytes \(boundaryBytes)")
        }

        await supervisor.stopAll()
    }

    // MARK: - Scenario 4: pending-output race — no loss, no duplication

    @Test("sequenced tokens: no dup/disorder/loss anywhere — the replay/live seam is exactly zero")
    func pendingOutputRace() async throws {
        guard await controlModeTmuxAvailable() else { return }
        let server = "tbd-replay-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        // Monotonic counter, lightly throttled (~30–80 lines/s effective).
        // history-limit 50000 is chained BEFORE new-session so NOTHING can be
        // lost to capture depth — every emitted token must be accounted for.
        let script = "i=0; while :; do printf 'SEQ %07d\\n' $i; i=$((i+1)); sleep 0.01; done"
        let paneID = try bootstrap(
            server: server, script: script,
            extraServerArgs: ["set-option", "-g", "history-limit", "50000", ";"])
        try await poll("counter emitting") {
            tmuxCapture(["-L", server, "capture-pane", "-p", "-t", paneID])?
                .contains("SEQ 00000") == true
        }

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        _ = try await awaitClient(supervisor, server: server)

        // Attach WHILE the counter is emitting — this is the race.
        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        makeNonblocking(readFD)
        let orchestrator = AttachReplayOrchestrator(
            supervisor: supervisor,
            commandProvider: { [supervisor] in await supervisor.command(server: $0) })

        // Continuous read across the boundary; stop after >= 15 live tokens.
        async let collected = drain(fd: readFD) { [self] data in
            let text = String(decoding: data, as: UTF8.self)
            guard let boundary = rangeOfLastDigitCUP(in: text) else { return false }
            let live = strippingEscapes(String(text[boundary.upperBound...]))
            return tokens(in: live, label: "SEQ").count >= 15
        }
        let outcome = try await orchestrator.performAttachReady(server: server, paneID: paneID)
        #expect(outcome == .ready)
        let text = String(decoding: await collected, as: UTF8.self)

        #expect(text.hasPrefix(ReplayWriter.resetPrelude), "replay must start with the reset prelude")
        let boundary = try #require(rangeOfLastDigitCUP(in: text),
                                    "replay never produced its final digit-CUP")
        let boundaryBytes = context(text, around: boundary)

        // M2 FENCE (Phase B): the boundary gap the M4-era matrix accepted
        // (3 -> 25 tokens lost under load) is CLOSED. Two probe-verified
        // facts (tmux 3.6a, 6/6 trials under throttle and firehose) carry
        // the design: (1) a paused pane delivers NOTHING — its output lands
        // in pane history, reachable via capture; (2) an atomic
        // [captures…, continue] command list has a seam gap of exactly
        // zero — the first live token delivered after the continue is
        // contiguous with the capture's last token. The orchestrator pauses
        // (awaited alone), arms a generation-scoped fence while the pane is
        // provably silent, sends captures + continue as ONE list, and
        // markReady flushes the fenced bytes right after the replay.
        //
        // This test therefore pins the STRICT zero-seam contract: nothing
        // duplicated, nothing reordered, no rewind, gapless within the
        // replay, gapless within the live stream, and the first live token
        // is EXACTLY lastReplayed + 1.
        let replayTokens = tokens(
            in: strippingEscapes(String(text[..<boundary.upperBound])), label: "SEQ")
        let liveTokens = tokens(
            in: strippingEscapes(String(text[boundary.upperBound...])), label: "SEQ")
        #expect(replayTokens.first == 0,
                "replay must start at token 0 — tokens lost to capture depth or a truncated capture")
        let replayViolations = sequenceViolations(replayTokens).joined(separator: "; ")
        #expect(replayViolations.isEmpty,
                "LOSS/DUP inside the replayed snapshot: \(replayViolations) — boundary bytes \(boundaryBytes)")
        #expect(liveTokens.count >= 15, "live output never continued after the replay")
        let liveViolations = sequenceViolations(liveTokens).joined(separator: "; ")
        #expect(liveViolations.isEmpty,
                "LOSS/DUP inside the live stream: \(liveViolations) — boundary bytes \(boundaryBytes)")
        if let lastReplayed = replayTokens.last, let firstLive = liveTokens.first {
            #expect(firstLive == lastReplayed + 1,
                    "SEAM violation at the replay/live boundary: replay ended at \(lastReplayed), live began at \(firstLive) — expected exactly \(lastReplayed + 1) (zero-loss fence, Phase B M2) — bytes \(boundaryBytes)")
        }

        await supervisor.stopAll()
    }

    // MARK: - Scenario 5: firehose overflow → pause+recapture repair (Phase B M3)

    /// Thread-safe done-flag for cross-task drain coordination.
    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("firehose overflow heals via the repair cycle: SEQ gapless and monotonic after the last reset prelude")
    func firehoseOverflowRepairHeals() async throws {
        guard await controlModeTmuxAvailable() else { return }
        let server = "tbd-repair-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }

        // FULL-BLAST monotonic counter — no throttle: during the deliberate
        // 2 s reader stall below the pane out-emits the unread pipe by far,
        // overflowing the ~64 KB pipe + 128 KB queue, which must enter the
        // M3 repair cycle (pause → wait for the reader → recapture + atomic
        // continue → replay → fence flush) instead of dropping.
        let script = "i=0; while :; do printf 'SEQ %07d\\n' $i; i=$((i+1)); done"
        let paneID = try bootstrap(
            server: server, script: script,
            extraServerArgs: ["set-option", "-g", "history-limit", "50000", ";"])
        try await poll("counter emitting") {
            // Full blast: the counter races past any fixed value before the
            // first capture — any SEQ token proves the firehose is live.
            tmuxCapture(["-L", server, "capture-pane", "-p", "-t", paneID])?
                .contains("SEQ ") == true
        }

        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        _ = try await awaitClient(supervisor, server: server)

        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }
        makeNonblocking(readFD)
        let provider: @Sendable (String) async -> TmuxControlCommandClient? =
            { [supervisor] in await supervisor.command(server: $0) }
        let orchestrator = AttachReplayOrchestrator(supervisor: supervisor, commandProvider: provider)
        // A REAL repair coordinator wired through onOverflowRepair exactly as
        // the bridge wires it at daemon startup.
        let coordinator = PaneRepairCoordinator(supervisor: supervisor, commandProvider: provider)
        supervisor.fanout.onOverflowRepair = { key, generation in
            Task { await coordinator.repairIfNeeded(key: key, generation: generation) }
        }

        // Phase 1: read concurrently while the attach runs (its replay write
        // needs the reader), until the attach outcome lands.
        let attachDone = FlagBox()
        async let phase1 = drain(fd: readFD, deadline: .seconds(30)) { _ in attachDone.get() }
        let outcome = try await orchestrator.performAttachReady(server: server, paneID: paneID)
        #expect(outcome == .ready)
        attachDone.set()
        var accumulated = await phase1

        // The baseline for everything below. Every "a repair happened" check in
        // this test is a DELTA against it — see `overflowRepairEntryFailure` for
        // why an absolute count is a vacuous pass here.
        let key = PaneKey(server: server, paneID: paneID)
        let fanout = supervisor.fanout
        guard let baseline = fanout.flowStats(key: key) else {
            // Stop the supervisor BEFORE unwinding: the pane is still blasting,
            // and the `defer` above closes the read end of the pipe it writes to.
            await supervisor.stopAll()
            throw MatrixError.sinkVanished("before the overflow window opened")
        }

        // Phase 2: deliberately do NOT read — the overflow window. The repair
        // fires, pauses the pane, and parks in its reader-catch-up wait until
        // phase 3 starts reading.
        //
        // The end of this window is an OBSERVED event, not a wall-clock guess.
        // Overflow is a byte threshold the test does not itself produce: the
        // queue only grows once the ~64 KB pipe fills and `route()` starts
        // taking EAGAIN, so ~192 KB has to arrive from the pane before
        // `enqueueLocked` crosses `PaneFanout.queueCap`. A fixed sleep makes
        // that a race against an external producer — this pane emits 700 KB–1 MB
        // per 2 s on an idle box, but a run that dragged 28x slower delivered
        // ~25–39 KB in the same window, never overflowed, and reddened
        // `stats.repairs >= 1` as though production had failed to repair. Waiting
        // for the stall itself makes the setup's postcondition true by
        // construction, so every assertion downstream is about the repair.
        if let failure = await overflowRepairEntryFailure(
            fanout: fanout, key: key, baseline: baseline) {
            // Stop the supervisor BEFORE unwinding: the pane is still blasting,
            // and the `defer` above closes the read end of the pipe it writes to.
            await supervisor.stopAll()
            throw failure
        }

        // Phase 3: read continuously until a repair completed AFTER the window
        // opened and the healed stream carries enough post-repair tokens to
        // judge. The delta is the same guard as the entry gate's, for the same
        // reason: `>= 1` here would be satisfied by a pre-window repair.
        let phase1Prefix = accumulated
        accumulated += await drain(fd: readFD, deadline: .seconds(45)) { [self] data in
            guard let stats = fanout.flowStats(key: key),
                  stats.repairs > baseline.repairs else { return false }
            let text = String(decoding: phase1Prefix + data, as: UTF8.self)
            guard let last = text.range(of: ReplayWriter.resetPrelude, options: .backwards)
            else { return false }
            let healed = strippingEscapes(String(text[last.upperBound...]))
            return tokens(in: healed, label: "SEQ").count >= 30
        }
        let text = String(decoding: accumulated, as: UTF8.self)
        let observed = fanout.flowStats(key: key)
        // Stop the supervisor BEFORE the assertions, not after: the pane is
        // still blasting, and a `try #require` that fails below would unwind
        // past the `defer` that closes the read end of the pipe it writes to —
        // the next fanout write then raises SIGPIPE and kills the whole test
        // process (measured: `Exited with unexpected signal code 13`, with no
        // diagnostic at all). The counters are snapshotted above so tearing the
        // supervisor down first costs nothing.
        await supervisor.stopAll()

        // (a) A repair completed DURING the overflow window — both in the
        // counters and as one more reset prelude in the byte stream than the
        // window opened with (the attach replay contributed the first).
        let stats = try #require(observed, "sink vanished mid-test")
        #expect(stats.repairs > baseline.repairs,
                "the overflow window never triggered a completed repair (repairs \(stats.repairs), baseline \(baseline.repairs))")
        let preludeCount = text.components(separatedBy: ReplayWriter.resetPrelude).count - 1
        let baselinePreludes = String(decoding: phase1Prefix, as: UTF8.self)
            .components(separatedBy: ReplayWriter.resetPrelude).count - 1
        #expect(preludeCount > baselinePreludes,
                "expected the repair's reset prelude in the stream (found \(preludeCount), of which \(baselinePreludes) were already present when the window opened)")

        // (b) The heal proof: after the LAST reset prelude — the final repair
        // replay — SEQ tokens are gapless and monotonic through the end of
        // the accumulated stream: recapture tail ⊕ fence flush ⊕ live, with
        // no hole where the overflow used to drop.
        let last = try #require(text.range(of: ReplayWriter.resetPrelude, options: .backwards))
        let healed = tokens(in: strippingEscapes(String(text[last.upperBound...])), label: "SEQ")
        #expect(healed.count >= 30, "healed stream too short to prove anything (\(healed.count) tokens)")
        let violations = sequenceViolations(healed).joined(separator: "; ")
        #expect(violations.isEmpty,
                "LOSS/DUP after the repair replay — the overflow hole was not healed: \(violations)")
    }
}

private enum MatrixError: Error, CustomStringConvertible {
    case clientNeverReady
    case pollDeadline(String)
    /// The pane's sink was gone when the test needed to read its counters.
    case sinkVanished(String)
    /// The overflow window closed without the sink entering the repair cycle.
    /// Carries the counters observed at the deadline AND the baseline the window
    /// opened with, since every verdict here is a delta — `nil` stats mean the
    /// sink itself was gone.
    case overflowRepairNeverEntered(
        stats: PaneFlowStats?, baseline: PaneFlowStats, queueCap: Int, waited: Duration)

    var description: String {
        switch self {
        case .clientNeverReady:
            return "the tmux control-mode command client never became ready"
        case .pollDeadline(let what):
            return "timed out polling for: \(what)"
        case .sinkVanished(let when):
            return "the pane's fanout sink was gone \(when) (detached or superseded), "
                + "so nothing was routing"
        case .overflowRepairNeverEntered(let stats, let baseline, let queueCap, let waited):
            guard let stats else {
                return "no repair cycle after \(waited) of firehose with no reader — "
                    + "the sink had vanished (detached or superseded), so nothing was routing"
            }
            // Every counter is shown against the value the window opened with:
            // the question this error answers is what happened DURING the
            // window, and the absolute totals include everything before it.
            let facts = "queuedHighWater=\(stats.queuedHighWater) of queueCap=\(queueCap), "
                + "queuedBytes=\(stats.queuedBytes), "
                + "overflowEvents=\(stats.overflowEvents) (baseline \(baseline.overflowEvents)), "
                + "droppedBytes=\(stats.droppedBytes) (baseline \(baseline.droppedBytes)), "
                + "repairing=\(stats.repairing), "
                + "repairs=\(stats.repairs) (baseline \(baseline.repairs))"
            let verdict = stats.overflowEvents > baseline.overflowEvents
                ? "the queue DID overflow and the sink dropped instead of repairing — production"
                : "the queue never reached the cap, so the setup never induced an overflow — harness"
            return "no repair cycle after \(waited) of firehose with no reader: \(verdict). \(facts)"
        }
    }
}
