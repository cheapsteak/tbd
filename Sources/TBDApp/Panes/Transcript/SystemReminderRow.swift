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

    @ViewBuilder var body: some View {
        // Background-task notifications are not labelled reminders: they read as
        // one gray sentence with no icon, no capsule and no timestamp. Same
        // treatment, same shared phrasing as the native cell.
        if kind == .taskNotification {
            taskNotificationRow
        } else {
            reminderRow
        }
    }

    private var taskNotificationRow: some View {
        let phrasing = ActivityRowFormatter.taskNotificationPhrasing(text)
        return ActivityRowChrome(
            icon: nil,
            timestamp: nil,
            onOpen: { openTranscriptOverlay?(id) }
        ) {
            HStack(spacing: 6) {
                // `ActivityRowChrome` already styles its header `.subheadline` /
                // `.secondary` — the native cell's `.secondary` segment style.
                Text(phrasing.phrase)
                    .lineLimit(1)
                // Only a failure still earns a capsule; every other outcome is
                // already in the sentence.
                if let failure = phrasing.failureStatus {
                    Text(failure)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red.opacity(0.2))
                        .clipShape(Capsule())
                        .foregroundStyle(.red)
                }
            }
        }
        .accessibilityLabel(
            ActivityRowFormatter.taskNotificationAccessibilityLabel(
                text: text, timestamp: timestamp)
        )
    }

    private var reminderRow: some View {
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
