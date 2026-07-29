import AppKit
import SwiftUI
import WebKit

/// What to do with a navigation the webview is about to perform.
enum MarkdownNavigationPolicy: Equatable {
    /// Render in place: our own document load, or an in-page anchor.
    case allowInPlace
    /// Hand to `NSWorkspace` and cancel in place.
    case openExternally(URL)
    /// Drop silently.
    case cancel
}

/// Hardened webview for rendered markdown.
///
/// JavaScript is disabled, no script message handlers are installed, the data
/// store is non-persistent, and in-place navigation is denied — link clicks go
/// to `NSWorkspace`. There is deliberately no URL scheme handler: local images
/// arrive as `data:` URIs. See the spec's "Security posture" section.
enum MarkdownWebViewConfiguration {
    /// Factored out of the view so the security posture is unit-testable.
    /// Deliberately registers NO URL scheme handler — see the spec's
    /// "Local file resolution" section.
    @MainActor
    static func make() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        return config
    }

    /// Pure navigation decision, extracted so the awkward URL shapes are
    /// unit-testable instead of live-only.
    ///
    /// `isOwnLoad` is tracked by the coordinator around its own
    /// `loadHTMLString` calls. It is NOT inferred from the URL's scheme:
    /// with `baseURL: nil` our document is `about:blank`, and a
    /// protocol-relative link resolves to `about://host/...`, so scheme
    /// alone cannot tell our trusted load from attacker-influenced markup.
    static func policy(for url: URL?, isOwnLoad: Bool) -> MarkdownNavigationPolicy {
        if isOwnLoad { return .allowInPlace }
        guard let url else { return .cancel }

        // In-page anchor: about:blank#section — no host, has a fragment.
        // README tables of contents depend on these scrolling in place.
        if url.scheme == "about", url.host == nil, url.fragment != nil {
            return .allowInPlace
        }
        // Anything still on the about: scheme is either a bare reload or a
        // protocol-relative URL wearing about:// — neither is safe to hand
        // to NSWorkspace.
        guard let scheme = url.scheme?.lowercased(), scheme != "about" else {
            return .cancel
        }
        return .openExternally(url)
    }
}

struct MarkdownWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = MarkdownWebViewConfiguration.make()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(html, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.load(html, into: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?

        /// Set immediately before every `loadHTMLString` call this view makes
        /// itself, and consumed by the very next `decidePolicyFor` call. This
        /// is how the initial render (and any later reload when `html`
        /// changes) is distinguished from every other navigation, without
        /// inspecting the navigated-to URL at all.
        ///
        /// An earlier draft tried to recognize "our own load" by checking
        /// `navigationType == .other` and/or the request URL's scheme. That
        /// breaks on protocol-relative sources: `loadHTMLString(baseURL: nil)`
        /// gives the document base URL "about:blank", so a bare `//host/path`
        /// reference (no scheme of its own) resolves against that base to
        /// something like `about://host/path` — a URL with scheme "about",
        /// same as the initial load. Recognizing "about" scheme as "allow in
        /// place" would have let a click on such a link navigate in place
        /// instead of being routed out. Tracking our own loads explicitly
        /// sidesteps the ambiguity entirely.
        private var awaitingOwnLoad = false

        func load(_ html: String, into webView: WKWebView) {
            loadedHTML = html
            awaitingOwnLoad = true
            webView.loadHTMLString(html, baseURL: nil)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let isOwnLoad = awaitingOwnLoad
            awaitingOwnLoad = false

            switch MarkdownWebViewConfiguration.policy(
                for: navigationAction.request.url, isOwnLoad: isOwnLoad
            ) {
            case .allowInPlace:
                decisionHandler(.allow)
            case .openExternally(let url):
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            case .cancel:
                decisionHandler(.cancel)
            }
        }
    }
}
