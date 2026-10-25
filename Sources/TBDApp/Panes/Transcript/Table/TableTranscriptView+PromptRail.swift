import AppKit

/// Prompt rail tracking and navigation: the outline of prompts in `nodes`,
/// which one is active for the current scroll position (reported to
/// `promptRailPresenter`), and jumps to a prompt.
///
/// Everything here reads node data and `rect(ofRow:)` only. `rect(ofRow:)` sums
/// row heights the table already holds (cached exact heights or per-kind
/// estimates), so nothing here builds or measures a cell.
@MainActor
extension TableTranscriptView.Coordinator {
    /// How far below the viewport top a jump puts its target row's top.
    static let jumpTopInset: CGFloat = 16

    /// How far the viewport's top must sit below the active prompt's top for
    /// Previous to read the reader as inside that prompt's exchange. Right
    /// after a jump the viewport's top is `jumpTopInset` above the target's,
    /// a depth of −16, so Previous then goes to the prompt before.
    private static let insideExchangeDepth: CGFloat = 16

    /// The Previous Prompt and Next Prompt commands.
    enum PromptStep { case previous, next }

    /// What ended a jump's pin, its hold, or both (`lastJumpRelease`).
    enum JumpRelease: Equatable {
        /// Both: the reader scrolled.
        case readerScroll
        /// Both: the column width changed.
        case widthChange
        /// Both: the rows were rebuilt.
        case rebuild
        /// Both: history was prepended.
        case prepend
        /// Both: Next from the last prompt scrolled to the end.
        case nextFromLast
        /// The pin only: the coordinator followed the tail.
        case tailFollow
        /// The hold only: a prompt arrived after the target.
        case newPrompt
    }

    /// Rebuilds the outline from `nodes`, tells the presenter if it changed,
    /// then calls `refreshActivePrompt()`. `update(...)` calls it once the table
    /// holds the new rows. While a tail-follow is queued
    /// (`isAwaitingTailFollow`) that call re-derives nothing: the entries are
    /// delivered now, and the follow re-derives the active prompt once the clip
    /// has reached the end.
    ///
    /// A prompt arriving after a held jump target ends the hold before the
    /// active prompt is next re-derived, so the rule can pick the new prompt.
    /// The jump's pin is unaffected: a row added below cannot move the target.
    ///
    /// Projects only the prompts `promptOutlineCache` has not seen at their
    /// current content, so an append reads the new prompts' text and no other.
    func refreshPromptOutline() {
        let entries = promptOutlineCache.entries(from: nodes)
        if entries != promptEntries {
            if gainsEntryAfterHeldJumpTarget(entries) {
                heldJumpTargetID = nil
                lastJumpRelease = .newPrompt
            }
            promptEntries = entries
            promptRailPresenter?.promptRail(entriesDidChange: entries)
        }
        refreshActivePrompt()
    }

    /// Whether `entries` has more entries after the held jump target than
    /// `promptEntries` does: a prompt or peer message arrived below it. False
    /// with no held target, or one that is not an entry (it holds nothing).
    private func gainsEntryAfterHeldJumpTarget(_ entries: [PromptOutlineEntry]) -> Bool {
        guard let held = heldJumpTargetID, entries.count > promptEntries.count,
              let newIndex = entries.firstIndex(where: { $0.id == held })
        else { return false }
        let oldCountAfter = promptEntries.firstIndex { $0.id == held }
            .map { promptEntries.count - 1 - $0 } ?? 0
        return entries.count - 1 - newIndex > oldCountAfter
    }

    /// Applies `PromptRailActiveRule` to the entries' row tops and the clip
    /// view's bounds, and tells the presenter if the active index changed. The
    /// clip-bounds observer calls it on every scroll; the rule's binary search
    /// keeps that to O(log n) `rect(ofRow:)` reads.
    ///
    /// Does nothing while a tail-follow is queued (`isAwaitingTailFollow`):
    /// the document has grown at the bottom and the clip has not followed, so
    /// the bottom rule would fail for that turn. The follow calls this once
    /// the clip is at the end.
    func refreshActivePrompt() {
        guard !isAwaitingTailFollow else { return }
        let index: Int?
        if promptEntries.isEmpty {
            index = nil
        } else {
            guard let tableView, let scrollView, promptOutlineDescribesNodes(tableView) else { return }
            let entries = promptEntries
            let clip = scrollView.contentView.bounds
            let held = heldJumpTargetID.flatMap { id in entries.firstIndex { $0.id == id } }
            index = PromptRailActiveRule.activeIndex(
                count: entries.count,
                rowTop: { tableView.rect(ofRow: entries[$0].rowIndex).minY },
                viewport: PromptRailActiveRule.Viewport(
                    minY: clip.minY, height: clip.height, documentHeight: tableView.frame.height),
                heldIndex: held)
        }
        guard index != activePromptIndex else { return }
        activePromptIndex = index
        promptRailPresenter?.promptRail(activeIndexDidChange: index)
    }

    /// Whether an `.updateLast` can change the outline: only when the last row
    /// is a prompt or peer message now, or was an entry of the outline being
    /// replaced. A streaming reply is neither, so its ticks skip the rebuild.
    /// Call once `nodes` holds the new array; `.updateLast` keeps the row count,
    /// so the old outline's row indices still name the same rows.
    func updateLastCanChangeOutline() -> Bool {
        if let last = promptEntries.last, last.rowIndex == nodes.count - 1 { return true }
        guard let node = nodes.last, case .chatBubble(let item) = node.kind else { return false }
        switch item {
        case .userPrompt, .peerMessage:
            return true
        default:
            return false
        }
    }

    /// Whether the entries still name the rows they were built from. A
    /// clip-bounds change can post from inside `update(...)` — a reload that
    /// clamps the clip, or the prepend restore — after `nodes` moved and before
    /// `refreshPromptOutline()` rebuilds the entries. An index computed then
    /// would be against rows the entries no longer describe, so the refresh
    /// waits for the rebuild instead. Checking the two ends is O(1) and catches
    /// any insertion or removal at or above the last entry, which is what
    /// shifts entries' rows.
    private func promptOutlineDescribesNodes(_ tableView: NSTableView) -> Bool {
        guard let first = promptEntries.first, let last = promptEntries.last else { return true }
        let rowCount = min(nodes.count, tableView.numberOfRows)
        return [first, last].allSatisfy { entry in
            entry.rowIndex < rowCount && nodes[entry.rowIndex].id == entry.id
        }
    }

    // MARK: Jumping

    /// Scrolls at once, unanimated, so the row for `id` has its top
    /// `jumpTopInset` below the viewport top, clamped to the scrollable range,
    /// and holds it there: the row becomes `pendingJumpAnchor`, re-pinned
    /// whenever a row above it corrects an estimated height, and
    /// `heldJumpTargetID`, which keeps it the active prompt. Nothing above the
    /// target is measured; the pin absorbs those rows' corrections as they
    /// realize. See `pendingJumpAnchor` and `heldJumpTargetID` for what
    /// releases each.
    ///
    /// An id with no row is ignored, unlike `scrollToRow(withNodeID:)`, whose
    /// fallback to the end suits the composer hint that uses it.
    func jump(toNodeID id: String) {
        guard let tableView, let scrollView,
              let row = nodes.firstIndex(where: { $0.id == id }),
              row < tableView.numberOfRows
        else { return }
        let clip = scrollView.contentView
        let rowTop = tableView.rect(ofRow: row).minY
        let maxOrigin = max(0, tableView.frame.height - clip.bounds.height)
        let origin = min(max(0, rowTop - Self.jumpTopInset), maxOrigin)

        // The jump moves the reader, so a held prepend anchor no longer says
        // where they are looking: a later correction above it would pull the
        // viewport back. The previous jump's anchor is replaced below. A
        // tail-follow queued before the jump, by content that landed at the
        // bottom, would undo it.
        pendingPrependAnchor = nil
        supersedeQueuedTailFollow()
        // Held before the move, so the active prompt the move reports through
        // the bounds observer is already the target.
        heldJumpTargetID = id
        lastJumpRelease = nil
        do {
            isRestoringAnchor = true
            defer { isRestoringAnchor = false }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: origin))
            scrollView.reflectScrolledClipView(clip)
        }
        pendingJumpAnchor = PrependAnchor(
            id: id, offset: rowTop - origin, gapToBottom: viewportGapToBottom())
        refreshActivePrompt()
        // Re-assert once more on the next turn, after AppKit has laid out the
        // rows the move brought on screen and corrected their heights — the
        // same double pin the prepend path and the initial open use.
        DispatchQueue.main.async { [weak self] in
            guard let self, let held = self.pendingJumpAnchor else { return }
            self.restorePrependAnchor(held)
        }
    }

    /// Previous Prompt and Next Prompt.
    ///
    /// - Previous jumps to the active prompt itself when the reader is inside
    ///   its exchange, its top more than `insideExchangeDepth` above the
    ///   viewport top, and otherwise to the prompt before it. From the top of the first
    ///   prompt it does nothing.
    /// - Next jumps to the prompt after the active one. From the last prompt it
    ///   scrolls to the end of the transcript and stops holding the target.
    /// - With no active prompt, Next jumps to the first and Previous does
    ///   nothing.
    func jumpToPrompt(_ step: PromptStep) {
        let entries = promptEntries
        guard !entries.isEmpty else { return }
        guard let active = activePromptIndex, entries.indices.contains(active) else {
            if step == .next { jump(toNodeID: entries[0].id) }
            return
        }
        switch step {
        case .previous:
            guard let tableView, let scrollView else { return }
            let rowTop = tableView.rect(ofRow: entries[active].rowIndex).minY
            let depth = scrollView.contentView.bounds.minY - rowTop
            let target = depth > Self.insideExchangeDepth ? active : active - 1
            guard target >= 0 else { return }
            jump(toNodeID: entries[target].id)
        case .next:
            if active + 1 < entries.count {
                jump(toNodeID: entries[active + 1].id)
                return
            }
            // From the last prompt. Released before the scroll: when the clip
            // is already at the end the scroll posts nothing, so the observer
            // would not release it.
            releaseJumpAnchor(.nextFromLast)
            scrollToEnd(animated: false)
            refreshActivePrompt()
        }
    }

    /// Stops holding the last jump's target, as a pin and as the active
    /// prompt, and records why when something was held. Every caller
    /// re-derives the active prompt on its own path.
    func releaseJumpAnchor(_ reason: JumpRelease) {
        if pendingJumpAnchor != nil || heldJumpTargetID != nil { lastJumpRelease = reason }
        pendingJumpAnchor = nil
        heldJumpTargetID = nil
    }
}
