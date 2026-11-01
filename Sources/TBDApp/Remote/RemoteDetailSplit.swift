import AppKit
import SwiftUI

/// The remote detail pane: the terminal side and the transcript, placed by
/// role with a draggable divider between them, over a live-terminal slot that
/// hosts the attached terminal.
///
/// `terminal` always shows. `transcript` and the divider show beside it when
/// `showsTranscript`, and `transcriptLeads` says which half is on the left:
/// the transcript while the session is not attached, the terminal once it is.
/// `transcriptLeads` is ignored while the transcript is hidden, and the
/// terminal side then spans the pane.
///
/// `liveTerminal` is always laid out where the attached terminal is drawn —
/// the left half, or the whole pane without the transcript — whatever
/// `transcriptLeads` says, and it is drawn behind everything else. It hosts
/// `RemoteAttachPager`, which keeps other sessions' terminals alive. While
/// the session on screen is not attached, the pager keeps the tab it last
/// showed selected, and that one terminal stays laid out. Were the pager
/// inside the terminal side, viewing a session that is not attached would
/// move it into the right half with the terminal side and resize that
/// terminal's remote program. The terminal side draws over it, and renders
/// nothing while attached so the live terminal shows through.
///
/// The one property this container exists for is that **the split never
/// remounts any of its parts** — not when the transcript shows or hides, and
/// not when the halves swap. `RemoteAttachPager`'s `NSTabViewController` owns
/// every live attach connection, and the transcript is
/// `RemoteTranscriptLivePane`, which owns a sync driver; dismantling either
/// would drop them. So each part keeps a fixed structural position in the view
/// tree — the live terminal first, then the terminal side, both
/// unconditionally, then the divider and the transcript while shown — and a
/// private `Layout` reads each subview's role (a `LayoutValueKey`) and places
/// it from `columns(...)`. A swap changes only where each half is drawn, so
/// SwiftUI's structural identity keeps every part and the AppKit views under
/// them. A container that places children by order cannot do this: reordering
/// an `HStack`'s children changes their structural identity, and `HSplitView`
/// bridges its children into `NSSplitView` subviews with nothing documenting
/// that it keeps a sibling's hosted views when the child list changes.
///
/// The divider sets the width of whichever half is on the right, so the half
/// that moves there takes the stored width. `RemoteDetailSplitTests` pins the
/// placement, the width math, that the live terminal holds still across a
/// swap, and that no part is remade.
struct RemoteDetailSplit<TerminalSide: View, TranscriptSide: View, LiveTerminal: View>: View {
    let showsTranscript: Bool
    let transcriptLeads: Bool
    @ViewBuilder let terminal: () -> TerminalSide
    @ViewBuilder let transcript: () -> TranscriptSide
    @ViewBuilder let liveTerminal: () -> LiveTerminal

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
            // Each part takes exactly the column it is proposed: with both a
            // minimum and a maximum, a frame adopts its proposal whatever its
            // content asks for. Subviews draw in this order, so the live
            // terminal sits behind the rest.
            layout {
                liveTerminal()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .layoutValue(key: RemoteDetailSplitRoleKey.self, value: .liveTerminal)
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

    /// Where each part is drawn, as offsets from the split's left edge. Pure,
    /// so the placement can be tested without a window.
    ///
    /// Without the transcript the terminal side and the live terminal span the
    /// whole width and `transcriptLeads` changes nothing. With it, the right
    /// half is `rightWidth` wide (already clamped), the divider sits just left
    /// of it, and the left half takes what remains. The right half never
    /// extends past the pane: in a pane narrower than `rightWidth` plus the
    /// divider, it takes what the divider leaves and the left half is empty.
    /// The terminal side takes the right half when `transcriptLeads`, the left
    /// half otherwise. The live terminal takes the left half either way, which
    /// is where the terminal side is drawn while attached.
    nonisolated static func columns(
        totalWidth: CGFloat, rightWidth: CGFloat, dividerWidth: CGFloat,
        showsTranscript: Bool, transcriptLeads: Bool
    ) -> RemoteDetailSplitColumns {
        guard showsTranscript else {
            let whole = RemoteDetailSplitColumn(x: 0, width: totalWidth)
            return RemoteDetailSplitColumns(
                terminal: whole, divider: nil, transcript: nil, liveTerminal: whole)
        }
        let cappedRightWidth = min(rightWidth, max(0, totalWidth - dividerWidth))
        let leftWidth = max(0, totalWidth - cappedRightWidth - dividerWidth)
        let left = RemoteDetailSplitColumn(x: 0, width: leftWidth)
        let middle = RemoteDetailSplitColumn(x: leftWidth, width: dividerWidth)
        let right = RemoteDetailSplitColumn(x: leftWidth + dividerWidth, width: cappedRightWidth)
        return RemoteDetailSplitColumns(
            terminal: transcriptLeads ? right : left,
            divider: middle,
            transcript: transcriptLeads ? left : right,
            liveTerminal: left)
    }

    /// The stored right-half width, clamped for a pane `totalWidth` wide (see
    /// `clamp`): the left half keeps `leftMinWidth` whenever the pane is wide
    /// enough for both minimums and the divider; otherwise the right half
    /// keeps `rightMinWidth` and the left half shrinks. `columns` then keeps
    /// the right half inside the pane.
    private func clampedRightWidth(totalWidth: CGFloat) -> CGFloat {
        Self.clamp(
            rightWidth, totalWidth: totalWidth,
            leftMin: Self.leftMinWidth, rightMin: Self.rightMinWidth, dividerWidth: Self.dividerHitWidth)
    }

    /// Clamps the right half's width to at least `rightMin`, and to at most
    /// what leaves `leftMin` for the left half once the divider has its
    /// `dividerWidth`. So the left half keeps `leftMin` whenever the pane is
    /// wide enough for both minimums and the divider. In a narrower pane the
    /// lower bound wins: the right half keeps `rightMin` and the left half
    /// shrinks. The result can still exceed what the pane has room for;
    /// `columns` caps the right half at the pane.
    nonisolated static func clamp(
        _ width: CGFloat, totalWidth: CGFloat, leftMin: CGFloat, rightMin: CGFloat, dividerWidth: CGFloat
    ) -> CGFloat {
        let upper = max(rightMin, totalWidth - leftMin - dividerWidth)
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
                            leftMin: Self.leftMinWidth, rightMin: Self.rightMinWidth,
                            dividerWidth: Self.dividerHitWidth)
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
/// `transcript` are nil while the transcript is hidden; `liveTerminal` is where
/// the attached terminal is drawn, whichever half leads.
struct RemoteDetailSplitColumns: Equatable, Sendable {
    var terminal: RemoteDetailSplitColumn
    var divider: RemoteDetailSplitColumn?
    var transcript: RemoteDetailSplitColumn?
    var liveTerminal: RemoteDetailSplitColumn
}

/// What a subview of the split is, read by `RemoteDetailSplitLayout` to find
/// its column.
private enum RemoteDetailSplitRole: Sendable {
    case liveTerminal
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
        case .liveTerminal: liveTerminal
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
