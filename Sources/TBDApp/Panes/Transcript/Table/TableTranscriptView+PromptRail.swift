import AppKit

/// Prompt rail tracking: the outline of prompts in `nodes` and which one is
/// active for the current scroll position, reported to `promptRailPresenter`.
///
/// Both refreshes read node data and `rect(ofRow:)` only. `rect(ofRow:)` sums
/// row heights the table already holds (cached exact heights or per-kind
/// estimates), so nothing here builds or measures a cell.
@MainActor
extension TableTranscriptView.Coordinator {
    /// Rebuilds the outline from `nodes`, tells the presenter if it changed,
    /// then re-derives the active prompt. `update(...)` calls it once the table
    /// holds the new rows.
    func refreshPromptOutline() {
        let entries = PromptOutline.entries(from: nodes)
        if entries != promptEntries {
            promptEntries = entries
            promptRailPresenter?.promptRail(entriesDidChange: entries)
        }
        refreshActivePrompt()
    }

    /// Applies `PromptRailActiveRule` to the entries' row tops and the clip
    /// view's bounds, and tells the presenter if the active index changed. The
    /// clip-bounds observer calls it on every scroll; the rule's binary search
    /// keeps that to O(log n) `rect(ofRow:)` reads.
    func refreshActivePrompt() {
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
}
