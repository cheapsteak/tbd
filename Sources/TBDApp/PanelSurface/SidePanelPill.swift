import AppKit
import SwiftUI

// The side region's toggle pills: Changes, the transcript and Notes, each one
// control that turns its panel on and off and shows the panel's name while it
// is open. Spec: docs/specs/2026-11-03-side-panel-toggle-pills-design.md.

// MARK: - SidePanelPillState

/// The state of one of the three toggles at the window's right edge
/// (`TabRowEdgeControls`), read from the decision a press of it sends, so what
/// the toggle shows and what it does cannot disagree.
enum SidePanelPillState: Equatable {
    /// No panel shows the content: a press opens one.
    case off
    /// The panel is in front of a visible side region: a press closes it.
    case front
    /// The panel exists, but another panel is in front of it or the region is
    /// collapsed: a press brings it to the front, which expands the region.
    case behind

    /// Whether the panel exists, in front or behind.
    var isOn: Bool { self != .off }

    /// The state a Changes or transcript toggle's decision
    /// (`PanelToggleDecision`) stands for: `open` is off, `select` behind and
    /// `close` in front.
    static func state(for decision: PanelToggleDecision) -> SidePanelPillState {
        switch decision {
        case .open: .off
        case .select: .behind
        case .close: .front
        }
    }

    /// The state the Notes toggle's decision (`NotesToggleDecision`) stands
    /// for: a create, an open, or a toggle that cannot act yet is off,
    /// `select` behind and `close` in front.
    static func state(for decision: NotesToggleDecision) -> SidePanelPillState {
        switch decision {
        case .create, .unavailable, .open: .off
        case .select: .behind
        case .close: .front
        }
    }
}

// MARK: - SidePanelPillMetrics

/// A pill's geometry, and the rule for when the pills that are on show their
/// labels.
///
/// Off, a pill is its icon alone in a row icon button's square,
/// `RowIconSquare.standardSide` wide, so the strip's fixed controls take
/// `SideStripMetrics.fixedControlsWidth` with every pill off. A label adds
/// `labelExtra` to its pill: the icon keeps its place, centred where the
/// square centres it, and the label follows it. Every width here is a whole
/// number of points, so the label rule's thresholds are too.
@MainActor
enum SidePanelPillMetrics {
    /// The icon's and the label's point size, the strip's tab titles' size.
    static let fontSize: CGFloat = 11
    /// The width the icon is centred in.
    static let iconSlotWidth: CGFloat = 14
    /// Between the icon's slot and the label.
    static let iconToLabelSpacing: CGFloat = 4
    /// After the label, to the pill's trailing end.
    static let trailingPadding: CGFloat = 8
    /// A behind pill's outline: the primary colour at this opacity.
    static let outlineOpacity: Double = 0.2
    /// A behind pill's outline width.
    static let outlineWidth: CGFloat = 1

    /// Before the icon's slot: what centres the slot where the square centres
    /// the icon of a pill that is off.
    static var leadingPadding: CGFloat {
        (RowIconSquare.standardSide - iconSlotWidth) / 2
    }

    /// Each pill label's width, measured once.
    private static let measuredLabelWidths: [String: CGFloat] = Dictionary(
        uniqueKeysWithValues: TabRowEdgeItem.pillLabels.map { ($0, measuredWidth(of: $0)) })

    /// `label`'s width at `fontSize` in the system font, which SwiftUI's
    /// `.system(size:)` draws, rounded up to a whole point.
    static func measuredWidth(of label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        return ceil((label as NSString).size(withAttributes: [.font: font]).width)
    }

    /// `label`'s width, from the measurements taken once.
    static func labelWidth(_ label: String) -> CGFloat {
        measuredLabelWidths[label] ?? measuredWidth(of: label)
    }

    /// A pill's width while it shows `label`.
    static func labelledWidth(_ label: String) -> CGFloat {
        leadingPadding + iconSlotWidth + iconToLabelSpacing + labelWidth(label) + trailingPadding
    }

    /// How much wider than the icon-only square a pill showing `label` is.
    static func labelExtra(_ label: String) -> CGFloat {
        labelledWidth(label) - RowIconSquare.standardSide
    }

    /// Whether the pills that are on show their labels in a strip
    /// `stripWidth` wide, with `edgeItems` its pills: when the strip's fixed
    /// controls (`SideStripMetrics.fixedControlsWidth`) and every pill that
    /// is on at its labelled width fit with no room left for a tab. The tabs
    /// scroll, so they give up their room first; only when even that leaves
    /// too little do the labels go, all together, and each pill that is on
    /// keeps its fill or outline (`SidePanelPillButton`).
    ///
    /// The fixed controls count the strip's full trailing group, not the
    /// items drawn now, so the labels do not come and go as the active panel
    /// gains or loses a control of its own.
    static func labelsFit(stripWidth: CGFloat, edgeItems: [TabRowEdgeItem]) -> Bool {
        var needed = SideStripMetrics.fixedControlsWidth
        for item in edgeItems where item.state.isOn {
            needed += labelExtra(item.pillLabel)
        }
        return needed <= stripWidth
    }

    /// Whether `item` shows its label: only a pill that is on, and only while
    /// the labels fit (`labelsFit`).
    static func showsLabel(_ item: TabRowEdgeItem, labelsFit: Bool) -> Bool {
        labelsFit && item.state.isOn
    }

    /// The strip widths across which `labelsFit` can change its answer: from
    /// a point short of the fixed controls, where no label fits, to the
    /// fixed controls with every pill labelled, where every label does.
    static var labelRuleBand: ClosedRange<CGFloat> {
        let fixed = SideStripMetrics.fixedControlsWidth
        var widest = fixed
        for label in TabRowEdgeItem.pillLabels {
            widest += labelExtra(label)
        }
        return (fixed - 1)...widest
    }

    /// The width the strip measures for the label rule: `stripWidth` in whole
    /// points, held within `band` (`labelRuleBand`). Every threshold of the
    /// rule is a whole number of points in that band, so the rule answers the
    /// same for this as for `stripWidth`, and a strip resized outside the
    /// band changes nothing the strip's body reads. Nonisolated, with the
    /// band handed in, so a geometry callback can call it.
    nonisolated static func labelRuleWidth(_ stripWidth: CGFloat, band: ClosedRange<CGFloat>) -> CGFloat {
        let measured = stripWidth.isFinite ? stripWidth.rounded(.down) : band.lowerBound
        return min(max(measured, band.lowerBound), band.upperBound)
    }
}

// MARK: - SidePanelPillButton

/// One of the side region's strip's pills (`TabRowEdgeItem`):
///
/// - **Off:** its icon alone, in the row icon button's square.
/// - **On, in front:** filled as a selected pill tab is (`TabPillShape`), its
///   icon and label in the label colour.
/// - **On, behind** another panel or with the region collapsed: outlined, with
///   no fill, in the row's grey.
///
/// An on pill shows its label while `showsLabel` says so
/// (`SidePanelPillMetrics.showsLabel`), and keeps its fill or outline without
/// it. Its hover and press feedback are `RowIconButtonStyle`'s, sized to the
/// pill (`RowIconSquare.Size.pill`), so they cover the shape it draws; the
/// fill and outline are drawn in that same shape (`RowIconSquareShape`).
///
/// It sets its own style on the button, and the strip hangs its right-click
/// menu outside it, so the menu's content still sits in the style's
/// environment and resets it (`SideRegionView`, `Sources/TBDApp/CLAUDE.md`).
struct SidePanelPillButton: View {
    let item: TabRowEdgeItem
    let showsLabel: Bool
    let action: () -> Void

    /// The pill's square: a labelled pill's width, or the icon-only square.
    static func size(for item: TabRowEdgeItem, showsLabel: Bool) -> RowIconSquare.Size {
        showsLabel ? .pill(width: SidePanelPillMetrics.labelledWidth(item.pillLabel)) : RowIconSquare.standard
    }

    var body: some View {
        let control = item.control
        let size = Self.size(for: item, showsLabel: showsLabel)
        Button(action: action) {
            label(control: control, size: size)
        }
        .buttonStyle(RowIconButtonStyle(size))
        .disabled(!control.isEnabled)
        .help(control.help)
        .accessibilityLabel(Text(control.help))
        .accessibilityAddTraits(item.state == .front ? .isSelected : [])
    }

    @ViewBuilder
    private func label(control: PaneChromeControl, size: RowIconSquare.Size) -> some View {
        let shape = RowIconSquareShape(size: size)
        let content = HStack(spacing: SidePanelPillMetrics.iconToLabelSpacing) {
            Image(systemName: control.systemImage)
                .frame(width: SidePanelPillMetrics.iconSlotWidth)
            if showsLabel {
                Text(item.pillLabel)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.system(size: SidePanelPillMetrics.fontSize))
        .padding(.leading, showsLabel ? SidePanelPillMetrics.leadingPadding : 0)
        .padding(.trailing, showsLabel ? SidePanelPillMetrics.trailingPadding : 0)
        .frame(width: Self.width(of: size), height: RowIconSquare.standardSide,
               alignment: showsLabel ? .leading : .center)

        switch item.state {
        case .front:
            // A concrete colour: a hierarchical `.primary` would be a level
            // of the style's grey (`RowIconButtonStyle`).
            content
                .foregroundStyle(Color(nsColor: .labelColor))
                .background {
                    shape.fill(Color.primary.opacity(MainTabRowMetrics.pillActiveOpacity))
                }
        case .behind:
            content
                .background {
                    shape.strokeBorder(
                        Color.primary.opacity(SidePanelPillMetrics.outlineOpacity),
                        lineWidth: SidePanelPillMetrics.outlineWidth)
                }
        case .off:
            content
        }
    }

    /// The width `size` frames the pill in.
    private static func width(of size: RowIconSquare.Size) -> CGFloat {
        switch size {
        case .pill(let width): width
        case .square(let side): side
        case .outset: RowIconSquare.standardSide
        }
    }
}
