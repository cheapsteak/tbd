import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The file a workspace tab's right-click menu offers Reveal in Finder and
/// Open With for. On the daemon path no header names the primary, so for a
/// file or transcript primary that menu is where those items are. Asserted
/// through the resolver rather than a rendered menu, so each kind is testable
/// without SwiftUI.
@Suite("Workspace tab file menu")
struct WorkspaceTabFileMenuTests {
    private static let filePath = "/w/src/main.swift"
    private static let sessionPath = "/w/session.jsonl"

    @Test("a file tab offers its file")
    func fileTabOffersItsFile() {
        let content = PaneContent.codeViewer(id: UUID(), path: Self.filePath)

        let target = WorkspaceTabFileMenu.target(for: content, transcriptPath: { _ in Self.sessionPath })

        let expected = HeaderMenuTarget(path: Self.filePath, copyLabel: "Copy Path")
        #expect(target == expected)
    }

    @Test("a transcript tab offers the session file of the terminal it follows")
    func transcriptTabOffersItsSessionFile() {
        let terminalID = UUID()
        let content = PaneContent.liveTranscript(id: UUID(), terminalID: terminalID)

        // Only the followed terminal has a session file, so a lookup by any
        // other ID finds none.
        let target = WorkspaceTabFileMenu.target(
            for: content, transcriptPath: { $0 == terminalID ? Self.sessionPath : nil })

        let expected = HeaderMenuTarget(path: Self.sessionPath, copyLabel: "Copy Conversation Path")
        #expect(target == expected)
    }

    @Test("a transcript tab whose terminal has no session file yet offers none")
    func transcriptTabWithoutSessionFileOffersNone() {
        let content = PaneContent.liveTranscript(id: UUID(), terminalID: UUID())

        let withoutPath = WorkspaceTabFileMenu.target(for: content, transcriptPath: { _ in nil })
        let withEmptyPath = WorkspaceTabFileMenu.target(for: content, transcriptPath: { _ in "" })

        #expect(withoutPath == nil)
        #expect(withEmptyPath == nil)
    }

    @Test("terminal, note and web tabs offer none, whatever the session files say")
    func otherTabsOfferNone() throws {
        let pageURL = try #require(URL(string: "https://example.com/docs"))
        let others: [PaneContent] = [
            .terminal(terminalID: UUID()),
            .note(noteID: UUID()),
            .webview(id: UUID(), url: pageURL),
        ]

        for content in others {
            let target = WorkspaceTabFileMenu.target(for: content, transcriptPath: { _ in Self.sessionPath })
            #expect(target == nil, "\(content)")
        }
    }
}
