import Foundation

/// Since when each worktree's branch tip has stood still.
///
/// The third of §13's runaway inputs — "commits unchanged across cycles" — and
/// it costs **no new subprocess**. `refreshGitStatuses` already resolves every
/// branch tip in one `git for-each-ref` per repo to drive the conflict sweep's
/// dirty gate; this actor is handed the same map on the way past and remembers
/// when each tip was first found to have **stopped moving** — the second
/// sighting of the same value, never the first. A tip that keeps arriving
/// unchanged keeps that stamp, so "no commits since 09:14" falls out of
/// comparisons the sweep was making anyway.
///
/// **A working-tree diff fact is deliberately absent.** §13 names "commits or
/// the diff unchanged", but the sweep resolves refs, not worktree status —
/// answering the diff half would mean a `git status` subprocess per worktree per
/// sweep, which is the per-agent cost this slice exists to avoid. So only the
/// commit half is reported, and an unestablished fact is reported as nil rather
/// than as "unchanged": `SessionCounters.commitsUnchangedSince` is optional
/// precisely so ignorance does not get to look like stillness.
///
/// Entries are scoped by repo for the same reason `ConflictSweepCache`'s are:
/// the sweep runs per repo, so an unscoped `retain` during repo B's pass would
/// evict repo A's entries and the stamps would restart on every sweep of a
/// multi-repo install.
public actor BranchTipTracker {
    private struct Entry {
        var tip: String
        /// When this tip was observed to **stop** moving: the instant of the
        /// first observation that found it unchanged since the one before.
        ///
        /// nil on a first sighting, and that is the whole point. A first
        /// sighting establishes what the tip *is*, never how long it has been
        /// that — the sweep has one sample and one sample cannot measure a
        /// duration. Stamping it with the read would report a branch untouched
        /// for three days as "unchanged since thirty seconds after the daemon
        /// restarted", which disarms stall detection for hours after every
        /// restart while looking like an answer.
        var unchangedSince: Date?
    }

    /// repoID → (worktreeID → the tip last seen and when it arrived).
    private var entries: [UUID: [UUID: Entry]] = [:]

    public init() {}

    /// Record a branch tip observed by the sweep.
    ///
    /// Three cases, and the first is the one worth stating: a **first** sighting
    /// records the tip with no stillness stamp at all. It cannot have one —
    /// nothing has yet been compared — and inventing one would make every
    /// branch in the fleet look freshly still for the rest of the daemon's
    /// life. The **second** sighting of the same tip is the first evidence of
    /// stillness, and it stamps the moment that evidence arrived; further
    /// unchanged sightings keep that stamp, because refreshing it would report
    /// every still branch as having just moved. A **changed** tip starts over,
    /// unstamped, exactly like a first sighting.
    ///
    /// The consequence is deliberate: "unchanged since" is always a duration
    /// TBD actually watched elapse, and is understated by up to one sweep
    /// interval rather than overstated by however long the branch had already
    /// been quiet. Understating costs a late stall report; overstating disarms
    /// the detector, which is the failure this exists to avoid.
    ///
    /// `date` is a one-shot stamp of an observation that gets persisted in a
    /// reported fact — data, so the date seam rather than a clock.
    public func record(repoID: UUID, worktreeID: UUID, branchTip: String, at date: Date = Date()) {
        guard let existing = entries[repoID]?[worktreeID], existing.tip == branchTip else {
            entries[repoID, default: [:]][worktreeID] = Entry(tip: branchTip, unchangedSince: nil)
            return
        }
        guard existing.unchangedSince == nil else { return }
        entries[repoID, default: [:]][worktreeID] = Entry(tip: branchTip, unchangedSince: date)
    }

    /// Since when this worktree's commits have not changed, or nil when the
    /// sweep has not yet *established* that — either because it never resolved
    /// the tip, or because it has resolved it exactly once and one sample
    /// measures no duration. Both are "not established", which is what
    /// `SessionCounters.commitsUnchangedSince`'s optionality is for.
    public func unchangedSince(repoID: UUID, worktreeID: UUID) -> Date? {
        entries[repoID]?[worktreeID]?.unchangedSince
    }

    /// Drop this repo's entries for worktrees no longer in its sweep. Other
    /// repos' entries are untouched.
    public func retain(repoID: UUID, worktreeIDs: Set<UUID>) {
        entries[repoID] = entries[repoID]?.filter { worktreeIDs.contains($0.key) }
    }
}
