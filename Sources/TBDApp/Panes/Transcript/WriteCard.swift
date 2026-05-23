import SwiftUI
import TBDShared

struct WriteCard: View {
    let id: String
    let inputJSON: String
    let inputTruncatedTo: Int?
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @Environment(\.openTranscriptOverlay) private var openTranscriptOverlay

    private struct Input: Decodable { let file_path: String; let content: String }
    private static let decoder = JSONDecoder()

    private func decodeInput() -> Input? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(Input.self, from: data)
    }

    private func lineCount(for parsed: Input?) -> Int {
        guard let content = parsed?.content, !content.isEmpty else { return 0 }
        return content.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        let parsedInput = decodeInput()
        ActivityRowChrome(
            icon: "square.and.pencil",
            timestamp: timestamp,
            onOpen: { openTranscriptOverlay?(id) }
        ) {
            HStack(spacing: 6) {
                Text("Write")
                Text(parsedInput?.file_path ?? "…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                let count = lineCount(for: parsedInput)
                let prefix = (inputTruncatedTo != nil) ? "≥" : ""
                Text("\(prefix)\(count) lines").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
