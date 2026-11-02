import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import DaemonTestSupport
import TestSupport

/// When the holder's job started, and the row's anchor: the same instant, so
/// the job sits inside `HolderChildIdentity.startWindow` of its row.
private let born = Date(timeIntervalSince1970: 1_800_000_000)

/// Tier 1: each hook-only RPC, driven through `RPCRouter.handle` with a
/// connection whose peer pid the test chooses and an injected process table.
/// No process is spawned or inspected, apart from the executable-name lookup
/// a refusal's log line makes.
///
/// One holder row: holder 100 under launchd, its job 200. Caller 300 runs
/// below the job, so it is inside the tab. Caller 400 sits directly under
/// launchd, so its whole ancestry is known and misses the job: proven
/// foreign. For each checked method a pair: the foreign caller changes no
/// state and gets the reply an unknown row gets; the inside caller changes
/// state as every hook did before the check existed.
///
/// Design: `docs/specs/2026-11-01-env-marker-attribution-design.md`, Part 2.
@Suite("Hook-caller guard in the router")
struct HookCallerGuardHandlerTests {
    private static let holderPID: Int32 = 100
    private static let jobPID: Int32 = 200
    private static let inside = RPCConnectionContext(peerPID: 300)
    private static let foreign = RPCConnectionContext(peerPID: 400)

    private static func table() -> ProcessTableSnapshot {
        ProcessTableSnapshot(entries: [
            100: .init(parent: 1, startedAt: born),
            200: .init(parent: 100, startedAt: born),
            300: .init(parent: 200, startedAt: born),
            400: .init(parent: 1, startedAt: born),
        ])
    }

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let worktreeID: UUID
        let terminal: TBDShared.Terminal
    }

    /// A worktree with one holder-backed Claude row whose job anchors a walk,
    /// and a router that reads the literal table. The PR seams answer for a
    /// github.com repo without spawning `gh`, and the limit-resume scheduler
    /// is installed but never started.
    private func makeFixture() async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let processes = Self.table()
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            prManager: PRStatusManager(ghRunner: { _, _ in
                Issue.record("pr.attach must not spawn gh")
                return nil
            }),
            prBindingRepoResolver: { _ in (owner: "acme", name: "acme-prod", host: "github.com") },
            actuationLog: makeTestActuationLog(),
            processTableReader: { processes })
        router.limitResumeScheduler = LimitResumeScheduler(
            store: db.scheduledResumes, config: db.config,
            actuator: FakeActuator(), clock: TestPollerClock(),
            jitterProvider: { 0 }, onOutcome: { _, _ in })
        let repo = try await db.repos.create(
            path: "/tmp/hook-caller-repo-\(UUID().uuidString)",
            displayName: "acme-prod", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-feature", branch: "tbd/acme-feature",
            path: "/tmp/hook-caller-wt-\(UUID().uuidString)", tmuxServer: "tbd-hook-caller")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            label: TerminalLabel.claudeCode, kind: .claude, transport: .holder,
            holderPID: Self.holderPID, childPID: Self.jobPID, holderChildStartedAt: born)
        return Fixture(db: db, router: router, worktreeID: worktree.id, terminal: terminal)
    }

    // MARK: - terminal.sessionEvent

    private func sessionStart(_ f: Fixture) throws -> RPCRequest {
        try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: f.terminal.id, sessionID: "other-session",
                transcriptPath: nil, source: "startup"))
    }

    /// Discriminates: before the check, this SessionStart bound the row to
    /// `other-session` and stamped the activity ledger.
    @Test func aForeignSessionStartLeavesTheSessionAlone() async throws {
        let f = try await makeFixture()
        await f.router.activityLedger.setEnabled(true)

        let response = await f.router.handle(try sessionStart(f), connection: Self.foreign)

        #expect(response.success)
        #expect(response.result == nil)
        #expect(try await f.db.terminals.get(id: f.terminal.id)?.claudeSessionID == nil)
        #expect(await f.router.activityLedger.snapshot().hooks[f.terminal.id] == nil)
    }

    @Test func anInsideSessionStartBindsTheSession() async throws {
        let f = try await makeFixture()
        await f.router.activityLedger.setEnabled(true)

        let response = await f.router.handle(try sessionStart(f), connection: Self.inside)

        #expect(response.success)
        #expect(try await f.db.terminals.get(id: f.terminal.id)?.claudeSessionID == "other-session")
        #expect(await f.router.activityLedger.snapshot().hooks[f.terminal.id] != nil)
    }

    /// A request that reached the router without a socket has no peer pid,
    /// and that is "cannot tell", never "foreign". Passes against the code
    /// before the check too; it fails against a guard that fails closed.
    @Test func aNilConnectionAcceptsAsToday() async throws {
        let f = try await makeFixture()

        let response = await f.router.handle(try sessionStart(f))

        #expect(response.success)
        #expect(try await f.db.terminals.get(id: f.terminal.id)?.claudeSessionID == "other-session")
    }

    // MARK: - terminal.sessionEnded

    private func openPrompt(terminalID: UUID, in f: Fixture) async {
        _ = await f.router.pendingQuestions.open(
            terminalID: terminalID, sessionID: "s1", toolUseID: "toolu_1", toolName: "Bash",
            toolInputJSON: #"{"command":"ls"}"#, suggestionsJSON: nil)
    }

    private func sessionEnd(terminalID: UUID) throws -> RPCRequest {
        try RPCRequest(
            method: RPCMethod.terminalSessionEnded,
            params: TerminalSessionEndedParams(terminalID: terminalID, reason: "clear"))
    }

    /// Discriminates: before the check, every session end resolved the
    /// terminal's open prompts, whoever sent it.
    @Test func aForeignSessionEndLeavesThePromptsOpen() async throws {
        let f = try await makeFixture()
        await openPrompt(terminalID: f.terminal.id, in: f)

        let response = await f.router.handle(
            try sessionEnd(terminalID: f.terminal.id), connection: Self.foreign)

        #expect(response.success)
        #expect(response.result == nil)
        #expect(await f.router.pendingQuestions.prompts(forTerminal: f.terminal.id).count == 1)
    }

    @Test func anInsideSessionEndResolvesThePrompts() async throws {
        let f = try await makeFixture()
        await openPrompt(terminalID: f.terminal.id, in: f)

        let response = await f.router.handle(
            try sessionEnd(terminalID: f.terminal.id), connection: Self.inside)

        #expect(response.success)
        #expect(await f.router.pendingQuestions.prompts(forTerminal: f.terminal.id).isEmpty)
    }

    /// With no row there is nothing to check a caller against, so the prompts
    /// are resolved exactly as before, even for a caller that would be
    /// foreign to any row. Fails against a handler that returns early, or
    /// refuses, when the row lookup finds nothing.
    @Test func sessionEndedForAnUnknownRowBehavesAsToday() async throws {
        let f = try await makeFixture()
        let unknown = UUID()
        await openPrompt(terminalID: unknown, in: f)

        let response = await f.router.handle(
            try sessionEnd(terminalID: unknown), connection: Self.foreign)

        #expect(response.success)
        #expect(await f.router.pendingQuestions.prompts(forTerminal: unknown).isEmpty)
    }

    // MARK: - terminal.askUserQuestionPending

    private func questionPending(_ f: Fixture) throws -> RPCRequest {
        try RPCRequest(
            method: RPCMethod.terminalAskUserQuestionPending,
            params: TerminalAskUserQuestionPendingParams(
                terminalID: f.terminal.id, toolUseID: "toolu_q",
                inputJSON: #"{"questions":[{"question":"Pick one","header":"H","options":[],"multiSelect":false}]}"#,
                timestampMillis: 1_800_000_000_000))
    }

    /// Discriminates: before the check, the question was stored for the tab
    /// and, on a session that does not report its own state, raised an
    /// attention notification.
    @Test func aForeignPendingQuestionIsNotStored() async throws {
        let f = try await makeFixture()

        let response = await f.router.handle(try questionPending(f), connection: Self.foreign)

        #expect(response.success)
        #expect(response.result == nil)
        #expect(await f.router.pendingQuestions.entries(forTerminal: f.terminal.id).isEmpty)
        #expect(try await f.db.notifications.unread(worktreeID: f.worktreeID).isEmpty)
    }

    @Test func anInsidePendingQuestionIsStored() async throws {
        let f = try await makeFixture()

        let response = await f.router.handle(try questionPending(f), connection: Self.inside)

        #expect(response.success)
        #expect(await f.router.pendingQuestions.entries(forTerminal: f.terminal.id).count == 1)
        #expect(try await f.db.notifications.unread(worktreeID: f.worktreeID).count == 1)
    }

    // MARK: - terminal.askUserQuestionCleared

    private func questionCleared(_ f: Fixture) throws -> RPCRequest {
        try RPCRequest(
            method: RPCMethod.terminalAskUserQuestionCleared,
            params: TerminalAskUserQuestionClearedParams(
                terminalID: f.terminal.id, toolUseID: "toolu_q"))
    }

    /// Discriminates: before the check, a cleared question marked the
    /// worktree's notifications read, whoever sent it.
    @Test func aForeignClearedQuestionMarksNothingRead() async throws {
        let f = try await makeFixture()
        _ = try await f.db.notifications.create(
            worktreeID: f.worktreeID, type: .attentionNeeded, message: "Pick one")

        let response = await f.router.handle(try questionCleared(f), connection: Self.foreign)

        #expect(response.success)
        #expect(response.result == nil)
        #expect(try await f.db.notifications.unread(worktreeID: f.worktreeID).count == 1)
    }

    @Test func anInsideClearedQuestionMarksTheWorktreeRead() async throws {
        let f = try await makeFixture()
        _ = try await f.db.notifications.create(
            worktreeID: f.worktreeID, type: .attentionNeeded, message: "Pick one")

        let response = await f.router.handle(try questionCleared(f), connection: Self.inside)

        #expect(response.success)
        #expect(try await f.db.notifications.unread(worktreeID: f.worktreeID).isEmpty)
    }

    // MARK: - claude.rateLimitDetected

    private func rateLimit(_ f: Fixture) throws -> RPCRequest {
        try RPCRequest(
            method: RPCMethod.claudeRateLimitDetected,
            params: RateLimitDetectedParams(
                terminalID: f.terminal.id, resetsAt: born.addingTimeInterval(3600),
                limitType: "session", rawMessage: "session limit"))
    }

    /// Discriminates: before the check, a usage limit always recorded an
    /// audit row and posted a `limitReached` notification on the tab.
    @Test func aForeignRateLimitPostsNothing() async throws {
        let f = try await makeFixture()

        let response = await f.router.handle(try rateLimit(f), connection: Self.foreign)

        #expect(response.success)
        #expect(response.result == nil)
        #expect(try await f.db.notifications.unread(worktreeID: f.worktreeID).isEmpty)
        #expect(try await f.db.scheduledResumes.all(terminalID: f.terminal.id).isEmpty)
    }

    @Test func anInsideRateLimitPostsTheNotification() async throws {
        let f = try await makeFixture()

        let response = await f.router.handle(try rateLimit(f), connection: Self.inside)

        #expect(response.success)
        let types = try await f.db.notifications.unread(worktreeID: f.worktreeID).map(\.type)
        #expect(types == [.limitReached])
    }

    // MARK: - claude.transientApiErrorDetected

    private func transientError(_ f: Fixture) throws -> RPCRequest {
        try RPCRequest(
            method: RPCMethod.claudeTransientApiErrorDetected,
            params: TransientApiErrorDetectedParams(
                terminalID: f.terminal.id, errorClass: "overloaded",
                rawMessage: "API Error: 529 overloaded"))
    }

    /// Discriminates: with auto-continue on, the error was handled before the
    /// check — a resume scheduled and a notification posted on the tab.
    @Test func aForeignTransientErrorIsNotHandled() async throws {
        let f = try await makeFixture()
        try await f.db.config.setAutoResumeOnApiError(true)

        let response = await f.router.handle(try transientError(f), connection: Self.foreign)

        #expect(response.success)
        #expect(try response.decodeResult(TransientApiErrorDetectedResult.self).handled == false)
        #expect(try await f.db.scheduledResumes.pending(terminalID: f.terminal.id) == nil)
        #expect(try await f.db.notifications.unread(worktreeID: f.worktreeID).isEmpty)
    }

    @Test func anInsideTransientErrorIsHandled() async throws {
        let f = try await makeFixture()
        try await f.db.config.setAutoResumeOnApiError(true)

        let response = await f.router.handle(try transientError(f), connection: Self.inside)

        #expect(response.success)
        #expect(try response.decodeResult(TransientApiErrorDetectedResult.self).handled == true)
        #expect(try await f.db.scheduledResumes.pending(terminalID: f.terminal.id) != nil)
    }

    // MARK: - terminal.sessionTitle

    private func sessionTitle(_ f: Fixture) throws -> RPCRequest {
        try RPCRequest(
            method: RPCMethod.terminalSessionTitle,
            params: TerminalSessionTitleParams(
                terminalID: f.terminal.id, sessionIncarnationID: f.terminal.sessionIncarnationID))
    }

    /// Discriminates: before the check, the first prompt from any caller
    /// claimed the tab's title, so the tab's own session could miss it.
    @Test func aForeignPromptClaimsNoTitle() async throws {
        let f = try await makeFixture()

        let response = await f.router.handle(try sessionTitle(f), connection: Self.foreign)

        #expect(response.success)
        #expect(response.result == nil)
        #expect(await f.router.lifecycle.sessionTitles.lastApplied(terminalID: f.terminal.id) == nil)
    }

    @Test func anInsidePromptClaimsTheTitle() async throws {
        let f = try await makeFixture()

        let response = await f.router.handle(try sessionTitle(f), connection: Self.inside)

        #expect(response.success)
        #expect(try response.decodeResult(TerminalSessionTitleResult.self).sessionTitle == "acme-feature")
        #expect(await f.router.lifecycle.sessionTitles.lastApplied(terminalID: f.terminal.id) == "acme-feature")
    }

    // MARK: - pr.attach

    private func attach(_ f: Fixture, source: PRBindingSource) throws -> RPCRequest {
        try RPCRequest(
            method: RPCMethod.prAttach,
            params: PRBindingRefParams(
                worktreeID: f.worktreeID, url: "https://github.com/acme/acme-prod/pull/412",
                source: source.rawValue))
    }

    /// Discriminates: before the check, `pr bind --from-hook` bound the PR to
    /// whichever worktree the caller's inherited `TBD_WORKTREE_ID` named.
    @Test func aForeignHookAttachBindsNothing() async throws {
        let f = try await makeFixture()

        let response = await f.router.handle(try attach(f, source: .hook), connection: Self.foreign)

        #expect(response.success)
        #expect(response.result == nil)
        #expect(try await f.db.prBindings.list(worktreeID: f.worktreeID, includeDetached: true).isEmpty)
    }

    @Test func anInsideHookAttachBinds() async throws {
        let f = try await makeFixture()

        let response = await f.router.handle(try attach(f, source: .hook), connection: Self.inside)

        #expect(response.success)
        #expect(try response.decodeResult(PRAttachResult.self).outcome == "bound")
        let numbers = try await f.db.prBindings.list(worktreeID: f.worktreeID).map(\.number)
        #expect(numbers == [412])
    }

    /// Only a hook-sourced attach is checked: a manual one is a person naming
    /// the worktree. Fails against a guard that checked every source.
    @Test func aManualPRAttachFromAForeignPeerStillBinds() async throws {
        let f = try await makeFixture()

        let response = await f.router.handle(try attach(f, source: .manual), connection: Self.foreign)

        #expect(response.success)
        #expect(try response.decodeResult(PRAttachResult.self).outcome == "bound")
        let numbers = try await f.db.prBindings.list(worktreeID: f.worktreeID).map(\.number)
        #expect(numbers == [412])
    }
}
