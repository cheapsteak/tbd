import Testing
import WebKit
@testable import TBDApp

@Suite("MarkdownWebViewConfiguration")
@MainActor
struct MarkdownWebViewConfigurationTests {

    @Test("JavaScript is disabled")
    func javaScriptDisabled() {
        let config = MarkdownWebViewConfiguration.make()
        #expect(config.defaultWebpagePreferences.allowsContentJavaScript == false)
    }

    @Test("data store is non-persistent")
    func nonPersistentStore() {
        let config = MarkdownWebViewConfiguration.make()
        #expect(config.websiteDataStore.isPersistent == false)
    }

    // MARK: - Navigation policy. Extracted as a pure function so the tricky
    // URL shapes are unit-testable rather than live-only.

    @Test("our own loadHTMLString renders in place")
    func ownLoadAllowed() {
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "about:blank"), isOwnLoad: true) == .allowInPlace)
    }

    @Test("in-page anchors scroll in place")
    func fragmentAnchorAllowed() {
        // A README table-of-contents link resolves to about:blank#section
        // against a nil baseURL. Cancelling these makes every TOC link in
        // every README silently do nothing.
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "about:blank#installation"), isOwnLoad: false) == .allowInPlace)
    }

    @Test("protocol-relative URLs are cancelled, never opened externally")
    func protocolRelativeCancelled() {
        // //evil.com/x.png has no scheme, so the image inliner leaves it
        // verbatim and it resolves to about://evil.com/x.png — scheme "about"
        // but WITH a host, unlike a fragment anchor. Handing that to
        // NSWorkspace would open something nonsensical.
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "about://evil.com/x.png"), isOwnLoad: false) == .cancel)
    }

    @Test("remote links open externally")
    func remoteOpensExternally() {
        let url = URL(string: "https://example.com/docs")!
        #expect(MarkdownWebViewConfiguration.policy(
            for: url, isOwnLoad: false) == .openExternally(url))
    }

    @Test("file links open externally")
    func fileOpensExternally() {
        let url = URL(string: "file:///tmp/notes.md")!
        #expect(MarkdownWebViewConfiguration.policy(
            for: url, isOwnLoad: false) == .openExternally(url))
    }

    @Test("a bare about: navigation that is not ours is cancelled")
    func bareAboutCancelled() {
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "about:blank"), isOwnLoad: false) == .cancel)
    }

    @Test("a nil URL is cancelled")
    func nilURLCancelled() {
        #expect(MarkdownWebViewConfiguration.policy(for: nil, isOwnLoad: false) == .cancel)
    }

    @Test("no URL scheme handler is registered for tbd-md")
    func noSchemeHandler() {
        let config = MarkdownWebViewConfiguration.make()
        #expect(config.urlSchemeHandler(forURLScheme: "tbd-md") == nil)
    }
}
