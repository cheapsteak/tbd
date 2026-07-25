import SwiftUI
import TBDShared

struct SystemReminderRow: View {
    let id: String
    let kind: SystemKind
    let text: String
    let timestamp: Date?
    /// Where the injected context came from (CLAUDE.md path, hook name).
    /// Nil for reminder kinds that carry no source.
    var source: String? = nil
    /// Original character count when `text` was capped by the parser.
    var truncatedTo: Int? = nil

    @Environment(\.openTranscriptOverlay) private var openTranscriptOverlay

    private var kindLabel: String {
        switch kind {
        case .toolReminder: return "system-reminder"
        case .hookOutput: return "hook"
        case .environmentDetails: return "env"
        case .slashEnvelope: return "command"
        case .skillBody: return "skill"
        case .taskNotification: return "background"
        case .nestedMemory: return "file"
        case .other: return "info"
        }
    }

    var body: some View {
        ActivityRowChrome(
            icon: "info.circle",
            timestamp: timestamp,
            onOpen: { openTranscriptOverlay?(id) }
        ) {
            HStack(spacing: 6) {
                Text(kindLabel)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                    .clipShape(Capsule())
                // Same "<source> · <size>" readout the table renderer shows —
                // injected-context rows are otherwise indistinguishable from
                // one another, and the size is the point.
                if let source, !source.isEmpty {
                    Text(source)
                        // Paths head-truncate so the whole filename survives —
                        // matches the table renderer's `titleTruncation`.
                        .truncationMode(kind == .nestedMemory ? .head : .middle)
                        .lineLimit(1)
                        // Truncated paths need hover to reveal the whole thing;
                        // hook names are short and need no tooltip.
                        .help(kind == .nestedMemory ? source : "")
                    Text("· \(ActivityRowFormatter.injectedSize(text: text, truncatedTo: truncatedTo))")
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
