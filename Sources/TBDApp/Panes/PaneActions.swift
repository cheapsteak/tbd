import SwiftUI
import TBDShared

// MARK: - PaneActions

/// The structural mutations a pane leaf can ask for, injected instead of
/// performed in place.
///
/// `PanePlaceholder` renders one leaf of a workspace, but it used to also
/// rewrite the surrounding tree through its `@Binding var layout`. Routing
/// every mutation through this action set keeps the leaf's chrome and content
/// rendering usable on top of a different source of truth without duplicating
/// the view.
///
/// `PaneActions.legacy` is today's behavior — the app-side `LayoutNode` tree
/// plus its `AppState` bookkeeping — moved here unchanged.
struct PaneActions {
    /// One step of slot-history navigation, as requested by a viewer pane's
    /// back/forward chevrons and its history palette. Resolving the step
    /// against the slot's recorded history is the action set's job, not the
    /// leaf's.
    enum HistoryStep: Equatable {
        case back
        case forward
        case to(index: Int)
    }

    /// Split `paneID` and put `content` in the new sibling.
    var openBeside: @MainActor (_ paneID: UUID, _ direction: SplitDirection, _ content: PaneContent) -> Void

    /// Open the file a terminal link pointed at, routed to whichever pane
    /// should show it (reuse a viewer slot, else split off the terminal).
    var routeFile: @MainActor (_ terminalID: UUID, _ path: String) -> Void

    /// Toggle the live-transcript pane for `terminalID`, opening it beside
    /// `paneID` when there is no viewer slot to reuse.
    var toggleTranscript: @MainActor (_ paneID: UUID, _ terminalID: UUID) -> Void

    /// Navigate the viewer slot `paneID` one step through its history.
    var historyStep: @MainActor (_ paneID: UUID, _ step: HistoryStep) -> Void

    /// Close the pane showing `content`. Takes the content, not just the pane
    /// ID, because closing a note pane also deletes the note.
    var close: @MainActor (_ content: PaneContent) -> Void

    /// Commit new child ratios for the split identified by `splitID`.
    var resize: @MainActor (_ splitID: UUID, _ ratios: [CGFloat]) -> Void
}

// MARK: - Legacy action set

extension PaneActions {
    /// Today's behavior: mutate the app-side `LayoutNode` tree in `layout` and
    /// keep `AppState`'s pane bookkeeping (histories, tabs, notes) in step.
    ///
    /// Every closure body below came verbatim from the call site it replaced
    /// in `PanePlaceholder` / `SplitContainer`.
    @MainActor
    static func legacy(
        layout: Binding<LayoutNode>,
        appState: AppState,
        worktreeID: UUID
    ) -> PaneActions {
        PaneActions(
            openBeside: { paneID, direction, content in
                layout.wrappedValue = layout.wrappedValue.splitPane(
                    id: paneID,
                    direction: direction,
                    newContent: content
                )
            },
            routeFile: { terminalID, path in
                let result = routeFileClick(into: layout.wrappedValue, terminalID: terminalID, path: path)
                if let replaced = result.replaced {
                    appState.recordPaneReplacement(replaced)
                }
                layout.wrappedValue = result.layout
            },
            toggleTranscript: { paneID, terminalID in
                let result = TBDShared.toggleTranscript(
                    into: layout.wrappedValue,
                    terminalID: terminalID,
                    fromPaneID: paneID
                )
                if let replaced = result.replaced {
                    appState.recordPaneReplacement(replaced)
                }
                if let removed = result.removedPaneID {
                    // Reused slot: restore its pre-transcript content in place instead
                    // of applying the removal layout.
                    if let previous = appState.popHistoryForRemovedPane(removed),
                       let restored = layout.wrappedValue.replacingContent(at: removed, with: previous) {
                        layout.wrappedValue = restored
                        return
                    }
                }
                layout.wrappedValue = result.layout
            },
            historyStep: { paneID, step in
                // Mutate the slot's history, then swap the layout content in
                // place keeping the pane UUID. Goes through `replacingContent`
                // directly — never through the routing functions — so
                // navigating does not push new history entries.
                guard var history = appState.paneHistories[paneID] else { return }
                let target: PaneContent?
                switch step {
                case .back: target = history.goBack()
                case .forward: target = history.goForward()
                case .to(let index): target = history.go(to: index)
                }
                guard let target,
                      let updated = layout.wrappedValue.replacingContent(at: paneID, with: target)
                else { return }
                appState.paneHistories[paneID] = history
                layout.wrappedValue = updated
            },
            close: { content in
                // Delete the underlying resource for note panes
                if case .note(let noteID) = content {
                    Task { await appState.deleteNote(noteID: noteID, worktreeID: worktreeID) }
                }

                appState.paneHistories.removeValue(forKey: content.paneID)

                if let newLayout = layout.wrappedValue.removePane(id: content.paneID) {
                    layout.wrappedValue = newLayout
                } else {
                    // Last pane in this tab — remove the entire tab
                    if let tabIndex = appState.tabs[worktreeID]?.firstIndex(where: {
                        $0.id == content.paneID || $0.content.paneID == content.paneID
                    }) {
                        appState.tabs[worktreeID]?.remove(at: tabIndex)
                        appState.layouts.removeValue(forKey: content.paneID)
                    }
                }
            },
            resize: { splitID, ratios in
                // Write back current ratios into the layout binding, targeting
                // this split by its stable ID (never by child-array equality).
                layout.wrappedValue = layout.wrappedValue.updatingRatios(forSplitID: splitID, to: ratios)
            }
        )
    }
}
