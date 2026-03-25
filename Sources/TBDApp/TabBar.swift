import SwiftUI

// MARK: - TabBar

/// Generic tab bar that renders Tab items with type-appropriate icons and labels.
/// Replaces the former TerminalTabBar.
struct TabBar: View {
    let tabs: [Tab]
    @Binding var activeTabIndex: Int
    var onAddTab: () -> Void
    var onCloseTab: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    // Subtle vertical divider between tabs (iTerm2-style)
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1, height: 18)
                }

                TabBarItem(
                    tab: tab,
                    index: index,
                    isSelected: index == activeTabIndex,
                    onSelect: { activeTabIndex = index },
                    onClose: { onCloseTab(index) }
                )
            }

            // Divider before + button
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1, height: 18)

            Button(action: onAddTab) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Terminal Tab")

            Spacer()
        }
        .padding(.horizontal, 0)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - TabBarItem

private struct TabBarItem: View {
    let tab: Tab
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var isHoveringClose = false

    private var showClose: Bool {
        isSelected || isHovering
    }

    var body: some View {
        HStack(spacing: 0) {
            // Close button area — always takes space, visibility changes via opacity
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHoveringClose ? .primary : .secondary)
                    .frame(width: 16, height: 16)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isHoveringClose ? 0.12 : 0))
                    )
                    .onHover { hovering in
                        isHoveringClose = hovering
                    }
            }
            .buttonStyle(.plain)
            .opacity(showClose ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: showClose)

            // Type icon
            Image(systemName: tabIcon)
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? .primary : .tertiary)
                .frame(width: 14)
                .padding(.trailing, 3)

            Text(tabLabel)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity)

            // Invisible spacer matching close button width for centering
            Color.clear
                .frame(width: 16, height: 16)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(minWidth: 80, maxWidth: 180, minHeight: 28)
        .background(
            isSelected
                ? Color(nsColor: .controlBackgroundColor)
                : (isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            onSelect()
        }
        .contentShape(Rectangle())
    }

    private var tabIcon: String {
        switch tab.content {
        case .terminal: return "terminal"
        case .webview: return "globe"
        case .codeViewer: return "doc.text"
        }
    }

    private var tabLabel: String {
        if let label = tab.label, !label.isEmpty {
            return label
        }
        switch tab.content {
        case .terminal:
            return "Terminal \(index + 1)"
        case .webview(_, let url):
            return url.host ?? "Web"
        case .codeViewer(_, let path):
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }
}
