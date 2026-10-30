import Foundation
import CoreGraphics

/// Converts one legacy workspace tab — `Tab.content` plus its `LayoutNode`
/// tree — into a `WorkspaceTabSurface` (panel tabs spec, "Legacy import").
/// `panel.syncTabs` runs it for each listed tab that has no surface yet.
///
/// The tab's content becomes the primary. Every other leaf of the tree is a
/// viewer pane and becomes one `ViewerPanel`, in pre-order, under a freshly
/// minted ID: a note pane's legacy ID is the note's own ID, so reusing pane
/// IDs would collide when one note is open in two tabs, and panel IDs are a
/// table-wide key. A terminal anywhere but the primary has no panel form, and
/// workspace tabs are app-owned, so it cannot become a tab of its own either:
/// such a tab is skipped and keeps rendering legacy.
public enum LegacyTabConverter {
    public enum Outcome: Equatable, Sendable {
        case converted(WorkspaceTabSurface)
        /// The tab gets no surface; the reason names it.
        case skipped(String)
    }

    public static func convert(
        worktreeID: UUID,
        tab: LegacyTabPayload,
        paneHistories: [UUID: MRUHistory<PaneContent>],
        makeID: () -> UUID = { UUID() }
    ) -> Outcome {
        guard let primary = primaryContent(from: tab.content) else {
            return .skipped("tab \(tab.tabID): its content has no primary form")
        }
        let layout = tab.layout ?? .pane(tab.content)
        let primaryPaneID = tab.content.paneID
        let viewerPanes = leaves(of: layout).filter { $0.paneID != primaryPaneID }

        for pane in viewerPanes {
            if case .terminal(let terminalID) = pane {
                return .skipped("tab \(tab.tabID): terminal \(terminalID) outside the primary")
            }
        }

        var panels: [ViewerPanel] = []
        for pane in viewerPanes {
            guard let content = panelContent(from: pane) else { continue }
            panels.append(ViewerPanel(
                id: makeID(), history: history(paneHistories[pane.paneID], current: content)))
        }

        var side = SideRegion.empty
        if let first = panels.first {
            side = SideRegion(
                panels: panels, activePanelID: first.id, recency: panels.map(\.id),
                collapsed: false, width: width(of: layout, primaryPaneID: primaryPaneID))
        }
        let surface = WorkspaceTabSurface(
            id: tab.tabID, worktreeID: worktreeID, label: tab.label,
            primary: primary, side: side, revision: 0)

        // Legacy data the model cannot express — two panes on one terminal's
        // transcript — keeps the tab legacy rather than losing a pane.
        let violations = PanelSurfaceValidator.violations(in: surface)
        guard violations.isEmpty else {
            return .skipped("tab \(tab.tabID): \(violations)")
        }
        return .converted(surface)
    }

    // MARK: - Content mapping

    /// Maps a legacy pane to the panel content it shows. `.terminal` has none:
    /// a terminal is only ever a primary.
    public static func panelContent(from legacy: PaneContent) -> PanelContent? {
        switch legacy {
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

    /// Maps a legacy pane to primary content. Every legacy variant has a
    /// primary form today; the optional leaves room for one without, whose
    /// tab `convert` skips.
    public static func primaryContent(from legacy: PaneContent) -> PrimaryContent? {
        switch legacy {
        case .terminal(let id):
            return .terminal(terminalID: id)
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

    // MARK: - Pieces

    /// Every leaf of `node`, in pre-order: depth first, left to right.
    private static func leaves(of node: LayoutNode) -> [PaneContent] {
        switch node {
        case .pane(let content):
            return [content]
        case .split(_, _, let children, _):
            return children.flatMap { leaves(of: $0) }
        }
    }

    /// A viewer pane's legacy history as a panel history. Entries map through
    /// `panelContent(from:)` and are kept only when they have the pane's
    /// current kind. Two legacy entries can map to one `PanelContent` (code
    /// viewers with different pane IDs on one path), so the first in MRU
    /// order is kept. Past `MRUHistory.maxEntries` the oldest entries are
    /// evicted, never the current one. The cursor points at the pane's
    /// current content, whatever the legacy cursor said; a history that lacks
    /// that content, or no history at all, gives a one-entry history of it.
    private static func history(
        _ legacy: MRUHistory<PaneContent>?, current: PanelContent
    ) -> PanelHistory {
        var entries: [PanelContent] = []
        for entry in legacy?.entries ?? [] {
            guard let mapped = panelContent(from: entry), mapped.kind == current.kind,
                  !entries.contains(mapped) else { continue }
            entries.append(mapped)
        }
        if entries.count > PanelHistory.maxEntries {
            var kept = Array(entries.prefix(PanelHistory.maxEntries))
            // The current entry is older than every kept one, so it takes the
            // last slot and the order stays most recent first.
            if entries.contains(current), !kept.contains(current) {
                kept[kept.count - 1] = current
            }
            entries = kept
        }
        guard let cursor = entries.firstIndex(of: current) else {
            return .seeded(with: current)
        }
        return PanelHistory(entries: entries, cursor: cursor)
    }

    /// The side region's share of the tab. When the root is a horizontal
    /// split of two children and one of them holds the primary pane, the
    /// viewer side gets the rest, `1 - primaryChildRatio`, clamped to
    /// `SideRegion.widthRange`. Anything else — a vertical root, three or
    /// more columns, ratios that are missing or not finite, no child holding
    /// the primary — gives `SideRegion.defaultWidth`.
    private static func width(of layout: LayoutNode, primaryPaneID: UUID) -> Double {
        guard case .split(_, .horizontal, let children, let ratios) = layout,
              children.count == 2, ratios.count == 2,
              let primaryIndex = children.firstIndex(where: { child in
                  leaves(of: child).contains { $0.paneID == primaryPaneID }
              })
        else { return SideRegion.defaultWidth }

        let share = 1 - Double(ratios[primaryIndex])
        guard share.isFinite else { return SideRegion.defaultWidth }
        return min(max(share, SideRegion.widthRange.lowerBound), SideRegion.widthRange.upperBound)
    }
}
