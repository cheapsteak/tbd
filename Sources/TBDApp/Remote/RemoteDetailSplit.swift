import AppKit
import SwiftUI

/// The remote detail pane's two halves: `leading` always, `trailing` beside it
/// when `showsTrailing`, with a draggable divider between them.
///
/// A plain `HStack` rather than `HSplitView`, because the one property this
/// container exists for is that **adding or removing the trailing half never
/// remounts the leading one**. The leading half hosts `RemoteAttachPager`,
/// whose `NSTabViewController` owns every live attach connection; dismantling
/// it would drop them all. In an `HStack` the leading child sits at a fixed
/// position in a `TupleView`, so SwiftUI's structural identity keeps it — and
/// the AppKit views under it — across the toggle. `HSplitView` bridges its
/// children into `NSSplitView` subviews, and nothing documents that it keeps a
/// sibling's hosted views when the child list changes shape.
/// `RemoteDetailSplitTests` pins the property.
struct RemoteDetailSplit<Leading: View, Trailing: View>: View {
    let showsTrailing: Bool
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    static var leadingMinWidth: CGFloat { 240 }
    static var trailingMinWidth: CGFloat { 280 }
    private static var dividerHitWidth: CGFloat { 6 }

    /// The trailing half's width (420 pt by default), kept across hide/show
    /// within one mount.
    @State private var trailingWidth: CGFloat = 420
    /// The width a drag started from, so the drag is relative to it.
    @State private var dragOrigin: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                leading()
                    .frame(minWidth: Self.leadingMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                if showsTrailing {
                    divider(totalWidth: proxy.size.width)
                    trailing()
                        .frame(width: clampedTrailingWidth(totalWidth: proxy.size.width))
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    /// Never narrower than its minimum, and never so wide the leading half
    /// drops below its own.
    private func clampedTrailingWidth(totalWidth: CGFloat) -> CGFloat {
        Self.clamp(
            trailingWidth, totalWidth: totalWidth,
            leadingMin: Self.leadingMinWidth, trailingMin: Self.trailingMinWidth)
    }

    static func clamp(
        _ width: CGFloat, totalWidth: CGFloat, leadingMin: CGFloat, trailingMin: CGFloat
    ) -> CGFloat {
        let upper = max(trailingMin, totalWidth - leadingMin)
        return min(max(width, trailingMin), upper)
    }

    private func divider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, (Self.dividerHitWidth - 1) / 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let origin = dragOrigin ?? clampedTrailingWidth(totalWidth: totalWidth)
                        if dragOrigin == nil { dragOrigin = origin }
                        trailingWidth = Self.clamp(
                            origin - value.translation.width, totalWidth: totalWidth,
                            leadingMin: Self.leadingMinWidth, trailingMin: Self.trailingMinWidth)
                    }
                    .onEnded { _ in dragOrigin = nil })
            .accessibilityHidden(true)
    }
}
