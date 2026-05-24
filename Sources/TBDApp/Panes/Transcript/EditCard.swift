import SwiftUI
import TBDShared

/// Curated header-only renderer for `Edit` and `MultiEdit`. Click opens
/// the overlay with the diff hunks (see #129).
struct EditCard: View {
    let id: String
    let name: String           // "Edit" or "MultiEdit"
    let inputJSON: String
    let inputTruncatedTo: Int?
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @Environment(\.openTranscriptOverlay) private var openTranscriptOverlay

    private struct EditHunk: Decodable, Equatable {
        let old_string: String
        let new_string: String
        let replace_all: Bool?
    }

    private struct EditInput: Decodable {
        let file_path: String
        let old_string: String?
        let new_string: String?
        let replace_all: Bool?
        let edits: [EditHunk]?
    }

    private static let decoder = JSONDecoder()

    private func decodeInput() -> EditInput? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(EditInput.self, from: data)
    }

    var body: some View {
        let parsedInput = decodeInput()
        let hunks: [EditHunk] = {
            if let multi = parsedInput?.edits, !multi.isEmpty { return multi }
            if let i = parsedInput, let oldS = i.old_string, let newS = i.new_string {
                return [EditHunk(old_string: oldS, new_string: newS, replace_all: i.replace_all)]
            }
            return []
        }()

        return ActivityRowChrome(
            icon: "pencil",
            timestamp: timestamp,
            onOpen: { openTranscriptOverlay?(id) }
        ) {
            HStack(spacing: 6) {
                if name == "MultiEdit" {
                    Text("Edit ×\(hunks.count)")
                } else {
                    Text("Edit")
                }
                Text(parsedInput?.file_path ?? "…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !hunks.isEmpty && hunks.allSatisfy({ $0.replace_all == true }) {
                    Text("all").font(.caption2).foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                        .clipShape(Capsule())
                }
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
