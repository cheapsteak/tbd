import AppKit
import os
import SwiftUI

private let logger = Logger(subsystem: "com.tbd.app", category: "prompt-rail")

/// Presents the SwiftUI renderer's card over the rail: the overlay
/// `PromptRailContainer` lays over its rail and table. It owns the card's
/// lifetime on screen, so the pane around it never reads the hover model or
/// the outline.
///
/// - **Shown** – while the hover model has the card open and it has at least
///   one row. A rail with no prompts opens no empty card, and an open card
///   shows as soon as a prompt arrives.
/// - **Fade** – the card fades in over `PromptRailCardMetrics.fadeDuration`,
///   easing out, and leaves at once: Escape, a row click and app deactivation
///   close it at once, and the hover grace has already been spent by then.
/// - **Escape** – the monitor runs exactly while the card is shown. It is
///   app-wide, so an open card with no rows, which shows nothing, must not
///   take Escape from every other view in the window.
/// - **Key window** – the card closes when its window stops being key, and
///   tells `PromptRailPointer` whether rail hover counts, so a card never
///   holds the app-wide Escape monitor from a background window.
struct PromptRailCardOverlay: View {
    let state: PromptRailState
    let hover: PromptRailHoverModel
    let pointer: PromptRailPointer
    let escape: PromptRailEscapeMonitor
    let earlier: PromptRailEarlierHistory?

    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let hover = self.hover
        let pointer = self.pointer
        let escape = self.escape
        let shown = Self.isShown(isOpen: hover.isOpen, entryCount: state.entries.count, earlier: earlier)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if shown {
                    // The pointer is read here, once per opening, rather than
                    // observed: a pointer moving over the rail re-renders nothing.
                    PromptRailCardView(
                        state: state,
                        hover: hover,
                        pointedIndex: pointer.pointedIndex,
                        earlier: earlier,
                        maxWidth: proxy.size.width,
                        maxHeight: proxy.size.height,
                        pointerY: pointer.pointerY)
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                        .zIndex(1)
                }
            }
        }
        // The overlay spans the pane; with no card it must take no clicks
        // from the table under it.
        .allowsHitTesting(shown)
        .animation(.easeOut(duration: PromptRailCardMetrics.fadeDuration), value: shown)
        .onChange(of: shown, initial: true) { _, shown in
            if shown {
                escape.start { hover.dismiss(.escape) }
            } else {
                escape.stop()
            }
        }
        .onChange(of: appearsActive, initial: true) { _, active in
            pointer.windowKeyChanged(active, hover: hover)
        }
        .onDisappear { escape.stop() }
    }

    /// Whether the card is on screen: open, with at least one row.
    static func isShown(isOpen: Bool, entryCount: Int, earlier: PromptRailEarlierHistory?) -> Bool {
        isOpen && PromptRailCardView.rowCount(entryCount: entryCount, showsEarlierRow: earlier?.hasEarlier == true) > 0
    }
}

/// The SwiftUI renderer's hover card: every prompt by first line and time,
/// anchored at the rail's top-left with its dash column over the rail's
/// notches. Geometry, typography and colours are shared with the AppKit card
/// (`PromptRailCardMetrics`, `PromptRailNotchStyle`), so the two renderers
/// differ in framework alone.
///
/// - **Size** – `PromptRailCardMetrics.maxWidth` wide, capped at `maxWidth`
///   (the pane's width) minus `PromptRailCardMetrics.paneInset`, and at most
///   `maxHeight` (the rail's height) less
///   `PromptRailCardMetrics.bottomClearance` tall, which keeps the pane's
///   jump-to-bottom button clear of it. A longer list scrolls inside, without
///   scrollers, behind 24pt fades over whichever edge clips a row.
/// - **Opening** – the card is built afresh each time it opens, with its list
///   scrolled so the row for `pointedIndex` sits under `pointerY`, or as close
///   as the card's height and the list's ends allow.
/// - **Updates** – a new outline while open updates the rows in place; the
///   card keeps its identity and its scroll position.
/// - **Rows** – a click jumps through `state.onJump` and closes the card at
///   once; a truncated row shows its prompt's first 500 characters as a
///   tooltip.
/// - **Earlier history** – with older Remote history not loaded, the first
///   row reads "Earlier prompts not loaded" beside a Load button that calls
///   the pane's load-earlier action. Nothing else here loads history.
///
/// It lives outside the transcript's row list and is never measured as a
/// row, which is why its `ScrollView` is allowed in this directory.
struct PromptRailCardView: View {
    private typealias Metrics = PromptRailCardMetrics

    let state: PromptRailState
    let hover: PromptRailHoverModel
    /// The notch under the pointer when the card opened.
    let pointedIndex: Int?
    let earlier: PromptRailEarlierHistory?
    /// The pane's width, which caps the card's.
    let maxWidth: CGFloat
    /// The rail's height, which caps the card's.
    let maxHeight: CGFloat

    @State private var position: ScrollPosition
    @State private var hoveredRow: Int?
    @State private var fades = EdgeFades()
    /// "Today" for the time labels, read once per opening.
    @State private var openedAt = Date()

    /// - Parameter pointerY: The pointer's y over the rail when the card
    ///   opened; the pointed row's centre is scrolled under it.
    init(
        state: PromptRailState,
        hover: PromptRailHoverModel,
        pointedIndex: Int?,
        earlier: PromptRailEarlierHistory?,
        maxWidth: CGFloat,
        maxHeight: CGFloat = .infinity,
        pointerY: CGFloat = 0
    ) {
        self.state = state
        self.hover = hover
        self.pointedIndex = pointedIndex
        self.earlier = earlier
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight

        let showsEarlierRow = earlier?.hasEarlier == true
        let entryCount = state.entries.count
        let rowCount = Self.rowCount(entryCount: entryCount, showsEarlierRow: showsEarlierRow)
        let pointedRow = pointedIndex.flatMap { index in
            (0..<entryCount).contains(index) ? index + (showsEarlierRow ? 1 : 0) : nil
        }
        let height = Self.height(rowCount: rowCount, maxHeight: maxHeight)
        let offset = pointedRow.map {
            Self.openOffset(row: $0, under: pointerY, rowCount: rowCount, cardHeight: height)
        } ?? 0
        _position = State(initialValue: ScrollPosition(y: offset))
        _hoveredRow = State(initialValue: pointedRow)
    }

    var body: some View {
        let entries = state.entries
        let active = state.activeIndex
        let rows = Self.rows(entries: entries, showsEarlierRow: earlier?.hasEarlier == true)
        let width = Self.width(paneWidth: maxWidth)
        let height = Self.height(rowCount: rows.count, maxHeight: maxHeight)
        let overflows = Self.contentHeight(rowCount: rows.count) > height + 0.5
        let shape = RoundedRectangle(cornerRadius: Metrics.cornerRadius)

        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    if let index = row.entryIndex {
                        entryRow(entries[index], row: row.position, active: index == active, width: width)
                    } else {
                        earlierRow(width: width)
                    }
                }
            }
            .padding(.vertical, Metrics.verticalPadding)
        }
        .scrollIndicators(.never)
        .scrollPosition($position)
        .onScrollGeometryChange(for: EdgeFades.self) { geometry in
            EdgeFades.of(geometry)
        } action: { _, new in
            fades = new
        }
        .frame(width: width, height: height)
        .mask {
            if overflows {
                PromptRailFade.gradient(height: height, fadesTop: fades.top, fadesBottom: fades.bottom)
            } else {
                Rectangle()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
        .shadow(color: Color(nsColor: .shadowColor).opacity(0.2), radius: 8)
        .contentShape(shape)
        .onHover { hover.cardHoverChanged($0) }
    }

    // MARK: Rows

    /// One row of the list: the earlier row or an entry's.
    struct Row: Identifiable, Equatable {
        /// The row's identity: an entry's row is its node's.
        enum Key: Hashable {
            case earlier
            case entry(String)
        }

        let id: Key
        /// Position in the list, the earlier row included.
        let position: Int
        /// The entry the row shows; nil for the earlier row.
        let entryIndex: Int?
    }

    /// The list's rows: the "Earlier prompts not loaded" row first when it
    /// shows, then one per entry.
    static func rows(entries: [PromptOutlineEntry], showsEarlierRow: Bool) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(entries.count + 1)
        if showsEarlierRow {
            rows.append(Row(id: .earlier, position: 0, entryIndex: nil))
        }
        let base = rows.count
        for (index, entry) in entries.enumerated() {
            rows.append(Row(id: .entry(entry.id), position: base + index, entryIndex: index))
        }
        return rows
    }

    private func entryRow(_ entry: PromptOutlineEntry, row: Int, active: Bool, width: CGFloat) -> some View {
        let time = PromptOutline.timeLabel(entry.timestamp, now: openedAt, calendar: .current, locale: .current)
        let dash = active ? PromptRailLayout.activeNotch : PromptRailLayout.inactiveNotch
        let state = self.state
        let hover = self.hover
        return Button {
            Self.activate(entry.id, state: state, hover: hover)
        } label: {
            HStack(spacing: 0) {
                Capsule()
                    .fill(Color(nsColor: PromptRailNotchStyle.color(for: entry.kind, active: active)))
                    .frame(width: dash.width, height: dash.height)
                    .frame(width: Metrics.dashColumnWidth, alignment: .leading)
                    .padding(.trailing, Metrics.dashGap)
                Self.titleView(entry, active: active)
                Spacer(minLength: time.isEmpty ? 0 : Metrics.timeGap)
                if !time.isEmpty {
                    Text(time)
                        .font(.system(size: Metrics.fontSize).monospacedDigit())
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.leading, Metrics.dashColumnLeading)
            .padding(.trailing, Metrics.trailingPadding)
            .frame(width: width, height: Metrics.rowHeight)
            .background {
                if hoveredRow == row {
                    RoundedRectangle(cornerRadius: Metrics.hoverCornerRadius)
                        .fill(Color(nsColor: .quaternarySystemFill))
                        .padding(.horizontal, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredRow = row
            } else if hoveredRow == row {
                hoveredRow = nil
            }
        }
    }

    /// The row's title, carrying the prompt's first 500 characters as a
    /// tooltip only when it is truncated: the full line is taken when it fits.
    private static func titleView(_ entry: PromptOutlineEntry, active: Bool) -> some View {
        let text = title(entry, active: active)
        return ViewThatFits(in: .horizontal) {
            text.fixedSize()
            text
                .lineLimit(1)
                .truncationMode(.tail)
                .help(entry.tooltip)
        }
    }

    /// The first line, after "sender: " in amber for a peer; medium weight
    /// for the active row.
    static func title(_ entry: PromptOutlineEntry, active: Bool) -> Text {
        let line = String(entry.firstLine.prefix(Metrics.drawnPrefix))
        let text: Text
        switch entry.kind {
        case .prompt:
            text = Text(line)
        case .peer(let sender):
            text = Text("\(Text(sender).foregroundStyle(AttentionAmber.color)): \(line)")
        }
        return text
            .font(.system(size: Metrics.fontSize, weight: active ? .medium : .regular))
            .foregroundStyle(Color(nsColor: .labelColor))
    }

    private func earlierRow(width: CGFloat) -> some View {
        let earlier = self.earlier
        return HStack(spacing: 0) {
            Text(Metrics.earlierRowText)
                .font(.system(size: Metrics.fontSize))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Metrics.timeGap)
            Button("Load") {
                logger.debug("card load earlier pressed")
                earlier?.load()
            }
            .controlSize(.small)
        }
        .padding(.leading, Metrics.textLeading)
        .padding(.trailing, Metrics.trailingPadding)
        .frame(width: width, height: Metrics.rowHeight)
    }

    /// A click on an entry's row: jump to its prompt, then close the card at
    /// once. The same path the row's button takes.
    static func activate(_ entryID: String, state: PromptRailState, hover: PromptRailHoverModel) {
        logger.debug("card row clicked id=\(entryID, privacy: .public)")
        state.onJump?(entryID)
        hover.dismiss(.click)
    }

    // MARK: Geometry

    /// `PromptRailCardMetrics.maxWidth`, capped at the pane's width minus
    /// `PromptRailCardMetrics.paneInset`.
    static func width(paneWidth: CGFloat) -> CGFloat {
        max(0, min(Metrics.maxWidth, paneWidth - Metrics.paneInset))
    }

    /// Rows in the list, the earlier row included.
    static func rowCount(entryCount: Int, showsEarlierRow: Bool) -> Int {
        entryCount + (showsEarlierRow ? 1 : 0)
    }

    /// The list's full height: its rows inside the vertical padding.
    static func contentHeight(rowCount: Int) -> CGFloat {
        Metrics.verticalPadding * 2 + CGFloat(rowCount) * Metrics.rowHeight
    }

    /// As tall as the rows, up to `maxHeight` (the rail's height) less
    /// `PromptRailCardMetrics.bottomClearance`.
    static func height(rowCount: Int, maxHeight: CGFloat) -> CGFloat {
        Metrics.height(contentHeight: contentHeight(rowCount: rowCount), railHeight: maxHeight)
    }

    /// The list offset that puts the centre of `row` at `pointerY` in card
    /// coordinates, or as close as the card's height and the list's ends
    /// allow (`PromptRailCardMetrics.openOffset`).
    static func openOffset(row: Int, under pointerY: CGFloat, rowCount: Int, cardHeight: CGFloat) -> CGFloat {
        Metrics.openOffset(
            row: row, pointerY: pointerY, contentHeight: contentHeight(rowCount: rowCount), cardHeight: cardHeight)
    }
}

/// Which edges of the card's list clip a row, and so fade.
private struct EdgeFades: Equatable {
    var top = false
    var bottom = false

    static func of(_ geometry: ScrollGeometry) -> EdgeFades {
        let offset = geometry.contentOffset.y
        return EdgeFades(
            top: offset > 0.5,
            bottom: offset + geometry.containerSize.height < geometry.contentSize.height - 0.5)
    }
}
