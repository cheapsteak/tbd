import AppKit

/// The view `TableTranscriptView` hands SwiftUI, under both prompt rail
/// renderers: the transcript's scroll view, inset from the leading edge by a
/// fixed gutter, plus the AppKit renderer's rail in that gutter and its card
/// stacked above both.
///
/// - **Gutter** – `leadingGutter` is `PromptRailLayout.width` for the AppKit
///   renderer and 0 otherwise, set once from the mount when the view is made.
///   The scroll view always fills the rest, so the table's width is fixed from
///   creation whatever the prompt count.
/// - **Stacking** – subview order settles it: the scroll view at the bottom,
///   the rail above it, the card above everything.
/// - **Coordinator** – a weak handle back to the table's coordinator, for
///   code that reaches the transcript through its view hierarchy.
/// - **AppKit prompt rail** – `installPromptRail` makes this view the hub
///   between the rail, the card and their shared hover model: the rail's
///   outline changes reach the card through here, the hover model's open and
///   close show and hide the card, and the Escape monitor runs only while the
///   card is on screen — an open card with no rows is not. The card closes at
///   once when this view leaves its window
///   (a pane rebuilt under a new identity, as on session rollover) or when
///   that window resigns key, so a card in a background window never holds
///   the app-wide Escape monitor.
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

    /// The rail, laid out to fill the gutter. Installed by the AppKit
    /// renderer; kept below `cardView`.
    var railView: NSView? {
        didSet {
            guard railView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let railView {
                if let cardView, cardView.superview === self {
                    addSubview(railView, positioned: .below, relativeTo: cardView)
                } else {
                    addSubview(railView, positioned: .above, relativeTo: scrollView)
                }
            }
            layoutContent()
        }
    }

    /// The card, stacked above the scroll view and the rail. Installed by the
    /// AppKit renderer; an open `PromptRailCardNSView` is re-laid out against
    /// this view's size whenever it changes.
    var cardView: NSView? {
        didSet {
            guard cardView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let cardView { addSubview(cardView, positioned: .above, relativeTo: nil) }
        }
    }

    // MARK: AppKit prompt rail

    /// The hover model the AppKit rail and card share. Nil under any other
    /// mount.
    private(set) var promptRailHover: PromptRailHoverModel?
    /// The Remote pane's earlier-history state for the card's Load row,
    /// refreshed by every `updateNSView`.
    var promptRailEarlier: PromptRailEarlierHistory? {
        didSet { pushOutlineToCard() }
    }
    private var promptRailEscape: PromptRailEscapeMonitor?
    private var promptRailNotificationCenter: NotificationCenter = .default
    /// The window whose resign-key notification is observed.
    private weak var observedKeyWindow: NSWindow?

    private var promptRailNSView: PromptRailNSView? { railView as? PromptRailNSView }
    private var promptRailCard: PromptRailCardNSView? { cardView as? PromptRailCardNSView }

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

    /// The scroll view takes everything right of the gutter; the rail fills
    /// the gutter; an open card is sized against the whole view. A gutter
    /// wider than the view leaves the scroll view zero wide rather than
    /// negative.
    private func layoutContent() {
        let gutter = min(max(leadingGutter, 0), bounds.width)
        let scrollFrame = NSRect(
            x: gutter, y: 0, width: bounds.width - gutter, height: bounds.height)
        if scrollView.frame != scrollFrame { scrollView.frame = scrollFrame }
        if let railView {
            let railFrame = NSRect(x: 0, y: 0, width: gutter, height: bounds.height)
            if railView.frame != railFrame { railView.frame = railFrame }
        }
        if let card = promptRailCard, card.isOpen { card.layoutCard(maxSize: bounds.size) }
    }

    // MARK: AppKit prompt rail wiring

    /// Mounts the AppKit renderer: `rail` in the gutter, `card` above
    /// everything, both driven by `hover`. Wheel events over the rail go to
    /// the transcript, and the rail's outline changes reach the card.
    ///
    /// `escapeMonitor` and `notificationCenter` default to the production
    /// ones; tests pass their own to count installs and to post a resign-key
    /// notification without reaching `.default`'s other observers.
    func installPromptRail(
        rail: PromptRailNSView,
        card: PromptRailCardNSView,
        hover: PromptRailHoverModel,
        earlier: PromptRailEarlierHistory?,
        escapeMonitor: PromptRailEscapeMonitor = PromptRailEscapeMonitor(),
        notificationCenter: NotificationCenter = .default
    ) {
        stopObservingKeyWindow()
        promptRailHover?.onOpenChange = nil
        promptRailCard?.onShownChange = nil
        promptRailEscape?.stop()

        promptRailHover = hover
        promptRailEscape = escapeMonitor
        promptRailNotificationCenter = notificationCenter
        rail.wheelTarget = scrollView
        rail.onOutlineChange = { [weak self] in self?.pushOutlineToCard() }
        card.onShownChange = { [weak self] shown in self?.promptRailCardShownChanged(shown) }
        cardView = card
        railView = rail
        hover.onOpenChange = { [weak self] open in self?.promptRailOpenChanged(open) }
        promptRailEarlier = earlier
        startObservingKeyWindow()
    }

    /// Hands the rail's outline and active prompt, and the earlier-history
    /// state, to the card.
    private func pushOutlineToCard() {
        guard let rail = promptRailNSView, let card = promptRailCard else { return }
        card.update(entries: rail.entries, activeIndex: rail.activeIndex, earlier: promptRailEarlier)
    }

    /// The hover model opened or closed the card. Opening lays it out against
    /// this view and the pointer's place on the rail; closing hides it. The
    /// Escape monitor follows what is on screen, not this: see
    /// `promptRailCardShownChanged`.
    private func promptRailOpenChanged(_ open: Bool) {
        if open {
            let rail = promptRailNSView
            promptRailCard?.open(
                pointedIndex: rail?.pointedIndex, pointerY: rail?.pointerY ?? 0, maxSize: bounds.size)
        } else {
            promptRailCard?.close()
            promptRailEscape?.stop()
        }
    }

    /// Runs the Escape monitor exactly while the card is on screen. The rail
    /// reports hover with no prompts too, so the hover model can open a card
    /// that has no rows and stays hidden; a monitor started then would take
    /// Escape from every view in the window — a terminal's interrupt among
    /// them — with nothing visible to dismiss. An open card that gains its
    /// first row shows, and starts the monitor then.
    private func promptRailCardShownChanged(_ shown: Bool) {
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
        // identity — closes the card with it.
        promptRailHover?.closeNow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingKeyWindow()
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

    /// The Escape monitor is app-wide, so a card left open in a window that
    /// is no longer key would swallow Escape typed elsewhere.
    @objc private func promptRailWindowDidResignKey() {
        promptRailHover?.closeNow()
    }
}
