import SwiftUI

// MARK: - TabRowEdgeControls

/// The two buttons at the window's right edge, just before the button that
/// hides or shows the side region: the transcript button and the Notes
/// button, in that order (`items`). They act on the workspace tab as a whole,
/// not on whatever column they sit over, so they keep to the edge: in the side
/// region's strip while the region shows (`SideStripTrailingItem`), and at
/// the end of the workspace tab bar while it is hidden
/// (`TabBarTrailingItem`).
///
/// `PanelSurfaceWorkspaceView.edgeControls` builds them, values and actions
/// together, so the strip and the bar draw the same two buttons from one
/// decision. The workspace view builds them for the bar, and `SideRegionView`
/// builds them for the strip from the same plain inputs, so no view hands
/// another a struct of closures SwiftUI cannot compare.
struct TabRowEdgeControls {
    /// The transcript button (`WorkspaceTabBarChrome.transcriptControl`), or
    /// nil while the transcript view is off.
    let transcript: PaneChromeControl?
    /// What a press of the transcript button does; nothing unless the button
    /// is enabled.
    let onTranscript: @MainActor () -> Void
    /// The Notes button (`PanelSurfaceWorkspaceView.notesControl`).
    let notes: PaneChromeControl
    /// What a press of the Notes button does (`AppState.toggleNotesPanel`).
    let onNotes: @MainActor () -> Void

    /// The buttons, left to right: the transcript button while it is drawn,
    /// then Notes. The one place the pair's order is decided; the bar and
    /// the strip both take it from here.
    var items: [TabRowEdgeItem] {
        var items: [TabRowEdgeItem] = []
        if let transcript {
            items.append(.transcript(transcript))
        }
        items.append(.notes(notes))
        return items
    }
}

// MARK: - TabRowEdgeItem

/// One of the two buttons at the window's right edge (`TabRowEdgeControls`),
/// as a value.
enum TabRowEdgeItem: Equatable, Identifiable {
    /// The transcript button (`TabRowEdgeControls.transcript`).
    case transcript(PaneChromeControl)
    /// The Notes button (`TabRowEdgeControls.notes`).
    case notes(PaneChromeControl)

    /// One per kind, whatever the control's state, so a button whose state
    /// changes keeps its place in the row.
    var id: String {
        switch self {
        case .transcript: return "transcript"
        case .notes: return "notes"
        }
    }
}

// MARK: - TabRowEdgeButton

/// One of the two buttons at the window's right edge, drawn the same way in
/// the side region's strip and the workspace tab bar: `item`'s control,
/// pressing which does what `edge` says for it.
struct TabRowEdgeButton: View {
    let item: TabRowEdgeItem
    let edge: TabRowEdgeControls

    var body: some View {
        switch item {
        case .transcript(let control):
            PaneChromeControlButton(control: control) {
                edge.onTranscript()
            }
        case .notes(let control):
            PaneChromeControlButton(control: control) {
                edge.onNotes()
            }
        }
    }
}

// MARK: - TabBarTrailingItem

/// One item at the workspace tab bar's trailing end, decided as a value so
/// the bar's order can be asserted without standing up a view.
enum TabBarTrailingItem: Equatable, Identifiable {
    /// The primary's viewer control (`WorkspaceTabBarChrome.viewerControl`).
    case viewerControl(PaneChromeControl)
    /// Session History.
    case sessionHistory
    /// The transcript or Notes button (`TabRowEdgeControls.items`).
    case edge(TabRowEdgeItem)
    /// The button that shows the hidden side region.
    case expand

    /// One per kind, whatever the control's state, so a button whose state
    /// changes keeps its place in the row.
    var id: String {
        switch self {
        case .viewerControl: return "viewer-control"
        case .sessionHistory: return "session-history"
        case .edge(let item): return item.id
        case .expand: return "expand"
        }
    }

    /// The bar's trailing items, left to right: the primary's viewer control
    /// when it has one, then Session History. While the side region is
    /// hidden (`showsSide` false) the bar reaches the window's right edge, so
    /// `edgeItems` (`TabRowEdgeControls.items`) follow, and the expand button
    /// last, when `PanelSurfaceWorkspaceView.showsExpandButton` says so. While
    /// the region shows, its strip holds the edge buttons and its own collapse
    /// button, so the bar ends at Session History.
    static func items(
        viewerControl: PaneChromeControl?,
        edgeItems: [TabRowEdgeItem],
        showsSide: Bool,
        showsExpandButton: Bool
    ) -> [TabBarTrailingItem] {
        var items: [TabBarTrailingItem] = []
        if let viewerControl {
            items.append(.viewerControl(viewerControl))
        }
        items.append(.sessionHistory)
        guard !showsSide else { return items }
        items.append(contentsOf: edgeItems.map { TabBarTrailingItem.edge($0) })
        if showsExpandButton {
            items.append(.expand)
        }
        return items
    }
}

// MARK: - SideStripTrailingItem

/// One item at the side region's strip's trailing end, decided as a value so
/// the strip's order can be asserted without standing up a view.
enum SideStripTrailingItem: Equatable, Identifiable {
    /// The + menu (`SideRegionStrip.addMenuItems`).
    case addMenu
    /// The active panel's own control (`SideRegionStrip.trailingControl`).
    case activePanelControl(PaneChromeControl)
    /// The transcript or Notes button (`TabRowEdgeControls.items`).
    case edge(TabRowEdgeItem)
    /// The button that hides the region, carrying `⌘\`.
    case collapse

    /// One per kind, whatever the control's state, so a button whose state
    /// changes keeps its place in the row.
    var id: String {
        switch self {
        case .addMenu: return "add-menu"
        case .activePanelControl: return "active-panel-control"
        case .edge(let item): return item.id
        case .collapse: return "collapse"
        }
    }

    /// The strip's trailing items, left to right: the + menu, the active
    /// panel's control when it has one, `edgeItems`
    /// (`TabRowEdgeControls.items`), and the collapse button, which ends the
    /// strip at the window's right edge.
    static func items(
        activePanelControl: PaneChromeControl?,
        edgeItems: [TabRowEdgeItem]
    ) -> [SideStripTrailingItem] {
        var items: [SideStripTrailingItem] = [.addMenu]
        if let activePanelControl {
            items.append(.activePanelControl(activePanelControl))
        }
        items.append(contentsOf: edgeItems.map { SideStripTrailingItem.edge($0) })
        items.append(.collapse)
        return items
    }
}
