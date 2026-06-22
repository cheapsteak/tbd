import Foundation
import TBDShared
@testable import TBDApp

@MainActor
extension TranscriptRenderNode {
    static func makeToolCall(id: String, name: String, inputJSON: String) -> TranscriptRenderNode {
        TranscriptRenderNode(
            id: id,
            kind: .toolCall(id: id, name: name, inputJSON: inputJSON, inputTruncatedTo: nil, result: nil, timestamp: nil),
            badgeUsage: nil
        )
    }

    static func makeAssistantText(id: String, text: String) -> TranscriptRenderNode {
        TranscriptRenderNode(
            id: id,
            kind: .chatBubble(.assistantText(id: id, text: text, timestamp: nil)),
            badgeUsage: nil
        )
    }

    static func makeUserPrompt(id: String, text: String) -> TranscriptRenderNode {
        TranscriptRenderNode(
            id: id,
            kind: .chatBubble(.userPrompt(id: id, text: text, timestamp: nil)),
            badgeUsage: nil
        )
    }

    static func makeSubagentSummary(id: String, count: Int, agentType: String?) -> TranscriptRenderNode {
        TranscriptRenderNode(
            id: id,
            kind: .subagentSummary(parentItemID: id, count: count, agentType: agentType),
            badgeUsage: nil
        )
    }
}
