import SwiftUI
import TBDShared

/// Shared chrome for non-bubble activity rows (tool calls, thinking, system).
/// Provides the full-bleed row layout, header (icon + title + timestamp),
/// and a header-only click-to-overlay interaction (see #129 spec).
struct ActivityRowChrome<Header: View>: View {
    let icon: String
    let timestamp: Date?
    let onOpen: () -> Void
    let headerContent: () -> Header

    @State private var hovering = false

    init(
        icon: String,
        timestamp: Date?,
        onOpen: @escaping () -> Void,
        @ViewBuilder header: @escaping () -> Header
    ) {
        self.icon = icon
        self.timestamp = timestamp
        self.onOpen = onOpen
        self.headerContent = header
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                headerContent()
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let ts = timestamp {
                    Text(ts.absoluteShort)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "scope")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 0.8 : 0.0)
                    .animation(.easeInOut(duration: 0.12), value: hovering)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(hovering ? 0.65 : 0.4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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

/// Button that opens a file path in a new code-viewer split pane.
struct PreviewFileButton: View {
    let path: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "doc.text.magnifyingglass")
                Text("Preview file").foregroundStyle(.tint)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .help("Open \(path) in viewer")
    }
}
