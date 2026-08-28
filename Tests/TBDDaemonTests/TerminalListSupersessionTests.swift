import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Records every path the list pass measured, and answers with one fixed
/// fingerprint. The call log is what lets a test assert the stat never happened.
private final class ListFingerprintSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    let result: TranscriptFingerprint?

    init(result: TranscriptFingerprint?) { self.result = result }

    var fingerprinter: TranscriptFingerprinter {
        { [self] path in
            lock.lock()
            _calls.append(path)
            lock.unlock()
            return result
        }
    }
}

/// Thread-safe collector for broadcast StateDeltas.
private final class ListBroadcastDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}

/// Tier 1. `terminal.list` supersedes a standing prompt on the pass that is
/// about to report it.
///
/// Three things have to agree, and each is asserted separately because a
/// partial fix can satisfy any one of them alone: the row in the RESPONSE, the
/// row in the DATABASE, and the `.terminalAwaitingInputChanged` delta the app
/// mirrors its own copy from. A response corrected without a write reports a
/// prompt the next poll raises again; a write without a broadcast leaves the
/// indicator standing until that poll.
@Suite struct TerminalListSupersessionTests {
    let db: TBDDatabase
    let worktreeID: UUID
    let terminalID: UUID
    private let subscriptions: StateSubscriptionManager
    private let broadcasts: ListBroadcastDeltas

    static let observedAt = Date(timeIntervalSince1970: 1_780_000_000)
    static let modifiedAt = Date(timeIntervalSince1970: 1_779_900_000)
    static let transcriptPath = "/tmp/terminal-list-supersession.jsonl"

    init() async throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        let broadcasts = ListBroadcastDeltas()
        self.broadcasts = broadcasts
        let subscriptions = StateSubscriptionManager()
        self.subscriptions = subscriptions
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                broadcasts.append(delta)
            }
            return true
        }
        let repo = try await db.repos.create(
            path: "/tmp/tls-repo-\(UUID().uuidString)", displayName: "T", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/tls-wt-\(UUID().uuidString)", tmuxServer: "tbd-tls")
        worktreeID = wt.id
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "s-1", kind: .claude)
        terminalID = terminal.id
        try await db.terminals.updateSession(
            id: terminal.id, sessionID: "s-1", transcriptPath: Self.transcriptPath)
    }

    private static func fingerprint(size: Int64) -> TranscriptFingerprint {
        TranscriptFingerprint(path: transcriptPath, modifiedAt: modifiedAt, size: size)
    }

    private func record(type: String, fingerprint: TranscriptFingerprint?) async throws {
        _ = try await db.terminals.recordAwaitingInputReason(
            id: terminalID,
            reason: AwaitingInputReason(
                message: "Claude needs your permission to use Bash",
                hookEventName: "Notification",
                raw: "{}",
                notificationType: type,
                transcriptFingerprint: fingerprint),
            observedAt: Self.observedAt)
    }

    private func router(_ spy: ListFingerprintSpy) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subscriptions,
            now: { Self.observedAt },
            transcriptFingerprinter: spy.fingerprinter,
            actuationLog: makeTestActuationLog())
    }

    /// The response rows, through the real RPC surface the app calls.
    private func list(_ spy: ListFingerprintSpy) async throws -> [Terminal] {
        let request = try RPCRequest(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: worktreeID))
        let response = await router(spy).handle(request)
        #expect(response.success)
        return try response.decodeResult([Terminal].self)
    }

    private func awaitingInputDeltas() -> [TerminalAwaitingInputDelta] {
        broadcasts.snapshot().compactMap { delta in
            if case .terminalAwaitingInputChanged(let d) = delta { return d }
            return nil
        }
    }

    @Test func terminalListRetractsAPromptWhoseTranscriptMoved() async throws {
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        let spy = ListFingerprintSpy(result: Self.fingerprint(size: 20))

        let reported = try await list(spy)
        let row = try #require(reported.first { $0.id == terminalID })
        #expect(row.awaitingInputReason == nil, "this pass must not report a prompt it retracted")
        #expect(row.awaitingInputObservedAt == nil)
        #expect(row.hasPromptOnScreen == false)

        let stored = try #require(try await db.terminals.get(id: terminalID))
        #expect(stored.awaitingInputReason == nil)
        #expect(stored.awaitingInputObservedAt == nil)

        let deltas = awaitingInputDeltas()
        #expect(deltas.count == 1)
        #expect(deltas.first?.terminalID == terminalID)
        #expect(deltas.first?.worktreeID == worktreeID)
        #expect(deltas.first?.reason == nil)
        #expect(deltas.first?.observedAt == nil)
        #expect(spy.calls == [Self.transcriptPath])
    }

    /// A session sitting on a permission prompt writes nothing, so an unchanged
    /// file is the pending case — and the app must hear nothing about it.
    @Test func terminalListLeavesAPendingPromptRaised() async throws {
        try await record(type: "permission_prompt", fingerprint: Self.fingerprint(size: 10))
        let spy = ListFingerprintSpy(result: Self.fingerprint(size: 10))

        let reported = try await list(spy)
        let row = try #require(reported.first { $0.id == terminalID })
        let reason = try #require(row.awaitingInputReason)
        #expect(reason.classification == .promptOnScreen)
        #expect(reason.transcriptFingerprint == Self.fingerprint(size: 10))
        #expect(row.hasPromptOnScreen)
        #expect(row.awaitingInputObservedAt == Self.observedAt)

        #expect(try await db.terminals.get(id: terminalID)?.awaitingInputReason != nil)
        #expect(awaitingInputDeltas().isEmpty)
        #expect(spy.calls == [Self.transcriptPath])
    }

    /// Only a raised hand can be lowered. A `doneWaiting` reason is not one, so
    /// the pass neither stats nor announces anything for it.
    @Test func terminalListDoesNotBroadcastForANonPromptReason() async throws {
        try await record(type: "idle_prompt", fingerprint: nil)
        let spy = ListFingerprintSpy(result: Self.fingerprint(size: 20))

        let reported = try await list(spy)
        let row = try #require(reported.first { $0.id == terminalID })
        let reason = try #require(row.awaitingInputReason)
        #expect(reason.classification == .doneWaiting)

        #expect(try await db.terminals.get(id: terminalID)?.awaitingInputReason != nil)
        #expect(awaitingInputDeltas().isEmpty)
        #expect(spy.calls.isEmpty)
    }
}
