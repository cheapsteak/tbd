import SwiftUI
import TBDShared

/// Overlay body for tool calls without a curated card.
struct GenericToolCardBody: View {
    let id: String
    let inputJSON: String
    let inputTruncatedTo: Int?
    let result: ToolResult?
    let terminalID: UUID?
    /// The transcript file to read a full body from when there is no
    /// terminal — see `TranscriptFullBodySource`.
    let detailPath: String?

    @State private var fullResultText: String? = nil
    @State private var fullInputJSON: String? = nil
    @Environment(AppState.self) var appState

    var fullBodySource: TranscriptFullBodySource? {
        TranscriptFullBodySource.resolve(terminalID: terminalID, detailPath: detailPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let displayedInput = fullInputJSON ?? inputJSON
            if !displayedInput.isEmpty && displayedInput != "{}" {
                Text("Input")
                    .font(.caption2).foregroundStyle(.tertiary).textCase(.uppercase)
                Text(prettyJSON(displayedInput))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .transcriptSelectableText()
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                if let cap = inputTruncatedTo, fullInputJSON == nil, fullBodySource != nil {
                    TruncationFooter(truncatedTo: cap, currentLength: inputJSON.count) {
                        Task { await fetchFullInput() }
                    }
                }
            }
            if let r = result {
                Text("Result")
                    .font(.caption2).foregroundStyle(.tertiary).textCase(.uppercase)
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
        if let r = await fullBodySource?.fetch(itemID: id, appState: appState) {
            fullResultText = r.text
        }
    }

    private func fetchFullInput() async {
        if let r = await fullBodySource?.fetch(itemID: "\(id)#input", appState: appState) {
            fullInputJSON = r.text
        }
    }
}
