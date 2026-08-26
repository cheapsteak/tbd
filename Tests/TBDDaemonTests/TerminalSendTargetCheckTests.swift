import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — dry-run tmux plus a real (temp-directory) actuation log.
///
/// `terminal.send` consults its target before it types. These prove what each
/// answer produces: which sends are refused, with which reason on the record,
/// which still go through, and that the healthy path emits exactly the tmux
/// commands it emitted before the check existed.
@Suite("terminal.send target check")
struct TerminalSendTargetCheckTests {

    // MARK: - Fixture

    /// Thread-safe collector for tmux argv lists invoked during dryRun.
    private final class ArgvRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func record(_ args: [String]) {
            lock.lock(); defer { lock.unlock() }
            _calls.append(args)
        }
    }

    /// What the fixture's pane answers when asked who it is. Spelled relative to
    /// the terminal rather than as a literal, because the interesting cases are
    /// agreement and disagreement with an id the fixture only mints later.
    private enum PaneAnswer: Sendable {
        case absent
        case dead
        /// Alive, carrying no identity at all.
        case unresolvable
        /// Alive, answering with the requested terminal's own id.
        case matching
        /// Alive, answering with the requested id in the other case.
        case matchingLowercased
        /// Alive, answering with somebody else's id.
        case stranger(String)
        /// The consultation could not be run at all — a wedged tmux tripping
        /// the subprocess timeout. Not an answer about the pane.
        case wedged
        /// The consultation ran and reached no server. Also not an answer about
        /// the pane, and the case the daemon used to conflate with `.absent`.
        case unreachable
    }

    /// The error a `.wedged` consultation fails with, so the test can
    /// assert the handler propagated *that* error rather than inventing one.
    private struct WedgedTmux: Error {}

    /// Lets the dryRun hook — constructed before the terminal row exists —
    /// answer with that terminal's id once it does.
    private final class TerminalIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _id: String = ""
        var id: String {
            get { lock.lock(); defer { lock.unlock() }; return _id }
            set { lock.lock(); defer { lock.unlock() }; _id = newValue }
        }
    }

    private struct Fixture {
        let router: RPCRouter
        let terminal: Terminal
        let recorder: ArgvRecorder
        let logPath: String
    }

    private func makeFixture(answer: PaneAnswer) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-send-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logPath = directory.appendingPathComponent("actuations.jsonl").path

        let recorder = ArgvRecorder()
        let box = TerminalIDBox()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunPaneSendTarget: { _, _ in
                switch answer {
                case .absent: return .absent
                case .dead: return .dead(terminalID: box.id)
                case .unresolvable: return .live(terminalID: nil)
                case .matching: return .live(terminalID: box.id)
                case .matchingLowercased: return .live(terminalID: box.id.lowercased())
                case .stranger(let other): return .live(terminalID: other)
                case .wedged: throw WedgedTmux()
                case .unreachable: return .unreachable
                }
            })
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            actuationLog: ActuationLog(path: logPath))
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@3", tmuxPaneID: "%7")
        box.id = terminal.id.uuidString
        return Fixture(router: router, terminal: terminal, recorder: recorder, logPath: logPath)
    }

    private func send(
        _ fixture: Fixture, text: String = "status?", submit: Bool = true
    ) async throws -> RPCResponse {
        await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: fixture.terminal.id, text: text, submit: submit)))
    }

    private func rows(at path: String) throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    private func lastOutcome(at path: String) throws -> [String: Any] {
        try #require(try rows(at: path).last)
    }

    // MARK: - Refusals

    @Test("a dead pane is refused as not-eligible instead of reporting success")
    func deadPaneRefused() async throws {
        // The whole point: `send-keys` into a `remain-on-exit` dead pane exits 0,
        // so tmux's own status would have called this a successful send.
        let fixture = try await makeFixture(answer: .dead)
        let response = try await send(fixture)

        #expect(!response.success)
        #expect(response.error?.contains("%7") == true)
        #expect(response.error?.contains("dead") == true)
        #expect(fixture.recorder.calls.isEmpty)

        let written = try rows(at: fixture.logPath)
        #expect(written.count == 2)
        #expect(written.first?["kind"] as? String == "send")
        let outcome = try #require(written.last)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "not-eligible")
        #expect(!written.contains { $0["result"] as? String == "dispatched" })
    }

    @Test("a pane tmux cannot find is refused as not-found")
    func missingPaneRefused() async throws {
        let fixture = try await makeFixture(answer: .absent)
        let response = try await send(fixture)

        #expect(!response.success)
        #expect(fixture.recorder.calls.isEmpty)
        let written = try rows(at: fixture.logPath)
        // Exactly the request row and its outcome — a refusal must not also
        // leave a second outcome behind.
        #expect(written.count == 2)
        let outcome = try #require(written.last)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "not-found")
        #expect(!written.contains { $0["result"] as? String == "dispatched" })
    }

    @Test("a pane that answers with a different terminal is refused, naming both ids")
    func mismatchedPaneRefused() async throws {
        let stranger = UUID().uuidString
        let fixture = try await makeFixture(answer: .stranger(stranger))
        let response = try await send(fixture)

        #expect(!response.success)
        let error = try #require(response.error)
        // Both ids, so the reader can tell which coordinate went stale.
        #expect(error.contains(stranger))
        #expect(error.contains(fixture.terminal.id.uuidString))
        #expect(fixture.recorder.calls.isEmpty)

        let written = try rows(at: fixture.logPath)
        #expect(written.count == 2)
        let outcome = try #require(written.last)
        #expect(outcome["result"] as? String == "refused")
        #expect(outcome["reason"] as? String == "target-mismatch")
        #expect(!written.contains { $0["result"] as? String == "dispatched" })
    }

    /// The consultation failing to *run* is not an answer about the pane, so it
    /// is not a refusal: the daemon reached for the transport and the transport
    /// did not answer. The caller gets the underlying error, not a verdict about
    /// its target, and the record says `transport-failed`.
    @Test("a consultation that cannot be run is a transport failure, not a refusal")
    func unreachableConsultationIsTransportFailure() async throws {
        let fixture = try await makeFixture(answer: .wedged)

        // The handler rethrows; the router turns that into an error response.
        let response = try await send(fixture)
        #expect(!response.success)
        #expect(response.error?.contains("WedgedTmux") == true)
        #expect(fixture.recorder.calls.isEmpty)

        let written = try rows(at: fixture.logPath)
        #expect(written.count == 2)
        let outcome = try #require(written.last)
        #expect(outcome["result"] as? String == "transport-failed")
        // Not misfiled as any flavour of refusal.
        #expect(outcome["reason"] == nil)
        #expect(!written.contains { $0["result"] as? String == "dispatched" })
    }

    /// The field defect this suite grew for: the daemon could not reach the
    /// server (its `TMUX_TMPDIR` differs from the user's shell, so the same
    /// `-L <name>` resolved elsewhere) and the send refused with "no longer
    /// exists on server …" while the pane was demonstrably alive and accepting
    /// `send-keys` from a shell. A failed read must not wear the words of a
    /// missing pane, and must not be filed as a refusal.
    @Test("an unreachable server is a transport failure, and never says the pane is gone")
    func unreachableServerIsNotReportedAsMissing() async throws {
        let fixture = try await makeFixture(answer: .unreachable)
        let response = try await send(fixture)

        #expect(!response.success)
        let error = try #require(response.error)
        // The exact phrase the old code produced for this state.
        #expect(!error.contains("no longer exists"))
        // It says what actually happened, and that it is worth retrying.
        #expect(error.contains("could not reach tmux server"))
        #expect(error.contains("tbd-acme"))
        #expect(error.contains("%7"))
        #expect(error.lowercased().contains("retry"))
        // Nothing was typed.
        #expect(fixture.recorder.calls.isEmpty)

        let written = try rows(at: fixture.logPath)
        #expect(written.count == 2)
        let outcome = try #require(written.last)
        #expect(outcome["result"] as? String == "transport-failed")
        // Emphatically not filed as any flavour of refusal — least of all
        // `not-found`, which would put "the pane is gone" on the record.
        #expect(outcome["reason"] == nil)
        #expect(!written.contains { $0["result"] as? String == "dispatched" })
    }

    /// Liveness comes from what tmux answered, never from the row's own
    /// bookkeeping. A terminal the DB still calls `working` whose pane is dead
    /// is dead — stale activity metadata must not soften the verdict into
    /// "unknown", nor harden an unreachable read into a verdict.
    @Test("stale working activity does not change a dead pane's verdict")
    func staleActivityDoesNotChangeLivenessVerdict() async throws {
        for state in [TerminalActivityState.working, .waitingForUser] {
            let fixture = try await makeFixture(answer: .dead)
            try await fixture.router.db.terminals.setActivityState(
                id: fixture.terminal.id, activityState: state,
                source: .hookEvent("UserPromptSubmit"))
            let stamped = try await fixture.router.db.terminals.get(id: fixture.terminal.id)
            #expect(stamped?.activityState == state)

            let response = try await send(fixture)
            #expect(!response.success)
            #expect(response.error?.contains("dead") == true)
            let outcome = try lastOutcome(at: fixture.logPath)
            #expect(outcome["result"] as? String == "refused")
            #expect(outcome["reason"] as? String == "not-eligible")
        }
    }

    // MARK: - The branches that still send

    @Test("a pane that agrees on its identity sends normally")
    func matchingPaneSends() async throws {
        let fixture = try await makeFixture(answer: .matching)
        let response = try await send(fixture)

        #expect(response.success)
        #expect(try lastOutcome(at: fixture.logPath)["result"] as? String == "dispatched")
    }

    /// UUIDs round-trip through tmux and the DB as strings; a case difference is
    /// the same session, not a stranger.
    @Test("identity comparison is case-insensitive")
    func identityComparisonIsCaseInsensitive() async throws {
        let fixture = try await makeFixture(answer: .matchingLowercased)
        let response = try await send(fixture)

        #expect(response.success)
        #expect(try lastOutcome(at: fixture.logPath)["result"] as? String == "dispatched")
    }

    /// Absence is not disagreement. A pane spawned before TBD stamped
    /// identities — or by something outside TBD — carries no id, and refusing
    /// on that would make this fix a regression for every such pane.
    @Test("a pane with no identity to compare still sends")
    func unresolvablePaneSends() async throws {
        let fixture = try await makeFixture(answer: .unresolvable)
        let response = try await send(fixture)

        #expect(response.success)
        let outcome = try lastOutcome(at: fixture.logPath)
        #expect(outcome["result"] as? String == "dispatched")
        #expect(outcome["reason"] == nil)
    }

    /// The healthy path must emit the SAME tmux commands, with the same
    /// arguments, that it emitted before the target check existed: an explicit
    /// bracketed paste (load-buffer + paste-buffer -d -p) then a separate Enter.
    /// The consultation is a read-only query and contributes no command here.
    @Test("a healthy send emits exactly the tmux commands it always did")
    func healthySendCommandsUnchanged() async throws {
        let fixture = try await makeFixture(answer: .matching)
        let response = try await send(fixture, text: "rebase onto main")
        #expect(response.success)

        let calls = fixture.recorder.calls
        #expect(calls.count == 3)

        let load = try #require(calls.first { $0.contains("load-buffer") })
        // Compared as a prefix rather than by index: `#require` proves the call
        // exists, not that it is four arguments long, and indexing past its end
        // would crash the run instead of failing it.
        #expect(load.prefix(4) == ["-L", "tbd-acme", "load-buffer", "-b"])

        let paste = try #require(calls.first { $0.contains("paste-buffer") })
        #expect(paste.contains("-d"))
        #expect(paste.contains("-p"))
        #expect(paste.contains("-t"))
        #expect(paste.contains("%7"))

        let enter = try #require(calls.first { $0.contains("send-keys") })
        #expect(enter == ["-L", "tbd-acme", "send-keys", "-t", "%7", "Enter"])

        // Order: paste, then the Enter that must land outside it.
        let pasteIdx = try #require(calls.firstIndex { $0.contains("paste-buffer") })
        let enterIdx = try #require(calls.firstIndex { $0.contains("send-keys") })
        #expect(pasteIdx < enterIdx)
    }

    @Test("a send without submit still skips the Enter")
    func noSubmitStillSkipsEnter() async throws {
        let fixture = try await makeFixture(answer: .matching)
        #expect(try await send(fixture, submit: false).success)
        #expect(!fixture.recorder.calls.contains { $0.contains("send-keys") })
    }

    // MARK: - Serialization wiring

    /// A one-shot gate a test can open from the outside.
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var entered = false

        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            entered = true
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        var hasEntered: Bool { entered }
    }

    /// Two payloads spliced into one composer is a transport bug: neither caller
    /// asked for the message that would arrive. This holds the terminal's lane
    /// from outside the handler and proves the handler waits for it — nothing is
    /// typed while another send owns the terminal, and the queued send is
    /// delivered afterwards rather than refused.
    @Test("a send waits for the terminal's lane before typing anything")
    func sendQueuesBehindTheLane() async throws {
        let fixture = try await makeFixture(answer: .matching)
        let gate = Gate()

        // Occupy this terminal's lane the way an in-flight send would.
        async let holder: Void = fixture.router.terminalSendSerializer
            .run(terminalID: fixture.terminal.id) { await gate.wait() }
        let deadline = ContinuousClock.now + .seconds(15)
        while await !gate.hasEntered && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.hasEntered)

        async let response = send(fixture, text: "queued")
        // Bounded window: with the lane held, the send must type nothing.
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.recorder.calls.isEmpty)

        await gate.open()
        try await holder
        #expect(try await response.success)
        #expect(!fixture.recorder.calls.isEmpty)
        #expect(try lastOutcome(at: fixture.logPath)["result"] as? String == "dispatched")
    }

    /// A send to a DIFFERENT terminal must not wait behind this one: the lane is
    /// per composer, not a global send lock.
    @Test("a busy terminal's lane does not block another terminal's send")
    func otherTerminalsAreUnaffected() async throws {
        let fixture = try await makeFixture(answer: .unresolvable)
        let gate = Gate()
        let other = try await fixture.router.db.terminals.create(
            worktreeID: fixture.terminal.worktreeID, tmuxWindowID: "@4", tmuxPaneID: "%8")

        async let holder: Void = fixture.router.terminalSendSerializer
            .run(terminalID: fixture.terminal.id) { await gate.wait() }
        let deadline = ContinuousClock.now + .seconds(15)
        while await !gate.hasEntered && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.hasEntered)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: other.id, text: "hi", submit: true)))
        #expect(response.success)
        #expect(fixture.recorder.calls.contains { $0.contains("%8") })

        await gate.open()
        try await holder
    }
}
