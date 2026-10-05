import Foundation
import TBDShared

/// Where an overlay card gets a truncated row's full body — the "Show full
/// output" footer — decided as a value so both routes are assertable without
/// a view, and fetched through one shared `fetch` so no card carries its own
/// copy of either route.
///
/// A terminal-bound card asks the daemon (`terminalTranscriptItemFullBody`),
/// as it always has. A card with no terminal but a transcript file it may read
/// looks the row up in that file app-side: the remote transcript pane hands
/// its cache file here, because a remote session has no local terminal row
/// and its conversation already sits on this machine. With neither, there is
/// no full body to offer and the footer is withheld — the History pane's
/// behavior, unchanged.
///
/// Every card decides whether to show its footer from `resolve(...) != nil`
/// and fetches through `fetch`, so the footer is offered exactly when a fetch
/// has somewhere to go.
enum TranscriptFullBodySource: Equatable {
    case daemon(terminalID: UUID)
    case file(path: String)

    static func resolve(terminalID: UUID?, detailPath: String?) -> TranscriptFullBodySource? {
        if let terminalID { return .daemon(terminalID: terminalID) }
        if let detailPath, TranscriptDetailReader.shouldReadAppSide(path: detailPath) {
            return .file(path: detailPath)
        }
        return nil
    }

    /// The full body for `itemID` (a row id, or `"<id>#input"` for a tool
    /// call's input), plus any attachment metadata. Nil when the daemon call
    /// fails; the file route returns the daemon's own placeholder text for a
    /// record it cannot find, so the two routes read the same to a card.
    @MainActor
    func fetch(
        itemID: String, includeBody: Bool = true, appState: AppState
    ) async -> TerminalTranscriptItemFullBodyResult? {
        switch self {
        case .daemon(let terminalID):
            let path = appState.transcriptPath(forTerminal: terminalID)
            return try? await appState.daemonClient.terminalTranscriptItemFullBody(
                terminalID: terminalID, itemID: itemID, includeBody: includeBody, path: path)
        case .file(let path):
            // A bounded one-shot file read; kept off the main actor.
            return await Task.detached(priority: .userInitiated) {
                TranscriptDetailReader.fullBody(path: path, itemID: itemID, includeBody: includeBody)
            }.value
        }
    }
}
