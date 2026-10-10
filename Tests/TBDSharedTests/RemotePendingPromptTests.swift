import Foundation
import Testing
@testable import TBDShared

@Suite("Session pending_prompt")
struct RemotePendingPromptTests {
    private func decode(_ json: String) throws -> RemoteSessionPayload {
        try JSONDecoder().decode(RemoteSessionPayload.self, from: Data(json.utf8))
    }

    private func session(_ prompt: String) -> String {
        """
        {"id":"s1","state":"running","agent_state":"waiting_input","pending_prompt":\(prompt)}
        """
    }

    @Test("a full permission prompt decodes")
    func decodesPermission() throws {
        let payload = try decode(session("""
        {"id":"p-1","kind":"permission","tool_use_id":"toolu_1","tool_name":"Bash",
         "tool_input":{"command":"ls","timeout":5},"tool_input_truncated":false,
         "suggestions":[{"type":"addRules"}]}
        """))
        let prompt = try #require(payload.pendingPrompt)
        #expect(prompt.id == "p-1")
        #expect(prompt.kind == .permission)
        #expect(prompt.toolUseID == "toolu_1")
        #expect(prompt.toolName == "Bash")
        #expect(prompt.toolInputJSON == #"{"command":"ls","timeout":5}"#)
        #expect(prompt.suggestionsJSON == #"[{"type":"addRules"}]"#)
        #expect(prompt.toolInputTruncated == false)
        #expect(prompt.questions == nil)
    }

    @Test("a question prompt carries pending_question-shaped items")
    func decodesQuestion() throws {
        let payload = try decode(session("""
        {"id":"p-2","kind":"question","questions":[
          {"prompt":"Pick one","options":[{"label":"a"},{"label":"b"}]}]}
        """))
        let prompt = try #require(payload.pendingPrompt)
        #expect(prompt.kind == .question)
        #expect(prompt.questions?.first?.options.map(\.label) == ["a", "b"])
    }

    @Test("an absent tool_use_id is nil")
    func absentToolUseID() throws {
        let payload = try decode(session(#"{"id":"p-1","kind":"permission","tool_name":"Bash"}"#))
        #expect(payload.pendingPrompt?.toolUseID == nil)
        let null = try decode(session(#"{"id":"p-1","kind":"permission","tool_use_id":null}"#))
        #expect(null.pendingPrompt?.toolUseID == nil)
    }

    @Test("a truncated prompt with no tool_input stays answerable")
    func truncatedWithoutInput() throws {
        let payload = try decode(session(
            #"{"id":"p-1","kind":"permission","tool_name":"Write","tool_input_truncated":true}"#))
        let prompt = try #require(payload.pendingPrompt)
        #expect(prompt.toolInputJSON == nil)
        #expect(prompt.toolInputTruncated)
    }

    @Test("bad fields cost the prompt, never the session")
    func lenientDecode() throws {
        for bad in [
            #"{"id":"p-1","kind":"mystery"}"#,
            #"{"id":" ","kind":"permission"}"#,
            #"{"id":"p-1","kind":"question","questions":[{"options":[]}]}"#,
            #""garbage""#,
        ] {
            let payload = try decode(session(bad))
            #expect(payload.id == "s1", "\(bad)")
            #expect(payload.agentState == .waitingInput, "\(bad)")
            #expect(payload.pendingPrompt == nil, "\(bad)")
        }
    }

    @Test("a wrong-typed optional field reads as absent and keeps the prompt")
    func wrongTypedOptionalFields() throws {
        let payload = try decode(session("""
        {"id":"p-1","kind":"permission","tool_name":7,"tool_input":"x","suggestions":{"a":1},
         "tool_input_truncated":"yes","tool_use_id":3}
        """))
        let prompt = try #require(payload.pendingPrompt)
        #expect(prompt.toolName == nil)
        #expect(prompt.toolInputJSON == nil)
        #expect(prompt.suggestionsJSON == nil)
        #expect(prompt.toolInputTruncated == false)
        #expect(prompt.toolUseID == nil)
    }

    @Test("a pending_question alone projects to a question prompt")
    func projectsPendingQuestion() throws {
        let payload = try decode("""
        {"id":"s1","state":"running","agent_state":"waiting_input",
         "pending_question":{"id":"q-1","questions":[{"prompt":"Go?"}]}}
        """)
        #expect(payload.pendingPrompt == nil)
        let prompt = try #require(payload.effectivePendingPrompt)
        #expect(prompt.id == "q-1")
        #expect(prompt.kind == .question)
        #expect(prompt.questions?.map(\.prompt) == ["Go?"])
    }

    @Test("a pending_question without an id is not answerable")
    func questionWithoutIDHasNoPrompt() throws {
        let payload = try decode("""
        {"id":"s1","state":"running","agent_state":"waiting_input",
         "pending_question":{"questions":[{"prompt":"Go?"}]}}
        """)
        #expect(payload.effectivePendingPrompt == nil)
    }

    @Test("pending_prompt wins over pending_question")
    func promptWins() throws {
        let payload = try decode("""
        {"id":"s1","state":"running","agent_state":"waiting_input",
         "pending_prompt":{"id":"p-9","kind":"permission","tool_name":"Bash"},
         "pending_question":{"id":"q-1","questions":[{"prompt":"Go?"}]}}
        """)
        #expect(payload.effectivePendingPrompt?.id == "p-9")
    }

    @Test("the field round-trips through the mirror")
    func roundTrips() throws {
        let original = try decode(session("""
        {"id":"p-1","kind":"permission","tool_use_id":"toolu_1","tool_name":"Bash",
         "tool_input":{"b":[1,2.5,true,null],"a":"x/y"},"tool_input_truncated":true,
         "suggestions":[{"type":"addRules"}]}
        """))
        let data = try JSONEncoder().encode(original)
        let again = try JSONDecoder().decode(RemoteSessionPayload.self, from: data)
        #expect(again == original)
        #expect(again.pendingPrompt?.toolInputJSON == #"{"a":"x/y","b":[1,2.5,true,null]}"#)
    }

    @Test("a stale snapshot drops the prompt and keeps archived")
    func staleProjectionDropsPrompt() {
        let payload = RemoteSessionPayload(
            id: "s1", state: .running, agentState: .waitingInput, archived: true,
            pendingPrompt: RemotePendingPrompt(id: "p-1", kind: .permission, toolName: "Bash"))
        let projected = payload.projectedForStaleSnapshot()
        #expect(projected.pendingPrompt == nil)
        #expect(projected.archived == true)

        let exited = RemoteSessionPayload(
            id: "s1", state: .exited, agentState: .exited,
            pendingPrompt: RemotePendingPrompt(id: "p-1", kind: .permission))
        #expect(exited.projectedForStaleSnapshot() == exited)
    }

    @Test("effective questions prefer the items, then fall back to tool_input")
    func effectiveQuestions() {
        let input = #"{"questions":[{"header":"H","multiSelect":true,"options":[{"label":"A"}],"question":"From input?"}]}"#
        let fromInput = RemotePendingPrompt(id: "p-1", kind: .question, toolInputJSON: input)
        #expect(fromInput.effectiveQuestions.map(\.text) == ["From input?"])
        #expect(fromInput.effectiveQuestions.first?.multiSelect == true)

        let fromItems = RemotePendingPrompt(
            id: "p-2", kind: .question,
            questions: [RemotePendingQuestionItem(prompt: "From items?")], toolInputJSON: input)
        #expect(fromItems.effectiveQuestions.map(\.text) == ["From items?"])

        let permission = RemotePendingPrompt(id: "p-3", kind: .permission, toolInputJSON: input)
        #expect(permission.effectiveQuestions.isEmpty)
    }
}
