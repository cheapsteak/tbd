import AppKit
import Foundation
import Testing
import TBDShared
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

    @Test("the off-main lookup returns empty for a non-existent file")
    func offMainLookupOfMissingFile() async {
        let missing = NSTemporaryDirectory() + "tbd-does-not-exist-\(UUID().uuidString).md"
        let apps = await lookUpOpenWithApps(forPath: missing)
        #expect(apps.isEmpty)
    }

    /// What one `openWithApps` call did, in a task cancelled at `cancelAt`.
    private struct LookupRun: Sendable {
        let apps: [OpenWithApp]
        let calls: [String]
    }

    /// Where `runLookup` cancels the task the lookup runs in.
    private enum CancelPoint: Sendable {
        case never
        case beforeTheFileCheck
        case afterTheFileCheck
    }

    private static let editorURL = URL(fileURLWithPath: "/Applications/Editor.app")

    /// Runs `openWithApps` on a task of its own over stand-ins for the disk
    /// and Launch Services, which report a file that exists and one app for
    /// it, cancelling the task at `cancelAt`.
    private static func runLookup(cancelAt: CancelPoint) async -> LookupRun {
        let editorURL = Self.editorURL
        return await Task.detached { () -> LookupRun in
            if cancelAt == .beforeTheFileCheck {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            var calls: [String] = []
            let apps = openWithApps(
                forPath: "/abs/foo.md",
                fileExists: { _ in
                    calls.append("fileExists")
                    if cancelAt == .afterTheFileCheck {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return true
                },
                applicationsToOpen: { _ in
                    calls.append("applicationsToOpen")
                    return [editorURL]
                })
            return LookupRun(apps: apps, calls: calls)
        }.value
    }

    @Test("openWithApps checks the file and queries Launch Services when its task is not cancelled")
    func uncancelledLookupRunsItsQuery() async {
        let run = await Self.runLookup(cancelAt: .never)
        let expectedCalls: [String] = ["fileExists", "applicationsToOpen"]
        let expectedApps: [OpenWithApp] = [OpenWithApp(url: Self.editorURL)]
        #expect(run.calls == expectedCalls)
        #expect(run.apps == expectedApps)
    }

    @Test("openWithApps in a cancelled task neither checks the file nor queries Launch Services")
    func cancelledLookupSkipsItsQuery() async {
        let run = await Self.runLookup(cancelAt: .beforeTheFileCheck)
        #expect(run.calls.isEmpty, "observed \(run.calls)")
        #expect(run.apps.isEmpty)
    }

    @Test("openWithApps cancelled after its file check skips the Launch Services query")
    func lookupCancelledAfterTheFileCheckSkipsTheQuery() async {
        let run = await Self.runLookup(cancelAt: .afterTheFileCheck)
        let expectedCalls: [String] = ["fileExists"]
        #expect(run.calls == expectedCalls)
        #expect(run.apps.isEmpty)
    }
}
