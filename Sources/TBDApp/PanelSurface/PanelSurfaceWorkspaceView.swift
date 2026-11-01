import SwiftUI
import TBDShared

/// The `.task(id:)` key for loading a worktree's surfaces into the app's copy
/// (`AppState.panelSurfaceLoadKey`). A load runs while the shown tab has no
/// surface in the copy, so one starts when such a tab is shown — in a newly
/// shown worktree, or by a tab switch. That is the backstop for a tab a
/// failed `panel.get`, or an import delta missed while the subscription was
/// down, left without a surface: it loads again when it is shown, instead of
/// drawing an empty side region until the user picks another worktree. A
/// shown tab with a surface asks for no load: one load fills every tab of the
/// worktree and deltas keep the copy current, so switching between such tabs
/// costs no `panel.get`. Neither does a tab the last tab sync skipped
/// (`panelSyncSkippedTabIDs`): the daemon could not import its legacy layout,
/// so no load would find a surface for it, and it renders legacy until a
/// change to its layout offers it again. Not the resubscribe either: its
/// acknowledgement refetches every worktree with a tab list itself. A struct
/// rather than an interpolated string, so a new dimension is a compile error
/// at the call site instead of a key that silently stays equal.
struct PanelSurfaceLoadKey: Equatable {
    let worktreeID: UUID
    /// A tab is shown, the copy holds no surface for it, and the last tab
    /// sync did not skip it.
    let activeTabAwaitsSurface: Bool

    /// Whether the task this key starts loads the worktree's surfaces.
    var loads: Bool { activeTabAwaitsSurface }
}

// MARK: - PanelSurfaceWorkspaceView

/// One workspace tab drawn from the daemon-owned surface (panel tabs spec,
/// "The renderer"): the primary on the left, the split divider, and the side
/// region on the right while it has panels and is not collapsed.
///
/// The primary comes from the app's tab, not from the surface: it is
/// app-owned like the tab itself (panel tabs spec, "Tab sync"), and the
/// surface's copy of it only catches up after a `panel.syncTabs` round trip.
/// The side region comes from the surface, and is empty while the copy holds
/// none for the tab (`surface` nil), so a new tab draws this same view before
/// and after its surface arrives.
///
/// Every gesture here sends one panel operation through
/// `AppState.applyPanelOperation` and adopts the tab the daemon returns; the
/// only local state is the divider's overlay while a drag is committing.
struct PanelSurfaceWorkspaceView: View {
    let tab: TBDShared.Tab
    /// The copy's surface for this tab, or nil while it holds none yet.
    let surface: WorkspaceTabSurface?
    let worktree: LocalWorktree
    @Environment(AppState.self) var appState

    /// `[primary, side]` shares for the divider. A drag changes them only
    /// here, and one `resize` goes out on release; the adopted reply, or a
    /// width another client set, resets them from the surface.
    @State private var ratios: [CGFloat]

    init(tab: TBDShared.Tab, surface: WorkspaceTabSurface?, worktree: LocalWorktree) {
        self.tab = tab
        self.surface = surface
        self.worktree = worktree
        _ratios = State(initialValue: Self.ratios(forWidth: Self.sideRegion(of: surface).width))
    }

    /// The side region drawn: the surface's, or an empty one without it.
    private var side: SideRegion { Self.sideRegion(of: surface) }

    var body: some View {
        let side = self.side
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

                if showsSide, let surface {
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
        .onChange(of: side.width) { _, width in
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
            tabID: tab.id,
            actions: .daemon(
                appState: appState, worktreeID: worktree.id, tabID: tab.id, panelID: nil)
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
                worktreeID: worktree.id, tabID: tab.id, .setCollapsed(false))
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
        let worktreeID = worktree.id
        let tabID = tab.id
        let heldWidth = side.width
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

    /// A surface's side region, or `SideRegion.empty` for none.
    static func sideRegion(of surface: WorkspaceTabSurface?) -> SideRegion {
        surface?.side ?? .empty
    }

    /// The divider's `[primary, side]` shares for a side-region width, clamped
    /// by `SideRegion.clamp`, the divider's own limit.
    static func ratios(forWidth width: Double) -> [CGFloat] {
        let clamped = SideRegion.clamp(width)
        return [CGFloat(1 - clamped), CGFloat(clamped)]
    }

    /// The `resize` a released drag sends: the side's share, clamped. Nil when
    /// the ratios are malformed or not finite, or the width did not change, so
    /// a click on the divider sends nothing. A non-finite share is no width
    /// the user chose: `SideRegion.clamp` would turn it into the default, and
    /// a resize to that would move the divider nobody dragged there.
    static func resizeOperation(ratios: [CGFloat], currentWidth: Double) -> PanelOperation? {
        guard ratios.count == 2, ratios[1].isFinite else { return nil }
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
