import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: pure value mapping, no state.

/// The content-only bridge from the daemon surface's model to the leaf view's
/// `PaneContent` (panel tabs spec, "The leaf seam"): every panel content
/// case, and a history mapped entry by entry.
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
        // The Changes list has no leaf form.
        #expect(PanelContent.changes.paneContent(panelID: panelID) == nil)
    }

    @Test("every panel content with a leaf form survives the round trip through it")
    func panelContentRoundTrips() {
        let panelID = UUID()
        let cases: [PanelContent] = [
            .file(FileReference(path: "/w/a.swift")),
            .web(Self.pageURL),
            .transcript(terminalID: UUID()),
            .note(noteID: UUID()),
        ]
        for content in cases {
            var mappedBack: PanelContent?
            if let leaf = content.paneContent(panelID: panelID) {
                mappedBack = Self.panelContent(of: leaf)
            }
            #expect(mappedBack == content, "lost in the mapping: \(content)")
        }
    }

    @Test("a history holding content with no leaf form has no leaf history")
    func paneHistoryIsNilWithChangesContent() {
        let history = PanelHistory.seeded(with: .changes)
        #expect(history.paneHistory(panelID: UUID()) == nil)
    }

    @Test("one entry with no leaf form is enough to leave a history without a leaf history")
    func paneHistoryIsNilWithAnyChangesEntry() {
        let file = PanelContent.file(FileReference(path: "/w/a.md"))
        var history = PanelHistory.seeded(with: file)
        history.recordReplacement(outgoing: file, incoming: .changes)
        #expect(history.entries.count == 2, "precondition: a leaf entry beside the Changes one")
        #expect(history.paneHistory(panelID: UUID()) == nil)
    }

    @Test("a history maps entry by entry, keeping order and cursor")
    func paneHistoryKeepsOrderAndCursor() throws {
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

        let mapped = try #require(history.paneHistory(panelID: panelID))

        let expectedEntries: [PaneContent] = history.entries.compactMap { $0.paneContent(panelID: panelID) }
        #expect(expectedEntries.count == history.entries.count, "precondition: every entry has a leaf form")
        #expect(mapped.entries == expectedEntries)
        #expect(mapped.cursor == history.cursor)
        #expect(mapped.cursor == 1, "precondition: the cursor is off the front")
        #expect(mapped.current == history.current?.paneContent(panelID: panelID))
        // An index the palette picks names the same entry on both sides.
        for index in history.entries.indices {
            #expect(Self.panelContent(of: mapped.entries[index]) == history.entries[index])
        }
    }

    @Test("a tab's icon and title for each viewer kind, the same in the tab bar and the side region's strip")
    func tabAppearanceForEachKind() {
        let noteID = UUID()
        let titled: (UUID) -> String? = { $0 == noteID ? "Plan" : nil }
        let untitled: (UUID) -> String? = { _ in "" }
        let file = PanelContent.file(FileReference(path: "/repo/src/a.swift"))
        let web = PanelContent.web(Self.pageURL)
        let note = PanelContent.note(noteID: noteID)
        let transcript = PanelContent.transcript(terminalID: UUID())
        let changes = PanelContent.changes

        #expect(file.kind.tabSystemImage == "doc.text")
        #expect(web.kind.tabSystemImage == "globe")
        #expect(note.kind.tabSystemImage == "note.text")
        #expect(transcript.kind.tabSystemImage == "text.bubble")
        #expect(changes.kind.tabSystemImage == "plus.forwardslash.minus")

        #expect(file.tabTitle(noteTitle: titled, untitledNote: "Note") == "a.swift")
        #expect(web.tabTitle(noteTitle: titled, untitledNote: "Note") == "example.com")
        #expect(PanelContent.web(URL(string: "about:blank")!)
            .tabTitle(noteTitle: titled, untitledNote: "Note") == "Web")
        #expect(note.tabTitle(noteTitle: titled, untitledNote: "Note") == "Plan")
        #expect(transcript.tabTitle(noteTitle: titled, untitledNote: "Note") == "Transcript")
        #expect(changes.tabTitle(noteTitle: titled, untitledNote: "Note") == "Changes")

        // The one deliberate difference: an untitled note is numbered in the
        // tab bar and plain in the strip.
        #expect(note.tabTitle(noteTitle: untitled, untitledNote: "Note 2") == "Note 2")
        #expect(SideRegionStrip.title(for: note, noteTitle: untitled) == "Note")
        #expect(SideRegionStrip.title(for: file, noteTitle: untitled) == "a.swift")
    }
}
