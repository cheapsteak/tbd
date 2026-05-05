import SwiftUI
import TBDShared

struct GlobCard: View {
    let id: String
    let inputJSON: String
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @State private var expanded = true
    @State private var fullResultText: String? = nil
    @EnvironmentObject var appState: AppState

    private struct Input: Decodable { let pattern: String; let path: String? }

    private var input: Input? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Input.self, from: data)
    }

    var body: some View {
        ActivityRowChrome(
            icon: "folder",
            timestamp: timestamp,
            expanded: $expanded
        ) {
            HStack(spacing: 6) {
                Text("Glob")
                Text(input?.pattern ?? "…")
                    .font(.system(.callout, design: .monospaced))
                if let p = input?.path {
                    Text("in \(p)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } body: {
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

    private func fetchFull() async {
        guard let terminalID else { return }
        if let r = try? await appState.daemonClient.terminalTranscriptItemFullBody(terminalID: terminalID, itemID: id) {
            await MainActor.run { fullResultText = r.text }
        }
    }
}
