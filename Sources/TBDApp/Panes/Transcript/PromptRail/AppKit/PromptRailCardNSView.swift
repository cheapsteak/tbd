import AppKit
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "prompt-rail")

/// The AppKit renderer's hover card: every prompt by first line and time,
/// anchored at the rail's top-left with its dash column over the rail's
/// notches. `TranscriptContainerView` opens and closes it as
/// `PromptRailHoverModel` says.
///
/// - **Size** – `maxWidth` wide, capped at the pane's width minus `paneInset`,
///   and at most as tall as the rail. A longer list scrolls inside, without
///   scrollers, behind 24pt fades over whichever edge clips a row.
/// - **Opening** – fades in over `fadeDuration`, easing out, with the list
///   scrolled so the row for the pointed notch sits under the pointer, or as
///   close as the list's ends allow.
/// - **Updates** – a new outline while open updates the rows in place; the
///   card neither closes nor moves its list.
/// - **Rows** – drawn, not built: a flipped list view draws only the rows a
///   redraw covers, from node data alone. A row click jumps and closes the card
///   at once; a truncated row carries its prompt's first 500 characters as a
///   tooltip.
/// - **Earlier history** – with older Remote history not loaded, the first
///   row reads "Earlier prompts not loaded" beside a Load button that calls the
///   pane's load-earlier action. Nothing else here loads history.
final class PromptRailCardNSView: NSView {
    static let maxWidth: CGFloat = 320
    /// The card leaves this much of the pane's width uncovered.
    static let paneInset: CGFloat = 24
    static let rowHeight: CGFloat = 22
    static let fontSize: CGFloat = 13
    /// Starts at the rail's notch leading edge, so the dashes sit over the notches.
    static let dashColumnLeading: CGFloat = PromptRailLayout.notchLeading
    static let dashColumnWidth: CGFloat = 18
    static let dashGap: CGFloat = 8
    static let verticalPadding: CGFloat = 6
    static let trailingPadding: CGFloat = 10
    static let timeGap: CGFloat = 8
    static let hoverCornerRadius: CGFloat = 6
    static let cornerRadius: CGFloat = 8
    static let fadeDuration: TimeInterval = 0.15
    static let earlierRowText = "Earlier prompts not loaded"

    /// Where row text starts: after the dash column and its gap.
    static var textLeading: CGFloat { dashColumnLeading + dashColumnWidth + dashGap }

    private let hover: PromptRailHoverModel
    private let onJump: @MainActor (String) -> Void

    private(set) var entries: [PromptOutlineEntry] = []
    private var deliveredActiveIndex: Int?
    /// The active entry, or nil when the delivered index is out of range.
    var activeIndex: Int? {
        deliveredActiveIndex.flatMap { entries.indices.contains($0) ? $0 : nil }
    }
    private(set) var earlier: PromptRailEarlierHistory?
    private(set) var isOpen = false
    /// The pane size the card was last laid out against.
    private var maxSize: CGSize = .zero

    /// The list's scroll view; internal so tests can read and move its clip.
    let listScrollView = NSScrollView()
    /// Clips the list to the card's rounded shape and carries the edge fade.
    private let listHost = PromptRailFlippedView()
    private let listView = PromptRailCardListView()
    private let fadeMask = CAGradientLayer()
    private let earlierLabel = NSTextField(labelWithString: PromptRailCardNSView.earlierRowText)
    private let loadButton = NSButton(title: "Load", target: nil, action: nil)
    private var hoverTrackingArea: NSTrackingArea?
    private var pointerInside = false

    init(hover: PromptRailHoverModel, onJump: @escaping @MainActor (String) -> Void) {
        self.hover = hover
        self.onJump = onJump
        super.init(frame: .zero)
        isHidden = true
        alphaValue = 0
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.borderWidth = 0.5
        layer?.masksToBounds = false
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 8
        layer?.shadowOffset = .zero

        listHost.wantsLayer = true
        listHost.layer?.cornerRadius = Self.cornerRadius
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

        earlierLabel.font = .systemFont(ofSize: Self.fontSize)
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

        listView.onClickRow = { [weak self] row in self?.performClick(row: row) }

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
        Self.verticalPadding * 2 + CGFloat(rowCount) * Self.rowHeight
    }

    /// Takes a new outline, active entry and earlier-history state. Rows
    /// update in place; an open card keeps its scroll position.
    func update(entries: [PromptOutlineEntry], activeIndex: Int?, earlier: PromptRailEarlierHistory?) {
        let rowsChanged = entries != self.entries || (earlier?.hasEarlier == true) != showsEarlierRow
        let previousActive = self.activeIndex
        self.entries = entries
        self.earlier = earlier
        deliveredActiveIndex = activeIndex
        if rowsChanged {
            pushRows()
            if isOpen {
                layoutCard(maxSize: maxSize)
                applyVisibility()
            }
        } else if previousActive != self.activeIndex {
            listView.activeIndex = self.activeIndex
            if isOpen { listView.rebuildToolTips() }
        }
    }

    private func pushRows() {
        listView.configure(
            entries: entries, activeIndex: activeIndex, showsEarlierRow: showsEarlierRow,
            buildToolTips: isOpen)
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
        logger.debug("card open rows=\(self.rowCount, privacy: .public)")
        alphaValue = 0
        applyVisibility()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Hides the card at once.
    func close() {
        isOpen = false
        pointerInside = false
        listView.hoveredRow = nil
        alphaValue = 0
        applyVisibility()
    }

    /// Shown while open with at least one row: a rail with no prompts opens
    /// no empty card, and shows one as soon as a prompt arrives.
    private func applyVisibility() {
        let hidden = !isOpen || rowCount == 0
        if isHidden != hidden { isHidden = hidden }
    }

    /// Sizes the card against the pane: `maxWidth` capped at the pane's width
    /// minus `paneInset`, as tall as its rows up to the pane's height, at the
    /// rail's top-left.
    func layoutCard(maxSize: CGSize) {
        self.maxSize = maxSize
        let width = max(0, min(Self.maxWidth, maxSize.width - Self.paneInset))
        let height = max(0, min(contentHeight, maxSize.height))
        let widthChanged = width != frame.width
        let cardFrame = NSRect(x: 0, y: 0, width: width, height: height)
        if frame != cardFrame { frame = cardFrame }
        listHost.frame = bounds
        listScrollView.frame = listHost.bounds
        // The clip's size is read straight after, for the scroll range.
        listScrollView.tile()
        let listFrame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        if listView.frame != listFrame { listView.frame = listFrame }
        layoutEarlierRow(width: width)
        if widthChanged || listView.toolTipsStale { listView.rebuildToolTips() }
        // CGPath traps on a corner larger than half the rectangle.
        let radius = max(0, min(Self.cornerRadius, bounds.width / 2, bounds.height / 2))
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        updateFades()
    }

    private func layoutEarlierRow(width: CGFloat) {
        guard showsEarlierRow else { return }
        let row = Self.rowRect(0, width: width)
        let buttonSize = loadButton.fittingSize
        loadButton.frame = NSRect(
            x: row.maxX - Self.trailingPadding - buttonSize.width,
            y: row.midY - buttonSize.height / 2,
            width: buttonSize.width,
            height: buttonSize.height)
        let labelHeight = earlierLabel.fittingSize.height
        earlierLabel.frame = NSRect(
            x: Self.textLeading,
            y: row.midY - labelHeight / 2,
            width: max(0, loadButton.frame.minX - Self.timeGap - Self.textLeading),
            height: labelHeight)
    }

    // MARK: Scrolling

    private var maxListOffset: CGFloat {
        max(0, listView.frame.height - listScrollView.contentView.bounds.height)
    }

    /// Scrolls so the centre of `row` sits at `y` in card coordinates,
    /// clamped to the list's ends.
    private func scrollList(row: Int, under y: CGFloat) {
        scrollList(toOffset: Self.rowRect(row, width: bounds.width).midY - y)
    }

    private func scrollList(toOffset offset: CGFloat) {
        let clip = listScrollView.contentView
        let clamped = min(max(0, offset), maxListOffset)
        clip.scroll(to: NSPoint(x: 0, y: clamped))
        listScrollView.reflectScrolledClipView(clip)
        updateFades()
    }

    @objc private func listBoundsDidChange() {
        updateFades()
        if pointerInside, let window {
            updateHoveredRow(windowPoint: window.mouseLocationOutsideOfEventStream)
        }
    }

    /// Fades whichever edge clips a row; no mask when the whole list fits.
    private func updateFades() {
        let clip = listScrollView.contentView.bounds
        let overflows = listView.frame.height > clip.height + 0.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if overflows {
            fadeMask.frame = listHost.bounds
            PromptRailFade.configure(
                fadeMask,
                height: listHost.bounds.height,
                fadesTop: clip.minY > 0.5,
                fadesBottom: clip.maxY < listView.frame.height - 0.5)
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
        pointerInside = true
        hover.cardHoverChanged(true)
        updateHoveredRow(windowPoint: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isOpen else { return }
        // A card that opened under a resting pointer may hear a move before
        // any enter: a move only reaches the card from inside it.
        if !pointerInside {
            pointerInside = true
            hover.cardHoverChanged(true)
        }
        updateHoveredRow(windowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverTrackingArea else {
            super.mouseExited(with: event)
            return
        }
        pointerInside = false
        listView.hoveredRow = nil
        hover.cardHoverChanged(false)
    }

    private func updateHoveredRow(windowPoint: NSPoint) {
        let point = listView.convert(windowPoint, from: nil)
        listView.hoveredRow = listView.clickableRow(at: point)
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

    // MARK: Geometry

    /// A row's rectangle in list coordinates.
    static func rowRect(_ row: Int, width: CGFloat) -> NSRect {
        NSRect(
            x: 0, y: verticalPadding + CGFloat(row) * rowHeight,
            width: width, height: rowHeight)
    }

    /// The row containing list y `y`, or nil above the first or below the last.
    static func row(atY y: CGFloat, rowCount: Int) -> Int? {
        let raw = ((y - verticalPadding) / rowHeight).rounded(.down)
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
/// fonts, dash, hover fill, truncation and its tooltips — while the card owns
/// the data and layout.
private final class PromptRailCardListView: NSView, NSViewToolTipOwner {
    private typealias Card = PromptRailCardNSView

    /// Characters of a first line that are laid out at all. Far more than a
    /// 320pt row can show, so a longer line still truncates at the tail, and
    /// a first line of a large paste costs no more to draw than a short one.
    private static let drawnPrefix = 400

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
        }
    }
    var onClickRow: (@MainActor (Int) -> Void)?
    /// Set when the rows changed while the card was closed; the next layout
    /// rebuilds the tooltips.
    private(set) var toolTipsStale = true

    private let regularFont = NSFont.systemFont(ofSize: Card.fontSize)
    private let activeFont = NSFont.systemFont(ofSize: Card.fontSize, weight: .medium)
    private let timeFont = NSFont.monospacedDigitSystemFont(ofSize: Card.fontSize, weight: .regular)
    private let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    /// Time labels by entry id, built as rows are drawn and cleared on each
    /// open so "today" is read afresh.
    private var timeLabels: [String: String] = [:]
    private var labelsNow = Date()
    private var mouseDownRow: Int?

    override var isFlipped: Bool { true }

    private var rowCount: Int { entries.count + (showsEarlierRow ? 1 : 0) }

    private func rowFor(_ entryIndex: Int) -> Int { entryIndex + (showsEarlierRow ? 1 : 0) }

    private func entryIndex(forRow row: Int) -> Int? {
        let index = row - (showsEarlierRow ? 1 : 0)
        return entries.indices.contains(index) ? index : nil
    }

    func configure(
        entries: [PromptOutlineEntry], activeIndex: Int?, showsEarlierRow: Bool, buildToolTips: Bool
    ) {
        self.entries = entries
        self.showsEarlierRow = showsEarlierRow
        self.activeIndex = activeIndex
        if let hoveredRow, hoveredRow >= rowCount { self.hoveredRow = nil }
        needsDisplay = true
        toolTipsStale = true
        if buildToolTips { rebuildToolTips() }
    }

    func refreshTimeLabels() {
        timeLabels.removeAll()
        labelsNow = Date()
        needsDisplay = true
    }

    private func invalidateRow(_ row: Int) {
        setNeedsDisplay(Card.rowRect(row, width: bounds.width))
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
        let first = max(0, Int(((dirtyRect.minY - Card.verticalPadding) / Card.rowHeight).rounded(.down)))
        let last = min(rowCount - 1, Int(((dirtyRect.maxY - Card.verticalPadding) / Card.rowHeight).rounded(.down)))
        guard first <= last else { return }
        for row in first...last { drawRow(row) }
    }

    private func drawRow(_ row: Int) {
        guard let index = entryIndex(forRow: row) else { return }
        let entry = entries[index]
        let active = index == activeIndex
        let rect = Card.rowRect(row, width: bounds.width)

        if row == hoveredRow {
            NSColor.quaternarySystemFill.setFill()
            NSBezierPath(
                roundedRect: rect.insetBy(dx: 1, dy: 0),
                xRadius: Card.hoverCornerRadius, yRadius: Card.hoverCornerRadius
            ).fill()
        }

        let dashSize = active ? PromptRailLayout.activeNotch : PromptRailLayout.inactiveNotch
        let dash = NSRect(
            x: Card.dashColumnLeading, y: rect.midY - dashSize.height / 2,
            width: dashSize.width, height: dashSize.height)
        PromptRailNotchStyle.color(for: entry.kind, active: active).setFill()
        NSBezierPath(roundedRect: dash, xRadius: dashSize.height / 2, yRadius: dashSize.height / 2).fill()

        let layout = textLayout(index, rowWidth: rect.width)
        if let time = layout.time {
            let size = time.size()
            time.draw(
                with: NSRect(
                    x: rect.maxX - Card.trailingPadding - size.width, y: rect.midY - size.height / 2,
                    width: size.width, height: size.height),
                options: [.usesLineFragmentOrigin])
        }
        let lineHeight = ceil(regularFont.ascender - regularFont.descender + regularFont.leading)
        layout.title.draw(
            with: NSRect(
                x: Card.textLeading, y: rect.midY - lineHeight / 2,
                width: max(0, layout.titleWidth), height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
        title.append(NSAttributedString(string: String(entry.firstLine.prefix(Self.drawnPrefix)), attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: truncating,
        ]))

        let label = timeLabel(for: entry)
        let time = label.isEmpty ? nil : NSAttributedString(string: label, attributes: [
            .font: timeFont, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        var trailing = rowWidth - Card.trailingPadding
        if let time { trailing -= time.size().width + Card.timeGap }
        return (title, time, trailing - Card.textLeading)
    }

    private func timeLabel(for entry: PromptOutlineEntry) -> String {
        if let cached = timeLabels[entry.id] { return cached }
        let label = PromptOutline.timeLabel(entry.timestamp, now: labelsNow, calendar: .current, locale: .current)
        timeLabels[entry.id] = label
        return label
    }

    // MARK: Tooltips

    /// One tooltip rectangle per truncated row.
    func rebuildToolTips() {
        removeAllToolTips()
        toolTipsStale = false
        let width = bounds.width
        guard width > 0 else {
            toolTipsStale = true
            return
        }
        for index in entries.indices {
            let layout = textLayout(index, rowWidth: width)
            guard layout.title.size().width > layout.titleWidth else { continue }
            _ = addToolTip(Card.rowRect(rowFor(index), width: width), owner: self, userData: nil)
        }
    }

    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let row = Card.row(atY: point.y, rowCount: rowCount),
              let index = entryIndex(forRow: row)
        else { return "" }
        return entries[index].tooltip
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
