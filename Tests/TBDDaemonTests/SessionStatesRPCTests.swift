import Foundation
import Testing
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — in-memory database plus real (temp-dir) transcript files, no
/// holder and no subprocess.
@Suite("session.states RPC")
struct SessionStatesRPCTests {

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let scratch: URL
        let worktreeID: UUID

        func cleanUp() { try? FileManager.default.removeItem(at: scratch) }
    }

    /// - Parameters:
    ///   - now: the router's date seam. Defaulted so every existing case is
    ///     unchanged; the fallback-stamp case below pins it, which is the only
    ///     way to tell an injected clock from wall time.
    ///   - touches: when given, every seam `HolderTouchRecorder` covers
    ///     records into it — the router's and the lifecycle's process seams,
    ///     the router's screen and input seams, and the router's holder
    ///     registry, which spawns through `holder`.
    private func makeFixture(
        now: @escaping @Sendable () -> Date = { Date() },
        touches: HolderTouchRecorder? = nil,
        holder: FakeHolderLaunch = FakeHolderLaunch()
    ) async throws -> Fixture {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-session-states-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let db = try TBDDatabase(inMemory: true)
        // Typed as `RPCRouter.init` takes them, and chosen here rather than
        // inside the call, so the call infers nothing.
        let processSignaller: any ProcessSignaller
        let processTableReader: @Sendable () -> ProcessTableSnapshot?
        if let touches {
            processSignaller = touches.signaller
            processTableReader = touches.processTableReader
        } else {
            processSignaller = ProductionProcessSignaller()
            processTableReader = { ProcessTableSnapshot.read() }
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), hooks: HookResolver(),
                processSignaller: processSignaller,
                leftoverTmuxProbe: .absent),
            startTime: Date(),
            now: now,
            processSignaller: processSignaller,
            actuationLog: makeTestActuationLog(),
            processTableReader: processTableReader)
        if let touches {
            touches.install(on: router)
            router.holderRegistry = touches.registryDouble(launch: holder)
        }

        let repo = try await db.repos.create(
            path: scratch.appendingPathComponent("repo").path,
            displayName: "repo", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "feature",
            path: scratch.appendingPathComponent("repo").path, tmuxServer: "tbd-states-test")
        return Fixture(
            db: db, router: router, scratch: scratch,
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
            id: a.id, activityState: .working, source: .programStatus)

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
        #expect(reportA.state.source == .programStatus)

        // The terminal nothing ever spoke about is `unknown`, not `idle`.
        let reportC = try #require(reports.first { $0.terminalID == c.id })
        #expect(reportC.state.value.isConfident == false)
    }

    /// A plain shell is not a session this model has anything to say about: no
    /// transcript, no context window, no hook rail. Reporting one spends a stat
    /// and a transcript-tail attempt on every call to produce a paragraph
    /// explaining why a session that was never an agent has no denominator.
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
        // real agent from the report is the worse of the two errors.
        let legacy = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2", label: "legacy")

        let reported = Set(try await states(fixture).map(\.terminalID))
        #expect(reported == [agent.id, legacy.id])
        #expect(!reported.contains(shell.id))
    }

    /// End to end for the column rung: a wait the program status store wrote is
    /// reported with its block, and a transcript that grows afterwards — a
    /// parallel subagent's records, a queued message — changes nothing, because
    /// nothing on this path reads growth.
    @Test func aWaitingColumnIsReportedWithItsBlockByTheRPC() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            label: "claude", kind: .claude, transport: .holder)
        let path = try writeTranscript(
            fixture, name: "prompt.jsonl",
            lines: [#"{"type":"assistant","message":{"usage":{"input_tokens":10}}}"#])
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: "sess-prompt", transcriptPath: path)

        let block = ProgramStatusBlock(kind: .permission, taskID: nil)
        // Whole seconds: the column stores milliseconds.
        let reportedAt = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try #require(try await fixture.db.terminals.applyProgramStatusActivity(
            id: terminal.id, scope: .anyLiveIncarnation, activityState: .waitingForUser,
            awaitingInputReason: AwaitingInputReason(message: "", programStatusBlock: block),
            observedAt: reportedAt))

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"user","message":{"role":"user"}}"#.utf8))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        let report = try #require(try await states(fixture).first)
        guard case .awaitingInput(let reason) = report.state.value else {
            Issue.record("expected .awaitingInput, got \(report.state.value)")
            return
        }
        #expect(reason?.programStatusBlock == block)
        #expect(report.state.source == .programStatus)
        #expect(report.state.observedAt == reportedAt)
    }

    /// The cheap-path property, asserted rather than assumed: a pass over a
    /// live holder Claude row starts no process, reads no screen, types
    /// nothing, reads no process table, signals nothing and builds no reader
    /// for the session. That is what lets this method be called on a cadence
    /// for every agent at once.
    ///
    /// Each of those, made through a seam the router, its lifecycle or its
    /// holder registry owns, records into `touches`, and the last assertion
    /// shows the fixture wired every such seam — so the empty record speaks
    /// for all of them. It cannot speak for a subprocess started without a
    /// seam, such as a direct `ProcessTableSnapshot.read()` or a `Process`
    /// launched in the handler: `HolderTouchRecorder` lists what it cannot
    /// see.
    @Test func performsNoSubprocessOrScreenRead() async throws {
        let touches = HolderTouchRecorder()
        let holder = FakeHolderLaunch()
        let fixture = try await makeFixture(touches: touches, holder: holder)
        defer { fixture.cleanUp() }

        // Pids above macOS's PID_MAX, so none can name a real process.
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            label: "claude", kind: .claude, transport: .holder,
            holderPID: 100_001, childPID: 100_002)
        let path = try writeTranscript(
            fixture, name: "session.jsonl",
            lines: [#"{"type":"assistant","message":{"usage":{"input_tokens":1000}}}"#])
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: "sess-1", transcriptPath: path)

        let reports = try await states(fixture)

        #expect(reports.map(\.terminalID) == [terminal.id])
        #expect(touches.events.isEmpty,
                "session.states reached a holder session's process or screen: \(touches.events)")
        #expect(holder.launches.isEmpty)
        #expect(holder.abandonments.isEmpty)

        // The control: every seam the empty record above speaks for was
        // wired on this fixture, so reaching it would have recorded.
        let unwired = await touches.unwiredSeams(of: fixture.router)
        #expect(unwired.isEmpty,
                "left unwired, so the empty record says nothing about them: \(unwired)")
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

    @Test func contextLoadReportsAnUnknownWindowForASessionSpawnedWithoutUsage() async throws {
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
        // Nothing reports the window of a session spawned without the
        // session mod's `usage` feature, so it is reported as unknown.
        guard case .unknown = load.window else {
            Issue.record("expected an unknown window for a session spawned without usage, got \(load.window)")
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
