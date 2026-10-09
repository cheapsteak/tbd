import Foundation
import Testing
@testable import TBDShared

@Suite("Session pending_question")
struct RemotePendingQuestionTests {
    private func decode(_ json: String) throws -> RemoteSessionPayload {
        try JSONDecoder().decode(RemoteSessionPayload.self, from: Data(json.utf8))
    }

    @Test("a full question block decodes")
    func decodesFullBlock() throws {
        let payload = try decode("""
        {"id":"s1","state":"running","agent_state":"waiting_input",
         "pending_question":{"id":"q-4f2a1c","questions":[
           {"prompt":"Which environment should this deploy to?","label":"Environment","multi":false,
            "options":[{"label":"staging","description":"the staging cluster"},{"label":"production"}]}]}}
        """)

        let question = try #require(payload.pendingQuestion)
        #expect(question.id == "q-4f2a1c")
        #expect(question.questions.count == 1)
        #expect(question.questions[0].prompt == "Which environment should this deploy to?")
        #expect(question.questions[0].label == "Environment")
        #expect(question.questions[0].multi == false)
        #expect(question.questions[0].options.map(\.label) == ["staging", "production"])
        #expect(question.questions[0].options[0].description == "the staging cluster")
        #expect(question.questions[0].options[1].description == nil)
    }

    @Test("a session without the field decodes exactly as before")
    func absentFieldIsNil() throws {
        let payload = try decode("""
        {"id":"s1","state":"running","agent_state":"working"}
        """)

        #expect(payload.pendingQuestion == nil)
        #expect(payload.agentState == .working)
    }

    @Test("a malformed question block costs the explanation, never the session")
    func malformedBlockIsAbsent() throws {
        let payload = try decode("""
        {"id":"s1","title":"t","state":"running","agent_state":"waiting_input",
         "pending_question":"blocked"}
        """)

        #expect(payload.pendingQuestion == nil)
        #expect(payload.id == "s1")
        #expect(payload.title == "t")
        #expect(payload.agentState == .waitingInput)
    }

    @Test("a question with no readable prompt is skipped, and an empty block reads as absent")
    func skipsUnreadableQuestions() throws {
        let partial = try decode("""
        {"id":"s1","state":"running","agent_state":"waiting_input",
         "pending_question":{"questions":[{"options":[{"label":"a"}]},{"prompt":"Continue?"}]}}
        """)
        #expect(partial.pendingQuestion?.questions.map(\.prompt) == ["Continue?"])

        let empty = try decode("""
        {"id":"s1","state":"running","agent_state":"waiting_input",
         "pending_question":{"questions":[{"options":[]}]}}
        """)
        // Not an empty question set: an explanation with nothing in it is not
        // an explanation, and every caller would have to remember to check.
        #expect(empty.pendingQuestion == nil)
    }

    @Test("an option with no label is skipped without costing the question")
    func skipsUnlabelledOptions() throws {
        let payload = try decode("""
        {"id":"s1","state":"running","agent_state":"waiting_input",
         "pending_question":{"questions":[{"prompt":"Pick","options":[{"description":"d"},{"label":"ok"}]}]}}
        """)

        #expect(payload.pendingQuestion?.questions[0].options.map(\.label) == ["ok"])
    }

    @Test("a stale snapshot cannot keep claiming what a session is blocked on")
    func staleProjectionClearsTheQuestion() {
        let payload = RemoteSessionPayload(
            id: "s1", state: .running, agentState: .waitingInput,
            agentStateReason: "permission_prompt", archived: true,
            pendingQuestion: RemotePendingQuestion(
                id: "q1", questions: [RemotePendingQuestionItem(prompt: "Continue?")]))

        let projected = payload.projectedForStaleSnapshot()

        // Liveness axis: cleared alongside agent state.
        #expect(projected.pendingQuestion == nil)
        #expect(projected.agentState == .unknown)
        #expect(projected.agentStateReason == nil)
        // Filing axis: untouched, as the projection's contract requires.
        #expect(projected.archived == true)
    }

    @Test("an already-exited session keeps its question block untouched")
    func staleProjectionLeavesTerminalRowsAlone() {
        let payload = RemoteSessionPayload(
            id: "s1", state: .exited, exitCode: 0, agentState: .exited,
            pendingQuestion: RemotePendingQuestion(
                id: "q1", questions: [RemotePendingQuestionItem(prompt: "Continue?")]))

        #expect(payload.projectedForStaleSnapshot() == payload)
    }

    @Test("the field round-trips so a mirrored payload keeps its explanation")
    func roundTripsThroughTheMirror() throws {
        let payload = RemoteSessionPayload(
            id: "s1", state: .running, agentState: .waitingInput,
            pendingQuestion: RemotePendingQuestion(
                id: "q1",
                questions: [RemotePendingQuestionItem(
                    prompt: "Continue?", multi: true,
                    options: [RemotePendingQuestionOption(label: "yes")])]))

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(RemoteSessionPayload.self, from: data)

        #expect(decoded == payload)
        // The wire key is the contract's, not Swift's property name.
        #expect(String(data: data, encoding: .utf8)?.contains("pending_question") == true)
    }
}
