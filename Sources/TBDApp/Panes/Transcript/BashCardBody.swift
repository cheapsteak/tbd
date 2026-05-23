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

    @State private var fullResultText: String? = nil
    @State private var fullInputJSON: String? = nil
    @EnvironmentObject var appState: AppState

    private struct Input: Decodable { let command: String; let description: String? }
    private static let decoder = JSONDecoder()

    private func decodeInput() -> Input? {
        guard let data = (fullInputJSON ?? inputJSON).data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(Input.self, from: data)
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
            if let cap = inputTruncatedTo, fullInputJSON == nil, terminalID != nil {
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

    private func fetchFullInput() async {
        guard let terminalID else { return }
        if let r = try? await appState.daemonClient.terminalTranscriptItemFullBody(terminalID: terminalID, itemID: "\(id)#input") {
            await MainActor.run { fullInputJSON = r.text }
        }
    }
}
