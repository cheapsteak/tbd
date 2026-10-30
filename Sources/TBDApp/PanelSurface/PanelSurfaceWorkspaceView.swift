import SwiftUI
import TBDShared

/// The `.task(id:)` key for loading a worktree's surfaces into the app's copy:
/// a new worktree, or the flag turning on, starts a load. Not the active tab:
/// one load fills every tab of the worktree, and deltas keep the copy current
/// after it, so switching tabs costs no `panel.get`. Not the resubscribe reset
/// either: the reset reloads every worktree itself, and its generation is not
/// observed. A struct rather than an interpolated string, so a new dimension
/// is a compile error at the call site instead of a key that silently stays
/// equal.
struct PanelSurfaceLoadKey: Equatable {
    let worktreeID: UUID
    let active: Bool
}

// MARK: - PanelSurfaceWorkspaceView

/// One workspace tab drawn from the daemon-owned surface (panel tabs spec,
/// "The renderer"): the primary on the left, the split divider, and the side
/// region on the right while it has panels and is not collapsed.
///
/// The primary comes from the app's tab, not from the surface: it is
/// app-owned like the tab itself (panel tabs spec, "Tab sync"), and the
/// surface's copy of it only catches up after a `panel.syncTabs` round trip.
/// The side region comes from the surface.
///
/// Every gesture here sends one panel operation through
/// `AppState.applyPanelOperation` and adopts the tab the daemon returns; the
/// only local state is the divider's overlay while a drag is committing.
struct PanelSurfaceWorkspaceView: View {
    let tab: TBDShared.Tab
    let surface: WorkspaceTabSurface
    let worktree: LocalWorktree
    @Environment(AppState.self) var appState

    /// `[primary, side]` shares for the divider. A drag changes them only
    /// here, and one `resize` goes out on release; the adopted reply, or a
    /// width another client set, resets them from the surface.
    @State private var ratios: [CGFloat]

    init(tab: TBDShared.Tab, surface: WorkspaceTabSurface, worktree: LocalWorktree) {
        self.tab = tab
        self.surface = surface
        self.worktree = worktree
        _ratios = State(initialValue: Self.ratios(forWidth: surface.side.width))
    }

    var body: some View {
        let side = surface.side
        GeometryReader { geometry in
            let showsSide = side.isVisible
            let thickness = SplitDividerMetrics.lineThickness
            let availableSpace = max(geometry.size.width - thickness, 0)
            let shares = ratios.count == 2 ? ratios : Self.ratios(forWidth: side.width)

            // The primary stays the first child whatever the side region does,
            // so showing or hiding the region never rebuilds the primary's
            // terminal view.
            HStack(spacing: 0) {
                primaryPane
                    .frame(width: showsSide ? shares[0] * availableSpace : geometry.size.width)
                    .overlay(alignment: .topTrailing) {
                        if Self.showsExpandButton(side: side) {
                            expandButton
                        }
                    }

                if showsSide {
                    SplitDivider(
                        direction: .horizontal,
                        thickness: thickness,
                        index: 0,
                        ratios: $ratios,
                        availableSpace: availableSpace,
                        onDragEnd: { commitWidth() }
                    )
                    .zIndex(1)

                    SideRegionView(surface: surface, worktree: worktree)
                        .frame(width: shares[1] * availableSpace)
                }
            }
        }
        .onChange(of: surface.side.width) { _, width in
            ratios = Self.ratios(forWidth: width)
        }
    }

    /// The primary leaf's content: the app's tab, never `surface.primary`. A
    /// primary re-pointed in the app — the file viewer pointing a file tab at
    /// a new file — shows at once, and still shows if the sync that carries it
    /// to the daemon fails.
    var primaryContent: PaneContent { tab.content }

    private var primaryPane: some View {
        PanePlaceholder(
            content: primaryContent,
            worktree: worktree,
            tabID: surface.id,
            actions: .daemon(
                appState: appState, worktreeID: surface.worktreeID, tabID: surface.id, panelID: nil)
        )
    }

    /// Sits over the primary header's trailing corner, where the primary's
    /// close button is — always disabled on this path, since no operation
    /// removes the primary — sized and padded like it, on the header's
    /// background, so it takes that slot rather than covering the header's
    /// other buttons.
    private var expandButton: some View {
        Button {
            appState.sendPanelOperation(
                worktreeID: surface.worktreeID, tabID: surface.id, .setCollapsed(false))
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 10))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("\\", modifiers: .command)
        .help("Show the side panel (⌘\\)")
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Sends the drag's width, clamped to the model's range. With nothing to
    /// send, or once the apply has finished, the overlay snaps to the copy: an
    /// adopted reply has already moved it there, and a failed apply leaves the
    /// copy where it was.
    private func commitWidth() {
        let appState = appState
        let worktreeID = surface.worktreeID
        let tabID = surface.id
        let heldWidth = surface.side.width
        guard let operation = Self.resizeOperation(ratios: ratios, currentWidth: heldWidth) else {
            ratios = Self.ratios(forWidth: heldWidth)
            return
        }
        Task { @MainActor in
            _ = await appState.applyPanelOperation(worktreeID: worktreeID, tabID: tabID, operation)
            let width = appState.panelSurface(worktreeID: worktreeID, tabID: tabID)?.side.width ?? heldWidth
            ratios = Self.ratios(forWidth: width)
        }
    }

    // MARK: - Pure helpers

    /// The divider's `[primary, side]` shares for a side-region width, clamped
    /// by `SideRegion.clamp`, the divider's own limit.
    static func ratios(forWidth width: Double) -> [CGFloat] {
        let clamped = SideRegion.clamp(width)
        return [CGFloat(1 - clamped), CGFloat(clamped)]
    }

    /// The `resize` a released drag sends: the side's share, clamped. Nil when
    /// the ratios are malformed or the width did not change, so a click on the
    /// divider sends nothing.
    static func resizeOperation(ratios: [CGFloat], currentWidth: Double) -> PanelOperation? {
        guard ratios.count == 2 else { return nil }
        let width = SideRegion.clamp(Double(ratios[1]))
        guard width != currentWidth else { return nil }
        return .resize(width: width)
    }

    /// The expand button shows while the region is collapsed and has panels to
    /// show; an empty region has nothing to expand.
    static func showsExpandButton(side: SideRegion) -> Bool {
        side.collapsed && !side.panels.isEmpty
    }
}
