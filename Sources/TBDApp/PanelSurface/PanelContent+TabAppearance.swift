import Foundation
import TBDShared

// The icon and title a tab shows for viewer content, shared by the workspace
// tab bar (`TabBar`) and the side region's strip (`SideRegionStrip`), so one
// piece of content looks the same in both. The tab bar reaches these through
// `LegacyTabConverter.panelContent(from:)`; a terminal, which has no panel
// content, keeps the tab bar's own icon and title.

extension PanelKind {
    /// The symbol a tab shows for this kind of content.
    var tabSystemImage: String {
        switch self {
        case .file: return "doc.text"
        case .web: return "globe"
        case .note: return "note.text"
        case .transcript: return "text.bubble"
        }
    }
}

extension PanelContent {
    /// The title a tab shows for this content: a file's name, a page's host,
    /// a note's title, or "Transcript".
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
        }
    }
}
