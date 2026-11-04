import SwiftUI
import TBDShared

// MARK: - TabRowEdgeControls

/// The three toggles at the window's right edge, just before the button that
/// hides or shows the side region: Changes while the worktree has changes or
/// its Changes panel is open (`showsChanges`), the transcript and Notes, in
/// that order (`items`). They act on the workspace tab as a whole, not on
/// whatever column they sit over, so they keep to the edge: in the side
/// region's strip while the region shows, as pills (`SideStripTrailingItem`,
/// `SidePanelPillButton`), and at the end of the workspace tab bar while it
/// is hidden, as icon buttons (`TabBarTrailingItem`, `TabRowEdgeButton`).
///
/// `make` builds them, values and actions together, so the strip and the bar
/// draw the same three toggles from one decision. The workspace view builds
/// them for the bar, only while the bar draws them
/// (`PanelSurfaceWorkspaceView.barEdgeControls`), and `SideRegionView` builds
/// them for the strip from the same plain inputs, so no view hands another a
/// struct of closures SwiftUI cannot compare.
struct TabRowEdgeControls {
    /// The Changes toggle (`PanelSurfaceWorkspaceView.changesControl`), or
    /// nil while `showsChanges` hides it.
    let changes: PaneChromeControl?
    /// What a press of the Changes toggle does
    /// (`AppState.toggleChangesPanel(worktreeID:tabID:)`).
    let onChanges: @MainActor () -> Void
    /// The transcript toggle (`WorkspaceTabBarChrome.transcriptControl`), or
    /// nil while the transcript view is off.
    let transcript: PaneChromeControl?
    /// The Claude terminal whose transcript panel the transcript toggle
    /// stands for: the primary, while the toggle is drawn and can act. Nil
    /// otherwise, when no pill stands for any transcript panel, so the strip
    /// shows one as a tab (`SideRegionStrip.pillPanelIDs`).
    let transcriptTerminalID: UUID?
    /// What a press of the transcript toggle does; nothing unless the toggle
    /// is enabled.
    let onTranscript: @MainActor () -> Void
    /// The Notes toggle (`PanelSurfaceWorkspaceView.notesControl`).
    let notes: PaneChromeControl
    /// What a press of the Notes toggle does (`AppState.toggleNotesPanel`).
    let onNotes: @MainActor () -> Void

    /// The toggles, left to right: Changes and the transcript while each is
    /// drawn, then Notes. The one place their order is decided; the bar and
    /// the strip both take it from here.
    var items: [TabRowEdgeItem] {
        var items: [TabRowEdgeItem] = []
        if let changes {
            items.append(.changes(changes))
        }
        if let transcript {
            items.append(.transcript(transcript))
        }
        items.append(.notes(notes))
        return items
    }

    /// Whether the Changes toggle is drawn: while the worktree's Changes list
    /// has a file in it, from its last load (`listIsEmpty` false), or while
    /// its Changes panel is open in this tab (`panelOpen`), so an open panel
    /// can always be closed. Hidden while the last load found no change, and
    /// before any load has finished (`listIsEmpty` nil): a toggle that opens
    /// an empty list would offer nothing. ⌘⇧E opens the list either way.
    static func showsChanges(listIsEmpty: Bool?, panelOpen: Bool) -> Bool {
        panelOpen || listIsEmpty == false
    }

    /// What a press of `item`'s toggle does.
    func action(for item: TabRowEdgeItem) -> @MainActor () -> Void {
        switch item {
        case .changes: onChanges
        case .transcript: onTranscript
        case .notes: onNotes
        }
    }

    /// The Changes, transcript and Notes toggles of the workspace tab
    /// `tabID`, whose primary is `primary`, with what a press of each sends.
    /// One function decides all three, so the side region's strip and the
    /// workspace tab bar, whichever reaches the window's right edge, draw the
    /// same toggles: `PanelSurfaceWorkspaceView` calls it for the bar, and
    /// `SideRegionView` for the strip.
    ///
    /// - **Changes** is in the state of the worktree's Changes panel in this
    ///   tab (`PaneActions.changesToggleDecision`), and a press opens,
    ///   selects or closes it in this tab, whichever tab is on screen
    ///   (`AppState.toggleChangesPanel(worktreeID:tabID:)`). It is drawn
    ///   while `showsChanges` says so, from whether the worktree's last
    ///   loaded Changes list was empty (`AppState.changesListIsEmpty`, which
    ///   `ChangesListPoller` keeps fresh for the worktree on screen).
    /// - **The transcript** is the toggle
    ///   `WorkspaceTabBarChrome.transcriptControl` decides, in the state of a
    ///   Claude terminal's transcript panel
    ///   (`PaneActions.transcriptToggleDecision`). Enabled, a press opens,
    ///   selects or closes that panel through the daemon action set
    ///   (`PaneActions.toggleTranscript`), the only set that can send it;
    ///   disabled, a press sends nothing.
    /// - **Notes** (`PanelSurfaceWorkspaceView.notesControl`) shows, brings
    ///   forward or closes the worktree's first note
    ///   (`AppState.toggleNotesPanel`).
    @MainActor
    static func make(
        appState: AppState,
        worktreeID: UUID,
        tabID: UUID,
        primary: PaneContent,
        surface: WorkspaceTabSurface?,
        transcriptViewEnabled: Bool
    ) -> TabRowEdgeControls {
        var isClaudeTerminal = false
        var transcriptState = SidePanelPillState.off
        if case .terminal(let terminalID) = primary {
            isClaudeTerminal = appState.terminal(id: terminalID, in: worktreeID)?.isClaudeResumable == true
            if isClaudeTerminal && transcriptViewEnabled {
                transcriptState = .state(for: PaneActions.transcriptToggleDecision(
                    side: PanelSurfaceWorkspaceView.sideRegion(of: surface), terminalID: terminalID))
            }
        }
        let transcript = WorkspaceTabBarChrome.transcriptControl(
            primary: primary,
            isClaudeTerminal: isClaudeTerminal,
            transcriptViewEnabled: transcriptViewEnabled,
            transcript: transcriptState)
        var transcriptTerminalID: UUID?
        if transcript?.isEnabled == true, case .terminal(let terminalID) = primary {
            transcriptTerminalID = terminalID
        }

        let changes = PanelSurfaceWorkspaceView.changesControl(surface: surface)
        let changesShown = showsChanges(
            listIsEmpty: appState.changesListIsEmpty[worktreeID],
            panelOpen: changes.pillState?.isOn == true)

        return TabRowEdgeControls(
            changes: changesShown ? changes : nil,
            onChanges: {
                appState.toggleChangesPanel(worktreeID: worktreeID, tabID: tabID)
            },
            transcript: transcript,
            transcriptTerminalID: transcriptTerminalID,
            onTranscript: {
                guard transcript?.isEnabled == true, case .terminal(let terminalID) = primary else { return }
                PaneActions.daemon(
                    appState: appState, worktreeID: worktreeID, tabID: tabID, panelID: nil
                ).toggleTranscript(primary, terminalID)
            },
            notes: PanelSurfaceWorkspaceView.notesControl(surface: surface, notes: appState.notes[worktreeID]),
            onNotes: {
                Task { @MainActor in
                    await appState.toggleNotesPanel(worktreeID: worktreeID, tabID: tabID)
                }
            })
    }
}

// MARK: - TabRowEdgeItem

/// One of the three toggles at the window's right edge
/// (`TabRowEdgeControls`), as a value.
enum TabRowEdgeItem: Equatable, Identifiable {
    /// The Changes toggle (`TabRowEdgeControls.changes`).
    case changes(PaneChromeControl)
    /// The transcript toggle (`TabRowEdgeControls.transcript`).
    case transcript(PaneChromeControl)
    /// The Notes toggle (`TabRowEdgeControls.notes`).
    case notes(PaneChromeControl)

    static let transcriptLabel = "Transcript"
    static let notesLabel = "Notes"
    /// Every pill label, in the toggles' order: the transcript's and Notes'.
    /// Changes has none.
    static let pillLabels = [transcriptLabel, notesLabel]

    /// One per kind, whatever the control's state, so a toggle whose state
    /// changes keeps its place in the row.
    var id: String {
        switch self {
        case .changes: return "changes"
        case .transcript: return "transcript"
        case .notes: return "notes"
        }
    }

    /// The toggle's control.
    var control: PaneChromeControl {
        switch self {
        case .changes(let control), .transcript(let control), .notes(let control):
            return control
        }
    }

    /// The state of the panel the toggle stands for.
    var state: SidePanelPillState {
        control.pillState ?? .off
    }

    /// What the toggle's pill reads, in every state and at every strip width:
    /// its panel's name for the transcript and Notes, the Notes pill reading
    /// "Notes" whatever its note is titled. Nil for Changes, whose pill is
    /// its icon alone (`SidePanelPillButton`).
    var pillLabel: String? {
        switch self {
        case .changes: return nil
        case .transcript: return Self.transcriptLabel
        case .notes: return Self.notesLabel
        }
    }
}

// MARK: - TabRowEdgeButton

/// One of the three toggles at the window's right edge as the workspace tab
/// bar draws it while the side region is hidden: `item`'s control as an icon
/// button with no label, open or not, since no panel is in view, in its
/// pill's grey and with its pill's symbol (`PaneChromeControl.tint`,
/// `PaneChromeControl.systemImage`). Pressing it does what `edge` says for
/// it. The strip draws the same toggles as pills instead
/// (`SidePanelPillButton`).
struct TabRowEdgeButton: View {
    let item: TabRowEdgeItem
    let edge: TabRowEdgeControls

    var body: some View {
        let action = edge.action(for: item)
        PaneChromeControlButton(control: item.control) {
            action()
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
    /// The Changes, transcript or Notes toggle (`TabRowEdgeControls.items`).
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
    /// the region shows, its strip holds the toggles and its own collapse
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
    /// The active panel's own control (`SideRegionStrip.trailingControl`).
    case activePanelControl(PaneChromeControl)
    /// The Changes, transcript or Notes pill (`TabRowEdgeControls.items`).
    case edge(TabRowEdgeItem)
    /// The button that hides the region, carrying `⌘\`.
    case collapse

    /// One per kind, whatever the control's state, so a button whose state
    /// changes keeps its place in the row.
    var id: String {
        switch self {
        case .activePanelControl: return "active-panel-control"
        case .edge(let item): return item.id
        case .collapse: return "collapse"
        }
    }

    /// The strip's trailing items, left to right: the active panel's control
    /// when it has one, then the pills, `edgeItems`
    /// (`TabRowEdgeControls.items`), and the collapse button, which ends the
    /// strip at the window's right edge.
    static func items(
        activePanelControl: PaneChromeControl?,
        edgeItems: [TabRowEdgeItem]
    ) -> [SideStripTrailingItem] {
        var items: [SideStripTrailingItem] = []
        if let activePanelControl {
            items.append(.activePanelControl(activePanelControl))
        }
        items.append(contentsOf: edgeItems.map { SideStripTrailingItem.edge($0) })
        items.append(.collapse)
        return items
    }
}
