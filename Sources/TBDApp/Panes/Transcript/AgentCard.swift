import SwiftUI
import TBDShared

/// Curated renderer for the `Task` / `Agent` subagent-dispatch tool.
/// The actual subagent conversation is rendered separately by
/// SubagentDisclosure beneath the parent card — this card only summarizes
/// the dispatch (description, agent type chip, prompt preview, result).
struct AgentCard: View {
    let id: String
    let inputJSON: String
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @State private var expanded = false
    @State private var fullResultText: String? = nil
    @EnvironmentObject var appState: AppState

    private struct Input: Decodable {
        let description: String?
        let prompt: String?
        let subagent_type: String?
    }

    private var input: Input? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Input.self, from: data)
    }

    private var headerSummary: String {
        if let desc = input?.description, !desc.isEmpty { return desc }
        return "(no description)"
    }

    private var promptPreview: String? {
        guard let p = input?.prompt, !p.isEmpty else { return nil }
        let lines = p.split(separator: "\n", omittingEmptySubsequences: false).prefix(3)
        return lines.map(String.init).joined(separator: "\n")
    }

    var body: some View {
        ActivityRowChrome(
            icon: "sparkles",
            timestamp: timestamp,
            expanded: $expanded
        ) {
            HStack(spacing: 6) {
                Text("Agent")
                Text(headerSummary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if result?.isError == true {
                    Text("error")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.red)
                }
            }
        } body: {
            VStack(alignment: .leading, spacing: 8) {
                if let agentType = input?.subagent_type, !agentType.isEmpty {
                    Text(agentType)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }
                if let preview = promptPreview {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if let r = result {
                    Text(fullResultText ?? r.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if let cap = r.truncatedTo, fullResultText == nil, terminalID != nil {
                        TruncationFooter(truncatedTo: cap, currentLength: r.text.count) {
                            Task { await fetchFull() }
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Running…").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func fetchFull() async {
        guard let terminalID else { return }
        if let r = try? await appState.daemonClient.terminalTranscriptItemFullBody(terminalID: terminalID, itemID: id) {
            await MainActor.run { fullResultText = r.text }
        }
    }
}
