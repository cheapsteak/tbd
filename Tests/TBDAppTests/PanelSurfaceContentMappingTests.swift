import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: pure value mapping, no state.

/// The content-only bridge from the daemon surface's model to the leaf view's
/// `PaneContent` (panel tabs spec, "The leaf seam"): every case of both
/// content enums, and a history mapped entry by entry.
@Suite("Panel surface content mapping")
@MainActor
struct PanelSurfaceContentMappingTests {
    private static let pageURL = URL(string: "https://example.com/page")!

    /// The inverse of `PanelContent.paneContent(panelID:)`, kept here so the
    /// tests can show the mapping loses nothing. Production needs no inverse:
    /// the daemon action set is handed the panel ID and never reads content
    /// back.
    private static func panelContent(of content: PaneContent) -> PanelContent? {
        switch content {
        case .terminal: return nil
        case .codeViewer(_, let path): return .file(FileReference(path: path))
        case .webview(_, let url): return .web(url)
        case .liveTranscript(_, let terminalID): return .transcript(terminalID: terminalID)
        case .note(let noteID): return .note(noteID: noteID)
        }
    }

    @Test("every panel content maps to the leaf content carrying the panel's ID")
    func panelContentMapsEveryCase() {
        let panelID = UUID()
        let terminalID = UUID()
        let noteID = UUID()

        #expect(PanelContent.file(FileReference(path: "/w/a.swift")).paneContent(panelID: panelID)
            == .codeViewer(id: panelID, path: "/w/a.swift"))
        #expect(PanelContent.web(Self.pageURL).paneContent(panelID: panelID)
            == .webview(id: panelID, url: Self.pageURL))
        #expect(PanelContent.transcript(terminalID: terminalID).paneContent(panelID: panelID)
            == .liveTranscript(id: panelID, terminalID: terminalID))
        // A note keeps its note ID: the note case carries nothing else.
        #expect(PanelContent.note(noteID: noteID).paneContent(panelID: panelID)
            == .note(noteID: noteID))
    }

    @Test("every panel content survives the round trip through the leaf content")
    func panelContentRoundTrips() {
        let panelID = UUID()
        let cases: [PanelContent] = [
            .file(FileReference(path: "/w/a.swift")),
            .web(Self.pageURL),
            .transcript(terminalID: UUID()),
            .note(noteID: UUID()),
        ]
        for content in cases {
            #expect(Self.panelContent(of: content.paneContent(panelID: panelID)) == content,
                    "lost in the mapping: \(content)")
        }
    }

    @Test("every primary content maps to leaf content, the tab's ID standing in for a pane ID")
    func primaryContentMapsEveryCase() {
        let tabID = UUID()
        let terminalID = UUID()
        let noteID = UUID()

        #expect(PrimaryContent.terminal(terminalID: terminalID).paneContent(tabID: tabID)
            == .terminal(terminalID: terminalID))
        #expect(PrimaryContent.note(noteID: noteID).paneContent(tabID: tabID)
            == .note(noteID: noteID))
        #expect(PrimaryContent.file(FileReference(path: "/w/b.md")).paneContent(tabID: tabID)
            == .codeViewer(id: tabID, path: "/w/b.md"))
        #expect(PrimaryContent.web(Self.pageURL).paneContent(tabID: tabID)
            == .webview(id: tabID, url: Self.pageURL))
        #expect(PrimaryContent.transcript(terminalID: terminalID).paneContent(tabID: tabID)
            == .liveTranscript(id: tabID, terminalID: terminalID))
    }

    @Test("a history maps entry by entry, keeping order and cursor")
    func paneHistoryKeepsOrderAndCursor() {
        let panelID = UUID()
        let first = PanelContent.file(FileReference(path: "/w/a.md"))
        let second = PanelContent.file(FileReference(path: "/w/b.md"))
        let third = PanelContent.file(FileReference(path: "/w/c.md"))
        let history: PanelHistory = {
            var built = PanelHistory.seeded(with: first)
            built.recordReplacement(outgoing: first, incoming: second)
            built.recordReplacement(outgoing: second, incoming: third)
            _ = built.goBack()
            return built
        }()

        let mapped = history.paneHistory(panelID: panelID)

        let expectedEntries = history.entries.map { $0.paneContent(panelID: panelID) }
        #expect(mapped.entries == expectedEntries)
        #expect(mapped.cursor == history.cursor)
        #expect(mapped.cursor == 1, "precondition: the cursor is off the front")
        #expect(mapped.current == history.current?.paneContent(panelID: panelID))
        // An index the palette picks names the same entry on both sides.
        for index in history.entries.indices {
            #expect(Self.panelContent(of: mapped.entries[index]) == history.entries[index])
        }
    }
}
