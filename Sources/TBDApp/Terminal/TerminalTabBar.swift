import SwiftUI
import TBDShared

// MARK: - TerminalTabBar

struct TerminalTabBar: View {
    let terminals: [Terminal]
    @Binding var activeTabIndex: Int
    var onAddTab: () -> Void
    var onCloseTab: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(terminals.enumerated()), id: \.element.id) { index, terminal in
                if index > 0 {
                    // Subtle vertical divider between tabs (iTerm2-style)
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1, height: 18)
                }

                TerminalTabItem(
                    terminal: terminal,
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

// MARK: - TerminalTabItem

private struct TerminalTabItem: View {
    let terminal: Terminal
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

    private var tabLabel: String {
        if let label = terminal.label, !label.isEmpty {
            return label
        }
        return "Terminal \(index + 1)"
    }
}
