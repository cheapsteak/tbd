import SwiftUI
import TBDShared

// MARK: - SplitLayoutView

struct SplitLayoutView: View {
    let node: LayoutNode
    let worktree: Worktree
    @Binding var layout: LayoutNode

    var body: some View {
        switch node {
        case .terminal(let id):
            TerminalPanelPlaceholder(
                terminalID: id,
                worktree: worktree,
                layout: $layout
            )
        case .split(let direction, let children, let ratios):
            SplitContainer(
                direction: direction,
                children: children,
                ratios: ratios,
                worktree: worktree,
                layout: $layout
            )
        }
    }
}

// MARK: - SplitContainer

/// Divides space according to ratios using GeometryReader.
/// Renders each child recursively with a 4px draggable divider between them.
struct SplitContainer: View {
    let direction: SplitDirection
    let children: [LayoutNode]
    let ratios: [CGFloat]
    let worktree: Worktree
    @Binding var layout: LayoutNode

    /// Local mutable copy of ratios used during drag operations.
    @State private var currentRatios: [CGFloat] = []

    var body: some View {
        GeometryReader { geometry in
            let totalSize = direction == .horizontal
                ? geometry.size.width
                : geometry.size.height
            let dividerThickness: CGFloat = 4
            let totalDividerSpace = dividerThickness * CGFloat(children.count - 1)
            let availableSpace = max(totalSize - totalDividerSpace, 0)

            let activeRatios = currentRatios.isEmpty ? ratios : currentRatios

            buildLayout(
                activeRatios: activeRatios,
                availableSpace: availableSpace,
                dividerThickness: dividerThickness
            )
        }
        .onAppear {
            currentRatios = ratios
        }
        .onChange(of: ratios) { _, newRatios in
            currentRatios = newRatios
        }
    }

    @ViewBuilder
    private func buildLayout(
        activeRatios: [CGFloat],
        availableSpace: CGFloat,
        dividerThickness: CGFloat
    ) -> some View {
        let isHorizontal = direction == .horizontal

        if isHorizontal {
            HStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    SplitLayoutView(
                        node: child,
                        worktree: worktree,
                        layout: $layout
                    )
                    .frame(width: activeRatios[index] * availableSpace)

                    if index < children.count - 1 {
                        SplitDivider(
                            direction: direction,
                            thickness: dividerThickness,
                            index: index,
                            ratios: $currentRatios,
                            availableSpace: availableSpace,
                            onDragEnd: { commitRatios() }
                        )
                    }
                }
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    SplitLayoutView(
                        node: child,
                        worktree: worktree,
                        layout: $layout
                    )
                    .frame(height: activeRatios[index] * availableSpace)

                    if index < children.count - 1 {
                        SplitDivider(
                            direction: direction,
                            thickness: dividerThickness,
                            index: index,
                            ratios: $currentRatios,
                            availableSpace: availableSpace,
                            onDragEnd: { commitRatios() }
                        )
                    }
                }
            }
        }
    }

    /// Write back current ratios into the layout binding.
    private func commitRatios() {
        layout = updateRatios(in: layout, for: children, newRatios: currentRatios)
    }

    /// Recursively find the matching split node and update its ratios.
    private func updateRatios(
        in node: LayoutNode,
        for targetChildren: [LayoutNode],
        newRatios: [CGFloat]
    ) -> LayoutNode {
        switch node {
        case .terminal:
            return node
        case .split(let dir, let nodeChildren, let nodeRatios):
            if nodeChildren == targetChildren {
                return .split(direction: dir, children: nodeChildren, ratios: newRatios)
            }
            let updatedChildren = nodeChildren.map { child in
                updateRatios(in: child, for: targetChildren, newRatios: newRatios)
            }
            return .split(direction: dir, children: updatedChildren, ratios: nodeRatios)
        }
    }
}

// MARK: - SplitDivider

/// A draggable divider between split children.
struct SplitDivider: View {
    let direction: SplitDirection
    let thickness: CGFloat
    let index: Int
    @Binding var ratios: [CGFloat]
    let availableSpace: CGFloat
    let onDragEnd: () -> Void

    @State private var dragStartRatios: [CGFloat] = []

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .frame(
                width: direction == .horizontal ? thickness : nil,
                height: direction == .vertical ? thickness : nil
            )
            .contentShape(Rectangle())
            .cursor(direction == .horizontal ? .resizeLeftRight : .resizeUpDown)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartRatios.isEmpty {
                            dragStartRatios = ratios
                        }
                        guard availableSpace > 0 else { return }

                        let delta: CGFloat
                        if direction == .horizontal {
                            delta = value.translation.width / availableSpace
                        } else {
                            delta = value.translation.height / availableSpace
                        }

                        var newRatios = dragStartRatios
                        let minRatio: CGFloat = 0.1

                        newRatios[index] = dragStartRatios[index] + delta
                        newRatios[index + 1] = dragStartRatios[index + 1] - delta

                        // Clamp both ratios
                        if newRatios[index] < minRatio {
                            let correction = minRatio - newRatios[index]
                            newRatios[index] = minRatio
                            newRatios[index + 1] -= correction
                        }
                        if newRatios[index + 1] < minRatio {
                            let correction = minRatio - newRatios[index + 1]
                            newRatios[index + 1] = minRatio
                            newRatios[index] -= correction
                        }

                        ratios = newRatios
                    }
                    .onEnded { _ in
                        dragStartRatios = []
                        onDragEnd()
                    }
            )
    }
}

// MARK: - Cursor helper

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - TerminalPanelPlaceholder

/// Terminal panel with split buttons toolbar and real SwiftTerm terminal view.
/// Looks up the Terminal object from AppState to get tmux server and pane ID.
struct TerminalPanelPlaceholder: View {
    let terminalID: UUID
    let worktree: Worktree
    @Binding var layout: LayoutNode
    @EnvironmentObject var appState: AppState

    /// Find the Terminal model matching this terminalID across all worktree terminals.
    private var terminal: Terminal? {
        for (_, terms) in appState.terminals {
            if let t = terms.first(where: { $0.id == terminalID }) {
                return t
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mini toolbar with split buttons
            HStack(spacing: 8) {
                Text("Terminal: \(terminalID.uuidString.prefix(8))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

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
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Real terminal view or fallback placeholder
            if let terminal = terminal {
                TerminalPanelView(
                    terminalID: terminalID,
                    tmuxServer: worktree.tmuxServer,
                    tmuxPaneID: terminal.tmuxPaneID,
                    tmuxBridge: appState.tmuxBridge
                )
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
    }

    private func splitRight() {
        let newID = UUID()
        layout = layout.splitTerminal(
            id: terminalID,
            direction: .horizontal,
            newTerminalID: newID
        )
    }

    private func splitDown() {
        let newID = UUID()
        layout = layout.splitTerminal(
            id: terminalID,
            direction: .vertical,
            newTerminalID: newID
        )
    }
}
