import SwiftUI
import TBDShared

/// Curated renderer for `Edit` and `MultiEdit`. Shows an inline diff
/// (red/green hunks) for old_string → new_string.
struct EditCard: View {
    let id: String
    let name: String           // "Edit" or "MultiEdit"
    let inputJSON: String
    let result: ToolResult?
    let timestamp: Date?
    let terminalID: UUID?

    @State private var expanded = true
    @EnvironmentObject var appState: AppState

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
        let language: String? = {
            if let path = parsedInput?.file_path {
                return DiffSyntaxHighlighter.languageForFilename(path)
            }
            return nil
        }()
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
            expanded: $expanded
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
        } body: {
            if result?.isError == true, let r = result {
                Text(r.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
                        diffHunk(hunk, language: language)
                        if hunk != hunks.last { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func diffHunk(_ hunk: EditHunk, language: String?) -> some View {
        let oldLines = DiffSyntaxHighlighter.highlightLines(hunk.old_string, language: language)
        let newLines = DiffSyntaxHighlighter.highlightLines(hunk.new_string, language: language)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(oldLines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Text("-").foregroundStyle(.red)
                    Text(AttributedString(line))
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.10))
            }
            ForEach(Array(newLines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Text("+").foregroundStyle(.green)
                    Text(AttributedString(line))
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.10))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .textSelection(.enabled)
    }
}
