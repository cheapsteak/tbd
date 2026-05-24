import SwiftUI
import TBDShared

/// Overlay body for a `.thinking` item.
struct ThinkingRowBody: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .italic()
            .foregroundStyle(.tertiary)
            .transcriptSelectableText()
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
