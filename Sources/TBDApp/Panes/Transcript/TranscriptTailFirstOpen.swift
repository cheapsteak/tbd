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
/// - **The tail-first read.** Each reads the tail before the whole session:
///   the live pane's daemon poll fetches the last `tailLimit` items before its
///   full fetch, and writes that tail into an empty slot, or splices it onto
///   a slot that already holds its first item, never cutting the history a
///   slot holds (`TableTranscriptPaneView.openingTailMerge`); Session History
///   reads the tail first when the store holds nothing for the session
///   (`AppState.loadSessionTranscript`).
enum TranscriptTailFirstOpen {
    /// How many items a tail-first read fetches, and how many render nodes a
    /// pane's table first mounts with. Fast to read even on a 2000+ item /
    /// 30 MB session, and well over a screenful.
    static let tailLimit = 60

    /// The nodes a pane hands the table it mounts under `mountKey`: only the
    /// last `limit` until that table has mounted and settled its open
    /// (`widenedKey == mountKey`), and every node from then on.
    ///
    /// The key is the table's own SwiftUI identity (its `.id`): the session ID
    /// in Session History, the terminal and session in the live pane. Each
    /// pane outlives the tables it rebuilds, and a widen recorded for one
    /// table does not match a table built under another identity, so that
    /// table mounts windowed in the very pass that builds it, whatever the
    /// store already holds. A table can also be built again under an identity
    /// that widened before, so each pane clears its widened key too:
    ///
    /// - **The live pane** (`TableTranscriptPaneView.shownTableKey`) whenever
    ///   the shown table's identity changes or the table leaves its body.
    /// - **Session History** (`SessionTranscriptView`) on every selection
    ///   change. A remount while the same session stays selected keeps the
    ///   key, and is not covered.
    static func mountedNodes<Node, Key: Equatable>(
        _ nodes: [Node],
        mountKey: Key,
        widenedKey: Key?,
        limit: Int = tailLimit
    ) -> [Node] {
        guard widenedKey != mountKey, nodes.count > limit else { return nodes }
        return Array(nodes.suffix(limit))
    }
}
