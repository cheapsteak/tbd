import AppKit
import SwiftUI
import Testing
@testable import TBDApp

/// Driving helpers for `TableTranscriptScene`, shared by `TableTranscriptPaneTests`
/// and the prompt-rail suites: prime the coordinator the way production's first
/// update does, move the clip, and read row geometry back.
@MainActor
extension TableTranscriptScene {
    /// Primes the scene on `nodes` exactly as production's first `updateNSView`
    /// does, then keeps updating until the table's COLUMN WIDTH stops moving.
    ///
    /// The first `update` after `makeNSView` always takes the width-change branch
    /// (`cachedColumnWidth` starts at 0): it measures the bottom window and reloads.
    /// That reload is also what first makes the document taller than the viewport,
    /// so an autohiding legacy scroller claims its 17pt on the NEXT layout pass —
    /// AFTER those heights were cached. Every cache here is keyed by `(id,
    /// contentVersion, width)`, so the whole cache is then unreachable, and the next
    /// `update` legitimately takes the width-change branch again (wipe + re-measure)
    /// instead of the `.rebuild` branch a disclosure test means to exercise. Rows
    /// above the click fall back to the arithmetic estimate, and even though that
    /// estimate is now accurate to a point or two on these fixtures
    /// (`TranscriptEstimatorAccuracyTests` pins it), a re-measure at a DIFFERENT
    /// width re-flows every one of them, so the anchor still jumps.
    ///
    /// So: settle the width FIRST, and only then take a "before" snapshot. Returns
    /// the settled column width; fails the test if it never settles.
    @discardableResult
    func prime(nodes: [TranscriptRenderNode], linkRoot: String = "") -> CGFloat {
        for _ in 0..<4 {
            let widthAtUpdate = tableView.bounds.width
            coordinator.update(
                nodes: nodes, atBottom: .constant(true), activityToggleToken: 0, linkRoot: linkRoot)
            settle()
            if tableView.bounds.width == widthAtUpdate { return widthAtUpdate }
        }
        Issue.record("the table's column width never settled: \(tableView.bounds.width)")
        return tableView.bounds.width
    }

    /// Scrolls so `row`'s top sits `below` points under the viewport top.
    func park(row: Int, below: CGFloat) {
        let clip = scrollView.contentView
        let target = max(0, tableView.rect(ofRow: row).minY - below)
        clip.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clip)
        settle()
    }

    /// Moves the clip to `y`, clamped to the document.
    func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, tableView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Screen-space offset of `row`'s top edge from the top of the viewport.
    func screenOffset(ofRow row: Int) -> CGFloat {
        tableView.rect(ofRow: row).origin.y - scrollView.contentView.bounds.origin.y
    }

    /// Vertical gap between the viewport's bottom edge and the document bottom.
    var gapToBottom: CGFloat {
        let clip = scrollView.contentView
        return tableView.frame.height - (clip.bounds.origin.y + clip.bounds.height)
    }
}

/// Lets work the coordinator deferred with `DispatchQueue.main.async` — the
/// tail-follow `scrollToEnd` — actually run.
///
/// `TableTranscriptScene.settle()` cannot do it: a Swift Testing `@MainActor`
/// test body is ITSELF a block executing on the serial main queue, so the
/// nested run loop that settle turns can never re-enter that queue, and the
/// deferred block sits there until the test ends. Suspending is what returns
/// the queue, so the queued block runs and only then does this continuation
/// resume. Without this a test would "pass" against a tail-follow that never
/// fired.
@MainActor
func drainMainQueue() async {
    for _ in 0..<4 { await Task.yield() }
}
