import AppKit

// Presentation both prompt rail renderers share: notch colours, the edge
// fade's extent, the card's metrics and the rail's accessibility labels. It
// lives beside the shared core rather than in either renderer's folder, so the
// follow-up that deletes one renderer deletes only that folder.

/// Notch and dash colours, shared by both renderers' rails and cards so a
/// card's dashes match the notches they sit over.
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

/// The 24pt edge fade both renderers put over a clipped edge of the rail and
/// of the card's list. Each renderer spells the mask in its own framework.
enum PromptRailFade {
    /// The fraction of a view `height` tall that each edge's fade covers:
    /// `PromptRailLayout.fadeHeight`, at most half the view.
    static func edgeFraction(height: CGFloat) -> CGFloat {
        height > 0 ? min(0.5, PromptRailLayout.fadeHeight / height) : 0
    }
}

/// The card's geometry, typography and timing, shared by both renderers'
/// cards so the two differ in framework alone.
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

/// The rail's accessibility, shared by both renderers' rails.
enum PromptRailAccessibility {
    /// An entry's button label: "<first line>, <time>", or the first line
    /// alone when the entry has no time.
    static func label(for entry: PromptOutlineEntry, now: Date) -> String {
        let time = PromptOutline.timeLabel(entry.timestamp, now: now, calendar: .current, locale: .current)
        return time.isEmpty ? entry.firstLine : "\(entry.firstLine), \(time)"
    }
}
