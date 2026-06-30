import AppKit
import Foundation
import Testing
@testable import TBDApp

@Suite("Header file actions")
struct HeaderFileActionsTests {
    // MARK: headerMenuTarget

    @Test("codeViewer with a path → Copy Path target")
    func codeViewerTarget() {
        let content = PaneContent.codeViewer(id: UUID(), path: "/abs/foo.md")
        let target = headerMenuTarget(for: content, transcriptPath: nil)
        #expect(target == HeaderMenuTarget(path: "/abs/foo.md", copyLabel: "Copy Path"))
    }

    @Test("codeViewer with empty path → no target")
    func codeViewerEmptyPath() {
        let content = PaneContent.codeViewer(id: UUID(), path: "")
        #expect(headerMenuTarget(for: content, transcriptPath: nil) == nil)
    }

    @Test("liveTranscript with a transcript path → Copy Conversation Path target")
    func transcriptTarget() {
        let content = PaneContent.liveTranscript(id: UUID(), terminalID: UUID())
        let target = headerMenuTarget(for: content, transcriptPath: "/abs/session.jsonl")
        #expect(target == HeaderMenuTarget(path: "/abs/session.jsonl", copyLabel: "Copy Conversation Path"))
    }

    @Test("liveTranscript with nil/empty transcript path → no target")
    func transcriptNoPath() {
        let content = PaneContent.liveTranscript(id: UUID(), terminalID: UUID())
        #expect(headerMenuTarget(for: content, transcriptPath: nil) == nil)
        #expect(headerMenuTarget(for: content, transcriptPath: "") == nil)
    }

    @Test("non-file panes → no target")
    func otherPanesNoTarget() {
        #expect(headerMenuTarget(for: .terminal(terminalID: UUID()), transcriptPath: nil) == nil)
        #expect(headerMenuTarget(for: .note(noteID: UUID()), transcriptPath: nil) == nil)
        #expect(headerMenuTarget(for: .webview(id: UUID(), url: URL(string: "https://example.com")!), transcriptPath: nil) == nil)
    }

    // MARK: appDisplayName

    @Test("appDisplayName strips the .app extension")
    func displayName() {
        #expect(appDisplayName(for: URL(fileURLWithPath: "/Applications/Visual Studio Code.app")) == "Visual Studio Code")
        #expect(appDisplayName(for: URL(fileURLWithPath: "/System/Applications/TextEdit.app")) == "TextEdit")
    }

    // MARK: openWithApps

    @Test("openWithApps returns empty for a non-existent file")
    func openWithMissingFile() {
        let missing = NSTemporaryDirectory() + "tbd-does-not-exist-\(UUID().uuidString).md"
        #expect(openWithApps(forPath: missing).isEmpty)
    }
}
