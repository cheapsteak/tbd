import SwiftUI
import TBDShared

/// Curated renderer for the `Read` tool. Compact by default (no body shown);
/// expand to see file contents result.
struct ReadCard: View {
    let id: String
    let inputJSON: String
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @State private var expanded = false
    @State private var fullResultText: String? = nil
    @EnvironmentObject var appState: AppState

    private struct Input: Decodable {
        let file_path: String
        let offset: Int?
        let limit: Int?
    }

    private static let decoder = JSONDecoder()

    private func decodeInput() -> Input? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(Input.self, from: data)
    }

    var body: some View {
        let parsedInput = decodeInput()
        return ActivityRowChrome(
            icon: "doc.text",
            timestamp: timestamp,
            expanded: $expanded
        ) {
            HStack(spacing: 6) {
                Text("Read")
                    .foregroundStyle(.primary)
                Text(parsedInput?.file_path ?? "…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let off = parsedInput?.offset {
                    if let lim = parsedInput?.limit {
                        Text("lines \(off)–\(off + lim - 1)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("from line \(off)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
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
