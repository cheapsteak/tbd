import SwiftUI
import TBDShared

/// Fallback renderer for tool calls that don't have a curated card.
struct GenericToolCard: View {
    let id: String
    let name: String
    let inputJSON: String
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @State private var expanded = false
    @State private var fullResultText: String? = nil
    @EnvironmentObject var appState: AppState

    private var displayName: String {
        if name.hasPrefix("mcp__") {
            // mcp__plugin_foo__bar → mcp · plugin_foo · bar
            return name.replacingOccurrences(of: "mcp__", with: "mcp · ")
                .replacingOccurrences(of: "__", with: " · ")
        }
        return name
    }

    var body: some View {
        ActivityRowChrome(
            icon: "wrench.and.screwdriver",
            timestamp: timestamp,
            expanded: $expanded
        ) {
            HStack(spacing: 6) {
                Text(displayName)
                if result?.isError == true {
                    Text("error")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.red)
                }
            }
        } body: {
            VStack(alignment: .leading, spacing: 8) {
                if !inputJSON.isEmpty && inputJSON != "{}" {
                    Text(prettyJSON(inputJSON))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
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
                        Text("Running…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return s
    }

    private func fetchFull() async {
        guard let terminalID else { return }
        do {
            let result = try await appState.daemonClient.terminalTranscriptItemFullBody(terminalID: terminalID, itemID: id)
            await MainActor.run { fullResultText = result.text }
        } catch {
            // Keep showing truncated version on error.
        }
    }
}
