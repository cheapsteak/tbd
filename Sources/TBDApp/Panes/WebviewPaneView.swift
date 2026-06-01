import SwiftUI
import WebKit

@MainActor
protocol WebviewFindClient: AnyObject {
    func find(_ string: String, backwards: Bool, completionHandler: @escaping (Bool) -> Void)
}

@MainActor
protocol WebviewReloadClient: AnyObject {
    func reload()
}

extension WKWebView: WebviewFindClient {
    func find(_ string: String, backwards: Bool, completionHandler: @escaping (Bool) -> Void) {
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        find(string, configuration: config) { result in
            completionHandler(result.matchFound)
        }
    }
}

extension WKWebView: WebviewReloadClient {
    func reload() {
        // Disambiguate from WKWebView.reload() -> WKNavigation? — calling
        // reload() inside this extension would recurse, so route through a
        // typed reference to the original method.
        let webkitReload: (WKWebView) -> () -> WKNavigation? = WKWebView.reload
        _ = webkitReload(self)()
    }
}

@MainActor
final class WebviewState: ObservableObject {
    @Published var currentURL: URL?
}

struct WebviewPaneView: NSViewRepresentable {
    let url: URL
    let state: WebviewState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> WebviewPaneHostView {
        let host = WebviewPaneHostView(url: url)
        host.webView.navigationDelegate = context.coordinator
        context.coordinator.observe(host.webView)
        return host
    }

    func updateNSView(_ host: WebviewPaneHostView, context: Context) {
        // Don't reload on SwiftUI updates — only initial load matters
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let state: WebviewState
        private var urlObservation: NSKeyValueObservation?

        init(state: WebviewState) {
            self.state = state
        }

        func observe(_ webView: WKWebView) {
            urlObservation = webView.observe(\.url, options: [.initial, .new]) { [weak state] webView, _ in
                let newURL = webView.url
                Task { @MainActor in state?.currentURL = newURL }
            }
        }
    }
}

final class WebviewPaneHostView: NSView, NSUserInterfaceValidations {
    let webView: WKWebView
    let findBar = WebviewFindBarView()

    private static let supportedTextFinderActions: Set<NSTextFinder.Action> = [
        .showFindInterface,
        .hideFindInterface,
        .nextMatch,
        .previousMatch,
    ]

    private let findClient: WebviewFindClient
    private let reloadClient: WebviewReloadClient

    init(url: URL, findClient: WebviewFindClient? = nil, reloadClient: WebviewReloadClient? = nil) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: config)
        self.findClient = findClient ?? webView
        self.reloadClient = reloadClient ?? webView

        super.init(frame: .zero)

        addSubview(webView)
        addSubview(findBar)
        findBar.isHidden = true
        findBar.onQueryChanged = { [weak self] query in
            self?.search(query, backwards: false)
        }
        findBar.onSubmit = { [weak self] backwards in
            self?.search(self?.findBar.searchField.stringValue ?? "", backwards: backwards)
        }
        findBar.onClose = { [weak self] in
            self?.hideFindBar()
        }
        webView.load(URLRequest(url: url))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // performKeyEquivalent walks the whole view hierarchy, so without this
        // guard an unfocused webview pane would steal Cmd+R from whichever
        // pane the user actually clicked. The first responder is normally the
        // WKWebView or one of its descendants, not the host itself — walk up
        // from the first responder and only handle when self is an ancestor.
        guard isFirstResponderInHierarchy() else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        guard event.charactersIgnoringModifiers?.lowercased() == "r" else {
            return super.performKeyEquivalent(with: event)
        }
        reloadClient.reload()
        return true
    }

    private func isFirstResponderInHierarchy() -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        var current: NSView? = responder
        while let view = current {
            if view === self { return true }
            current = view.superview
        }
        return false
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard let action = textFinderAction(from: sender) else { return }
        switch action {
        case .showFindInterface:
            showFindBar()
        case .nextMatch:
            search(findBar.searchField.stringValue, backwards: false)
        case .previousMatch:
            search(findBar.searchField.stringValue, backwards: true)
        case .hideFindInterface:
            hideFindBar()
        default:
            return
        }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let action = textFinderAction(from: item) else { return false }
        return Self.supportedTextFinderActions.contains(action)
    }

    func showFindBar() {
        findBar.isHidden = false
        needsLayout = true
        window?.makeFirstResponder(findBar.searchField)
        findBar.searchField.selectText(nil)
    }

    func hideFindBar() {
        findBar.isHidden = true
        needsLayout = true
        window?.makeFirstResponder(webView)
    }

    override func layout() {
        super.layout()

        webView.frame = bounds

        let margin: CGFloat = 10
        let barSize = findBar.fittingSize
        findBar.frame = CGRect(
            x: max(margin, bounds.maxX - barSize.width - margin),
            y: max(margin, bounds.maxY - barSize.height - margin),
            width: barSize.width,
            height: barSize.height
        )
    }

    private func textFinderAction(from sender: Any?) -> NSTextFinder.Action? {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        return NSTextFinder.Action(rawValue: tag)
    }

    private func search(_ query: String, backwards: Bool) {
        guard !query.isEmpty else { return }
        findClient.find(query, backwards: backwards) { [weak self] matchFound in
            self?.findBar.setMatchFound(matchFound)
        }
    }
}

final class WebviewFindBarView: NSVisualEffectView, NSSearchFieldDelegate {
    let searchField = NSSearchField()

    var onQueryChanged: ((String) -> Void)?
    var onSubmit: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        searchField.placeholderString = "Find"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldSubmitted)

        configureButton(previousButton, symbolName: "chevron.up", action: #selector(previous))
        configureButton(nextButton, symbolName: "chevron.down", action: #selector(next))
        configureButton(closeButton, symbolName: "xmark", action: #selector(close))

        [searchField, previousButton, nextButton, closeButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        NSSize(width: 330, height: 38)
    }

    override func layout() {
        super.layout()

        let height: CGFloat = 28
        let buttonSize = NSSize(width: 28, height: height)
        let padding: CGFloat = 6
        let y = (bounds.height - height) / 2
        let closeX = bounds.maxX - padding - buttonSize.width
        let nextX = closeX - buttonSize.width
        let previousX = nextX - buttonSize.width

        closeButton.frame = CGRect(origin: CGPoint(x: closeX, y: y), size: buttonSize)
        nextButton.frame = CGRect(origin: CGPoint(x: nextX, y: y), size: buttonSize)
        previousButton.frame = CGRect(origin: CGPoint(x: previousX, y: y), size: buttonSize)
        searchField.frame = CGRect(
            x: padding,
            y: y,
            width: max(80, previousX - padding - 6),
            height: height
        )
    }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onClose?()
        return true
    }

    func submit(backwards: Bool) {
        onSubmit?(backwards)
    }

    func setMatchFound(_ matchFound: Bool) {
        searchField.textColor = matchFound ? .labelColor : .systemRed
    }

    private func configureButton(_ button: NSButton, symbolName: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.target = self
        button.action = action
    }

    @objc private func previous() {
        submit(backwards: true)
    }

    @objc private func next() {
        submit(backwards: false)
    }

    @objc private func close() {
        onClose?()
    }

    @objc private func searchFieldSubmitted() {
        submit(backwards: false)
    }
}
