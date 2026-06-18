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
        // Flattened (issue #129 per-row layout-depth): the inner HStack's greedy
        // `Spacer(minLength: 8)` already stretches the row to full width, so the
        // prior `.frame(maxWidth: .infinity, alignment: .leading)` was a redundant
        // _FlexFrameLayout (proven pixel-identical when removed). Dropping it
        // removes a flex-frame + its explicitAlignment recursion from every
        // tool/thinking/system row's measure pass. Padding pair → single EdgeInsets.
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
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

// MARK: - Preview

/// Exercises the ActivityRowChrome layout after the per-row flattening
/// (issue #129). Uses `PreviewProvider` (not the `#Preview` macro) so the
/// file still compiles under bare `swift build` — the SPM toolchain doesn't
/// ship the `PreviewsMacros` plugin that Xcode injects.
struct ActivityRowChrome_Previews: PreviewProvider {
    static let sampleTS = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static var previews: some View {
        VStack(spacing: 0) {
            ActivityRowChrome(
                icon: "hammer",
                timestamp: sampleTS,
                onOpen: {}
            ) {
                Text("Bash: swift build")
            }
            ActivityRowChrome(
                icon: "brain",
                timestamp: nil,
                onOpen: {}
            ) {
                Text("Thinking…")
            }
            ActivityRowChrome(
                icon: "info.circle",
                timestamp: sampleTS,
                onOpen: {}
            ) {
                Text("System: context window at 80 %")
            }
            ActivityRowChrome(
                icon: "doc.text",
                timestamp: nil,
                onOpen: {}
            ) {
                Text("Read: Sources/TBDApp/Panes/Transcript/ChatBubbleView.swift")
            }
        }
        .frame(width: 560)
    }
}
