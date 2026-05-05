import SwiftUI
import TBDShared

struct WriteCard: View {
    let id: String
    let inputJSON: String
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @State private var expanded = true
    @EnvironmentObject var appState: AppState

    private struct Input: Decodable { let file_path: String; let content: String }

    private var input: Input? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Input.self, from: data)
    }

    private var lineCount: Int {
        input?.content.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
    }

    var body: some View {
        ActivityRowChrome(
            icon: "square.and.pencil",
            timestamp: timestamp,
            expanded: $expanded
        ) {
            HStack(spacing: 6) {
                Text("Write")
                Text(input?.file_path ?? "…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(lineCount) lines").font(.caption2).foregroundStyle(.tertiary)
            }
        } body: {
            if let content = input?.content {
                let preview = String(content.split(separator: "\n", omittingEmptySubsequences: false).prefix(15).joined(separator: "\n"))
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}
