import AppKit
import Observation
import SwiftUI

/// The SwiftUI renderer's rail: one notch per prompt in a 20pt column beside
/// the transcript, the active prompt's notch accented. It reads the outline
/// and the active prompt from `PromptRailState` and its laid-out height and
/// overflow offset from `PromptRailPointer`, and nothing else; the pane
/// around it never reads either.
///
/// - **Notches** – drawn in a `Canvas` with the AppKit rail's geometry
///   (`PromptRailLayout`) and colours (`PromptRailNotchStyle`). Only notches
///   inside the rail are drawn.
/// - **Overflow** – past the minimum pitch the notches are offset to keep the
///   active one `PromptRailLayout.edgeMargin` from either end, and a gradient
///   mask fades whichever edge clips a notch.
/// - **Hover** – not here. SwiftUI hover follows hit-testing, so a hover
///   handler on the rail would hear the pointer leave once the open card
///   covers the rail, and Escape and click suppression would lapse with the
///   pointer still on it. `PromptRailContainer` reports hover from the rail
///   column's geometry instead, through `PromptRailPointer`.
/// - **Accessibility** – a group labelled "Prompts" with one button per entry,
///   labelled with its first line and time; pressing one jumps to it.
///
/// Coordinates are y-down, matching `PromptRailLayout`.
struct PromptRailSwiftUIView: View {
    let state: PromptRailState
    let pointer: PromptRailPointer

    /// Read so an appearance change redraws the notches, re-resolving their
    /// dynamic colours.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let entries = state.entries
        let active = state.activeIndex
        let offset = pointer.offset
        let layout = PromptRailLayout(count: entries.count, railHeight: pointer.railHeight)
        let _ = colorScheme
        Canvas { context, size in
            Self.drawNotches(in: &context, size: size, entries: entries, active: active, offset: offset)
        }
        .frame(width: PromptRailLayout.width)
        .frame(maxHeight: .infinity)
        .mask {
            if layout.overflows, layout.railHeight > 0 {
                PromptRailFade.gradient(
                    height: layout.railHeight,
                    fadesTop: offset > 0,
                    fadesBottom: offset < layout.contentHeight - layout.railHeight)
            } else {
                Rectangle()
            }
        }
        // The whole column, not only the drawn notches, is the rail: the
        // container's hover handler hears the pointer anywhere over it.
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            pointer.railLaidOut(height: height, count: state.entries.count, active: state.activeIndex)
        }
        .onChange(of: OutlineKey(count: entries.count, active: active), initial: true) { _, key in
            pointer.outlineChanged(count: key.count, active: key.active)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Prompts")
        .accessibilityChildren {
            accessibilityButtons(entries: entries, layout: layout, offset: offset)
        }
    }

    /// What the overflow offset depends on besides the rail's height.
    private struct OutlineKey: Equatable {
        let count: Int
        let active: Int?
    }

    /// Draws the notches that fall inside the rail, offset by `offset`.
    nonisolated static func drawNotches(
        in context: inout GraphicsContext,
        size: CGSize,
        entries: [PromptOutlineEntry],
        active: Int?,
        offset: CGFloat
    ) {
        let layout = PromptRailLayout(count: entries.count, railHeight: size.height)
        guard let range = visibleRange(layout: layout, offset: offset) else { return }
        for index in range {
            let isActive = index == active
            let rect = layout.notchRect(index, active: isActive).offsetBy(dx: 0, dy: -offset)
            let color = Color(nsColor: PromptRailNotchStyle.color(for: entries[index].kind, active: isActive))
            context.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(color))
        }
    }

    /// The notches at least partly inside a rail `layout.railHeight` tall,
    /// with one to spare at each end; nil with none.
    nonisolated static func visibleRange(layout: PromptRailLayout, offset: CGFloat) -> ClosedRange<Int>? {
        guard layout.count > 0 else { return nil }
        let pitch = layout.pitch
        let first = Int(((offset - PromptRailLayout.topInset) / pitch).rounded(.down)) - 1
        let last = Int(((offset + layout.railHeight - PromptRailLayout.topInset) / pitch).rounded(.up)) + 1
        let lower = max(0, first)
        let upper = min(layout.count - 1, last)
        return lower <= upper ? lower...upper : nil
    }

    /// One button per entry, each over the band of the rail its notch owns:
    /// the full rail width, one pitch tall.
    private func accessibilityButtons(
        entries: [PromptOutlineEntry], layout: PromptRailLayout, offset: CGFloat
    ) -> some View {
        let now = Date()
        let state = self.state
        return ZStack(alignment: .topLeading) {
            ForEach(entries.indices, id: \.self) { index in
                let entry = entries[index]
                Button(PromptRailNSView.accessibilityLabel(for: entry, now: now)) {
                    state.onJump?(entry.id)
                }
                .frame(width: PromptRailLayout.width, height: layout.pitch)
                .position(x: PromptRailLayout.width / 2, y: layout.notchCenterY(index) - offset)
            }
        }
        .frame(width: PromptRailLayout.width, height: layout.railHeight, alignment: .topLeading)
    }
}

/// The SwiftUI renderer's pointer and rail geometry: where the pointer is over
/// the rail column, which notch it points at, and the rail's height and
/// overflow offset that turn one into the other.
///
/// - **Who writes it** – the rail writes its height and offset;
///   `PromptRailContainer`'s hover handler writes the pointer, from a handler
///   on the whole pane so that the open card, which covers the rail, cannot
///   occlude it; the card overlay writes whether the window is key.
/// - **Who reads it** – the rail draws with `offset` and `railHeight`, the
///   only observed properties: its fade mask and accessibility bands are
///   laid out from them, so a resize that leaves the offset alone must still
///   re-render it. The card reads `pointedIndex` and `pointerY` once, when it
///   opens, so a pointer moving over the rail re-renders nothing.
@MainActor
@Observable
final class PromptRailPointer {
    /// How far the notches are shifted up to keep the active one in view.
    private(set) var offset: CGFloat = 0

    /// The rail's height, as last laid out. Written only when it changes.
    private(set) var railHeight: CGFloat = 0
    /// The notch nearest the pointer while it is over the rail column; nil
    /// otherwise.
    @ObservationIgnored private(set) var pointedIndex: Int?
    /// The pointer's last y over the rail column, in rail coordinates. The
    /// card scrolls its list on opening so the pointed row sits under it.
    @ObservationIgnored private(set) var pointerY: CGFloat = 0
    /// Whether the rail's window is key. Rail hover counts only in the key
    /// window, as the AppKit rail's `.activeInKeyWindow` tracking area does:
    /// the Escape monitor an open card runs is app-wide, so a card opened in
    /// a background window would take Escape typed in the key one.
    @ObservationIgnored private(set) var isWindowKey = false
    /// Whether the rail column was hovered at the last report.
    @ObservationIgnored private var reportedRailHover = false

    init() {}

    /// The rail was laid out `height` tall.
    func railLaidOut(height: CGFloat, count: Int, active: Int?) {
        if railHeight != height { railHeight = height }
        outlineChanged(count: count, active: active)
    }

    /// The outline or the active prompt changed: move the notches by the
    /// least that keeps the active one in view.
    func outlineChanged(count: Int, active: Int?) {
        // A rail not yet laid out has no height to keep anything in view of;
        // an offset derived from it would carry into the first real layout.
        let next = railHeight > 0
            ? PromptRailLayout(count: count, railHeight: railHeight)
                .scrollOffset(keepingVisible: active, current: offset)
            : 0
        if next != offset { offset = next }
    }

    /// The pointer moved to `location` in the pane's coordinates, or left the
    /// pane (`nil`). The rail is hovered while the pointer is over its column
    /// — `x` inside `PromptRailLayout.width` — whatever is drawn on top of it:
    /// the open card's dash column sits over the notches, and a pointer there
    /// is still on the rail for Escape and click suppression.
    ///
    /// Hover over the rail is reported on every move, so a card that
    /// `closeNow()` shut under a resting pointer opens again once it moves.
    /// Leaving is reported once.
    func pointerMoved(to location: CGPoint?, count: Int, hover: PromptRailHoverModel) {
        let onRail: Bool
        if isWindowKey, let location, location.x >= 0, location.x < PromptRailLayout.width {
            onRail = true
            pointerY = location.y
            pointedIndex = PromptRailLayout(count: count, railHeight: railHeight)
                .index(atRailY: location.y, offset: offset)
        } else {
            onRail = false
            pointedIndex = nil
        }
        if onRail || reportedRailHover {
            hover.railHoverChanged(onRail)
        }
        reportedRailHover = onRail
    }

    /// The rail's window became key or stopped being key. Losing key closes
    /// the card at once: no exit event follows, and an open card would keep
    /// the app-wide Escape monitor running in a window that no longer takes
    /// keys.
    func windowKeyChanged(_ isKey: Bool, hover: PromptRailHoverModel) {
        isWindowKey = isKey
        guard !isKey else { return }
        reportedRailHover = false
        pointedIndex = nil
        hover.closeNow()
    }
}

extension PromptRailFade {
    /// The SwiftUI spelling of `configure(_:height:fadesTop:fadesBottom:)`:
    /// fades the top and/or bottom `PromptRailLayout.fadeHeight` of a view
    /// `height` tall, used as a mask.
    static func gradient(height: CGFloat, fadesTop: Bool, fadesBottom: Bool) -> LinearGradient {
        let fraction = height > 0 ? min(0.5, PromptRailLayout.fadeHeight / height) : 0
        return LinearGradient(
            stops: [
                Gradient.Stop(color: fadesTop ? .clear : .black, location: 0),
                Gradient.Stop(color: .black, location: fraction),
                Gradient.Stop(color: .black, location: 1 - fraction),
                Gradient.Stop(color: fadesBottom ? .clear : .black, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom)
    }
}
