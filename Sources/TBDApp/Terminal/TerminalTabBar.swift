import SwiftUI
import TBDShared

// MARK: - TerminalTabBar

/// A horizontal tab bar showing labels for each terminal in the current worktree.
/// Styled to resemble a native macOS tab bar with subtle background and selected-tab highlighting.
struct TerminalTabBar: View {
    let terminals: [Terminal]
    @Binding var activeTabIndex: Int
    var onAddTab: () -> Void
    var onCloseTab: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(terminals.enumerated()), id: \.element.id) { index, terminal in
                TerminalTabItem(
                    terminal: terminal,
                    index: index,
                    isSelected: index == activeTabIndex,
                    onSelect: { activeTabIndex = index },
                    onClose: { onCloseTab(index) }
                )

                // Divider between tabs (not after the last one)
                if index < terminals.count - 1 {
                    Divider()
                        .frame(height: 16)
                        .opacity(0.4)
                }
            }

            // "+" button for new tab
            Button(action: onAddTab) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Terminal Tab")

            Spacer()
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - TerminalTabItem

/// A single tab in the terminal tab bar.
private struct TerminalTabItem: View {
    let terminal: Terminal
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(tabLabel)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            // Close button — visible on hover or when selected
            if isSelected || isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minWidth: 60, maxWidth: 160, minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected
                    ? Color(nsColor: .controlBackgroundColor)
                    : Color.clear)
                .shadow(color: isSelected ? .black.opacity(0.1) : .clear, radius: 1, y: 1)
        )
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
