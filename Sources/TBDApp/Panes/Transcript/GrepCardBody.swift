import SwiftUI
import TBDShared

/// Overlay body for a `Grep` tool call.
struct GrepCardBody: View {
    let id: String
    let result: ToolResult?
    let terminalID: UUID?
    /// The transcript file to read a full body from when there is no
    /// terminal — see `TranscriptFullBodySource`.
    let detailPath: String?

    @State private var fullResultText: String? = nil
    @Environment(AppState.self) var appState

    var fullBodySource: TranscriptFullBodySource? {
        TranscriptFullBodySource.resolve(terminalID: terminalID, detailPath: detailPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = result {
                Text(fullResultText ?? r.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .transcriptSelectableText()
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                if let cap = r.truncatedTo, fullResultText == nil, fullBodySource != nil {
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
        if let r = await fullBodySource?.fetch(itemID: id, appState: appState) {
            fullResultText = r.text
        }
    }
}
