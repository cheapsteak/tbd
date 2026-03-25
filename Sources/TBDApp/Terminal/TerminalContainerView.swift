import SwiftUI
import TBDShared

// MARK: - TerminalContainerView

/// Manages the terminal area for the selected worktree(s).
///
/// - Single worktree selected: Shows TerminalTabBar at top + SplitLayoutView below
///   for the active tab's layout.
/// - Multi-select (Cmd-click): Auto-grid layout, one panel per selected worktree
///   showing its primary terminal. No tab bar.
struct TerminalContainerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.selectedWorktreeIDs.count == 1,
           let worktreeID = appState.selectedWorktreeIDs.first {
            SingleWorktreeView(worktreeID: worktreeID)
        } else if appState.selectedWorktreeIDs.count > 1 {
            MultiWorktreeView(worktreeIDs: Array(appState.selectedWorktreeIDs))
        } else {
            Text("Select a worktree or click + to create one")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - SingleWorktreeView

/// Shows the tab bar and split layout for a single selected worktree.
private struct SingleWorktreeView: View {
    let worktreeID: UUID
    @EnvironmentObject var appState: AppState
    @State private var activeTabIndex: Int = 0

    private var worktree: Worktree? {
        for wts in appState.worktrees.values {
            if let wt = wts.first(where: { $0.id == worktreeID }) {
                return wt
            }
        }
        return nil
    }

    private var terminals: [Terminal] {
        appState.terminals[worktreeID] ?? []
    }

    var body: some View {
        if let worktree {
            VStack(spacing: 0) {
                // Tab bar
                if !terminals.isEmpty {
                    TerminalTabBar(
                        terminals: terminals,
                        activeTabIndex: $activeTabIndex,
                        onAddTab: {
                            Task {
                                await appState.createTerminal(worktreeID: worktreeID)
                                // Select the newly added tab
                                let newCount = appState.terminals[worktreeID]?.count ?? 0
                                if newCount > 0 {
                                    activeTabIndex = newCount - 1
                                }
                            }
                        },
                        onCloseTab: { index in
                            closeTab(at: index)
                        }
                    )

                    Divider()
                }

                // Split layout view for the active tab's layout
                layoutContent(worktree: worktree)
            }
            // TmuxBridge sessions are created on-demand by TerminalPanelView
            .task(id: worktreeID) {
                // Auto-create a terminal when selecting a main worktree with none
                if worktree.status == .main && terminals.isEmpty {
                    await appState.createTerminal(worktreeID: worktreeID)
                }
            }
        } else {
            Text("Worktree not found")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func layoutContent(worktree: Worktree) -> some View {
        if let terminal = activeTerminal {
            // Each tab shows one terminal (with optional splits stored per-terminal)
            let layoutKey = terminal.id
            let layoutBinding = Binding<LayoutNode>(
                get: {
                    appState.layouts[layoutKey] ?? .pane(.terminal(terminalID: terminal.id))
                },
                set: { newLayout in
                    appState.layouts[layoutKey] = newLayout
                }
            )

            SplitLayoutView(
                node: layoutBinding.wrappedValue,
                worktree: worktree,
                layout: layoutBinding
            )
            .id(terminal.id) // Force new view hierarchy when switching tabs
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No terminals")
                    .foregroundStyle(.secondary)
                Button("Create Terminal") {
                    Task {
                        await appState.createTerminal(worktreeID: worktreeID)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var activeTerminal: Terminal? {
        let terms = terminals
        guard !terms.isEmpty else { return nil }
        let clampedIndex = min(activeTabIndex, terms.count - 1)
        return terms[clampedIndex]
    }

    private func closeTab(at index: Int) {
        let terms = terminals
        guard index >= 0, index < terms.count else { return }
        let terminal = terms[index]

        // Remove terminal from layout
        if let currentLayout = appState.layouts[worktreeID] {
            if let newLayout = currentLayout.removePane(id: terminal.id) {
                appState.layouts[worktreeID] = newLayout
            } else {
                appState.layouts.removeValue(forKey: worktreeID)
            }
        }

        // Remove from terminals list
        appState.terminals[worktreeID]?.removeAll { $0.id == terminal.id }

        // Adjust active tab index
        let remaining = appState.terminals[worktreeID]?.count ?? 0
        if remaining > 0 {
            activeTabIndex = min(activeTabIndex, remaining - 1)
        } else {
            activeTabIndex = 0
        }
    }
}

// MARK: - MultiWorktreeView

/// Auto-grid layout showing one panel per selected worktree.
/// Each panel displays the worktree name and its primary terminal.
private struct MultiWorktreeView: View {
    let worktreeIDs: [UUID]
    @EnvironmentObject var appState: AppState

    private var columns: Int {
        let count = worktreeIDs.count
        if count <= 1 { return 1 }
        if count <= 4 { return 2 }
        if count <= 9 { return 3 }
        return 4
    }

    var body: some View {
        GeometryReader { geometry in
            let cols = columns
            let rows = Int(ceil(Double(worktreeIDs.count) / Double(cols)))
            let cellWidth = geometry.size.width / CGFloat(cols)
            let cellHeight = geometry.size.height / CGFloat(rows)

            VStack(spacing: 1) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(0..<cols, id: \.self) { col in
                            let index = row * cols + col
                            if index < worktreeIDs.count {
                                MultiWorktreeCell(
                                    worktreeID: worktreeIDs[index]
                                )
                                .frame(width: cellWidth - 1, height: cellHeight - 1)
                            } else {
                                Color.clear
                                    .frame(width: cellWidth - 1, height: cellHeight - 1)
                            }
                        }
                    }
                }
            }
            .background(Color(nsColor: .separatorColor))
        }
    }
}

// MARK: - MultiWorktreeCell

/// A single cell in the multi-worktree grid showing worktree name and its primary terminal.
private struct MultiWorktreeCell: View {
    let worktreeID: UUID
    @EnvironmentObject var appState: AppState

    private var worktree: Worktree? {
        for wts in appState.worktrees.values {
            if let wt = wts.first(where: { $0.id == worktreeID }) {
                return wt
            }
        }
        return nil
    }

    private var primaryTerminal: Terminal? {
        appState.terminals[worktreeID]?.first
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with worktree name
            HStack {
                if let worktree {
                    Text(worktree.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(worktree.branch)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Terminal placeholder content
            if let worktree, let terminal = primaryTerminal {
                let layoutBinding = Binding<LayoutNode>(
                    get: {
                        appState.layouts[worktreeID]
                            ?? .pane(.terminal(terminalID: terminal.id))
                    },
                    set: { newLayout in
                        appState.layouts[worktreeID] = newLayout
                    }
                )
                PanePlaceholder(
                    content: .terminal(terminalID: terminal.id),
                    worktree: worktree,
                    layout: layoutBinding
                )
            } else {
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    VStack(spacing: 4) {
                        Image(systemName: "terminal")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("No terminal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
