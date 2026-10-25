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
    /// AppKit renderer, which also sizes and places it.
    var cardView: NSView? {
        didSet {
            guard cardView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let cardView { addSubview(cardView, positioned: .above, relativeTo: nil) }
        }
    }

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
    /// the gutter. A gutter wider than the view leaves the scroll view zero
    /// wide rather than negative.
    private func layoutContent() {
        let gutter = min(max(leadingGutter, 0), bounds.width)
        let scrollFrame = NSRect(
            x: gutter, y: 0, width: bounds.width - gutter, height: bounds.height)
        if scrollView.frame != scrollFrame { scrollView.frame = scrollFrame }
        if let railView {
            let railFrame = NSRect(x: 0, y: 0, width: gutter, height: bounds.height)
            if railView.frame != railFrame { railView.frame = railFrame }
        }
    }
}
