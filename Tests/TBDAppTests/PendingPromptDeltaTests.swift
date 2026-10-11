import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

/// `AppState`'s mirror of the daemon's pending prompts, carried by
/// `.terminalPendingPromptsChanged`. One delta carries both the legacy
/// `AskUserQuestion` captures and the prompts, ordered by one revision.
///
/// Every test constructs `AppState(userDefaults:)` against a throwaway suite:
/// `UserDefaults.standard` is the developer's real `TBDApp.plist`.
@MainActor
@Suite("pending prompt delta")
struct PendingPromptDeltaTests {

    private func withAppState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.PendingPromptDelta.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func capture(_ toolUseID: String) -> PendingQuestionPayload {
        PendingQuestionPayload(
            toolUseID: toolUseID, inputJSON: #"{"questions":[]}"#,
            timestamp: Date(timeIntervalSince1970: 1000))
    }

    private func prompt(_ id: String) -> PendingPromptPayload {
        PendingPromptPayload(
            id: id, kind: .permission, toolUseID: "toolu_\(id)", toolName: "Bash",
            toolInputJSON: #"{"command":"ls"}"#, suggestionsJSON: nil,
            createdAt: Date(timeIntervalSince1970: 1000))
    }

    private func delta(_ terminalID: UUID, captures: [String] = [], prompts: [String] = [],
                       revision: UInt64? = nil) -> StateDelta {
        .terminalPendingPromptsChanged(TerminalPendingPromptsDelta(
            terminalID: terminalID, captures: captures.map(capture), prompts: prompts.map(prompt),
            revision: revision))
    }

    @Test("a delta sets both the captures and the prompts")
    func deltaSetsBoth() {
        withAppState { state in
            let terminalID = UUID()
            state.handleDelta(delta(terminalID, captures: ["toolu_q"], prompts: ["p1"], revision: 1))
            #expect(state.pendingQuestions[terminalID]?.map(\.toolUseID) == ["toolu_q"])
            #expect(state.pendingPrompts[terminalID]?.map(\.id) == ["p1"])
        }
    }

    @Test("an empty delta removes both keys")
    func emptyDeltaRemovesBoth() {
        withAppState { state in
            let terminalID = UUID()
            state.handleDelta(delta(terminalID, captures: ["toolu_q"], prompts: ["p1"], revision: 1))
            state.handleDelta(delta(terminalID, revision: 2))
            #expect(state.pendingQuestions[terminalID] == nil)
            #expect(state.pendingPrompts[terminalID] == nil)
        }
    }

    @Test("an older revision is dropped")
    func olderRevisionDropped() {
        withAppState { state in
            let terminalID = UUID()
            state.handleDelta(delta(terminalID, revision: 5))
            state.handleDelta(delta(terminalID, captures: ["toolu_q"], prompts: ["p1"], revision: 4))
            #expect(state.pendingQuestions[terminalID] == nil,
                    "a late set must not resurrect a capture a newer clear retracted")
            #expect(state.pendingPrompts[terminalID] == nil,
                    "a late set must not resurrect a prompt a newer clear retracted")
        }
    }

    @Test("a nil revision is applied")
    func nilRevisionApplied() {
        withAppState { state in
            let terminalID = UUID()
            state.handleDelta(delta(terminalID, revision: 5))
            state.handleDelta(delta(terminalID, prompts: ["p1"], revision: nil))
            #expect(state.pendingPrompts[terminalID]?.map(\.id) == ["p1"])
        }
    }

    @Test("terminals are independent")
    func terminalsIndependent() {
        withAppState { state in
            let a = UUID()
            let b = UUID()
            state.handleDelta(delta(a, prompts: ["p1"], revision: 9))
            state.handleDelta(delta(b, prompts: ["p2"], revision: 1))
            #expect(state.pendingPrompts[a]?.map(\.id) == ["p1"])
            #expect(state.pendingPrompts[b]?.map(\.id) == ["p2"])
        }
    }

    /// The reset `startSubscription` runs, called directly: starting a real
    /// subscription would dial the daemon socket.
    @Test("a new subscription's ordering reset clears the prompt revisions")
    func resetDeltaOrderingClearsRevisions() {
        withAppState { state in
            let terminalID = UUID()
            state.handleDelta(delta(terminalID, prompts: ["p1"], revision: 5))
            #expect(state.pendingPromptRevisions[terminalID] == 5)
            state.resetDeltaOrdering()
            #expect(state.pendingPromptRevisions.isEmpty,
                    "a restarted daemon counts from zero; a kept high-water mark drops its deltas")
            state.handleDelta(delta(terminalID, prompts: ["p2"], revision: 1))
            #expect(state.pendingPrompts[terminalID]?.map(\.id) == ["p2"])
        }
    }

    @Test("the legacy question delta still applies")
    func legacyDeltaStillApplies() {
        withAppState { state in
            let terminalID = UUID()
            state.handleDelta(.terminalPendingQuestionsChanged(
                TerminalPendingQuestionsDelta(terminalID: terminalID, pending: [capture("toolu_q")])))
            #expect(state.pendingQuestions[terminalID]?.map(\.toolUseID) == ["toolu_q"])
            #expect(state.pendingPrompts[terminalID] == nil)
        }
    }
}
