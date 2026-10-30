import AppKit
import SwiftUI
import TBDShared

// MARK: - PaneHistoryStep

/// One step through a viewer slot's history: the back and forward chevrons,
/// or a jump to an absolute entry index picked in the history palette.
enum PaneHistoryStep: Equatable {
    case back
    case forward
    case jump(Int)
}

// MARK: - PaneActions

/// Everything `PanePlaceholder` asks of the workspace around it, injected
/// instead of performed in place.
///
/// The leaf renders one pane — its header, history chevrons and content — but
/// it does not own the tree it sits in. Every structural change it triggers,
/// and the two things it needs to know about that tree (whether a transcript
/// is open, which history to show), goes through this set, so the same leaf
/// can render on top of more than one source of truth. `legacy` is the
/// app-side `LayoutNode` tree.
///
/// Split ratios are not here: `SplitContainer` commits them itself, and the
/// leaf never resizes anything.
struct PaneActions {
    /// Step the viewer slot showing the given content through its history.
    var historyStep: @MainActor (PaneContent, PaneHistoryStep) -> Void
    /// Point the pane showing the given content at another file, keeping the
    /// pane — raised by a link clicked inside a rendered markdown document.
    var navigateInPane: @MainActor (PaneContent, String) -> Void
    /// Open a file path command-clicked in a terminal.
    var routeTerminalFile: @MainActor (_ terminalID: UUID, _ path: String) -> Void
    /// Open a file preview raised from inside the pane showing the given
    /// content — a transcript tool card, or the transcript overlay drawn over
    /// a terminal.
    var openFilePreview: @MainActor (PaneContent, String) -> Void
    /// Act on a link clicked in a terminal's live transcript.
    var openTranscriptLink: @MainActor (PaneContent, _ terminalID: UUID, TranscriptLinkTarget) -> Void
    /// Close the pane showing the given content. Takes the content, not just
    /// the pane ID, because closing a note pane also deletes the note.
    var close: @MainActor (PaneContent) -> Void
    /// Show or hide a terminal's live transcript, from the pane showing the
    /// given content.
    var toggleTranscript: @MainActor (PaneContent, _ terminalID: UUID) -> Void
    /// Whether a terminal's live transcript is showing: the on-state of the
    /// terminal header's Transcript button.
    var isTranscriptOpen: @MainActor (_ terminalID: UUID) -> Bool
    /// The history behind a pane's back/forward chevrons and history palette.
    /// Nil hides them.
    var history: @MainActor (PaneContent) -> PaneHistory?
    /// Whether the pane's close button is enabled.
    var canClose: @MainActor (PaneContent) -> Bool
}

// MARK: - Legacy action set

extension PaneActions {
    /// The app-side layout tree: mutate the `LayoutNode` behind `layout` and
    /// keep `AppState`'s pane bookkeeping (slot histories, tabs, notes) in
    /// step. This is the whole of the legacy split layout's behaviour for a
    /// leaf, and so the rollback path while the panel tabs flag is off.
    ///
    /// `tabID` is not read: closing the last pane finds its tab by pane ID.
    @MainActor
    static func legacy(
        layout: Binding<LayoutNode>,
        appState: AppState,
        worktree: LocalWorktree,
        tabID: UUID?
    ) -> PaneActions {
        PaneActions(
            historyStep: { content, step in
                // Mutate the slot's history, then swap the layout content in
                // place keeping the pane UUID. Goes through `replacingContent`
                // directly — never through the routing functions — so
                // navigating does not push new history entries.
                guard var history = appState.paneHistories[content.paneID] else { return }
                let target: PaneContent?
                switch step {
                case .back: target = history.goBack()
                case .forward: target = history.goForward()
                case .jump(let index): target = history.go(to: index)
                }
                guard let target,
                      let updated = layout.wrappedValue.replacingContent(at: content.paneID, with: target)
                else { return }
                appState.paneHistories[content.paneID] = history
                layout.wrappedValue = updated
            },
            navigateInPane: { content, path in
                // Not `routeFileClick`: that one picks a destination slot, and
                // the destination here is already known.
                guard let result = routeInPaneFileNavigation(
                    into: layout.wrappedValue, paneID: content.paneID, path: path) else { return }
                if let replaced = result.replaced {
                    appState.recordPaneReplacement(replaced)
                }
                layout.wrappedValue = result.layout
            },
            routeTerminalFile: { terminalID, path in
                let result = routeFileClick(into: layout.wrappedValue, terminalID: terminalID, path: path)
                if let replaced = result.replaced {
                    appState.recordPaneReplacement(replaced)
                }
                layout.wrappedValue = result.layout
            },
            openFilePreview: { content, path in
                let newContent = PaneContent.codeViewer(id: UUID(), path: path)
                layout.wrappedValue = layout.wrappedValue.splitPane(
                    id: content.paneID, direction: .horizontal, newContent: newContent)
            },
            openTranscriptLink: { _, terminalID, target in
                switch TranscriptLinkDestination.live(
                    target, layout: layout.wrappedValue, terminalID: terminalID
                ) {
                case .route(let result):
                    if let replaced = result.replaced {
                        appState.recordPaneReplacement(replaced)
                    }
                    layout.wrappedValue = result.layout
                case .openInBrowser(let url):
                    NSWorkspace.shared.open(url)
                }
            },
            close: { content in
                // Delete the underlying resource for note panes
                if case .note(let noteID) = content {
                    Task { await appState.deleteNote(noteID: noteID, worktreeID: worktree.id) }
                }

                appState.paneHistories.removeValue(forKey: content.paneID)

                if let newLayout = layout.wrappedValue.removePane(id: content.paneID) {
                    layout.wrappedValue = newLayout
                } else {
                    // Last pane in this tab — remove the entire tab
                    let worktreeID = worktree.id
                    if let tabIndex = appState.tabs[worktreeID]?.firstIndex(where: {
                        $0.id == content.paneID || $0.content.paneID == content.paneID
                    }) {
                        appState.tabs[worktreeID]?.remove(at: tabIndex)
                        appState.layouts.removeValue(forKey: content.paneID)
                    }
                }
            },
            toggleTranscript: { content, terminalID in
                // Qualified: the `toggleTranscript` member shadows the free
                // function here.
                let result = TBDShared.toggleTranscript(
                    into: layout.wrappedValue, terminalID: terminalID, fromPaneID: content.paneID)
                if let replaced = result.replaced {
                    appState.recordPaneReplacement(replaced)
                }
                if let removed = result.removedPaneID {
                    // Reused slot: restore its pre-transcript content in place
                    // instead of applying the removal layout.
                    if let previous = appState.popHistoryForRemovedPane(removed),
                       let restored = layout.wrappedValue.replacingContent(at: removed, with: previous) {
                        layout.wrappedValue = restored
                        return
                    }
                }
                layout.wrappedValue = result.layout
            },
            isTranscriptOpen: { terminalID in
                layout.wrappedValue.firstPaneID(where: { isLiveTranscriptPane($0, for: terminalID) }) != nil
            },
            history: { content in
                // Only viewer-class panes navigate. One that hasn't navigated
                // yet has no recorded history — but it always has its current
                // content, so fall back to a single-entry history seeded with
                // it rather than an empty one. Otherwise the search button
                // would wrongly read as "nothing to show" for the common case
                // of a freshly opened viewer slot.
                guard content.isViewerClass else { return nil }
                return appState.paneHistories[content.paneID] ?? PaneHistory.seeded(with: content)
            },
            canClose: { _ in
                // Always: `close` removes the pane from the tree, and the last
                // pane in a tab takes the tab with it.
                true
            }
        )
    }
}
