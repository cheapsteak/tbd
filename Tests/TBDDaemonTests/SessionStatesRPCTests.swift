import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// Records every tmux interaction the router would have had. `session.states`
/// must leave it empty — that is the cheap-path property, asserted rather than
/// assumed.
///
/// `dryRunRecorder` alone is **not** enough, and the gap matters here more than
/// anywhere: it fires on the mutating commands, while `capturePaneOutput`,
/// `capturePaneWithAnsi`, `capturePaneScrollback`, `paneCurrentCommand`,
/// `paneSendTarget`, `listWindows` and `windowPresence` short-circuit on their own
/// dryRun hooks and never reach it. A pane *read* is exactly what this method
/// must never do, so the fixture wires every one of those hooks into the same
/// recorder and the assertion covers the composed set rather than one arm of it.
private final class TmuxCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []

    func record(_ args: [String]) {
        lock.lock()
        defer { lock.unlock() }
        commands.append(args)
    }

    var recorded: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }
}

/// Tier 2 — in-memory database plus real (temp-dir) transcript files, no tmux
/// server and no subprocess.
@Suite("session.states RPC")
struct SessionStatesRPCTests {

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let recorder: TmuxCommandRecorder
        let scratch: URL
        let worktreeID: UUID

        func cleanUp() { try? FileManager.default.removeItem(at: scratch) }
    }

    /// - Parameter now: the router's date seam. Defaulted so every existing
    ///   case is unchanged; the fallback-stamp case below pins it, which is the
    ///   only way to tell an injected clock from wall time.
    private func makeFixture(
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> Fixture {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-session-states-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let db = try TBDDatabase(inMemory: true)
        let recorder = TmuxCommandRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunWindowIsDead: { window in
                recorder.record(["window-exists", window])
                return false
            },
            dryRunListWindows: { server, session in
                recorder.record(["list-windows", server, session])
                return []
            },
            dryRunCapturePane: { server, pane in
                recorder.record(["capture-pane", server, pane])
                return ""
            },
            dryRunPaneCurrentCommand: { server, pane in
                recorder.record(["pane-current-command", server, pane])
                return "zsh"
            },
            dryRunPaneSendTarget: { server, pane in
                recorder.record(["pane-send-target", server, pane])
                return .live(terminalID: nil)
            })
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver()),
            tmux: tmux,
            startTime: Date(),
            now: now,
            actuationLog: makeTestActuationLog())

        let repo = try await db.repos.create(
            path: scratch.appendingPathComponent("repo").path,
            displayName: "repo", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "feature",
            path: scratch.appendingPathComponent("repo").path, tmuxServer: "tbd-states-test")
        return Fixture(
            db: db, router: router, recorder: recorder, scratch: scratch,
            worktreeID: worktree.id)
    }

    private func writeTranscript(_ fixture: Fixture, name: String, lines: [String]) throws -> String {
        let path = fixture.scratch.appendingPathComponent(name).path
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: URL(fileURLWithPath: path))
        return path
    }

    private func states(_ fixture: Fixture, worktreeID: UUID? = nil) async throws -> [SessionStateReport] {
        let request = try RPCRequest(
            method: RPCMethod.sessionStates, params: SessionStatesParams(worktreeID: worktreeID))
        let response = await fixture.router.handle(request)
        #expect(response.error == nil, "session.states errored: \(response.error ?? "")")
        return try response.decodeResult(SessionStatesResult.self).reports
    }

    // MARK: -

    @Test func reportsOnePerTerminalWithProvenanceOnEveryState() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let a = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", kind: .claude)
        let c = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "codex", kind: .codex)
        try await fixture.db.terminals.setActivityState(
            id: a.id, activityState: .working, source: .hookEvent(RPCMethod.terminalActivityEvent))

        let reports = try await states(fixture)
        #expect(reports.count == 2)
        #expect(Set(reports.map(\.terminalID)) == [a.id, c.id])
        for report in reports {
            #expect(report.worktreeID == fixture.worktreeID)
            // Composed output, not field presence: the summary is only
            // constructible from all three parts of the triple.
            #expect(report.state.summary.contains("source:"))
            #expect(report.state.summary.contains("observed "))
        }

        let reportA = try #require(reports.first { $0.terminalID == a.id })
        #expect(reportA.state.value == .working)
        #expect(reportA.state.source == .hookEvent(RPCMethod.terminalActivityEvent))

        // The terminal nothing ever spoke about is `unknown`, not `idle`.
        let reportC = try #require(reports.first { $0.terminalID == c.id })
        #expect(reportC.state.value.isConfident == false)
    }

    /// A plain shell is not a session this model has anything to say about: no
    /// transcript, no context window, no hook rail. Reporting one spends a stat
    /// and a transcript-tail attempt every cycle to produce a paragraph
    /// explaining why a session that was never going to have a statusline tee
    /// has no denominator.
    @Test func aPlainShellIsNotReportedOnAtAll() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let agent = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", kind: .claude)
        let shell = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "shell", kind: .shell)
        // A pre-`kind` row carries nil and is treated as an agent: dropping a
        // real agent from the fleet's readout is the worse of the two errors.
        let legacy = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2", label: "legacy")

        let reported = Set(try await states(fixture).map(\.terminalID))
        #expect(reported == [agent.id, legacy.id])
        #expect(!reported.contains(shell.id))
    }

    /// End to end for the resolver's staleness rule: the append stamp has to be
    /// a real file's, or the rule is a well-tested decoration.
    ///
    /// The prompt is recorded AFTER the turn's `working` stamp, so it wins on
    /// observed-at and nothing on the hook rail will ever retract it — the
    /// activity handler returns early on an unchanged value. Then the transcript
    /// grows, which could be the answered tool's result or a parallel subagent's
    /// records with the prompt still up. Machine facts cannot separate the two,
    /// so the answer becomes `unknown` — never `.working`, which is what the
    /// stale hook stamp on the row would otherwise say.
    @Test func aPromptTheTranscriptHasGrownPastIsReportedAsUnknownByTheRPC() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", kind: .claude)
        let path = try writeTranscript(
            fixture, name: "prompt.jsonl",
            lines: [#"{"type":"assistant","message":{"usage":{"input_tokens":10}}}"#])
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: "sess-prompt", transcriptPath: path)

        let turnStartedAt = Date().addingTimeInterval(-120)
        try await fixture.db.terminals.setActivityState(
            id: terminal.id, activityState: .working,
            source: .hookEvent(RPCMethod.terminalActivityEvent), observedAt: turnStartedAt)
        // Recorded a minute into the turn, and never superseded.
        let promptAt = turnStartedAt.addingTimeInterval(60)
        // The transcript's last append is the assistant record that RAISED the
        // prompt, so it predates it — which is what an unanswered prompt looks
        // like in bytes.
        try FileManager.default.setAttributes(
            [.modificationDate: turnStartedAt.addingTimeInterval(59)], ofItemAtPath: path)
        try await fixture.db.terminals.recordAwaitingInputReason(
            id: terminal.id,
            reason: AwaitingInputReason(
                message: "Claude needs your permission to run rm",
                hookEventName: "Notification",
                notificationType: "permission_prompt"),
            observedAt: promptAt)

        let beforeAnswer = try #require(try await states(fixture).first)
        #expect(beforeAnswer.state.value.label == "awaiting input")

        // Something appended. It could be the answered tool's result — or a
        // parallel subagent's sidechain record with the prompt still on screen.
        // Nothing reads what was appended, so nothing can tell those apart.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"user","message":{"role":"user"}}"#.utf8))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        let afterGrowth = try #require(try await states(fixture).first)
        // NOT `.working`: the stale `working` stamp from `UserPromptSubmit` is
        // still on the row, and reporting it would present a session possibly
        // blocked on a human as one making progress.
        #expect(afterGrowth.state.value != .working)
        guard case .unknown(let why) = afterGrowth.state.value else {
            Issue.record("expected .unknown, got \(afterGrowth.state.value)")
            return
        }
        #expect(why.contains("a prompt was reported"))
        #expect(why.contains("the transcript has grown since"))
        #expect(afterGrowth.state.source == .transcriptTail)
        #expect(!afterGrowth.state.summary.contains("permission to run rm"))
    }

    @Test func performsNoSubprocessOrPaneRead() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", kind: .claude)
        let path = try writeTranscript(
            fixture, name: "session.jsonl",
            lines: [#"{"type":"assistant","message":{"usage":{"input_tokens":1000}}}"#])
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: "sess-1", transcriptPath: path)

        _ = try await states(fixture)

        // Every tmux interaction the router could have in dryRun lands in the
        // recorder — the mutating commands and, separately wired, every
        // read-only query and pane capture. An empty recorder is the proof
        // that the pass costs no subprocess and reads no pane, which is what
        // lets this method be called every cycle for the whole fleet.
        #expect(fixture.recorder.recorded.isEmpty,
                "session.states touched tmux: \(fixture.recorder.recorded)")
    }

    @Test func theWorktreeFilterNarrowsTheReport() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let repo = try #require(try await fixture.db.repos.list().first)
        let other = try await fixture.db.worktrees.create(
            repoID: repo.id, name: "other", branch: "other",
            path: fixture.scratch.appendingPathComponent("other").path,
            tmuxServer: "tbd-states-test")

        _ = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@0", tmuxPaneID: "%0", label: "a")
        let elsewhere = try await fixture.db.terminals.create(
            worktreeID: other.id, tmuxWindowID: "@1", tmuxPaneID: "%1", label: "b")

        let filtered = try await states(fixture, worktreeID: other.id)
        #expect(filtered.map(\.terminalID) == [elsewhere.id])
        #expect(try await states(fixture).count == 2)
    }

    @Test func aWorktreeScopedCallLeavesCountersOutsideTheScopeIntact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let repo = try #require(try await fixture.db.repos.list().first)
        let other = try await fixture.db.worktrees.create(
            repoID: repo.id, name: "other", branch: "other",
            path: fixture.scratch.appendingPathComponent("other").path,
            tmuxServer: "tbd-states-test")

        let here = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "here", kind: .claude)
        let elsewhere = try await fixture.db.terminals.create(
            worktreeID: other.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "elsewhere", kind: .claude)
        let herePath = try writeTranscript(fixture, name: "here.jsonl", lines: ["{}"])
        let elsewherePath = try writeTranscript(fixture, name: "elsewhere.jsonl", lines: ["{}"])
        try await fixture.db.terminals.updateSession(
            id: here.id, sessionID: "sess-here", transcriptPath: herePath)
        try await fixture.db.terminals.updateSession(
            id: elsewhere.id, sessionID: "sess-elsewhere", transcriptPath: elsewherePath)

        _ = try await states(fixture)  // fleet-wide: both baselines established

        // Give the out-of-scope session something to lose: one hook event and
        // three appended records inside its observation window.
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: elsewhere.id, activityState: .working))
        _ = await fixture.router.handle(request)
        let handle = try #require(FileHandle(forWritingAtPath: elsewherePath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n{}\n{}\n".utf8))
        try handle.close()

        // A call about the *other* worktree enumerates only its terminals, and
        // must not treat that narrowed list as the whole fleet.
        _ = try await states(fixture, worktreeID: fixture.worktreeID)

        let report = try #require(try await states(fixture).first { $0.terminalID == elsewhere.id })
        let counters = try #require(report.counters)
        #expect(counters.turnsInWindow == 3)
        #expect(counters.hookEventsInWindow == 1)
    }

    @Test func contextLoadReportsAnUnknownWindowForAFleetSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", kind: .claude)
        let path = try writeTranscript(
            fixture, name: "session.jsonl",
            lines: [
                #"{"type":"assistant","message":{"usage":{"input_tokens":900,"cache_read_input_tokens":100}}}"#
            ])
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: "sess-1", transcriptPath: path)

        let report = try #require(try await states(fixture).first)
        let load = try #require(report.contextLoad)
        #expect(load.used?.value == 1_000)
        #expect(load.used?.source == .transcriptTail)
        // The statusline tee installs on desk sessions only, so the
        // denominator is unknown and reported as unknown.
        guard case .unknown = load.window else {
            Issue.record("expected an unknown window for a fleet session, got \(load.window)")
            return
        }
        #expect(load.isPairedReading == false)
    }

    /// The router's date seam has to reach every fact this pass stamps,
    /// including the ones a collaborator stamps on its behalf.
    ///
    /// A transcript record that carries no parseable `timestamp` of its own
    /// gets the reader's fallback date. That reader is `ContextLoadReader`,
    /// which the gatherer owns — so if the gatherer keeps its injected `now` to
    /// itself, this one field comes back as wall time while every other stamp
    /// in the same report is pinned. The two are only distinguishable by a
    /// pinned clock, which is exactly what makes this worth asserting.
    @Test func aTranscriptRecordWithNoTimestampIsStampedWithTheRoutersClock() async throws {
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = try await makeFixture(now: { pinned })
        defer { fixture.cleanUp() }
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", kind: .claude)
        // No `timestamp` key: the record cannot say when it was written, so the
        // fallback date is the only stamp the fact can carry.
        let path = try writeTranscript(
            fixture, name: "no-timestamp.jsonl",
            lines: [
                #"{"type":"assistant","message":{"usage":{"input_tokens":900,"cache_read_input_tokens":100}}}"#
            ])
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: "sess-1", transcriptPath: path)

        let report = try #require(try await states(fixture).first)
        let load = try #require(report.contextLoad)
        let used = try #require(load.used)

        #expect(used.value == 1_000)
        #expect(used.observedAt == pinned,
                "the numerator's fallback stamp came from wall time, not the injected seam: \(used.observedAt)")
    }

    /// The desk role brands the ROW; the tee installs on the Claude spawn path
    /// only. `spawnPrimaryTerminals` resolves the primary agent from
    /// `primaryAgentPreference`, so a desk created on a Codex-preferring install
    /// is a `.codex` row wearing `.readOnlyCoordinator` — and telling its reader
    /// "the tee is installed but has not fired yet" would be a claim about a
    /// capture that will never appear.
    @Test func aCodexDeskIsNotDescribedAsWaitingForATeeItDoesNotHave() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let codexDesk = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "codex", kind: .codex, watchDeskRole: .readOnlyCoordinator)
        let claudeDesk = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", kind: .claude, watchDeskRole: .readOnlyCoordinator)

        let reports = try await states(fixture)

        let codexReport = try #require(reports.first { $0.terminalID == codexDesk.id })
        guard case .unknown(let codexWhy) = try #require(codexReport.contextLoad).window else {
            Issue.record("expected an unknown window for a Codex desk")
            return
        }
        #expect(!codexWhy.contains("has not fired yet"))
        #expect(codexWhy.contains("does not run the agent the statusline tee installs on"))

        // The Claude desk keeps the wording it had — the fix adds a case rather
        // than moving the existing one.
        let claudeReport = try #require(reports.first { $0.terminalID == claudeDesk.id })
        guard case .unknown(let claudeWhy) = try #require(claudeReport.contextLoad).window else {
            Issue.record("expected an unknown window for a desk whose tee has not fired")
            return
        }
        #expect(claudeWhy.contains("has not fired yet"))
    }

    @Test func countersAppearForASessionWithAReadableTranscriptAndNotForOneWithout() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let withTranscript = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", kind: .claude)
        // An agent whose session has not started yet: it is reported on, and
        // its counters are absent rather than zero. (A plain shell would not be
        // reported at all — see `aPlainShellIsNotReportedOnAtAll`.)
        let withoutTranscript = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", kind: .claude)
        let path = try writeTranscript(fixture, name: "session.jsonl", lines: ["{}"])
        try await fixture.db.terminals.updateSession(
            id: withTranscript.id, sessionID: "sess-1", transcriptPath: path)

        let reports = try await states(fixture)
        let counted = try #require(reports.first { $0.terminalID == withTranscript.id })
        let counters = try #require(counted.counters)
        // First sighting baselines at the file's end — history is never a burst.
        #expect(counters.turnsInWindow == 0)
        // No sweep has run in this fixture, so the commits fact is not
        // established. nil, never "unchanged".
        #expect(counters.commitsUnchangedSince == nil)

        let uncounted = try #require(reports.first { $0.terminalID == withoutTranscript.id })
        #expect(uncounted.counters == nil)
    }

    @Test func hookEventsRaiseTheCountAndAppendedRecordsRaiseTheTurns() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", kind: .claude)
        let path = try writeTranscript(fixture, name: "session.jsonl", lines: ["{}"])
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: "sess-1", transcriptPath: path)
        _ = try await states(fixture)  // establish the baseline

        // Two hook-driven RPCs, one of which repeats a state the row already
        // holds — the shape the activity handler's unchanged-state early
        // return skips. The counter must still see it.
        for state in [TerminalActivityState.working, .working] {
            let request = try RPCRequest(
                method: RPCMethod.terminalActivityEvent,
                params: TerminalActivityEventParams(terminalID: terminal.id, activityState: state))
            _ = await fixture.router.handle(request)
        }

        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n{}\n{}\n".utf8))
        try handle.close()

        let counters = try #require(try await states(fixture).first?.counters)
        #expect(counters.hookEventsInWindow == 2)
        #expect(counters.turnsInWindow == 3)
    }

    @Test func aScheduledResumeMirrorSurfacesAsRateLimited() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@0", tmuxPaneID: "%0",
            label: "claude", kind: .claude)
        let until = Date().addingTimeInterval(3_600)
        _ = try await fixture.db.scheduledResumes.insertPending(ScheduledResume(
            terminalID: terminal.id, worktreeID: fixture.worktreeID,
            resetsAt: until, fireAt: until,
            limitType: "session", rawMessage: "hit your session limit"))

        let report = try #require(try await states(fixture).first)
        guard case .rateLimited(let reported) = report.state.value else {
            Issue.record("expected .rateLimited, got \(report.state.value)")
            return
        }
        #expect(reported != nil)
        #expect(report.state.source == .database)
    }
}
