import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

@Suite("terminal.activityEvent handler")
struct TerminalActivityEventHandlerTests {
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
        kind: TerminalKind = .codex,
        label: String = "Codex"
    ) async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/ta-repo-\(UUID().uuidString)",
            displayName: "ta-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt",
            branch: "main",
            path: "/tmp/ta-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-ta"
        )
        return try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: label,
            kind: kind
        )
    }

    @Test("updates activity state in DB")
    func updatesActivityState() async throws {
        let terminal = try await makeTerminal()
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminal.id,
                activityState: .working
            )
        )

        let response = await router.handle(request)
        #expect(response.success)

        let updated = try await db.terminals.get(id: terminal.id)
        #expect(updated?.activityState == .working)
    }

    @Test("unknown terminalID is a soft no-op")
    func unknownTerminalSoftSuccess() async throws {
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: UUID(),
                activityState: .idle
            )
        )

        let response = await router.handle(request)
        #expect(response.success)
        #expect(response.error == nil)
    }

    @Test("user interrupt persists distinct provenance from working state")
    func userInterruptPersistsProvenanceFromWorking() async throws {
        let terminal = try await makeTerminal()
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .working,
            source: .hookEvent(RPCMethod.terminalActivityEvent)
        )
        let request = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"idle","origin":"user_interrupt"}"#
        )

        let response = await router.handle(request)

        #expect(response.success)
        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .idle)
        #expect(updated.activityStateSource?.kind == "user-action")
        #expect(updated.activityStateSource?.detail == "terminal-interrupt")
    }

    @Test("user interrupt replaces provenance when raw state is already idle")
    func userInterruptPersistsProvenanceFromIdle() async throws {
        let terminal = try await makeTerminal()
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .idle,
            source: .hookEvent(RPCMethod.terminalActivityEvent)
        )
        let request = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"idle","origin":"user_interrupt"}"#
        )

        let response = await router.handle(request)

        #expect(response.success)
        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .idle)
        #expect(updated.activityStateSource?.kind == "user-action")
        #expect(updated.activityStateSource?.detail == "terminal-interrupt")
    }

    @Test("same-state hook does not erase an explicit interrupt")
    func sameStateHookPreservesInterrupt() async throws {
        let terminal = try await makeTerminal()
        let interruptSource = try JSONDecoder().decode(
            FactSource.self,
            from: Data(#"{"kind":"user-action","detail":"terminal-interrupt"}"#.utf8)
        )
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .idle,
            source: interruptSource
        )
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminal.id,
                activityState: .idle
            )
        )

        let response = await router.handle(request)

        #expect(response.success)
        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityStateSource?.kind == "user-action")
        #expect(updated.activityStateSource?.detail == "terminal-interrupt")
    }

    @Test("later working hook supersedes an explicit interrupt")
    func laterWorkingHookSupersedesInterrupt() async throws {
        let terminal = try await makeTerminal()
        let interrupt = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"idle","origin":"user_interrupt"}"#
        )
        #expect((await router.handle(interrupt)).success)

        let working = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminal.id,
                activityState: .working
            )
        )
        #expect((await router.handle(working)).success)

        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .working)
        #expect(updated.activityStateSource == .hookEvent(RPCMethod.terminalActivityEvent))
    }

    @Test("user interrupt is not counted as an agent hook event")
    func userInterruptDoesNotIncrementHookCounter() async throws {
        let terminal = try await makeTerminal()
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-activity-\(UUID().uuidString).jsonl")
        try Data().write(to: transcript)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let request = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"idle","origin":"user_interrupt"}"#
        )

        #expect((await router.handle(request)).success)

        let counters = try #require(await router.sessionCounters.sample(
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            transcriptPath: transcript.path,
            commitsUnchangedSince: nil
        ))
        #expect(counters.hookEventsInWindow == 0)
    }

    @Test("user interrupt origin rejects a non-idle state without mutation or hook count")
    func userInterruptRejectsNonIdleState() async throws {
        let terminal = try await makeTerminal()
        let originalObservedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .idle,
            source: .hookEvent(RPCMethod.terminalActivityEvent),
            observedAt: originalObservedAt
        )
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-terminal-activity-\(UUID().uuidString).jsonl")
        try Data().write(to: transcript)
        defer { try? FileManager.default.removeItem(at: transcript) }
        let request = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"working","origin":"user_interrupt"}"#
        )

        let response = await router.handle(request)

        #expect(!response.success)
        #expect(response.error == "user_interrupt origin requires idle activity")
        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .idle)
        #expect(updated.activityStateSource == .hookEvent(RPCMethod.terminalActivityEvent))
        #expect(updated.activityStateObservedAt == originalObservedAt)
        let counters = try #require(await router.sessionCounters.sample(
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            transcriptPath: transcript.path,
            commitsUnchangedSince: nil
        ))
        #expect(counters.hookEventsInWindow == 0)
    }

    @Test("an earlier idle hook cannot erase a later explicit interrupt")
    func earlierIdleHookCannotEraseLaterInterrupt() async throws {
        let terminal = try await makeTerminal()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = old.addingTimeInterval(1)
        let dates = BlockingDateSequence(first: old, subsequent: new)
        let router = makeRouter(now: dates.provider)
        let idle = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminal.id, activityState: .idle)
        )
        let interrupt = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"idle","origin":"user_interrupt"}"#
        )

        let earlier = Task { await router.handle(idle) }
        guard await waitUntil({ dates.firstCallIsBlocked }) else {
            dates.releaseFirstCall()
            _ = await earlier.value
            Issue.record("earlier idle event never reached the date seam")
            return
        }
        #expect((await router.handle(interrupt)).success)
        dates.releaseFirstCall()
        #expect((await earlier.value).success)

        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .idle)
        #expect(updated.activityStateSource == .terminalInterrupt)
        #expect(updated.activityStateObservedAt == new)
    }

    @Test("a later working hook cannot be lost behind an earlier interrupt")
    func laterWorkingCannotBeLostBehindEarlierInterrupt() async throws {
        let terminal = try await makeTerminal()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = old.addingTimeInterval(1)
        let dates = BlockingDateSequence(first: old, subsequent: new)
        let router = makeRouter(now: dates.provider)
        let interrupt = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"idle","origin":"user_interrupt"}"#
        )
        let working = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminal.id, activityState: .working)
        )

        let earlier = Task { await router.handle(interrupt) }
        guard await waitUntil({ dates.firstCallIsBlocked }) else {
            dates.releaseFirstCall()
            _ = await earlier.value
            Issue.record("earlier interrupt never reached the date seam")
            return
        }
        #expect((await router.handle(working)).success)
        dates.releaseFirstCall()
        #expect((await earlier.value).success)

        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .working)
        #expect(updated.activityStateSource == .hookEvent(RPCMethod.terminalActivityEvent))
        #expect(updated.activityStateObservedAt == new)
    }

    @Test("a later same-state working hook advances order ahead of a delayed idle")
    func laterSameStateWorkingAdvancesOrderAheadOfDelayedIdle() async throws {
        let terminal = try await makeTerminal()
        let initial = Date(timeIntervalSince1970: 1_700_000_000)
        let earlierIdleAt = initial.addingTimeInterval(1)
        let laterWorkingAt = initial.addingTimeInterval(2)
        let originalSource = FactSource.hookEvent("UserPromptSubmit")
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .working,
            source: originalSource,
            observedAt: initial,
            awaitingInputReason: AwaitingInputReason(
                message: "stale prompt",
                hookEventName: "Notification",
                notificationType: "permission_prompt"
            )
        )
        let dates = BlockingDateSequence(first: earlierIdleAt, subsequent: laterWorkingAt)
        let router = makeRouter(now: dates.provider)
        let idle = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminal.id, activityState: .idle)
        )
        let working = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminal.id, activityState: .working)
        )

        let earlier = Task { await router.handle(idle) }
        guard await waitUntil({ dates.firstCallIsBlocked }) else {
            dates.releaseFirstCall()
            _ = await earlier.value
            Issue.record("earlier idle event never reached the date seam")
            return
        }
        #expect((await router.handle(working)).success)
        dates.releaseFirstCall()
        #expect((await earlier.value).success)

        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .working)
        #expect(updated.activityStateSource == originalSource)
        #expect(updated.activityStateObservedAt == initial)
        #expect(updated.awaitingInputReason == nil)
        #expect(updated.awaitingInputObservedAt == nil)
        let orderObservedAt = try await db.writerForTests.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT activityStateOrderObservedAt FROM terminal WHERE id = ?",
                arguments: [terminal.id.uuidString]
            )
        }
        #expect(orderObservedAt == laterWorkingAt)
    }

    @Test("a newer same-state idle hook advances order without erasing interrupt provenance")
    func newerSameStateIdleAdvancesOrderWithoutErasingInterrupt() async throws {
        let terminal = try await makeTerminal()
        let interruptedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let refreshedAt = interruptedAt.addingTimeInterval(1)
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .idle,
            source: .terminalInterrupt,
            observedAt: interruptedAt
        )

        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id,
            activityState: .idle,
            source: .hookEvent(RPCMethod.terminalActivityEvent),
            observedAt: refreshedAt
        )

        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .idle)
        #expect(updated.activityStateSource == .terminalInterrupt)
        #expect(updated.activityStateObservedAt == interruptedAt)
        let orderObservedAt = try await db.writerForTests.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT activityStateOrderObservedAt FROM terminal WHERE id = ?",
                arguments: [terminal.id.uuidString]
            )
        }
        #expect(orderObservedAt == refreshedAt)
    }

    @Test(
        "a delayed activity observation cannot erase a newer permission prompt",
        arguments: [TerminalActivityState.working, .idle]
    )
    func delayedActivityPreservesNewerPermissionPrompt(
        activityState: TerminalActivityState
    ) async throws {
        let terminal = try await makeTerminal(kind: .claude, label: "Claude")
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let earlierActivityAt = baseline.addingTimeInterval(1)
        let laterPromptAt = baseline.addingTimeInterval(2)
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .working,
            source: .hookEvent("UserPromptSubmit"),
            observedAt: baseline
        )
        let dates = BlockingDateSequence(
            first: earlierActivityAt,
            subsequent: laterPromptAt)
        let router = makeRouter(now: dates.provider)
        let activity = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminal.id,
                activityState: activityState
            )
        )
        let notification = try RPCRequest(
            method: RPCMethod.terminalNotificationEvent,
            params: TerminalNotificationEventParams(
                terminalID: terminal.id,
                notificationType: "permission_prompt",
                message: "Claude needs permission"
            )
        )

        let earlier = Task { await router.handle(activity) }
        guard await waitUntil({ dates.firstCallIsBlocked }) else {
            dates.releaseFirstCall()
            _ = await earlier.value
            Issue.record("earlier activity never reached the date seam")
            return
        }
        #expect((await router.handle(notification)).success)
        dates.releaseFirstCall()
        #expect((await earlier.value).success)

        let updated = try #require(await db.terminals.get(id: terminal.id))
        let reason = try #require(updated.awaitingInputReason)
        #expect(reason.classification == .promptOnScreen)
        #expect(updated.awaitingInputObservedAt == laterPromptAt)
        let resolved = SessionStateResolver(now: { laterPromptAt }).resolve(
            SessionStateFacts(terminal: updated))
        #expect(resolved.value == .awaitingInput(reason: reason))
        #expect(resolved.observedAt == laterPromptAt)
    }

    @Test("a same-time earlier working hook cannot erase a later interrupt")
    func sameTimeEarlierWorkingCannotEraseLaterInterrupt() async throws {
        let terminal = try await makeTerminal()
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = BlockingDateSequence(first: instant, subsequent: instant)
        let router = makeRouter(now: dates.provider)
        let working = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminal.id, activityState: .working)
        )
        let interrupt = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"idle","origin":"user_interrupt"}"#
        )

        let earlier = Task { await router.handle(working) }
        guard await waitUntil({ dates.firstCallIsBlocked }) else {
            dates.releaseFirstCall()
            _ = await earlier.value
            Issue.record("earlier working event never reached the date seam")
            return
        }
        #expect((await router.handle(interrupt)).success)
        dates.releaseFirstCall()
        #expect((await earlier.value).success)

        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .idle)
        #expect(updated.activityStateSource == .terminalInterrupt)
        #expect(updated.activityStateObservedAt == instant)
    }

    @Test("a same-time earlier working hook cannot erase a later idle hook")
    func sameTimeEarlierWorkingCannotEraseLaterIdle() async throws {
        let terminal = try await makeTerminal()
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let dates = BlockingDateSequence(first: instant, subsequent: instant)
        let router = makeRouter(now: dates.provider)
        let working = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminal.id, activityState: .working)
        )
        let idle = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminal.id, activityState: .idle)
        )

        let earlier = Task { await router.handle(working) }
        guard await waitUntil({ dates.firstCallIsBlocked }) else {
            dates.releaseFirstCall()
            _ = await earlier.value
            Issue.record("earlier working event never reached the date seam")
            return
        }
        #expect((await router.handle(idle)).success)
        dates.releaseFirstCall()
        #expect((await earlier.value).success)

        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .idle)
        #expect(updated.activityStateSource == .hookEvent(RPCMethod.terminalActivityEvent))
        #expect(updated.activityStateObservedAt == instant)
        let orderObservedAt = try await db.writerForTests.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT activityStateOrderObservedAt FROM terminal WHERE id = ?",
                arguments: [terminal.id.uuidString]
            )
        }
        #expect(orderObservedAt == instant)
    }

    @Test("a same-time idle hook cannot erase a permission wait")
    func sameTimeIdleCannotEraseWaitingForUser() async throws {
        let terminal = try await makeTerminal()
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.terminals.setActivityState(
            id: terminal.id,
            activityState: .waitingForUser,
            source: .hookEvent("PermissionRequest"),
            observedAt: instant
        )

        _ = try await db.terminals.applyActivityObservation(
            id: terminal.id,
            activityState: .idle,
            source: .hookEvent("Stop"),
            observedAt: instant
        )

        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .waitingForUser)
        #expect(updated.activityStateSource == .hookEvent("PermissionRequest"))
        #expect(updated.activityStateObservedAt == instant)
    }

    @Test("an earlier SessionStart cannot erase a later explicit interrupt")
    func earlierSessionStartCannotEraseLaterInterrupt() async throws {
        let terminal = try await makeTerminal()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = old.addingTimeInterval(1)
        let dates = BlockingDateSequence(first: old, subsequent: new)
        let router = makeRouter(now: dates.provider)
        let sessionStart = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminal.id,
                sessionID: "new-session",
                transcriptPath: nil,
                source: "startup"
            )
        )
        let interrupt = RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: #"{"terminalID":"\#(terminal.id.uuidString)","activityState":"idle","origin":"user_interrupt"}"#
        )

        let earlier = Task { await router.handle(sessionStart) }
        guard await waitUntil({ dates.firstCallIsBlocked }) else {
            dates.releaseFirstCall()
            _ = await earlier.value
            Issue.record("earlier SessionStart never reached the date seam")
            return
        }
        #expect((await router.handle(interrupt)).success)
        dates.releaseFirstCall()
        #expect((await earlier.value).success)

        let updated = try #require(await db.terminals.get(id: terminal.id))
        #expect(updated.activityState == .idle)
        #expect(updated.activityStateSource == .terminalInterrupt)
        #expect(updated.activityStateObservedAt == new)
    }
}

private final class BlockingDateSequence: @unchecked Sendable {
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
