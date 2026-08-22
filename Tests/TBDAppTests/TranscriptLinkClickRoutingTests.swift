import AppKit
import Foundation
import Testing
@testable import TBDApp

/// The bubble text view's link-click routing: URL in, typed destination out.
@MainActor
struct TranscriptLinkClickRoutingTests {
    @Test func tbdFileURL_routesToAFileTarget() throws {
        try withTempTree { root in
            let path = root + "/sub/f.md"
            let url = TranscriptLinkPass.fileURL(forResolvedPath: path)!
            #expect(TranscriptLinkTarget(url: url) == .file(path))
        }
    }

    @Test func pathWithSpaces_survivesTheRoundTrip() throws {
        try withTempTree { root in
            let path = root + "/My Docs/a.md"
            let url = TranscriptLinkPass.fileURL(forResolvedPath: path)!
            #expect(TranscriptLinkTarget(url: url) == .file(path))
        }
    }

    @Test func httpsURL_routesToAWebTarget() {
        let url = URL(string: "https://example.com/x")!
        #expect(TranscriptLinkTarget(url: url) == .web(url))
    }

    // Every URL that reaches the delegate earns the same existence check, no
    // matter which scheme it wears or how it got there. `tbd-file:` is TBD's
    // own scheme, minted by the render pass for a path it resolved — but the
    // click path cannot see provenance, only a URL, so it checks. A `file://`
    // URL is the plain case: markdown the agent wrote can carry one and nothing
    // resolved it. Failing the check returns nil, which the delegate reports as
    // unhandled so AppKit's default handling takes the click.
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

    // A `tbd-file:` URL the render pass did NOT mint — hand-authored in
    // transcript markdown, which can be adversarial — names whatever its author
    // typed. The boundary check is what makes "a path links only if it names a
    // file that is there" true regardless of the URL's origin.
    @Test func tbdFileURL_toANonexistentPath_isNotRouted() throws {
        try withTempTree { root in
            let url = TranscriptLinkPass.fileURL(forResolvedPath: root + "/nope.md")!
            #expect(TranscriptLinkTarget(url: url) == nil)
        }
    }

    @Test func tbdFileURL_toADirectory_isNotRouted() throws {
        try withTempTree { root in
            let url = TranscriptLinkPass.fileURL(forResolvedPath: root + "/sub")!
            #expect(TranscriptLinkTarget(url: url) == nil)
        }
    }

    @Test func mailtoURL_isNotRouted() {
        #expect(TranscriptLinkTarget(url: URL(string: "mailto:a@b.c")!) == nil)
    }

    // MARK: - The delegate's two branches

    @Test func clickedLink_handsTheTargetToTheClosure() throws {
        try withTempTree { root in
            let view = TranscriptBubbleTextView(frame: .zero)
            var received: [TranscriptLinkTarget] = []
            view.onLinkClicked = { received.append($0) }
            let path = root + "/sub/f.md"
            let url = TranscriptLinkPass.fileURL(forResolvedPath: path)!
            #expect(view.textView(view, clickedOnLink: url, at: 0) == true)
            #expect(received == [.file(path)])
        }
    }

    // The gated branch: with no closure the link is inert, and the click is
    // still SWALLOWED. Returning false here would hand `tbd-file:` to
    // NSWorkspace, which has no handler for the scheme — inert must mean
    // nothing happens, not "something else happens".
    @Test func clickedLink_withNoHandler_isInertAndStillSwallowed() throws {
        try withTempTree { root in
            let view = TranscriptBubbleTextView(frame: .zero)
            view.onLinkClicked = nil
            let url = TranscriptLinkPass.fileURL(forResolvedPath: root + "/sub/f.md")!
            #expect(view.textView(view, clickedOnLink: url, at: 0) == true)
        }
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
    @Test func clickedLink_asAString_isParsedAndRouted() throws {
        try withTempTree { root in
            let view = TranscriptBubbleTextView(frame: .zero)
            var received: [TranscriptLinkTarget] = []
            view.onLinkClicked = { received.append($0) }
            let path = root + "/sub/f.md"
            let link = TranscriptLinkPass.fileURL(forResolvedPath: path)!.absoluteString
            #expect(view.textView(view, clickedOnLink: link, at: 0) == true)
            #expect(received == [.file(path)])
        }
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

    // The same fall-through for a hand-authored internal-scheme link: a
    // deceptively-labelled `tbd-file:` destination that names nothing must not
    // be routed into the viewer or revealed in Finder.
    @Test func clickedTbdFileURL_thatNamesNothing_fallsThroughToAppKit() throws {
        try withTempTree { root in
            let view = TranscriptBubbleTextView(frame: .zero)
            view.onLinkClicked = { _ in Issue.record("must not route") }
            let url = TranscriptLinkPass.fileURL(forResolvedPath: root + "/nope.md")!
            #expect(view.textView(view, clickedOnLink: url, at: 0) == false)
        }
    }

    // MARK: -

    /// Builds `<tmp>/sub/f.md` and `<tmp>/My Docs/a.md`, then removes the tree.
    private func withTempTree(_ body: (String) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TranscriptLinkClickRouting-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        let spaced = root.appendingPathComponent("My Docs")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("f.md"))
        try Data("x".utf8).write(to: spaced.appendingPathComponent("a.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.path)
    }
}
