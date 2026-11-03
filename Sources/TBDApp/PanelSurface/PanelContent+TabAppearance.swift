import Foundation
import TBDShared

// The icon and title a tab shows for viewer content, shared by the workspace
// tab bar (`TabBar`) and the side region's strip (`SideRegionStrip`), so one
// piece of content looks the same in both. The tab bar reaches these through
// `LegacyTabConverter.panelContent(from:)`; a terminal, which has no panel
// content, keeps the tab bar's own icon and title.

extension PanelKind {
    /// The symbol a tab shows for this kind of content, or nil for a file,
    /// whose tab shows its name alone, with no icon and no gap before it.
    var tabSystemImage: String? {
        switch self {
        case .file: return nil
        case .web: return "globe"
        case .note: return Self.noteSystemImage
        case .transcript: return "bubble"
        case .changes: return Self.changesSystemImage
        }
    }

    /// A note tab's symbol, which the Notes toggle shows too.
    static let noteSystemImage = "doc.text"

    /// The Changes tab's symbol, which the Changes toggle shows too.
    static let changesSystemImage = "plusminus"
}

extension PanelContent {
    /// The title a tab shows for this content: a file's name, a page's host,
    /// a note's title, "Transcript", or "Changes".
    ///
    /// A note with no title shows `untitledNote`, which the two callers
    /// choose differently on purpose: the tab bar numbers it by its tab's
    /// position ("Note 2"), and a side-region tab, which has no such number,
    /// shows "Note".
    func tabTitle(noteTitle: (UUID) -> String?, untitledNote: String) -> String {
        switch self {
        case .file(let reference):
            return URL(fileURLWithPath: reference.path).lastPathComponent
        case .web(let url):
            return url.host ?? "Web"
        case .note(let noteID):
            if let title = noteTitle(noteID), !title.isEmpty { return title }
            return untitledNote
        case .transcript:
            return "Transcript"
        case .changes:
            return "Changes"
        }
    }
}
