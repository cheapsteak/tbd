import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Which terminal a tab's deep link is anchored to.
///
/// `TabBarItem.linkTerminalID` is `TabTerminalTarget.terminalID(for:)`, and
/// that value is what `DeepLink.makeShareableOpenURL` carries as the link's
/// `terminal` component — so a nil here is a link that names the worktree
/// alone, and a value is the tab the link reopens. Asserted through the
/// resolver rather than a rendered menu, so each branch is testable without
/// SwiftUI.
@Suite("Tab deep-link terminal anchor")
struct TabTerminalTargetTests {
    @Test("a terminal tab targets its own terminal")
    func terminalTabResolvesToItsTerminal() {
        let terminalID = UUID()
        let content = PaneContent.terminal(terminalID: terminalID)
        #expect(TabTerminalTarget.terminalID(for: content) == terminalID)
    }

    @Test("a live transcript tab targets the terminal it renders, not the pane")
    func liveTranscriptResolvesToItsTerminal() {
        let paneID = UUID()
        let terminalID = UUID()
        let content = PaneContent.liveTranscript(id: paneID, terminalID: terminalID)
        #expect(TabTerminalTarget.terminalID(for: content) == terminalID)
    }

    @Test("tabs with no terminal behind them anchor to no terminal")
    func nonTerminalTabsAnchorToNothing() {
        let webview = PaneContent.webview(
            id: UUID(), url: URL(string: "https://example.com")!)
        let codeViewer = PaneContent.codeViewer(id: UUID(), path: "/tmp/file.swift")
        let note = PaneContent.note(noteID: UUID())

        for content in [webview, codeViewer, note] {
            #expect(TabTerminalTarget.terminalID(for: content) == nil)
        }
    }
}
