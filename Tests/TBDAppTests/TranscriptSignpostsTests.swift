import Foundation
import Testing
import TBDShared

@testable import TBDApp

/// Coverage for the `TranscriptSignposts` metadata helpers. These pure helpers
/// build the strings/lengths that get attached to per-row signpost intervals
/// (issue #129), so a regression here would silently make hang traces less
/// useful. CLAUDE.md branching-conditional rule: one test per `kind` arm.
@Suite("TranscriptSignposts")
struct TranscriptSignpostsTests {
    private func node(_ kind: TranscriptRenderNode.Kind, id: String = "n1") -> TranscriptRenderNode {
        TranscriptRenderNode(id: id, kind: kind, badgeUsage: nil)
    }

    // MARK: - kindLabel

    @Test func kindLabel_userPrompt() {
        let n = node(.chatBubble(.userPrompt(id: "u1", text: "hi", timestamp: nil)))
        #expect(TranscriptSignposts.kindLabel(for: n) == "userPrompt")
    }

    @Test func kindLabel_assistantText() {
        let n = node(.chatBubble(.assistantText(id: "a1", text: "hello", timestamp: nil, usage: nil)))
        #expect(TranscriptSignposts.kindLabel(for: n) == "assistantText")
    }

    @Test func kindLabel_systemReminder() {
        let n = node(.systemReminder(id: "s1", kind: .skillBody, text: "x", timestamp: nil))
        #expect(TranscriptSignposts.kindLabel(for: n) == "systemReminder")
    }

    @Test func kindLabel_chatBubble_thinking() {
        let n = node(.chatBubble(.thinking(id: "th1", text: "musing", timestamp: nil)))
        #expect(TranscriptSignposts.kindLabel(for: n) == "thinking")
    }

    @Test func kindLabel_chatBubble_systemReminder() {
        // Distinct from the node-level `.systemReminder` arm above — this is a
        // `TranscriptItem.systemReminder` wrapped in a chatBubble render node.
        let n = node(.chatBubble(.systemReminder(id: "s2", kind: .skillBody, text: "x", timestamp: nil)))
        #expect(TranscriptSignposts.kindLabel(for: n) == "chatSystemReminder")
    }

    @Test func kindLabel_chatBubble_slashCommand() {
        let n = node(.chatBubble(.slashCommand(id: "sl1", name: "compact", args: nil, timestamp: nil)))
        #expect(TranscriptSignposts.kindLabel(for: n) == "slashCommand")
    }

    @Test func kindLabel_chatBubble_toolCall_includesName() {
        let n = node(.chatBubble(.toolCall(
            id: "t1", name: "Bash", inputJSON: "{}", inputTruncatedTo: nil,
            result: nil, subagent: nil, timestamp: nil, usage: nil
        )))
        #expect(TranscriptSignposts.kindLabel(for: n) == "chatTool:Bash")
    }

    @Test func kindLabel_skillBody() {
        let n = node(.skillBody(id: "k1", text: "body", timestamp: nil))
        #expect(TranscriptSignposts.kindLabel(for: n) == "skillBody")
    }

    @Test func kindLabel_toolCall_includesName() {
        let n = node(.toolCall(id: "t1", name: "Bash", inputJSON: "{}", inputTruncatedTo: nil, result: nil, timestamp: nil))
        #expect(TranscriptSignposts.kindLabel(for: n) == "tool:Bash")
    }

    @Test func kindLabel_subagentSummary() {
        let n = node(.subagentSummary(parentItemID: "t1", count: 3, agentType: nil))
        #expect(TranscriptSignposts.kindLabel(for: n) == "subagentSummary")
    }

    // MARK: - contentLength

    @Test func contentLength_chatBubble_userPrompt() {
        let n = node(.chatBubble(.userPrompt(id: "u1", text: "hello", timestamp: nil)))
        #expect(TranscriptSignposts.contentLength(for: n) == 5)
    }

    @Test func contentLength_chatBubble_assistantText() {
        let n = node(.chatBubble(.assistantText(id: "a1", text: "1234567", timestamp: nil, usage: nil)))
        #expect(TranscriptSignposts.contentLength(for: n) == 7)
    }

    @Test func contentLength_toolCallNode_sumsInputAndResult() {
        let result = ToolResult(text: "RESULT", truncatedTo: nil, isError: false)
        let n = node(.toolCall(id: "t1", name: "Bash", inputJSON: "{\"x\":1}", inputTruncatedTo: nil, result: result, timestamp: nil))
        // inputJSON "{\"x\":1}" is 7 chars + "RESULT" is 6 → 13
        #expect(TranscriptSignposts.contentLength(for: n) == 13)
    }

    @Test func contentLength_toolCallNode_nilResult() {
        let n = node(.toolCall(id: "t1", name: "Bash", inputJSON: "abc", inputTruncatedTo: nil, result: nil, timestamp: nil))
        #expect(TranscriptSignposts.contentLength(for: n) == 3)
    }

    @Test func contentLength_skillBody_textLength() {
        let n = node(.skillBody(id: "k1", text: "abcdef", timestamp: nil))
        #expect(TranscriptSignposts.contentLength(for: n) == 6)
    }

    @Test func contentLength_subagentSummary_isZero() {
        let n = node(.subagentSummary(parentItemID: "t1", count: 1, agentType: nil))
        #expect(TranscriptSignposts.contentLength(for: n) == 0)
    }

    // MARK: - Signposter does not crash

    /// Smoke test: the shared signposter accepts our begin/end pattern with
    /// privacy-qualified metadata and the new `hang.detected` event without
    /// crashing. Doesn't (and can't easily) verify what Instruments sees —
    /// that's a manual-capture verification step documented in
    /// `docs/diagnostics-strategy.md`.
    @Test func signposter_emitEventAndIntervalDoNotCrash() {
        let id = TranscriptSignposts.signposter.makeSignpostID()
        let state = TranscriptSignposts.signposter.beginInterval(
            "transcript.row.body",
            id: id,
            "id=test kind=tool:Bash len=42"
        )
        TranscriptSignposts.signposter.endInterval("transcript.row.body", state)
        TranscriptSignposts.signposter.emitEvent(
            "hang.detected",
            "stallMs=1200 terminalID=abcd itemCount=10 pane=transcript"
        )
    }
}
