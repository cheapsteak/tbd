import SwiftUI
import TBDShared

/// A vertical dock showing pinned terminals from worktrees not currently visible.
/// Each pinned terminal gets a cell with a header (pin icon + worktree name) and the terminal view.
struct PinnedTerminalDock: View {
    let terminals: [Terminal]
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 1) {
            ForEach(terminals) { terminal in
                PinnedTerminalCell(terminal: terminal)
            }
        }
        .background(Color(nsColor: .separatorColor))
    }
}

/// A single cell in the pinned terminal dock.
private struct PinnedTerminalCell: View {
    let terminal: Terminal
    @EnvironmentObject var appState: AppState

    private var worktree: Worktree? {
        for wts in appState.worktrees.values {
            if let wt = wts.first(where: { $0.id == terminal.worktreeID }) {
                return wt
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: pin icon + worktree name
            HStack(spacing: 4) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                    .onTapGesture {
                        Task { await appState.setTerminalPin(id: terminal.id, pinned: false) }
                    }
                if let worktree {
                    Text(worktree.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Terminal content
            if let worktree {
                TerminalPanelView(
                    terminalID: terminal.id,
                    tmuxServer: worktree.tmuxServer,
                    tmuxWindowID: terminal.tmuxWindowID,
                    tmuxBridge: appState.tmuxBridge,
                    worktreePath: worktree.path
                )
                .id(terminal.id)
            } else {
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
