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
