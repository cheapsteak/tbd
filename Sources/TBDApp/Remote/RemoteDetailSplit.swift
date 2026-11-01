import AppKit
import SwiftUI

/// The remote detail pane's two halves, the terminal side and the transcript,
/// placed by role with a draggable divider between them.
///
/// `terminal` always shows. `transcript` and the divider show beside it when
/// `showsTranscript`, and `transcriptLeads` says which half is on the left:
/// the transcript while the session is not attached, the terminal once it is.
/// `transcriptLeads` is ignored while the transcript is hidden, and the
/// terminal side then spans the pane.
///
/// The one property this container exists for is that **the split never
/// remounts either half** — not when the transcript shows or hides, and not
/// when the halves swap. The terminal side hosts `RemoteAttachPager`, whose
/// `NSTabViewController` owns every live attach connection, and the transcript
/// is `RemoteTranscriptLivePane`, which owns a sync driver; dismantling either
/// would drop them. So both halves keep fixed structural positions in the view
/// tree — the terminal first and unconditionally, the divider and the
/// transcript after it while shown — and a private `Layout` reads each
/// subview's role (a `LayoutValueKey`) and places it from `columns(...)`. A
/// swap changes only where each half is drawn, so SwiftUI's structural
/// identity keeps both halves and the AppKit views under them. A container
/// that places children by order cannot do this: reordering an `HStack`'s
/// children changes their structural identity, and `HSplitView` bridges its
/// children into `NSSplitView` subviews with nothing documenting that it keeps
/// a sibling's hosted views when the child list changes.
///
/// The divider sets the width of whichever half is on the right, so the half
/// that moves there takes the stored width. `RemoteDetailSplitTests` pins the
/// placement, the width math, and that neither half is remade.
struct RemoteDetailSplit<TerminalSide: View, TranscriptSide: View>: View {
    let showsTranscript: Bool
    let transcriptLeads: Bool
    @ViewBuilder let terminal: () -> TerminalSide
    @ViewBuilder let transcript: () -> TranscriptSide

    /// The minimums are by position, not by role; `clamp` applies both to the
    /// right half's width.
    static var leftMinWidth: CGFloat { 240 }
    static var rightMinWidth: CGFloat { 280 }
    private static var dividerHitWidth: CGFloat { 6 }

    /// The right half's width (420 pt by default), whichever role sits there,
    /// kept across hide, show and swap within one mount.
    @State private var rightWidth: CGFloat = 420
    /// The width a drag started from, so the drag is relative to it.
    @State private var dragOrigin: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let columns = Self.columns(
                totalWidth: totalWidth,
                rightWidth: clampedRightWidth(totalWidth: totalWidth),
                dividerWidth: Self.dividerHitWidth,
                showsTranscript: showsTranscript,
                transcriptLeads: transcriptLeads)
            let layout = RemoteDetailSplitLayout(columns: columns)
            // Each half takes exactly the column it is proposed: with both a
            // minimum and a maximum, a frame adopts its proposal whatever its
            // content asks for.
            layout {
                terminal()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .layoutValue(key: RemoteDetailSplitRoleKey.self, value: .terminal)
                if showsTranscript {
                    divider(totalWidth: totalWidth)
                        .layoutValue(key: RemoteDetailSplitRoleKey.self, value: .divider)
                    transcript()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .layoutValue(key: RemoteDetailSplitRoleKey.self, value: .transcript)
                }
            }
        }
    }

    /// Where each half and the divider are drawn, as offsets from the split's
    /// left edge. Pure, so the placement can be tested without a window.
    ///
    /// Without the transcript the terminal side spans the whole width and
    /// `transcriptLeads` changes nothing. With it, the right half is
    /// `rightWidth` wide (already clamped), the divider sits just left of it,
    /// and the left half takes what remains. The terminal side takes the right
    /// half when `transcriptLeads`, the left half otherwise.
    nonisolated static func columns(
        totalWidth: CGFloat, rightWidth: CGFloat, dividerWidth: CGFloat,
        showsTranscript: Bool, transcriptLeads: Bool
    ) -> RemoteDetailSplitColumns {
        guard showsTranscript else {
            return RemoteDetailSplitColumns(
                terminal: RemoteDetailSplitColumn(x: 0, width: totalWidth),
                divider: nil, transcript: nil)
        }
        let leftWidth = max(0, totalWidth - rightWidth - dividerWidth)
        let left = RemoteDetailSplitColumn(x: 0, width: leftWidth)
        let middle = RemoteDetailSplitColumn(x: leftWidth, width: dividerWidth)
        let right = RemoteDetailSplitColumn(x: leftWidth + dividerWidth, width: rightWidth)
        return RemoteDetailSplitColumns(
            terminal: transcriptLeads ? right : left,
            divider: middle,
            transcript: transcriptLeads ? left : right)
    }

    /// Never narrower than its minimum, and never so wide the left half drops
    /// below its own.
    private func clampedRightWidth(totalWidth: CGFloat) -> CGFloat {
        Self.clamp(
            rightWidth, totalWidth: totalWidth,
            leftMin: Self.leftMinWidth, rightMin: Self.rightMinWidth)
    }

    /// Clamps the right half's width to at least `rightMin` and at most what
    /// leaves `leftMin` for the left half. When the split is too narrow for
    /// both minimums, the right half keeps its minimum.
    nonisolated static func clamp(
        _ width: CGFloat, totalWidth: CGFloat, leftMin: CGFloat, rightMin: CGFloat
    ) -> CGFloat {
        let upper = max(rightMin, totalWidth - leftMin)
        return min(max(width, rightMin), upper)
    }

    private func divider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, (Self.dividerHitWidth - 1) / 2)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let origin = dragOrigin ?? clampedRightWidth(totalWidth: totalWidth)
                        if dragOrigin == nil { dragOrigin = origin }
                        rightWidth = Self.clamp(
                            origin - value.translation.width, totalWidth: totalWidth,
                            leftMin: Self.leftMinWidth, rightMin: Self.rightMinWidth)
                    }
                    .onEnded { _ in dragOrigin = nil })
            .accessibilityHidden(true)
    }
}

/// One horizontal span of the split: its offset from the split's left edge
/// and its width.
struct RemoteDetailSplitColumn: Equatable, Sendable {
    var x: CGFloat
    var width: CGFloat
}

/// Where `RemoteDetailSplit` draws each of its parts. `divider` and
/// `transcript` are nil while the transcript is hidden.
struct RemoteDetailSplitColumns: Equatable, Sendable {
    var terminal: RemoteDetailSplitColumn
    var divider: RemoteDetailSplitColumn?
    var transcript: RemoteDetailSplitColumn?
}

/// What a subview of the split is, read by `RemoteDetailSplitLayout` to find
/// its column.
private enum RemoteDetailSplitRole: Sendable {
    case terminal
    case divider
    case transcript
}

/// Tags each subview of the split with its role. Nil, the default, marks a
/// subview the split did not tag; it gets no column.
private struct RemoteDetailSplitRoleKey: LayoutValueKey {
    static var defaultValue: RemoteDetailSplitRole? { nil }
}

private extension RemoteDetailSplitColumns {
    func column(for role: RemoteDetailSplitRole) -> RemoteDetailSplitColumn? {
        switch role {
        case .terminal: terminal
        case .divider: divider
        case .transcript: transcript
        }
    }
}

/// Places each subview of the split by its role, never by its index, at the
/// full height of the split. A plain value with no actor state, because
/// `Layout`'s requirements are nonisolated.
private struct RemoteDetailSplitLayout: Layout {
    let columns: RemoteDetailSplitColumns

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for subview in subviews {
            guard let role = subview[RemoteDetailSplitRoleKey.self],
                  let column = columns.column(for: role)
            else {
                subview.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
                continue
            }
            subview.place(
                at: CGPoint(x: bounds.minX + column.x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: column.width, height: bounds.height))
        }
    }
}
