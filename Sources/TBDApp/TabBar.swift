import SwiftUI
import TBDShared

// MARK: - TabBar

/// Generic tab bar that renders Tab items with type-appropriate icons and labels.
/// Replaces the former TerminalTabBar.
struct TabBar: View {
    let tabs: [Tab]
    @Binding var activeTabIndex: Int
    var onAddShell: () -> Void = {}
    var onAddClaude: () -> Void = {}
    var onAddNote: () -> Void = {}
    var onCloseTab: (Int) -> Void
    var terminalForTab: (UUID) -> Terminal? = { _ in nil }
    var onSuspendTab: (UUID) -> Void = { _ in }
    var onResumeTab: (UUID) -> Void = { _ in }

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
                    terminal: terminalForTab(tab.id),
                    onSelect: { activeTabIndex = index },
                    onClose: { onCloseTab(index) },
                    onSuspend: { onSuspendTab(tab.id) },
                    onResume: { onResumeTab(tab.id) }
                )
            }

            // Divider before + button
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1, height: 18)

            Menu {
                Button(action: onAddShell) {
                    Label("Shell", systemImage: "terminal")
                }
                Button(action: onAddClaude) {
                    Label("Claude", systemImage: "sparkle")
                }
                Divider()
                Button(action: onAddNote) {
                    Label("Note", systemImage: "note.text")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 34, height: 28)
            .help("New Tab")

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
    let terminal: Terminal?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onSuspend: () -> Void
    let onResume: () -> Void

    @State private var isHovering = false
    @State private var isHoveringClose = false
    @State private var isHoveringSuspend = false
    @AppStorage("codeViewer.showSidebar") private var showSidebar = false

    private var showClose: Bool {
        isSelected || isHovering
    }

    private var isCodeViewer: Bool {
        if case .codeViewer = tab.content { return true }
        return false
    }

    private var isClaudeTerminal: Bool {
        guard let terminal else { return false }
        return terminal.label?.hasPrefix("claude") == true
    }

    private var isSuspended: Bool {
        terminal?.suspendedAt != nil
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

            // Sidebar toggle for code viewer tabs
            if isCodeViewer {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSidebar.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 10))
                        .foregroundStyle(showSidebar ? .primary : .tertiary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Toggle file tree")
                .padding(.trailing, 2)
            }

            // Suspend/resume button for Claude terminals
            if isClaudeTerminal {
                Button(action: isSuspended ? onResume : onSuspend) {
                    Image(systemName: isSuspended ? "play.circle" : "pause.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(isHoveringSuspend ? .primary : .secondary)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(isHoveringSuspend ? 0.12 : 0))
                        )
                        .onHover { hovering in
                            isHoveringSuspend = hovering
                        }
                }
                .buttonStyle(.plain)
                .opacity((isSuspended || showClose) ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: isSuspended || showClose)
                .help(isSuspended ? "Resume Claude" : "Suspend Claude")
                .padding(.trailing, 2)
            }

            // Type icon
            Image(systemName: tabIcon)
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? .primary : .tertiary)
                .frame(width: 14)
                .padding(.trailing, 3)

            Text(tabLabel)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(isSuspended ? .tertiary : (isSelected ? .primary : .secondary))
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
        case .terminal:
            return isSuspended ? "moon.zzz" : "terminal"
        case .webview: return "globe"
        case .codeViewer: return "doc.text"
        case .note: return "note.text"
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
        case .note:
            return "Note \(index + 1)"
        }
    }
}
