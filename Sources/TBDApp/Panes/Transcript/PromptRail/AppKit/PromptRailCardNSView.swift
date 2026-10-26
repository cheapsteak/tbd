import AppKit
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "prompt-rail")

/// The prompt rail's hover card: every prompt by first line and time,
/// anchored at the rail's top-left with its dash column over the rail's
/// notches. `TranscriptContainerView` opens and closes it as
/// `PromptRailHoverModel` says.
///
/// - **Size** – `PromptRailCardMetrics.maxWidth` wide, capped at the pane's
///   width minus `PromptRailCardMetrics.paneInset`, and at most the rail's
///   height less `PromptRailCardMetrics.bottomClearance`, which keeps the
///   pane's jump-to-bottom button clear of it. A longer list scrolls inside,
///   without scrollers, behind 24pt fades over whichever edge clips a row.
/// - **Opening** – fades in over `PromptRailCardMetrics.fadeDuration`, easing
///   out, with the list scrolled so the row for the pointed notch sits under
///   the pointer, or as close as the card's height and the list's ends allow.
/// - **Updates** – a new outline while open updates the rows in place; the
///   card neither closes nor moves its list.
/// - **Rows** – drawn, not built: a flipped list view draws only the rows a
///   redraw covers, from node data alone. Each row's dash is as long as its
///   notch (`PromptRailWorkScale`), so the dash column repeats the rail's
///   profile. A row click jumps and closes the card at once.
/// - **Time column** – today's rows each show their time; an earlier day's
///   first row shows its date and the rest of that day nothing
///   (`PromptOutline.timeColumn`), worked out when the rows change and on
///   each open, never per draw.
/// - **Expansion** – a row that shows only part of its prompt, its first line
///   cut off or the prompt running past it, expands in place once the pointer
///   has rested over its text, right of the dash column, for
///   `PromptRailCardMetrics.expansionDelay` (`PromptRailRowDwell`, on the
///   injected clock). Over the dash column, where a pointer arriving from the
///   rail rests, the row highlights and a click jumps but nothing expands.
///   `PromptRailRowExpansionView` draws over it and the rows beside it,
///   growing down from the row, or up to it near the bottom of the visible
///   list. It takes no events, so clicks and the wheel reach the list. It
///   hides the moment the pointer leaves the row's band or moves onto the
///   dash column, or the list scrolls, and the next row waits its own delay.
///   Rows carry no tooltips.
/// - **Earlier history** – with older Remote history not loaded, the first
///   row reads "Earlier prompts not loaded" beside a Load button that calls the
///   pane's load-earlier action. Nothing else here loads history.
final class PromptRailCardNSView: NSView {
    private typealias Metrics = PromptRailCardMetrics

    private let hover: PromptRailHoverModel
    private let onJump: @MainActor (String) -> Void

    private(set) var entries: [PromptOutlineEntry] = []
    private var deliveredActiveIndex: Int?
    /// The active entry, or nil when the delivered index is out of range.
    var activeIndex: Int? {
        deliveredActiveIndex.flatMap { entries.indices.contains($0) ? $0 : nil }
    }
    private(set) var earlier: PromptRailEarlierHistory?
    /// Whether the hover model has the card open. An open card with no rows
    /// is not on screen; `isShown` says whether it is.
    private(set) var isOpen = false
    /// Whether the card is on screen: open, with at least one row.
    var isShown: Bool { !isHidden }
    /// Called on every change of `isShown`, and only on a change — when the
    /// card opens or closes with rows, and when an open card gains its first
    /// row or loses its last. The container runs the Escape monitor off it, so
    /// Escape is taken only while there is a card on screen to dismiss.
    var onShownChange: (@MainActor (Bool) -> Void)?
    /// The pane size the card was last laid out against.
    private var maxSize: CGSize = .zero

    /// The list's scroll view; internal so tests can read and move its clip.
    let listScrollView = NSScrollView()
    /// Clips the list to the card's rounded shape and carries the edge fade.
    private let listHost = PromptRailFlippedView()
    private let listView = PromptRailCardListView()
    private let fadeMask = CAGradientLayer()
    private let earlierLabel = NSTextField(labelWithString: PromptRailCardMetrics.earlierRowText)
    private let loadButton = NSButton(title: "Load", target: nil, action: nil)
    private var hoverTrackingArea: NSTrackingArea?
    /// Whether the card has seen the pointer over it since it opened, from a
    /// tracking event or a read on opening. The row expansion waits for it.
    private var pointerInside = false
    /// Whether the pointer was last seen over a row's text rather than the
    /// dash column (`PromptRailCardMetrics.isOverRowText`).
    private var pointerOverRowText = false
    /// Whether the hover model has been told the pointer is over the card.
    /// Kept apart from `pointerInside`: a pointer read on opening is not
    /// reported, and its first move reports it.
    private var cardHoverReported = false
    /// Where the pointer is in a window's coordinates, read outside the event
    /// stream: on opening, and when the list moves under a still pointer.
    /// A test seam, since an offscreen window cannot place the real cursor.
    var pointerLocation: @MainActor (NSWindow) -> NSPoint = { $0.mouseLocationOutsideOfEventStream }
    /// The row expansion, above every row and the earlier row's controls.
    /// Internal so tests can read what it shows.
    let expansionView = PromptRailRowExpansionView(frame: .zero)
    private let rowDwell: PromptRailRowDwell
    /// The list's clip bounds as last seen, so a bounds notification that
    /// moved nothing does not count as a scroll.
    private var observedListBounds: NSRect = .zero

    /// `clock` paces the row expansion's delay; tests pass a virtual one.
    init(
        hover: PromptRailHoverModel, onJump: @escaping @MainActor (String) -> Void,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.hover = hover
        self.onJump = onJump
        rowDwell = PromptRailRowDwell(clock: clock)
        super.init(frame: .zero)
        isHidden = true
        alphaValue = 0
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.borderWidth = 0.5
        layer?.masksToBounds = false
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 8
        layer?.shadowOffset = .zero

        listHost.wantsLayer = true
        listHost.layer?.cornerRadius = Metrics.cornerRadius
        listHost.layer?.masksToBounds = true
        addSubview(listHost)

        listScrollView.hasVerticalScroller = false
        listScrollView.hasHorizontalScroller = false
        listScrollView.drawsBackground = false
        listScrollView.borderType = .noBorder
        // The card can sit under a full-size-content titlebar; the list's
        // geometry is its own, not the window's.
        listScrollView.automaticallyAdjustsContentInsets = false
        listScrollView.documentView = listView
        listScrollView.contentView.postsBoundsChangedNotifications = true
        listHost.addSubview(listScrollView)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(listBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: listScrollView.contentView)

        earlierLabel.font = .systemFont(ofSize: Metrics.fontSize)
        earlierLabel.textColor = .secondaryLabelColor
        earlierLabel.lineBreakMode = .byTruncatingTail
        loadButton.target = self
        loadButton.action = #selector(loadEarlier)
        loadButton.controlSize = .small
        loadButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        loadButton.sizeToFit()
        earlierLabel.isHidden = true
        loadButton.isHidden = true
        listView.addSubview(earlierLabel)
        listView.addSubview(loadButton)
        // Added last, so an expansion covering the earlier row covers its
        // controls too.
        listView.addSubview(expansionView)

        listView.onClickRow = { [weak self] row in self?.performClick(row: row) }
        listView.onHoveredRowChange = { [weak self] in self?.restRowDwell() }
        rowDwell.onExpandedRowChange = { [weak self] row in self?.expandedRowChanged(row) }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        applyChromeColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: Rows

    private var showsEarlierRow: Bool { earlier?.hasEarlier == true }

    /// Rows in the list, the "Earlier prompts not loaded" row included.
    var rowCount: Int { entries.count + (showsEarlierRow ? 1 : 0) }

    /// The entry a row shows, or nil for the earlier row and out-of-range rows.
    private func entryIndex(forRow row: Int) -> Int? {
        let index = row - (showsEarlierRow ? 1 : 0)
        return entries.indices.contains(index) ? index : nil
    }

    private var contentHeight: CGFloat {
        Metrics.verticalPadding * 2 + CGFloat(rowCount) * Metrics.rowHeight
    }

    /// Each entry's work, parallel to `entries`, as last delivered.
    var workCounts: [Int] { listView.workScale.counts }

    /// Takes a new outline, its work counts, the active entry and the
    /// earlier-history state. Rows update in place; an open card keeps its
    /// scroll position. Changed rows hide a row expansion, which waits its
    /// delay again; new counts or a new active entry redraw one in place.
    func update(
        entries: [PromptOutlineEntry], workCounts: [Int], activeIndex: Int?,
        earlier: PromptRailEarlierHistory?
    ) {
        let rowsChanged = entries != self.entries || (earlier?.hasEarlier == true) != showsEarlierRow
        let previousActive = self.activeIndex
        let countsChanged = workCounts != listView.workScale.counts
        self.entries = entries
        self.earlier = earlier
        deliveredActiveIndex = activeIndex
        listView.workScale = PromptRailWorkScale(counts: workCounts)
        if rowsChanged {
            rowDwell.cancel()
            pushRows()
            if isOpen {
                layoutCard(maxSize: maxSize)
                applyVisibility()
            }
            restRowDwell()
        } else {
            let activeChanged = previousActive != self.activeIndex
            if activeChanged {
                listView.activeIndex = self.activeIndex
                // The active row's medium weight is wider: a row can start or
                // stop showing only part of its prompt.
                restRowDwell()
            }
            if activeChanged || countsChanged, let row = expansionView.row { showExpansion(row: row) }
        }
    }

    private func pushRows() {
        listView.configure(entries: entries, activeIndex: activeIndex, showsEarlierRow: showsEarlierRow)
        earlierLabel.isHidden = !showsEarlierRow
        loadButton.isHidden = !showsEarlierRow
    }

    // MARK: Open and close

    /// Lays the card out against the pane, scrolls the list so the row for
    /// `pointedIndex` sits under `pointerY` (rail coordinates), and fades the
    /// card in.
    func open(pointedIndex: Int?, pointerY: CGFloat, maxSize: CGSize) {
        // Rows already arrived through `update`; only "today" is read afresh.
        listView.refreshTimeLabels()
        listView.hoveredRow = nil
        isOpen = true
        layoutCard(maxSize: maxSize)
        if let pointedIndex, entries.indices.contains(pointedIndex) {
            let row = pointedIndex + (showsEarlierRow ? 1 : 0)
            scrollList(row: row, under: pointerY)
            listView.hoveredRow = row
        } else {
            scrollList(toOffset: 0)
        }
        // The card opens over the rail the pointer is on, and a tracking area
        // added under a still pointer sends no enter. A pointer already over
        // the list is seen now: its row, not the pointed notch's stand-in,
        // takes the hover fill, and waits to expand if the pointer is over its
        // text — not over the dash column, where one arriving from the rail
        // rests. Elsewhere, the stand-in stays and nothing waits.
        if let window {
            let point = pointerLocation(window)
            if listScrollView.contentView.bounds.contains(listView.convert(point, from: nil)) {
                pointerSeen(at: point)
            }
        }
        logger.debug("card open rows=\(self.rowCount, privacy: .public)")
        alphaValue = 0
        applyVisibility()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Hides the card at once.
    func close() {
        isOpen = false
        pointerInside = false
        pointerOverRowText = false
        cardHoverReported = false
        listView.hoveredRow = nil
        rowDwell.cancel()
        alphaValue = 0
        applyVisibility()
    }

    /// Shown while open with at least one row: a rail with no prompts opens
    /// no empty card, and shows one as soon as a prompt arrives.
    private func applyVisibility() {
        let hidden = !isOpen || rowCount == 0
        guard isHidden != hidden else { return }
        isHidden = hidden
        onShownChange?(!hidden)
    }

    /// Sizes the card against the pane, whose height is the rail's:
    /// `PromptRailCardMetrics.maxWidth` capped at the pane's width minus
    /// `PromptRailCardMetrics.paneInset`, as tall as its rows up to the rail's
    /// height less `PromptRailCardMetrics.bottomClearance`, at the rail's
    /// top-left.
    func layoutCard(maxSize: CGSize) {
        self.maxSize = maxSize
        let width = max(0, min(Metrics.maxWidth, maxSize.width - Metrics.paneInset))
        let height = Metrics.height(contentHeight: contentHeight, railHeight: maxSize.height)
        let cardFrame = NSRect(x: 0, y: 0, width: width, height: height)
        if frame != cardFrame { frame = cardFrame }
        listHost.frame = bounds
        listScrollView.frame = listHost.bounds
        // The clip's size is read straight after, for the scroll range.
        listScrollView.tile()
        let listFrame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        if listView.frame != listFrame { listView.frame = listFrame }
        layoutEarlierRow(width: width)
        // CGPath traps on a corner larger than half the rectangle.
        let radius = max(0, min(Metrics.cornerRadius, bounds.width / 2, bounds.height / 2))
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        updateFades()
        // A clip resized by `tile()` need not post a bounds notification;
        // one that did has already been handled and matches.
        if listScrollView.contentView.bounds != observedListBounds { listClipChanged() }
    }

    private func layoutEarlierRow(width: CGFloat) {
        guard showsEarlierRow else { return }
        let row = Metrics.rowRect(0, width: width)
        let buttonSize = loadButton.fittingSize
        loadButton.frame = NSRect(
            x: row.maxX - Metrics.trailingPadding - buttonSize.width,
            y: row.midY - buttonSize.height / 2,
            width: buttonSize.width,
            height: buttonSize.height)
        let labelHeight = earlierLabel.fittingSize.height
        earlierLabel.frame = NSRect(
            x: Metrics.textLeading,
            y: row.midY - labelHeight / 2,
            width: max(0, loadButton.frame.minX - Metrics.timeGap - Metrics.textLeading),
            height: labelHeight)
    }

    // MARK: Scrolling

    private var maxListOffset: CGFloat {
        max(0, listView.frame.height - listScrollView.contentView.bounds.height)
    }

    /// Scrolls so the centre of `row` sits at `y` in card coordinates, or as
    /// close as the card's height and the list's ends allow
    /// (`PromptRailCardMetrics.openOffset`).
    private func scrollList(row: Int, under y: CGFloat) {
        scrollList(toOffset: Metrics.openOffset(
            row: row, pointerY: y, contentHeight: listView.frame.height,
            cardHeight: listScrollView.contentView.bounds.height))
    }

    private func scrollList(toOffset offset: CGFloat) {
        let clip = listScrollView.contentView
        let clamped = min(max(0, offset), maxListOffset)
        clip.scroll(to: NSPoint(x: 0, y: clamped))
        listScrollView.reflectScrolledClipView(clip)
        updateFades()
    }

    @objc private func listBoundsDidChange() {
        listClipChanged()
    }

    /// The list scrolled, or its clip changed size: a row expansion hides at
    /// once, and whichever row is now under the pointer waits its own delay.
    /// A clip whose bounds did not move changes nothing: the rows under a
    /// still pointer are the same rows.
    private func listClipChanged() {
        updateFades()
        let bounds = listScrollView.contentView.bounds
        guard bounds != observedListBounds else { return }
        observedListBounds = bounds
        rowDwell.cancel()
        let before = listView.hoveredRow
        if pointerInside, let window {
            updateHoveredRow(windowPoint: pointerLocation(window))
        }
        // A changed row rested the delay through `hoveredRow`; the same row
        // under a still pointer waits afresh here.
        if listView.hoveredRow == before { restRowDwell() }
    }

    /// Which edges of the list's clip fade: each that clips a row, and
    /// neither when the whole list fits.
    private var listFades: (top: Bool, bottom: Bool) {
        let clip = listScrollView.contentView.bounds
        guard listView.frame.height > clip.height + 0.5 else { return (false, false) }
        return (clip.minY > 0.5, clip.maxY < listView.frame.height - 0.5)
    }

    /// Fades whichever edge clips a row; no mask when the whole list fits.
    private func updateFades() {
        let fades = listFades
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if fades.top || fades.bottom {
            fadeMask.frame = listHost.bounds
            PromptRailFade.configure(
                fadeMask, height: listHost.bounds.height, fadesTop: fades.top, fadesBottom: fades.bottom)
            if listHost.layer?.mask !== fadeMask { listHost.layer?.mask = fadeMask }
        } else if listHost.layer?.mask != nil {
            listHost.layer?.mask = nil
        }
        CATransaction.commit()
    }

    // MARK: Hover and click

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverTrackingArea else {
            super.mouseEntered(with: event)
            return
        }
        guard isOpen else { return }
        cardHoverReported = true
        hover.cardHoverChanged(true)
        pointerSeen(at: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isOpen else { return }
        // A card that opened under a resting pointer may hear a move before
        // any enter: a move only reaches the card from inside it.
        if !cardHoverReported {
            cardHoverReported = true
            hover.cardHoverChanged(true)
        }
        pointerSeen(at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverTrackingArea else {
            super.mouseExited(with: event)
            return
        }
        pointerInside = false
        pointerOverRowText = false
        cardHoverReported = false
        listView.hoveredRow = nil
        hover.cardHoverChanged(false)
    }

    /// The pointer is over the card at `windowPoint`: the row under it is
    /// hovered, and the row expansion's delay follows it. A changed row rests
    /// the delay through `hoveredRow`. The same row rests it here when the
    /// pointer has just arrived over it — the row the card opened with — or
    /// crossed between its dash column and its text. Any other move within a
    /// row measures nothing.
    private func pointerSeen(at windowPoint: NSPoint) {
        let arrived = !pointerInside
        let wasOverText = pointerOverRowText
        pointerInside = true
        let before = listView.hoveredRow
        updateHoveredRow(windowPoint: windowPoint)
        if listView.hoveredRow == before && (arrived || pointerOverRowText != wasOverText) { restRowDwell() }
    }

    /// The row under a window point, and whether the point is over row text.
    /// The text side is set first, so a row change rests the delay knowing it.
    private func updateHoveredRow(windowPoint: NSPoint) {
        let point = listView.convert(windowPoint, from: nil)
        pointerOverRowText = Metrics.isOverRowText(x: point.x)
        listView.hoveredRow = listView.clickableRow(at: point)
    }

    // MARK: Row expansion

    /// Rests the dwell on the hovered row when the pointer is over the card
    /// and over the row's text, and the row shows only part of its prompt;
    /// on no row otherwise, which hides any expansion at once. Measures only
    /// the hovered row's first line.
    ///
    /// The pointer must have been seen over the card, by a tracking event or
    /// the read on opening. A card opens with the row for the pointed notch
    /// highlighted, and notches are closer together than rows, so when the
    /// list fits without scrolling that row need not be the one under the
    /// pointer; expanding it would put one prompt's text under the pointer
    /// while a click jumps to another.
    private func restRowDwell() {
        guard isOpen, pointerInside, pointerOverRowText, let row = listView.hoveredRow,
              let index = entryIndex(forRow: row), listView.showsPartOfPrompt(index)
        else {
            rowDwell.rest(on: nil)
            return
        }
        rowDwell.rest(on: row)
    }

    private func expandedRowChanged(_ row: Int?) {
        guard let row, isOpen else {
            expansionView.hide()
            return
        }
        showExpansion(row: row)
    }

    /// Lays `row`'s expansion out in the list's visible rect, clear of its
    /// edge fades, and shows it. When the row now shows its whole prompt or
    /// not one line fits, it hides, and the dwell collapses with it so the two
    /// agree that nothing is expanded.
    private func showExpansion(row: Int) {
        let fades = listFades
        let room = Metrics.expansionRoom(
            clip: listScrollView.contentView.bounds, fadesTop: fades.top, fadesBottom: fades.bottom)
        guard let expansion = listView.expansion(forRow: row, visible: room) else {
            expansionView.hide()
            rowDwell.collapse()
            return
        }
        expansionView.show(expansion.content, frame: expansion.frame)
    }

    /// A click on `row`: jump to its prompt, then close the card at once. The
    /// earlier row is not a jump target; its Load button acts on its own.
    func performClick(row: Int) {
        guard let index = entryIndex(forRow: row) else { return }
        let id = entries[index].id
        logger.debug("card row clicked id=\(id, privacy: .public)")
        onJump(id)
        hover.dismiss(.click)
    }

    @objc private func loadEarlier() {
        logger.debug("card load earlier pressed")
        earlier?.load()
    }

    // MARK: Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeColors()
        listView.needsDisplay = true
        expansionView.needsDisplay = true
    }

    /// Layer colours are fixed when made, so they are resolved again in the
    /// current appearance on every change.
    private func applyChromeColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.shadowColor = NSColor.shadowColor.withAlphaComponent(0.2).cgColor
        }
    }

    // MARK: Test seams

    /// Entry `index`'s dash, in list coordinates, as its row draws it.
    func dashRect(forEntry index: Int) -> NSRect? {
        guard entries.indices.contains(index) else { return nil }
        return listView.dashRect(index, in: Metrics.rowRect(rowFor(entry: index), width: listView.bounds.width))
    }

    /// Whether entry `index`'s row shows only part of its prompt at the
    /// list's width, and so expands; nil past the entries.
    func showsPartOfPrompt(entry index: Int) -> Bool? {
        entries.indices.contains(index) ? listView.showsPartOfPrompt(index) : nil
    }

    /// The list row whose expansion is on screen; nil for none.
    var expandedRow: Int? { expansionView.row }

    /// The list row with the hover fill; nil for none.
    var hoveredRow: Int? { listView.hoveredRow }

    /// What entry `index`'s row shows in its time column, "" for nothing;
    /// nil past the entries.
    func timeText(forEntry index: Int) -> String? {
        entries.indices.contains(index) ? listView.timeText(at: index) : nil
    }

    /// Await the row expansion's armed delay, so a test asserts on the state
    /// it left rather than racing it.
    func _drainRowDwellForTesting() async {
        await rowDwell._drainForTesting()
    }

    private func rowFor(entry index: Int) -> Int { index + (showsEarlierRow ? 1 : 0) }

    // MARK: Geometry

    /// The row containing list y `y`, or nil above the first or below the last.
    static func row(atY y: CGFloat, rowCount: Int) -> Int? {
        let raw = ((y - Metrics.verticalPadding) / Metrics.rowHeight).rounded(.down)
        guard raw >= 0, raw < CGFloat(rowCount) else { return nil }
        return Int(raw)
    }
}

/// A plain flipped view: hosts the list's scroll view so the card's corner
/// clip and edge fade share the card's y-down coordinates.
private final class PromptRailFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The card's rows, drawn rather than built: only rows a redraw covers are
/// drawn, from the entries' own data. It owns the per-row presentation —
/// fonts, dash, hover fill, truncation and what a row's expansion shows —
/// while the card owns the data, layout and the expansion's timing.
private final class PromptRailCardListView: NSView {
    private typealias Card = PromptRailCardNSView
    private typealias Metrics = PromptRailCardMetrics

    private(set) var entries: [PromptOutlineEntry] = []
    private(set) var showsEarlierRow = false
    var activeIndex: Int? {
        didSet {
            guard activeIndex != oldValue else { return }
            for index in [oldValue, activeIndex].compactMap({ $0 }) { invalidateRow(rowFor(index)) }
        }
    }
    var hoveredRow: Int? {
        didSet {
            guard hoveredRow != oldValue else { return }
            for row in [oldValue, hoveredRow].compactMap({ $0 }) { invalidateRow(row) }
            onHoveredRowChange?()
        }
    }
    /// Each entry's work and the dash lengths it gives.
    var workScale = PromptRailWorkScale(counts: []) {
        didSet {
            if workScale != oldValue { needsDisplay = true }
        }
    }
    var onClickRow: (@MainActor (Int) -> Void)?
    /// Called on every change of `hoveredRow`, and only on a change.
    var onHoveredRowChange: (@MainActor () -> Void)?

    private let regularFont = NSFont.systemFont(ofSize: Metrics.fontSize)
    private let activeFont = NSFont.systemFont(ofSize: Metrics.fontSize, weight: .medium)
    private let timeFont = NSFont.monospacedDigitSystemFont(ofSize: Metrics.fontSize, weight: .regular)
    private let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    /// The time column, parallel to `entries` (`PromptOutline.timeColumn`)
    /// as of `labelsNow`. Worked out when the entries change and on each
    /// open, which reads "today" afresh; never per draw.
    private var timeColumn: [String] = []
    private var labelsNow = Date()
    private var mouseDownRow: Int?

    override var isFlipped: Bool { true }

    private var rowCount: Int { entries.count + (showsEarlierRow ? 1 : 0) }

    private func rowFor(_ entryIndex: Int) -> Int { entryIndex + (showsEarlierRow ? 1 : 0) }

    private func entryIndex(forRow row: Int) -> Int? {
        let index = row - (showsEarlierRow ? 1 : 0)
        return entries.indices.contains(index) ? index : nil
    }

    func configure(entries: [PromptOutlineEntry], activeIndex: Int?, showsEarlierRow: Bool) {
        self.entries = entries
        rebuildTimeColumn()
        self.showsEarlierRow = showsEarlierRow
        self.activeIndex = activeIndex
        if let hoveredRow, hoveredRow >= rowCount { self.hoveredRow = nil }
        needsDisplay = true
    }

    func refreshTimeLabels() {
        labelsNow = Date()
        rebuildTimeColumn()
        needsDisplay = true
    }

    private func rebuildTimeColumn() {
        timeColumn = PromptOutline.timeColumn(
            entries.map(\.timestamp), now: labelsNow, calendar: .current, locale: .current)
    }

    /// Entry `index`'s time column: its time, its day's date, or "".
    func timeText(at index: Int) -> String {
        timeColumn.indices.contains(index) ? timeColumn[index] : ""
    }

    private func invalidateRow(_ row: Int) {
        setNeedsDisplay(Metrics.rowRect(row, width: bounds.width))
    }

    /// The entry row under `point`, or nil off the rows or on the earlier row.
    func clickableRow(at point: NSPoint) -> Int? {
        guard point.x >= 0, point.x < bounds.width,
              let row = Card.row(atY: point.y, rowCount: rowCount),
              entryIndex(forRow: row) != nil
        else { return nil }
        return row
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard rowCount > 0 else { return }
        let first = max(0, Int(((dirtyRect.minY - Metrics.verticalPadding) / Metrics.rowHeight).rounded(.down)))
        let last = min(rowCount - 1, Int(((dirtyRect.maxY - Metrics.verticalPadding) / Metrics.rowHeight).rounded(.down)))
        guard first <= last else { return }
        for row in first...last { drawRow(row) }
    }

    private func drawRow(_ row: Int) {
        guard let index = entryIndex(forRow: row) else { return }
        let entry = entries[index]
        let active = index == activeIndex
        let rect = Metrics.rowRect(row, width: bounds.width)

        if row == hoveredRow {
            NSColor.quaternarySystemFill.setFill()
            NSBezierPath(
                roundedRect: rect.insetBy(dx: 1, dy: 0),
                xRadius: Metrics.hoverCornerRadius, yRadius: Metrics.hoverCornerRadius
            ).fill()
        }

        let dash = dashRect(index, in: rect)
        PromptRailNotchStyle.color(for: entry.kind, active: active).setFill()
        NSBezierPath(roundedRect: dash, xRadius: dash.height / 2, yRadius: dash.height / 2).fill()

        let layout = textLayout(index, rowWidth: rect.width)
        if let time = layout.time {
            let size = time.size()
            time.draw(
                with: NSRect(
                    x: rect.maxX - Metrics.trailingPadding - size.width, y: rect.midY - size.height / 2,
                    width: size.width, height: size.height),
                options: [.usesLineFragmentOrigin])
        }
        let lineHeight = ceil(regularFont.ascender - regularFont.descender + regularFont.leading)
        layout.title.draw(
            with: NSRect(
                x: Metrics.textLeading, y: rect.midY - lineHeight / 2,
                width: max(0, layout.titleWidth), height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Entry `index`'s dash in the row at `rowRect`: as long as its notch on
    /// the rail and as thick, so the dash column repeats the rail's profile.
    func dashRect(_ index: Int, in rowRect: NSRect) -> NSRect {
        let height = PromptRailLayout.notchHeight(active: index == activeIndex)
        return NSRect(
            x: Metrics.dashColumnLeading, y: rowRect.midY - height / 2,
            width: workScale.length(at: index), height: height)
    }

    /// The row's title and time strings, and the width the title may take.
    private func textLayout(
        _ index: Int, rowWidth: CGFloat
    ) -> (title: NSAttributedString, time: NSAttributedString?, titleWidth: CGFloat) {
        let entry = entries[index]
        let font = index == activeIndex ? activeFont : regularFont
        let title = NSMutableAttributedString()
        if case .peer(let sender) = entry.kind {
            title.append(NSAttributedString(string: sender, attributes: [
                .font: font, .foregroundColor: AttentionAmber.nsColor(alpha: 1), .paragraphStyle: truncating,
            ]))
            title.append(NSAttributedString(string: ": ", attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncating,
            ]))
        }
        title.append(NSAttributedString(string: String(entry.firstLine.prefix(Metrics.drawnPrefix)), attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncating,
        ]))

        let label = timeText(at: index)
        let time = label.isEmpty ? nil : NSAttributedString(string: label, attributes: [
            .font: timeFont, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        var trailing = rowWidth - Metrics.trailingPadding
        if let time { trailing -= time.size().width + Metrics.timeGap }
        return (title, time, trailing - Metrics.textLeading)
    }

    // MARK: Expansion

    /// Whether entry `index`'s row shows only part of its prompt: its first
    /// line is cut off at the row's width, or the prompt runs past that line.
    /// Lays out that one row's first line.
    func showsPartOfPrompt(_ index: Int) -> Bool {
        if entries[index].runsPastFirstLine { return true }
        let layout = textLayout(index, rowWidth: bounds.width)
        return layout.title.size().width > layout.titleWidth
    }

    /// Row `row`'s expansion and its frame in list coordinates, placed within
    /// `visible` by `PromptRailCardMetrics.expansionPlacement`; nil for a row
    /// that shows its whole prompt, and where not one line fits.
    ///
    /// The prompt's opening is wrapped to the row's title width, in the row's
    /// font. The line on the row's band — the first growing down, the
    /// tool-call line growing up — is centred in it as the row's title is,
    /// and the row's dash and time sit on that band.
    func expansion(
        forRow row: Int, visible: NSRect
    ) -> (content: PromptRailRowExpansionView.Content, frame: NSRect)? {
        guard let index = entryIndex(forRow: row), showsPartOfPrompt(index) else { return nil }
        let entry = entries[index]
        let active = index == activeIndex
        let rowRect = Metrics.rowRect(row, width: bounds.width)
        let layout = textLayout(index, rowWidth: rowRect.width)
        let full = PromptRailExpansionText(
            expansionText(entry, font: active ? activeFont : regularFont),
            width: max(1, layout.titleWidth))
        guard let placement = Metrics.expansionPlacement(
            row: rowRect, visible: visible,
            wantedLines: min(Metrics.expansionMaxLines, full.lineCount), lineHeight: full.lineHeight)
        else { return nil }

        let text = full.limited(toLines: placement.lines)
        let lineHeight = full.lineHeight
        let padding = (Metrics.rowHeight - lineHeight) / 2
        let height = padding * 2 + text.height + lineHeight
        let frame = NSRect(
            x: rowRect.minX, y: placement.growsUpward ? rowRect.maxY - height : rowRect.minY,
            width: rowRect.width, height: height)
        let band = rowRect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let count = NSAttributedString(
            string: PromptOutline.workLabel(workScale.count(at: index)),
            attributes: [.font: regularFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: truncating])
        let content = PromptRailRowExpansionView.Content(
            row: row,
            growsUpward: placement.growsUpward,
            rowBand: band,
            dash: dashRect(index, in: band),
            dashColor: PromptRailNotchStyle.color(for: entry.kind, active: active),
            time: layout.time,
            text: text,
            textOrigin: NSPoint(x: Metrics.textLeading, y: padding),
            count: count,
            countRect: NSRect(
                x: Metrics.textLeading, y: padding + text.height,
                width: max(0, layout.titleWidth), height: lineHeight))
        return (content, frame)
    }

    /// The prompt's opening as an expansion wraps it: "sender: " first for a
    /// peer, as on its row, then `PromptOutlineEntry.excerpt`.
    private func expansionText(_ entry: PromptOutlineEntry, font: NSFont) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if case .peer(let sender) = entry.kind {
            text.append(NSAttributedString(string: sender, attributes: [
                .font: font, .foregroundColor: AttentionAmber.nsColor(alpha: 1),
            ]))
            text.append(NSAttributedString(string: ": ", attributes: [
                .font: font, .foregroundColor: NSColor.labelColor,
            ]))
        }
        text.append(NSAttributedString(string: entry.excerpt, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]))
        return text
    }

    // MARK: Clicks

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownRow = clickableRow(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownRow = nil }
        guard let row = mouseDownRow,
              clickableRow(at: convert(event.locationInWindow, from: nil)) == row
        else { return }
        onClickRow?(row)
    }
}
