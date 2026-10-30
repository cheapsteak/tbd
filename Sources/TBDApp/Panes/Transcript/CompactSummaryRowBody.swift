import MarkdownUI
import SwiftUI

/// Overlay body for a `.systemReminder` item whose kind is `.compactSummary`:
/// the summary Claude Code wrote in place of the earlier turns when it
/// compacted the conversation.
///
/// Claude Code writes that summary as Markdown (numbered sections, bullet
/// lists, code spans), so it renders through MarkdownUI with the chat-bubble
/// theme, as `OverlayFileView` renders a `.md` file. The overlay is hosted
/// outside the transcript list, so a plain `.textSelection(.enabled)` is safe
/// here, and the overlay's own `ScrollView` scrolls it. The parser never
/// truncates a user-role line, so `text` is already the whole summary and no
/// full-body fetch is needed.
struct CompactSummaryRowBody: View {
    let text: String

    var body: some View {
        Markdown(text)
            .markdownTheme(.chatBubble)
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
