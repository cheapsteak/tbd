import AppKit
import Testing
@testable import TBDApp

/// The bubble text view's link-click routing: URL in, typed destination out.
@MainActor
struct TranscriptLinkClickRoutingTests {
    @Test func tbdFileURL_routesToAFileTarget() {
        let url = TranscriptLinkPass.fileURL(forResolvedPath: "/w/docs/a.md")!
        #expect(TranscriptLinkTarget(url: url) == .file("/w/docs/a.md"))
    }

    @Test func pathWithSpaces_survivesTheRoundTrip() {
        let url = TranscriptLinkPass.fileURL(forResolvedPath: "/w/My Docs/a.md")!
        #expect(TranscriptLinkTarget(url: url) == .file("/w/My Docs/a.md"))
    }

    @Test func httpsURL_routesToAWebTarget() {
        let url = URL(string: "https://example.com/x")!
        #expect(TranscriptLinkTarget(url: url) == .web(url))
    }

    @Test func fileURL_routesToAFileTarget() {
        let url = URL(fileURLWithPath: "/w/docs/a.md")
        #expect(TranscriptLinkTarget(url: url) == .file("/w/docs/a.md"))
    }

    @Test func mailtoURL_isNotRouted() {
        #expect(TranscriptLinkTarget(url: URL(string: "mailto:a@b.c")!) == nil)
    }

    // MARK: - The delegate's two branches

    @Test func clickedLink_handsTheTargetToTheClosure() {
        let view = TranscriptBubbleTextView(frame: .zero)
        var received: [TranscriptLinkTarget] = []
        view.onLinkClicked = { received.append($0) }
        let url = TranscriptLinkPass.fileURL(forResolvedPath: "/w/docs/a.md")!
        #expect(view.textView(view, clickedOnLink: url, at: 0) == true)
        #expect(received == [.file("/w/docs/a.md")])
    }

    // The gated branch: with no closure the link is inert, and the click is
    // still SWALLOWED. Returning false here would hand `tbd-file:` to
    // NSWorkspace, which has no handler for the scheme — inert must mean
    // nothing happens, not "something else happens".
    @Test func clickedLink_withNoHandler_isInertAndStillSwallowed() {
        let view = TranscriptBubbleTextView(frame: .zero)
        view.onLinkClicked = nil
        let url = TranscriptLinkPass.fileURL(forResolvedPath: "/w/docs/a.md")!
        #expect(view.textView(view, clickedOnLink: url, at: 0) == true)
    }
}
