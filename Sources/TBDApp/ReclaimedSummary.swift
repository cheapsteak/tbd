import Foundation
import TBDShared

/// Pure aggregation over a repo's `[ReapRecord]` (as fetched into
/// `AppState.reapRecords[repoID]`). UI-free on purpose: the "Reclaimed"
/// section (History → Reclaimed, Task 12) renders exactly these fields, and
/// keeping the arithmetic/sorting out of any View makes it trivially
/// testable.
///
/// Callers decide whether to exclude already-restored records before
/// constructing this (e.g. `records.filter { $0.restoredAt == nil }`) —
/// `ReclaimedSummary` itself does no restoredAt filtering, it just summarizes
/// whatever list it's handed.
struct ReclaimedSummary {
    let records: [ReapRecord]

    init(records: [ReapRecord]) {
        self.records = records
    }

    /// Total number of records in this summary.
    var count: Int {
        records.count
    }

    /// Sum of `apparentBytes` across all records. A nil `apparentBytes`
    /// (e.g. `du` failed or was never run) contributes 0, not a crash.
    var totalApparentBytes: Int64 {
        records.reduce(0) { $0 + ($1.apparentBytes ?? 0) }
    }

    /// Agent-worktree records, most-recently-reaped first — these render as
    /// individual restorable rows.
    var agentRecords: [ReapRecord] {
        records
            .filter { $0.kind == .agentWorktree }
            .sorted { $0.reapedAt > $1.reapedAt }
    }

    /// Scratchpad records rolled up into a single (count, bytes) pair —
    /// scratchpad volume can be high and scratchpads aren't individually
    /// restorable (`OrphanGC.restore` only accepts `.agentWorktree`), so the
    /// UI shows one summary line instead of a row per scratchpad. `nil` when
    /// there are no scratchpad records to summarize.
    var scratchpadRollup: (count: Int, bytes: Int64)? {
        let scratch = records.filter { $0.kind == .scratchpad }
        guard !scratch.isEmpty else { return nil }
        let bytes = scratch.reduce(Int64(0)) { $0 + ($1.apparentBytes ?? 0) }
        return (scratch.count, bytes)
    }

    /// `.archivedWorktree` records rolled up into a single (count, bytes)
    /// pair, same shape and same reason as `scratchpadRollup`: these are
    /// directories the sweep reclaimed after an archive failed to remove
    /// them (or drained from a pool's `.deleting/` queue), and like
    /// scratchpads they aren't individually restorable — `OrphanGC.restore`
    /// only accepts `.agentWorktree`. `nil` when there are none to summarize.
    var archivedWorktreeRollup: (count: Int, bytes: Int64)? {
        let archived = records.filter { $0.kind == .archivedWorktree }
        guard !archived.isEmpty else { return nil }
        let bytes = archived.reduce(Int64(0)) { $0 + ($1.apparentBytes ?? 0) }
        return (archived.count, bytes)
    }

    /// Subset excluding already-restored records — a restored agent worktree
    /// is no longer reclaimed disk. This is what the "Reclaimed (N · X GB)"
    /// header counts; the expanded row list still shows every `agentRecords`
    /// entry (restored ones render "Restored <date>" instead of a Restore
    /// button, via `ReapRecord.restoredAt`).
    var unrestored: ReclaimedSummary {
        ReclaimedSummary(records: records.filter { $0.restoredAt == nil })
    }
}
