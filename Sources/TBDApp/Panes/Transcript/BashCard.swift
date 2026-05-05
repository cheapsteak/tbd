import SwiftUI
import TBDShared

struct BashCard: View {
    let id: String
    let inputJSON: String
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID

    @State private var expanded = true
    @State private var fullResultText: String? = nil
    @EnvironmentObject var appState: AppState

    private struct Input: Decodable { let command: String; let description: String? }

    private var input: Input? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Input.self, from: data)
    }

    private var headerSummary: String {
        if let desc = input?.description, !desc.isEmpty { return desc }
        if let cmd = input?.command {
            let trimmed = cmd.replacingOccurrences(of: "\n", with: " ")
            return "$(\(String(trimmed.prefix(60)))…)"
        }
        return "…"
    }

    var body: some View {
        ActivityRowChrome(
            icon: "terminal",
            timestamp: timestamp,
            expanded: $expanded
        ) {
            HStack(spacing: 6) {
                Text("Bash")
                Text(headerSummary)
                    .lineLimit(1)
                if result?.isError == true {
                    Text("failed")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.red)
                }
            }
        } body: {
            VStack(alignment: .leading, spacing: 8) {
                if let cmd = input?.command {
                    Text(cmd)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if let r = result {
                    Text(fullResultText ?? r.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(r.isError ? .red.opacity(0.85) : .secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if let cap = r.truncatedTo, fullResultText == nil {
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
        if let r = try? await appState.daemonClient.terminalTranscriptItemFullBody(terminalID: terminalID, itemID: id) {
            await MainActor.run { fullResultText = r.text }
        }
    }
}
