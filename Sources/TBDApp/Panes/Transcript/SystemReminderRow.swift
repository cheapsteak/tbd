import SwiftUI
import TBDShared

struct SystemReminderRow: View {
    let id: String
    let kind: SystemKind
    let text: String
    let timestamp: Date?

    @State private var expanded = false

    private var kindLabel: String {
        switch kind {
        case .toolReminder: return "system-reminder"
        case .hookOutput: return "hook"
        case .environmentDetails: return "env"
        case .slashEnvelope: return "command"
        case .other: return "info"
        }
    }

    var body: some View {
        ActivityRowChrome(
            icon: "info.circle",
            timestamp: timestamp,
            expanded: $expanded
        ) {
            HStack(spacing: 6) {
                Text(kindLabel)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                    .clipShape(Capsule())
            }
        } body: {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
        }
    }
}
