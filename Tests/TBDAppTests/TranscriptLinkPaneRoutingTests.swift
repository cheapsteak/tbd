import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

/// Where a clicked transcript link lands, per render site: the live pane routes
/// into the panel layout, History reveals in Finder.
@MainActor
struct TranscriptLinkPaneRoutingTests {
    private func transcriptLayout(terminalID: UUID, transcriptID: UUID) -> LayoutNode {
        .split(
            id: UUID(),
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .pane(.liveTranscript(id: transcriptID, terminalID: terminalID))
            ],
            ratios: [0.5, 0.5]
        )
    }

    // MARK: - The routing primitive these decisions rest on

    // A click in the transcript, with no code viewer open, swaps the transcript
    // pane for the file — the chosen behavior. See the spec's click-plumbing
    // section for why the transcript is an acceptable casualty.
    @Test func clickWithNoCodeViewer_replacesTheTranscriptPane() {
        let terminalID = UUID()
        let transcriptID = UUID()
        let layout = transcriptLayout(terminalID: terminalID, transcriptID: transcriptID)
        let result = routeFileClick(into: layout, terminalID: terminalID, path: "/w/a.md")
        #expect(result.replaced?.paneID == transcriptID)
        if case .codeViewer(_, let path)? = result.replaced?.incoming {
            #expect(path == "/w/a.md")
        } else {
            Issue.record("expected a codeViewer to replace the transcript pane")
        }
    }

    @Test func clickWithACodeViewerOpen_reusesThatPane() {
        let terminalID = UUID()
        let viewerID = UUID()
        let layout = LayoutNode.split(
            id: UUID(),
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .pane(.codeViewer(id: viewerID, path: "/w/old.md"))
            ],
            ratios: [0.5, 0.5]
        )
        let result = routeFileClick(into: layout, terminalID: terminalID, path: "/w/new.md")
        #expect(result.replaced?.paneID == viewerID)
    }

    // MARK: - The two panes decide differently

    @Test func liveDestination_forAFile_replacesAPaneInTheLayout() {
        let terminalID = UUID()
        let transcriptID = UUID()
        let layout = transcriptLayout(terminalID: terminalID, transcriptID: transcriptID)
        let destination = TranscriptLinkDestination.live(
            .file("/w/a.md"), layout: layout, terminalID: terminalID)
        guard case .route(let result) = destination else {
            Issue.record("expected a layout route"); return
        }
        #expect(result.replaced?.paneID == transcriptID)
    }

    @Test func liveDestination_forAURL_leavesTheApp() {
        let url = URL(string: "https://example.com/x")!
        let destination = TranscriptLinkDestination.live(
            .web(url), layout: .pane(.terminal(terminalID: UUID())), terminalID: UUID())
        #expect(destination == .openInBrowser(url))
    }

    // History REVEALS. Opening would execute a resolved path that happens to be
    // a shell script, and transcript text is agent-authored.
    @Test func historyDestination_forAFile_revealsInFinder() {
        #expect(TranscriptLinkDestination.history(.file("/w/a.md"))
                == .revealInFinder("/w/a.md"))
    }

    // MARK: - The resolver each pane hands to the compose step

    private func withTempWorktree(_ body: (String) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TranscriptLinkPaneRouting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("a.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.path)
    }

    @Test func linkResolver_resolvesARelativeTokenUnderTheWorktree() throws {
        try withTempWorktree { root in
            let resolve = TranscriptLinkDestination.makeLinkResolver(
                worktreePath: root, cache: TranscriptLinkResolverCache())
            #expect(resolve("a.md") == root + "/a.md")
        }
    }

    // A remote worktree, or one whose row has not loaded, yields "" — and a
    // relative token then simply does not resolve.
    @Test func linkResolver_withNoWorktreePath_failsRelativeTokens() throws {
        try withTempWorktree { _ in
            let resolve = TranscriptLinkDestination.makeLinkResolver(
                worktreePath: "", cache: TranscriptLinkResolverCache())
            #expect(resolve("a.md") == nil)
        }
    }

    @Test func linkResolver_withNoWorktreePath_stillResolvesAbsoluteTokens() throws {
        try withTempWorktree { root in
            let resolve = TranscriptLinkDestination.makeLinkResolver(
                worktreePath: "", cache: TranscriptLinkResolverCache())
            #expect(resolve(root + "/a.md") == root + "/a.md")
        }
    }
}
