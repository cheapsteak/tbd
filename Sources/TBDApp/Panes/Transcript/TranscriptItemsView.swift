import SwiftUI
import TBDShared
import os

/// Tool names whose activity is hidden from the timeline. Keep small;
/// these are tools whose existence in the transcript adds no signal
/// for the reader.
let hiddenToolNames: Set<String> = ["TodoWrite", "TaskUpdate", "TaskCreate", "Skill"]

/// True if this item is hidden from the timeline (by the dispatch logic in
/// `TranscriptItemsView.rowFor`). Centralized so callers like
/// `SubagentDisclosure` can compute accurate counts without duplicating the
/// rule.
func isHiddenInTranscript(_ item: TranscriptItem) -> Bool {
    switch item {
    case .thinking:
        return true
    case .toolCall(_, let name, _, _, _, _, _):
        return hiddenToolNames.contains(name)
    default:
        return false
    }
}

/// Renders an ordered list of transcript items by dispatching each to its
/// per-case view. Used by both the live transcript pane (top-level depth=0)
/// and recursively by SubagentDisclosure (depth=N) for nested subagent timelines.
struct TranscriptItemsView: View {
    let items: [TranscriptItem]
    let terminalID: UUID?
    var depth: Int = 0

    nonisolated private static let perfLog = Logger(subsystem: "com.tbd.app", category: "perf-transcript")

    /// Tracks which terminal IDs have already emitted a `items.body` marker
    /// for >100-item bodies in this process. Throwaway diagnostic state —
    /// removed when the `perf-transcript` instrumentation is cleaned up.
    nonisolated private static let bodyLogged = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    nonisolated private static func shortID(_ id: UUID) -> String {
        return String(id.uuidString.suffix(4))
    }

    var body: some View {
        let _ = {
            guard depth == 0, items.count > 100, let tid = terminalID else { return }
            Self.bodyLogged.withLock { logged in
                if !logged.contains(tid) {
                    logged.insert(tid)
                    Self.perfLog.debug("items.body terminalID=\(Self.shortID(tid), privacy: .public) count=\(items.count, privacy: .public)")
                }
            }
        }()
        if depth >= 8 {
            Text("… nested too deep")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        } else if depth == 0 {
            // Top-level chat: LazyVStack inside a ScrollView with
            // defaultScrollAnchor(.bottom) (applied by the parent pane). Lazy
            // realization for perf; the parent's anchor handles initial
            // bottom-positioning and follow-bottom-on-growth declaratively.
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    rowFor(item)
                }
            }
            .padding(.vertical, 8)
        } else {
            // Nested subagent timeline (typically short, inside a DisclosureGroup).
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    rowFor(item)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func rowFor(_ item: TranscriptItem) -> some View {
        Group {
            switch item {
            case .userPrompt, .assistantText:
                ChatBubbleView(item: item)
            case .thinking:
                // Hidden by design. Claude Code emits .thinking blocks with empty
                // text fields in practice (the actual reasoning is server-side
                // cached), so a visible row would always show "Thinking" with no
                // body. Re-enable here if extended-thinking content ever ships
                // inline in the JSONL.
                EmptyView()
            case .systemReminder(let id, let kind, let text, let ts):
                if kind == .skillBody {
                    SkillBodyRow(id: id, text: text, timestamp: ts)
                } else {
                    SystemReminderRow(id: id, kind: kind, text: text, timestamp: ts)
                }
            case .slashCommand:
                // Dead branch: TranscriptParser folds <command-name> envelopes into
                // .userPrompt items so they render as user chat bubbles. The enum
                // case stays in the wire format for Codable safety, but no parser
                // path emits it today.
                EmptyView()
            case .toolCall(let id, let name, let inputJSON, let inputTruncatedTo, let result, let subagent, let ts):
                if hiddenToolNames.contains(name) {
                    EmptyView()
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        toolCardFor(name: name, id: id, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: ts)
                        if let subagent {
                            SubagentDisclosure(subagent: subagent, terminalID: terminalID, depth: depth)
                                .padding(.leading, 32)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolCardFor(name: String, id: String, inputJSON: String, inputTruncatedTo: Int?, result: ToolResult?, timestamp: Date?) -> some View {
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
        default:
            GenericToolCard(id: id, name: name, inputJSON: inputJSON, inputTruncatedTo: inputTruncatedTo, result: result, timestamp: timestamp, terminalID: terminalID)
        }
    }
}
