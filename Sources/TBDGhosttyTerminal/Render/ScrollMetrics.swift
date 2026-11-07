// Adapted from tkzmux c961533 Sources/TkzTerminalCore/ScrollMetrics.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// ScrollMetrics.swift — the terminal's scroll position, as a pure value.
//
// libghostty maintains `{total, offset, len}` for exactly this purpose, and `vt/terminal.h` is
// explicit about how it must be consumed:
//
//     There is intentionally no change notification for scroll state. Callers building scrollbars
//     should poll this once per frame or per write batch and diff the result to detect changes;
//     this is what Ghostty's own renderer does.
//
// So this type is a *snapshot*, not a subscription. `FrameBuilder.update` reads one per frame
// inside the terminal lock it already takes for `begin_update`, and a view diffs the result. A
// subscription would wake the display link on every scroll change, which the idle guarantee
// forbids.
import GhosttyVt

/// Where the viewport sits in the scrollable area, in rows, plus which screen it belongs to.
///
/// Rows, not pixels: the conversion to a thumb rect is the view layer's job, which keeps this
/// side testable without a window.
struct TerminalScrollMetrics: Sendable, Hashable {
    /// Total size of the scrollable area in rows (viewport + scrollback).
    var total: Int
    /// Offset into the total area that the viewport is at. Row 0 is the top of the scrollback.
    /// The same row space as `GHOSTTY_SCROLL_VIEWPORT_ROW`, so a position round-trips cleanly.
    var offset: Int
    /// Length of the visible area in rows.
    var visible: Int
    /// True on the alternate screen (Claude Code's TUI lives there), which has no scrollback.
    var isAlternateScreen: Bool

    init(total: Int, offset: Int, visible: Int, isAlternateScreen: Bool) {
        self.total = total
        self.offset = offset
        self.visible = visible
        self.isAlternateScreen = isAlternateScreen
    }

    /// Nothing to show. Also the value a failed read degrades to: a missing thumb is the safe
    /// failure, a wrong one is not.
    ///
    /// Spelled `empty` rather than `none` on purpose — it is stored in an `Optional` by the view's
    /// diff cache, where `== .none` would silently resolve to `Optional.none`.
    static let empty = TerminalScrollMetrics(
        total: 0, offset: 0, visible: 0, isAlternateScreen: false)

    /// True when there is more content than fits: the only case that draws anything.
    var isScrollable: Bool { !isAlternateScreen && visible > 0 && total > visible }

    /// Rows the viewport can travel. Zero when there is nothing to scroll.
    var scrollableRows: Int { max(0, total - visible) }

    /// Reads the current scroll position out of `terminal`.
    ///
    /// Two `ghostty_terminal_get`s, both amortized O(1) — cheap enough to run unconditionally on
    /// every frame, which is what the header asks for.
    ///
    /// The alternate screen is read explicitly rather than inferred from `total == len`. The header
    /// promises the alt screen has no scrollback, but never that `scrollbar.total` excludes the
    /// *primary* screen's — and `SCROLLBACK_MAX_BYTES` is documented to report the primary screen's
    /// value even while the alt screen is active, which is reason enough not to guess.
    ///
    /// Caller holds the terminal lock: it is only ever called inside `GhosttyTerminal.withRaw`.
    static func read(_ terminal: VtTerminal) -> TerminalScrollMetrics {
        var bar = GhosttyTerminalScrollbar()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar) == GHOSTTY_SUCCESS
        else { return .empty }

        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        // A screen we could not read is treated as primary: it only ever adds a thumb the geometry
        // would have drawn anyway, and `total <= visible` still hides it on a real alt screen.
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)

        return TerminalScrollMetrics(
            total: Int(bar.total),
            offset: Int(bar.offset),
            visible: Int(bar.len),
            isAlternateScreen: screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE)
    }
}
