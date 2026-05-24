import SwiftUI
import TBDShared

struct BashCard: View {
    let id: String
    let inputJSON: String
    let inputTruncatedTo: Int?
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @Environment(\.openTranscriptOverlay) private var openTranscriptOverlay

    private struct Input: Decodable { let command: String; let description: String? }
    private static let decoder = JSONDecoder()

    private func decodeInput() -> Input? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(Input.self, from: data)
    }

    private func headerSummary(for parsed: Input?) -> String {
        if let desc = parsed?.description, !desc.isEmpty { return desc }
        if let cmd = parsed?.command {
            let trimmed = cmd.replacingOccurrences(of: "\n", with: " ")
            if trimmed.count > 60 {
                return "$(\(String(trimmed.prefix(60)))…)"
            }
            return "$(\(trimmed))"
        }
        return "…"
    }

    var body: some View {
        let parsedInput = decodeInput()
        ActivityRowChrome(
            icon: "terminal",
            timestamp: timestamp,
            onOpen: { openTranscriptOverlay?(id) }
        ) {
            HStack(spacing: 6) {
                Text("Bash")
                Text(headerSummary(for: parsedInput))
                    .lineLimit(1)
                if result?.isError == true {
                    Text("failed")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
