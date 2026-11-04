import AppKit
import SwiftUI

// The side region's toggle pills: Changes, the transcript and Notes, each one
// control that turns its panel on and off. The transcript and Notes pills
// always show their panel's name; Changes is its icon alone. Spec:
// docs/specs/2026-11-03-side-panel-toggle-pills-design.md.

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

/// A pill's geometry.
///
/// The Changes pill is its icon alone in a row icon button's square,
/// `RowIconSquare.standardSide` wide, in every state. The transcript and Notes
/// pills show their label in every state (`TabRowEdgeItem.pillLabel`), so each
/// is `labelledWidth` wide whatever its panel does and whatever the strip's
/// width: the icon keeps the place the square would centre it in, and the
/// label follows it. Every width here is a whole number of points, so the
/// strip's fixed controls, which count both labelled pills, are too
/// (`SideStripMetrics.fixedControlsWidth`).
@MainActor
enum SidePanelPillMetrics {
    /// The icon's and the label's point size, the strip's tab titles' size.
    static let fontSize: CGFloat = 11
    /// The icon's and the label's colour in every state, in front, behind or
    /// off, hovered or not: the grey of the left sidebar's row icons
    /// (`WorktreeRowCell`), named as a concrete colour so the two match
    /// exactly. The pill in front is told apart by its fill alone. The
    /// toggles at the workspace tab bar's end draw it too
    /// (`PaneChromeControl.Tint.sidebarGrey`).
    static let foregroundColor: NSColor = .secondaryLabelColor
    /// The width the icon is centred in.
    static let iconSlotWidth: CGFloat = 14
    /// Between the icon's slot and the label.
    static let iconToLabelSpacing: CGFloat = 4
    /// After the label, to the pill's trailing end.
    static let trailingPadding: CGFloat = 8

    /// Before the icon's slot: what centres the slot where the square centres
    /// the Changes pill's icon.
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

    /// The width of a pill that shows `label`.
    static func labelledWidth(_ label: String) -> CGFloat {
        leadingPadding + iconSlotWidth + iconToLabelSpacing + labelWidth(label) + trailingPadding
    }
}

// MARK: - SidePanelPillButton

/// One of the side region's strip's pills (`TabRowEdgeItem`), its icon and
/// any label in the sidebar's grey (`SidePanelPillMetrics.foregroundColor`) in
/// every state, with its control's symbol (`PaneChromeControl.systemImage`).
/// Its shape is fixed by its kind, never by its state or the strip's width:
///
/// - **Changes:** its icon alone, in the row icon button's square.
/// - **The transcript and Notes:** icon and label (`TabRowEdgeItem.pillLabel`),
///   `SidePanelPillMetrics.labelledWidth` wide.
///
/// Its state shows only in its fill:
///
/// - **Off:** no fill.
/// - **On, in front:** filled as a selected pill tab is (`TabPillShape`), in
///   the pill's own shape, the square for Changes.
/// - **On, behind** another panel or with the region collapsed: no fill and
///   no outline, so it draws as one that is off. Only the pill in front is
///   marked.
///
/// Its hover and press feedback are `RowIconButtonStyle`'s, sized to the pill
/// (`RowIconSquare.Size.pill` for a labelled one), so they cover the shape it
/// draws, and leave its colour as it is; the fill is drawn in that same shape
/// (`RowIconSquareShape`).
///
/// It sets its own style on the button, and the strip hangs its right-click
/// menu outside it, so the menu's content still sits in the style's
/// environment and resets it (`SideRegionView`, `Sources/TBDApp/CLAUDE.md`).
struct SidePanelPillButton: View {
    let item: TabRowEdgeItem
    let action: () -> Void

    /// The pill's square: its labelled width for a pill with a label, the
    /// icon-only square for Changes.
    static func size(for item: TabRowEdgeItem) -> RowIconSquare.Size {
        guard let label = item.pillLabel else { return RowIconSquare.standard }
        return .pill(width: SidePanelPillMetrics.labelledWidth(label))
    }

    var body: some View {
        let control = item.control
        let size = Self.size(for: item)
        Button(action: action) {
            label(size: size)
        }
        .buttonStyle(RowIconButtonStyle(size))
        .disabled(!control.isEnabled)
        .help(control.help)
        .accessibilityLabel(Text(control.help))
        .accessibilityAddTraits(item.state == .front ? .isSelected : [])
    }

    @ViewBuilder
    private func label(size: RowIconSquare.Size) -> some View {
        let shape = RowIconSquareShape(size: size)
        let pillLabel = item.pillLabel
        let labelled = pillLabel != nil
        let content = HStack(spacing: SidePanelPillMetrics.iconToLabelSpacing) {
            Image(systemName: item.control.systemImage)
                .frame(width: SidePanelPillMetrics.iconSlotWidth)
            if let pillLabel {
                Text(pillLabel)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.system(size: SidePanelPillMetrics.fontSize))
        .padding(.leading, labelled ? SidePanelPillMetrics.leadingPadding : 0)
        .padding(.trailing, labelled ? SidePanelPillMetrics.trailingPadding : 0)
        .frame(width: Self.width(of: size), height: RowIconSquare.standardSide,
               alignment: labelled ? .leading : .center)
        // A concrete colour, so it is the sidebar's grey rather than the
        // style's hierarchical one (`RowIconButtonStyle`).
        .foregroundStyle(Color(nsColor: SidePanelPillMetrics.foregroundColor))

        if item.state == .front {
            content
                .background {
                    shape.fill(Color.primary.opacity(MainTabRowMetrics.pillActiveOpacity))
                }
        } else {
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
