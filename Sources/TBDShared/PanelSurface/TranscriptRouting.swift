import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "TranscriptRouting")

/// True when `content` is the live-transcript pane for `terminalID`.
///
/// Shared by `toggleTranscript` and the toolbar button's open-state check so
/// the two never drift apart.
public func isLiveTranscriptPane(_ content: PaneContent, for terminalID: UUID) -> Bool {
    if case .liveTranscript(_, let tid) = content { return tid == terminalID }
    return false
}

/// Toggles the live-transcript pane for `terminalID`.
///
/// Toggle off: the tab already shows a transcript for this terminal — remove
/// that pane. Toggle on: reuse an existing viewer-class slot in place
/// (preserving its `paneID`, see `routeFileClick`); otherwise split
/// horizontally off `fromPaneID`, matching the original always-open behavior.
public func toggleTranscript(into layout: LayoutNode, terminalID: UUID, fromPaneID: UUID) -> ViewerRouteResult {
    if let transcriptID = layout.firstPaneID(where: { isLiveTranscriptPane($0, for: terminalID) }) {
        if let updated = layout.removePane(id: transcriptID) {
            logger.debug("toggleTranscript[close]: transcriptID=\(transcriptID, privacy: .public)")
            return ViewerRouteResult(layout: updated, removedPaneID: transcriptID)
        }
        // The toggle is driven from a sibling terminal pane, so a transcript is
        // never the sole pane here — this branch is defensive and unreachable.
        return ViewerRouteResult(layout: layout)
    }

    if let outgoing = layout.firstPaneContent(where: \.isViewerClass) {
        let slotID = outgoing.paneID
        let incoming = PaneContent.liveTranscript(id: slotID, terminalID: terminalID)
        if let updated = layout.replacingContent(at: slotID, with: incoming) {
            logger.debug("toggleTranscript[swap]: slotID=\(slotID, privacy: .public) terminalID=\(terminalID, privacy: .public)")
            return ViewerRouteResult(
                layout: updated,
                replaced: .init(paneID: slotID, outgoing: outgoing, incoming: incoming)
            )
        }
    }

    logger.debug("toggleTranscript[open]: terminalID=\(terminalID, privacy: .public) fromPaneID=\(fromPaneID, privacy: .public)")
    return ViewerRouteResult(layout: layout.splitPane(
        id: fromPaneID,
        direction: .horizontal,
        newContent: .liveTranscript(id: UUID(), terminalID: terminalID)
    ))
}
