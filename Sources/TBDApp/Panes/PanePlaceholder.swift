import SwiftUI
import TBDShared

// MARK: - PanePlaceholder

/// Universal leaf wrapper that renders the appropriate pane content
/// based on PaneContent type. Replaces the former TerminalPanelPlaceholder.
struct PanePlaceholder: View {
    let content: PaneContent
    let worktree: Worktree
    @Binding var layout: LayoutNode
    @EnvironmentObject var appState: AppState

    /// Find the Terminal model matching a terminal ID across all worktree terminals.
    private func terminal(for id: UUID) -> Terminal? {
        for (_, terms) in appState.terminals {
            if let t = terms.first(where: { $0.id == id }) {
                return t
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar header
            toolbar

            Divider()

            // Pane content
            paneBody
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            paneLabel
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            toolbarActions

            Button(action: closePane) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help("Close pane")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var paneLabel: some View {
        switch content {
        case .terminal(let terminalID):
            Text("Terminal: \(terminalID.uuidString.prefix(8))")
        case .webview(_, let url):
            Text(url.host ?? url.absoluteString)
        case .codeViewer(_, let path):
            Text(URL(fileURLWithPath: path).lastPathComponent)
        }
    }

    @ViewBuilder
    private var toolbarActions: some View {
        switch content {
        case .terminal:
            Button(action: splitRight) {
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.split.1x2")
                        .rotationEffect(.degrees(90))
                    Text("Split Right")
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)

            Button(action: splitDown) {
                HStack(spacing: 2) {
                    Image(systemName: "rectangle.split.1x2")
                    Text("Split Down")
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)

        case .webview:
            // Placeholder for back/forward — will be wired in Task 6
            Button(action: {}) {
                Image(systemName: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(true)

            Button(action: {}) {
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(true)

        case .codeViewer:
            EmptyView()
        }
    }

    // MARK: - Pane Body

    @ViewBuilder
    private var paneBody: some View {
        switch content {
        case .terminal(let terminalID):
            terminalContent(terminalID: terminalID)
        case .webview(_, let url):
            WebviewPaneView(url: url)
        case .codeViewer(_, let path):
            CodeViewerPaneView(path: path, worktreePath: worktree.path)
        }
    }

    @ViewBuilder
    private func terminalContent(terminalID: UUID) -> some View {
        if let terminal = terminal(for: terminalID) {
            TerminalPanelView(
                terminalID: terminalID,
                tmuxServer: worktree.tmuxServer,
                tmuxWindowID: terminal.tmuxWindowID,
                tmuxBridge: appState.tmuxBridge,
                worktreePath: worktree.path,
                onFilePathClicked: { path in
                    let newContent = PaneContent.codeViewer(id: UUID(), path: path)
                    layout = layout.splitPane(id: terminalID, direction: .horizontal, newContent: newContent)
                }
            )
            .id(terminalID)
        } else {
            // Fallback when terminal data hasn't loaded yet
            ZStack {
                Color(nsColor: .black)

                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(worktree.displayName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(worktree.branch)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Close

    private func closePane() {
        if let newLayout = layout.removePane(id: content.paneID) {
            layout = newLayout
        } else {
            // Last pane in this tab — remove the entire tab
            let worktreeID = worktree.id
            if let tabIndex = appState.tabs[worktreeID]?.firstIndex(where: { $0.id == content.paneID || $0.content.paneID == content.paneID }) {
                appState.tabs[worktreeID]?.remove(at: tabIndex)
                appState.layouts.removeValue(forKey: content.paneID)
            }
        }
    }

    // MARK: - Split Actions

    private func splitRight() {
        Task {
            await createTerminalSplit(direction: .horizontal)
        }
    }

    private func splitDown() {
        Task {
            await createTerminalSplit(direction: .vertical)
        }
    }

    /// Creates a real terminal via the daemon, then inserts it as a split pane.
    /// Uses createTerminalForSplit so no extra tab is created — the terminal
    /// lives inside this tab's layout tree.
    private func createTerminalSplit(direction: SplitDirection) async {
        guard let newTerminal = await appState.createTerminalForSplit(worktreeID: worktree.id) else { return }
        layout = layout.splitPane(
            id: content.paneID,
            direction: direction,
            newContent: .terminal(terminalID: newTerminal.id)
        )
    }
}
