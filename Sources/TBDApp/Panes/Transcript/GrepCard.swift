import SwiftUI
import TBDShared

struct GrepCard: View {
    let id: String
    let inputJSON: String
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @Environment(\.openTranscriptOverlay) private var openTranscriptOverlay

    private struct Input: Decodable { let pattern: String; let path: String? }
    private static let decoder = JSONDecoder()

    private func decodeInput() -> Input? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(Input.self, from: data)
    }

    var body: some View {
        let parsedInput = decodeInput()
        ActivityRowChrome(
            icon: "magnifyingglass",
            timestamp: timestamp,
            onOpen: { openTranscriptOverlay?(id) }
        ) {
            HStack(spacing: 6) {
                Text("Grep")
                Text(parsedInput?.pattern ?? "…")
                    .font(.system(.callout, design: .monospaced))
                if let p = parsedInput?.path {
                    Text("in \(p)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
