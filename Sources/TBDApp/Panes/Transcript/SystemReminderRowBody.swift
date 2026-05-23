import SwiftUI
import TBDShared

/// Overlay body for a `.systemReminder` item (non-skillBody kinds).
struct SystemReminderRowBody: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .transcriptSelectableText()
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
