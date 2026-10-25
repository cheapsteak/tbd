import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TestProcessDefaults

/// Driving helpers for `TableTranscriptScene`, shared by `TableTranscriptPaneTests`
/// and the prompt-rail suites: prime the coordinator the way production's first
/// update does, move the clip, and read row geometry back.
@MainActor
extension TableTranscriptScene {
    /// Throws `AppKitRowHeightEstimationIsOn` when the table holds a row
    /// height its delegate does not give for that row.
    ///
    /// With `NSTableViewCanEstimateRowHeights` off, as production runs, AppKit
    /// asks the delegate for every row's height, so once the table has settled
    /// every row's rectangle is the delegate's height plus the intercell
    /// spacing; a realize-time correction under 0.5pt is not passed on, hence
    /// the 1pt tolerance. With it on, rows AppKit has never shown keep a height
    /// of its own guessing, and AppKit moves the clip itself as it swaps the
    /// guesses out — so a test that scrolls or pins would fail for a reason
    /// its own assertions cannot name. Asks the delegate through its
    /// `heightOfRow`, which reads cached heights and estimates and builds no
    /// cell.
    func requireDelegateRowHeights() throws {
        let spacing = tableView.intercellSpacing.height
        var mismatched = 0
        var first: AppKitRowHeightEstimationIsOn.Row?
        for row in 0..<tableView.numberOfRows {
            let appKit = tableView.rect(ofRow: row).height - spacing
            let delegate = coordinator.tableView(tableView, heightOfRow: row)
            guard abs(appKit - delegate) > 1 else { continue }
            mismatched += 1
            if first == nil {
                first = AppKitRowHeightEstimationIsOn.Row(index: row, appKit: appKit, delegate: delegate)
            }
        }
        guard let first else { return }
        throw AppKitRowHeightEstimationIsOn(
            mismatchedRows: mismatched, rowCount: tableView.numberOfRows, first: first,
            registeredAtLoad: TBDTestProcessDefaultsRegistered())
    }

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
    /// the settled column width; fails the test if it never settles, or if
    /// AppKit's own row-height estimation is on in this process
    /// (`requireDelegateRowHeights()`).
    @discardableResult
    func prime(nodes: [TranscriptRenderNode], linkRoot: String = "") -> CGFloat {
        for _ in 0..<4 {
            let widthAtUpdate = tableView.bounds.width
            coordinator.update(
                nodes: nodes, atBottom: .constant(true), activityToggleToken: 0, linkRoot: linkRoot)
            settle()
            if tableView.bounds.width == widthAtUpdate {
                do { try requireDelegateRowHeights() } catch { Issue.record(error) }
                return widthAtUpdate
            }
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

    /// The last clip move the bounds observer counted as the reader's while
    /// a jump or prepend anchor was held, with the stack that posted it
    /// (`Coordinator.lastHeldReaderMove`), for a failure's comment: a hold
    /// that ends early then names what moved the clip. A test may make such a
    /// move itself on purpose; this reports the latest one.
    var heldReaderMoveNote: String {
        #if DEBUG
        return coordinator.lastHeldReaderMove.map { "\($0)" } ?? "no reader move while anything was held"
        #else
        return "reader moves are recorded in DEBUG builds only"
        #endif
    }
}

/// The table holds row heights its delegate never gave it: NSTableView's own
/// row-height estimation is on in this test process. See
/// `TableTranscriptScene.requireDelegateRowHeights()`.
struct AppKitRowHeightEstimationIsOn: Error, CustomStringConvertible {
    struct Row {
        let index: Int
        let appKit: CGFloat
        let delegate: CGFloat
    }

    let mismatchedRows: Int
    let rowCount: Int
    let first: Row
    /// Whether `TestProcessDefaults` registered the opt-out when the test
    /// bundle loaded.
    let registeredAtLoad: Bool

    var description: String {
        "NSTableView's row-height estimation is on in this test process: \(mismatchedRows) of "
            + "\(rowCount) rows hold a height the delegate does not give (row \(first.index): "
            + "AppKit \(first.appKit) pt, delegate \(first.delegate) pt). The app turns it off at "
            + "launch; the TestProcessDefaults target registers NSTableViewCanEstimateRowHeights = NO "
            + "when the test bundle loads (registered: \(registeredAtLoad)). With it on, AppKit moves "
            + "the clip as it swaps its guesses for real heights, so scroll and pin assertions fail "
            + "for that reason."
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
