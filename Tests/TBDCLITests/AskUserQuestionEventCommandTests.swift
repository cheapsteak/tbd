import Foundation
import Testing

@testable import TBDCLI

@Suite("AskUserQuestionPayloadParser")
struct AskUserQuestionEventCommandTests {
    private static let mainAgentPayload = #"""
    {
      "session_id": "B88113CA-EAF0-41D7-AEF7-C4AB2FB449CF",
      "transcript_path": "/Users/x/.claude/projects/-Users-x-foo/B88113CA-EAF0-41D7-AEF7-C4AB2FB449CF.jsonl",
      "cwd": "/Users/x/foo",
      "hook_event_name": "PreToolUse",
      "tool_name": "AskUserQuestion",
      "tool_input": { "questions": [{"question": "?", "options": [{"label": "A"}]}] },
      "tool_use_id": "toolu_01ABCXYZ"
    }
    """#

    private static let subagentPayload = #"""
    {
      "session_id": "subagent-sid",
      "transcript_path": "/Users/x/.claude/projects/-Users-x-foo/PARENT/subagents/agent-abc.jsonl",
      "cwd": "/Users/x/foo",
      "hook_event_name": "PreToolUse",
      "tool_name": "AskUserQuestion",
      "tool_input": { "questions": [] },
      "tool_use_id": "toolu_subagent"
    }
    """#

    @Test func decode_main_agent_payload_extracts_fields() throws {
        let data = Data(Self.mainAgentPayload.utf8)
        let parsed = try AskUserQuestionPayloadParser.parse(data)
        #expect(parsed.toolUseID == "toolu_01ABCXYZ")
        #expect(parsed.transcriptPath
            == "/Users/x/.claude/projects/-Users-x-foo/B88113CA-EAF0-41D7-AEF7-C4AB2FB449CF.jsonl")
        let obj = try JSONSerialization.jsonObject(with: Data(parsed.toolInputJSON.utf8))
        #expect((obj as? [String: Any]) != nil)
    }

    @Test func is_subagent_transcript_detects_subagents_segment() {
        #expect(AskUserQuestionPayloadParser.isSubagentTranscript(
            "/Users/x/.claude/projects/-Users-x-foo/PARENT/subagents/agent-abc.jsonl"))
        #expect(!AskUserQuestionPayloadParser.isSubagentTranscript(
            "/Users/x/.claude/projects/-Users-x-foo/B88113CA-401C-47EE-843E-4BACB67AE5FA.jsonl"))
    }

    @Test func is_subagent_transcript_nil_path_is_not_subagent() {
        #expect(!AskUserQuestionPayloadParser.isSubagentTranscript(nil))
    }

    @Test func decode_malformed_json_throws() {
        #expect(throws: (any Error).self) {
            try AskUserQuestionPayloadParser.parse(Data("not json".utf8))
        }
    }

    @Test func decode_missing_tool_use_id_throws() {
        let bad = #"{"tool_input": {}}"#
        #expect(throws: (any Error).self) {
            try AskUserQuestionPayloadParser.parse(Data(bad.utf8))
        }
    }
}
