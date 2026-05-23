import SwiftUI
import TBDShared

/// Header-only renderer for tool calls without a curated card.
struct GenericToolCard: View {
    let id: String
    let name: String
    let inputJSON: String
    let inputTruncatedTo: Int?
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @Environment(\.openTranscriptOverlay) private var openTranscriptOverlay

    private var displayName: String {
        if name.hasPrefix("mcp__") {
            return name.replacingOccurrences(of: "mcp__", with: "mcp · ")
                .replacingOccurrences(of: "__", with: " · ")
        }
        return name
    }

    var body: some View {
        ActivityRowChrome(
            icon: "wrench.and.screwdriver",
            timestamp: timestamp,
            onOpen: { openTranscriptOverlay?(id) }
        ) {
            HStack(spacing: 6) {
                Text(displayName)
                if result?.isError == true {
                    Text("error")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
