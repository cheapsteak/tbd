import SwiftUI
import TBDShared

/// Tool names whose activity is hidden from the timeline. Keep small;
/// these are tools whose existence in the transcript adds no signal
/// for the reader.
private let hiddenToolNames: Set<String> = ["TodoWrite", "TaskUpdate", "TaskCreate"]

/// Renders an ordered list of transcript items by dispatching each to its
/// per-case view. Used by both the live transcript pane (top-level depth=0)
/// and recursively by SubagentDisclosure (depth=N) for nested subagent timelines.
struct TranscriptItemsView: View {
    let items: [TranscriptItem]
    let terminalID: UUID?
    var depth: Int = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    rowFor(item)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func rowFor(_ item: TranscriptItem) -> some View {
        switch item {
        case .userPrompt, .assistantText:
            ChatBubbleView(item: item)
        case .thinking:
            EmptyView()
        case .systemReminder(let id, let kind, let text, let ts):
            if kind == .skillBody {
                SkillBodyRow(id: id, text: text, timestamp: ts)
            } else {
                SystemReminderRow(id: id, kind: kind, text: text, timestamp: ts)
            }
        case .slashCommand(let id, let name, let args, let ts):
            SlashCommandRow(id: id, name: name, args: args, timestamp: ts)
        case .toolCall(let id, let name, let inputJSON, let result, let subagent, let ts):
            if hiddenToolNames.contains(name) {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    toolCardFor(name: name, id: id, inputJSON: inputJSON, result: result, timestamp: ts)
                    if let subagent {
                        SubagentDisclosure(subagent: subagent, terminalID: terminalID, depth: depth)
                            .padding(.leading, 32)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolCardFor(name: String, id: String, inputJSON: String, result: ToolResult?, timestamp: Date?) -> some View {
        switch name {
        case "Read":
            ReadCard(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Edit", "MultiEdit":
            EditCard(id: id, name: name, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Write":
            WriteCard(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Bash":
            BashCard(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Grep":
            GrepCard(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Glob":
            GlobCard(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        case "Task", "Agent":
            AgentCard(id: id, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        default:
            GenericToolCard(id: id, name: name, inputJSON: inputJSON, result: result, timestamp: timestamp, terminalID: terminalID)
        }
    }
}
