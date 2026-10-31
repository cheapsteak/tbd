import Foundation

public enum PanelOperationError: LocalizedError, Equatable, Sendable {
    case panelNotFound(PanelID)
    /// A panel's kind is fixed: `expected` is the panel's, `actual` the
    /// destination's.
    case kindMismatch(panelID: PanelID, expected: PanelKind, actual: PanelKind)
    case historyUnavailable(PanelID)
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
public enum PanelSurfaceReducer {
    public static func apply(
        _ operation: PanelOperation, to surface: WorkspaceTabSurface,
        makeID: () -> UUID = { UUID() }
    ) throws -> WorkspaceTabSurface {
        var side = surface.side
        switch operation {
        case .open(let content, let newPanel):
            open(content, newPanel: newPanel, in: &side, makeID: makeID)
        case .navigate(let panelID, let destination):
            try navigate(panelID, to: destination, in: &side)
        case .history(let panelID, let action):
            try moveHistory(of: panelID, action: action, in: &side)
        case .select(let panelID):
            guard side.panel(id: panelID) != nil else {
                throw PanelOperationError.panelNotFound(panelID)
            }
            select(panelID, in: &side)
        case .close(let panelID):
            try close(panelID, in: &side)
        case .setCollapsed(let collapsed):
            side.collapsed = collapsed
        case .resize(let width):
            guard width.isFinite, SideRegion.widthRange.contains(width) else {
                throw PanelOperationError.invalidWidth(width)
            }
            side.width = width
        }
        var next = surface
        next.side = side
        next.revision += 1
        return next
    }

    // MARK: - open

    /// 1. A panel already showing exactly `content` is selected.
    /// 2. Otherwise, for file, web or note content without `newPanel`, the
    ///    active panel if it is the same kind, else the most recent panel of
    ///    that kind, is navigated to `content` and selected.
    /// 3. Otherwise a new panel goes right after the active one and is
    ///    selected.
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
        // Right after the active panel; an empty region (no active) starts at 0.
        let insertionIndex = activeIndex.map { $0 + 1 } ?? side.panels.endIndex
        side.panels.insert(panel, at: insertionIndex)
        select(panel.id, in: &side)
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

    /// Makes the panel active, moves it to the front of `recency`, and shows
    /// the region.
    private static func select(_ panelID: PanelID, in side: inout SideRegion) {
        side.recency.removeAll { $0 == panelID }
        side.recency.insert(panelID, at: 0)
        side.activePanelID = panelID
        side.collapsed = false
    }

    /// Removes the panel and its history. Closing the active panel makes the
    /// most recent remaining one active; closing the last leaves the region
    /// empty, which hides it.
    private static func close(_ panelID: PanelID, in side: inout SideRegion) throws {
        guard let index = side.panels.firstIndex(where: { $0.id == panelID }) else {
            throw PanelOperationError.panelNotFound(panelID)
        }
        side.panels.remove(at: index)
        side.recency.removeAll { $0 == panelID }
        if side.activePanelID == panelID {
            side.activePanelID = side.recency.first
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
