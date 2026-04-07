import SwiftUI
import TBDShared

// MARK: - SplitLayoutView

struct SplitLayoutView: View {
    let node: LayoutNode
    let worktree: Worktree
    @Binding var layout: LayoutNode

    var body: some View {
        switch node {
        case .pane(let content):
            PanePlaceholder(
                content: content,
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
        case .pane:
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
/// Uses deferred resize: tracks drag offset for an indicator overlay, commits on release.
struct SplitDivider: View {
    let direction: SplitDirection
    let thickness: CGFloat
    let index: Int
    @Binding var ratios: [CGFloat]
    let availableSpace: CGFloat
    let onDragEnd: () -> Void

    @State private var dragStartRatios: [CGFloat] = []
    /// Pixel offset from the divider's resting position during drag.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .frame(
                width: direction == .horizontal ? thickness : nil,
                height: direction == .vertical ? thickness : nil
            )
            .contentShape(Rectangle())
            .cursor(direction == .horizontal ? .resizeLeftRight : .resizeUpDown)
            .overlay(alignment: direction == .horizontal ? .leading : .top) {
                if dragOffset != 0 {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(
                            width: direction == .horizontal ? 2 : nil,
                            height: direction == .vertical ? 2 : nil
                        )
                        .offset(
                            x: direction == .horizontal ? dragOffset : 0,
                            y: direction == .vertical ? dragOffset : 0
                        )
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

                        let translation: CGFloat = direction == .horizontal
                            ? value.translation.width
                            : value.translation.height

                        // Clamp the drag offset to respect min ratios
                        let minRatio: CGFloat = 0.1
                        let maxForward = (dragStartRatios[index + 1] - minRatio) * availableSpace
                        let maxBackward = -(dragStartRatios[index] - minRatio) * availableSpace
                        dragOffset = max(maxBackward, min(maxForward, translation))
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
                        onDragEnd()
                    }
            )
    }
}

// MARK: - Cursor helper

extension View {
    /// Overlays an AppKit cursor rect on the view. More reliable than `.onHover` +
    /// push/pop, which can miss events when a gesture is attached or leave the
    /// cursor stack unbalanced if the view disappears while hovered.
    func cursor(_ cursor: NSCursor) -> some View {
        self.overlay(CursorRectView(cursor: cursor).allowsHitTesting(false))
    }
}

/// NSViewRepresentable that installs an `addCursorRect` over its bounds so the
/// cursor changes whenever the pointer enters, regardless of SwiftUI gestures.
private struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorNSView {
        let view = CursorNSView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorNSView, context: Context) {
        nsView.cursor = cursor
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

final class CursorNSView: NSView {
    var cursor: NSCursor = .arrow

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override var isFlipped: Bool { true }

    // Don't intercept mouse events — let SwiftUI handle them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
