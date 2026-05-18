import SwiftUI
import TBDShared

/// One row of the transcript. Constant view-shape: always a `VStack` with a
/// content subview and an optional inlined `ContextUsageBadge`. The internal
/// `switch` on `node.kind` lives behind this struct's type boundary so the
/// parent `ForEach`'s body is homogeneous — see issue #129 / the
/// transcript-render-node design doc.
struct TranscriptRow: View {
    let node: TranscriptRenderNode
    let terminalID: UUID?

    var body: some View {
        // Per-row signpost so a hang trace identifies which row was being
        // evaluated when the main thread stalled. Metadata (kind, length, id)
        // is passed on the begin call — see docs/diagnostics-strategy.md
        // ("Capturing a transcript-perf trace") and issue #129.
        let kind = TranscriptSignposts.kindLabel(for: node)
        let len = TranscriptSignposts.contentLength(for: node)
        let state = TranscriptSignposts.signposter.beginInterval(
            "transcript.row.body",
            id: TranscriptSignposts.signposter.makeSignpostID(),
            "id=\(node.id, privacy: .public) kind=\(kind, privacy: .public) len=\(len, privacy: .public)"
        )
        defer { TranscriptSignposts.signposter.endInterval("transcript.row.body", state) }
        return rowBody
    }

    @ViewBuilder
    private var rowBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
            if let usage = node.badgeUsage {
                ContextUsageBadge(total: usage.contextTotal)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .chatBubble(let item):
            ChatBubbleView(item: item)
        case .systemReminder(let id, let kind, let text, let ts):
            SystemReminderRow(id: id, kind: kind, text: text, timestamp: ts)
        case .skillBody(let id, let text, let ts):
            SkillBodyRow(id: id, text: text, timestamp: ts)
        case .toolCall(let id, let name, let inputJSON, let inputTruncatedTo, let result, let ts):
            toolCard(id: id, name: name, inputJSON: inputJSON,
                     inputTruncatedTo: inputTruncatedTo, result: result, timestamp: ts)
        case .subagentSummary(_, let count, let agentType):
            SubagentSummaryRow(count: count, agentType: agentType)
        }
    }

    @ViewBuilder
    private func toolCard(id: String, name: String, inputJSON: String,
                          inputTruncatedTo: Int?, result: ToolResult?, timestamp: Date?) -> some View {
        switch name {
        case "Read":
            ReadCard(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Edit", "MultiEdit":
            EditCard(id: id, name: name, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Write":
            WriteCard(id: id, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Bash":
            BashCard(id: id, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Grep":
            GrepCard(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Glob":
            GlobCard(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Task", "Agent":
            AgentCard(id: id, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID)
        case "AskUserQuestion":
            AskUserQuestionCard(id: id, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID)
        default:
            GenericToolCard(id: id, name: name, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID)
        }
    }
}
