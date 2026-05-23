import SwiftUI
import TBDShared

/// Overlay body for `Edit` and `MultiEdit` tool calls. Shows the diff hunks
/// (red/green) plus the existing Preview-file + truncation affordances.
struct EditCardBody: View {
    let id: String
    let name: String           // "Edit" or "MultiEdit"
    let inputJSON: String
    let inputTruncatedTo: Int?
    let result: ToolResult?
    let terminalID: UUID?

    @State private var fullInputJSON: String? = nil
    @EnvironmentObject var appState: AppState
    @Environment(\.openFilePreview) private var openFilePreview

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
        guard let data = (fullInputJSON ?? inputJSON).data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(EditInput.self, from: data)
    }

    private var resolvedFilePath: String? {
        if let p = decodeInput()?.file_path { return p }
        return ToolInputFilePath.extract(from: fullInputJSON ?? inputJSON)
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

        VStack(alignment: .leading, spacing: 12) {
            if result?.isError == true, let r = result {
                Text(r.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .transcriptSelectableText()
            } else {
                ForEach(Array(hunks.enumerated()), id: \.offset) { idx, hunk in
                    diffHunk(hunk, language: language)
                    if idx < hunks.count - 1 { Divider() }
                }
            }
            let showTruncation = inputTruncatedTo != nil && fullInputJSON == nil && terminalID != nil
            let previewPath = resolvedFilePath
            let showPreview = previewPath != nil && openFilePreview != nil
            if showPreview || showTruncation {
                HStack(spacing: 12) {
                    if showPreview, let path = previewPath, let open = openFilePreview {
                        PreviewFileButton(path: path) { open(path) }
                    }
                    if showTruncation, let cap = inputTruncatedTo {
                        TruncationFooter(truncatedTo: cap, currentLength: inputJSON.count) {
                            Task { await fetchFullInput() }
                        }
                    }
                }
            }
        }
    }

    private func fetchFullInput() async {
        guard let terminalID else { return }
        if let r = try? await appState.daemonClient.terminalTranscriptItemFullBody(terminalID: terminalID, itemID: "\(id)#input") {
            await MainActor.run { fullInputJSON = r.text }
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
        .transcriptSelectableText()
    }
}
