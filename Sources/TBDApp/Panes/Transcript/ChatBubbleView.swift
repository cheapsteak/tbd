import SwiftUI
import TBDShared
import AppKit

/// Single user/assistant prose bubble. Renders inline markdown
/// (`**bold**`, `*italic*`, `` `code` ``, `[links](url)`) via
/// AttributedString and fenced code blocks via MarkdownSegments.
struct ChatBubbleView: View {
    let item: TranscriptItem

    private var isUser: Bool {
        if case .userPrompt = item { return true } else { return false }
    }

    private var text: String {
        switch item {
        case .userPrompt(_, let t, _): return t
        case .assistantText(_, let t, _): return t
        default: return ""
        }
    }

    private var roleLabel: String { isUser ? "You" : "Claude" }

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 52) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                roleHeader
                bubbleBody
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 52) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var roleHeader: some View {
        HStack(spacing: 4) {
            if isUser, let ts = item.timestamp {
                Text(ts.absoluteShort).font(.caption2).foregroundStyle(.tertiary)
                Text("·").foregroundStyle(.quaternary).font(.caption2)
            }
            Text(roleLabel).font(.caption2).foregroundStyle(.tertiary)
            if !isUser, let ts = item.timestamp {
                Text("·").foregroundStyle(.quaternary).font(.caption2)
                Text(ts.absoluteShort).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var bubbleBody: some View {
        let segments = MarkdownSegments.split(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .prose(let p):
                    Text(attributedProse(p))
                        .font(.body)
                        .textSelection(.enabled)
                case .code(let lang, let body):
                    codeBlock(language: lang, content: body)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            isUser
                ? Color.accentColor.opacity(0.15)
                : Color(nsColor: .controlBackgroundColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func codeBlock(language: String?, content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                    .clipShape(Capsule())
            }
            Text(content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func attributedProse(_ raw: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: raw, options: opts)) ?? AttributedString(raw)
    }
}
