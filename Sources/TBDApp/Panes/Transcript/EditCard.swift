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

    private var input: EditInput? {
        guard let data = inputJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EditInput.self, from: data)
    }

    private var hunks: [EditHunk] {
        if let multi = input?.edits, !multi.isEmpty { return multi }
        if let i = input, let oldS = i.old_string, let newS = i.new_string {
            return [EditHunk(old_string: oldS, new_string: newS, replace_all: i.replace_all)]
        }
        return []
    }

    var body: some View {
        ActivityRowChrome(
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
                Text(input?.file_path ?? "…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if hunks.contains(where: { $0.replace_all == true }) {
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
                        diffHunk(hunk)
                        if hunk != hunks.last { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func diffHunk(_ hunk: EditHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hunk.old_string.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Text("-").foregroundStyle(.red)
                    Text(String(line)).foregroundStyle(.primary)
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.10))
            }
            ForEach(Array(hunk.new_string.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Text("+").foregroundStyle(.green)
                    Text(String(line)).foregroundStyle(.primary)
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
