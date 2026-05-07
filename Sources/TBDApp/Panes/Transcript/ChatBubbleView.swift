import SwiftUI
import TBDShared
import AppKit
import MarkdownUI

/// Single user/assistant prose bubble. Renders block-level markdown
/// (paragraphs, lists, tables, blockquotes, headings) via MarkdownUI
/// and fenced code blocks via the local `codeBlock(...)` view, with
/// segments partitioned upstream by `MarkdownSegments`.
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
                    Markdown(p)
                        .markdownTheme(.chatBubble)
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
}

// MARK: - MarkdownUI theme

/// Chat-bubble-tuned MarkdownUI theme. Built from `Theme.basic` and
/// pared back so the common case — plain prose with inline `**bold**`,
/// `*italic*`, `` `code` ``, `[links]` — is visually indistinguishable
/// from the prior `AttributedString(markdown:)` rendering. Block
/// elements (tables, lists, blockquotes, headings) light up as a
/// byproduct.
private extension MarkdownUI.Theme {
    @MainActor static let chatBubble = MarkdownUI.Theme.basic
        .text {
            ForegroundColor(.primary)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            ForegroundColor(.chatBubbleInlineCode)
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 0, bottom: 16)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.35))
        }
        .list { configuration in
            configuration.label
                .markdownMargin(top: 0, bottom: 16)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.4))
                    .relativeFrame(width: .em(0.2))
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .relativePadding(.horizontal, length: .em(1))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.4))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.2))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.05))
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle { FontWeight(.semibold) }
        }
        .heading5 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle { FontWeight(.semibold) }
        }
        .heading6 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.2))
                .markdownTextStyle { FontWeight(.semibold) }
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(
                    .init(color: .secondary.opacity(0.3))
                )
                .markdownTableBackgroundStyle(
                    .alternatingRows(
                        Color.clear,
                        Color.primary.opacity(0.05)
                    )
                )
                .markdownMargin(top: 0, bottom: 0)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    BackgroundColor(nil)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
        }
        .thematicBreak {
            Divider()
                .markdownMargin(top: .em(0.25), bottom: .em(0.25))
        }
}

private extension Color {
    /// Inline code foreground — desaturated cool/blue. Matches the
    /// Claude Code terminal style: rgb(172,179,209) on dark, mirrored
    /// to a dark slate blue on light. Distinguishes inline code from
    /// surrounding body text without competing visually.
    static let chatBubbleInlineCode = Color(
        light: Color(red: 82.0/255, green: 88.0/255, blue: 130.0/255),
        dark: Color(red: 172.0/255, green: 179.0/255, blue: 209.0/255)
    )
}

// MARK: - Preview

/// Exercises the chat-bubble Markdown rendering path. Uses
/// `PreviewProvider` (not the `#Preview` macro) so the file still
/// compiles under bare `swift build` — the SPM toolchain doesn't ship
/// the `PreviewsMacros` plugin that Xcode injects.
struct ChatBubbleView_Previews: PreviewProvider {
    static let inlineProse = """
    Plain prose with **bold**, *italic*, `inline code`, and a [link](https://example.com).
    """

    static let tableProse = """
    Here are the span kinds we emit:

    | span_kind | Where |
    |---|---|
    | copy_context_suggestion | copy-context |
    | research_report | all research-pipeline steps share this kind |
    """

    static let listProse = """
    ## Next steps

    - First item
    - Second item with `code`
    - Third item
    """

    static let blockquoteProse = """
    > A quoted note from earlier in the thread.
    > Continues onto a second line.
    """

    static let fencedProse = """
    Here is some Swift:

    ```swift
    func greet(_ name: String) -> String {
        return "Hello, \\(name)"
    }
    ```
    """

    static var previews: some View {
        ScrollView {
            VStack(spacing: 8) {
                ChatBubbleView(item: .assistantText(id: "a1", text: inlineProse, timestamp: nil))
                ChatBubbleView(item: .assistantText(id: "a2", text: tableProse, timestamp: nil))
                ChatBubbleView(item: .assistantText(id: "a3", text: listProse, timestamp: nil))
                ChatBubbleView(item: .assistantText(id: "a4", text: blockquoteProse, timestamp: nil))
                ChatBubbleView(item: .assistantText(id: "a5", text: fencedProse, timestamp: nil))
            }
            .padding()
        }
        .frame(width: 560, height: 720)
    }
}

/// Side-by-side parity preview: renders the SAME prose with the OLD
/// `Text(AttributedString(markdown:, options: .inlineOnlyPreservingWhitespace))`
/// path on the left and the NEW `Markdown(...).markdownTheme(.chatBubble)`
/// path on the right. For pure inline prose the two columns should
/// visually overlay; tables, lists, etc. only render on the right
/// (expected — they're block-level features the old path can't show).
struct ChatBubbleParityPreviews: PreviewProvider {
    static let sampleA = """
    Plain prose with **bold**, *italic*, `inline code`, and a [link](https://example.com).

    A second paragraph follows after a blank line. It should sit one body-line-height below the first paragraph, no more, no less.

    And a third paragraph for good measure, so we can eyeball the inter-paragraph gap multiple times.
    """

    static let sampleB = """
    Short opener.

    A longer paragraph that wraps across multiple lines so we can see the intra-paragraph leading clearly. The lines within this paragraph should have zero extra spacing — only the natural body-font line height. If they look airy, the `relativeLineSpacing` is wrong.
    """

    static let sampleC = """
    One-liner with `code`.

    Another paragraph with **strong** and *emph* and a [link](https://example.com) all inline.
    """

    private static let bubbleBg: Color = Color(nsColor: .controlBackgroundColor)

    @ViewBuilder
    private static func oldBubble(_ prose: String) -> some View {
        let attr = (try? AttributedString(
            markdown: prose,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(prose)
        Text(attr)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(bubbleBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private static func newBubble(_ prose: String) -> some View {
        Markdown(prose)
            .markdownTheme(.chatBubble)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(bubbleBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private static func row(_ prose: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("OLD: Text(AttributedString)").font(.caption2).foregroundStyle(.tertiary)
                oldBubble(prose)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("NEW: Markdown + chatBubble theme").font(.caption2).foregroundStyle(.tertiary)
                newBubble(prose)
            }
        }
    }

    static var previews: some View {
        ScrollView {
            VStack(spacing: 16) {
                row(sampleA)
                Divider()
                row(sampleB)
                Divider()
                row(sampleC)
            }
            .padding()
        }
        .frame(width: 900, height: 800)
    }
}
