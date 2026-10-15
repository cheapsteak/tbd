import SwiftUI

/// The permission card's "Show all" popover: a tool's whole input. A popover
/// renders outside the transcript row and is never measured as part of it, so
/// a real `ScrollView` is safe here (this file is excluded from
/// `no_scrollview_in_transcript_cards`).
struct PromptInputPopoverView: View {
    let title: String
    let text: String
    /// The provider shortened the input, or left it out, for size.
    let truncated: Bool

    static let truncatedNote = "The provider shortened this input."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if truncated {
                Label(Self.truncatedNote, systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(width: 520, height: 360)
    }
}
