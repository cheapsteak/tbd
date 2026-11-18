import AppKit

// Presentation the rail and its lens share: notch colours, the edge fade's
// extent, the lens's row and box metrics, and the rail's accessibility
// labels. Notch lengths are `PromptRailWorkScale`'s.

/// Notch colours, the same at rest and in the lens's rows.
enum PromptRailNotchStyle {
    /// Alpha of an inactive peer notch: lavender at reduced opacity.
    static let inactivePeerAlpha: CGFloat = 0.5

    /// A dynamic colour; resolve it inside the drawing appearance.
    static func color(for kind: PromptOutlineEntry.Kind, active: Bool) -> NSColor {
        switch kind {
        case .prompt:
            return active ? .controlAccentColor : .tertiaryLabelColor
        case .peer:
            return PeerLavender.nsColor(alpha: active ? 1 : inactivePeerAlpha)
        }
    }
}

/// Every notch colour resolved for one appearance, so a draw pass resolves
/// each dynamic colour once rather than once per notch. A `CGColor` is fixed
/// the moment it is made, so a palette belongs to the draw that made it.
struct PromptRailNotchPalette: Equatable {
    let prompt: CGColor
    let activePrompt: CGColor
    let peer: CGColor
    let activePeer: CGColor

    /// Resolves each colour in the current drawing appearance: call it from
    /// `draw(_:)` or inside `performAsCurrentDrawingAppearance`. A peer's
    /// colour does not depend on its sender.
    static func resolvedInCurrentAppearance() -> PromptRailNotchPalette {
        let peer = PromptOutlineEntry.Kind.peer(sender: "")
        return PromptRailNotchPalette(
            prompt: PromptRailNotchStyle.color(for: .prompt, active: false).cgColor,
            activePrompt: PromptRailNotchStyle.color(for: .prompt, active: true).cgColor,
            peer: PromptRailNotchStyle.color(for: peer, active: false).cgColor,
            activePeer: PromptRailNotchStyle.color(for: peer, active: true).cgColor)
    }

    func color(for kind: PromptOutlineEntry.Kind, active: Bool) -> CGColor {
        switch kind {
        case .prompt:
            return active ? activePrompt : prompt
        case .peer:
            return active ? activePeer : peer
        }
    }
}

/// The 24pt edge fade over a clipped edge of the rail.
/// `configure(_:height:fadesTop:fadesBottom:)` spells it as a layer mask.
enum PromptRailFade {
    /// The fraction of a view `height` tall that each edge's fade covers:
    /// `PromptRailLayout.fadeHeight`, at most half the view.
    static func edgeFraction(height: CGFloat) -> CGFloat {
        height > 0 ? min(0.5, PromptRailLayout.fadeHeight / height) : 0
    }
}

/// The lens's readable rows and the box behind them: geometry and
/// typography (lens spec, "Drawing").
enum PromptRailRowMetrics {
    // MARK: Width

    /// The widest the box grows.
    static let maxWidth: CGFloat = 320
    /// The box leaves this much of the pane's width uncovered.
    static let paneInset: CGFloat = 24
    /// Room the overlay keeps past the box's widest for the box's shadow,
    /// which the overlay's layer would otherwise clip.
    static let shadowRoom: CGFloat = 12

    /// The widest the box grows over a pane `paneWidth` wide: `maxWidth`
    /// capped at the pane's width less `paneInset`, and never narrower than
    /// the rail itself.
    static func boxMaxWidth(paneWidth: CGFloat) -> CGFloat {
        max(PromptRailLayout.width, min(maxWidth, paneWidth - paneInset))
    }

    /// The rail overlay's width while a lens exists, opening, open or
    /// closing: the box's widest plus `shadowRoom`, capped at the pane's
    /// width, and never narrower than the rail. With no lens the overlay is
    /// the rail column alone.
    static func openOverlayWidth(paneWidth: CGFloat) -> CGFloat {
        max(PromptRailLayout.width, min(paneWidth, boxMaxWidth(paneWidth: paneWidth) + shadowRoom))
    }

    // MARK: Row layout

    /// Starts at the rail's notch leading edge, so a row's dash is its notch.
    static let dashColumnLeading: CGFloat = PromptRailLayout.notchLeading
    static let dashColumnWidth: CGFloat = 18
    static let dashGap: CGFloat = 8
    static let trailingPadding: CGFloat = 10
    static let timeGap: CGFloat = 8
    /// Characters of a first line that are laid out at all. Far more than a
    /// 320pt row can show, so a longer line still truncates at the tail,
    /// while the first line of a large paste costs no more to lay out than a
    /// short one.
    static let drawnPrefix = 400

    /// Where row text starts: after the dash column and its gap.
    static var textLeading: CGFloat { dashColumnLeading + dashColumnWidth + dashGap }
    /// Where the dash column ends: the rail's own trailing edge, since a
    /// row's dash is its notch.
    static var dashColumnTrailing: CGFloat { dashColumnLeading + dashColumnWidth }

    // MARK: Text

    /// The text size of a row at least `fullTextRowHeight` tall.
    static let fontSize: CGFloat = 13
    /// The text size of a row shorter than `fullTextRowHeight`.
    static let smallFontSize: CGFloat = 10.5
    /// The row height from which text is `fontSize` rather than `smallFontSize`.
    static let fullTextRowHeight: CGFloat = 15
    /// The row height at which a row's text starts to fade in. Its opacity is
    /// `(h − textFadeStart) / textFadeLength`, clamped to 0…1, for a row `h`
    /// tall.
    static let textFadeStart: CGFloat = 10.5
    static let textFadeLength: CGFloat = 2.5
    /// A row's wanted width grows with its height on a smoothstep, from the
    /// rail's width at `widthRevealStart` tall to its full width at
    /// `widthRevealEnd`.
    static let widthRevealStart: CGFloat = 8.5
    static let widthRevealEnd: CGFloat = 14
    /// A row's text shows only above this opacity, and the box spans only
    /// the rows whose text shows.
    static let textVisibleOpacity: CGFloat = 0.01
    /// Row text fades out as the room between `textLeading` and the box's
    /// trailing padding shrinks from twice this to this, and is gone below
    /// it: a box too narrow for any of a title shows no text rather than a
    /// bare time.
    static let textRoomFadeLength: CGFloat = 48

    /// A row `h` tall's text opacity, before the lens's open fraction:
    /// `(h − textFadeStart) / textFadeLength`, clamped to 0…1.
    static func textOpacity(rowHeight h: CGFloat) -> CGFloat {
        min(1, max(0, (h - textFadeStart) / textFadeLength))
    }

    /// How far a row `h` tall has grown from the rail's width toward its full
    /// width: a smoothstep from `widthRevealStart` to `widthRevealEnd`.
    static func widthReveal(rowHeight h: CGFloat) -> CGFloat {
        let t = min(1, max(0, (h - widthRevealStart) / (widthRevealEnd - widthRevealStart)))
        return t * t * (3 - 2 * t)
    }

    /// How much of a row's text shows in a box `boxWidth` wide, by the room
    /// left for it: none up to `textRoomFadeLength`, all from twice that.
    static func textRoomOpacity(boxWidth: CGFloat) -> CGFloat {
        let room = boxWidth - textLeading - trailingPadding
        return min(1, max(0, (room - textRoomFadeLength) / textRoomFadeLength))
    }

    // MARK: Hovered row

    static let hoverCornerRadius: CGFloat = 6
    /// The hovered row's fill shows only once the lens is more open than this.
    static let hoverMinOpenFraction: CGFloat = 0.6
    /// The hovered row's fill shows only on a row at least this tall.
    static let hoverMinRowHeight: CGFloat = 11

    // MARK: Box

    /// The box reaches this far above its first readable row and below its last.
    static let boxPadding: CGFloat = 3
    /// The radius of the box's trailing corners.
    static let boxCornerRadius: CGFloat = 8
    /// The 45° taper that joins the box to the rail column above and below it.
    static let boxTaper: CGFloat = 8
    static let boxBorderWidth: CGFloat = 0.5
    static let boxShadowRadius: CGFloat = 8
    static let boxShadowOpacity: CGFloat = 0.2
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
