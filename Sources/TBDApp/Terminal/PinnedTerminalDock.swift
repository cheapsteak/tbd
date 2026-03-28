import SwiftUI
import TBDShared

/// A vertical dock showing pinned terminals from worktrees not currently visible.
/// Each pinned terminal gets a cell with a header (pin icon + worktree name) and the terminal view.
/// When multiple terminals are docked, draggable dividers between cells allow vertical resizing.
struct PinnedTerminalDock: View {
    let terminals: [Terminal]
    @EnvironmentObject var appState: AppState
    @State private var ratios: [CGFloat] = []

    var body: some View {
        let count = terminals.count
        let activeRatios = ratios.count == count ? ratios : Array(repeating: 1.0 / CGFloat(count), count: count)

        GeometryReader { geometry in
            let totalHeight = geometry.size.height
            let dividerThickness: CGFloat = 4
            let totalDividerSpace = dividerThickness * CGFloat(max(count - 1, 0))
            let available = max(totalHeight - totalDividerSpace, 0)

            VStack(spacing: 0) {
                ForEach(Array(terminals.enumerated()), id: \.element.id) { index, terminal in
                    PinnedTerminalCell(terminal: terminal)
                        .frame(height: activeRatios[index] * available)

                    if index < count - 1 {
                        DockCellDivider(
                            index: index,
                            ratios: Binding(
                                get: { activeRatios },
                                set: { ratios = $0 }
                            ),
                            availableSpace: available
                        )
                        .frame(height: dividerThickness)
                    }
                }
            }
        }
        .onChange(of: terminals.map(\.id)) { _, newIDs in
            let count = newIDs.count
            ratios = Array(repeating: 1.0 / CGFloat(count), count: count)
        }
    }
}

/// Draggable vertical divider between dock cells.
/// Uses deferred resize: shows indicator line during drag, commits on release.
private struct DockCellDivider: View {
    let index: Int
    @Binding var ratios: [CGFloat]
    let availableSpace: CGFloat

    @State private var dragStartRatios: [CGFloat] = []
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .contentShape(Rectangle())
            .cursor(.resizeUpDown)
            .overlay(alignment: .top) {
                if dragOffset != 0 {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(height: 2)
                        .offset(y: dragOffset)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartRatios.isEmpty {
                            dragStartRatios = ratios
                        }
                        guard availableSpace > 0 else { return }
                        let minRatio: CGFloat = 0.1
                        let maxDown = (dragStartRatios[index + 1] - minRatio) * availableSpace
                        let maxUp = -(dragStartRatios[index] - minRatio) * availableSpace
                        dragOffset = max(maxUp, min(maxDown, value.translation.height))
                    }
                    .onEnded { _ in
                        guard availableSpace > 0 else {
                            dragOffset = 0
                            dragStartRatios = []
                            return
                        }
                        let delta = dragOffset / availableSpace
                        var newRatios = dragStartRatios
                        newRatios[index] = dragStartRatios[index] + delta
                        newRatios[index + 1] = dragStartRatios[index + 1] - delta
                        ratios = newRatios
                        dragOffset = 0
                        dragStartRatios = []
                    }
            )
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
