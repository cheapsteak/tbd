import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite("codex activity reconciliation")
struct CodexActivityReconciliationTests {
    let db: TBDDatabase
    let router: RPCRouter
    let presentationObservedAt: Date

    init() throws {
        let db = try TBDDatabase(inMemory: true)
        let presentationObservedAt = Date(timeIntervalSince1970: 1_790_000_000)
        self.db = db
        self.presentationObservedAt = presentationObservedAt
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
            now: { presentationObservedAt },
            actuationLog: makeTestActuationLog()
        )
    }

    @Test("terminal.list exposes transcript working without changing persisted hook activity")
    func terminalListExposesWorkingPresentationWithoutMutation() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-repo-\(UUID().uuidString)",
            displayName: "car-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/car-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car"
        )

        let transcriptPath = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"# + "\n")
        defer { try? FileManager.default.removeItem(at: transcriptPath.deletingLastPathComponent()) }

        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex
        )
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "codex-session",
            transcriptPath: transcriptPath.path
        )
        let observedAt = Date(timeIntervalSince1970: 1_780_000_000)
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .idle,
            source: .hookEvent("Stop"), observedAt: observedAt)

        let request = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id)
        )
        let response = await router.handle(request)
        #expect(response.success)

        let terminals = try response.decodeResult([Terminal].self)
        #expect(terminals.count == 1)
        #expect(terminals[0].presentationActivityState == .working)
        #expect(terminals[0].presentationActivityObservedAt == presentationObservedAt)
        #expect(terminals[0].activityState == .idle)
        #expect(terminals[0].activityStateSource == .hookEvent("Stop"))
        #expect(terminals[0].activityStateObservedAt == observedAt)

        let persisted = try await db.terminals.get(id: terminal.id)
        #expect(persisted?.presentationActivityState == nil)
        #expect(persisted?.presentationActivityObservedAt == nil)
        #expect(persisted?.activityState == .idle)
        #expect(persisted?.activityStateSource == .hookEvent("Stop"))
        #expect(persisted?.activityStateObservedAt == observedAt)
    }

    @Test("accepted same-path SessionStart supersedes an orphan transcript turn")
    func samePathSessionStartResetsTranscriptLifecycle() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-reset-repo-\(UUID().uuidString)",
            displayName: "car-reset-repo",
            defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/car-reset-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-reset")
        let transcript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"orphan"}}"#
                + "\n")
        defer { try? FileManager.default.removeItem(at: transcript.deletingLastPathComponent()) }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex)
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "same-session",
            transcriptPath: transcript.path)
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))

        let before = await router.handle(list)
        #expect(before.success)
        #expect(try before.decodeResult([Terminal].self).first?
            .presentationActivityState == .working)

        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "same-session",
                transcriptPath: transcript.path,
                source: "resume"))
        #expect((await router.handle(sessionStart)).success)

        let afterBoundary = await router.handle(list)
        #expect(afterBoundary.success)
        #expect(try afterBoundary.decodeResult([Terminal].self).first?
            .presentationActivityState == nil)

        try append(
            Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"later"}}"#
                + "\n").utf8),
            to: transcript)
        let afterLaterTurn = await router.handle(list)
        #expect(afterLaterTurn.success)
        #expect(try afterLaterTurn.decodeResult([Terminal].self).first?
            .presentationActivityState == .working)
    }

    @Test("matching transcript completion clears presentation while missed Stop remains persisted working")
    func terminalListObservesAppendedCompletionWithoutMutation() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-idle-repo-\(UUID().uuidString)",
            displayName: "car-idle-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/car-idle-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-idle"
        )

        let transcriptPath = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"# + "\n")
        defer { try? FileManager.default.removeItem(at: transcriptPath.deletingLastPathComponent()) }

        let terminal = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: "Codex",
            kind: .codex
        )
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "codex-session",
            transcriptPath: transcriptPath.path
        )
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .hookEvent("TurnStart"),
            observedAt: Date(timeIntervalSince1970: 1_780_000_000))

        let request = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id)
        )
        let workingResponse = await router.handle(request)
        #expect(workingResponse.success)
        let working = try workingResponse.decodeResult([Terminal].self)
        #expect(working.first?.presentationActivityState == .working)

        let handle = try FileHandle(forWritingTo: transcriptPath)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            (#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"a"}}"# + "\n").utf8))
        try handle.close()

        let idleResponse = await router.handle(request)
        #expect(idleResponse.success)
        let idle = try idleResponse.decodeResult([Terminal].self)
        #expect(idle.first?.presentationActivityState == .idle)
        #expect(idle.first?.activityState == .working)

        let persisted = try await db.terminals.get(id: terminal.id)
        #expect(persisted?.presentationActivityState == nil)
        #expect(persisted?.activityState == .working)
    }

    @Test("terminal.list leaves presentation unknown for unreadable Codex transcript and Claude")
    func terminalListUsesPresentationOnlyForReadableCodexTranscript() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-scope-repo-\(UUID().uuidString)",
            displayName: "car-scope-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-scope-wt-\(UUID().uuidString)", tmuxServer: "tbd-car-scope")
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).jsonl").path

        let codex = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        try await db.terminals.updateSession(
            id: codex.id, sessionID: "codex-session", transcriptPath: missingPath)
        try await db.terminals.setActivityState(
            id: codex.id, activityState: .working, source: .hookEvent("TurnStart"))

        let claudeTranscript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"# + "\n")
        defer { try? FileManager.default.removeItem(at: claudeTranscript.deletingLastPathComponent()) }
        let claude = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "Claude", kind: .claude)
        try await db.terminals.updateSession(
            id: claude.id, sessionID: "claude-session", transcriptPath: claudeTranscript.path)

        let request = try RPCRequest(
            method: RPCMethod.terminalList, params: TerminalListParams(worktreeID: wt.id))
        let response = await router.handle(request)
        #expect(response.success)

        let terminals = try response.decodeResult([Terminal].self)
        #expect(terminals.first(where: { $0.id == codex.id })?.presentationActivityState == nil)
        #expect(terminals.first(where: { $0.id == codex.id })?.presentationActivityObservedAt
            == presentationObservedAt)
        #expect(terminals.first(where: { $0.id == codex.id })?.activityState == .working)
        #expect(terminals.first(where: { $0.id == claude.id })?.presentationActivityState == nil)
        #expect(terminals.first(where: { $0.id == claude.id })?.presentationActivityObservedAt == nil)
    }

    @Test(
        "terminal.list binds presentation to the post-observation transcript identity",
        arguments: [true, false]
    )
    func terminalListRejectsPresentationFromRetargetedTranscript(
        scoped: Bool
    ) async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-rollover-repo-\(UUID().uuidString)",
            displayName: "car-rollover-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-rollover-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-car-rollover")
        let oldTranscript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"old"}}"#
                + "\n")
        let currentTranscript = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"current"}}"#
                + "\n")
        defer {
            try? FileManager.default.removeItem(
                at: oldTranscript.deletingLastPathComponent())
            try? FileManager.default.removeItem(
                at: currentTranscript.deletingLastPathComponent())
        }
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: "old-session",
            transcriptPath: oldTranscript.path)

        let firstAt = Date(timeIntervalSince1970: 1_790_000_100)
        let currentAt = firstAt.addingTimeInterval(1)
        let dates = BlockingListDates(first: firstAt, subsequent: currentAt)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            now: dates.provider,
            actuationLog: makeTestActuationLog())
        let list = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: scoped ? wt.id : nil))
        let priorResponse = await self.router.handle(list)
        #expect(priorResponse.success)
        let priorTerminal = try #require(
            priorResponse.decodeResult([Terminal].self).first(where: { $0.id == terminal.id }))
        #expect(priorTerminal.presentationActivityState == .working)
        #expect(priorTerminal.presentationActivityObservedAt == presentationObservedAt)
        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "current-session",
                transcriptPath: currentTranscript.path,
                source: "SessionStart"))

        let staleList = Task { await router.handle(list) }
        guard await waitUntil({ dates.firstCallIsBlocked }) else {
            dates.releaseFirstCall()
            _ = await staleList.value
            Issue.record("first terminal.list never reached its transcript stamp")
            return
        }
        let sessionUpdate = Task { await router.handle(sessionStart) }
        guard await waitUntilAsync({
            let current = try? await db.terminals.get(id: terminal.id)
            return current?.claudeSessionID == "current-session"
        }) else {
            dates.releaseFirstCall()
            _ = await staleList.value
            _ = await sessionUpdate.value
            Issue.record("SessionStart never committed its atomic retarget")
            return
        }
        let currentList = Task { await router.handle(list) }
        dates.releaseFirstCall()

        let staleResponse = await staleList.value
        #expect((await sessionUpdate.value).success)
        let currentResponse = await currentList.value
        #expect(staleResponse.success)
        #expect(currentResponse.success)
        let staleTerminal = try #require(
            staleResponse.decodeResult([Terminal].self).first(where: { $0.id == terminal.id }))
        let currentTerminal = try #require(
            currentResponse.decodeResult([Terminal].self).first(where: { $0.id == terminal.id }))

        #expect(staleTerminal.claudeSessionID == "current-session")
        #expect(staleTerminal.transcriptPath == currentTranscript.path)
        #expect(staleTerminal.presentationActivityState == nil)
        #expect(staleTerminal.presentationActivityObservedAt == firstAt)
        #expect(currentTerminal.transcriptPath == currentTranscript.path)
        // SessionStart establishes a boundary at the transcript's current EOF,
        // so pre-boundary lifecycle events are not evidence for the new session.
        #expect(currentTerminal.presentationActivityState == nil)
        #expect(currentTerminal.presentationActivityObservedAt == currentAt)
        #expect(!(await router.codexActivityTracker.hasBaseline(
            transcriptPath: oldTranscript.path)))
        #expect(await router.codexActivityTracker.hasBaseline(
            transcriptPath: currentTranscript.path))
    }

    @Test("terminal.list retention respects worktree and fleet scopes")
    func terminalListRetainsTrackerBaselinesByRequestScope() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-retain-repo-\(UUID().uuidString)",
            displayName: "car-retain-repo", defaultBranch: "main")
        let firstWorktree = try await db.worktrees.create(
            repoID: repo.id, name: "first", branch: "first",
            path: "/tmp/car-retain-first-\(UUID().uuidString)", tmuxServer: "tbd-car-first")
        let secondWorktree = try await db.worktrees.create(
            repoID: repo.id, name: "second", branch: "second",
            path: "/tmp/car-retain-second-\(UUID().uuidString)", tmuxServer: "tbd-car-second")
        let firstPath = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"# + "\n")
        let secondPath = try makeTranscript(
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"b"}}"# + "\n")
        defer {
            try? FileManager.default.removeItem(at: firstPath.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondPath.deletingLastPathComponent())
        }
        let first = try await db.terminals.create(
            worktreeID: firstWorktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .codex)
        let second = try await db.terminals.create(
            worktreeID: secondWorktree.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .codex)
        try await db.terminals.updateSession(
            id: first.id, sessionID: "first", transcriptPath: firstPath.path)
        try await db.terminals.updateSession(
            id: second.id, sessionID: "second", transcriptPath: secondPath.path)

        let fleetRequest = try RPCRequest(
            method: RPCMethod.terminalList, params: TerminalListParams())
        #expect(await router.handle(fleetRequest).success)
        #expect(await router.codexActivityTracker.baselineCount == 2)

        try await db.terminals.delete(id: first.id)
        let scopedRequest = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: firstWorktree.id))
        #expect(await router.handle(scopedRequest).success)
        #expect(!(await router.codexActivityTracker.hasBaseline(transcriptPath: firstPath.path)))
        #expect(await router.codexActivityTracker.hasBaseline(transcriptPath: secondPath.path))

        try await db.terminals.delete(id: second.id)
        #expect(await router.handle(fleetRequest).success)
        #expect(await router.codexActivityTracker.baselineCount == 0)
    }

    @Test("terminal.list shares its transcript byte budget fairly across Codex terminals")
    func terminalListSharesTranscriptBudgetFairly() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-budget-repo-\(UUID().uuidString)",
            displayName: "car-budget-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-budget-wt-\(UUID().uuidString)", tmuxServer: "tbd-car-budget")
        let paths = try ["first", "second"].map { turnID in
            try makeTranscript(String(decoding: lifecycleEvent(
                type: "task_complete", turnID: turnID), as: UTF8.self))
        }
        defer {
            for path in paths {
                try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
            }
        }

        for (index, path) in paths.enumerated() {
            let terminal = try await db.terminals.create(
                worktreeID: wt.id,
                tmuxWindowID: "@\(index + 1)", tmuxPaneID: "%\(index + 1)",
                label: "Codex \(index + 1)", kind: .codex)
            try await db.terminals.updateSession(
                id: terminal.id, sessionID: "codex-\(index + 1)", transcriptPath: path.path)
        }

        let request = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: wt.id))
        #expect(await router.handle(request).success)

        let oversizedRecordByteCount = CodexTranscriptActivityTracker.maxBufferedRecordByteCount + 128
        for (index, path) in paths.enumerated() {
            try append(
                lifecycleEvent(
                    type: "agent_message", turnID: "padding-\(index)",
                    exactByteCount: oversizedRecordByteCount)
                    + lifecycleEvent(type: "task_started", turnID: "turn-\(index)"),
                to: path)
        }

        let firstResponse = await router.handle(request)
        #expect(firstResponse.success)
        let firstTerminals = try firstResponse.decodeResult([Terminal].self)
        #expect(firstTerminals.allSatisfy { $0.presentationActivityState == nil })

        var bufferedByteCount = 0
        var progressedPathCount = 0
        for path in paths {
            let buffered = await router.codexActivityTracker.bufferedRecordState(
                transcriptPath: path.path)
            bufferedByteCount += buffered?.byteCount ?? 0
            if let buffered, buffered.byteCount > 0 {
                progressedPathCount += 1
            }
        }
        #expect(bufferedByteCount == Int(CodexTranscriptActivityTracker.requestReadByteLimit))
        #expect(progressedPathCount == paths.count)

        try append(
            lifecycleEvent(
                type: "agent_message", turnID: "first-keeps-growing",
                exactByteCount: 64 * 1024),
            to: paths[0])
        let secondResponse = await router.handle(request)
        #expect(secondResponse.success)
        let secondTerminals = try secondResponse.decodeResult([Terminal].self)
        #expect(secondTerminals.allSatisfy { $0.presentationActivityState == nil })

        try append(
            lifecycleEvent(
                type: "agent_message", turnID: "first-still-growing",
                exactByteCount: 64 * 1024),
            to: paths[0])
        let finalResponse = await router.handle(request)
        #expect(finalResponse.success)
        let finalTerminals = try finalResponse.decodeResult([Terminal].self)
        #expect(finalTerminals.allSatisfy { $0.presentationActivityState == .working })
    }

    private func makeTranscript(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("session.jsonl")
        try contents.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    private func lifecycleEvent(
        type: String,
        turnID: String,
        exactByteCount: Int? = nil
    ) -> Data {
        func encoded(padding: String?) -> Data {
            let paddingField = padding.map { #", "padding":"\#($0)""# } ?? ""
            return Data((
                #"{"type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turnID)"\#(paddingField)}}"#
                    + "\n").utf8)
        }

        guard let exactByteCount else { return encoded(padding: nil) }
        let emptyPadded = encoded(padding: "")
        precondition(exactByteCount >= emptyPadded.count)
        return encoded(padding: String(repeating: "x", count: exactByteCount - emptyPadded.count))
    }

    private func append(_ data: Data, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    // MARK: - The date seam on the two handlers that WRITE codex activity

    /// Pinned through the router's date seam, so each stored stamp is an exact
    /// assertion rather than a freshness window.
    static let observedAt = Date(timeIntervalSince1970: 1_781_234_567)

    /// A second router over the same database, with its `now` pinned.
    ///
    /// `setActivityState` defaults `observedAt` to a bare `Date()` **at the
    /// store**, so a handler that omits the argument mints a timestamp nothing
    /// outside the store can name. That is not a cosmetic difference: the stamp
    /// is *compared* — `SessionStateResolver` orders it against the
    /// awaiting-input stamp at rung 4 to decide which observation is newer — so
    /// per the root `CLAUDE.md` date-seam rule it is data, and it belongs on the
    /// router's seam like every sibling call site in this file.
    private func pinnedRouter() -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            now: { Self.observedAt },
            actuationLog: makeTestActuationLog())
    }

    @Test("terminal.sessionEvent stamps the codex idle observation from the router's date seam")
    func sessionEventStampsFromTheDateSeam() async throws {
        let repo = try await db.repos.create(
            path: "/tmp/car-seam-repo-\(UUID().uuidString)",
            displayName: "car-seam-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: "/tmp/car-seam-wt-\(UUID().uuidString)", tmuxServer: "tbd-car-seam")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)

        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id, sessionID: "codex-session",
                transcriptPath: nil, source: "SessionStart"))
        #expect(await pinnedRouter().handle(request).success)

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.activityState == .idle)
        #expect(after.activityStateObservedAt == Self.observedAt)
        #expect(after.observedActivity?.observedAt == Self.observedAt)
    }

    @Test("terminal.recreateWindow stamps the derived codex unknown from the router's date seam")
    func recreateWindowStampsFromTheDateSeam() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-car-recreate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = try await db.repos.create(
            path: root.path, displayName: "car-recreate-repo", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "main",
            path: root.path, tmuxServer: "tbd-car-recreate")
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@old", tmuxPaneID: "%old",
            label: TerminalLabel.codex, kind: .codex)
        // A prior observation, so "the stamp moved" is a real claim rather than
        // a column that happened to be nil before and non-nil after.
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .working, source: .hookEvent("TurnStart"),
            observedAt: Date(timeIntervalSince1970: 1_770_000_000))

        let router = pinnedRouter()
        router.codexExecutableResolver = { "/opt/test/bin/codex" }
        router.codexHomeEnsurer = { root.appendingPathComponent("codex-home", isDirectory: true) }

        let request = try RPCRequest(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminal.id))
        let response = await router.handle(request)
        #expect(response.success, "expected success; error: \(response.error ?? "nil")")

        let after = try #require(try await db.terminals.get(id: terminal.id))
        #expect(after.activityState == .unknown)
        #expect(after.activityStateObservedAt == Self.observedAt)
        #expect(after.observedActivity?.observedAt == Self.observedAt)
    }
}

private func waitUntilAsync(
    _ condition: @escaping @Sendable () async -> Bool,
    timeout: Duration = .seconds(2)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    repeat {
        if await condition() { return true }
        await Task.yield()
    } while clock.now < deadline
    return false
}

private final class BlockingListDates: @unchecked Sendable {
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
            release.wait()
            return first
        }
    }

    func releaseFirstCall() {
        release.signal()
    }
}
