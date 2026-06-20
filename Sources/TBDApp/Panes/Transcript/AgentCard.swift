import SwiftUI
import TBDShared

/// Header-only renderer for the `Task` / `Agent` subagent-dispatch tool.
/// Click drills into the subagent's thread in-place via \.navigateToThread (was an overlay; see #129).
struct AgentCard: View {
    let id: String
    let inputJSON: String
    let inputTruncatedTo: Int?
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @Environment(\.navigateToThread) private var navigateToThread

    private struct Input: Decodable {
        let description: String?
        let prompt: String?
        let subagent_type: String?
    }
    private static let decoder = JSONDecoder()

    private func decodeInput() -> Input? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(Input.self, from: data)
    }

    private func headerSummary(for parsed: Input?) -> String {
        if let desc = parsed?.description, !desc.isEmpty { return desc }
        return "(no description)"
    }

    var body: some View {
        let parsedInput = decodeInput()
        ActivityRowChrome(
            icon: "sparkles",
            timestamp: timestamp,
            onOpen: { navigateToThread?(id) }
        ) {
            HStack(spacing: 6) {
                Text("Agent")
                Text(headerSummary(for: parsedInput))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if result?.isError == true {
                    Text("error")
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
