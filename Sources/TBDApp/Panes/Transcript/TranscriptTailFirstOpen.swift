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
/// So both panes that open a stored transcript mount small and widen: the live
/// pane fetches only the last `tailLimit` items before its full fetch
/// (`TableTranscriptPaneView.pollOnce`), and Session History reads the tail
/// first (`AppState.loadSessionTranscript`) and hands its table only the last
/// `tailLimit` render nodes until the table's open has settled (`mountedNodes`).
enum TranscriptTailFirstOpen {
    /// How many items a tail-first read fetches, and how many render nodes
    /// Session History's table first mounts with. Fast to read even on a 2000+
    /// item / 30 MB session, and well over a screenful.
    static let tailLimit = 60

    /// The nodes Session History hands its table for `sessionID`: only the last
    /// `limit` until that session's table has mounted and settled its open
    /// (`widenedSessionID == sessionID`), and every node from then on.
    ///
    /// Keyed by session because the history view outlives a selection change
    /// while its table is rebuilt per session: a session the view has not
    /// widened for mounts windowed again, whatever the store already holds.
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
