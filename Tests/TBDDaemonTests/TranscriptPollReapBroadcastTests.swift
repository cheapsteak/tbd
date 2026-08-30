import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `terminal.transcript` runs `PendingQuestionStore.gcExpired`, which reaps
/// across EVERY terminal — not just the polled one. During the
/// `appSideTranscriptRead` soak the two paths run side by side, so a flag-off
/// terminal's poll can reap a flag-on terminal's stranded capture. Without a
/// broadcast for that terminal the app never hears about it:
/// `PendingQuestionExpirySweep` then finds nothing left to reap and stays
/// silent, so the flag-on pane renders "waiting for your answer" forever.
@Suite("terminal.transcript broadcasts every terminal its gc reaped")
struct TranscriptPollReapBroadcastTests {

    /// Router whose handlers broadcast into `deltas`.
    private func makeRouter(db: TBDDatabase) -> (router: RPCRouter, deltas: CapturedDeltas) {
        let deltas = CapturedDeltas()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            subscriptions: subs,
            actuationLog: makeTestActuationLog()
        )
        return (router, deltas)
    }

    /// A terminal the transcript handler will run all the way through: it has
    /// a session id, an owning worktree, and a transcript path. The path names
    /// a file that does not exist, so the parse yields no items and the test
    /// measures only the pending-question side of the handler.
    private func makeTerminal(db: TBDDatabase, index: Int) async throws -> Terminal {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo-\(index)",
            defaultBranch: "main"
        )
        let worktree = try await db.worktrees.create(
            repoID: repo.id,
            name: "wt-\(index)",
            branch: "tbd/wt-\(index)",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )
        let sessionID = UUID().uuidString
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id,
            tmuxWindowID: "@mock-\(index)",
            tmuxPaneID: "%mock-\(index)",
            claudeSessionID: sessionID
        )
        try await db.terminals.updateSession(
            id: terminal.id,
            sessionID: sessionID,
            transcriptPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-missing-transcript-\(UUID().uuidString).jsonl").path
        )
        return try #require(await db.terminals.get(id: terminal.id))
    }

    private func requestTranscript(router: RPCRouter, terminalID: UUID) async -> RPCResponse {
        let request = try! RPCRequest(
            method: RPCMethod.terminalTranscript,
            params: TerminalTranscriptParams(terminalID: terminalID)
        )
        return await router.handle(request)
    }

    private func pendingDeltas(_ deltas: CapturedDeltas) -> [TerminalPendingQuestionsDelta] {
        deltas.all.compactMap {
            if case .terminalPendingQuestionsChanged(let d) = $0 { return d }
            return nil
        }
    }

    @Test("a poll of one terminal broadcasts the retraction for another terminal it reaped")
    func reapOfAnotherTerminalIsBroadcast() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let polled = try await makeTerminal(db: db, index: 0)
        let other = try await makeTerminal(db: db, index: 1)

        // Stranded well past the handler's 900s max age, on the terminal that
        // is NOT being polled.
        await router.pendingQuestions.set(terminalID: other.id, PendingAskUserQuestion(
            toolUseID: "toolu_stranded",
            inputJSON: "{\"questions\":[]}",
            timestamp: Date().addingTimeInterval(-10_000)))

        let response = await requestTranscript(router: router, terminalID: polled.id)
        #expect(response.success)

        #expect(await router.pendingQuestions.entries(forTerminal: other.id).isEmpty,
                "the poll's gc should still reap across terminals")

        let broadcasts = pendingDeltas(deltas)
        let forOther = broadcasts.filter { $0.terminalID == other.id }
        #expect(forOther.count == 1,
                "the reaped terminal owes the app exactly one retraction, got \(broadcasts.count) deltas")
        #expect(forOther.first?.pending.isEmpty == true,
                "an empty set is the retraction")
    }

    @Test("a terminal both reaped and satisfied is broadcast once")
    func polledTerminalIsBroadcastOnce() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let polled = try await makeTerminal(db: db, index: 0)

        // One stranded entry (reaped by the gc) plus one fresh entry. The
        // fresh one is not satisfied — the transcript file is empty — so the
        // union must still yield exactly one broadcast for this terminal.
        await router.pendingQuestions.set(terminalID: polled.id, PendingAskUserQuestion(
            toolUseID: "toolu_stranded",
            inputJSON: "{\"questions\":[]}",
            timestamp: Date().addingTimeInterval(-10_000)))
        await router.pendingQuestions.set(terminalID: polled.id, PendingAskUserQuestion(
            toolUseID: "toolu_fresh",
            inputJSON: "{\"questions\":[]}",
            timestamp: Date()))

        let response = await requestTranscript(router: router, terminalID: polled.id)
        #expect(response.success)

        let forPolled = pendingDeltas(deltas).filter { $0.terminalID == polled.id }
        #expect(forPolled.count == 1)
        #expect(forPolled.first?.pending.map(\.toolUseID) == ["toolu_fresh"],
                "the surviving entry rides the same broadcast")
    }

    @Test("a poll that reaps nothing and satisfies nothing broadcasts nothing")
    func quietPollBroadcastsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db: db)
        let polled = try await makeTerminal(db: db, index: 0)
        await router.pendingQuestions.set(terminalID: polled.id, PendingAskUserQuestion(
            toolUseID: "toolu_fresh",
            inputJSON: "{\"questions\":[]}",
            timestamp: Date()))

        _ = await requestTranscript(router: router, terminalID: polled.id)

        #expect(pendingDeltas(deltas).isEmpty)
    }
}

/// Collects broadcast deltas from the subscription callback, which runs on
/// whatever thread the handler broadcast from.
private final class CapturedDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StateDelta] = []
    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        storage.append(delta)
    }
    var all: [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
