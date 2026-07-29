import Testing
import WebKit
@testable import TBDApp

@Suite("MarkdownWebViewConfiguration")
@MainActor
struct MarkdownWebViewConfigurationTests {

    // MARK: - Security posture

    @Test("JavaScript is disabled")
    func javaScriptDisabled() {
        #expect(MarkdownWebViewConfiguration.make()
            .defaultWebpagePreferences.allowsContentJavaScript == false)
    }

    @Test("data store is non-persistent")
    func nonPersistentStore() {
        #expect(MarkdownWebViewConfiguration.make().websiteDataStore.isPersistent == false)
    }

    @Test("no URL scheme handler is registered for tbd-md")
    func noSchemeHandler() {
        // Tripwire. A registered handler becomes reachable from any script
        // once JS is enabled in a later slice, which is why local images are
        // inlined as data: URIs instead.
        #expect(MarkdownWebViewConfiguration.make()
            .urlSchemeHandler(forURLScheme: "tbd-md") == nil)
    }

    // MARK: - Navigation policy. Pure, so the awkward URL shapes are
    // unit-testable rather than live-only.

    @Test("our own loadHTMLString renders in place")
    func ownLoadAllowed() {
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "about:blank"), isOwnLoad: true, isLinkActivation: false)
            == .allowInPlace)
    }

    @Test("in-page anchors scroll in place")
    func fragmentAnchorAllowed() {
        // README tables of contents depend on these. Cancelling them makes
        // every TOC link in every README silently do nothing.
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "about:blank#installation"), isOwnLoad: false, isLinkActivation: true)
            == .allowInPlace)
    }

    @Test("anchor matching is case-insensitive on the scheme")
    func fragmentAnchorCaseInsensitive() {
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "About:blank#install"), isOwnLoad: false, isLinkActivation: true)
            == .allowInPlace)
    }

    @Test("about://#frag is not same-document and is cancelled")
    func hostlessAboutWithFragmentCancelled() {
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "about://#frag"), isOwnLoad: false, isLinkActivation: true)
            == .cancel)
    }

    @Test("protocol-relative URLs are cancelled, never opened externally")
    func protocolRelativeCancelled() {
        // //evil.com/x.png has no scheme, so the image inliner leaves it
        // verbatim and it resolves to about://evil.com/x.png — scheme "about"
        // but WITH a host, unlike a fragment anchor.
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "about://evil.com/x.png"), isOwnLoad: false, isLinkActivation: true)
            == .cancel)
    }

    @Test("remote links open externally when the user clicked")
    func remoteOpensExternally() {
        let url = URL(string: "https://example.com/docs")!
        #expect(MarkdownWebViewConfiguration.policy(
            for: url, isOwnLoad: false, isLinkActivation: true) == .openExternally(url))
    }

    @Test("remote navigation WITHOUT a click is cancelled")
    func autoNavigationCancelled() {
        // <meta http-equiv="refresh"> fires even with JavaScript disabled and
        // reports navigationType .other. Without the gesture gate it would
        // launch an external app on render, with no user action.
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "https://evil.example/beacon"), isOwnLoad: false,
            isLinkActivation: false) == .cancel)
    }

    @Test("mailto opens externally")
    func mailtoOpensExternally() {
        let url = URL(string: "mailto:someone@example.com")!
        #expect(MarkdownWebViewConfiguration.policy(
            for: url, isOwnLoad: false, isLinkActivation: true) == .openExternally(url))
    }

    @Test("file links reveal in Finder and are never launched")
    func fileRevealsRatherThanOpens() {
        // NSWorkspace.open on a file: URL launches it with its default app.
        // `git clone` sets only com.apple.provenance, NOT com.apple.quarantine
        // (verified), so a .app inside a freshly cloned repo would run with
        // Gatekeeper never consulted.
        let url = URL(string: "file:///tmp/notes.md")!
        #expect(MarkdownWebViewConfiguration.policy(
            for: url, isOwnLoad: false, isLinkActivation: true) == .revealInFinder(url))
    }

    @Test("network-mount schemes are cancelled")
    func mountSchemesCancelled() {
        // smb:/afp:/nfs: make Finder mount against an attacker-chosen host
        // and prompt for credentials.
        for raw in ["smb://evil.com/share", "afp://evil.com/share", "nfs://evil.com/x"] {
            #expect(MarkdownWebViewConfiguration.policy(
                for: URL(string: raw), isOwnLoad: false, isLinkActivation: true) == .cancel)
        }
    }

    @Test("TBD's own deep-link scheme is cancelled")
    func ownDeepLinkSchemeCancelled() {
        // A rendered README must not be able to drive TBD's URL handler.
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "tbd://open?worktree=1"), isOwnLoad: false, isLinkActivation: true)
            == .cancel)
    }

    @Test("a bare about: navigation that is not ours is cancelled")
    func bareAboutCancelled() {
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "about:blank"), isOwnLoad: false, isLinkActivation: true) == .cancel)
    }

    @Test("a nil URL is cancelled")
    func nilURLCancelled() {
        #expect(MarkdownWebViewConfiguration.policy(
            for: nil, isOwnLoad: false, isLinkActivation: true) == .cancel)
    }
}
