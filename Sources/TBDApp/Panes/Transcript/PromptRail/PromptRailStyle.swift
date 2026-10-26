import AppKit

// Presentation the rail and the card share: notch colours, the edge fade's
// extent, the card's metrics and its rows' expansion, and the rail's
// accessibility labels. Notch lengths are `PromptRailWorkScale`'s.

/// Notch and dash colours, shared by the rail and the card so a card's dashes
/// match the notches they sit over.
enum PromptRailNotchStyle {
    /// Alpha of an inactive peer notch: amber at reduced opacity.
    static let inactivePeerAlpha: CGFloat = 0.5

    /// A dynamic colour; resolve it inside the drawing appearance.
    static func color(for kind: PromptOutlineEntry.Kind, active: Bool) -> NSColor {
        switch kind {
        case .prompt:
            return active ? .controlAccentColor : .tertiaryLabelColor
        case .peer:
            return AttentionAmber.nsColor(alpha: active ? 1 : inactivePeerAlpha)
        }
    }
}

/// The 24pt edge fade over a clipped edge of the rail and of the card's list.
/// `configure(_:height:fadesTop:fadesBottom:)` spells it as a layer mask.
enum PromptRailFade {
    /// The fraction of a view `height` tall that each edge's fade covers:
    /// `PromptRailLayout.fadeHeight`, at most half the view.
    static func edgeFraction(height: CGFloat) -> CGFloat {
        height > 0 ? min(0.5, PromptRailLayout.fadeHeight / height) : 0
    }
}

/// The card's geometry, typography and timing.
enum PromptRailCardMetrics {
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
    /// Characters of a first line that are laid out at all. Far more than a
    /// 320pt row can show, so a longer line still truncates at the tail,
    /// while the first line of a large paste costs no more to lay out than a
    /// short one.
    static let drawnPrefix = 400

    /// The card stops this far above the bottom of the rail, which keeps the
    /// pane's bottom-corner jump-to-bottom button clear of it.
    static let bottomClearance: CGFloat = 60

    /// Where row text starts: after the dash column and its gap.
    static var textLeading: CGFloat { dashColumnLeading + dashColumnWidth + dashGap }
    /// Where the dash column ends: the rail's own trailing edge, since the
    /// card's dashes sit over its notches.
    static var dashColumnTrailing: CGFloat { dashColumnLeading + dashColumnWidth }

    /// Whether a point `x` along a row, in list coordinates, is over the
    /// row's text — its first line and time — rather than its dash column.
    /// A row expands only for a pointer over its text.
    static func isOverRowText(x: CGFloat) -> Bool {
        x >= dashColumnTrailing
    }

    /// The card's height over a list `contentHeight` tall and a rail
    /// `railHeight` tall: the list's, up to the rail's less `bottomClearance`.
    static func height(contentHeight: CGFloat, railHeight: CGFloat) -> CGFloat {
        max(0, min(contentHeight, railHeight - bottomClearance))
    }

    /// Where the pointed row's centre goes when the card opens: the pointer's
    /// y, in card coordinates (the rail's, since the card sits at its
    /// top-left), held at least half a row inside the card's top and bottom.
    /// The card stops `bottomClearance` short of the rail's bottom, so a
    /// pointer over that stretch would otherwise put its row below the card.
    static func pointedRowCentre(pointerY: CGFloat, cardHeight: CGFloat) -> CGFloat {
        let half = rowHeight / 2
        return max(half, min(pointerY, cardHeight - half))
    }

    /// The list offset that opens the card with `row`'s centre at
    /// `pointedRowCentre(pointerY:cardHeight:)`, clamped to the list's ends:
    /// the row sits under the pointer, or as close as the card's height and
    /// the list's ends allow. Either clamp keeps the row inside the card.
    static func openOffset(row: Int, pointerY: CGFloat, contentHeight: CGFloat, cardHeight: CGFloat) -> CGFloat {
        let target = pointedRowCentre(pointerY: pointerY, cardHeight: cardHeight)
        let maxOffset = max(0, contentHeight - cardHeight)
        return min(max(0, rowRect(row, width: 0).midY - target), maxOffset)
    }

    /// A row's rectangle in list coordinates.
    static func rowRect(_ row: Int, width: CGFloat) -> NSRect {
        NSRect(
            x: 0, y: verticalPadding + CGFloat(row) * rowHeight,
            width: width, height: rowHeight)
    }
}

/// Where a card row's expansion goes: how many lines of its prompt it shows,
/// and whether it grows up to the row rather than down from it.
struct PromptRailExpansionPlacement: Equatable {
    let lines: Int
    let growsUpward: Bool
}

extension PromptRailCardMetrics {
    /// How long the pointer rests on a row before the row expands.
    static let expansionDelay = Duration.milliseconds(150)
    /// Lines of its prompt an expansion shows at most.
    static let expansionMaxLines = 6

    /// The height of an expansion showing `lines` lines of its prompt, each
    /// `lineHeight` tall, and its tool-call line: the row's own height, which
    /// holds one line centred in it, plus a line for each of the rest. The
    /// line on the row keeps the row's padding above and below it.
    static func expansionHeight(lines: Int, lineHeight: CGFloat) -> CGFloat {
        rowHeight + CGFloat(max(0, lines)) * lineHeight
    }

    /// The part of the list's `clip` rect, in list coordinates, an expansion
    /// may cover: the clip less each edge fade that is on, which covers
    /// `PromptRailFade.edgeFraction(height:)` of the clip at that edge.
    static func expansionRoom(clip: NSRect, fadesTop: Bool, fadesBottom: Bool) -> NSRect {
        let fade = PromptRailFade.edgeFraction(height: clip.height) * clip.height
        let top = clip.minY + (fadesTop ? fade : 0)
        let bottom = clip.maxY - (fadesBottom ? fade : 0)
        return NSRect(x: clip.minX, y: top, width: clip.width, height: max(0, bottom - top))
    }

    /// Where an expansion of `row` goes within the list's `visible` rect,
    /// both in list coordinates, for a prompt that would fill `wantedLines`
    /// lines `lineHeight` tall.
    ///
    /// It grows down from the row when all `wantedLines` fit below the row's
    /// top, and otherwise up to the row's bottom when they fit above it. When
    /// they fit neither way it shows as many as fit, growing whichever way has
    /// more room. Nil when not even one line fits beside the tool-call line,
    /// or there is nothing to show.
    static func expansionPlacement(
        row: NSRect, visible: NSRect, wantedLines: Int, lineHeight: CGFloat
    ) -> PromptRailExpansionPlacement? {
        guard wantedLines > 0, lineHeight > 0 else { return nil }
        // Laid-out heights are fractional; a hair over the room still fits.
        let slack: CGFloat = 0.01
        let below = visible.maxY - row.minY
        let above = row.maxY - visible.minY
        let wanted = expansionHeight(lines: wantedLines, lineHeight: lineHeight)
        if wanted <= below + slack { return PromptRailExpansionPlacement(lines: wantedLines, growsUpward: false) }
        if wanted <= above + slack { return PromptRailExpansionPlacement(lines: wantedLines, growsUpward: true) }
        let growsUpward = above > below
        let room = growsUpward ? above : below
        let fitting = Int(((room - rowHeight) / lineHeight + slack).rounded(.down))
        let lines = min(wantedLines, fitting)
        return lines > 0 ? PromptRailExpansionPlacement(lines: lines, growsUpward: growsUpward) : nil
    }
}

/// The rail's accessibility.
enum PromptRailAccessibility {
    /// An entry's button label: "<first line>, <time>, <work>", as in
    /// "fix the rail, 14:02, 40 tool calls"; with no time, "<first line>,
    /// <work>".
    static func label(for entry: PromptOutlineEntry, workCount: Int, now: Date) -> String {
        let time = PromptOutline.timeLabel(entry.timestamp, now: now, calendar: .current, locale: .current)
        let work = PromptOutline.workLabel(workCount)
        return time.isEmpty ? "\(entry.firstLine), \(work)" : "\(entry.firstLine), \(time), \(work)"
    }
}
