import SwiftUI
import TBDShared

/// Curated renderer for the `Read` tool. Collapsed header-only row; click
/// opens the overlay with file contents (see #129).
struct ReadCard: View {
    let id: String
    let inputJSON: String
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @Environment(\.openTranscriptOverlay) private var openTranscriptOverlay

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
        ActivityRowChrome(
            icon: "doc.text",
            timestamp: timestamp,
            onOpen: { openTranscriptOverlay?(id) }
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
        }
    }
}
