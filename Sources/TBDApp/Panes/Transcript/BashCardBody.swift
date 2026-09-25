import SwiftUI
import TBDShared

/// Overlay body for a `Bash` tool call. Hosted inside `TranscriptOverlayView`'s
/// outer scroll container — does NOT introduce its own scroll view (see
/// `Sources/TBDApp/Panes/Transcript/CLAUDE.md`).
struct BashCardBody: View {
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

    private struct Input: Decodable { let command: String; let description: String? }
    private static let decoder = JSONDecoder()

    private func decodeInput() -> Input? {
        guard let data = (fullInputJSON ?? inputJSON).data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(Input.self, from: data)
    }

    var fullBodySource: TranscriptFullBodySource? {
        TranscriptFullBodySource.resolve(terminalID: terminalID, detailPath: detailPath)
    }

    var body: some View {
        let parsedInput = decodeInput()
        VStack(alignment: .leading, spacing: 12) {
            if let cmd = parsedInput?.command {
                Text("Command")
                    .font(.caption2).foregroundStyle(.tertiary).textCase(.uppercase)
                Text(cmd)
                    .font(.system(.caption, design: .monospaced))
                    .transcriptSelectableText()
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if let cap = inputTruncatedTo, fullInputJSON == nil, fullBodySource != nil {
                TruncationFooter(truncatedTo: cap, currentLength: inputJSON.count) {
                    Task { await fetchFullInput() }
                }
            }
            if let r = result {
                Text("Result")
                    .font(.caption2).foregroundStyle(.tertiary).textCase(.uppercase)
                Text(fullResultText ?? r.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(r.isError ? .red.opacity(0.85) : .secondary)
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
        if let text = await fetchFullBody(itemID: id) {
            await MainActor.run { fullResultText = text }
        }
    }

    private func fetchFullInput() async {
        if let text = await fetchFullBody(itemID: "\(id)#input") {
            await MainActor.run { fullInputJSON = text }
        }
    }

    private func fetchFullBody(itemID: String) async -> String? {
        await fullBodySource?.fetch(itemID: itemID, appState: appState)?.text
    }
}
