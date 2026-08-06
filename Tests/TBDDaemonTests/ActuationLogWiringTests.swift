import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — dry-run tmux plus a real (temp-directory) actuation log.
///
/// These prove the wiring rather than the writer: that each surface appends
/// exactly one request row naming the right kind, method and actor, that the
/// outcome row confirms it, and that an unwritable record refuses the act
/// instead of performing it silently.
@Suite("Actuation log wiring")
struct ActuationLogWiringTests {

    // MARK: - Fixture

    private struct Fixture {
        let router: RPCRouter
        let db: TBDDatabase
        let logPath: String
    }

    private func makeFixture(
        logPath: String? = nil,
        paneTarget: (@Sendable (String, String) throws -> PaneSendTarget)? = nil
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = logPath ?? directory.appendingPathComponent("actuations.jsonl").path

        let db = try TBDDatabase(inMemory: true)
        let tmux = TmuxManager(dryRun: true, dryRunPaneSendTarget: paneTarget)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: tmux,
                hooks: HookResolver()
            ),
            tmux: tmux,
            startTime: Date(),
            actuationLog: ActuationLog(path: path)
        )
        return Fixture(router: router, db: db, logPath: path)
    }

    /// A path that can never be opened: its parent is a regular file.
    private func makeUnwritablePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        return blocker.appendingPathComponent("actuations.jsonl").path
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

    private func makeWorktree(in db: TBDDatabase) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        return try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
    }

    // MARK: - terminal.send

    @Test("terminal.send writes one send request and one dispatched outcome")
    func sendWritesRequestAndOutcome() async throws {
        let fixture = try makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminal.id, text: "rebase onto main", submit: true),
            actor: ActuationActor.session(
                worktree: worktree.id.uuidString, terminal: terminal.id.uuidString)))
        #expect(response.success)

        let written = try rows(at: fixture.logPath)
        #expect(written.count == 2)
        let request = try #require(written.first)
        #expect(request["kind"] as? String == "send")
        #expect(request["method"] as? String == "terminal.send")
        // Payload verbatim: a stale premise stays visible, never filtered.
        #expect(request["message"] as? String == "rebase onto main")
        #expect(request["submit"] as? Bool == true)
        let target = try #require(request["target"] as? [String: Any])
        #expect(target["worktree"] as? String == worktree.id.uuidString)
        #expect(target["terminal"] as? String == terminal.id.uuidString)
        let actor = try #require(request["actor"] as? [String: Any])
        #expect(actor["kind"] as? String == "session")
        #expect(actor["terminal"] as? String == terminal.id.uuidString)

        let outcome = try #require(written.last)
        #expect(outcome["kind"] as? String == "outcome")
        #expect(outcome["confirms"] as? String == request["id"] as? String)
        #expect(outcome["result"] as? String == "dispatched")
        // Only a refusal has a reason to name.
        #expect(outcome["reason"] == nil)
    }

    @Test("a request declaring no identity is recorded as anonymous, explicitly")
    func undeclaredCallerIsAnonymous() async throws {
        let fixture = try makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        _ = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminal.id, text: "hello", submit: false)))

        let request = try #require(try rows(at: fixture.logPath).first)
        let actor = try #require(request["actor"] as? [String: Any])
        #expect(Set(actor.keys) == ["kind"])
        #expect(actor["kind"] as? String == "anonymous")
    }

    @Test("the app's declaration rides through the router untouched")
    func appActorRecorded() async throws {
        let fixture = try makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        _ = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminal.id, text: "hi", submit: false),
            actor: .app))

        let request = try #require(try rows(at: fixture.logPath).first)
        #expect((request["actor"] as? [String: Any])?["kind"] as? String == "app")
    }

    @Test("a send to a terminal that does not exist acts on nothing and records nothing")
    func missingTargetWritesNoRow() async throws {
        let fixture = try makeFixture()
        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: UUID(), text: "hi", submit: false)))
        #expect(!response.success)
        #expect(try rows(at: fixture.logPath).isEmpty)
    }

    // MARK: - spawn / dispose

    @Test("terminal.create writes a spawn row naming the terminal it is about to mint")
    func createWritesSpawnRow() async throws {
        let fixture = try makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktree.id, cmd: "ls", type: .shell),
            actor: .app))
        #expect(response.success)
        let created = try response.decodeResult(Terminal.self)

        let written = try rows(at: fixture.logPath)
        #expect(written.count == 2)
        let request = try #require(written.first)
        #expect(request["kind"] as? String == "spawn")
        #expect(request["method"] as? String == "terminal.create")
        #expect(request["agent"] as? String == "shell")
        let target = try #require(request["target"] as? [String: Any])
        // The row was written BEFORE the spawn, and still names the row that
        // came out of it — that is what pre-minting the id buys.
        #expect(target["terminal"] as? String == created.id.uuidString)
        #expect(written.last?["result"] as? String == "dispatched")
    }

    /// A spawn the daemon declines *after* the row is written — the request row
    /// still stands, and its outcome says refused rather than being left
    /// unconfirmed. (The worktree-not-found and archived-worktree checks sit
    /// ahead of the row and write nothing at all; this is the first refusal
    /// downstream of it.)
    @Test("a spawn the daemon declines after the row is written reads as refused")
    func createRefusalIsConfirmedAsRefused() async throws {
        let fixture = try makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)

        // A login session with no profile to log into: the daemon refuses
        // before it touches the transport.
        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(
                worktreeID: worktree.id, type: .claude, loginSession: true),
            actor: .app))
        #expect(!response.success)

        let written = try rows(at: fixture.logPath)
        #expect(written.count == 2)
        #expect(written.first?["kind"] as? String == "spawn")
        #expect(written.first?["method"] as? String == "terminal.create")
        let outcome = try #require(written.last)
        #expect(outcome["result"] as? String == "refused")
        // A decline, not an idempotent no-op — and the record says which
        // without anyone having to read the detail string.
        #expect(outcome["reason"] as? String == "not-eligible")
        #expect(outcome["error"] as? String == response.error)
        // Refused means refused: no terminal row came out of it.
        #expect(try await fixture.db.terminals.list(worktreeID: worktree.id).isEmpty)
    }

    @Test("terminal.delete writes a dispose row")
    func deleteWritesDisposeRow() async throws {
        let fixture = try makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminal.id),
            actor: .app))
        #expect(response.success)

        let written = try rows(at: fixture.logPath)
        #expect(written.count == 2)
        #expect(written.first?["kind"] as? String == "dispose")
        #expect(written.first?["method"] as? String == "terminal.delete")
        #expect(written.last?["result"] as? String == "dispatched")
    }

    @Test("closing an already-gone terminal acts on nothing and records nothing")
    func deleteOfAbsentTerminalWritesNoRow() async throws {
        let fixture = try makeFixture()
        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: UUID())))
        #expect(response.success)
        #expect(try rows(at: fixture.logPath).isEmpty)
    }

    // MARK: - park / wake, including the legacy shims

    @Test("terminal.hibernate writes a hibernate row, and a decline reads as refused")
    func hibernateWritesRefusedOutcomeForIneligibleTarget() async throws {
        let fixture = try makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        // A plain shell terminal is not manually hibernatable — the daemon
        // declines before it touches the transport.
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        _ = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalHibernate,
            params: TerminalHibernateParams(terminalID: terminal.id),
            actor: .app))

        let written = try rows(at: fixture.logPath)
        #expect(written.count == 2)
        #expect(written.first?["kind"] as? String == "hibernate")
        #expect(written.first?["method"] as? String == "terminal.hibernate")
        #expect(written.last?["result"] as? String == "refused")
        #expect(written.last?["reason"] as? String == "not-eligible")
        #expect(written.last?["error"] as? String != nil)
    }

    @Test("the legacy terminal.suspend shim records kind hibernate under its own method")
    func legacySuspendKeepsItsMethod() async throws {
        let fixture = try makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        _ = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSuspend,
            params: TerminalSuspendParams(terminalID: terminal.id)))

        let request = try #require(try rows(at: fixture.logPath).first)
        #expect(request["kind"] as? String == "hibernate")
        #expect(request["method"] as? String == "terminal.suspend")
    }

    @Test("terminal.wake writes a wake row carrying the prompt it would type")
    func wakeCarriesPrompt() async throws {
        let fixture = try makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        _ = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id, prompt: "carry on")))

        let written = try rows(at: fixture.logPath)
        let request = try #require(written.first)
        #expect(request["kind"] as? String == "wake")
        #expect(request["method"] as? String == "terminal.wake")
        #expect(request["prompt"] as? String == "carry on")
        // Nothing was parked, so the daemon declined without touching tmux —
        // and waking something that was never parked is the idempotent no-op,
        // not a decline the operator's controls made.
        #expect(written.last?["result"] as? String == "refused")
        #expect(written.last?["reason"] as? String == "noop")
    }

    /// A wake at a row that claims awake but whose pane is GONE must land in
    /// the record as `not-found`, not the benign `noop` above. The two are one
    /// character apart in the JSONL and mean opposite things to anyone auditing
    /// what the daemon actually did.
    @Test("a wake at a vanished pane records not-found, not the benign no-op")
    func wakeAtMissingPaneRecordsNotFound() async throws {
        let fixture = try makeFixture(paneTarget: { _, _ in .missing })
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        _ = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id)))

        let written = try rows(at: fixture.logPath)
        #expect(written.last?["result"] as? String == "refused")
        #expect(written.last?["reason"] as? String == "not-found")
    }

    /// Pane-id reuse (#384): the coordinate resolved to a live STRANGER. The
    /// record has to be able to say that happened — `not-found` would claim the
    /// named target is gone when a healthy other one answered.
    @Test("a wake whose pane answers as another terminal records target-mismatch")
    func wakeAtReusedPaneRecordsTargetMismatch() async throws {
        let stranger = UUID().uuidString
        let fixture = try makeFixture(paneTarget: { _, _ in .live(terminalID: stranger) })
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        _ = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminal.id)))

        let written = try rows(at: fixture.logPath)
        #expect(written.last?["result"] as? String == "refused")
        #expect(written.last?["reason"] as? String == "target-mismatch")
    }

    @Test("worktree.resume fans out one row per parked terminal")
    func worktreeResumeFansOutPerTerminal() async throws {
        let fixture = try makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        for index in 1...2 {
            let terminal = try await fixture.db.terminals.create(
                worktreeID: worktree.id, tmuxWindowID: "@\(index)", tmuxPaneID: "%\(index)",
                label: TerminalLabel.claudeCode, claudeSessionID: "session-\(index)", kind: .claude)
            try await fixture.db.terminals.setHibernated(
                id: terminal.id, sessionID: "session-\(index)")
        }

        _ = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.worktreeResume,
            params: WorktreeResumeParams(worktreeID: worktree.id)))

        let requests = try rows(at: fixture.logPath).filter { $0["kind"] as? String == "wake" }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0["method"] as? String == "worktree.resume" })
        let terminals = Set(requests.compactMap { ($0["target"] as? [String: Any])?["terminal"] as? String })
        #expect(terminals.count == 2)
    }

    // MARK: - Fail-closed

    @Test("an unwritable record refuses the send with the self-explaining error")
    func unwritableRecordRefusesSend() async throws {
        let fixture = try makeFixture(logPath: try makeUnwritablePath())
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminal.id, text: "hi", submit: true)))

        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains(fixture.logPath))
        #expect(error.contains("actuation log"))
        #expect(error.contains("TBD will recreate it"))
    }

    @Test("an unwritable record refuses the spawn — the terminal is never created")
    func unwritableRecordRefusesSpawn() async throws {
        let fixture = try makeFixture(logPath: try makeUnwritablePath())
        let worktree = try await makeWorktree(in: fixture.db)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktree.id, cmd: "ls", type: .shell)))

        #expect(!response.success)
        #expect(try #require(response.error).contains("actuation log"))
        // The act did not proceed: no terminal row exists.
        #expect(try await fixture.db.terminals.list(worktreeID: worktree.id).isEmpty)
    }

    @Test("recovery: once the record is writable again, the next act goes through")
    func recoversOnceRecordIsWritableAgain() async throws {
        let fixture = try makeFixture()
        let worktree = try await makeWorktree(in: fixture.db)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1")

        func send() async -> RPCResponse {
            await fixture.router.handle(try! RPCRequest(
                method: RPCMethod.terminalSend,
                params: TerminalSendParams(terminalID: terminal.id, text: "hi", submit: false)))
        }

        #expect(await send().success)
        // Someone moved the whole directory aside between acts.
        try FileManager.default.removeItem(
            atPath: (fixture.logPath as NSString).deletingLastPathComponent)
        #expect(await send().success)
        #expect(try rows(at: fixture.logPath).count == 2)
    }

    // MARK: - The wired set

    @Test("every wired surface names a real RPC method and a kind in the vocabulary")
    func surfaceMapIsWellFormed() {
        let kinds: Set<ActuationKind> = [.send, .wake, .hibernate, .spawn, .dispose]
        var methods = Set<String>()
        for surface in ActuationSurface.allCases {
            #expect(!surface.method.isEmpty)
            #expect(surface.method.contains("."))
            #expect(kinds.contains(surface.kind))
            methods.insert(surface.method)
        }
        // One surface per method — no two enum cases claim the same door.
        #expect(methods.count == ActuationSurface.allCases.count)
        // `outcome` is the daemon's own confirmation rung; no surface produces it.
        #expect(!ActuationSurface.allCases.contains { $0.kind == .outcome })
    }
}
