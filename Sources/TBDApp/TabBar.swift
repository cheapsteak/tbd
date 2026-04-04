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
    var onForkTab: (UUID) -> Void = { _ in }

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
                    onResume: { onResumeTab(tab.id) },
                    onFork: { onForkTab(tab.id) }
                )
            }

            // Divider before + button
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1, height: 18)

            AddTabButton(
                onAddShell: onAddShell,
                onAddClaude: onAddClaude,
                onAddNote: onAddNote
            )
            Spacer()
        }
        .padding(.horizontal, 0)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - AddTabButton

/// Plain Button that shows an NSMenu on click. SwiftUI's Menu + borderlessButton
/// swallows hover events, making custom hover styling impossible. Using NSMenu
/// directly sidesteps this entirely.
private struct AddTabButton: View {
    let onAddShell: () -> Void
    let onAddClaude: () -> Void
    let onAddNote: () -> Void
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "plus")
            .font(.caption)
            .foregroundStyle(isHovering ? .primary : .secondary)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .padding(6)
            .contentShape(Rectangle())
            .onHover { hovering in isHovering = hovering }
            .onTapGesture { showMenu() }
            .help("New Tab")
    }

    private func showMenu() {
        let menu = NSMenu()

        let shellItem = NSMenuItem(title: "Shell", action: nil, keyEquivalent: "")
        shellItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        menu.addItem(shellItem)

        let claudeItem = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
        claudeItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(claudeItem)

        menu.addItem(.separator())

        let noteItem = NSMenuItem(title: "Note", action: nil, keyEquivalent: "")
        noteItem.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        menu.addItem(noteItem)

        // Use a coordinator to handle menu item actions via closures
        let coordinator = MenuCoordinator(
            onShell: onAddShell, onClaude: onAddClaude, onNote: onAddNote
        )
        shellItem.target = coordinator
        shellItem.action = #selector(MenuCoordinator.addShell)
        claudeItem.target = coordinator
        claudeItem.action = #selector(MenuCoordinator.addClaude)
        noteItem.target = coordinator
        noteItem.action = #selector(MenuCoordinator.addNote)

        // Keep coordinator alive for the duration of the menu
        objc_setAssociatedObject(menu, "coordinator", coordinator, .OBJC_ASSOCIATION_RETAIN)

        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: location, in: nil)
    }

}

private class MenuCoordinator: NSObject {
    let onShell: () -> Void
    let onClaude: () -> Void
    let onNote: () -> Void

    init(onShell: @escaping () -> Void, onClaude: @escaping () -> Void, onNote: @escaping () -> Void) {
        self.onShell = onShell
        self.onClaude = onClaude
        self.onNote = onNote
    }

    @objc func addShell() { onShell() }
    @objc func addClaude() { onClaude() }
    @objc func addNote() { onNote() }
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
    let onFork: () -> Void

    @State private var isHovering = false
    @State private var isHoveringClose = false
    @AppStorage("codeViewer.showSidebar") private var showSidebar = false

    private var showClose: Bool {
        isSelected || isHovering
    }

    private var isCodeViewer: Bool {
        if case .codeViewer = tab.content { return true }
        return false
    }

    private var isClaudeTerminal: Bool {
        terminal?.claudeSessionID != nil
    }

    private var isSuspended: Bool {
        terminal?.suspendedAt != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            // Clickable tab content area
            Button(action: onSelect) {
                HStack(spacing: 0) {
                    // Sidebar toggle for code viewer tabs
                    if isCodeViewer {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 10))
                            .foregroundStyle(showSidebar ? .primary : .tertiary)
                            .frame(width: 16, height: 16)
                            .padding(.trailing, 2)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showSidebar.toggle()
                                }
                            }
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
                        .fixedSize()
                        .foregroundStyle(isSuspended ? .tertiary : (isSelected ? .primary : .secondary))
                }
            }
            .buttonStyle(.plain)

            // Close button — right side
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isHoveringClose ? .primary : .secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(isHoveringClose ? 0.08 : 0))
                    )
                    .onHover { hovering in
                        isHoveringClose = hovering
                    }
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
            .padding(.trailing, 2)
            .opacity(showClose ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: showClose)
        }
        .padding(.leading, 8)
        .frame(minHeight: 28)
        .background(
            isSelected
                ? Color(nsColor: .controlBackgroundColor)
                : (isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .contextMenu { contextMenuContent }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if isClaudeTerminal {
            Button(action: onFork) {
                Label("Fork Session", systemImage: "arrow.triangle.branch")
            }

            Button(action: isSuspended ? onResume : onSuspend) {
                Label(
                    isSuspended ? "Resume Claude" : "Suspend Claude",
                    systemImage: isSuspended ? "play.circle" : "pause.circle"
                )
            }

            Divider()
        }

        Button(action: onClose) {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    private var tabIcon: String {
        switch tab.content {
        case .terminal:
            if isSuspended { return "moon.zzz" }
            return isClaudeTerminal ? "sparkles" : "terminal"
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

