import Clocks
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — dry-run tmux, an in-memory database, a `TestClock` for the
/// readiness ceiling and the settle.
///
/// `docs/specs/2026-08-10-queued-prompt-on-create-design.md`: a parked prompt
/// reaches its agent by the one delivery path — a paste, once, behind the
/// `SessionStart` hook and the measured settle — and reaches nobody at all
/// while the soak flag is off.
///
/// The invariant most of these tests exist for: **the coordinator, after a
/// paste it watched succeed, is the only thing that clears the column.**
/// `spawnPrimaryTerminals` neither reads it nor writes it.
@Suite("Queued prompt delivery", .clockDriven)
struct QueuedPromptDeliveryTests {

    // MARK: - Recorders

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
        /// Just the shell-command bodies — the last argv element of each
        /// `new-window` call, which is where a spawn's trailing prompt would
        /// land if anything still put one there.
        var shellBodies: String { calls.compactMap { $0.last }.joined(separator: "\n") }
        var joinedAll: String {
            calls.map { $0.joined(separator: " ") }.joined(separator: "\n")
        }
    }

    /// Collects the payloads handed to `pasteText`; the argv cannot carry them
    /// (the real path passes the body through a temp file).
    private final class PasteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _pastes: [String] = []
        var pastes: [String] {
            lock.lock(); defer { lock.unlock() }
            return _pastes
        }
        func record(_ bytes: Data) {
            lock.lock(); defer { lock.unlock() }
            _pastes.append(String(decoding: bytes, as: UTF8.self))
        }
    }

    /// Stands in for the daemon-internal send seam, so "the coordinator asked
    /// for exactly this text, exactly once" is assertable without a pane.
    private final class SendRecorder: @unchecked Sendable {
        struct Call: Sendable, Equatable {
            let terminalID: UUID
            let text: String
            let submit: Bool
        }
        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _succeeds = true
        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _calls.count
        }
        func failEverySend() {
            lock.lock(); defer { lock.unlock() }
            _succeeds = false
        }
        func record(_ call: Call) -> Bool {
            lock.lock(); defer { lock.unlock() }
            _calls.append(call)
            return _succeeds
        }
    }

    /// "Has this happened before?", answered once. For dry-run tmux hooks,
    /// which are synchronous and fire for every window a spawn creates.
    private final class FirstTime: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if seen { return false }
            seen = true
            return true
        }
    }

    /// A one-shot release, so a test can hold a delivery open and act while it
    /// is suspended — which is where every straddled-`await` defect lives.
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            open = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    /// Bounded stand-in for `awaitPendingDeliveries()`. Poll the coordinator's
    /// actual in-flight state so a separate wrapper task cannot itself be
    /// starved after the deliveries finish. A cycle whose continuation was
    /// orphaned never retires, and the plain await would then hang the whole
    /// run rather than attribute the defect; this records a named failure
    /// instead. Tier-2 bounded polling, per `Tests/CLAUDE.md`.
    private func awaitDeliveries(
        _ coordinator: PendingPromptCoordinator,
        within seconds: Double = 20,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await coordinator.inFlightCycleCount == 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if await coordinator.inFlightCycleCount == 0 { return }
        Issue.record(
            """
            a delivery cycle never retired within \(seconds)s — a superseded cycle's \
            continuation was orphaned and its task is suspended forever
            """,
            sourceLocation: sourceLocation)
    }

    /// Drive the settle the delivery waits out before it types
    /// (`pendingPromptSettleDelay`), and return once `condition` holds —
    /// normally "the bytes reached the pane".
    ///
    /// A loop rather than a single `advanceWhenSuspended`, because the
    /// readiness ceiling sleeps on the same clock: "some task is suspended" can
    /// be true of the wrong sleeper, and one advance would then move `now` past
    /// a settle deadline that had not been registered yet — the permanent
    /// desync `Tests/CLAUDE.md` names. Advancing a settle at a time converges
    /// whichever sleeper is parked.
    ///
    /// The condition, not a fixed number of advances, is what stops it: a test
    /// that expects a paste must not also silently buy an expired ceiling.
    private func advancePastSettle(
        _ clock: TestClock<Duration>,
        until description: String = "the settle expired and the paste happened",
        within seconds: Double = 20,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            await clock.advance(by: PendingPromptCoordinator.pendingPromptSettleDelay)
            try? await Task.sleep(for: .milliseconds(2))
        }
        // The wall deadline bounds a missing condition; it must not veto a
        // monotone success that completed while this polling task was starved.
        if await condition() { return }
        Issue.record(
            "timed out after \(seconds)s waiting until \(description)",
            sourceLocation: sourceLocation)
    }

    /// The spawn-fixture form: return once the send seam has been called
    /// `count` times.
    private func advancePastSettle(
        _ clock: TestClock<Duration>, _ fixture: SpawnFixture, sends count: Int = 1,
        within seconds: Double = 20,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await advancePastSettle(
            clock, until: "the coordinator had made \(count) send(s)", within: seconds,
            sourceLocation: sourceLocation
        ) { fixture.sends.callCount >= count }
    }

    /// The wired-fixture form: return once `count` payloads have reached the
    /// pane through the real send core.
    private func advancePastSettle(
        _ clock: TestClock<Duration>, _ fixture: SendFixture, pastes count: Int = 1,
        within seconds: Double = 20,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await advancePastSettle(
            clock, until: "\(count) paste(s) reached the pane", within: seconds,
            sourceLocation: sourceLocation
        ) { fixture.pastes.pastes.count >= count }
    }

    /// The refusal form: drive the settle until the delivery has spoken to the
    /// operator instead of typing.
    ///
    /// A delivery that refuses at the guard immediately before the send makes
    /// no send to wait on, so "the seam was called" cannot be the stop
    /// condition — its notification is the observable, and the same loop that
    /// converges the settle converges this.
    private func advanceUntilNotified(
        _ clock: TestClock<Duration>, _ fixture: SpawnFixture,
        within seconds: Double = 20,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await advancePastSettle(
            clock, until: "the delivery notified instead of typing", within: seconds,
            sourceLocation: sourceLocation
        ) {
            let notices = try? await fixture.db.notifications.unread(
                worktreeID: fixture.worktree.id)
            return !(notices ?? []).isEmpty
        }
    }

    /// Bounded poll on a condition the coordinator answers.
    private func waitUntil(
        _ description: String,
        within seconds: Double = 20,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if await condition() { return }
        Issue.record(
            "timed out after \(seconds)s waiting until \(description)",
            sourceLocation: sourceLocation)
    }

    // MARK: - Fixtures

    private func isolatedConfigDirManager() -> ClaudeProfileConfigDirManager {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-qp-claude-\(UUID().uuidString)", isDirectory: true)
        return ClaudeProfileConfigDirManager(
            baseDirectory: home.appendingPathComponent("profiles", isDirectory: true),
            hostBaseDirectory: home.appendingPathComponent("claude-host", isDirectory: true))
    }

    private struct SpawnFixture {
        let lifecycle: WorktreeLifecycle
        let db: TBDDatabase
        let recorder: ArgvRecorder
        let coordinator: PendingPromptCoordinator
        let sends: SendRecorder
        let repo: Repo
        let worktree: Worktree
    }

    /// A `WorktreeLifecycle` wired to a coordinator whose send seam is a
    /// recorder, so `spawnPrimaryTerminals` can be driven directly.
    ///
    /// The clock defaults to a `TestClock` nobody advances: a readiness wait
    /// this suite does not care about then simply never expires, instead of
    /// parking a two-minute wall sleep in the test process.
    ///
    /// `attachCoordinator: false` leaves the lifecycle with no coordinator at
    /// all — the shape that isolates "what does the spawn path itself do to the
    /// column", with nothing else running that could write it.
    ///
    /// `gate`, when given, holds the FIRST delivery open so a test can act
    /// while the cycle is suspended mid-send.
    private func makeSpawnFixture(
        clock: any Clock<Duration> = TestClock(),
        attachCoordinator: Bool = true,
        gate: Gate? = nil
    ) async throws -> SpawnFixture {
        let recorder = ArgvRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: nil) })
        let db = try TBDDatabase(inMemory: true)
        let sends = SendRecorder()
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main", path: path, tmuxServer: "tbd-test")
        let coordinator = PendingPromptCoordinator(db: db, clock: clock)
        let firstDelivery = FirstTime()
        await coordinator.setDeliver { terminalID, text, submit in
            // Recorded before the gate, so a test can see that this delivery is
            // in flight and act while it is still suspended.
            let delivered = sends.record(SendRecorder.Call(
                terminalID: terminalID, text: text, submit: submit))
            if let gate, firstDelivery.claim() { await gate.wait() }
            return delivered
        }
        var lifecycle = WorktreeLifecycle(
            db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
            modelProfileResolver: ModelProfileResolver(
                profiles: db.modelProfiles, repos: db.repos, config: db.config),
            configDirManager: isolatedConfigDirManager())
        if attachCoordinator { lifecycle.pendingPromptCoordinator = coordinator }
        return SpawnFixture(
            lifecycle: lifecycle, db: db, recorder: recorder, coordinator: coordinator,
            sends: sends, repo: repo, worktree: worktree)
    }

    private struct SendFixture {
        let router: RPCRouter
        let db: TBDDatabase
        let terminal: Terminal
        let pastes: PasteRecorder
        let recorder: ArgvRecorder
        let actuationLogPath: String
        let transcriptPath: String
    }

    /// The same router fixture with a coordinator attached exactly the way the
    /// daemon attaches one, and driven only through RPC requests.
    ///
    /// Everything the production delivery needs is wiring: the send seam that
    /// `attachPendingPromptCoordinator` installs, and the readiness hook inside
    /// `terminal.sessionEvent`. Calling the actor directly proves none of it —
    /// each of those lines can be deleted with the actor-level tests still
    /// green and every real parked prompt silently dead.
    private func makeWiredFixture(
        clock: any Clock<Duration> = TestClock()
    ) async throws -> (fixture: SendFixture, coordinator: PendingPromptCoordinator) {
        let fixture = try await makeSendFixture()
        let coordinator = PendingPromptCoordinator(db: fixture.db, clock: clock)
        await fixture.router.attachPendingPromptCoordinator(coordinator)
        try await fixture.db.config.setQueuedPrompt(true)
        return (fixture, coordinator)
    }

    /// Fire the `SessionStart` hook's RPC — the readiness signal, as it
    /// actually reaches the daemon.
    private func sendSessionEvent(_ fixture: SendFixture) async throws {
        FileManager.default.createFile(atPath: fixture.transcriptPath, contents: Data())
        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: fixture.terminal.id, sessionID: UUID().uuidString,
                transcriptPath: fixture.transcriptPath, source: "startup")))
        #expect(response.success)
    }

    /// A router over a dry-run tmux with an agent terminal, for the questions
    /// only the real send core can answer: which bytes reach the pane, and
    /// whether an Enter follows them.
    private func makeSendFixture(kind: TerminalKind = .claude) async throws -> SendFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-qp-send-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recorder = ArgvRecorder()
        let pastes = PasteRecorder()
        let tmux = TmuxManager(
            dryRun: true,
            dryRunRecorder: { recorder.record($0) },
            dryRunPaneSendTarget: { _, _ in .live(terminalID: nil) },
            dryRunPasteBytes: { _, _, bytes in pastes.record(bytes) })
        let db = try TBDDatabase(inMemory: true)
        let actuationLogPath = directory.appendingPathComponent("actuations.jsonl").path
        let transcriptPath = directory.appendingPathComponent("transcript.jsonl").path
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: tmux, hooks: HookResolver(),
                configDirManager: isolatedConfigDirManager()),
            tmux: tmux,
            startTime: Date(),
            configDirManager: isolatedConfigDirManager(),
            actuationLog: ActuationLog(path: actuationLogPath))
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-acme")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@3", tmuxPaneID: "%7", kind: kind)
        return SendFixture(
            router: router, db: db, terminal: terminal, pastes: pastes, recorder: recorder,
            actuationLogPath: actuationLogPath, transcriptPath: transcriptPath)
    }

    private func pendingPrompt(
        _ db: TBDDatabase, _ worktreeID: UUID
    ) async throws -> String? {
        try await db.worktrees.get(id: worktreeID)?.pendingPrompt
    }

    /// A prompt with a newline, a single quote, a double quote **and a slash**.
    /// The one that matters live: a multi-line prompt is what the composer's
    /// paste-burst detection swallows inside the dead window, and a
    /// single-line prompt survives that window on its own and therefore proves
    /// nothing.
    private static let multiLinePrompt = """
        Fix the flake in acme's src/parser.swift.
        It's the "quoted" branch that reds.
        """

    // MARK: - Polling infrastructure

    @Test("the settle poll rechecks completion after the wall deadline")
    func settlePollRechecksAfterDeadline() async {
        await advancePastSettle(TestClock<Duration>(), within: 0) { true }
    }

    @Test("the delivery poll rechecks completion after the wall deadline")
    func deliveryPollRechecksAfterDeadline() async throws {
        let coordinator = PendingPromptCoordinator(db: try TBDDatabase(inMemory: true))

        await awaitDeliveries(coordinator, within: 0)
    }

    @Test("the condition poll rechecks completion after the wall deadline")
    func conditionPollRechecksAfterDeadline() async {
        await waitUntil("an already-complete condition", within: 0) { true }
    }

    // MARK: - Flag OFF

    /// With the flag off nothing reads the column — a value written by hand (or
    /// left behind by a soak that was then turned off) is ignored, not
    /// delivered late, and not announced either.
    @Test("flag off: a hand-written pending_prompt is never delivered")
    func flagOffSpawnIgnoresColumn() async throws {
        let fixture = try await makeSpawnFixture()
        try await fixture.db.worktrees.setPendingPrompt(
            worktreeID: fixture.worktree.id, text: "deliver me", submit: true)

        _ = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
            preSessionTerminalID: nil)
        await awaitDeliveries(fixture.coordinator)

        #expect(!fixture.recorder.shellBodies.contains("deliver me"))
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "deliver me")
        #expect(fixture.sends.calls.isEmpty)
        #expect(try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id).isEmpty)
    }

    @Test("flag off: worktree.setPendingPrompt is refused")
    func flagOffParkingRefused() async throws {
        let fixture = try await makeSpawnFixture()

        let result = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "deliver me", submit: true)

        guard case .refused(let reason) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(reason.contains("queued_prompt_enabled"))
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
    }

    /// The RPC route exists and speaks the refusal, not an error — the app
    /// branches on the result.
    @Test("flag off: the worktree.setPendingPrompt route answers a refusal")
    func flagOffRouteRefuses() async throws {
        let fixture = try await makeSendFixture()
        fixture.router.pendingPromptCoordinator = PendingPromptCoordinator(db: fixture.db)
        let worktreeID = fixture.terminal.worktreeID

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.worktreeSetPendingPrompt,
            params: WorktreeSetPendingPromptParams(
                worktreeID: worktreeID, text: "hello", submit: true)))

        #expect(response.success)
        let result = try response.decodeResult(WorktreeSetPendingPromptResult.self)
        guard case .refused = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
    }

    // MARK: - One writer, and it is not the spawn path

    /// **The invariant, isolated.** With no coordinator attached there is
    /// nothing else in the process that could touch the column, so this asserts
    /// what `spawnPrimaryTerminals` does to it by itself: nothing at all.
    ///
    /// It also asserts the other half — the text does not reach the command
    /// line — because "the spawn consumed it" and "the spawn delivered it"
    /// were the same act in the design this replaces. Restore either and this
    /// reds: a take clears the column, an argv puts the words in
    /// `shellBodies`.
    @Test("the spawn path neither reads nor writes the pending-prompt column")
    func spawnPathNeverTouchesTheColumn() async throws {
        let fixture = try await makeSpawnFixture(attachCoordinator: false)
        try await fixture.db.config.setQueuedPrompt(true)
        try await fixture.db.worktrees.setPendingPrompt(
            worktreeID: fixture.worktree.id, text: Self.multiLinePrompt, submit: true)

        _ = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
            preSessionTerminalID: nil)

        #expect(!fixture.recorder.shellBodies.contains("parser.swift"))
        let row = try await fixture.db.worktrees.get(id: fixture.worktree.id)
        #expect(row?.pendingPrompt == Self.multiLinePrompt)
        #expect(row?.pendingPromptSubmit == true)
    }

    /// The same claim with the coordinator present and the whole creation path
    /// driven: a caller-supplied prompt still owns the command line, and the
    /// parked one is neither on it nor consumed by the spawn.
    @Test("a caller's own create prompt is unaffected, and the parked one stays parked")
    func callerPromptStillRidesTheCommandLine() async throws {
        let fixture = try await makeSpawnFixture()
        try await fixture.db.config.setQueuedPrompt(true)
        #expect(await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "parked words",
            submit: true) == .parkedForSpawn)

        _ = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
            initialPrompt: "cli words", preSessionTerminalID: nil)

        #expect(fixture.recorder.shellBodies.contains("'cli words'"))
        #expect(!fixture.recorder.shellBodies.contains("parked words"))
        // Still recoverable: the pane exists but its hook has not fired, so
        // nothing has been typed and nothing has been cleared.
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "parked words")
        #expect(fixture.sends.calls.isEmpty)
    }

    // MARK: - The one delivery path

    /// The ordinary case end to end at the actor: park before any pane exists,
    /// let the spawn bring one up, let the hook fire, wait out the settle —
    /// exactly one paste, of exactly those bytes, and only then is the column
    /// cleared.
    @Test("a prompt parked before the spawn is pasted once, when the pane is ready")
    func parkedBeforeSpawnIsPastedOnce() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)

        #expect(await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: Self.multiLinePrompt,
            submit: true) == .parkedForSpawn)

        let created = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
            preSessionTerminalID: nil)
        let primary = try #require(created.first?.id)
        // The spawn is over and nothing has been typed or cleared.
        #expect(fixture.sends.calls.isEmpty)
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == Self.multiLinePrompt)

        // The SessionStart hook — the machine signal, never screen text.
        await fixture.coordinator.noteSessionReady(
            worktreeID: fixture.worktree.id, terminalID: primary)
        await advancePastSettle(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls == [SendRecorder.Call(
            terminalID: primary, text: Self.multiLinePrompt, submit: true)])
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
        #expect(try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id).isEmpty)
    }

    @Test("a prompt parked after the pane exists is armed against its readiness")
    func parkedAfterSpawnAwaitsReady() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)

        let result = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: Self.multiLinePrompt, submit: true)
        #expect(result == .awaitingReady)

        await fixture.coordinator.noteSessionReady(
            worktreeID: fixture.worktree.id, terminalID: terminal.id)
        await advancePastSettle(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls == [SendRecorder.Call(
            terminalID: terminal.id, text: Self.multiLinePrompt, submit: true)])
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
    }

    /// A terminal whose hook already fired will not fire another, so the
    /// delivery must not wait for a signal that can never come.
    @Test("an agent whose hook already fired is ready immediately")
    func alreadyAnnouncedSessionDeliversWithoutWaiting() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
        // What `terminal.sessionEvent` writes, and nothing else does.
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: UUID().uuidString,
            transcriptPath: "/tmp/acme/transcript.jsonl")

        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "already up", submit: true)
        // No readiness wait — but the settle still applies, because a row that
        // already proves readiness may have been stamped a millisecond ago.
        await advancePastSettle(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.map(\.text) == ["already up"])
        #expect(fixture.sends.calls.first?.terminalID == terminal.id)
    }

    /// The trap this rule exists for: a fresh Claude spawn is created with a
    /// pre-chosen `--session-id`, so `claudeSessionID` is populated before the
    /// process has started. Reading that as readiness would paste into a
    /// booting TUI.
    @Test("a pre-chosen --session-id is not readiness")
    func preChosenSessionIDIsNotReadiness() async throws {
        let fixture = try await makeSpawnFixture()
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: UUID().uuidString, kind: .claude)
        #expect(!PendingPromptCoordinator.hasAnnouncedItself(terminal))
    }

    /// `hasAnnouncedItself` has two legs, and most fixtures here set
    /// `transcriptPath`, which short-circuits the first. A Codex pane reports
    /// only its activity state, so the second leg is the whole answer for it.
    @Test("an activity state alone counts as having announced")
    func activityStateAloneIsReadiness() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .codex)
        try await fixture.db.terminals.setActivityState(id: terminal.id, activityState: .idle)
        let announced = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(announced.transcriptPath == nil)
        #expect(PendingPromptCoordinator.hasAnnouncedItself(announced))

        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "codex words", submit: false)
        await advancePastSettle(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.map(\.text) == ["codex words"])
    }

    // MARK: - The measured settle

    /// The measured dead window, in virtual time. `SessionStart` says a session
    /// exists; it does not say the TUI has enabled bracketed-paste mode, and a
    /// paste inside that window is discarded outright. Bisected on live panes:
    /// lost at +0.07s and +0.42s, landed at +0.72s and beyond.
    ///
    /// Both halves are asserted, because only the pair discriminates: nothing
    /// is typed one tick short of the settle, and the paste follows the tick
    /// that clears it. Delete the sleep and the first half reds — there is no
    /// suspension to advance and the bytes are already gone.
    ///
    /// It is the *only* mitigation there is. Nothing observes whether the paste
    /// took, so nothing corrects it.
    @Test("no byte is typed until the settle after SessionStart has passed")
    func theFirstPasteWaitsOutTheSettle() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
        // Announced already, so the readiness wait resolves at once and the
        // settle is the only thing this cycle is sleeping on.
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: UUID().uuidString,
            transcriptPath: "/tmp/acme/transcript.jsonl")

        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "into a booting TUI", submit: true)

        // One tick short of the settle: the pane is still inside the window
        // where a live TUI throws the bytes away.
        await clock.advanceWhenSuspended(
            by: PendingPromptCoordinator.pendingPromptSettleDelay - .milliseconds(1))
        #expect(fixture.sends.calls.isEmpty)

        // The tick that clears it.
        await clock.advanceWhenSuspended(by: .milliseconds(1))
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.map(\.text) == ["into a booting TUI"])
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
    }

    // MARK: - Submitting is opt-in

    @Test("submit: false sends no Enter after the paste")
    func unsubmittedPasteSendsNoEnter() async throws {
        let fixture = try await makeSendFixture()

        _ = await fixture.router.sendQueuedPromptVerbatim(
            terminalID: fixture.terminal.id, text: "staged", submit: false)

        #expect(fixture.pastes.pastes == ["staged"])
        #expect(!fixture.recorder.joinedAll.contains("send-keys"))
        #expect(!fixture.recorder.joinedAll.contains("Enter"))
    }

    @Test("submit: true does send an Enter after the paste")
    func submittedPasteSendsEnter() async throws {
        let fixture = try await makeSendFixture()

        _ = await fixture.router.sendQueuedPromptVerbatim(
            terminalID: fixture.terminal.id, text: "go", submit: true)

        #expect(fixture.recorder.joinedAll.contains("Enter"))
    }

    /// The pair, at the coordinator: the submit bit the operator chose is the
    /// bit the send seam is asked for, and nothing else decides it.
    @Test("the parked submit choice is what reaches the send seam")
    func parkedSubmitChoiceReachesTheSendSeam() async throws {
        for submit in [true, false] {
            let clock = TestClock()
            let fixture = try await makeSpawnFixture(clock: clock)
            try await fixture.db.config.setQueuedPrompt(true)
            let terminal = try await fixture.db.terminals.create(
                worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
                kind: .claude)
            try await fixture.db.terminals.updateSession(
                id: terminal.id, sessionID: UUID().uuidString,
                transcriptPath: "/tmp/acme/transcript.jsonl")

            _ = await fixture.coordinator.park(
                worktreeID: fixture.worktree.id, text: "words", submit: submit)
            await advancePastSettle(clock, fixture)
            await awaitDeliveries(fixture.coordinator)

            #expect(fixture.sends.calls.map(\.submit) == [submit])
            // Cleared either way: the successful paste is the whole of what can
            // be known, and it is what the column is cleared on.
            #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
        }
    }

    // MARK: - Verbatim, with the envelope suppressed

    /// The bytes that actually reach the pane, from the real send core: the
    /// operator's own words, with no `<tbd-dispatch/>` framing.
    @Test("the internal send delivers verbatim, with no dispatch envelope")
    func internalSendSuppressesEnvelope() async throws {
        let fixture = try await makeSendFixture()

        let delivered = await fixture.router.sendQueuedPromptVerbatim(
            terminalID: fixture.terminal.id, text: Self.multiLinePrompt, submit: true)

        #expect(delivered)
        #expect(fixture.pastes.pastes == [Self.multiLinePrompt])
        #expect(!fixture.pastes.pastes.joined().contains("tbd-dispatch"))
    }

    /// The discriminating half: the same terminal, over the public verb, still
    /// gets the envelope. Suppression is a property of the internal seam, not
    /// something the change quietly removed for everyone.
    @Test("terminal.send still frames the same terminal with the envelope")
    func publicSendKeepsEnvelope() async throws {
        let fixture = try await makeSendFixture()

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(
                terminalID: fixture.terminal.id, text: "hello", submit: true)))

        #expect(response.success)
        #expect(fixture.pastes.pastes.count == 1)
        #expect(fixture.pastes.pastes[0].hasPrefix("<tbd-dispatch"))
        #expect(fixture.pastes.pastes[0].hasSuffix("\nhello"))
    }

    /// `TerminalSendParams` has no way to ask for suppression: the wire type
    /// carries no such key, so no RPC caller can type as a human. Asserted on
    /// the encoded form rather than on the Swift type, because the wire is
    /// what a caller controls.
    @Test("no RPC caller can ask terminal.send to suppress the envelope")
    func envelopeSuppressionIsUnreachableOverRPC() async throws {
        let fixture = try await makeSendFixture()

        // Every plausible spelling a caller might try, alongside a valid send.
        let json = """
            {"terminalID":"\(fixture.terminal.id.uuidString)","text":"hello","submit":true,\
            "envelope":"suppressed","suppressEnvelope":true,"verbatim":true}
            """
        let response = await fixture.router.handle(RPCRequest(
            method: RPCMethod.terminalSend, params: json))

        #expect(response.success)
        #expect(fixture.pastes.pastes.count == 1)
        #expect(fixture.pastes.pastes[0].hasPrefix("<tbd-dispatch"))
    }

    /// The actuation row names a rail from `ActuationRail`, like every sibling
    /// daemon-internal send, rather than a string spelled at the call site.
    @Test("the queued-prompt paste is logged under its named rail")
    func queuedPromptPasteRecordsItsRail() async throws {
        let fixture = try await makeSendFixture()

        _ = await fixture.router.sendQueuedPromptVerbatim(
            terminalID: fixture.terminal.id, text: "logged", submit: true)

        await waitUntil("the actuation row is on disk") {
            FileManager.default.fileExists(atPath: fixture.actuationLogPath)
        }
        let log = try String(contentsOfFile: fixture.actuationLogPath, encoding: .utf8)
        #expect(log.contains(ActuationRail.queuedPrompt))
    }

    // MARK: - Undeliverable, and the text stays put

    /// The spawn produced a plain shell. There is no composer, and pasting into
    /// one would run the operator's words as a command line.
    @Test("undeliverable: a shell primary notifies and keeps the text")
    func shellPrimaryIsUndeliverable() async throws {
        let fixture = try await makeSpawnFixture()
        try await fixture.db.config.setQueuedPrompt(true)
        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "for an agent", submit: true)

        // `skipClaude` resolves the primary terminal to a plain shell.
        _ = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: true,
            preSessionTerminalID: nil)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.isEmpty)
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "for an agent")
        let notices = try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id)
        #expect(notices.count == 1)
        #expect(notices.first?.message?.contains("plain shell") == true)
    }

    @Test("undeliverable: a paste that failed notifies and keeps the text")
    func failedPasteIsUndeliverable() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        fixture.sends.failEverySend()
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: UUID().uuidString,
            transcriptPath: "/tmp/acme/transcript.jsonl")

        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "undelivered", submit: true)
        await advancePastSettle(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.count == 1)
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "undelivered")
        let notices = try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id)
        #expect(notices.count == 1)
        #expect(notices.first?.terminalID == terminal.id)
    }

    /// A daemon with no send path wired cannot deliver, and says so rather than
    /// clearing the column on a delivery that never happened.
    @Test("undeliverable: no send path wired keeps the text")
    func noSendPathIsUndeliverable() async throws {
        let clock = TestClock()
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setQueuedPrompt(true)
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: FileManager.default.temporaryDirectory.path, tmuxServer: "tbd-test")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: UUID().uuidString,
            transcriptPath: "/tmp/acme/transcript.jsonl")
        // No `deliver` seam at all — mock mode, and every unit fixture that
        // forgets to wire one.
        let coordinator = PendingPromptCoordinator(db: db, clock: clock)

        _ = await coordinator.park(worktreeID: worktree.id, text: "nowhere to go", submit: true)
        await awaitDeliveries(coordinator)

        #expect(try await pendingPrompt(db, worktree.id) == "nowhere to go")
        let notices = try await db.notifications.unread(worktreeID: worktree.id)
        #expect(notices.count == 1)
        #expect(notices.first?.message?.contains("no send path wired") == true)
    }

    /// Parking on an archived worktree is refused rather than promised: archive
    /// deletes the terminal rows, so it looks exactly like a worktree still
    /// being created, and no agent is coming up to receive the text.
    @Test("undeliverable: parking on an archived worktree is refused, not promised")
    func parkingOnAnArchivedWorktreeIsRefused() async throws {
        let fixture = try await makeSpawnFixture()
        try await fixture.db.config.setQueuedPrompt(true)
        try await fixture.db.worktrees.updateStatus(
            id: fixture.worktree.id, status: .archived)

        let result = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "too late", submit: true)

        guard case .refused(let reason) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(reason.contains("archived"))
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
    }

    /// A worktree whose spawn already happened and produced a shell has no
    /// agent coming: the refusal says so instead of parking text nothing will
    /// ever read.
    @Test("undeliverable: parking on a worktree whose primary is a shell is refused")
    func parkingOnAShellPrimaryIsRefused() async throws {
        let fixture = try await makeSpawnFixture()
        try await fixture.db.config.setQueuedPrompt(true)
        _ = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .shell)

        let result = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "no composer here", submit: true)

        guard case .refused(let reason) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(reason.contains("not an agent"))
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
    }

    /// Park a real hibernated row — written through `TerminalStore`'s own park
    /// choke point, not hand-set fields — and check what it actually looks like
    /// before parking against it. A hibernated agent keeps `kind == .claude`
    /// while its pane holds a bare shell, and the park stamps
    /// `activityState = .idle`, so the row reads as *announced*: every signal
    /// the coordinator had said "agent, ready" about a pane that would have run
    /// the operator's words as a command line.
    @Test("undeliverable: parking against a hibernated primary is refused")
    func parkingOnAHibernatedPrimaryIsRefused() async throws {
        let fixture = try await makeSpawnFixture()
        try await fixture.db.config.setQueuedPrompt(true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
        try await fixture.db.terminals.setHibernated(
            id: terminal.id, sessionID: UUID().uuidString, reason: .auto)

        let parked = try #require(try await fixture.db.terminals.get(id: terminal.id))
        #expect(parked.isParked)
        #expect(parked.kind == .claude, "hibernation does not change the row's kind")
        #expect(
            PendingPromptCoordinator.hasAnnouncedItself(parked),
            "a parked session reads as announced — which is why the kind check alone was not enough")

        let result = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "into a bare shell", submit: true)

        guard case .refused(let reason) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(reason.contains("hibernated"))
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
        #expect(fixture.sends.calls.isEmpty)
    }

    /// The window this feature opened: the prompt was eligible when it was
    /// parked, and the pane hibernated while the daemon waited for its agent to
    /// announce itself. Nothing is typed, the text stays put, and the operator
    /// is told.
    @Test("undeliverable: a primary that hibernates during the readiness wait is not typed into")
    func hibernationDuringTheReadinessWaitIsUndeliverable() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        // Not announced yet, so the cycle parks on the readiness wait.
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)

        let result = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "hibernated mid-wait", submit: true)
        #expect(result == .awaitingReady, "the prompt was eligible when it was parked")

        // The idle sweep parks the session while the wait is still open; the
        // agent's `SessionStart` then reaches the daemon behind it.
        try await fixture.db.terminals.setHibernated(
            id: terminal.id, sessionID: UUID().uuidString, reason: .auto)
        await fixture.coordinator.noteSessionReady(
            worktreeID: fixture.worktree.id, terminalID: terminal.id)

        await advanceUntilNotified(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.isEmpty, "no byte may reach a bare shell")
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "hibernated mid-wait")
        let notices = try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id)
        #expect(notices.count == 1)
        #expect(notices.first?.message?.contains("hibernated") == true)
    }

    /// The same window, one step later: readiness had already arrived and the
    /// cycle was asleep in the settle when the session was parked. The check
    /// therefore has to sit after the settle, immediately before the send —
    /// anything answered earlier is a fact about a moment that has passed.
    @Test("undeliverable: a primary that hibernates during the settle is not typed into")
    func hibernationDuringTheSettleIsUndeliverable() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: UUID().uuidString,
            transcriptPath: "/tmp/acme/transcript.jsonl")

        let result = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "hibernated mid-settle", submit: true)
        #expect(result == .awaitingReady)

        // Nothing has advanced this clock, so the cycle cannot be past the
        // settle — the park lands underneath a suspended delivery.
        try await fixture.db.terminals.setHibernated(
            id: terminal.id, sessionID: UUID().uuidString, reason: .auto)

        await advanceUntilNotified(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.isEmpty)
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "hibernated mid-settle")
        let notices = try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id)
        #expect(notices.count == 1)
        #expect(notices.first?.message?.contains("hibernated") == true)
    }

    /// The flag is a kill-switch, which means it has to stop a delivery that is
    /// already armed. Read only at `park` it would gate the next prompt while
    /// the one in flight typed anyway, up to two minutes later.
    @Test("the flag stops a delivery that was already armed when it was switched off")
    func disablingTheFlagMidFlightStopsTheDelivery() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: UUID().uuidString,
            transcriptPath: "/tmp/acme/transcript.jsonl")

        let result = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "stop this one too", submit: true)
        #expect(result == .awaitingReady)

        try await fixture.db.config.setQueuedPrompt(false)

        await advanceUntilNotified(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.isEmpty)
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "stop this one too")
        let notices = try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id)
        #expect(notices.count == 1)
        #expect(notices.first?.message?.contains("switched off") == true)
    }

    @Test("undeliverable: the readiness wait is bounded on the injected clock")
    func readinessWaitUsesTheInjectedClock() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        // No session id: the hook has not fired, so the wait is live.
        _ = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)

        let result = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "never answered", submit: true)
        #expect(result == .awaitingReady)

        // One advance past the ceiling — 120 s of virtual time, no wall time.
        await clock.advanceWhenSuspended(
            by: PendingPromptCoordinator.pendingPromptReadinessTimeout)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.isEmpty)
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "never answered")
        let notices = try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id)
        #expect(notices.count == 1)
        #expect(notices.first?.message?.contains("did not report a session") == true)
    }

    /// The other side of the same clock: one tick short of the ceiling, the
    /// wait is still live and the prompt is still deliverable.
    @Test("the readiness wait has not expired one tick before the ceiling")
    func readinessWaitStillLiveBeforeTheCeiling() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)

        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "late but fine", submit: true)
        await clock.advanceWhenSuspended(
            by: PendingPromptCoordinator.pendingPromptReadinessTimeout - .seconds(1))

        await fixture.coordinator.noteSessionReady(
            worktreeID: fixture.worktree.id, terminalID: terminal.id)
        await advancePastSettle(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.map(\.text) == ["late but fine"])
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
        #expect(try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id).isEmpty)
    }

    // MARK: - The licence to type is granted once, and spent

    /// After a daemon restart the column still holds the text but nothing is
    /// armed, so the pane that comes up must hand the prompt back to the
    /// operator rather than type into a session unbidden.
    @Test("a prompt from a previous daemon is announced, never typed")
    func promptFromAPreviousDaemonIsNotTyped() async throws {
        let fixture = try await makeSpawnFixture()
        try await fixture.db.config.setQueuedPrompt(true)
        // Written straight to the column: this coordinator never saw a park,
        // which is exactly the state a restart leaves behind.
        try await fixture.db.worktrees.setPendingPrompt(
            worktreeID: fixture.worktree.id, text: "from yesterday", submit: true)

        _ = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
            preSessionTerminalID: nil)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.isEmpty)
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "from yesterday")
        let notices = try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id)
        #expect(notices.count == 1)
        #expect(notices.first?.message?.contains("did not type it into this session") == true)
    }

    /// The text stays in the column for as long as the operator wants it, and
    /// every later spawn meets it. Saying so once is a pointer at something
    /// recoverable; saying so on every spawn is noise.
    @Test("a stranded prompt is announced once, not on every later spawn")
    func strandedPromptIsAnnouncedOnce() async throws {
        let fixture = try await makeSpawnFixture()
        try await fixture.db.config.setQueuedPrompt(true)
        try await fixture.db.worktrees.setPendingPrompt(
            worktreeID: fixture.worktree.id, text: "from yesterday", submit: true)

        for _ in 0..<3 {
            _ = try await fixture.lifecycle.spawnPrimaryTerminals(
                worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
                preSessionTerminalID: nil)
        }
        await awaitDeliveries(fixture.coordinator)

        #expect(try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id).count == 1)
    }

    /// Four of the five undeliverable outcomes leave the text in the column on
    /// purpose. The licence to type was spent by the pane the prompt was parked
    /// for, so the next spawn — a revive, a desk session — types nothing into a
    /// conversation the words were never written for.
    @Test("a retained prompt is not typed into a later spawn's agent")
    func aRetainedPromptIsNotTypedByALaterSpawn() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        fixture.sends.failEverySend()

        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "first message", submit: true)
        let created = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
            preSessionTerminalID: nil)
        await fixture.coordinator.noteSessionReady(
            worktreeID: fixture.worktree.id, terminalID: try #require(created.first?.id))
        await advancePastSettle(clock, fixture)
        await awaitDeliveries(fixture.coordinator)
        // The paste failed, so the text is retained on purpose.
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "first message")
        #expect(fixture.sends.callCount == 1)

        // Weeks later, or minutes: another spawn for the same worktree.
        fixture.sends.failEverySend()
        let revived = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
            preSessionTerminalID: nil)
        await fixture.coordinator.noteSessionReady(
            worktreeID: fixture.worktree.id, terminalID: try #require(revived.first?.id))
        await awaitDeliveries(fixture.coordinator)

        // Still exactly one send: the second pane was never armed.
        #expect(fixture.sends.callCount == 1)
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "first message")
    }

    /// Pressing Deliver-now re-parks, which grants the licence again — the
    /// operator's own gesture is what makes a retained prompt deliverable.
    @Test("re-parking a retained prompt makes it deliverable again")
    func reParkingGrantsTheLicenceAgain() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        try await fixture.db.worktrees.setPendingPrompt(
            worktreeID: fixture.worktree.id, text: "stranded", submit: true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: UUID().uuidString,
            transcriptPath: "/tmp/acme/transcript.jsonl")

        #expect(await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "stranded",
            submit: true) == .awaitingReady)
        await advancePastSettle(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.map(\.text) == ["stranded"])
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
    }

    /// A prompt that was delivered and cleared leaves nothing to announce. The
    /// column, not the licence set, is what decides whether anything is
    /// outstanding.
    @Test("a pane coming up after a delivered prompt claims no stranded text")
    func paneAfterADeliveredPromptSaysNothing() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: UUID().uuidString,
            transcriptPath: "/tmp/acme/transcript.jsonl")
        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "delivered", submit: true)
        await advancePastSettle(clock, fixture)
        await awaitDeliveries(fixture.coordinator)
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)

        await fixture.coordinator.notePrimaryTerminalExists(
            worktreeID: fixture.worktree.id, terminalID: terminal.id)
        await awaitDeliveries(fixture.coordinator)

        #expect(try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id).isEmpty)
        #expect(fixture.sends.callCount == 1)
    }

    // MARK: - One park, one paste

    /// One prompt per worktree, not a queue: a second park replaces the first
    /// in the column *and* in the arming. The superseded wait must go quiet —
    /// it must not clear its successor's arming, and it must not announce a
    /// timeout for a prompt that was replaced rather than lost.
    @Test("a second park supersedes the first without announcing a timeout")
    func secondParkSupersedesTheFirstQuietly() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)

        let first = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "first", submit: true)
        let second = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "second", submit: true)
        #expect(first == .awaitingReady)
        #expect(second == .awaitingReady)

        await fixture.coordinator.noteSessionReady(
            worktreeID: fixture.worktree.id, terminalID: terminal.id)
        await advancePastSettle(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        // Exactly one delivery, and it is the replacement.
        #expect(fixture.sends.calls.map(\.text) == ["second"])
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
        #expect(try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id).isEmpty)
    }

    /// "Deliver Now" pressed twice, or pressed while its own RPC is in flight.
    /// The column still holds the text — it is the recovery store — so a second
    /// park reads the same words, and typing them again would put the prompt in
    /// front of the model twice.
    ///
    /// The settle is the window where both cycles are alive, so the check that
    /// closes it has to be *after* the settle. Move it before and this reds.
    @Test("a repeated park of the same text pastes it once")
    func repeatedParkOfTheSameTextPastesOnce() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
        try await fixture.db.terminals.updateSession(
            id: terminal.id, sessionID: UUID().uuidString,
            transcriptPath: "/tmp/acme/transcript.jsonl")

        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "say it once", submit: true)
        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "say it once", submit: true)
        await advancePastSettle(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.map(\.text) == ["say it once"])
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
    }

    /// The delivery reads the text, suspends through a settle and a send, and
    /// comes back to clear — and a park can land anywhere in that suspension.
    /// Clearing whatever the column happens to hold destroys the newcomer: it
    /// vanishes from the recovery store having never been delivered, and its
    /// own cycle then reads an empty column and returns silently, so the
    /// operator gets neither the prompt nor a notice, having been told
    /// `.awaitingReady`.
    @Test("a park landing mid-delivery survives its predecessor's clear")
    func clearOnlyRemovesTheTextThatWasDelivered() async throws {
        let clock = TestClock()
        let gate = Gate()
        let fixture = try await makeSpawnFixture(clock: clock, gate: gate)
        try await fixture.db.config.setQueuedPrompt(true)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)

        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "first", submit: true)
        // Readiness by signal, not by row: the row stays un-announced so the
        // SECOND cycle parks on its readiness wait instead of racing ahead and
        // reading the column before the first cycle has cleared it.
        await fixture.coordinator.noteSessionReady(
            worktreeID: fixture.worktree.id, terminalID: terminal.id)
        await advancePastSettle(clock, fixture, sends: 1)

        // The park that lands while the first delivery is suspended.
        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "second", submit: true)
        await gate.release()
        await waitUntil("the superseded cycle has retired") {
            await fixture.coordinator.inFlightCycleCount == 1
        }
        // The first cycle's clear named "first"; the column holds "second", so
        // the compare-and-swap did not fire and the newcomer survived.
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "second")

        await fixture.coordinator.noteSessionReady(
            worktreeID: fixture.worktree.id, terminalID: terminal.id)
        await advancePastSettle(clock, fixture, sends: 2)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.map(\.text) == ["first", "second"])
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
        #expect(try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id).isEmpty)
    }

    /// `arm` installs a new record under the worktree's key. An incumbent
    /// record holding a continuation must be resumed on the way out, or nothing
    /// can ever resume it: every resumer matches on the generation token that
    /// just left the slot.
    @Test("a pane hand-off over an armed prompt does not strand the incumbent cycle")
    func handOffOverAnArmedPromptRetiresTheIncumbent() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)

        #expect(await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "hello",
            submit: true) == .parkedForSpawn)
        let terminal = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
        // The pane hand-off, twice — the second is a second arming under a key
        // that already holds a suspended waiter.
        await fixture.coordinator.notePrimaryTerminalExists(
            worktreeID: fixture.worktree.id, terminalID: terminal.id)
        await fixture.coordinator.notePrimaryTerminalExists(
            worktreeID: fixture.worktree.id, terminalID: terminal.id)

        await fixture.coordinator.noteSessionReady(
            worktreeID: fixture.worktree.id, terminalID: terminal.id)
        await advancePastSettle(clock, fixture)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.map(\.text) == ["hello"])
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
    }

    /// A cycle a later park superseded owns nothing. It must not speak: the
    /// timeout it is about to report belongs to a prompt that was replaced, not
    /// lost.
    @Test("a superseded cycle announces no timeout of its own")
    func supersededCycleStaysQuietOnItsOwnTimeout() async throws {
        let clock = TestClock()
        let fixture = try await makeSpawnFixture(clock: clock)
        try await fixture.db.config.setQueuedPrompt(true)
        _ = try await fixture.db.terminals.create(
            worktreeID: fixture.worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)

        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "first", submit: true)
        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "second", submit: true)

        await clock.advanceWhenSuspended(
            by: PendingPromptCoordinator.pendingPromptReadinessTimeout)
        await awaitDeliveries(fixture.coordinator)

        // Exactly one notice: the surviving arming's ceiling. The superseded
        // cycle was woken with "not ready" by the disarm and has nothing to say.
        let notices = try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id)
        #expect(notices.count == 1)
        #expect(notices.first?.message?.contains("did not report a session") == true)
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == "second")
    }

    // MARK: - Small refusals

    /// Whitespace with an Enter after it is a turn the operator did not ask
    /// for. Emptiness is judged on the trimmed text, and the unpark works even
    /// where a park would be refused — Discard has to reach an archived
    /// worktree's text too.
    @Test("a whitespace-only prompt parks nothing and unparks what was there")
    func whitespaceOnlyPromptParksNothing() async throws {
        let fixture = try await makeSpawnFixture()
        try await fixture.db.config.setQueuedPrompt(true)
        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "real words", submit: true)

        let result = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "   \n  ", submit: true)

        guard case .refused(let reason) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(reason.contains("unparked"))
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
    }

    /// An unparked prompt is gone: the pane that later comes up finds nothing
    /// and says nothing.
    @Test("an unparked prompt is not resurrected by the pane hand-off")
    func unparkedPromptIsNotResurrected() async throws {
        let fixture = try await makeSpawnFixture()
        try await fixture.db.config.setQueuedPrompt(true)
        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: "never mind", submit: true)
        _ = await fixture.coordinator.park(
            worktreeID: fixture.worktree.id, text: nil, submit: true)

        _ = try await fixture.lifecycle.spawnPrimaryTerminals(
            worktree: fixture.worktree, repo: fixture.repo, skipClaude: false,
            preSessionTerminalID: nil)
        await awaitDeliveries(fixture.coordinator)

        #expect(fixture.sends.calls.isEmpty)
        #expect(try await pendingPrompt(fixture.db, fixture.worktree.id) == nil)
        #expect(try await fixture.db.notifications.unread(
            worktreeID: fixture.worktree.id).isEmpty)
    }

    // MARK: - The production wiring

    /// End to end over the wire: park over RPC, readiness over RPC. Nothing
    /// here calls the actor directly, so it fails if the send seam or the
    /// readiness hook is unwired — either being a single deletable line that
    /// leaves every actor-level test in this file green.
    @Test("delivery runs on the RPC hooks alone, with no direct actor calls")
    func deliveryRunsEntirelyThroughRPC() async throws {
        let clock = TestClock()
        let (fixture, coordinator) = try await makeWiredFixture(clock: clock)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.worktreeSetPendingPrompt,
            params: WorktreeSetPendingPromptParams(
                worktreeID: fixture.terminal.worktreeID,
                text: Self.multiLinePrompt, submit: true)))
        #expect(try response.decodeResult(WorktreeSetPendingPromptResult.self) == .awaitingReady)

        try await sendSessionEvent(fixture)
        await advancePastSettle(clock, fixture, pastes: 1)
        await awaitDeliveries(coordinator)

        // The operator's own words, verbatim, with no dispatch framing — and
        // exactly one paste, which is the whole claim this feature makes.
        #expect(fixture.pastes.pastes == [Self.multiLinePrompt])
        #expect(fixture.recorder.joinedAll.contains("Enter"))
        #expect(try await pendingPrompt(fixture.db, fixture.terminal.worktreeID) == nil)
        #expect(try await fixture.db.notifications.unread(
            worktreeID: fixture.terminal.worktreeID).isEmpty)
    }

    /// The same route with the box unticked: the bytes land in the composer and
    /// no Enter follows them. Over the wire, because the submit bit crosses two
    /// boundaries — the RPC and the send core — and either could drop it.
    @Test("an unsubmitted prompt is staged over RPC, with no Enter")
    func unsubmittedDeliveryRunsThroughRPC() async throws {
        let clock = TestClock()
        let (fixture, coordinator) = try await makeWiredFixture(clock: clock)

        _ = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.worktreeSetPendingPrompt,
            params: WorktreeSetPendingPromptParams(
                worktreeID: fixture.terminal.worktreeID,
                text: Self.multiLinePrompt, submit: false)))
        try await sendSessionEvent(fixture)
        await advancePastSettle(clock, fixture, pastes: 1)
        await awaitDeliveries(coordinator)

        #expect(fixture.pastes.pastes == [Self.multiLinePrompt])
        #expect(!fixture.recorder.joinedAll.contains("Enter"))
        // Cleared on the paste, and on nothing else: nothing observable records
        // text sitting unsent in a composer, so the successful paste is the
        // whole of what can be known.
        #expect(try await pendingPrompt(fixture.db, fixture.terminal.worktreeID) == nil)
    }
}
