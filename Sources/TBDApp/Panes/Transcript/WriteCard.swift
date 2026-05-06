import SwiftUI
import TBDShared

struct WriteCard: View {
    let id: String
    let inputJSON: String
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @State private var expanded = true
    @State private var containerExpanded = false
    @EnvironmentObject var appState: AppState

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
        return ActivityRowChrome(
            icon: "square.and.pencil",
            timestamp: timestamp,
            expanded: $expanded
        ) {
            HStack(spacing: 6) {
                Text("Write")
                Text(parsedInput?.file_path ?? "…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(lineCount(for: parsedInput)) lines").font(.caption2).foregroundStyle(.tertiary)
            }
        } body: {
            if let content = parsedInput?.content {
                ZStack(alignment: .topTrailing) {
                    ScrollView(.vertical) {
                        Text(content)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: containerExpanded ? .infinity : 120)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    Button(action: { containerExpanded.toggle() }) {
                        Image(systemName: containerExpanded
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                            .padding(4)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .help(containerExpanded ? "Collapse container" : "Expand container")
                }
            }
        }
    }
}
