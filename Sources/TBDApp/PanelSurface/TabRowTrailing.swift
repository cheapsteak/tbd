// MARK: - TabRowEdgeControls

/// The two buttons at the window's right edge, just before the button that
/// hides or shows the side region: the transcript button and the Notes
/// button, in that order. They act on the workspace tab as a whole, not on
/// whatever column they sit over, so they keep to the edge: in the side
/// region's strip while the region shows (`SideStripTrailingItem`), and at
/// the end of the workspace tab bar while it is hidden
/// (`TabBarTrailingItem`).
///
/// `PanelSurfaceWorkspaceView.edgeControls` builds them, values and actions
/// together, so the strip and the bar draw the same two buttons from one
/// decision.
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
}

// MARK: - TabBarTrailingItem

/// One item at the workspace tab bar's trailing end, decided as a value so
/// the bar's order can be asserted without standing up a view.
enum TabBarTrailingItem: Equatable, Identifiable {
    /// The primary's viewer control (`WorkspaceTabBarChrome.viewerControl`).
    case viewerControl(PaneChromeControl)
    /// Session History.
    case sessionHistory
    /// The transcript button (`TabRowEdgeControls.transcript`).
    case transcript(PaneChromeControl)
    /// The Notes button (`TabRowEdgeControls.notes`).
    case notes(PaneChromeControl)
    /// The button that shows the hidden side region.
    case expand

    /// One per kind, whatever the control's state, so a button whose state
    /// changes keeps its place in the row.
    var id: String {
        switch self {
        case .viewerControl: return "viewer-control"
        case .sessionHistory: return "session-history"
        case .transcript: return "transcript"
        case .notes: return "notes"
        case .expand: return "expand"
        }
    }

    /// The bar's trailing items, left to right: the primary's viewer control
    /// when it has one, then Session History. While the side region is
    /// hidden (`showsSide` false) the bar reaches the window's right edge, so
    /// the edge controls follow — the transcript button while it is drawn,
    /// then Notes — and the expand button last, when
    /// `PanelSurfaceWorkspaceView.showsExpandButton` says so. While the region
    /// shows, its strip holds the edge controls and its own collapse button,
    /// so the bar ends at Session History.
    static func items(
        viewerControl: PaneChromeControl?,
        transcript: PaneChromeControl?,
        notes: PaneChromeControl,
        showsSide: Bool,
        showsExpandButton: Bool
    ) -> [TabBarTrailingItem] {
        var items: [TabBarTrailingItem] = []
        if let viewerControl {
            items.append(.viewerControl(viewerControl))
        }
        items.append(.sessionHistory)
        guard !showsSide else { return items }
        if let transcript {
            items.append(.transcript(transcript))
        }
        items.append(.notes(notes))
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
    /// The transcript button (`TabRowEdgeControls.transcript`).
    case transcript(PaneChromeControl)
    /// The Notes button (`TabRowEdgeControls.notes`).
    case notes(PaneChromeControl)
    /// The button that hides the region, carrying `⌘\`.
    case collapse

    /// One per kind, whatever the control's state, so a button whose state
    /// changes keeps its place in the row.
    var id: String {
        switch self {
        case .addMenu: return "add-menu"
        case .activePanelControl: return "active-panel-control"
        case .transcript: return "transcript"
        case .notes: return "notes"
        case .collapse: return "collapse"
        }
    }

    /// The strip's trailing items, left to right: the + menu, the active
    /// panel's control when it has one, the edge controls — the transcript
    /// button while it is drawn, then Notes — and the collapse button, which
    /// ends the strip at the window's right edge.
    static func items(
        activePanelControl: PaneChromeControl?,
        transcript: PaneChromeControl?,
        notes: PaneChromeControl
    ) -> [SideStripTrailingItem] {
        var items: [SideStripTrailingItem] = [.addMenu]
        if let activePanelControl {
            items.append(.activePanelControl(activePanelControl))
        }
        if let transcript {
            items.append(.transcript(transcript))
        }
        items.append(.notes(notes))
        items.append(.collapse)
        return items
    }
}
