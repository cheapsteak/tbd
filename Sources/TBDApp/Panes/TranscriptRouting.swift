import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "TranscriptRouting")

/// True when `content` is the live-transcript pane for `terminalID`.
///
/// Shared by `toggleTranscript` and the toolbar button's open-state check so
/// the two never drift apart.
func isLiveTranscriptPane(_ content: PaneContent, for terminalID: UUID) -> Bool {
    if case .liveTranscript(_, let tid) = content { return tid == terminalID }
    return false
}

/// Toggles the live-transcript pane for `terminalID`.
///
/// If the tab's layout already contains a `.liveTranscript` pane for this
/// terminal, that pane is removed (toggle off). Otherwise a new transcript
/// pane is split horizontally off `fromPaneID` (toggle on), matching the
/// original always-open behavior.
func toggleTranscript(into layout: LayoutNode, terminalID: UUID, fromPaneID: UUID) -> LayoutNode {
    if let transcriptID = layout.firstPaneID(where: { isLiveTranscriptPane($0, for: terminalID) }) {
        if let updated = layout.removePane(id: transcriptID) {
            logger.debug("toggleTranscript[close]: transcriptID=\(transcriptID, privacy: .public)")
            return updated
        }
        // The toggle is driven from a sibling terminal pane, so a transcript is
        // never the sole pane here — this branch is defensive and unreachable.
        return layout
    }

    logger.debug("toggleTranscript[open]: terminalID=\(terminalID, privacy: .public) fromPaneID=\(fromPaneID, privacy: .public)")
    return layout.splitPane(
        id: fromPaneID,
        direction: .horizontal,
        newContent: .liveTranscript(id: UUID(), terminalID: terminalID)
    )
}
