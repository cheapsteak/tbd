import Foundation

/// How a transcript opens on a long session: tail first.
///
/// A transcript table must never be MOUNTED holding hundreds of rows. When
/// SwiftUI adds a platform view to the window, AppKit rebuilds the key-view
/// loop, and on a table that already holds every row that realizes far more
/// rows than the viewport needs, inside the first layout: 18–21 s on the main
/// thread for a 323- or 604-item session. The same rows arriving as an UPDATE
/// to a table that is already in the window, sized and pinned to its bottom
/// cost nothing of the kind — they go through the coordinator's `.rebuild`
/// path, which re-pins the unchanged bottom.
///
/// So both panes that show a stored transcript, the live pane
/// (`TableTranscriptPaneView`) and Session History (`SessionTranscriptView`),
/// mount small and widen:
///
/// - **The mount window.** Each hands its table only the last `tailLimit`
///   render nodes until the table's open has settled (`mountedNodes`,
///   widened from `TableTranscriptView.onOpenSettled`), whatever the store
///   already holds. That covers a pane mounting over a populated store: a
///   session reopened in Session History, or a live pane remounted on
///   returning to a worktree that left the keep-alive set, or moved or reopened.
/// - **The tail-first read.** Where the store holds nothing yet, each reads
///   the tail before the whole session: the live pane's daemon poll fetches
///   the last `tailLimit` items before its full fetch, and writes that tail
///   only into an empty slot (`TableTranscriptPaneView.publishOpeningTail`);
///   Session History reads the tail first (`AppState.loadSessionTranscript`).
enum TranscriptTailFirstOpen {
    /// How many items a tail-first read fetches, and how many render nodes a
    /// pane's table first mounts with. Fast to read even on a 2000+ item /
    /// 30 MB session, and well over a screenful.
    static let tailLimit = 60

    /// The nodes a pane hands its table for `sessionID`: only the last `limit`
    /// until that session's table has mounted and settled its open
    /// (`widenedSessionID == sessionID`), and every node from then on.
    ///
    /// Keyed by session because each pane outlives a change of session while
    /// its table is rebuilt per session; each pane also clears its widened
    /// session on every such change, so a session it has not widened for
    /// mounts windowed again, whatever the store already holds.
    static func mountedNodes<Node>(
        _ nodes: [Node],
        sessionID: String,
        widenedSessionID: String?,
        limit: Int = tailLimit
    ) -> [Node] {
        guard widenedSessionID != sessionID, nodes.count > limit else { return nodes }
        return Array(nodes.suffix(limit))
    }
}
