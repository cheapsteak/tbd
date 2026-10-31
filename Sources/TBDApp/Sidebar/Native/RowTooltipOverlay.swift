import AppKit
import SwiftUI

/// The native sidebar's tooltip bubble: today's `RowTooltipBubble`, hosted, in
/// a view laid over the whole outline (spec "Hover"). It shows a truncated row
/// name and a PR glyph's description below the hovered element, at once, as
/// `SidebarView`'s `RowTooltipPreferenceKey` overlay does, rather than after
/// AppKit's tooltip delay.
///
/// It never takes a click: `hitTest` returns nil for it and everything inside
/// it, so a press under the bubble reaches the row and can start a drag.
final class RowTooltipOverlay: NSView {
    private let bubble = NSHostingView(rootView: RowTooltipBubble(text: ""))
    private(set) var text: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bubble.isHidden = true
        addSubview(bubble)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `text` 4 pt below `anchor`, left-aligned with it, kept inside the
    /// overlay's width. `anchor` is in the overlay's coordinates.
    func show(_ text: String, below anchor: NSRect) {
        if text != self.text {
            self.text = text
            bubble.rootView = RowTooltipBubble(text: text)
        }
        let size = bubble.fittingSize
        let x = max(min(anchor.minX, bounds.width - size.width), 0)
        bubble.frame = NSRect(x: x, y: anchor.maxY + 4, width: size.width, height: size.height)
        bubble.isHidden = false
    }

    func hide() {
        text = nil
        bubble.isHidden = true
    }
}
