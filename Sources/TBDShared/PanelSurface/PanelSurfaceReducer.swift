import Foundation

public enum PanelOperationError: LocalizedError, Equatable, Sendable {
    case panelNotFound(PanelID)
    /// A panel's kind is fixed: `expected` is the panel's, `actual` the
    /// destination's.
    case kindMismatch(panelID: PanelID, expected: PanelKind, actual: PanelKind)
    case historyUnavailable(PanelID)
    /// `history` or `navigate` named a worktree panel, which shows one piece
    /// of content for its whole life.
    case worktreePanelHasNoHistory(PanelID)
    case invalidWidth(Double)

    public var errorDescription: String? {
        switch self {
        case .panelNotFound(let panelID):
            return "panel not found: \(panelID.uuidString)"
        case .kindMismatch(let panelID, let expected, let actual):
            return "panel \(panelID.uuidString) shows \(expected.rawValue) content "
                + "and cannot be pointed at \(actual.rawValue) content"
        case .historyUnavailable(let panelID):
            return "no navigation history for panel: \(panelID.uuidString)"
        case .worktreePanelHasNoHistory(let panelID):
            return "panel \(panelID.uuidString) is a worktree panel, which has no history "
                + "and shows one note or the Changes list for its whole life"
        case .invalidWidth(let width):
            return "invalid side region width \(width): must be finite and within "
                + "\(SideRegion.widthRange.lowerBound)...\(SideRegion.widthRange.upperBound)"
        }
    }
}

/// Pure reducer for the panel tabs operations (spec "Operations"). No clock,
/// no I/O. `apply` works on a local copy, so it either returns the new
/// surface — with `revision` one higher, even when nothing else changed — or
/// throws and leaves the caller's surface as it was.
///
/// One rule spans `open`, `navigate` and `history`: a workspace tab shows a
/// terminal's transcript at most once, so an operation that would show a
/// transcript another panel already shows selects that panel instead.
///
/// Note and Changes content lives in the worktree's panels (side panel notes
/// spec, "Operations"), at most one panel per note and one for Changes:
/// `open` of it selects the worktree panel already showing it or appends
/// one, and `close` of a worktree panel removes it from the list. The panel
/// in front, collapse and recency stay this tab's, and recency covers only
/// the tab's own panels.
public enum PanelSurfaceReducer {
    public static func apply(
        _ operation: PanelOperation, to surface: WorkspaceTabSurface,
        makeID: () -> UUID = { UUID() }
    ) throws -> WorkspaceTabSurface {
        var next = surface
        switch operation {
        case .open(let content, let newPanel):
            if let worktreeContent = WorktreePanelContent(content) {
                openWorktreePanel(worktreeContent, in: &next, makeID: makeID)
            } else {
                open(content, newPanel: newPanel, in: &next.side, makeID: makeID)
            }
        case .navigate(let panelID, let destination):
            guard next.worktreePanel(id: panelID) == nil else {
                throw PanelOperationError.worktreePanelHasNoHistory(panelID)
            }
            try navigate(panelID, to: destination, in: &next.side)
        case .history(let panelID, let action):
            guard next.worktreePanel(id: panelID) == nil else {
                throw PanelOperationError.worktreePanelHasNoHistory(panelID)
            }
            try moveHistory(of: panelID, action: action, in: &next.side)
        case .select(let panelID):
            if next.worktreePanel(id: panelID) != nil {
                selectWorktreePanel(panelID, in: &next.side)
            } else {
                guard next.side.panel(id: panelID) != nil else {
                    throw PanelOperationError.panelNotFound(panelID)
                }
                select(panelID, in: &next.side)
            }
        case .close(let panelID):
            if next.worktreePanel(id: panelID) != nil {
                closeWorktreePanel(panelID, in: &next)
            } else {
                try close(panelID, in: &next)
            }
        case .setCollapsed(let collapsed):
            next.side.collapsed = collapsed
        case .resize(let width):
            guard width.isFinite, SideRegion.widthRange.contains(width) else {
                throw PanelOperationError.invalidWidth(width)
            }
            next.side.width = width
        }
        next.revision += 1
        return next
    }

    /// `surface` holding `worktreePanels` as the worktree's panels: the list
    /// another workspace tab of the worktree just changed. The panel in front
    /// is repaired when it no longer names a panel of either kind, or names
    /// none while there is one to show: it becomes the tab's most recent own
    /// panel, else the list's first panel, else nil. Collapse, recency and
    /// `revision` are left as they are; the store gives the write its
    /// revision.
    public static func adopting(
        _ worktreePanels: [WorktreePanel], into surface: WorkspaceTabSurface
    ) -> WorkspaceTabSurface {
        var next = surface
        next.worktreePanels = worktreePanels
        if let front = next.side.activePanelID,
           next.side.panel(id: front) != nil || next.worktreePanel(id: front) != nil {
            return next
        }
        next.side.activePanelID = next.side.recency.first ?? worktreePanels.first?.id
        return next
    }

    // MARK: - open

    /// 1. A panel already showing exactly `content` is selected.
    /// 2. Otherwise, for file or web content without `newPanel`, the active
    ///    panel if it is the same kind, else the most recent panel of that
    ///    kind, is navigated to `content` and selected.
    /// 3. Otherwise a new panel goes right after the active one and is
    ///    selected; with a worktree panel in front, or none, it goes first
    ///    among the tab's own panels, which the strip shows right after the
    ///    worktree's.
    /// Selecting clears `collapsed` on every path.
    private static func open(
        _ content: PanelContent, newPanel: Bool,
        in side: inout SideRegion, makeID: () -> UUID
    ) {
        if let shown = side.panels.first(where: { $0.content == content }) {
            select(shown.id, in: &side)
            return
        }
        if !newPanel, content.kind != .transcript,
           let reusedID = reusablePanelID(for: content.kind, in: side),
           let index = side.panels.firstIndex(where: { $0.id == reusedID }),
           let current = side.panels[index].content {
            side.panels[index].history.recordReplacement(outgoing: current, incoming: content)
            select(reusedID, in: &side)
            return
        }
        let panel = ViewerPanel(id: makeID(), content: content)
        let activeID = side.activePanelID
        let activeIndex = side.panels.firstIndex { $0.id == activeID }
        let insertionIndex = activeIndex.map { $0 + 1 } ?? side.panels.startIndex
        side.panels.insert(panel, at: insertionIndex)
        select(panel.id, in: &side)
    }

    /// Selects the worktree panel already showing `content`, or appends one
    /// and selects it. `newPanel` plays no part: a note or the Changes list
    /// is never shown twice.
    private static func openWorktreePanel(
        _ content: WorktreePanelContent, in surface: inout WorkspaceTabSurface, makeID: () -> UUID
    ) {
        if let shown = surface.worktreePanel(showing: content) {
            selectWorktreePanel(shown.id, in: &surface.side)
            return
        }
        let panel = WorktreePanel(id: makeID(), content: content)
        surface.worktreePanels.append(panel)
        selectWorktreePanel(panel.id, in: &surface.side)
    }

    /// The active panel when it shows `kind`, else the first panel of that
    /// kind in recency order.
    private static func reusablePanelID(for kind: PanelKind, in side: SideRegion) -> PanelID? {
        if let active = side.activePanelID, side.panel(id: active)?.content?.kind == kind {
            return active
        }
        return side.recency.first { side.panel(id: $0)?.content?.kind == kind }
    }

    // MARK: - navigate

    /// Commits the panel's history to `destination`, keeping the selection.
    /// Navigating to the content already shown changes nothing but the
    /// revision.
    private static func navigate(
        _ panelID: PanelID, to destination: PanelContent, in side: inout SideRegion
    ) throws {
        guard let index = side.panels.firstIndex(where: { $0.id == panelID }) else {
            throw PanelOperationError.panelNotFound(panelID)
        }
        // Nil only for a malformed decoded history, whose cursor
        // `recordReplacement` would trap on.
        guard let current = side.panels[index].content else {
            throw PanelOperationError.historyUnavailable(panelID)
        }
        guard current.kind == destination.kind else {
            throw PanelOperationError.kindMismatch(
                panelID: panelID, expected: current.kind, actual: destination.kind)
        }
        if let other = panelShowingTranscript(destination, otherThan: panelID, in: side) {
            select(other, in: &side)
            return
        }
        side.panels[index].history.recordReplacement(outgoing: current, incoming: destination)
    }

    // MARK: - history

    /// Moves the panel's cursor without reordering its history or changing
    /// the selection.
    private static func moveHistory(
        of panelID: PanelID, action: PanelHistoryAction, in side: inout SideRegion
    ) throws {
        guard let index = side.panels.firstIndex(where: { $0.id == panelID }) else {
            throw PanelOperationError.panelNotFound(panelID)
        }
        var history = side.panels[index].history
        // `goBack`/`goForward` index by the cursor; a malformed decoded
        // history would trap there.
        guard history.isWellFormed else {
            throw PanelOperationError.historyUnavailable(panelID)
        }
        let target: PanelContent?
        switch action {
        case .back: target = history.goBack()
        case .forward: target = history.goForward()
        case .jump(let entryIndex): target = history.go(to: entryIndex)
        }
        guard let target else {
            throw PanelOperationError.historyUnavailable(panelID)
        }
        if let other = panelShowingTranscript(target, otherThan: panelID, in: side) {
            select(other, in: &side)
            return
        }
        side.panels[index].history = history
    }

    // MARK: - select and close

    /// Makes the tab's own panel active, moves it to the front of `recency`,
    /// and shows the region.
    private static func select(_ panelID: PanelID, in side: inout SideRegion) {
        side.recency.removeAll { $0 == panelID }
        side.recency.insert(panelID, at: 0)
        side.activePanelID = panelID
        side.collapsed = false
    }

    /// Makes a worktree panel active in this tab and shows the region.
    /// `recency` is left alone: it covers only the tab's own panels.
    private static func selectWorktreePanel(_ panelID: PanelID, in side: inout SideRegion) {
        side.activePanelID = panelID
        side.collapsed = false
    }

    /// Removes the tab's own panel and its history. Closing the active panel
    /// makes the most recent remaining own panel active, else the first
    /// worktree panel; closing the last panel of either kind leaves the
    /// region empty, which hides it. It never changes `collapsed`.
    private static func close(_ panelID: PanelID, in surface: inout WorkspaceTabSurface) throws {
        guard let index = surface.side.panels.firstIndex(where: { $0.id == panelID }) else {
            throw PanelOperationError.panelNotFound(panelID)
        }
        surface.side.panels.remove(at: index)
        surface.side.recency.removeAll { $0 == panelID }
        if surface.side.activePanelID == panelID {
            surface.side.activePanelID = surface.side.recency.first ?? surface.worktreePanels.first?.id
        }
    }

    /// Removes a worktree panel from the worktree's list. Closing it while it
    /// is in front of this tab brings the tab's most recent own panel
    /// forward, else the first remaining worktree panel. It never changes
    /// `collapsed`.
    private static func closeWorktreePanel(_ panelID: PanelID, in surface: inout WorkspaceTabSurface) {
        surface.worktreePanels.removeAll { $0.id == panelID }
        if surface.side.activePanelID == panelID {
            surface.side.activePanelID = surface.side.recency.first ?? surface.worktreePanels.first?.id
        }
    }

    // MARK: - helpers

    /// The panel other than `panelID` currently showing `content`, when
    /// `content` is a transcript. Nil for any other kind: only transcripts
    /// are limited to one view.
    private static func panelShowingTranscript(
        _ content: PanelContent, otherThan panelID: PanelID, in side: SideRegion
    ) -> PanelID? {
        guard case .transcript = content else { return nil }
        return side.panels.first { $0.id != panelID && $0.content == content }?.id
    }
}
