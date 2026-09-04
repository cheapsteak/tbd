import AppKit
import os
import SwiftUI
import WebKit

private let logger = Logger(subsystem: "com.tbd.app", category: "markdown")

/// What to do with a navigation the webview is about to perform.
enum MarkdownNavigationPolicy: Equatable {
    /// Render in place: our own document load, or a same-document anchor.
    case allowInPlace
    /// Hand to `NSWorkspace.open` and cancel in place.
    case openExternally(URL)
    /// Render this local markdown file in the code-viewer pane itself, the way
    /// selecting it in the sidebar would. Never leaves the app.
    case openInPane(URL)
    /// Reveal in Finder WITHOUT launching. `file:` URLs never get `open`.
    case revealInFinder(URL)
    /// Drop silently.
    case cancel
}

enum MarkdownWebViewConfiguration {

    /// Hardened configuration. Deliberately registers NO URL scheme handler:
    /// a registered handler becomes reachable from any script once JavaScript
    /// is enabled in a later slice, so local images are inlined as `data:`
    /// URIs instead.
    @MainActor
    static func make() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        return config
    }

    /// Extensions the code-viewer pane can render in place.
    ///
    /// Single source of truth: `isRenderableFile` in `CodeViewerPaneView`
    /// reads the same set, so the pane can always render whatever a link
    /// routed to it.
    static let renderableExtensions: Set<String> = ["md", "markdown"]

    /// Is this a local file the pane itself renders?
    static func isRenderableMarkdown(_ url: URL) -> Bool {
        renderableExtensions.contains(url.pathExtension.lowercased())
    }

    /// Does this URL have the shape of a document we loaded ourselves?
    ///
    /// Conjoined with the outstanding-load counter, this is what decides WHO
    /// is trusted — the more security-relevant half of the decision. Hoisted
    /// out of the delegate so it is unit-testable: the delegate method is
    /// `@MainActor` and its callback never fires under bare `swift test`
    /// (no app bundle / WindowServer).
    static func isOwnLoadShaped(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.scheme?.lowercased() == "about"
            && url.host == nil
            && url.fragment == nil
    }

    /// Pure navigation decision, extracted so the awkward URL shapes are
    /// unit-testable instead of live-only.
    ///
    /// `isOwnLoad` is tracked by the coordinator around its own
    /// `loadHTMLString` calls. It is NOT inferred from the URL's scheme: with
    /// `baseURL: nil` our document is `about:blank`, and a protocol-relative
    /// link resolves to `about://host/...`, so scheme alone cannot tell our
    /// trusted load from attacker-influenced markup.
    ///
    /// `isLinkActivation` gates everything that leaves the app. Without it a
    /// `<meta http-equiv="refresh">` — which fires even with JavaScript
    /// disabled — would launch an external app on render, with no gesture.
    static func policy(
        for url: URL?,
        isOwnLoad: Bool,
        isLinkActivation: Bool
    ) -> MarkdownNavigationPolicy {
        if isOwnLoad { return .allowInPlace }
        guard let url else { return .cancel }
        let scheme = url.scheme?.lowercased()

        // Same-document anchor: exactly `about:blank#fragment`. Comparing the
        // fragment-stripped string (rather than just "has a fragment, no
        // host") rejects `about://#frag`, which satisfies the loose shape but
        // is not same-document and would blank the pane.
        if scheme == "about", url.fragment != nil {
            var stripped = URLComponents(url: url, resolvingAgainstBaseURL: false)
            stripped?.fragment = nil
            return stripped?.string?.lowercased() == "about:blank" ? .allowInPlace : .cancel
        }

        // Everything past here leaves the app, so require a real gesture.
        guard isLinkActivation else { return .cancel }

        switch scheme {
        case "http", "https", "mailto":
            return .openExternally(url)
        case "file":
            // A relative link that `MarkdownLinkResolver` rewrote — the only
            // way a file: URL reaches here. An explicit `file:` destination in
            // the markdown source cannot: comrak's safe mode empties the href
            // for `file:`, `data:`, `javascript:` and `vbscript:`, so the
            // anchor arrives with nothing to navigate to. Markdown navigates
            // the pane — in-app, so no launch decision is involved at all.
            //
            // This function is pure and knows no worktree, so it cannot judge
            // WHICH file. Containment is re-judged on the consuming side, by
            // `MarkdownLinkNavigation.target(for:worktreeRoot:)`, against the
            // same rule the resolver applied — that check, not comrak's safe
            // mode, is what keeps a file outside the worktree from rendering
            // in the pane.
            //
            // `isLinkActivation` means "a real gesture" only while JavaScript
            // is off on this path, which it unconditionally is today. Enabling
            // it for `renderMermaidDiagrams` (see
            // `docs/specs/2026-07-28-markdown-display-options-design.md`)
            // ends that: `document.querySelector('a').click()` produces
            // navigationType `.linkActivated`, so a script in the rendered
            // document could drive this route — and `.openExternally` —
            // without the user touching anything. Whoever lands mermaid needs
            // a gesture signal that a script cannot forge.
            if isRenderableMarkdown(url) { return .openInPane(url) }
            // NEVER `NSWorkspace.open` a file: URL. `git clone` sets only
            // com.apple.provenance, not com.apple.quarantine (verified), so a
            // .app/.command/.terminal inside a freshly cloned repo would
            // launch with Gatekeeper never consulted. Reveal it instead.
            return .revealInFinder(url)
        default:
            // Allowlist, not blocklist. smb:/afp:/nfs: mount against an
            // attacker-chosen host and prompt for credentials; tbd:// drives
            // our own deep-link handler; any installed app can claim a scheme.
            return .cancel
        }
    }
}

/// Hardened webview for rendered markdown.
///
/// JavaScript is disabled, no script message handlers are installed, the data
/// store is non-persistent, and there is no URL scheme handler. Navigation is
/// four-way: our own load and same-document anchors render in place, a link to
/// a repo-local markdown file navigates the enclosing pane, allowed schemes
/// leave via `NSWorkspace` on a real click, everything else is dropped. See
/// `MarkdownNavigationPolicy`.
struct MarkdownWebView: NSViewRepresentable {
    let html: String
    /// Invoked when a link resolves to a repo-local markdown file. The pane
    /// owns the selection, so it decides what "navigate" means.
    let onOpenFile: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: MarkdownWebViewConfiguration.make())
        webView.navigationDelegate = context.coordinator
        context.coordinator.onOpenFile = onOpenFile
        // Supported API. `setValue(false, forKey: "drawsBackground")` is
        // private KVC; if the key ever disappears it raises an ObjC exception
        // that Swift cannot catch, crashing on the render path.
        webView.underPageBackgroundColor = .clear
        // No `appearance` override here: leave it nil so WebKit resolves
        // `prefers-color-scheme` from the system's `effectiveAppearance`,
        // not a pinned one. The surrounding SwiftUI pane applies
        // `.colorScheme(.dark)`, but that does not propagate into WebKit —
        // a SwiftUI color scheme is invisible to it. This used to be pinned
        // to `.darkAqua` to match, back when the stylesheet had a
        // transparent `--md-bg` and relied on the (unconditionally dark)
        // pane showing through. The stylesheet now paints its own opaque
        // ground in both schemes, so the document should follow the user's
        // system appearance instead.
        context.coordinator.load(html, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Refreshed BEFORE the equality guard: an unchanged document still
        // needs the latest closure, which captures the current pane state.
        context.coordinator.onOpenFile = onOpenFile
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.load(html, into: webView)
    }

    /// Take whatever the container offers instead of being sized by content.
    ///
    /// `WKWebView` reports `NSView.noIntrinsicMetric` on both axes and has no
    /// internal constraints, so the default representable sizing — which falls
    /// back to `intrinsicContentSize`/`fittingSize` — resolves it to zero and
    /// the pane renders empty. The document scrolls inside the webview, so
    /// "fill the offer" is also the correct behavior, not just the non-zero one.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: WKWebView, context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private(set) var loadedHTML: String?

        /// Set by `makeNSView`/`updateNSView`. Optional so a `Coordinator` can
        /// still be constructed bare in tests.
        var onOpenFile: ((URL) -> Void)?

        /// Counter, not a Bool. WebKit delivers one policy callback per
        /// `loadHTMLString`, so two loads dispatched before the first callback
        /// round-trips would collapse into a single Bool — cancelling the
        /// newer load and leaving the pane on stale content that
        /// `updateNSView`'s equality guard then prevents recovering from.
        private var pendingOwnLoads = 0

        func load(_ html: String, into webView: WKWebView) {
            loadedHTML = html
            noteOwnLoadForTesting()
            webView.loadHTMLString(html, baseURL: nil)
        }

        /// Claims a slot for a `loadHTMLString` call that's about to happen.
        /// Named for tests: it's the one seam that lets a test construct a
        /// `Coordinator` and exercise `consumeOwnLoad` without a real
        /// `WKWebView`, whose navigation callbacks don't fire under bare
        /// `swift test` anyway.
        func noteOwnLoadForTesting() {
            pendingOwnLoads += 1
        }

        /// Claim an outstanding own-load slot, if this navigation looks like
        /// one. Belt and braces: either check alone is insufficient — the
        /// counter can drift, and URL shape alone cannot identify us — but
        /// conjoined, a stolen slot can only ever be spent rendering
        /// `about:blank` in place, never on an external open.
        ///
        /// Deliberately NOT decremented for a foreign callback: the counter
        /// means "N own loads outstanding", not "the next N callbacks are
        /// mine", so a user's link click arriving mid-load must leave the
        /// slot reserved for the load that claimed it.
        func consumeOwnLoad(for url: URL?) -> Bool {
            guard pendingOwnLoads > 0,
                  MarkdownWebViewConfiguration.isOwnLoadShaped(url) else { return false }
            pendingOwnLoads -= 1
            return true
        }

        /// The annotation set on `decisionHandler` must match WebKit's modern
        /// declaration EXACTLY. A near-match compiles and still dispatches at
        /// runtime, but emits a "nearly matches optional requirement" warning
        /// whose two offered fix-its (`private`, or move-to-extension) would
        /// drop the `@objc` exposure and turn this whole allowlist into dead
        /// code — silently, since `decidePolicyFor` never fires under
        /// `swift test`.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let isOwnLoad = consumeOwnLoad(for: url)

            switch MarkdownWebViewConfiguration.policy(
                for: url,
                isOwnLoad: isOwnLoad,
                isLinkActivation: navigationAction.navigationType == .linkActivated
            ) {
            case .allowInPlace:
                decisionHandler(.allow)
            case .openExternally(let target):
                NSWorkspace.shared.open(target)
                decisionHandler(.cancel)
            case .openInPane(let target):
                if let onOpenFile {
                    onOpenFile(target)
                } else {
                    logger.debug(
                        "no in-pane handler for \(target.path, privacy: .public)")
                }
                decisionHandler(.cancel)
            case .revealInFinder(let target):
                NSWorkspace.shared.activateFileViewerSelecting([target])
                decisionHandler(.cancel)
            case .cancel:
                decisionHandler(.cancel)
            }
        }
    }
}
