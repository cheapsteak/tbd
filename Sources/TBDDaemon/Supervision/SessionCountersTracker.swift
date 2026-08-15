import Foundation
import TBDShared

// MARK: - Reading appended records

/// How many JSONL records were appended past a byte offset, and where the file
/// now ends.
struct AppendedRecords: Sendable, Equatable {
    /// Newline-terminated records seen in the appended span. **Nothing is
    /// parsed** — a record is a `\n`, which is the one property of this file
    /// that survives every change to its internal format.
    let records: Int
    /// The file's end offset at the moment of the read, which becomes the next
    /// baseline.
    let endOffset: UInt64
}

/// The seam `SessionCountersTracker` reads transcripts through.
///
/// A protocol rather than a direct `FileHandle` call so the counter arithmetic
/// — window rolls, rollover resets, truncation — is a tier-1 test with no
/// filesystem, and so a fake can *count reads* and prove the tracker never
/// re-reads a file it has already advanced past.
protocol TranscriptAppendReading: Sendable {
    /// The file's current end offset, or nil when it cannot be read at all.
    ///
    /// nil and 0 are different answers and must stay different: 0 is an empty
    /// file, nil is no observation, and collapsing them turns a missing
    /// transcript into a claim of inactivity.
    func endOffset(atPath path: String) -> UInt64?

    /// Records appended between `offset` and the file's end.
    func appendedRecords(atPath path: String, from offset: UInt64) -> AppendedRecords?
}

/// The production reader: seek to the baseline, stream to the end in bounded
/// chunks, count newlines.
///
/// Streaming rather than `readToEnd` is not premature caution. The span is
/// normally one cycle's worth of appends — kilobytes — but the baseline is set
/// to the file's *end* on first sighting, so a multi-megabyte transcript is
/// never read wholesale on any path; bounding the buffer keeps that true even
/// if a cycle is missed for an hour.
struct FileTranscriptAppendReader: TranscriptAppendReading {
    /// Read buffer. Not a limit on how much may be counted — the loop runs to
    /// the end — only on how much is resident at once.
    static let chunkBytes = 64 * 1024

    func endOffset(atPath path: String) -> UInt64? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.seekToEnd()
    }

    func appendedRecords(atPath path: String, from offset: UInt64) -> AppendedRecords? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        guard end > offset else { return AppendedRecords(records: 0, endOffset: end) }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }
        var records = 0
        while true {
            guard let chunk = try? handle.read(upToCount: Self.chunkBytes), !chunk.isEmpty else {
                break
            }
            records += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
        }
        return AppendedRecords(records: records, endOffset: end)
    }
}

// MARK: - The tracker

/// Runaway-detection counters for the fleet (design §13): how much has happened
/// on each session lately.
///
/// **These numbers are reported and never acted on.** There is no threshold in
/// this file and there will not be one. §13 rejects automatic pauses at a
/// threshold outright, and the reason is worth keeping next to the arithmetic:
/// a counter cannot tell "burning quota without progress" from "thinking hard",
/// and pausing a working agent by mistake destroys trust in overnight
/// supervision faster than any missed runaway. What counts as too many turns is
/// a project's convention and lives in its shipped sweep program; this actor
/// hands over the numbers and the sweep program decides whether they mean
/// anything.
///
/// Three inputs, all from interfaces the daemon already reads:
///
/// - **Turns** — records appended to the session's transcript JSONL, counted by
///   newline **without parsing content**. The format is documented as internal
///   and version-unstable; "a record is a line" is the one thing about it that
///   holds across its revisions.
/// - **Hook events** — the hook-driven RPCs (activity, session, notification,
///   ask-user-question) increment a counter as they arrive. One actor hop per
///   event and nothing else.
/// - **Commits unchanged** — supplied by the caller from `BranchTipTracker`,
///   which the git sweep fills from the `for-each-ref` it already runs. No new
///   subprocess.
///
/// ## The window is an observation window, not a threshold
///
/// `observationWindow` bounds *how far back the numbers look*. Crossing it
/// causes nothing: the counts reset and a new window begins. It is compiled
/// because it describes how this actor keeps its books, not what any number
/// means — the thresholds those numbers are compared against ship in the sweep
/// program, where a project can edit them in a file it owns.
///
/// ## Baselines, and the rollover that would otherwise lie
///
/// A session's transcript path moves under it: `/clear` and `/compact` roll the
/// session onto a different file. Comparing the new file's size against the old
/// file's offset would report a wildly wrong delta — a negative one, or a
/// several-thousand-record "burst" that never happened. So a path change (and a
/// file that shrank below its own baseline) **resets the baseline** instead:
/// the offset moves to the new file's end and the turn count restarts at zero
/// within the same window. Zero-since-the-rollover is a true statement about
/// what TBD observed; a bogus delta is not.
actor SessionCountersTracker {
    /// How far back the counts look. See the type's note — an observation
    /// window, never a threshold.
    static let observationWindow: TimeInterval = 30 * 60

    private struct Baseline {
        /// The worktree this terminal belonged to when it was last sampled.
        /// Carried so a worktree-scoped `retain` can tell "this terminal is
        /// gone" from "this terminal was never in the caller's scope" — see
        /// `retain(terminalIDs:inWorktree:)`.
        var worktreeID: UUID
        var transcriptPath: String
        var byteOffset: UInt64
        var turns: Int
        var hookEvents: Int
        var windowStart: Date
    }

    /// terminalID → its baseline. Flat, and deliberately not nested by worktree
    /// the way `ConflictSweepCache` and `BranchTipTracker` are: `recordHookEvent`
    /// runs on every hook RPC the fleet produces and is handed a terminal ID
    /// alone, so a nested map would make the hot path scan every worktree.
    /// The scoping rule those two keep is honoured by the `worktreeID` each
    /// entry carries instead.
    private var baselines: [UUID: Baseline] = [:]
    /// Hook events for terminals with no transcript baseline yet. Kept so an
    /// event that arrives before the first sample is not lost; folded into the
    /// baseline when one is established.
    ///
    /// **Self-bounded, because nothing else bounds it.** Its only pruner is the
    /// fleet-wide `retain`, and every terminal the fleet has ever produced a
    /// hook for lands here on its first event — a session that is never sampled
    /// (no transcript path, a `session.states` call that is always
    /// worktree-scoped, or no caller at all) leaves an entry behind forever, on
    /// a daemon that runs for weeks. So an entry whose window has expired is
    /// dropped rather than restarted at the next write: the count it carries
    /// describes a window that is over, and holding it is holding nothing.
    /// Same defect as the one `b38a899d` fixed on `baselines`, one map over.
    private var pendingHookEvents: [UUID: (count: Int, windowStart: Date)] = [:]
    /// Size at which `recordHookEvent` starts sweeping expired pending entries.
    /// Above the largest fleet anyone runs, so the sweep costs the hot path
    /// nothing in the ordinary case.
    static let pendingHookEventSweepThreshold = 256
    /// Hard ceiling on `pendingHookEvents`. Reached only pathologically — every
    /// entry is normally either folded into a baseline on the terminal's first
    /// sample or expired by its own window — so the eviction below is a
    /// backstop against unbounded growth, not a working cache policy.
    static let maxPendingHookEventTerminals = 4096
    private let windowLength: TimeInterval
    private let reader: any TranscriptAppendReading
    private let pendingSweepThreshold: Int
    private let pendingLimit: Int
    /// The size `pendingHookEvents` must **exceed** before the next sweep, never
    /// below `pendingSweepThreshold` and ratcheted to the post-sweep size after
    /// each one.
    ///
    /// Without it the threshold alone does not amortize anything: a fleet
    /// holding more than `pendingSweepThreshold` *fresh* entries drops nothing
    /// on a sweep, stays over the threshold, and pays a whole-map rebuild on
    /// every hook event thereafter — on the path whose entire budget is "one
    /// actor hop and an integer add". The map only grows when a terminal TBD has
    /// never seen produces its first event, so gating on growth makes the sweep
    /// cost proportional to new terminals rather than to traffic.
    private var pendingSweepWatermark: Int
    /// How many sweeps `expirePendingHookEvents` has actually run.
    ///
    /// The amortization above is invisible in the map's contents — a gated sweep
    /// and an ungated one that drops nothing leave the same state — so it is
    /// counted, and the counter is what a test asserts against.
    private(set) var pendingSweepsPerformed = 0

    /// - Parameters:
    ///   - pendingSweepThreshold: size at which `recordHookEvent` starts
    ///     sweeping; injectable so a test crosses it in a handful of events
    ///     rather than 257 of them.
    ///   - pendingLimit: the hard ceiling, injectable for the same reason.
    init(
        windowLength: TimeInterval = SessionCountersTracker.observationWindow,
        reader: any TranscriptAppendReading = FileTranscriptAppendReader(),
        pendingSweepThreshold: Int = SessionCountersTracker.pendingHookEventSweepThreshold,
        pendingLimit: Int = SessionCountersTracker.maxPendingHookEventTerminals
    ) {
        self.windowLength = windowLength
        self.reader = reader
        self.pendingSweepThreshold = max(0, pendingSweepThreshold)
        self.pendingLimit = max(1, pendingLimit)
        self.pendingSweepWatermark = max(0, pendingSweepThreshold)
    }

    /// Count one hook-driven RPC for a terminal.
    ///
    /// Deliberately trivial: this runs on every activity, session, notification
    /// and ask-user-question event the fleet produces, so it must cost one
    /// actor hop and an integer add. `date` is a one-shot stamp — persisted and
    /// compared, so the date seam, not a clock.
    func recordHookEvent(terminalID: UUID, at date: Date = Date()) {
        if baselines[terminalID] != nil {
            rollWindowIfNeeded(terminalID: terminalID, at: date)
            baselines[terminalID]?.hookEvents += 1
            return
        }
        var pending = pendingHookEvents[terminalID] ?? (count: 0, windowStart: date)
        if date.timeIntervalSince(pending.windowStart) >= windowLength {
            pending = (count: 0, windowStart: date)
        }
        pending.count += 1
        pendingHookEvents[terminalID] = pending
        expirePendingHookEvents(at: date)
    }

    /// Drop pending entries whose observation window has closed, and — if the
    /// map is somehow still over its ceiling — the oldest ones past it.
    ///
    /// Expiry is not an approximation of `retain`: an entry older than one
    /// window would have been reset to zero by the next event anyway, so
    /// dropping it loses no count that would ever have been reported. It is
    /// what makes the map's size a function of recent fleet activity instead of
    /// of how long the daemon has been up.
    ///
    /// Gated on a size **watermark** rather than run on every event, because the
    /// caller is the hot path and owes it one actor hop and an integer add. In
    /// the ordinary steady state the map holds a handful of entries — each one
    /// is folded into a baseline on its terminal's first sample — so the sweep
    /// does not run at all. Past the threshold it runs only when the map has
    /// grown since the last sweep, which happens once per newly-seen terminal
    /// and never on repeat traffic from terminals already in the map. See
    /// `pendingSweepWatermark`.
    private func expirePendingHookEvents(at date: Date) {
        guard pendingHookEvents.count > pendingSweepWatermark else { return }
        pendingSweepsPerformed += 1
        pendingHookEvents = pendingHookEvents.filter {
            date.timeIntervalSince($0.value.windowStart) < windowLength
        }
        if pendingHookEvents.count > pendingLimit {
            let survivors = pendingHookEvents
                .sorted { $0.value.windowStart > $1.value.windowStart }
                .prefix(pendingLimit)
            pendingHookEvents = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        }
        // Ratchet to what survived, never below the threshold: the next sweep
        // waits for the map to grow past this size again.
        pendingSweepWatermark = max(pendingSweepThreshold, pendingHookEvents.count)
    }

    /// Sample one terminal's counters.
    ///
    /// Returns nil when the transcript could not be read — a session with no
    /// readable transcript has no honest `turnsInWindow`, and `SessionCounters`
    /// has nowhere to say "unknown". `SessionStateReport.counters` is optional
    /// for exactly this: reporting the state without the counters is the honest
    /// shape, and reporting a zero would be a claim of inactivity TBD never
    /// observed.
    ///
    /// - Parameters:
    ///   - worktreeID: the terminal's worktree, remembered so a scoped
    ///     `retain` knows which entries are inside its scope. A terminal that
    ///     moves re-homes on its next sample.
    ///   - transcriptPath: the session's transcript JSONL, when TBD knows one.
    ///   - commitsUnchangedSince: from `BranchTipTracker`. Passed through
    ///     verbatim, nil included — nil means "not established", which is a
    ///     different fact from "changed just now".
    ///   - date: the sample instant.
    func sample(
        terminalID: UUID,
        worktreeID: UUID,
        transcriptPath: String?,
        commitsUnchangedSince: Date?,
        at date: Date = Date()
    ) -> SessionCounters? {
        guard let transcriptPath, !transcriptPath.isEmpty else { return nil }

        rollWindowIfNeeded(terminalID: terminalID, at: date)

        guard var baseline = baselines[terminalID],
              baseline.transcriptPath == transcriptPath else {
            // First sighting, or the session rolled onto a different file. The
            // baseline starts at the file's END: nothing before this instant is
            // "in the window", and scanning a multi-megabyte history to find
            // out otherwise is exactly the cost this design refuses.
            guard let end = reader.endOffset(atPath: transcriptPath) else { return nil }
            let pending = pendingHookEvents.removeValue(forKey: terminalID)
            let existing = baselines[terminalID]
            baselines[terminalID] = Baseline(
                worktreeID: worktreeID,
                transcriptPath: transcriptPath,
                byteOffset: end,
                turns: 0,
                hookEvents: existing?.hookEvents ?? pending?.count ?? 0,
                windowStart: existing?.windowStart ?? pending?.windowStart ?? date)
            return counters(baselines[terminalID], commitsUnchangedSince: commitsUnchangedSince, at: date)
        }

        guard let appended = reader.appendedRecords(
            atPath: transcriptPath, from: baseline.byteOffset) else { return nil }
        if appended.endOffset < baseline.byteOffset {
            // The file shrank below its own baseline — replaced, truncated, or
            // rotated in place. Same treatment as a path change: re-baseline
            // rather than report a delta computed against bytes that are gone.
            baseline.byteOffset = appended.endOffset
            baseline.turns = 0
        } else {
            baseline.byteOffset = appended.endOffset
            baseline.turns += appended.records
        }
        // Re-home a terminal that changed worktree, so the next scoped retain
        // reasons about where it lives now rather than where it used to.
        baseline.worktreeID = worktreeID
        baselines[terminalID] = baseline
        return counters(baseline, commitsUnchangedSince: commitsUnchangedSince, at: date)
    }

    /// Drop bookkeeping for terminals that no longer exist, so a long-lived
    /// daemon does not accumulate an entry per terminal ever created.
    ///
    /// **`worktreeID` is the scope the caller's terminal list was filtered by,
    /// and pruning never reaches outside it.** Same rule as `ConflictSweepCache`
    /// and `BranchTipTracker`, for the same reason: `session.states` may be
    /// asked about one worktree, and that call enumerates only that worktree's
    /// terminals. Pruning fleet-wide against such a list would evict every
    /// *other* worktree's baselines — terminals that are alive and busy — so
    /// the next fleet-wide call would re-baseline them as first sightings, with
    /// turns and hook events back at zero and the observation window thrown
    /// away. Silently, on every scoped call, for every session outside the
    /// scope. nil means the caller enumerated the whole fleet, and only that
    /// caller may prune it.
    ///
    /// Hook events counted before a terminal's first sample carry no worktree —
    /// nothing has yet told this actor where that terminal lives — so a scoped
    /// call leaves them alone and the fleet-wide call collects them.
    func retain(terminalIDs: Set<UUID>, inWorktree worktreeID: UUID?) {
        guard let worktreeID else {
            baselines = baselines.filter { terminalIDs.contains($0.key) }
            pendingHookEvents = pendingHookEvents.filter { terminalIDs.contains($0.key) }
            return
        }
        baselines = baselines.filter {
            $0.value.worktreeID != worktreeID || terminalIDs.contains($0.key)
        }
    }

    // MARK: - Internals

    private func rollWindowIfNeeded(terminalID: UUID, at date: Date) {
        guard var baseline = baselines[terminalID] else { return }
        guard date.timeIntervalSince(baseline.windowStart) >= windowLength else { return }
        baseline.windowStart = date
        baseline.turns = 0
        baseline.hookEvents = 0
        // The byte offset deliberately survives the roll: it marks where the
        // file was last read, not where the window began. Resetting it would
        // re-count everything appended since the previous read.
        baselines[terminalID] = baseline
    }

    private func counters(
        _ baseline: Baseline?, commitsUnchangedSince: Date?, at date: Date
    ) -> SessionCounters? {
        guard let baseline else { return nil }
        return SessionCounters(
            turnsInWindow: baseline.turns,
            hookEventsInWindow: baseline.hookEvents,
            windowStart: baseline.windowStart,
            observedAt: date,
            commitsUnchangedSince: commitsUnchangedSince)
    }
}
