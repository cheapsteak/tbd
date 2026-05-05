import SwiftUI
import TBDShared

/// Shared chrome for non-bubble activity rows (tool calls, thinking, system).
/// Provides the full-bleed row layout, header (icon + title + timestamp),
/// expand/collapse toggle, and a truncation footer that lazily fetches the
/// un-truncated body via the daemon.
struct ActivityRowChrome<Header: View, BodyContent: View>: View {
    let icon: String
    let timestamp: Date?
    @Binding var expanded: Bool
    let headerContent: () -> Header
    let bodyContent: () -> BodyContent

    init(
        icon: String,
        timestamp: Date?,
        expanded: Binding<Bool>,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder body: @escaping () -> BodyContent
    ) {
        self.icon = icon
        self.timestamp = timestamp
        self._expanded = expanded
        self.headerContent = header
        self.bodyContent = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    headerContent()
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let ts = timestamp {
                        Text(ts.absoluteShort)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                bodyContent()
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
    }
}

/// Footer view for any body that may have been truncated. Shows the
/// "… N more chars · Show full output" affordance and, on tap, calls the
/// fetch closure provided by the parent. The parent caches the fetched
/// full content and re-renders.
struct TruncationFooter: View {
    let truncatedTo: Int
    let currentLength: Int
    let onShowFull: () -> Void

    var body: some View {
        Button(action: onShowFull) {
            HStack(spacing: 4) {
                Text("…")
                Text("\(truncatedTo - currentLength) more chars")
                Text("·").foregroundStyle(.quaternary)
                Text("Show full output").foregroundStyle(.tint)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}
