import AppKit
import SwiftUI

// The pieces of the panes' top rows, which draw in the window's toolbar row:
// the row's metrics, the main row's width rule and layout, the side strip's
// layout, the drag gap and the pill tabs. Spec:
// docs/specs/2026-11-02-tabs-in-toolbar-design.md.

// MARK: - Metrics

/// The sizes the top rows rest on. The row's height and leading inset follow
/// the toolbar (`WindowChromeState`); the rest are choices. The title
/// column's fonts and spacing are the toolbar title's (`WorktreeTitleMetrics`).
enum MainTabRowMetrics {
    /// The gap between the toolbar's leading item and the main row's first
    /// item while the item sits over the main pane (sidebar collapsed).
    static let leadingItemClearance: CGFloat = 8
    /// The main row's leading inset while the sidebar is shown: the gap
    /// between the sidebar's border and the title column.
    static let shownSidebarInset: CGFloat = 16
    /// The gap between a tab row's last icon button and the row's trailing
    /// edge, so the button's hover square stays off the window's edge and its
    /// rounded corner. Applied inside each row's background, which still
    /// reaches the edge.
    static let trailingInset: CGFloat = 12
    /// The narrowest the title column shrinks to before the tabs scroll.
    static let titleFloor: CGFloat = 110
    /// The narrowest the main row's drag gap gets.
    static let minimumDragGap: CGFloat = 24
    /// Between the title column and the first tab.
    static let titleToTabsSpacing: CGFloat = 14
    /// How far the notes button's hover square, which is its hit area too,
    /// reaches past its symbol on each side (`RowIconSquare.Size.outset`).
    /// It changes neither the button's size nor the line's layout.
    static let notesHitOutset: CGFloat = 3

    /// A pill tab's height.
    static let pillHeight: CGFloat = 28
    /// A pill tab's corner radius.
    static let pillCornerRadius: CGFloat = 7
    /// The active pill's fill: the primary colour at this opacity.
    static let pillActiveOpacity: Double = 0.075
    /// A hovered pill's fill: the primary colour at this opacity.
    static let pillHoverOpacity: Double = 0.045
    /// Between two pill tabs.
    static let pillSpacing: CGFloat = 2
    /// Between the last pill tab and the + button's hover square.
    static let pillToAddSpacing: CGFloat = 4

    /// The row's height: the content pane's top safe-area inset, the
    /// toolbar's height over the pane, never less than
    /// `TabRowMetrics.height`. The floor holds only before the toolbar
    /// controller has measured the inset, when the row would otherwise take
    /// no height.
    static func height(topSafeAreaInset: CGFloat) -> CGFloat {
        max(topSafeAreaInset, TabRowMetrics.height)
    }

    /// The main row's leading inset, in points from the main pane's leading
    /// edge: `leadingItemClearance` past the toolbar's leading item while that
    /// item reaches over the pane, and `shownSidebarInset` while it does not,
    /// or before it is measured (`leadingItemTrailingEdge` nil).
    static func leadingInset(leadingItemTrailingEdge: CGFloat?) -> CGFloat {
        guard let edge = leadingItemTrailingEdge else { return shownSidebarInset }
        return max(shownSidebarInset, edge + leadingItemClearance)
    }

    /// A pill tab's fill opacity: the active pill's, else a hovered one's,
    /// else none.
    static func pillOpacity(isActive: Bool, isHovering: Bool) -> Double {
        if isActive { return pillActiveOpacity }
        return isHovering ? pillHoverOpacity : 0
    }
}

// MARK: - Width rule

/// The widths the main row gives its title column and its tabs.
struct MainTabRowWidths: Equatable {
    var title: CGFloat
    var tabs: CGFloat

    /// When the row runs short, the title gives way before the tabs:
    ///
    /// - With room for both, each takes its ideal width.
    /// - Short of room, the title shrinks first, down to `titleFloor`, while
    ///   the tabs keep their ideal width.
    /// - Once the title is at its floor, the tabs take what is left, and
    ///   scroll.
    ///
    /// A title whose ideal width is already below the floor keeps its ideal
    /// width: the floor never makes it grow. `fixed` is the width of
    /// everything else in the row, the drag gap's minimum included, and
    /// `available` the row's width. Neither width is ever negative.
    static func make(
        titleIdeal: CGFloat,
        titleFloor: CGFloat = MainTabRowMetrics.titleFloor,
        tabsIdeal: CGFloat,
        fixed: CGFloat,
        available: CGFloat
    ) -> MainTabRowWidths {
        let room = max(0, available - fixed)
        let floor = max(0, min(titleFloor, titleIdeal))
        let title = min(max(0, titleIdeal), max(floor, room - tabsIdeal))
        let tabs = min(max(0, tabsIdeal), max(0, room - title))
        return MainTabRowWidths(title: title, tabs: tabs)
    }
}

// MARK: - Main row layout

/// Lays out the main row's four parts, left to right: the title column, which
/// holds the notes button, the tabs with their + button, the drag gap and the
/// trailing items, each centred on the row's midline. The trailing items take
/// their ideal width, the title column and the tabs what
/// `MainTabRowWidths.make` gives them, and the drag gap the rest, which is at
/// least `MainTabRowMetrics.minimumDragGap` whenever the title column is above
/// its floor.
///
/// Each subview's ideal width is measured once, when SwiftUI makes or updates
/// the cache: an ideal size does not depend on the proposal.
struct MainTabRowLayout: Layout {
    struct Cache {
        var idealSizes: [CGSize]
    }

    /// The parts, in the order the row's body lists them.
    enum Part: Int, CaseIterable {
        case title, tabs, gap, trailing
    }

    /// Where a part sits: its leading x from the row's leading edge, and its
    /// width.
    struct Slot: Equatable {
        var x: CGFloat
        var width: CGFloat
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(idealSizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let ideals = cache.idealSizes.map(\.width)
        let width = proposal.width ?? Self.idealWidth(idealWidths: ideals)
        let height = proposal.height ?? cache.idealSizes.map(\.height).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let slots = Self.slots(idealWidths: cache.idealSizes.map(\.width), available: bounds.width)
        for (subview, slot) in zip(subviews, slots) {
            subview.place(
                at: CGPoint(x: bounds.minX + slot.x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: slot.width, height: bounds.height))
        }
    }

    /// The row's width with every part at its ideal width and the drag gap
    /// at its minimum.
    static func idealWidth(idealWidths: [CGFloat]) -> CGFloat {
        let parts = Self.parts(idealWidths)
        return parts.title + MainTabRowMetrics.titleToTabsSpacing + parts.tabs
            + MainTabRowMetrics.minimumDragGap + parts.trailing
    }

    /// Each part's slot, in `Part` order, for parts whose ideal widths are
    /// `idealWidths` in a row `available` wide. The title column starts at
    /// the row's leading edge and the trailing items end at its trailing
    /// edge; the drag gap fills from the tabs to them.
    static func slots(idealWidths: [CGFloat], available: CGFloat) -> [Slot] {
        let parts = Self.parts(idealWidths)
        let fixed = MainTabRowMetrics.titleToTabsSpacing + MainTabRowMetrics.minimumDragGap + parts.trailing
        let widths = MainTabRowWidths.make(
            titleIdeal: parts.title, tabsIdeal: parts.tabs, fixed: fixed, available: available)

        let title = Slot(x: 0, width: widths.title)
        let tabs = Slot(x: title.x + title.width + MainTabRowMetrics.titleToTabsSpacing, width: widths.tabs)
        let trailingX = max(tabs.x + tabs.width, available - parts.trailing)
        let gap = Slot(x: tabs.x + tabs.width, width: max(0, trailingX - (tabs.x + tabs.width)))
        let trailing = Slot(x: trailingX, width: parts.trailing)
        return [title, tabs, gap, trailing]
    }

    /// The ideal widths by part, the drag gap's aside; a missing one counts
    /// as zero.
    private static func parts(_ idealWidths: [CGFloat])
        -> (title: CGFloat, tabs: CGFloat, trailing: CGFloat) {
        func width(_ part: Part) -> CGFloat {
            idealWidths.indices.contains(part.rawValue) ? max(0, idealWidths[part.rawValue]) : 0
        }
        return (width(.title), width(.tabs), width(.trailing))
    }
}

// MARK: - Side strip layout

/// Lays out the side region's strip's tabs and the drag gap after them: the
/// tabs, a horizontal scroll view, take their ideal width while it fits and
/// the width offered past that, where they scroll; the gap takes the rest.
/// So the empty width after the last tab is the gap's, and moves the window.
struct TabsThenDragGapLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width ?? ideal.width, height: proposal.height ?? ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = subviews.first?.sizeThatFits(.unspecified).width ?? 0
        let widths = Self.widths(tabsIdeal: ideal, available: bounds.width)
        var x = bounds.minX
        for (subview, width) in zip(subviews, [widths.tabs, widths.gap]) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }

    /// The tabs' width, their ideal capped to `available`, and the gap's,
    /// the rest. Neither is ever negative.
    static func widths(tabsIdeal: CGFloat, available: CGFloat) -> (tabs: CGFloat, gap: CGFloat) {
        let room = max(0, available)
        let tabs = min(max(0, tabsIdeal), room)
        return (tabs, room - tabs)
    }
}

// MARK: - Drag gap

/// The top rows' empty space: an AppKit view whose `mouseDownCanMoveWindow`
/// is true, so a drag on it moves the window and a double-click does what
/// System Settings names, as on a title bar. No other view in the rows
/// answers true, so a drag that starts on a tab reorders tabs.
struct WindowDragGap: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragGapView {
        WindowDragGapView()
    }

    func updateNSView(_ nsView: WindowDragGapView, context: Context) {}
}

/// The view `WindowDragGap` places. It draws nothing.
final class WindowDragGapView: NSView {
    /// Identifies the view in a window's hierarchy, for tests.
    static let viewIdentifier = NSUserInterfaceItemIdentifier("tbd.windowDragGap")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.viewIdentifier
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { true }
    override var isOpaque: Bool { false }
}

// MARK: - Pill tabs

/// A tab drawn as a pill: `MainTabRowMetrics.pillHeight` tall, on a rounded
/// rectangle filled by `MainTabRowMetrics.pillOpacity`, following its own
/// hover. For a tab that does not already follow the pointer, as the side
/// region's tabs do not; the workspace tab bar's items, which do, draw the
/// same fill from their own hover state (`TabPillShape`).
struct TabPillBackground: ViewModifier {
    let isActive: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .frame(height: MainTabRowMetrics.pillHeight)
            .background(TabPillShape(isActive: isActive, isHovering: isHovering))
            .onHover { isHovering = $0 }
    }
}

/// A pill tab's fill.
struct TabPillShape: View {
    let isActive: Bool
    let isHovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: MainTabRowMetrics.pillCornerRadius, style: .continuous)
            .fill(Color.primary.opacity(MainTabRowMetrics.pillOpacity(isActive: isActive, isHovering: isHovering)))
    }
}
