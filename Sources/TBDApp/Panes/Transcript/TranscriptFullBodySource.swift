import Foundation

/// Where an overlay card gets a truncated row's full body — the "Show full
/// output" footer — decided as a value so both routes are assertable without
/// a view.
///
/// A terminal-bound card asks the daemon (`terminalTranscriptItemFullBody`),
/// as it always has. A card with no terminal but a transcript file it may read
/// looks the row up in that file app-side: the remote transcript pane hands
/// its cache file here, because a remote session has no local terminal row
/// and its conversation already sits on this machine. With neither, there is
/// no full body to offer and the footer is withheld — the History pane's
/// behavior, unchanged.
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
}
