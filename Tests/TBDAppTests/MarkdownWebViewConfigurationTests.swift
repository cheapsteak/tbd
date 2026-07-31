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

    @Test("plain http is on the allowlist")
    func plainHTTPOpensExternally() {
        let url = URL(string: "http://example.com/x")!
        #expect(MarkdownWebViewConfiguration.policy(
            for: url, isOwnLoad: false, isLinkActivation: true) == .openExternally(url))
    }

    @Test("uppercase schemes are handled case-insensitively")
    func uppercaseSchemes() {
        let https = URL(string: "HTTPS://example.com/x")!
        #expect(MarkdownWebViewConfiguration.policy(
            for: https, isOwnLoad: false, isLinkActivation: true) == .openExternally(https))
        let file = URL(string: "FILE:///tmp/x")!
        #expect(MarkdownWebViewConfiguration.policy(
            for: file, isOwnLoad: false, isLinkActivation: true) == .revealInFinder(file))
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "SMB://evil.com/s"), isOwnLoad: false, isLinkActivation: true)
            == .cancel)
    }

    @Test("data: and javascript: hrefs are cancelled")
    func dangerousSchemesCancelled() {
        // comrak safe mode empties these today, so this is a tripwire against
        // a future renderer change rather than a live vector.
        for raw in ["data:text/html;base64,PGh0bWw+", "javascript:alert(1)"] {
            #expect(MarkdownWebViewConfiguration.policy(
                for: URL(string: raw), isOwnLoad: false, isLinkActivation: true) == .cancel)
        }
    }

    @Test("anchors are allowed without a click, deliberately bypassing the gesture gate")
    func anchorBypassesGestureGate() {
        // Documents the one intentional exception: same-document scrolling is
        // harmless and can be triggered without a link activation.
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "about:blank#x"), isOwnLoad: false, isLinkActivation: false)
            == .allowInPlace)
    }

    @Test("isOwnLoad short-circuits the allowlist entirely")
    func ownLoadShortCircuitsAllowlist() {
        // Contract documentation: policy trusts isOwnLoad completely, which is
        // exactly why the coordinator's shape conjunction is safety-critical.
        #expect(MarkdownWebViewConfiguration.policy(
            for: URL(string: "file:///etc/passwd"), isOwnLoad: true, isLinkActivation: false)
            == .allowInPlace)
    }

    // MARK: - Who is trusted. The counter + shape conjunction, hoisted out of
    // the delegate so it is testable without a WKWebView.

    @Test("own-load shapes are recognised, foreign ones are not")
    func ownLoadShapeRecognition() {
        #expect(MarkdownWebViewConfiguration.isOwnLoadShaped(nil))
        #expect(MarkdownWebViewConfiguration.isOwnLoadShaped(URL(string: "about:blank")))
        #expect(MarkdownWebViewConfiguration.isOwnLoadShaped(URL(string: "About:blank")))
        #expect(!MarkdownWebViewConfiguration.isOwnLoadShaped(URL(string: "about:blank#x")))
        #expect(!MarkdownWebViewConfiguration.isOwnLoadShaped(URL(string: "about://evil.com/x")))
        #expect(!MarkdownWebViewConfiguration.isOwnLoadShaped(URL(string: "https://example.com")))
    }

    @Test("a single load claims exactly one slot")
    func singleLoadBalances() {
        let c = MarkdownWebView.Coordinator()
        c.noteOwnLoadForTesting()
        #expect(c.consumeOwnLoad(for: URL(string: "about:blank")))
        #expect(!c.consumeOwnLoad(for: URL(string: "about:blank")))
    }

    @Test("two rapid loads each claim a slot")
    func doubleLoadBothClaim() {
        // The bug the counter replaced: a Bool collapsed these into one, so
        // the newer load was cancelled and the pane stuck on stale content.
        let c = MarkdownWebView.Coordinator()
        c.noteOwnLoadForTesting()
        c.noteOwnLoadForTesting()
        #expect(c.consumeOwnLoad(for: URL(string: "about:blank")))
        #expect(c.consumeOwnLoad(for: URL(string: "about:blank")))
        #expect(!c.consumeOwnLoad(for: URL(string: "about:blank")))
    }

    @Test("a link click mid-load does not steal the slot")
    func interleavedClickLeavesSlotReserved() {
        let c = MarkdownWebView.Coordinator()
        c.noteOwnLoadForTesting()
        // Foreign callback arrives first — must NOT consume.
        #expect(!c.consumeOwnLoad(for: URL(string: "https://example.com")))
        // The real load's callback still finds its slot.
        #expect(c.consumeOwnLoad(for: URL(string: "about:blank")))
    }

    @Test("the counter never goes negative")
    func counterNeverNegative() {
        let c = MarkdownWebView.Coordinator()
        #expect(!c.consumeOwnLoad(for: URL(string: "about:blank")))
        #expect(!c.consumeOwnLoad(for: nil))
        c.noteOwnLoadForTesting()
        #expect(c.consumeOwnLoad(for: URL(string: "about:blank")))
    }
}
