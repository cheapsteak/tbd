import Foundation
import Testing
import TBDShared
@testable import TBDApp

@Suite("Remote agent attention")
struct RemoteAgentAttentionTests {
    // MARK: - What blocks a session

    @Test("a structured question is quoted, with its options")
    func explainsAPendingQuestion() {
        let session = session(
            terminal: .running, agent: .waitingInput,
            question: RemotePendingQuestion(id: "q1", questions: [
                RemotePendingQuestionItem(
                    prompt: "Which environment should this deploy to?",
                    options: [
                        RemotePendingQuestionOption(label: "staging"),
                        RemotePendingQuestionOption(label: "production"),
                    ]),
            ]))

        #expect(RemoteAgentAttention.explanation(for: session)
            == "Blocked on a question: Which environment should this deploy to? (staging / production)")
    }

    @Test("more than one pending question is counted, not concatenated")
    func countsAdditionalQuestions() {
        let session = session(
            terminal: .running, agent: .waitingInput,
            question: RemotePendingQuestion(questions: [
                RemotePendingQuestionItem(prompt: "First?"),
                RemotePendingQuestionItem(prompt: "Second?"),
            ]))

        #expect(RemoteAgentAttention.explanation(for: session)
            == "Blocked on a question: First? — and 1 more.")
    }

    @Test("the contract's own reason value is humanized and every other passes through")
    func humanizesTheKnownReason() {
        #expect(RemoteAgentAttention.humanizedReason("permission_prompt")
            == "Blocked on a permission prompt.")
        // Provider-defined; TBD invents no meaning for a value it was never
        // promised.
        #expect(RemoteAgentAttention.humanizedReason("awaiting_reviewer") == "awaiting_reviewer")
        #expect(RemoteAgentAttention.humanizedReason("   ") == nil)
        #expect(RemoteAgentAttention.humanizedReason(nil) == nil)
    }

    @Test("a question outranks a reason string, and a reason outranks the bare state")
    func prefersTheMostSpecificSource() {
        let both = session(
            terminal: .running, agent: .waitingInput, reason: "permission_prompt",
            question: RemotePendingQuestion(questions: [RemotePendingQuestionItem(prompt: "Go on?")]))
        #expect(RemoteAgentAttention.explanation(for: both) == "Blocked on a question: Go on?")

        let reasonOnly = session(terminal: .running, agent: .waitingInput, reason: "permission_prompt")
        #expect(RemoteAgentAttention.explanation(for: reasonOnly) == "Blocked on a permission prompt.")

        let bare = session(terminal: .running, agent: .waitingInput)
        #expect(RemoteAgentAttention.explanation(for: bare) == "Waiting for input.")
    }

    // MARK: - Liveness is not progress

    @Test("a running terminal with no agent state is stated as such, not as work")
    func namesTheUnattributedRunningRow() {
        let session = session(terminal: .running, agent: .unknown)

        #expect(RemoteAgentAttention.isUnattributedRunning(session))
        #expect(RemoteAgentAttention.explanation(for: session)
            == RemoteAgentAttention.unattributedRunningExplanation)
        // It is neither working nor waiting, and must not be counted as either.
        #expect(RemoteAgentAttention.needsAttention(session) == false)
    }

    @Test("an idle agent under a live terminal says it is idle")
    func namesTheIdleRow() {
        #expect(RemoteAgentAttention.explanation(for: session(terminal: .running, agent: .idle))
            == "Agent is idle — it reported no work in progress.")
    }

    @Test("a working session asks nothing of a human")
    func workingSessionsAreSilent() {
        let working = session(terminal: .running, agent: .working)

        #expect(RemoteAgentAttention.explanation(for: working) == nil)
        #expect(RemoteAgentAttention.needsAttention(working) == false)
        #expect(RemoteAgentAttention.isUnattributedRunning(working) == false)
    }

    @Test("a tombstoned row asks nothing of a human either")
    func goneRowsAreSilent() {
        let gone = session(terminal: .running, agent: .waitingInput, gone: true)

        #expect(RemoteAgentAttention.explanation(for: gone) == nil)
        #expect(RemoteAgentAttention.needsAttention(gone) == false)
        #expect(RemoteAgentAttention.isUnattributedRunning(gone) == false)
    }

    @Test("blockage is read off the agent axis, never off the question block")
    func neverInfersBlockageFromAQuestion() {
        // The contract forbids concluding a session is blocked from
        // `pending_question` alone. A provider that leaves a stale block
        // behind can make the explanation wrong; it must never make TBD
        // claim a working session needs a human.
        let working = session(
            terminal: .running, agent: .working,
            question: RemotePendingQuestion(questions: [RemotePendingQuestionItem(prompt: "Stale?")]))

        #expect(RemoteAgentAttention.needsAttention(working) == false)
        #expect(RemoteAgentAttention.explanation(for: working) == nil)
    }

    // MARK: - The desk's aggregate

    @Test("the desk separates blocked rows from unattributed running ones")
    func summarySeparatesTheTwoReadings() {
        let sessions = [
            session(id: "blocked", terminal: .running, agent: .waitingInput, reason: "permission_prompt"),
            session(id: "opaque", terminal: .running, agent: .unknown),
            session(id: "busy", terminal: .running, agent: .working),
        ]

        let summary = RemoteProviderDeskSummary(provider: "agentbox", sessions: sessions)

        #expect(summary.needsAttention.map(\.payload.id) == ["blocked"])
        #expect(summary.unattributedRunning.map(\.payload.id) == ["opaque"])
        #expect(summary.unattributedRunningNotice
            == "1 running session reports no agent state — terminal liveness is not agent progress.")
        // Terminal liveness still counts all three: the axes stay separate.
        #expect(summary.terminal.running == 3)
    }

    @Test("no unattributed rows means no notice")
    func noNoticeWhenEverythingIsAttributed() {
        let summary = RemoteProviderDeskSummary(
            provider: "agentbox",
            sessions: [session(terminal: .running, agent: .working)])

        #expect(summary.unattributedRunningNotice == nil)
        #expect(summary.needsAttention.isEmpty)
    }

    private func session(
        id: String = "s1",
        provider: String = "agentbox",
        terminal: RemoteProcessState,
        agent: RemoteAgentState,
        reason: String? = nil,
        question: RemotePendingQuestion? = nil,
        gone: Bool = false
    ) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(
                id: id, title: id, state: terminal, agentState: agent,
                agentStateReason: reason, pendingQuestion: question),
            gone: gone, dismissed: false,
            lastSeen: Date(timeIntervalSince1970: 1_000))
    }
}
