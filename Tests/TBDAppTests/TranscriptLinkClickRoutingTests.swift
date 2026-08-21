import AppKit
import Foundation
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

    // A `file://` URL reaches the delegate straight from markdown the agent
    // wrote — nothing resolved it during the render pass — so it earns the
    // same existence check a scanner-derived candidate gets. The three cases
    // below are that check.
    @Test func fileURL_toAnExistingFile_routesToAFileTarget() throws {
        try withTempTree { root in
            let url = URL(fileURLWithPath: root + "/sub/f.md")
            #expect(TranscriptLinkTarget(url: url) == .file(root + "/sub/f.md"))
        }
    }

    @Test func fileURL_toANonexistentPath_isNotRouted() throws {
        try withTempTree { root in
            #expect(TranscriptLinkTarget(url: URL(fileURLWithPath: root + "/nope.md")) == nil)
        }
    }

    // A directory is not something the viewer can open, and `NSWorkspace`
    // would happily reveal it — so it is a miss, not a file.
    @Test func fileURL_toADirectory_isNotRouted() throws {
        try withTempTree { root in
            #expect(TranscriptLinkTarget(url: URL(fileURLWithPath: root + "/sub")) == nil)
        }
    }

    // The `tbd-file:` branch carries a path the render pass ALREADY checked
    // against the filesystem. Re-checking it would put a `stat()` on every
    // click for an answer that is already known, so the predicate must not be
    // consulted at all.
    @Test func tbdFileURL_isNotRestatted() {
        let url = TranscriptLinkPass.fileURL(forResolvedPath: "/w/docs/a.md")!
        var asked: [String] = []
        let target = TranscriptLinkTarget(url: url, isReadableFile: { path in
            asked.append(path)
            return false
        })
        #expect(target == .file("/w/docs/a.md"))
        #expect(asked.isEmpty)
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

    // The `return false` branch is the ONLY thing that lets a scheme the
    // transcript does not route — `mailto:`, and anything else a markdown link
    // can carry — reach AppKit's default handling. Swallowing it would make
    // those links silently dead.
    @Test func clickedUnroutableLink_fallsThroughToAppKit() {
        let view = TranscriptBubbleTextView(frame: .zero)
        var received: [TranscriptLinkTarget] = []
        view.onLinkClicked = { received.append($0) }
        #expect(view.textView(view, clickedOnLink: URL(string: "mailto:a@b.c")!, at: 0) == false)
        #expect(received.isEmpty)
    }

    // AppKit passes whatever the `.link` attribute holds, and a string is a
    // legal value for it, so the delegate parses that shape too.
    @Test func clickedLink_asAString_isParsedAndRouted() {
        let view = TranscriptBubbleTextView(frame: .zero)
        var received: [TranscriptLinkTarget] = []
        view.onLinkClicked = { received.append($0) }
        let link = TranscriptLinkPass.fileURL(forResolvedPath: "/w/docs/a.md")!.absoluteString
        #expect(view.textView(view, clickedOnLink: link, at: 0) == true)
        #expect(received == [.file("/w/docs/a.md")])
    }

    @Test func clickedLink_asAnUnparseableValue_fallsThroughToAppKit() {
        let view = TranscriptBubbleTextView(frame: .zero)
        view.onLinkClicked = { _ in Issue.record("must not route") }
        #expect(view.textView(view, clickedOnLink: NSNumber(value: 7), at: 0) == false)
    }

    // A markdown-authored `file://` link to nothing must reach AppKit's
    // default handling rather than being swallowed as a route to a file that
    // is not there.
    @Test func clickedFileURL_thatNamesNothing_fallsThroughToAppKit() throws {
        try withTempTree { root in
            let view = TranscriptBubbleTextView(frame: .zero)
            view.onLinkClicked = { _ in Issue.record("must not route") }
            let url = URL(fileURLWithPath: root + "/nope.md")
            #expect(view.textView(view, clickedOnLink: url, at: 0) == false)
        }
    }

    // MARK: -

    /// Builds `<tmp>/sub/` with `<tmp>/sub/f.md` inside it, then removes it.
    private func withTempTree(_ body: (String) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TranscriptLinkClickRouting-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("f.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.path)
    }
}
