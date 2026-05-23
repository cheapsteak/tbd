import SwiftUI
import TBDShared

/// Renders the click-to-open overlay for a transcript row. Hosted by both
/// the terminal-pane `.overlay { … }` (primary location) and the
/// window-root fallback `.overlay { … }`. Looks up its item by
/// `(terminalID, itemID)` from the live transcript store in AppState.
///
/// Safe to use real `ScrollView` here: this view is rendered *outside*
/// the transcript pane's LazyVStack — no `_FlexFrameLayout`/
/// `ScrollViewLayoutComputer` measure-then-clamp trap. See issue #129.
struct TranscriptOverlayView: View {
    let frame: TranscriptOverlayFrame
    let hasBack: Bool
    let onBack: () -> Void
    let onClose: () -> Void

    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                bodyContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if hasBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.caption)
                }
                .buttonStyle(.plain)
                .help("Back")
            }
            Image(systemName: headerIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(headerLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let ts = lookupItem()?.timestamp {
                Text(ts.absoluteShort)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headerIcon: String {
        guard let item = lookupItem() else { return "doc.text" }
        switch item {
        case .toolCall(_, let name, _, _, _, _, _, _):
            switch name {
            case "Bash":              return "terminal"
            case "Write":             return "square.and.pencil"
            case "Read":              return "doc.text"
            case "Edit", "MultiEdit": return "pencil"
            case "Grep":              return "magnifyingglass"
            case "Glob":              return "folder"
            case "Task", "Agent":     return "sparkles"
            default:                  return "wrench.and.screwdriver"
            }
        case .thinking:
            return "brain"
        case .systemReminder(_, let kind, _, _):
            return kind == .skillBody ? "sparkles" : "info.circle"
        case .userPrompt, .assistantText, .slashCommand:
            return "doc.text"
        }
    }

    private var headerLabel: String {
        guard let item = lookupItem() else { return "" }
        switch item {
        case .toolCall(_, let name, let inputJSON, _, _, _, _, _):
            return toolCallLabel(name: name, inputJSON: inputJSON)
        case .thinking:
            return "Thinking"
        case .systemReminder(_, let kind, _, _):
            switch kind {
            case .skillBody:          return "Skill"
            case .toolReminder:       return "system-reminder"
            case .hookOutput:         return "hook"
            case .environmentDetails: return "env"
            case .slashEnvelope:      return "command"
            case .other:              return "info"
            }
        case .userPrompt:   return "User"
        case .assistantText: return "Assistant"
        case .slashCommand(_, let name, _, _): return "/\(name)"
        }
    }

    /// One-line label matching what each collapsed row's `ActivityRowChrome`
    /// header `Text(...)` renders. For tool calls, decodes the input enough to
    /// surface the same first-line summary the card itself shows.
    private func toolCallLabel(name: String, inputJSON: String) -> String {
        struct AnyInput: Decodable {
            let command: String?
            let description: String?
            let file_path: String?
            let pattern: String?
            let path: String?
            let prompt: String?
        }
        let parsed = (inputJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(AnyInput.self, from: $0) })
        switch name {
        case "Bash":
            if let desc = parsed?.description, !desc.isEmpty { return "Bash · \(desc)" }
            if let cmd = parsed?.command {
                let oneLine = cmd.replacingOccurrences(of: "\n", with: " ")
                let trimmed = oneLine.count > 60 ? "\(oneLine.prefix(60))…" : oneLine
                return "Bash · $(\(trimmed))"
            }
            return "Bash"
        case "Write", "Read":
            return "\(name) · \(parsed?.file_path ?? "…")"
        case "Edit", "MultiEdit":
            return "\(name) · \(parsed?.file_path ?? "…")"
        case "Grep", "Glob":
            return "\(name) · \(parsed?.pattern ?? "…")"
        case "Task", "Agent":
            if let desc = parsed?.description, !desc.isEmpty { return "Agent · \(desc)" }
            return "Agent"
        default:
            return name.replacingOccurrences(of: "mcp__", with: "mcp · ")
                .replacingOccurrences(of: "__", with: " · ")
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let item = lookupItem() {
            switch item {
            case .toolCall(let toolID, let name, let inputJSON, let inputTruncatedTo, let toolResult, _, _, _) where name == "Bash":
                BashCardBody(
                    id: toolID,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    result: toolResult,
                    terminalID: frame.terminalID
                )
            case .toolCall(let toolID, let name, let inputJSON, let inputTruncatedTo, _, _, _, _) where name == "Write":
                WriteCardBody(
                    id: toolID,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    terminalID: frame.terminalID
                )
            case .toolCall(let toolID, let name, let inputJSON, _, let toolResult, _, _, _) where name == "Read":
                ReadCardBody(
                    id: toolID,
                    inputJSON: inputJSON,
                    result: toolResult,
                    terminalID: frame.terminalID
                )
            case .toolCall(let toolID, let name, let inputJSON, let inputTruncatedTo, let toolResult, _, _, _) where name == "Edit" || name == "MultiEdit":
                EditCardBody(
                    id: toolID,
                    name: name,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    result: toolResult,
                    terminalID: frame.terminalID
                )
            case .toolCall(let toolID, let name, _, _, let toolResult, _, _, _) where name == "Grep":
                GrepCardBody(
                    id: toolID,
                    result: toolResult,
                    terminalID: frame.terminalID
                )
            case .toolCall(let toolID, let name, _, _, let toolResult, _, _, _) where name == "Glob":
                GlobCardBody(
                    id: toolID,
                    result: toolResult,
                    terminalID: frame.terminalID
                )
            case .toolCall(let toolID, let name, let inputJSON, let inputTruncatedTo, let toolResult, let subagent, _, _) where name == "Task" || name == "Agent":
                AgentCardBody(
                    id: toolID,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    result: toolResult,
                    subagent: subagent,
                    terminalID: frame.terminalID
                )
            case .toolCall(let toolID, _, let inputJSON, let inputTruncatedTo, let toolResult, _, _, _):
                GenericToolCardBody(
                    id: toolID,
                    inputJSON: inputJSON,
                    inputTruncatedTo: inputTruncatedTo,
                    result: toolResult,
                    terminalID: frame.terminalID
                )
            case .systemReminder(_, let kind, let text, _) where kind == .skillBody:
                SkillBodyRowBody(text: text)
            case .thinking(_, let text, _):
                ThinkingRowBody(text: text)
            case .systemReminder(_, _, let text, _):
                SystemReminderRowBody(text: text)
            default:
                Text(String(describing: item))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else {
            Text("Item not found.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// Look up the active transcript item by terminal + item ID.
    ///
    /// AppState stores transcripts keyed by `claudeSessionID` (a String),
    /// not directly by `terminalID`. The lookup resolves:
    ///   terminalID (UUID) → Terminal.claudeSessionID (String?)
    ///   → appState.sessionTranscripts[sessionID] → [TranscriptItem]
    ///   → first(where: { $0.id == frame.itemID })
    ///
    /// Returns nil if the terminal isn't found, has no active session,
    /// the session isn't in the transcript store, or the item has been
    /// removed.
    private func lookupItem() -> TranscriptItem? {
        guard let terminal = appState.terminals.values
            .flatMap({ $0 })
            .first(where: { $0.id == frame.terminalID }),
              let sessionID = terminal.claudeSessionID,
              let items = appState.sessionTranscripts[sessionID]
        else { return nil }
        return deepFind(frame.itemID, in: items)
    }

    private func deepFind(_ targetID: String, in items: [TranscriptItem]) -> TranscriptItem? {
        for item in items {
            if item.id == targetID { return item }
            if case .toolCall(_, _, _, _, _, let subagent, _, _) = item,
               let sub = subagent,
               let found = deepFind(targetID, in: sub.items) {
                return found
            }
        }
        return nil
    }
}
