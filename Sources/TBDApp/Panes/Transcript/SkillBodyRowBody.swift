import SwiftUI
import TBDShared

/// Overlay body for a `.systemReminder` item whose kind is `.skillBody`.
struct SkillBodyRowBody: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .transcriptSelectableText()
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
