import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Visibility of the tab context menu's "Copy Attach Command" item, and the
/// terminal it targets. The item exists to hand the user a tmux attach command
/// for *this tab's* terminal, so a tab with no terminal behind it must not
/// offer it — there is no tmux window for an external emulator to attach to,
/// and the daemon RPC it calls takes a terminal id that would not exist.
///
/// The assertions go through `TabTerminalTarget.terminalID(for:)` because that
/// is literally the menu's gate: `contextMenuContent` writes
/// `if let attachTerminalID = TabTerminalTarget.terminalID(for: tab.content)`,
/// so a nil here is the button's absence and a value is both its presence and
/// the id it sends. There is no boolean twin to assert on — one would be a
/// second rule these tests could hold green while the menu's own drifted.
@Suite("Copy Attach Command menu visibility")
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

    @Test("tabs with no terminal behind them offer no attach command")
    func nonTerminalTabsAreHidden() {
        let webview = PaneContent.webview(
            id: UUID(), url: URL(string: "https://example.com")!)
        let codeViewer = PaneContent.codeViewer(id: UUID(), path: "/tmp/file.swift")
        let note = PaneContent.note(noteID: UUID())

        for content in [webview, codeViewer, note] {
            #expect(TabTerminalTarget.terminalID(for: content) == nil)
        }
    }
}
