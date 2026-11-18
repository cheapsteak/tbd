import AppKit

/// What the box covers for one displayed layout of the lens.
struct PromptRailLensShape: Equatable {
    /// The widest any row wants, and at least the rail's width: the box's
    /// width, and the hovered row's fill's.
    let width: CGFloat
    /// The rows whose text shows at all; nil when none does.
    let textRows: ClosedRange<Int>?
    /// The box, in rail coordinates: from the pane's leading edge to `width`,
    /// and from `boxPadding` above the text band of the first of `textRows`
    /// to `boxPadding` below the last's
    /// (`PromptRailLensPainter.textBand(row:in:)`). nil when no row shows
    /// text, or when the box would be no more than 2pt wider than the rail.
    /// Its taper reaches past it above and below, over the rail column only.
    let box: CGRect?

    static let closed = PromptRailLensShape(width: PromptRailLayout.width, textRows: nil, box: nil)
}

/// Which ends of the rail fade the lens's notches, because a displayed row
/// runs past them.
struct PromptRailEndFades: Equatable {
    var top: Bool
    var bottom: Bool

    static let neither = PromptRailEndFades(top: false, bottom: false)
}

/// The lens's colours other than the notches', resolved for one appearance.
/// A `CGColor` is fixed the moment it is made, so a palette belongs to the
/// draw that made it.
struct PromptRailLensPalette: Equatable {
    let background: CGColor
    let border: CGColor
    let shadow: CGColor
    let hoverFill: CGColor

    /// Resolves each colour in the current drawing appearance: call it inside
    /// `performAsCurrentDrawingAppearance`.
    static func resolvedInCurrentAppearance() -> PromptRailLensPalette {
        PromptRailLensPalette(
            background: NSColor.windowBackgroundColor.cgColor,
            border: NSColor.separatorColor.cgColor,
            shadow: NSColor.shadowColor.withAlphaComponent(PromptRailRowMetrics.boxShadowOpacity).cgColor,
            hoverFill: NSColor.quaternarySystemFill.cgColor)
    }
}

/// Draws the open lens (lens spec, "The lens" → "Drawing") for a displayed
/// layout the rail view hands it: the box behind the readable rows, the
/// hovered row's fill, every row's notch, and the text of the rows that show
/// any. A port of the approved mock's `drawBox`, `drawNotch` and row text.
///
/// It also says how wide the box is (`shape(for:openFraction:maxWidth:)`),
/// which takes each entry's natural width: its first line and time at 13pt
/// with the row's padding. Those are measured once per entry and cached, and
/// the cache is cleared when the outline, the active prompt or the time
/// column changes, so a frame measures only rows it has not measured since —
/// and only rows tall enough to start widening.
@MainActor
final class PromptRailLensPainter {
    private typealias Metrics = PromptRailRowMetrics

    private(set) var entries: [PromptOutlineEntry] = []
    /// The active entry, held to `entries`.
    private(set) var activeIndex: Int?
    /// Natural widths measured since the cache was last cleared. A test
    /// seam: it says how much measuring the frames did.
    private(set) var measuredWidths = 0

    /// Each entry's natural width, parallel to `entries`; nil until measured.
    private var naturalWidths: [CGFloat?] = []
    /// The time column (`PromptOutline.timeColumn`) as of `labelsNow`,
    /// parallel to `entries`; nil until a row needs it after a change.
    private var timeColumn: [String]?
    private var labelsNow = Date()

    private let fullFonts = Fonts(size: Metrics.fontSize)
    private let smallFonts = Fonts(size: Metrics.smallFontSize)
    private let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// A row's three fonts at one size, and the height of its line.
    private struct Fonts {
        let regular: NSFont
        let active: NSFont
        let time: NSFont
        let lineHeight: CGFloat

        init(size: CGFloat) {
            regular = NSFont.systemFont(ofSize: size)
            active = NSFont.systemFont(ofSize: size, weight: .medium)
            time = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
            lineHeight = ceil(regular.ascender - regular.descender + regular.leading)
        }
    }

    // MARK: Data

    /// A new outline: the time column and every natural width are stale.
    func setEntries(_ entries: [PromptOutlineEntry], activeIndex: Int?) {
        self.entries = entries
        self.activeIndex = activeIndex.flatMap { entries.indices.contains($0) ? $0 : nil }
        timeColumn = nil
        clearWidths()
    }

    /// A new active prompt: its row and the old one change weight, so their
    /// widths are stale.
    func setActiveIndex(_ index: Int?) {
        let held = index.flatMap { entries.indices.contains($0) ? $0 : nil }
        guard held != activeIndex else { return }
        activeIndex = held
        clearWidths()
    }

    /// Works the time column out afresh as of `now`, which reads "today"
    /// anew. The lens does this as it opens.
    func refreshTimeColumn(now: Date) {
        labelsNow = now
        timeColumn = nil
        clearWidths()
    }

    /// Entry `index`'s time column: its time, its day's date, or "".
    func timeText(at index: Int) -> String {
        let column = timeColumn ?? makeTimeColumn()
        return column.indices.contains(index) ? column[index] : ""
    }

    private func makeTimeColumn() -> [String] {
        let column = PromptOutline.timeColumn(
            entries.map(\.timestamp), now: labelsNow, calendar: .current, locale: .current)
        timeColumn = column
        return column
    }

    private func clearWidths() {
        naturalWidths = Array(repeating: nil, count: entries.count)
        measuredWidths = 0
    }

    /// Entry `index`'s natural width: `textLeading`, its first line, the gap
    /// and its time when it has one, `trailingPadding` and
    /// `naturalWidthSlack`, at 13pt in the row's weight. Measured on first
    /// use and cached.
    func naturalWidth(at index: Int) -> CGFloat {
        guard entries.indices.contains(index) else { return Metrics.textLeading + Metrics.trailingPadding }
        if naturalWidths.count != entries.count { clearWidths() }
        if let cached = naturalWidths[index] { return cached }
        let fonts = fullFonts
        let font = index == activeIndex ? fonts.active : fonts.regular
        let titleWidth = ceil(title(index, font: font, small: false).size().width)
        let label = timeText(at: index)
        let timeWidth = label.isEmpty ? 0 : ceil(timeString(label, font: fonts.time).size().width) + Metrics.timeGap
        let width = Metrics.textLeading + titleWidth + timeWidth
            + Metrics.trailingPadding + Metrics.naturalWidthSlack
        naturalWidths[index] = width
        measuredWidths += 1
        return width
    }

    // MARK: Shape

    /// The box for `rows` with the lens `openFraction` open, in a pane whose
    /// box can grow to `maxWidth`. A row's wanted width is `20 + (min(natural,
    /// maxWidth) − 20) × widthReveal(h)`, and the box is as wide as the
    /// widest. A row's text shows when `textOpacity(h) × openFraction` passes
    /// `textVisibleOpacity`; the box spans those rows' text bands.
    func shape(for rows: PromptRailLensRows, openFraction: CGFloat, maxWidth: CGFloat) -> PromptRailLensShape {
        guard openFraction > 0 else { return .closed }
        let rail = PromptRailLayout.width
        var width = rail
        var first: Int?
        var last: Int?
        for index in rows.heights.indices {
            let height = rows.heights[index]
            let reveal = Metrics.widthReveal(rowHeight: height)
            if reveal > 0 {
                let wanted = rail + (min(naturalWidth(at: index), maxWidth) - rail) * reveal
                width = max(width, wanted)
            }
            if Metrics.textOpacity(rowHeight: height) * openFraction > Metrics.textVisibleOpacity {
                if first == nil { first = index }
                last = index
            }
        }
        guard let first, let last else { return PromptRailLensShape(width: width, textRows: nil, box: nil) }
        guard width - rail > 2 else { return PromptRailLensShape(width: width, textRows: first...last, box: nil) }
        let firstBand = Self.textBand(row: first, in: rows)
        let lastBand = Self.textBand(row: last, in: rows)
        let top = firstBand.minY - Metrics.boxPadding
        let bottom = lastBand.maxY + Metrics.boxPadding
        return PromptRailLensShape(
            width: width, textRows: first...last,
            box: CGRect(x: 0, y: top, width: width, height: bottom - top))
    }

    /// Row `index`'s text band in `rows`, in rail coordinates, as a
    /// zero-width rect at x 0: the row itself, or, for a row taller than the
    /// lens's peak (a few-prompts rail), a band the peak's height centred on
    /// it (lens spec, "Drawing"). The row's text, its hover fill and its
    /// share of the box lie in it, so the box hugs the text rather than a row
    /// up to 184pt tall.
    static func textBand(row index: Int, in rows: PromptRailLensRows) -> CGRect {
        let height = rows.heights[index]
        let bandHeight = min(height, PromptRailLayout.lensPeak)
        return CGRect(x: 0, y: rows.tops[index] + (height - bandHeight) / 2, width: 0, height: bandHeight)
    }

    // MARK: Drawing

    /// Draws the lens: the box, the hovered row's fill, every notch `dirtyRect`
    /// reaches (the active one last, on top) faded at the ends `fades` names,
    /// and the text of the rows that show any, faded by `openFraction` and by
    /// the box's room. Call it from `draw(_:)`, where row text resolves its
    /// colours in the view's appearance; `notchColors` and `colors` are
    /// resolved in it already.
    func draw(
        rows: PromptRailLensRows,
        shape: PromptRailLensShape,
        openFraction: CGFloat,
        hoveredRow: Int?,
        workScale: PromptRailWorkScale,
        notchColors: PromptRailNotchPalette,
        colors: PromptRailLensPalette,
        railHeight: CGFloat,
        fades: PromptRailEndFades,
        dirtyRect: CGRect,
        in context: CGContext
    ) {
        guard rows.heights.count == entries.count, !entries.isEmpty else { return }
        if let box = shape.box { drawBox(box, in: context, colors: colors) }
        if let hoveredRow, rows.heights.indices.contains(hoveredRow) {
            drawHoverFill(row: hoveredRow, rows: rows, width: shape.width, color: colors.hoverFill, in: context)
        }
        drawNotches(
            rows: rows, workScale: workScale, colors: notchColors, railHeight: railHeight, fades: fades,
            dirtyRect: dirtyRect, in: context)

        guard let textRows = shape.textRows else { return }
        let roomOpacity = Metrics.textRoomOpacity(boxWidth: shape.width)
        guard roomOpacity > 0 else { return }
        for index in textRows {
            let band = Self.textBand(row: index, in: rows)
            // Text in the rail's insets would sit past its notches' fades.
            guard band.maxY > PromptRailLayout.topInset,
                  band.minY < railHeight - PromptRailLayout.bottomInset,
                  band.minY <= dirtyRect.maxY, band.maxY >= dirtyRect.minY
            else { continue }
            let alpha = Metrics.textOpacity(rowHeight: rows.heights[index]) * openFraction * roomOpacity
            guard alpha > Metrics.textVisibleOpacity else { continue }
            drawText(row: index, rows: rows, width: shape.width, alpha: alpha, in: context)
        }
    }

    /// Row `index`'s notch in `rows`: from `notchLeading`, `length` long and
    /// centred in the row. The active notch is 3pt thick, or the row's height
    /// down to 2pt; the rest are 2pt, or the row's height less 1pt down to
    /// 0.5pt. The mock's `drawNotch`.
    static func notchRect(row index: Int, in rows: PromptRailLensRows, active: Bool, length: CGFloat) -> CGRect {
        let height = rows.heights[index]
        let thickness = active
            ? min(PromptRailLayout.activeNotchHeight, max(PromptRailLayout.inactiveNotchHeight, height))
            : min(PromptRailLayout.inactiveNotchHeight, max(0.5, height - 1))
        let centre = rows.tops[index] + height / 2
        return CGRect(x: PromptRailLayout.notchLeading, y: centre - thickness / 2, width: length, height: thickness)
    }

    /// The box's outline (the mock's `drawBox`): from behind the rail's
    /// leading edge, an 8pt 45° taper out of the rail column into a box with
    /// rounded trailing corners, and the same taper back below it.
    static func boxPath(_ box: CGRect) -> CGPath {
        let rail = PromptRailLayout.width
        let width = box.maxX
        let top = box.minY
        let bottom = box.maxY
        let taper = max(0, min(Metrics.boxTaper, (width - rail) / 2))
        let radius = max(0, min(Metrics.boxCornerRadius, (bottom - top) / 2, width - rail - taper))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -2, y: top - taper))
        path.addLine(to: CGPoint(x: rail, y: top - taper))
        path.addLine(to: CGPoint(x: rail + taper, y: top))
        path.addArc(tangent1End: CGPoint(x: width, y: top), tangent2End: CGPoint(x: width, y: bottom), radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: width, y: bottom), tangent2End: CGPoint(x: rail + taper, y: bottom),
            radius: radius)
        path.addLine(to: CGPoint(x: rail + taper, y: bottom))
        path.addLine(to: CGPoint(x: rail, y: bottom + taper))
        path.addLine(to: CGPoint(x: -2, y: bottom + taper))
        path.closeSubpath()
        return path
    }

    private func drawBox(_ box: CGRect, in context: CGContext, colors: PromptRailLensPalette) {
        let path = Self.boxPath(box)
        context.saveGState()
        // The mock's shadow falls 2pt right and 1pt down. A shadow's offset
        // is in the context's base space, where y points up even in a flipped
        // view, so down is −1.
        context.setShadow(
            offset: CGSize(width: 2, height: -1), blur: Metrics.boxShadowRadius, color: colors.shadow)
        context.addPath(path)
        context.setFillColor(colors.background)
        context.fillPath()
        context.restoreGState()
        context.addPath(path)
        context.setStrokeColor(colors.border)
        context.setLineWidth(Metrics.boxBorderWidth)
        context.strokePath()
    }

    /// The hovered row's fill, over its text band.
    private func drawHoverFill(
        row index: Int, rows: PromptRailLensRows, width: CGFloat, color: CGColor, in context: CGContext
    ) {
        let band = Self.textBand(row: index, in: rows)
        let rect = CGRect(x: 1, y: band.minY, width: max(0, width - 2), height: band.height)
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = min(Metrics.hoverCornerRadius, rect.width / 2, rect.height / 2)
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    /// Every notch `dirtyRect` reaches, the active one last, on top. While a
    /// row runs past an end, the notches fade toward it over the rail's
    /// 24pt fade band, as the resting rail's layer mask fades them. They are
    /// drawn into a transparency layer and faded there, so the fade touches
    /// the notches alone, not the box or its text.
    private func drawNotches(
        rows: PromptRailLensRows, workScale: PromptRailWorkScale, colors: PromptRailNotchPalette,
        railHeight: CGFloat, fades: PromptRailEndFades, dirtyRect: CGRect, in context: CGContext
    ) {
        let fading = fades.top || fades.bottom
        if fading { context.beginTransparencyLayer(auxiliaryInfo: nil) }
        let margin = PromptRailLayout.activeNotchHeight
        if let first = rows.index(atY: dirtyRect.minY - margin),
           let last = rows.index(atY: dirtyRect.maxY + margin), first <= last {
            for index in first...last where index != activeIndex {
                fillNotch(index, rows: rows, workScale: workScale, colors: colors, in: context)
            }
        }
        if let activeIndex {
            fillNotch(activeIndex, rows: rows, workScale: workScale, colors: colors, in: context)
        }
        guard fading else { return }
        Self.fadeEnds(fades, railHeight: railHeight, in: context)
        context.endTransparencyLayer()
    }

    /// Erases what is drawn toward the ends `fades` names: all of it at the
    /// rail's edge, none of it `PromptRailLayout.fadeHeight` in (at most half
    /// the rail), on a straight ramp, the resting rail's mask's ramp.
    private static func fadeEnds(_ fades: PromptRailEndFades, railHeight: CGFloat, in context: CGContext) {
        let band = PromptRailFade.edgeFraction(height: railHeight) * railHeight
        // Gray and alpha: opaque at the start, clear at the end.
        let components: [CGFloat] = [0, 1, 0, 0]
        let locations: [CGFloat] = [0, 1]
        guard band > 0,
              let gradient = CGGradient(
                colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: components,
                locations: locations, count: 2)
        else { return }
        context.saveGState()
        context.setBlendMode(.destinationOut)
        if fades.top {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: band), options: [])
        }
        if fades.bottom {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: railHeight), end: CGPoint(x: 0, y: railHeight - band), options: [])
        }
        context.restoreGState()
    }

    private func fillNotch(
        _ index: Int, rows: PromptRailLensRows, workScale: PromptRailWorkScale,
        colors: PromptRailNotchPalette, in context: CGContext
    ) {
        guard rows.heights.indices.contains(index) else { return }
        let active = index == activeIndex
        let rect = Self.notchRect(row: index, in: rows, active: active, length: workScale.length(at: index))
        guard rect.width > 0, rect.height > 0 else { return }
        context.setFillColor(colors.color(for: entries[index].kind, active: active))
        if rect.height >= 1.5 {
            let radius = min(rect.width, rect.height) / 2
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        } else {
            context.fill(rect)
        }
    }

    /// Row `index`'s first line from `textLeading`, truncated at the tail
    /// where the time or the box's padding begins, and its time right-aligned
    /// `trailingPadding` in from the box's edge, both centred on the row.
    private func drawText(row index: Int, rows: PromptRailLensRows, width: CGFloat, alpha: CGFloat, in context: CGContext) {
        let height = rows.heights[index]
        let small = height < Metrics.fullTextRowHeight
        let fonts = small ? smallFonts : fullFonts
        let centre = rows.tops[index] + height / 2
        var trailing = width - Metrics.trailingPadding

        context.saveGState()
        context.setAlpha(alpha)
        // Text never strays past the box, sideways: not even a time wider
        // than a narrow box's room.
        context.clip(to: CGRect(
            x: Metrics.textLeading, y: centre - fonts.lineHeight,
            width: max(0, width - Metrics.textLeading), height: fonts.lineHeight * 2))
        let label = timeText(at: index)
        if !label.isEmpty {
            let time = timeString(label, font: fonts.time)
            let size = time.size()
            time.draw(
                with: NSRect(x: trailing - size.width, y: centre - size.height / 2, width: size.width, height: size.height),
                options: [.usesLineFragmentOrigin])
            trailing -= size.width + Metrics.timeGap
        }
        let font = index == activeIndex ? fonts.active : fonts.regular
        title(index, font: font, small: small).draw(
            with: NSRect(
                x: Metrics.textLeading, y: centre - fonts.lineHeight / 2,
                width: max(0, trailing - Metrics.textLeading), height: fonts.lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        context.restoreGState()
    }

    /// The row's first line, "sender: " first for a peer with the sender in
    /// lavender. A small row's line is in the secondary label colour.
    private func title(_ index: Int, font: NSFont, small: Bool) -> NSAttributedString {
        let entry = entries[index]
        let color: NSColor = small ? .secondaryLabelColor : .labelColor
        let result = NSMutableAttributedString()
        if case .peer(let sender) = entry.kind {
            result.append(NSAttributedString(string: sender, attributes: [
                .font: font, .foregroundColor: PeerLavender.nsColor(alpha: 1), .paragraphStyle: truncating,
            ]))
            result.append(NSAttributedString(string: ": ", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: truncating,
            ]))
        }
        result.append(NSAttributedString(string: String(entry.firstLine.prefix(Metrics.drawnPrefix)), attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: truncating,
        ]))
        return result
    }

    private func timeString(_ label: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
    }
}
