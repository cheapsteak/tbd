import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite("terminal.sessionEvent handler")
struct TerminalSessionEventHandlerTests {
    let db: TBDDatabase
    let router: RPCRouter

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
    }

    private func makeRouter(now: @escaping @Sendable () -> Date) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            now: now,
            actuationLog: makeTestActuationLog()
        )
    }

    private func makeTerminal(
        initialSession: String? = nil,
        label: String = "claude",
        kind: TerminalKind? = nil
    ) async throws -> (Terminal, Worktree) {
        let repo = try await db.repos.create(
            path: "/tmp/se-repo-\(UUID().uuidString)",
            displayName: "se-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/se-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-se"
        )
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: label,
            claudeSessionID: initialSession,
            kind: kind
        )
        return (terminal, wt)
    }

    /// Creates a second, independent worktree (different path) so we can
    /// simulate a foreign Claude session whose cwd lives elsewhere.
    private func makeForeignWorktree() async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/se-foreign-repo-\(UUID().uuidString)",
            displayName: "acme-prod",
            defaultBranch: "main"
        )
        return try await db.worktrees.create(
            repoID: repo.id,
            name: "acme-prod-wt",
            branch: "main",
            path: "/tmp/se-foreign-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-se-foreign"
        )
    }

    @Test("updates sessionID + transcriptPath in DB on a fresh SessionStart")
    func updatesSessionAndBroadcasts() async throws {
        let (terminal, _) = try await makeTerminal(initialSession: "old-id")
        let observedAt = Date(timeIntervalSinceReferenceDate: 123)
        let orderedRouter = makeRouter(now: { observedAt })
        let captured = SessionDeltaCapture()
        orderedRouter.subscriptions.addSubscriber { data in
            captured.append(data)
            return true
        }
        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "new-id",
                transcriptPath: "/Users/me/.claude/projects/-x/new-id.jsonl",
                source: "clear"
            )
        )
        let response = await orderedRouter.handle(request)
        #expect(response.success)

        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "new-id")
        #expect(updated?.transcriptPath == "/Users/me/.claude/projects/-x/new-id.jsonl")
        let delta = try #require(captured.values.compactMap {
            try? JSONDecoder().decode(StateDelta.self, from: $0)
        }.first)
        guard case let .terminalSessionUpdated(session) = delta else {
            Issue.record("expected terminalSessionUpdated")
            return
        }
        #expect(session.sessionOrderObservedAt == nil)
    }

    @Test("ignores non-absolute transcriptPath but still updates sessionID")
    func ignoresNonAbsolutePath() async throws {
        let (terminal, _) = try await makeTerminal()
        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "abc",
                transcriptPath: "relative/path.jsonl",
                source: "startup"
            )
        )
        _ = await router.handle(request)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "abc")
        #expect(updated?.transcriptPath == nil)
    }

    @Test("treats empty transcriptPath as not-provided")
    func treatsEmptyPathAsAbsent() async throws {
        let (terminal, _) = try await makeTerminal()
        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "s",
                transcriptPath: "",
                source: nil
            )
        )
        _ = await router.handle(request)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "s")
        #expect(updated?.transcriptPath == nil)
    }

    @Test("nil/rejected transcriptPath preserves a previously-stored path")
    func nilPathPreservesExisting() async throws {
        let (terminal, _) = try await makeTerminal()
        // First event sets a valid path.
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "s1",
                transcriptPath: "/abs/s1.jsonl",
                source: "startup"
            )
        ))
        // Second event has a rejected (non-absolute) path. sessionID
        // updates; transcriptPath stays at the previously-stored value
        // rather than getting zeroed back to nil.
        _ = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "s2",
                transcriptPath: "relative/path.jsonl",
                source: "clear"
            )
        ))
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "s2")
        #expect(updated?.transcriptPath == "/abs/s1.jsonl")
    }

    /// A `/clear`, a resume after an in-place profile swap, and a hand relaunch
    /// all arrive here as one event: a NEW session context in this pane. A
    /// prompt recorded against the previous one died with it.
    ///
    /// Nothing else retracts it. `SessionStateResolver`'s rung 4 keeps a
    /// standing `promptOnScreen` live while the transcript has not grown past
    /// it, and after a `/clear` the new `transcriptPath` points at a file Claude
    /// Code creates lazily — so the growth fact is absent and "we could not look
    /// is not evidence it went away" pins the dead prompt in place. The
    /// overlay's own `tbd terminal-activity idle` does not save it either: this
    /// row already reads idle, and `handleTerminalActivityEvent` returns early
    /// on an unchanged state without rewriting provenance.
    @Test("SessionStart retracts a wait reason recorded against the previous session")
    func sessionStartRetractsAStandingWaitReason() async throws {
        let (terminal, _) = try await makeTerminal(initialSession: "old-id")
        let idleAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptAt = idleAt.addingTimeInterval(60)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .idle, source: .hookEvent("Stop"),
            observedAt: idleAt)
        try await db.terminals.recordAwaitingInputReason(
            id: terminal.id,
            reason: AwaitingInputReason(
                message: "Claude needs your permission to use Bash",
                hookEventName: "Notification",
                notificationType: "permission_prompt"),
            observedAt: promptAt)

        let before = try #require(try await db.terminals.get(id: terminal.id))
        guard case .awaitingInput = SessionStateResolver()
            .resolve(SessionStateFacts(terminal: before)).value else {
            Issue.record("precondition: the prompt should read as live before the SessionStart")
            return
        }

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "cleared-id",
                transcriptPath: "/Users/me/.claude/projects/-x/cleared-id.jsonl",
                source: "clear"
            )
        ))
        #expect(response.success)

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.awaitingInputReason == nil)
        #expect(after.awaitingInputObservedAt == nil)
        // The composed answer no longer reports a wait that ended.
        let state = SessionStateResolver().resolve(SessionStateFacts(terminal: after))
        #expect(state.value == .idle)

        // And the retraction did NOT reach for `setActivityState`: this event
        // says a session exists, not what it is doing, and `activityState` is
        // what `HibernationGate.blockingRail` gates on. All three activity
        // columns survive unchanged, provenance included.
        #expect(after.activityState == .idle)
        #expect(after.activityStateSource == .hookEvent("Stop"))
        #expect(after.activityStateObservedAt == idleAt)
    }

    @Test("Claude SessionStart retains legacy unordered identity and prompt semantics")
    func claudeSessionStartRetainsLegacyUnorderedSemantics() async throws {
        let (terminal, _) = try await makeTerminal(initialSession: "initial-session")
        let olderSessionAt = Date(timeIntervalSince1970: 1_700_000_100)
        let newerSessionAt = olderSessionAt.addingTimeInterval(1)
        _ = try await db.terminals.applySessionStart(
            id: terminal.id,
            sessionID: "newer-session",
            transcriptPath: "/tmp/newer-session.jsonl",
            observedAt: newerSessionAt)
        try await db.terminals.recordAwaitingInputReason(
            id: terminal.id,
            reason: AwaitingInputReason(
                message: "Claude needs permission",
                hookEventName: "Notification",
                notificationType: "permission_prompt"),
            observedAt: newerSessionAt)
        let router = makeRouter(now: { olderSessionAt })
        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "last-arriving-session",
                transcriptPath: "/tmp/last-arriving-session.jsonl",
                source: "resume"))

        #expect((await router.handle(request)).success)

        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.claudeSessionID == "last-arriving-session")
        #expect(updated.transcriptPath == "/tmp/last-arriving-session.jsonl")
        #expect(updated.sessionOrderObservedAt == nil)
        #expect(updated.awaitingInputReason == nil)
        #expect(updated.awaitingInputObservedAt == nil)
    }

    @Test("a later-completing Claude SessionStart retains legacy prompt retraction")
    func laterCompletingClaudeSessionStartRetractsPrompt() async throws {
        let (terminal, _) = try await makeTerminal(initialSession: "old-session")
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionStartAt = baseline.addingTimeInterval(1)
        let delayedPromptAt = baseline.addingTimeInterval(2)
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .working,
            source: .hookEvent("UserPromptSubmit"),
            observedAt: baseline)

        let dates = BlockingSessionDates(first: sessionStartAt, subsequent: delayedPromptAt)
        let raceRouter = makeRouter(now: dates.provider)
        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "new-session",
                transcriptPath: "/tmp/new-session.jsonl",
                source: "resume"))
        let delayedPrompt = try RPCRequest(
            method: RPCMethod.terminalNotificationEvent,
            params: TerminalNotificationEventParams(
                terminalID: terminal.id,
                notificationType: "permission_prompt",
                message: "The old session needs permission"))

        let sessionUpdate = Task { await raceRouter.handle(sessionStart) }
        guard await waitUntil({ dates.firstCallIsBlocked }) else {
            dates.releaseFirstCall()
            _ = await sessionUpdate.value
            Issue.record("SessionStart never reached the date seam")
            return
        }
        #expect((await raceRouter.handle(delayedPrompt)).success)
        dates.releaseFirstCall()
        #expect((await sessionUpdate.value).success)

        let updated = try #require(try await db.terminals.get(id: terminal.id))
        #expect(updated.claudeSessionID == "new-session")
        #expect(updated.transcriptPath == "/tmp/new-session.jsonl")
        #expect(updated.sessionOrderObservedAt == nil)
        #expect(updated.awaitingInputReason == nil)
        #expect(updated.awaitingInputObservedAt == nil)
        #expect(updated.activityState == .working)
        #expect(updated.activityStateSource == .hookEvent("UserPromptSubmit"))
        #expect(updated.activityStateObservedAt == baseline)
    }

    @Test("an older SessionStart cannot roll back identity or erase a newer prompt")
    func olderSessionStartPreservesNewerSessionAndPrompt() async throws {
        let (terminal, worktree) = try await makeTerminal(
            initialSession: "initial-session", label: "Codex", kind: .codex)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-session-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("current.jsonl")
        try (#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"current"}}"#
            + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "initial-session",
            transcriptPath: transcript.path)

        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let earlierSessionAt = baseline.addingTimeInterval(1)
        let laterPromptAt = baseline.addingTimeInterval(2)
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .working,
            source: .hookEvent("UserPromptSubmit"),
            observedAt: baseline)
        let dates = BlockingSessionDates(first: earlierSessionAt, subsequent: laterPromptAt)
        let raceRouter = makeRouter(now: dates.provider)
        #expect(await raceRouter.codexActivityTracker.observe(
            transcriptPath: transcript.path,
            worktreeID: worktree.id) == .working)

        let staleSession = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "stale-session",
                transcriptPath: transcript.path,
                source: "resume"))
        let currentSession = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "current-session",
                transcriptPath: transcript.path,
                source: "resume"))
        let prompt = try RPCRequest(
            method: RPCMethod.terminalNotificationEvent,
            params: TerminalNotificationEventParams(
                terminalID: terminal.id,
                notificationType: "permission_prompt",
                message: "Codex needs permission"))

        let earlier = Task { await raceRouter.handle(staleSession) }
        guard await waitUntil({ dates.firstCallIsBlocked }) else {
            dates.releaseFirstCall()
            _ = await earlier.value
            Issue.record("earlier SessionStart never reached the date seam")
            return
        }
        #expect((await raceRouter.handle(currentSession)).success)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            (#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"current-after-boundary"}}"#
                + "\n").utf8))
        try handle.close()
        #expect(await raceRouter.codexActivityTracker.observe(
            transcriptPath: transcript.path,
            worktreeID: worktree.id) == .working)
        #expect((await raceRouter.handle(prompt)).success)
        dates.releaseFirstCall()
        #expect((await earlier.value).success)

        let updated = try #require(try await db.terminals.get(id: terminal.id))
        #expect(updated.claudeSessionID == "current-session")
        #expect(updated.transcriptPath == transcript.path)
        #expect(updated.awaitingInputReason?.classification == .promptOnScreen)
        #expect(updated.awaitingInputObservedAt == laterPromptAt)
        #expect(SessionStateResolver(now: { laterPromptAt })
            .resolve(SessionStateFacts(terminal: updated)).value
            == .awaitingInput(reason: updated.awaitingInputReason))
        // A rejected old SessionStart must not reset the current transcript's
        // reducer; only an accepted lifecycle boundary may do that.
        #expect(await raceRouter.codexActivityTracker.observe(
            transcriptPath: transcript.path,
            worktreeID: worktree.id) == .working)
    }

    @Test(
        "SessionStart tie ordering is scoped to Codex",
        arguments: [TerminalKind.codex, .claude]
    )
    func equalTimeDifferentSessionStartPreservesFirstIdentity(
        kind: TerminalKind
    ) async throws {
        let label = kind == .codex ? TerminalLabel.codex : "Claude"
        let (terminal, _) = try await makeTerminal(label: label, kind: kind)
        let observedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let sameTimeRouter = makeRouter(now: { observedAt })
        let first = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "first-session",
                transcriptPath: "/tmp/first-session.jsonl",
                source: "SessionStart"))
        let second = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "second-session",
                transcriptPath: "/tmp/second-session.jsonl",
                source: "SessionStart"))

        #expect((await sameTimeRouter.handle(first)).success)
        #expect((await sameTimeRouter.handle(second)).success)

        let updated = try #require(try await db.terminals.get(id: terminal.id))
        if kind == .codex {
            #expect(updated.claudeSessionID == "first-session")
            #expect(updated.transcriptPath == "/tmp/first-session.jsonl")
            #expect(updated.sessionOrderObservedAt == observedAt)
            #expect(updated.activityStateOrderObservedAt == observedAt)
        } else {
            #expect(updated.claudeSessionID == "second-session")
            #expect(updated.transcriptPath == "/tmp/second-session.jsonl")
            #expect(updated.sessionOrderObservedAt == nil)
            #expect(updated.activityStateOrderObservedAt == nil)
        }
    }

    @Test("unknown terminalID is a soft no-op (success, no error)")
    func unknownTerminalSoftSuccess() async throws {
        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: UUID(),
                sessionID: "x",
                transcriptPath: nil,
                source: nil
            )
        )
        let response = await router.handle(request)
        #expect(response.success)
        #expect(response.error == nil)
    }

    // MARK: - Worktree-ownership guard (foreign-session hijack defense)

    @Test("guard ACCEPTS event whose cwd resolves to the terminal's worktree")
    func guardAcceptsMatchingWorktreeCwd() async throws {
        let (terminal, wt) = try await makeTerminal(initialSession: "old-id")
        // A cwd nested inside the terminal's own worktree path.
        let cwd = wt.localPath + "/Sources/Foo"
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "real-session",
                transcriptPath: "/abs/real-session.jsonl",
                source: "startup",
                cwd: cwd
            )
        ))
        #expect(response.success)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "real-session")
        #expect(updated?.transcriptPath == "/abs/real-session.jsonl")
    }

    @Test("guard REJECTS event whose cwd resolves to a DIFFERENT worktree")
    func guardRejectsForeignWorktreeCwd() async throws {
        let (terminal, _) = try await makeTerminal(initialSession: "old-id")
        let foreign = try await makeForeignWorktree()
        // Foreign teammate session inherited TBD_TERMINAL_ID but runs in a
        // different worktree's directory.
        let cwd = foreign.localPath + "/subdir"
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "foreign-session",
                transcriptPath: "/abs/foreign-session.jsonl",
                source: "startup",
                cwd: cwd
            )
        ))
        // Soft success (fire-and-forget hook) but the pointer is unchanged.
        #expect(response.success)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "old-id")
        #expect(updated?.transcriptPath == nil)
    }

    @Test("guard REJECTS event whose cwd resolves to NO known worktree")
    func guardRejectsUnknownCwd() async throws {
        let (terminal, _) = try await makeTerminal(initialSession: "old-id")
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "stray-session",
                transcriptPath: nil,
                source: "startup",
                cwd: "/tmp/se-unrelated-\(UUID().uuidString)/nope"
            )
        ))
        #expect(response.success)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "old-id")
    }

    @Test("guard is bypassed when cwd is absent (backward compatibility)")
    func guardBypassedWhenCwdAbsent() async throws {
        let (terminal, _) = try await makeTerminal(initialSession: "old-id")
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "no-cwd-session",
                transcriptPath: nil,
                source: "startup",
                cwd: nil
            )
        ))
        #expect(response.success)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "no-cwd-session")
    }

    @Test("self-heal: a terminal stuck on a foreign pointer recovers on the next valid SessionStart")
    func selfHealRecoversFromForeignPointer() async throws {
        // Terminal is already hijacked: its stored session is foreign.
        let (terminal, wt) = try await makeTerminal(initialSession: "foreign-2907c5ee")
        // The terminal's REAL Claude fires its own SessionStart with a cwd
        // inside the terminal's own worktree — this must be accepted and must
        // overwrite the foreign pointer.
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "real-session-after-heal",
                transcriptPath: "/abs/real.jsonl",
                source: "resume",
                cwd: wt.localPath
            )
        ))
        #expect(response.success)
        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.claudeSessionID == "real-session-after-heal")
    }

    @Test("transcript handler prefers stored transcriptPath over cwd resolution")
    func transcriptHandlerPrefersStoredPath() async throws {
        // Write a synthetic JSONL at a path the legacy cwd-derived resolution
        // would never find (a /tmp directory unrelated to the worktree path).
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-se-prefer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let storedPath = tmpDir.appendingPathComponent("session.jsonl").path
        // A minimal user message line so TranscriptParser produces at least one item.
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]},"uuid":"abc","timestamp":"2025-01-01T00:00:00Z"}"#
        try (line + "\n").data(using: .utf8)!.write(to: URL(fileURLWithPath: storedPath))

        let (terminal, _) = try await makeTerminal()

        // Tell the daemon about the stored path via sessionEvent.
        let evt = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "logical-session-id",
                transcriptPath: storedPath,
                source: "startup"
            )
        )
        _ = await router.handle(evt)

        // Now ask for the transcript — it should resolve via storedPath, not
        // via ClaudeProjectDirectory.resolve(worktreePath:) (which would fail
        // for our /tmp/se-wt-* path since no ~/.claude/projects/ entry exists).
        let req = try RPCRequest(
            method: RPCMethod.terminalTranscript,
            params: TerminalTranscriptParams(terminalID: terminal.id)
        )
        let resp = await router.handle(req)
        #expect(resp.success)
        let result = try resp.decodeResult(TerminalTranscriptResult.self)
        #expect(result.sessionID == "logical-session-id")
        #expect(!result.messages.isEmpty)
    }
}

private final class SessionDeltaCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] { lock.withLock { storage } }

    func append(_ data: Data) {
        lock.withLock { storage.append(data) }
    }
}

private final class BlockingSessionDates: @unchecked Sendable {
    private let lock = NSLock()
    private let first: Date
    private let subsequent: Date
    private let release = DispatchSemaphore(value: 0)
    private var callCount = 0
    private var firstBlocked = false

    init(first: Date, subsequent: Date) {
        self.first = first
        self.subsequent = subsequent
    }

    var firstCallIsBlocked: Bool {
        lock.withLock { firstBlocked }
    }

    var provider: @Sendable () -> Date {
        { [self] in
            let call = lock.withLock { () -> Int in
                let call = callCount
                callCount += 1
                if call == 0 { firstBlocked = true }
                return call
            }
            guard call == 0 else { return subsequent }
            release.waitForGate("terminal.sessionEvent first date-provider call")
            return first
        }
    }

    func releaseFirstCall() {
        release.signal()
    }
}
