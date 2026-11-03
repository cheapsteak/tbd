import AppKit
import SwiftUI

// MARK: - RowIconSquare

/// The hover square of an icon button in the panes' top rows: the main pane's
/// tab row and the side region's strip, in the toolbar row with the Tabs in
/// the toolbar setting on and as the classic tab bars with it off. It is the
/// square the toolbar's leading buttons draw (`ToolbarIconButton`), with the
/// same colours, the same corner radius and the same size, read from the same
/// constants so the two never drift: `ToolbarIconButton.hoverFill` while the
/// pointer is over the button, `ToolbarIconButton.pressedFill` while it is
/// pressed, nothing at rest or while it is disabled.
enum RowIconSquare {
    /// How big the square is.
    enum Size: Equatable {
        /// A square `side` points on a side: the button's frame, with the
        /// label centred in it, and its hit area. Adjacent buttons of this
        /// size tile edge to edge, as the toolbar's leading buttons do.
        case square(side: CGFloat)
        /// A square around the label, reaching `outset` points past the
        /// label's longer side on each side, for an icon that leads a line of
        /// text, which a full square would dwarf. The label keeps its own
        /// size, so the line's layout does not change; the square and the
        /// hit area reach past the label's frame.
        case outset(CGFloat)
    }

    /// The side of a row icon button: the toolbar's icon button height.
    static let standardSide: CGFloat = MainToolbarMetrics.iconButtonHeight
    /// The size every row icon button takes unless it names another.
    static let standard = Size.square(side: standardSide)
    /// The corner radius of an `outset` square, smaller than a full square's
    /// to suit its smaller size.
    static let outsetCornerRadius: CGFloat = 4
    /// A disabled button's label, at this opacity.
    static let disabledLabelOpacity: Double = 0.4

    /// The square's corner radius for `size`: the toolbar's
    /// `MainToolbarMetrics.iconButtonCornerRadius` for a full square.
    static func cornerRadius(for size: Size) -> CGFloat {
        switch size {
        case .square: MainToolbarMetrics.iconButtonCornerRadius
        case .outset: outsetCornerRadius
        }
    }

    /// The square's colour for a state, as the toolbar's leading buttons
    /// choose it (`ToolbarIconButton.highlightFill`): none while disabled.
    @MainActor
    static func fill(isHovered: Bool, isPressed: Bool, isEnabled: Bool) -> Color? {
        ToolbarIconButton.highlightFill(isHovered: isHovered, isPressed: isPressed, isEnabled: isEnabled)
            .map { Color(nsColor: $0) }
    }
}

// MARK: - RowIconButtonStyle

/// The style of an icon button in the panes' top rows: the label centred in a
/// `RowIconSquare`, which fills on hover and on press and is the button's hit
/// area. A disabled button draws no square and dims its label.
///
/// **It draws the label in the secondary colour**, the grey of the toolbar's
/// leading glyphs, unless the label sets a colour of its own, which wins. A
/// label that shows a state in a colour of its own names a concrete one
/// (`Color.accentColor`, `Color(nsColor: .labelColor)`): a hierarchical style
/// in the label (`.primary`, `.secondary`, `.tertiary`) is a level of this
/// default, not of the label colour, so `.primary` there draws grey.
///
/// **The rows apply it to their icon groups, never at their root.** The main
/// pane's row (`TabBar`) applies it to its trailing group and to the + after
/// the tabs; the side region's strip (`SideRegionView`) to its history group
/// and its trailing group. A new `Button` in one of those groups gets the
/// square with no code of its own. A control that is not a `Button`, such as
/// a `Menu`, takes `.rowIconHoverSquare()` instead, and sets its label's
/// colour itself: a custom button style does not reach a menu's label, and
/// AppKit lays out a borderless menu's label itself, in the label colour.
///
/// **Never put it, or any custom `ButtonStyle`, over a subtree that holds a
/// `.contextMenu` or a `Menu`'s content.** SwiftUI then rebuilds the open menu
/// continuously, and each rebuild closes an open submenu (measured on a
/// session tab's context menu: the same 15 items removed and re-added about
/// 230 times a second while it was open, with no body re-running). So no tab
/// and no title column sits under it, and a `Menu` inside a styled group
/// resets it with `.buttonStyle(.automatic)` on its content, as the strip's +
/// menu does.
struct RowIconButtonStyle: ButtonStyle {
    let size: RowIconSquare.Size

    init(_ size: RowIconSquare.Size = RowIconSquare.standard) {
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        RowIconSquareHost(
            size: size, isPressed: configuration.isPressed, dimsLabelWhenDisabled: true,
            content: configuration.label.foregroundStyle(.secondary))
    }
}

extension View {
    /// Draws a row icon button's hover square behind a control that is not a
    /// `Button`, such as a `Menu`, as `RowIconButtonStyle` draws it for a
    /// button: on hover, never while disabled. It has no pressed state, and
    /// it sets no colour, so the control's label sets its own. Put it outside
    /// a borderless `Menu`, whose label AppKit lays out ignoring the label's
    /// own modifiers.
    func rowIconHoverSquare(_ size: RowIconSquare.Size = RowIconSquare.standard) -> some View {
        RowIconSquareHost(size: size, isPressed: false, dimsLabelWhenDisabled: false, content: self)
    }
}

// MARK: - Host

/// `content` framed for `size`, on its square, following its own hover.
private struct RowIconSquareHost<Content: View>: View {
    let size: RowIconSquare.Size
    let isPressed: Bool
    /// Whether a disabled control's content is dimmed here: a button's label
    /// is; a control that dims itself, such as a menu, is not.
    let dimsLabelWhenDisabled: Bool
    let content: Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let shape = RowIconSquareShape(size: size)
        let fill = RowIconSquare.fill(isHovered: isHovered, isPressed: isPressed, isEnabled: isEnabled)
        framed
            .opacity(dimsLabelWhenDisabled && !isEnabled ? RowIconSquare.disabledLabelOpacity : 1)
            .background {
                if let fill {
                    shape.fill(fill)
                }
            }
            .contentShape(shape)
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var framed: some View {
        switch size {
        case .square(let side):
            content.frame(width: side, height: side)
        case .outset:
            content
        }
    }
}

/// A row icon button's square, centred in the rect it is given: the rect's
/// shorter side for a full square, which fills the button's frame, and the
/// longer side plus the outset on each side for an `outset` one. Corners
/// are circular, as `ToolbarIconButton` draws them.
private struct RowIconSquareShape: Shape {
    let size: RowIconSquare.Size

    func path(in rect: CGRect) -> Path {
        let side: CGFloat
        switch size {
        case .square:
            side = min(rect.width, rect.height)
        case .outset(let outset):
            side = max(rect.width, rect.height) + 2 * outset
        }
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        return Path(roundedRect: square, cornerRadius: RowIconSquare.cornerRadius(for: size))
    }
}
