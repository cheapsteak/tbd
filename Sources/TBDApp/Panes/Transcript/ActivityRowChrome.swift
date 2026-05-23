import SwiftUI
import TBDShared

/// Shared chrome for non-bubble activity rows (tool calls, thinking, system).
/// Provides the full-bleed row layout, header (icon + title + timestamp),
/// expand/collapse toggle (legacy path), and a header-only click-to-overlay
/// path used by migrated cards (see #129 spec and Task 20 of the plan).
struct ActivityRowChrome<Header: View, BodyContent: View>: View {
    /// Two render modes during migration: the legacy chevron-driven
    /// expand/collapse path, and the new header-only click-to-overlay
    /// path. Cards migrate one at a time; the legacy mode is deleted
    /// once no callers remain (see #129 spec and Task 20 of the plan).
    enum Mode {
        case legacy(expanded: Binding<Bool>, body: () -> BodyContent)
        case overlay(onOpen: () -> Void)
    }

    let icon: String
    let timestamp: Date?
    let headerContent: () -> Header
    let mode: Mode

    @State private var hovering = false

    /// Legacy init — preserves chevron + expand/collapse semantics.
    /// New code MUST NOT use this; migrate callers to the `onOpen:`
    /// init below. Tracked for removal in #129.
    init(
        icon: String,
        timestamp: Date?,
        expanded: Binding<Bool>,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder body: @escaping () -> BodyContent
    ) {
        self.icon = icon
        self.timestamp = timestamp
        self.headerContent = header
        self.mode = .legacy(expanded: expanded, body: body)
    }

    /// New init — header-only row with hover-reveal `⌖` glyph and
    /// click-to-overlay. Used by every migrated card after #129.
    init(
        icon: String,
        timestamp: Date?,
        onOpen: @escaping () -> Void,
        @ViewBuilder header: @escaping () -> Header
    ) where BodyContent == EmptyView {
        self.icon = icon
        self.timestamp = timestamp
        self.headerContent = header
        self.mode = .overlay(onOpen: onOpen)
    }

    var body: some View {
        switch mode {
        case .legacy(let expanded, let bodyClosure):
            legacyBody(expanded: expanded, content: bodyClosure)
        case .overlay(let onOpen):
            overlayBody(onOpen: onOpen)
        }
    }

    @ViewBuilder
    private func legacyBody(
        expanded: Binding<Bool>,
        content: @escaping () -> BodyContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { expanded.wrappedValue.toggle() }) {
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
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded.wrappedValue {
                content()
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
    }

    @ViewBuilder
    private func overlayBody(onOpen: @escaping () -> Void) -> some View {
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
