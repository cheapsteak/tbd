import SwiftUI
import TBDShared
import os

/// Phase 3b (`docs/specs/2026-07-31-panel-3b-app-rendering-design.md`) — the
/// workspace renderer for the daemon-owned panel surface.
///
/// This is the half of the dual path that the legacy `SplitLayoutView` cannot
/// be: it walks a `PanelLayoutNode`, which has a `.primary` anchor the legacy
/// homogeneous pane tree has no concept of. What it does NOT do is rebuild a
/// `LayoutNode` — the leaf-content mapping below is content-only, and that is
/// exactly what separates this from the rejected adapter bridge (spec
/// §Approach B): the tree renderer and the source of truth stay separate per
/// path, and no `@Binding` races the daemon.
private let logger = Logger(subsystem: "com.tbd.app", category: "panelSurface")

// MARK: - Render-path selection

/// Which renderer the workspace root uses for one tab. Extracted from the
/// view so both branches are assertable without touching SwiftUI internals.
enum WorkspaceRenderPath: Equatable {
    /// Today's `SplitLayoutView` over the app-side `LayoutNode` tree.
    case legacy
    /// `PanelSurfaceWorkspaceView` over this mirrored daemon surface.
    case daemonSurface(WorkspaceTabSurface)
}

extension AppState {
    /// The render path for one worktree tab.
    ///
    /// Two conditions, both required. `daemonManagedPanelsActive` is the
    /// user flag AND the daemon's store flag. The mirror lookup is the
    /// second: the mirror starts EMPTY and fills asynchronously from
    /// `panel.get`, so a flag-on tab with nothing loaded yet must fall
    /// through to legacy rather than render blank.
    func workspaceRenderPath(worktreeID: UUID, tabID: WorkspaceTabID) -> WorkspaceRenderPath {
        guard daemonManagedPanelsActive,
              let surface = panelSurfaceTab(worktreeID: worktreeID, tabID: tabID)
        else { return .legacy }
        return .daemonSurface(surface)
    }
}

/// `.task(id:)` key for the mirror's initial load. A struct rather than an
/// interpolated string so adding a dimension is a compile error at the call
/// site instead of a silently unchanged key.
struct PanelSurfaceLoadKey: Equatable {
    let worktreeID: UUID
    let active: Bool
    let connected: Bool
}

// MARK: - Leaf content mapping

/// Content-only bridges from the new model's leaf content to the legacy
/// `PaneContent` the shared leaf view (`PanePlaceholder`) renders.
///
/// Total in the direction that matters: `PanelContent` is a strict subset of
/// `PaneContent` (Spec C §5.5 — no terminal case in a viewer panel), and
/// `PrimaryContent` adds only the terminal case, which `PaneContent` has.
///
/// **Never use these to reconstruct a `LayoutNode` tree.** They exist so one
/// leaf view can render on top of either source of truth; flattening the
/// primary/viewer distinction back into a homogeneous tree is the rejected
/// adapter bridge.
enum PanelSurfaceLeaf {

    /// A viewer panel's content as the leaf view understands it. The panel's
    /// own `PanelID` supplies the legacy pane identity for the content cases
    /// that carry one.
    static func paneContent(for content: PanelContent, panelID: PanelID) -> PaneContent {
        switch content {
        case .file(let reference):
            return .codeViewer(id: panelID, path: reference.path)
        case .web(let url):
            return .webview(id: panelID, url: url)
        case .transcript(let terminalID):
            return .liveTranscript(id: panelID, terminalID: terminalID)
        case .note(let noteID):
            return .note(noteID: noteID)
        }
    }

    /// The primary anchor's content as the leaf view understands it. The
    /// anchor has no `PanelID` — there is exactly one per tab — so the tab's
    /// own ID stands in as the legacy pane identity where one is needed.
    static func paneContent(for content: PrimaryContent, primaryID: UUID) -> PaneContent {
        switch content {
        case .terminal(let terminalID):
            return .terminal(terminalID: terminalID)
        case .note(let noteID):
            return .note(noteID: noteID)
        case .file(let reference):
            return .codeViewer(id: primaryID, path: reference.path)
        case .web(let url):
            return .webview(id: primaryID, url: url)
        case .transcript(let terminalID):
            return .liveTranscript(id: primaryID, terminalID: terminalID)
        }
    }

    /// The reverse, for the one gesture that names its own content: the
    /// leaf's "open this file beside me". Partial by design — a terminal can
    /// never be a viewer panel (§5.5), and nothing in the app asks to open
    /// one this way.
    static func panelContent(for content: PaneContent) -> PanelContent? {
        switch content {
        case .terminal:
            return nil
        case .webview(_, let url):
            return .web(url)
        case .codeViewer(_, let path):
            return .file(FileReference(path: path))
        case .note(let noteID):
            return .note(noteID: noteID)
        case .liveTranscript(_, let terminalID):
            return .transcript(terminalID: terminalID)
        }
    }
}

// MARK: - Tree renderer

/// Renders one `WorkspaceTabSurface` from the mirror.
struct PanelSurfaceWorkspaceView: View {
    let surface: WorkspaceTabSurface
    let worktree: Worktree

    var body: some View {
        PanelSurfaceNodeView(node: surface.layout, surface: surface, worktree: worktree)
    }
}

/// One node of the panel tree: the primary anchor, a viewer panel, or a
/// split. Mirrors `SplitLayoutView`'s shape over the new model.
private struct PanelSurfaceNodeView: View {
    let node: PanelLayoutNode
    let surface: WorkspaceTabSurface
    let worktree: Worktree
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch node {
        case .primary:
            PanePlaceholder(
                content: PanelSurfaceLeaf.paneContent(
                    for: surface.primary, primaryID: surface.id),
                worktree: worktree,
                tabID: surface.id,
                actions: actions(anchor: .primary)
            )
        case .panel(let slot):
            PanePlaceholder(
                content: PanelSurfaceLeaf.paneContent(for: slot.content, panelID: slot.id),
                worktree: worktree,
                tabID: surface.id,
                actions: actions(anchor: .panel(slot.id))
            )
        case .split(let split):
            PanelSurfaceSplitContainer(
                split: split, surface: surface, worktree: worktree,
                // Resize is the one gesture that names a split rather than a
                // leaf, so the anchor it is built with is irrelevant.
                resize: actions(anchor: .primary).resize
            )
        }
    }

    private func actions(anchor: PanelAnchor) -> PaneActions {
        .daemonManaged(
            appState: appState,
            worktreeID: surface.worktreeID,
            tabID: surface.id,
            anchor: anchor
        )
    }
}

/// Divides space among a `SplitNode`'s children, reusing the existing
/// `SplitDivider` verbatim — the unified divider / native resize indicator is
/// a separate follow-up and deliberately not attempted here.
///
/// Ratios are `Double` in the new model and `CGFloat` in the divider; the
/// local drag copy is the conversion boundary, and the commit on release
/// converts back.
private struct PanelSurfaceSplitContainer: View {
    let split: SplitNode
    let surface: WorkspaceTabSurface
    let worktree: Worktree
    let resize: @MainActor (UUID, [CGFloat]) -> Void

    /// Local mutable copy of ratios used during drag operations. Nothing
    /// reaches the daemon until release (spec §Ownership: no per-frame RPC).
    @State private var currentRatios: [CGFloat] = []

    /// The node's ratios, widened to the divider's `CGFloat`. Falls back to
    /// equal shares on a count mismatch: the daemon's validator forbids that
    /// state, but indexing out of range here would take the whole workspace
    /// down rather than render one split oddly.
    private var modelRatios: [CGFloat] {
        guard !split.children.isEmpty else { return [] }
        guard split.ratios.count == split.children.count else {
            return Array(repeating: 1 / CGFloat(split.children.count), count: split.children.count)
        }
        return split.ratios.map { CGFloat($0) }
    }

    var body: some View {
        GeometryReader { geometry in
            let totalSize = split.direction == .horizontal
                ? geometry.size.width
                : geometry.size.height
            let dividerThickness: CGFloat = 4
            let totalDividerSpace = dividerThickness * CGFloat(max(split.children.count - 1, 0))
            let availableSpace = max(totalSize - totalDividerSpace, 0)

            let activeRatios = currentRatios.count == split.children.count
                ? currentRatios
                : modelRatios

            buildLayout(
                activeRatios: activeRatios,
                availableSpace: availableSpace,
                dividerThickness: dividerThickness
            )
        }
        .onAppear {
            currentRatios = modelRatios
        }
        .onChange(of: split.ratios) { _, _ in
            currentRatios = modelRatios
        }
    }

    @ViewBuilder
    private func buildLayout(
        activeRatios: [CGFloat],
        availableSpace: CGFloat,
        dividerThickness: CGFloat
    ) -> some View {
        if split.direction == .horizontal {
            HStack(spacing: 0) {
                ForEach(Array(split.children.enumerated()), id: \.element.renderIdentity) { index, child in
                    PanelSurfaceNodeView(node: child, surface: surface, worktree: worktree)
                        .frame(width: activeRatios[index] * availableSpace)

                    if index < split.children.count - 1 {
                        divider(index: index, availableSpace: availableSpace,
                                thickness: dividerThickness)
                    }
                }
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(split.children.enumerated()), id: \.element.renderIdentity) { index, child in
                    PanelSurfaceNodeView(node: child, surface: surface, worktree: worktree)
                        .frame(height: activeRatios[index] * availableSpace)

                    if index < split.children.count - 1 {
                        divider(index: index, availableSpace: availableSpace,
                                thickness: dividerThickness)
                    }
                }
            }
        }
    }

    private func divider(index: Int, availableSpace: CGFloat, thickness: CGFloat) -> some View {
        SplitDivider(
            direction: split.direction,
            thickness: thickness,
            index: index,
            ratios: $currentRatios,
            availableSpace: availableSpace,
            onDragEnd: { resize(split.id, currentRatios) }
        )
    }
}

// MARK: - Render identity

extension PanelLayoutNode {
    /// Stable `ForEach` identity, matching `LayoutNode.nodeID`'s role. A tab
    /// has exactly one primary anchor, so a constant stands in for it.
    var renderIdentity: UUID {
        switch self {
        case .primary: return Self.primaryRenderIdentity
        case .panel(let slot): return slot.id
        case .split(let split): return split.id
        }
    }

    /// Fixed sentinel for the single `.primary` node in a tab. The all-zero
    /// UUID is never a real `PanelID` — the daemon mints those with `UUID()`.
    static let primaryRenderIdentity = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

// MARK: - Daemon-backed action set

extension PaneActions {
    /// The daemon-backed twin of `PaneActions.legacy`: every structural
    /// mutation becomes a `PanelOperation` through `AppState`'s single
    /// `panel.apply` chokepoint, and the two queries are answered from the
    /// mirrored surface instead of a local tree.
    ///
    /// Built per leaf: `anchor` is what this leaf *is*, which the new model
    /// needs (a `PanelID`, or the primary anchor) and the legacy `paneID`
    /// arguments cannot supply — a note panel's legacy pane ID is its note
    /// ID, not its `PanelID`. Every closure therefore ignores the `paneID`
    /// it is handed; the leaf only ever passes its own.
    ///
    /// **Close is not delete.** Closing a note panel here removes the panel
    /// and leaves the note file alone, unlike the legacy set. That is the
    /// intended new semantics (spec §Non-goals); an explicit delete-note
    /// affordance is a separate follow-up.
    @MainActor
    static func daemonManaged(
        appState: AppState,
        worktreeID: UUID,
        tabID: WorkspaceTabID,
        anchor: PanelAnchor
    ) -> PaneActions {
        // nil for the primary anchor, which has no PanelID: `.primary` is
        // unremovable and history-less by type in the shared reducer, so the
        // close and history gestures are no-ops there.
        let ownPanelID: PanelID? = {
            if case .panel(let id) = anchor { return id }
            return nil
        }()

        @MainActor func fire(_ operation: PanelOperation) {
            Task {
                await appState.applyPanelOperation(
                    worktreeID: worktreeID, tabID: tabID, operation: operation)
            }
        }

        /// The panel currently showing this terminal's transcript, if any.
        @MainActor func openTranscriptPanelID(terminalID: UUID) -> PanelID? {
            guard let layout = appState.panelSurfaceTab(
                worktreeID: worktreeID, tabID: tabID)?.layout else { return nil }
            return layout.allPanelIDs.first { panelID in
                if case .transcript(let openFor)? = layout.panelSlot(id: panelID)?.content {
                    return openFor == terminalID
                }
                return false
            }
        }

        return PaneActions(
            openBeside: { _, direction, content in
                guard let panelContent = PanelSurfaceLeaf.panelContent(for: content) else {
                    logger.error("""
                        openBeside: \(String(describing: content), privacy: .public) \
                        has no viewer-panel form — dropped
                        """)
                    return
                }
                fire(.open(
                    content: panelContent,
                    placement: .beside(
                        target: anchor, edge: direction.trailingPanelEdge, share: nil)))
            },
            routeFile: { _, path in
                // `.automatic` IS the reducer's "reuse the first viewer panel,
                // else split right of the primary anchor" contract — the same
                // routing the legacy `routeFileClick` did by hand.
                fire(.open(content: .file(FileReference(path: path)), placement: .automatic))
            },
            toggleTranscript: { _, terminalID in
                if let openPanelID = openTranscriptPanelID(terminalID: terminalID) {
                    fire(.close(panelID: openPanelID))
                } else {
                    fire(.open(content: .transcript(terminalID: terminalID), placement: .automatic))
                }
            },
            historyStep: { _, step in
                guard let panelID = ownPanelID else { return }
                fire(.history(panelID: panelID, action: step.panelHistoryAction))
            },
            close: { _ in
                guard let panelID = ownPanelID else { return }
                fire(.close(panelID: panelID))
            },
            resize: { splitID, ratios in
                fire(.resize(splitID: splitID, ratios: ratios.map { Double($0) }))
            },
            isTranscriptOpen: { terminalID in
                openTranscriptPanelID(terminalID: terminalID) != nil
            },
            history: { _, content in
                // The mirror carries no per-panel history: `panel.get`
                // returns tabs only, and the daemon keeps histories in its
                // own store. So a leaf on this path reports the honest
                // single-entry history — its chevrons stay disabled rather
                // than pretending to a back/forward state the app cannot
                // see. Surfacing real history needs `panel.get` to return it
                // (a daemon change, deliberately out of this phase).
                PaneHistory.seeded(with: content)
            }
        )
    }
}

// MARK: - Gesture vocabulary bridges

extension SplitDirection {
    /// The edge a legacy "split off me" gesture lands on in the new model's
    /// user-facing edge vocabulary. Matches the legacy behavior: a horizontal
    /// split puts the new pane on the right, a vertical one below.
    var trailingPanelEdge: PanelEdge {
        switch self {
        case .horizontal: return .right
        case .vertical: return .below
        }
    }
}

extension PaneActions.HistoryStep {
    var panelHistoryAction: PanelHistoryAction {
        switch self {
        case .back: return .back
        case .forward: return .forward
        case .to(let index): return .jump(index: index)
        }
    }
}
