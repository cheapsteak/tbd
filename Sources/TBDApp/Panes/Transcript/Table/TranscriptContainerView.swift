import AppKit

/// The view `TableTranscriptView` hands SwiftUI: the transcript's scroll
/// view, inset from the leading edge by a fixed gutter, plus the prompt rail's
/// overlay stacked above it.
///
/// - **Gutter** – `leadingGutter` is `PromptRailLayout.width` with the rail
///   mounted and 0 without it, set once from the mount when the view is made.
///   The scroll view always fills the rest, so the table's width is fixed from
///   creation whatever the prompt count.
/// - **Overlay** – the rail view starts at the leading edge. With no lens it
///   is the gutter alone; while the rail has a lens (`wantsOpenWidth`) it is
///   as wide as the lens's box can grow plus room for its shadow
///   (`PromptRailRowMetrics.openOverlayWidth(paneWidth:)`), so it covers the
///   transcript's leading strip too. It draws over the transcript and answers
///   clicks and the wheel only over the rail column, and over the box while
///   the lens is open, so the table's width never changes on its account.
/// - **Stacking** – subview order settles it: the scroll view at the bottom,
///   the rail's overlay above it.
/// - **Coordinator** – a weak handle back to the table's coordinator, for
///   code that reaches the transcript through its view hierarchy.
/// - **Prompt rail** – `installPromptRail` makes this view the hub between
///   the rail and its hover model: the hover model's open and close reach the
///   rail as the lens's open state, and the Escape monitor runs only while
///   the rail reports the lens on screen — an open lens with no prompts is
///   not. The lens closes at once when this view leaves its window (a pane
///   rebuilt under a new identity, as on session rollover) or when that
///   window resigns key, so a lens in a background window never holds the
///   app-wide Escape monitor.
///
/// Coordinates are flipped (y grows downward), matching the table.
final class TranscriptContainerView: NSView {
    let scrollView: NSScrollView

    /// Width kept free on the leading edge for the rail.
    var leadingGutter: CGFloat {
        didSet {
            guard leadingGutter != oldValue else { return }
            layoutContent()
        }
    }

    weak var coordinator: TableTranscriptView.Coordinator?

    /// The rail's overlay, above the scroll view. Installed with the prompt
    /// rail.
    var railView: NSView? {
        didSet {
            guard railView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let railView { addSubview(railView, positioned: .above, relativeTo: nil) }
            layoutContent()
        }
    }

    // MARK: Prompt rail

    /// The hover model the rail feeds. Nil with no rail mounted.
    private(set) var promptRailHover: PromptRailHoverModel?
    private var promptRailEscape: PromptRailEscapeMonitor?
    private var promptRailNotificationCenter: NotificationCenter = .default
    /// The window whose resign-key notification is observed.
    private weak var observedKeyWindow: NSWindow?

    private var promptRailNSView: PromptRailNSView? { railView as? PromptRailNSView }

    init(scrollView: NSScrollView, leadingGutter: CGFloat) {
        self.scrollView = scrollView
        self.leadingGutter = leadingGutter
        super.init(frame: .zero)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// SwiftUI sizes this view by setting its frame; the subviews follow at
    /// once, so the table sees its final width in the same pass.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContent()
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    /// The scroll view takes everything right of the gutter; the rail's
    /// overlay starts at the leading edge, as wide as the rail column, or as
    /// the lens's box can grow while the rail has a lens. A gutter wider than
    /// the view leaves the scroll view zero wide rather than negative.
    private func layoutContent() {
        let gutter = min(max(leadingGutter, 0), bounds.width)
        let scrollFrame = NSRect(
            x: gutter, y: 0, width: bounds.width - gutter, height: bounds.height)
        if scrollView.frame != scrollFrame { scrollView.frame = scrollFrame }
        if let railView {
            var width = PromptRailLayout.width
            if let rail = railView as? PromptRailNSView {
                rail.boxMaxWidth = PromptRailRowMetrics.boxMaxWidth(paneWidth: bounds.width)
                if rail.wantsOpenWidth { width = PromptRailRowMetrics.openOverlayWidth(paneWidth: bounds.width) }
            }
            let railFrame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            if railView.frame != railFrame { railView.frame = railFrame }
        }
    }

    // MARK: Prompt rail wiring

    /// Mounts the prompt rail: `rail` as the overlay above the scroll view,
    /// driven by `hover`. Wheel events over the rail go to the transcript, the
    /// hover model's open state reaches the rail's lens, and the rail's lens
    /// reframes the overlay as it comes and goes.
    ///
    /// `escapeMonitor` and `notificationCenter` default to the production
    /// ones; tests pass their own to count installs and to post a resign-key
    /// notification without reaching `.default`'s other observers.
    func installPromptRail(
        rail: PromptRailNSView,
        hover: PromptRailHoverModel,
        escapeMonitor: PromptRailEscapeMonitor = PromptRailEscapeMonitor(),
        notificationCenter: NotificationCenter = .default
    ) {
        stopObservingKeyWindow()
        promptRailHover?.onOpenChange = nil
        promptRailNSView?.onLensShownChange = nil
        promptRailNSView?.onOpenWidthChange = nil
        promptRailEscape?.stop()

        promptRailHover = hover
        promptRailEscape = escapeMonitor
        promptRailNotificationCenter = notificationCenter
        rail.wheelTarget = scrollView
        rail.onLensShownChange = { [weak self] shown in self?.promptRailLensShownChanged(shown) }
        // A lens starting to open widens the overlay to take its box, and
        // one that has closed narrows it back to the gutter.
        rail.onOpenWidthChange = { [weak self] in self?.layoutContent() }
        railView = rail
        hover.onOpenChange = { [weak self] open in self?.promptRailNSView?.lensOpenChanged(open) }
        startObservingKeyWindow()
    }

    /// Runs the Escape monitor exactly while the lens is on screen. The rail
    /// reports hover with no prompts too, so the hover model can open a lens
    /// that has nothing to show; a monitor started then would take Escape
    /// from every view in the window — a terminal's interrupt among them —
    /// with nothing visible to dismiss. An open lens that gains its first
    /// prompt shows, and starts the monitor then.
    private func promptRailLensShownChanged(_ shown: Bool) {
        if shown {
            promptRailEscape?.start { [weak self] in self?.promptRailHover?.dismiss(.escape) }
        } else {
            promptRailEscape?.stop()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow !== window else { return }
        stopObservingKeyWindow()
        // Leaving the window — a pane torn down or rebuilt under a new
        // identity — closes the lens with it.
        promptRailHover?.closeNow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingKeyWindow()
        // An open that settled while the table was out of a window is reported
        // now that it is back in one. A turn later, because this can run
        // inside a SwiftUI update and the report writes the pane's state; the
        // coordinator checks the window again then.
        if window != nil, coordinator?.pendingOpenSettled != nil {
            DispatchQueue.main.async { [weak self] in
                self?.coordinator?.reportPendingOpenSettled()
            }
        }
    }

    private func startObservingKeyWindow() {
        guard promptRailHover != nil, let window, observedKeyWindow !== window else { return }
        stopObservingKeyWindow()
        promptRailNotificationCenter.addObserver(
            self,
            selector: #selector(promptRailWindowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window)
        observedKeyWindow = window
    }

    private func stopObservingKeyWindow() {
        guard let observedKeyWindow else { return }
        promptRailNotificationCenter.removeObserver(
            self, name: NSWindow.didResignKeyNotification, object: observedKeyWindow)
        self.observedKeyWindow = nil
    }

    /// The Escape monitor is app-wide, so a lens left open in a window that
    /// is no longer key would swallow Escape typed elsewhere.
    @objc private func promptRailWindowDidResignKey() {
        promptRailHover?.closeNow()
    }
}
