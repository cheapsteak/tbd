import SwiftUI
import TBDShared

/// Overlay body for a `Write` tool call.
struct WriteCardBody: View {
    let id: String
    let inputJSON: String
    let inputTruncatedTo: Int?
    let terminalID: UUID?

    @State private var fullInputJSON: String? = nil
    @EnvironmentObject var appState: AppState
    @Environment(\.openFilePreview) private var openFilePreview

    private struct Input: Decodable { let file_path: String; let content: String }
    private static let decoder = JSONDecoder()

    private func decodeInput() -> Input? {
        guard let data = (fullInputJSON ?? inputJSON).data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(Input.self, from: data)
    }

    private var resolvedFilePath: String? {
        if let p = decodeInput()?.file_path { return p }
        return ToolInputFilePath.extract(from: fullInputJSON ?? inputJSON)
    }

    var body: some View {
        let parsedInput = decodeInput()
        VStack(alignment: .leading, spacing: 12) {
            if let content = parsedInput?.content {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .transcriptSelectableText()
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            let showTruncation = inputTruncatedTo != nil && fullInputJSON == nil && terminalID != nil
            let previewPath = resolvedFilePath
            let showPreview = previewPath != nil && openFilePreview != nil
            if showPreview || showTruncation {
                HStack(spacing: 12) {
                    if showPreview, let path = previewPath, let open = openFilePreview {
                        PreviewFileButton(path: path) { open(path) }
                    }
                    if showTruncation, let cap = inputTruncatedTo {
                        TruncationFooter(truncatedTo: cap, currentLength: inputJSON.count) {
                            Task { await fetchFullInput() }
                        }
                    }
                }
            }
        }
    }

    private func fetchFullInput() async {
        guard let terminalID else { return }
        if let r = try? await appState.daemonClient.terminalTranscriptItemFullBody(terminalID: terminalID, itemID: "\(id)#input") {
            await MainActor.run { fullInputJSON = r.text }
        }
    }
}
