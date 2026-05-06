import SwiftUI
import TBDShared

/// Curated renderer for the `Task` / `Agent` subagent-dispatch tool.
/// The actual subagent conversation is rendered separately by
/// SubagentDisclosure beneath the parent card — this card only summarizes
/// the dispatch (description, agent type chip, prompt preview, result).
struct AgentCard: View {
    let id: String
    let inputJSON: String
    let inputTruncatedTo: Int?
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @State private var expanded = false
    @State private var fullResultText: String? = nil
    @State private var fullInputJSON: String? = nil
    @EnvironmentObject var appState: AppState

    private struct Input: Decodable {
        let description: String?
        let prompt: String?
        let subagent_type: String?
    }

    private static let decoder = JSONDecoder()

    private func decodeInput() -> Input? {
        guard let data = (fullInputJSON ?? inputJSON).data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(Input.self, from: data)
    }

    private func headerSummary(for parsed: Input?) -> String {
        if let desc = parsed?.description, !desc.isEmpty { return desc }
        return "(no description)"
    }

    private func promptPreview(for parsed: Input?) -> String? {
        guard let p = parsed?.prompt, !p.isEmpty else { return nil }
        let lines = p.split(separator: "\n", omittingEmptySubsequences: false).prefix(3)
        return lines.map(String.init).joined(separator: "\n")
    }

    var body: some View {
        let parsedInput = decodeInput()
        return ActivityRowChrome(
            icon: "sparkles",
            timestamp: timestamp,
            expanded: $expanded
        ) {
            HStack(spacing: 6) {
                Text("Agent")
                Text(headerSummary(for: parsedInput))
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
                if let agentType = parsedInput?.subagent_type, !agentType.isEmpty {
                    Text(agentType)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }
                if let preview = promptPreview(for: parsedInput) {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if let cap = inputTruncatedTo, fullInputJSON == nil, terminalID != nil {
                    TruncationFooter(truncatedTo: cap, currentLength: inputJSON.count) {
                        Task { await fetchFullInput() }
                    }
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

    private func fetchFullInput() async {
        guard let terminalID else { return }
        if let r = try? await appState.daemonClient.terminalTranscriptItemFullBody(terminalID: terminalID, itemID: "\(id)#input") {
            await MainActor.run { fullInputJSON = r.text }
        }
    }
}
