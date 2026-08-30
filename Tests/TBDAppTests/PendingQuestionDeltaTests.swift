import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

/// The app half of the pending-`AskUserQuestion` hand-off: the pure merge the
/// daemon's `terminal.transcript` handler used to run, and the mirror
/// `AppState` keeps of the daemon's store.
@Suite("pending question merge")
struct PendingQuestionMergeTests {

    private let pending = PendingAskUserQuestion(
        toolUseID: "toolu_01",
        inputJSON: #"{"questions":[]}"#,
        timestamp: Date(timeIntervalSince1970: 1000))

    @Test("a pending question renders before its JSONL line lands")
    func synthesizesBeforeJSONL() {
        let merged = AskUserQuestionMerger.merge(jsonlItems: [], pending: [pending])
        #expect(merged.items.count == 1)
        #expect(merged.satisfiedToolUseIDs.isEmpty)
    }

    @Test("the arriving JSONL line replaces the synthetic item, never duplicates it")
    func replacedNotDuplicated() {
        let real = TranscriptItem.toolCall(
            id: "toolu_01", name: "AskUserQuestion", inputJSON: #"{"questions":[]}"#,
            inputTruncatedTo: nil, result: nil, subagent: nil,
            timestamp: Date(timeIntervalSince1970: 1001), usage: nil)
        let merged = AskUserQuestionMerger.merge(jsonlItems: [real], pending: [pending])
        #expect(merged.items.count == 1, "must not render the question twice")
        #expect(merged.satisfiedToolUseIDs == ["toolu_01"])
    }

    @Test("an empty delta retracts a previously pending question")
    func emptyDeltaRetracts() {
        let merged = AskUserQuestionMerger.merge(jsonlItems: [], pending: [])
        #expect(merged.items.isEmpty)
    }
}

/// `AppState` mirrors the daemon's store rather than deriving it, so these
/// pin both halves: the delta lands, and the session-keyed lookup the
/// transcript publish path uses finds it.
///
/// Every AppState-touching test constructs `AppState(userDefaults:)` against a
/// unique throwaway suite — TBDApp ships as an unbundled SPM executable, so
/// `UserDefaults.standard` is the running developer's real `TBDApp.plist`.
@MainActor
@Suite("pending question delta")
struct PendingQuestionDeltaTests {

    private func withAppState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.PendingQuestionDelta.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func payload(_ toolUseID: String) -> PendingQuestionPayload {
        PendingQuestionPayload(
            toolUseID: toolUseID,
            inputJSON: #"{"questions":[]}"#,
            timestamp: Date(timeIntervalSince1970: 1000))
    }

    private func terminal(id: UUID, worktreeID: UUID, sessionID: String?) -> Terminal {
        Terminal(
            id: id, worktreeID: worktreeID,
            tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: sessionID)
    }

    @Test("the delta populates the mirror")
    func deltaPopulatesMirror() {
        withAppState { state in
            let terminalID = UUID()
            state.handleDelta(.terminalPendingQuestionsChanged(
                TerminalPendingQuestionsDelta(
                    terminalID: terminalID, pending: [payload("toolu_01")])))
            #expect(state.pendingQuestions[terminalID]?.map(\.toolUseID) == ["toolu_01"])
        }
    }

    @Test("an empty delta retracts the mirrored set")
    func emptyDeltaClearsMirror() {
        withAppState { state in
            let terminalID = UUID()
            state.handleDelta(.terminalPendingQuestionsChanged(
                TerminalPendingQuestionsDelta(
                    terminalID: terminalID, pending: [payload("toolu_01")])))
            state.handleDelta(.terminalPendingQuestionsChanged(
                TerminalPendingQuestionsDelta(terminalID: terminalID, pending: [])))
            #expect(state.pendingQuestions[terminalID] == nil,
                    "a set cleared without a retraction renders an answered question forever")
        }
    }

    @Test("the session lookup joins through the terminal that owns the session")
    func lookupJoinsOnTerminal() {
        withAppState { state in
            let worktreeID = UUID()
            let mine = UUID()
            let other = UUID()
            state.terminals[worktreeID] = [
                terminal(id: other, worktreeID: worktreeID, sessionID: "session-b"),
                terminal(id: mine, worktreeID: worktreeID, sessionID: "session-a"),
            ]
            state.handleDelta(.terminalPendingQuestionsChanged(
                TerminalPendingQuestionsDelta(
                    terminalID: mine, pending: [payload("toolu_01")])))

            #expect(state.pendingQuestionsForSession("session-a").map(\.toolUseID) == ["toolu_01"])
            #expect(state.pendingQuestionsForSession("session-b").isEmpty,
                    "another terminal's question must not leak into this session's transcript")
            #expect(state.pendingQuestionsForSession("session-unknown").isEmpty)
        }
    }

    @Test("the lookup is empty when nothing is pending")
    func lookupEmptyWithoutPending() {
        withAppState { state in
            let worktreeID = UUID()
            state.terminals[worktreeID] = [
                terminal(id: UUID(), worktreeID: worktreeID, sessionID: "session-a")
            ]
            #expect(state.pendingQuestionsForSession("session-a").isEmpty)
        }
    }

    @Test("the delta survives a JSON round trip")
    func deltaRoundTrips() throws {
        let terminalID = UUID()
        let delta = StateDelta.terminalPendingQuestionsChanged(
            TerminalPendingQuestionsDelta(terminalID: terminalID, pending: [payload("toolu_01")]))
        let data = try JSONEncoder().encode(delta)
        let decoded = try JSONDecoder().decode(StateDelta.self, from: data)
        guard case .terminalPendingQuestionsChanged(let d) = decoded else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(d.terminalID == terminalID)
        #expect(d.pending.map(\.toolUseID) == ["toolu_01"])
    }
}

/// Ordering. The daemon publishes in two hops — mutate the store, then read it
/// back and send — and only the first hop is ordered, so two deltas for one
/// terminal can arrive out of order. Since each delta carries the WHOLE set,
/// applying a stale one is a rollback: a `set` landing after the `clear` that
/// retracted it puts an answered question back on screen for good. The
/// per-terminal revision the daemon stamps is what makes the loser droppable.
@MainActor
@Suite("pending question delta ordering")
struct PendingQuestionDeltaOrderingTests {

    private func withAppState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.PendingQuestionOrdering.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func payload(_ toolUseID: String) -> PendingQuestionPayload {
        PendingQuestionPayload(
            toolUseID: toolUseID,
            inputJSON: #"{"questions":[]}"#,
            timestamp: Date(timeIntervalSince1970: 1000))
    }

    private func delta(
        _ terminalID: UUID, _ pending: [PendingQuestionPayload], revision: UInt64?
    ) -> StateDelta {
        .terminalPendingQuestionsChanged(TerminalPendingQuestionsDelta(
            terminalID: terminalID, pending: pending, revision: revision))
    }

    @Test("a set that loses the race to its own retraction is dropped")
    func staleSetDoesNotResurrectAClearedQuestion() {
        withAppState { state in
            let terminalID = UUID()
            // The clear was produced by the later mutation, but reached the
            // app first — the exact interleaving the revision exists for.
            state.handleDelta(delta(terminalID, [], revision: 2))
            state.handleDelta(delta(terminalID, [payload("toolu_01")], revision: 1))
            #expect(state.pendingQuestions[terminalID] == nil,
                    "the stale set resurrected an answered question")
        }
    }

    @Test("a newer revision applies")
    func newerRevisionApplies() {
        withAppState { state in
            let terminalID = UUID()
            state.handleDelta(delta(terminalID, [payload("toolu_01")], revision: 1))
            #expect(state.pendingQuestions[terminalID]?.map(\.toolUseID) == ["toolu_01"])
            state.handleDelta(delta(terminalID, [payload("toolu_02")], revision: 2))
            #expect(state.pendingQuestions[terminalID]?.map(\.toolUseID) == ["toolu_02"])
            state.handleDelta(delta(terminalID, [], revision: 3))
            #expect(state.pendingQuestions[terminalID] == nil)
        }
    }

    @Test("the first delta for an unknown terminal applies whatever its revision")
    func firstDeltaAlwaysApplies() {
        withAppState { state in
            let terminalID = UUID()
            // A daemon that has been running a while stamps a high revision;
            // an app that just launched holds none. That must not read as
            // stale.
            state.handleDelta(delta(terminalID, [payload("toolu_01")], revision: 4096))
            #expect(state.pendingQuestions[terminalID]?.map(\.toolUseID) == ["toolu_01"])
        }
    }

    @Test("a repeated revision still applies")
    func equalRevisionApplies() {
        withAppState { state in
            let terminalID = UUID()
            state.handleDelta(delta(terminalID, [payload("toolu_01")], revision: 7))
            state.handleDelta(delta(terminalID, [], revision: 7))
            #expect(state.pendingQuestions[terminalID] == nil,
                    "only a STRICTLY older revision is stale; equal is the same state, applied twice")
        }
    }

    @Test("an unstamped delta is applied")
    func nilRevisionApplies() {
        withAppState { state in
            let terminalID = UUID()
            state.handleDelta(delta(terminalID, [payload("toolu_01")], revision: 9))
            state.handleDelta(delta(terminalID, [], revision: nil))
            #expect(state.pendingQuestions[terminalID] == nil,
                    "a daemon that predates the field publishes no revision; dropping its deltas would break it")
        }
    }

    @Test("terminals order independently")
    func revisionsAreScopedToTheirTerminal() {
        withAppState { state in
            let busy = UUID()
            let quiet = UUID()
            state.handleDelta(delta(busy, [payload("toolu_busy")], revision: 50))
            state.handleDelta(delta(quiet, [payload("toolu_quiet")], revision: 1))
            #expect(state.pendingQuestions[quiet]?.map(\.toolUseID) == ["toolu_quiet"],
                    "one terminal's high revision must not suppress another's first delta")
        }
    }

    @Test("the revision survives a JSON round trip, and its absence decodes as nil")
    func revisionRoundTrips() throws {
        let terminalID = UUID()
        let encoded = try JSONEncoder().encode(delta(terminalID, [payload("toolu_01")], revision: 12))
        guard case .terminalPendingQuestionsChanged(let d) =
            try JSONDecoder().decode(StateDelta.self, from: encoded) else {
            Issue.record("decoded to the wrong case")
            return
        }
        #expect(d.revision == 12)

        // What a daemon that predates the field puts on the wire: the same
        // delta with no `revision` key at all. Encoding an unstamped delta
        // reproduces that payload — the key must be absent, not null — and it
        // must decode back to nil rather than throwing.
        let legacy = try JSONEncoder().encode(delta(terminalID, [payload("toolu_01")], revision: nil))
        let legacyText = try #require(String(bytes: legacy, encoding: .utf8))
        #expect(!legacyText.contains("revision"),
                "an unstamped delta must omit the key entirely, which is what an older daemon sends")
        guard case .terminalPendingQuestionsChanged(let legacyDelta) =
            try JSONDecoder().decode(StateDelta.self, from: legacy) else {
            Issue.record("legacy payload decoded to the wrong case")
            return
        }
        #expect(legacyDelta.revision == nil)
        #expect(legacyDelta.terminalID == terminalID)
    }
}

/// The app-side read path's other half: with `appSideTranscriptRead` on the
/// daemon's `terminal.transcript` handler never runs, so the app is the only
/// party that can see a capture's `tool_use` line land — and it owes the
/// daemon a report, or the answered card lingers until
/// `PendingQuestionExpirySweep` reaps it up to fifteen minutes later.
///
/// Every case drives a real `AskUserQuestionMerger.merge` result rather than a
/// hand-built id list, so a change to what the merger considers satisfied
/// reaches these assertions.
@Suite("ask user question satisfaction reporter")
struct AskUserQuestionSatisfactionReporterTests {

    /// Records what the reporter asked the daemon to clear.
    private actor Recorder {
        private(set) var calls: [(terminalID: UUID, toolUseIDs: [String])] = []
        func record(_ terminalID: UUID, _ toolUseIDs: [String]) {
            calls.append((terminalID, toolUseIDs))
        }
    }

    private func pending(_ toolUseID: String) -> PendingAskUserQuestion {
        PendingAskUserQuestion(
            toolUseID: toolUseID,
            inputJSON: #"{"questions":[]}"#,
            timestamp: Date(timeIntervalSince1970: 1000))
    }

    private func jsonlToolCall(_ toolUseID: String) -> TranscriptItem {
        .toolCall(
            id: toolUseID, name: "AskUserQuestion", inputJSON: #"{"questions":[]}"#,
            inputTruncatedTo: nil, result: nil, subagent: nil,
            timestamp: Date(timeIntervalSince1970: 1001), usage: nil)
    }

    private func makeReporter(
        _ recorder: Recorder
    ) -> AskUserQuestionSatisfactionReporter {
        AskUserQuestionSatisfactionReporter { terminalID, toolUseIDs in
            await recorder.record(terminalID, toolUseIDs)
        }
    }

    @Test("a merge that reports satisfied ids asks the daemon to clear them")
    func satisfiedIsReported() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder)
        let terminalID = UUID()
        let entries = [pending("toolu_a")]
        let merged = AskUserQuestionMerger.merge(
            jsonlItems: [jsonlToolCall("toolu_a")], pending: entries)

        await reporter.report(
            terminalID: terminalID,
            pendingToolUseIDs: Set(entries.map(\.toolUseID)),
            satisfiedToolUseIDs: merged.satisfiedToolUseIDs)

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls.first?.terminalID == terminalID)
        #expect(calls.first?.toolUseIDs == ["toolu_a"])
    }

    @Test("a merge that reports nothing satisfied sends no RPC")
    func unsatisfiedSendsNothing() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder)
        let entries = [pending("toolu_a")]
        let merged = AskUserQuestionMerger.merge(jsonlItems: [], pending: entries)
        #expect(merged.satisfiedToolUseIDs.isEmpty, "guards the case this test is about")

        await reporter.report(
            terminalID: UUID(),
            pendingToolUseIDs: Set(entries.map(\.toolUseID)),
            satisfiedToolUseIDs: merged.satisfiedToolUseIDs)

        #expect(await recorder.calls.isEmpty)
    }

    /// The merge runs on every publish, so the same id is satisfied on every
    /// tick until the daemon's retraction delta arrives. Only the first tick
    /// may reach the socket.
    @Test("a repeated satisfied id is reported exactly once")
    func repeatIsSuppressed() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder)
        let terminalID = UUID()
        let entries = [pending("toolu_a")]
        let ids = Set(entries.map(\.toolUseID))
        let merged = AskUserQuestionMerger.merge(
            jsonlItems: [jsonlToolCall("toolu_a")], pending: entries)

        for _ in 0..<5 {
            await reporter.report(
                terminalID: terminalID, pendingToolUseIDs: ids,
                satisfiedToolUseIDs: merged.satisfiedToolUseIDs)
        }

        #expect(await recorder.calls.count == 1)
    }

    @Test("a second capture on the same terminal is reported on its own")
    func newIDStillReported() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder)
        let terminalID = UUID()
        let entries = [pending("toolu_a"), pending("toolu_b")]
        let ids = Set(entries.map(\.toolUseID))

        let first = AskUserQuestionMerger.merge(
            jsonlItems: [jsonlToolCall("toolu_a")], pending: entries)
        await reporter.report(
            terminalID: terminalID, pendingToolUseIDs: ids,
            satisfiedToolUseIDs: first.satisfiedToolUseIDs)

        let second = AskUserQuestionMerger.merge(
            jsonlItems: [jsonlToolCall("toolu_a"), jsonlToolCall("toolu_b")],
            pending: entries)
        await reporter.report(
            terminalID: terminalID, pendingToolUseIDs: ids,
            satisfiedToolUseIDs: second.satisfiedToolUseIDs)

        let calls = await recorder.calls
        #expect(calls.map(\.toolUseIDs) == [["toolu_a"], ["toolu_b"]],
                "the already-reported id must not ride along a second time")
    }

    /// Memory of a report is scoped to the capture set it was made against, so
    /// a daemon that raises a fresh question under an id it previously held —
    /// after an expiry reap, say — gets told about it again.
    @Test("an id the daemon no longer holds is forgotten, not remembered forever")
    func memoryIsBoundedByTheCaptureSet() async {
        let recorder = Recorder()
        let reporter = makeReporter(recorder)
        let terminalID = UUID()
        let entries = [pending("toolu_a")]
        let merged = AskUserQuestionMerger.merge(
            jsonlItems: [jsonlToolCall("toolu_a")], pending: entries)

        await reporter.report(
            terminalID: terminalID, pendingToolUseIDs: ["toolu_a"],
            satisfiedToolUseIDs: merged.satisfiedToolUseIDs)
        // The retraction lands: the terminal's capture set is empty for a
        // while, and only then does the same id come back.
        await reporter.report(
            terminalID: terminalID, pendingToolUseIDs: [], satisfiedToolUseIDs: [])
        await reporter.report(
            terminalID: terminalID, pendingToolUseIDs: ["toolu_a"],
            satisfiedToolUseIDs: merged.satisfiedToolUseIDs)

        #expect(await recorder.calls.count == 2)
    }
}

/// `AppState`'s session-to-terminal join, which is what lets the app name the
/// terminal whose capture the JSONL satisfied — the daemon's store is keyed on
/// terminal, the poll scheduler on Claude session id.
@MainActor
@Suite("pending question capture lookup")
struct PendingQuestionCaptureLookupTests {

    @Test("the capture lookup returns the owning terminal alongside its entries")
    func lookupCarriesTerminalID() {
        let suiteName = "TBDAppTests.PendingQuestionCapture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)

        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [
            Terminal(
                id: terminalID, worktreeID: worktreeID, tmuxWindowID: "@1",
                tmuxPaneID: "%1", claudeSessionID: "session-a")
        ]
        state.handleDelta(.terminalPendingQuestionsChanged(
            TerminalPendingQuestionsDelta(
                terminalID: terminalID,
                pending: [PendingQuestionPayload(
                    toolUseID: "toolu_01", inputJSON: #"{"questions":[]}"#,
                    timestamp: Date(timeIntervalSince1970: 1000))])))

        let capture = state.pendingQuestionCaptureForSession("session-a")
        #expect(capture?.terminalID == terminalID)
        #expect(capture?.entries.map(\.toolUseID) == ["toolu_01"])
        #expect(state.pendingQuestionCaptureForSession("session-b") == nil)
    }
}
