import SwiftUI
import TBDShared

/// Overlay body for a `Read` tool call.
struct ReadCardBody: View {
    let id: String
    let inputJSON: String
    let result: ToolResult?
    let terminalID: UUID?

    @State private var fullResultText: String? = nil
    @EnvironmentObject var appState: AppState
    @Environment(\.openFilePreview) private var openFilePreview

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
                let showTruncation = r.truncatedTo != nil && fullResultText == nil && terminalID != nil
                let showPreview = parsedInput?.file_path != nil && openFilePreview != nil
                if showPreview || showTruncation {
                    HStack(spacing: 12) {
                        if showPreview, let path = parsedInput?.file_path, let open = openFilePreview {
                            PreviewFileButton(path: path) { open(path) }
                        }
                        if showTruncation, let cap = r.truncatedTo {
                            TruncationFooter(truncatedTo: cap, currentLength: r.text.count) {
                                Task { await fetchFull() }
                            }
                        }
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
