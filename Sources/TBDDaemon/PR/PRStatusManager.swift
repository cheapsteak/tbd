import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "PRStatusManager")

/// Why an attempt to learn a worktree's PR state produced no answer.
///
/// Deliberately a small closed vocabulary of *failure classes*, never the
/// underlying tool's message: these strings reach a tooltip, and a forge error
/// routinely names a host, an organization, a repository, or an account. A
/// class says what went wrong without carrying any of that.
enum PRUndeterminedCause {
    /// No forge CLI could be launched at all.
    static let cliUnavailable = "the forge CLI was unavailable"
    /// The CLI ran but the query did not produce an answer for this worktree.
    static let queryFailed = "the forge query failed"
    /// An answer came back in a shape this build could not read.
    static let unparseableResponse = "the forge response did not parse"
    /// Every branch this worktree is known by came back without a pull
    /// request, yet a pull request is already cached for it — so the cached one
    /// lives on a branch the query could not name (a fork head, a rename-push)
    /// and this attempt settles nothing. Not `.none`: the branch list is a
    /// guess at where to look, and its silence is not the forge saying "there
    /// is no pull request here".
    static let branchQueryFoundNothing = "no pull request was found on any branch this worktree is known by"
    /// The pull request resolved, but its check state could not be read, so the
    /// value on hand was kept rather than recomputed from partial data.
    static let checkQueryFailed = "the forge check query failed"
    /// A recorded outcome was on the row but could not be read back — a
    /// truncated or malformed blob. Not the absence of a record: an attempt was
    /// made, and only what it concluded is lost.
    static let unreadableRecord = "the recorded outcome could not be read"
    /// The worktree lives on a forge this path cannot ask. The direct refresh
    /// speaks GitHub's API alone, and a GitLab worktree is refreshed through
    /// its bindings instead — so one with no binding yet has no direct-refresh
    /// route at all. Named rather than folded into `queryFailed` because
    /// nothing failed and retrying changes nothing; the alternative to saying
    /// so is letting a same-named GitHub repository answer in its place.
    static let forgeNotQueryableDirectly = "this worktree's forge cannot be queried directly"
    /// The CLI ran and reached the host, which refused the credentials. Named
    /// separately from `cliUnavailable` because the remedy differs: a token
    /// expired, and only re-authenticating that specific host fixes it. A
    /// personal access token has no refresh, so a host that answered yesterday
    /// starts refusing today — and letting that read as "there is no merge
    /// request here" is the silent degradation this whole vocabulary exists to
    /// prevent.
    ///
    /// The host is the one piece of forge detail this vocabulary does carry,
    /// and deliberately: the remedy is `glab auth login --hostname <host>`, so
    /// a report that withheld the host would name a fix nobody could apply.
    static func forgeAuthFailed(host: String) -> String {
        "the forge rejected the credentials for \(host)"
    }
}

/// In-memory cache of GitHub PR status per worktree.
///
/// `fetchAll` runs one batch GraphQL call for all viewer PRs, plus one combined per-PR
/// GraphQL call (run concurrently) for each OPEN PR whose aggregate rollup isn't SUCCESS —
/// that call returns the aggregate state, every check context with its `isRequired`
/// flag, and a pagination flag in a single round trip. `refresh` runs
/// `gh pr view` plus the same combined call for OPEN PRs. On transient fetch failure,
/// callers keep the previous cached status instead of guessing.
///
/// Two facts, not one. The cached `PRStatus` is the newest *value* anyone holds;
/// the `PRObservation` beside it is the outcome of the last *attempt*. They
/// disagree exactly when it matters: a failed fetch keeps the previous value
/// (it remains the best anyone has) while recording `.undetermined`, so a reader
/// gets a value from before, honestly labeled as not reconfirmed. And a worktree
/// with no cached status is `.none` only when the forge actually answered —
/// never because nobody could ask.
public actor PRStatusManager {

    /// One worktree's poll inputs: its identity, the branch it owns, the branch
    /// it merely tracks (`upstreamBranch`), its repo's default branch, where git
    /// says it would push (`pushBranch`), the directory `git` and `gh` run in
    /// (`worktreePath`), and the PR number it was created from, if any.
    ///
    /// `worktreePath` is a *repo* handle, not a row identifier. Several entries
    /// legitimately share one — every remote lane of a repo resolves to that
    /// repo's own checkout (`RPCRouter.pollWorkingDirectory`) — so nothing here
    /// may use it to tell two entries apart. `id` is the row key; the path only
    /// ever answers "which GitHub repo is this, and where can a subprocess run".
    public typealias PollWorktree = (
        id: UUID,
        branch: String,
        upstreamBranch: String?,
        defaultBranch: String?,
        pushBranch: GitManager.PushBranchResolution,
        worktreePath: String,
        prNumber: Int?
    )

    private var cache: [UUID: PRStatus] = [:]

    /// The outcome of the last attempt per worktree, kept beside `cache` rather
    /// than inside it: an entry can exist here with no cache entry (the forge
    /// answered "no PR"), and a cache entry can survive an attempt recorded
    /// here as `.undetermined`.
    private var observations: [UUID: PRObservation] = [:]

    /// TTL cache for `resolveNameWithOwner` so the periodic poll's by-number and
    /// open-PR queries don't spawn a `gh repo view` subprocess per call. Keyed by
    /// repoPath; ~15-min TTL (a checkout's owner/name effectively never changes).
    /// Actor-isolated, so no locking — mirrors `RPCRouter.branchTrackingCache`.
    ///
    /// The key is a *checkout*, and what it stores is a property of that
    /// checkout's repo — so poll entries that share a path (every remote lane of
    /// one repo) sharing an entry is the cache working, not a collision. Entries
    /// are only ever added and expire on time; nothing prunes by row, so no
    /// worktree can evict another's.
    private var ownerRepoCache: [String: (value: (owner: String, name: String, host: String), expiry: Date)] = [:]

    /// Reentrancy guard: a previous poll still running means a new `fetchAll` is skipped
    /// so two generations of batch data can't interleave their cache writes.
    private var fetchAllInProgress = false

    /// Set by `refresh()`/`invalidate()`; `fetchAll` won't overwrite newer data.
    private var lastDirectUpdate: [UUID: Date] = [:]

    private var onMergedTransition: (@Sendable (UUID, Int) async -> Void)?

    private var onStatusPersist: (@Sendable (UUID, PRStatus?) async -> Void)?

    private var onObservationPersist: (@Sendable (UUID, PRObservation?) async -> Void)?

    /// Worktrees whose cached PR head ref has been *attempted* in this daemon
    /// run (see the head-ref heal in `fetchAll`), whether or not the by-number
    /// lookup resolved.
    ///
    /// Attempted, not resolved: an entry whose number can never resolve (PR
    /// deleted, repo inaccessible, persistent auth or rate-limit failure) is
    /// terminal-state, so it never leaves the unnumbered-with-cache set and
    /// would be re-queried on every poll forever — exactly what
    /// `cachedNumberFallback` excludes terminal states to avoid. The trade: a
    /// transient `gh` outage costs re-verification until the next daemon run.
    /// On a path that polls continuously, that is the right side to err on.
    ///
    /// The bound really is per daemon run: `invalidate` clears the flag, but it
    /// has no production caller today, so nothing shortens the window in a
    /// running daemon.
    private var headRefVerifiedIDs: Set<UUID> = []

    /// Behavior seam for the `gh` subprocess. Production leaves it nil and
    /// shells out; tests inject a runner so `fetchAll`'s heal, apply and
    /// merged-transition paths can be driven end to end without a network or a
    /// `gh` binary. `nil` from a runner means "gh did not launch", matching the
    /// production failure shape.
    typealias GHRunner = @Sendable (_ args: [String], _ repoPath: String) async -> GHCommandResult?

    private let ghRunner: GHRunner?

    /// Behavior seam for the `glab` subprocess, mirroring `ghRunner`. Nil means
    /// "shell out to the real `glab`"; a test injects one so the whole GitLab
    /// path runs with no binary, no credentials and no network.
    private let glRunner: GLRunner?

    /// Hosts known to speak GitLab, stated outright. Tests pass the set
    /// directly so the resolver — and the `glab auth status` subprocess behind
    /// it — stays out of the loop; production leaves it empty and lets
    /// `gitLabHostResolver` answer.
    private let gitLabHosts: Set<String>

    /// Production's answer to "is this host GitLab?", read from what the user
    /// already told `glab`. Nil in the injecting init: a test that hands over
    /// `gitLabHosts` has stated the whole answer, and consulting a resolver
    /// behind its back would spawn `glab auth status` from a unit test.
    private let gitLabHostResolver: GitLabHostResolver?

    /// The last authentication refusal observed per forge host, lowercased.
    ///
    /// Keyed by host rather than by worktree or binding because that is the
    /// scope of both the fault and its remedy: one expired token silences every
    /// project on that instance at once, and one `glab auth login` restores
    /// them all. Cleared the moment a call to that host succeeds.
    private var forgeAuthFailures: [String: String] = [:]

    /// Behavior seam for reading a checkout's `origin` remote URL — the second
    /// identity source, used only when `gh` cannot name the repo, which is
    /// every checkout on a host `gh` does not speak to. Production leaves it
    /// nil and runs `GitManager`; the injecting init defaults it to "no
    /// remote", so a test that stubs `gh` never spawns a `git` subprocess.
    typealias RemoteURLReader = @Sendable (_ repoPath: String) async -> String?

    private let remoteURLReader: RemoteURLReader?

    /// Date seam for the observed-at this actor *stamps* on the facts it
    /// records — `PRStatus.observedAt` and `PRObservation.observedAt`. Both are
    /// persisted and later compared to age a cache, so they are data, and take
    /// the `now:` seam rather than a `Clock` (`Duration` is behavior, `Date` is
    /// data). This actor schedules nothing, so it has no clock at all.
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.ghRunner = nil
        self.remoteURLReader = nil
        self.glRunner = nil
        self.gitLabHosts = []
        // The resolver needs a runner of its own: it is constructed here, before
        // any instance exists to capture, so it gets the static `glab` spawner
        // rather than `runGLResult`.
        self.gitLabHostResolver = GitLabHostResolver(glRunner: { args, repoPath in
            await PRStatusManager.runGlab(args: args, repoPath: repoPath)
        })
        self.now = now
    }

    /// `glRunner` and `gitLabHosts` are defaulted so every existing call site
    /// stays a GitHub-only manager that can never spawn `glab`.
    init(ghRunner: @escaping GHRunner,
         glRunner: GLRunner? = nil,
         gitLabHosts: Set<String> = [],
         remoteURLReader: @escaping RemoteURLReader = { _ in nil },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.ghRunner = ghRunner
        self.glRunner = glRunner
        self.gitLabHosts = Set(gitLabHosts.map { $0.lowercased() })
        self.gitLabHostResolver = nil
        self.remoteURLReader = remoteURLReader
        self.now = now
    }

    // MARK: - Public interface

    public func allStatuses() -> [UUID: PRStatus] { cache }

    /// The outcome of the last attempt per worktree. A missing key means no
    /// attempt is on record — a third thing again from `.none` or
    /// `.undetermined`, and one no caller may fold into either.
    public func allObservations() -> [UUID: PRObservation] { observations }

    public func observation(for worktreeID: UUID) -> PRObservation? { observations[worktreeID] }

    public func invalidate(worktreeID: UUID) async {
        // FIRST, and above every `await` below. This actor's suspensions are
        // reentrancy points: an in-flight `fetchAll` resumes inside one of the
        // persist callbacks, reads `directRefreshLanded == false`, and rewrites
        // both the cache entry and the row — resurrecting exactly what this call
        // is removing. Stamping before anything suspends is what makes the
        // invalidation hold.
        lastDirectUpdate[worktreeID] = now()
        cache.removeValue(forKey: worktreeID)
        await onStatusPersist?(worktreeID, nil)
        // The value is gone, so any outcome recorded for it describes a value
        // that no longer exists. Drop it — in memory **and** on disk, because
        // `hydrateObservations` reads that row back at the next daemon start
        // and an in-memory-only drop would resurrect the very `.observed`
        // pointing at nothing this line exists to remove.
        observations.removeValue(forKey: worktreeID)
        await onObservationPersist?(worktreeID, nil)
        // Whatever PR attaches next is a different attachment and deserves its
        // own head-ref check.
        headRefVerifiedIDs.remove(worktreeID)
    }

    /// Drop the recorded outcome of every worktree not in `active`, bounding
    /// this actor's memory to the fleet that still exists.
    ///
    /// The persisted side of this fact is already scoped that way:
    /// `allPRObservations` reads **unarchived** rows only, so the map a fresh
    /// daemon hydrates holds active worktrees and nothing else. Without this
    /// call the running daemon drifts away from that shape — an entry recorded
    /// while a worktree was active outlives its archival for the life of the
    /// process and rides in every `pr.list` payload — and only `invalidate`,
    /// which has no production caller, ever removed one.
    ///
    /// **The cached statuses are deliberately left alone.** They are the
    /// baseline the merged-PR edge is computed against, and `.merged` is never
    /// persisted (see `apply`), so an in-memory entry is the *only* record that
    /// a worktree's pull request was already seen merged. Dropping it would rest
    /// the whole no-double-fire guarantee on the per-worktree disarm that
    /// archive/revive writes. The map is bounded in practice anyway: an entry
    /// exists only for a worktree that had a pull request, it is persisted and
    /// re-hydrated unarchived-only at every restart, and it is a small value
    /// per worktree. The outcome map has none of those excuses — it grows an
    /// entry per worktree *considered*, PR or no PR.
    ///
    /// Nothing is written through to the DB: the row belongs to a worktree that
    /// may be revived, and clearing it would destroy a fact this call is only
    /// declining to hold in memory. `invalidate` is the caller that means
    /// "forget it everywhere".
    public func retain(active: Set<UUID>) {
        observations = observations.filter { active.contains($0.key) }
    }

    /// Register a callback fired when a worktree's cached PR state transitions
    /// from non-merged (or absent) into `.merged`. Passes `(worktreeID, prNumber)`.
    public func setOnMergedTransition(_ cb: @escaping @Sendable (UUID, Int) async -> Void) {
        self.onMergedTransition = cb
    }

    /// Register a callback fired whenever a worktree's cached PR status actually
    /// changes, so the daemon can persist it to the DB. A nil status means the
    /// entry was cleared (cross-repo cache heal in `fetchAll`) and the DB row
    /// must be cleared too, or `hydrate` would resurrect the stale value at the
    /// next daemon start.
    public func setOnStatusPersist(_ cb: @escaping @Sendable (UUID, PRStatus?) async -> Void) {
        self.onStatusPersist = cb
    }

    /// Register a callback fired whenever an attempt's outcome is recorded, so
    /// the daemon can persist it to `worktree.prObservation`.
    ///
    /// A nil observation means the entry was dropped and the DB row must be
    /// cleared too — exactly as `onStatusPersist`'s nil does. `invalidate` is
    /// the one caller: without the nil case `hydrateObservations` would
    /// resurrect an outcome describing a value that no longer exists, which is
    /// the `.observed`-pointing-at-nothing that invalidation exists to prevent.
    /// "No attempt on record" is still expressed by never having fired.
    public func setOnObservationPersist(_ cb: @escaping @Sendable (UUID, PRObservation?) async -> Void) {
        self.onObservationPersist = cb
    }

    /// Seed the observation map from persisted DB state at startup, so an
    /// `.undetermined` recorded before a restart is not silently downgraded to
    /// "no attempt on record". Writes directly, firing no persist callback.
    public func hydrateObservations(_ observed: [UUID: PRObservation]) {
        for (id, observation) in observed { observations[id] = observation }
    }

    /// Whether a forge CLI could be launched at all — the difference between
    /// "asked and got nothing back" and "there was nobody to ask". An injected
    /// runner counts as available: it is what stands in for the binary.
    private var forgeCLIAvailable: Bool {
        ghRunner != nil || Self.resolvedGHPath != nil
    }

    /// The same question for `glab`. `nonisolated` because the GitLab fetch
    /// paths are, and it reads only immutable state.
    private nonisolated var gitLabCLIAvailable: Bool {
        glRunner != nil || Self.resolvedGlabPath != nil
    }

    /// Whether this host speaks GitLab.
    ///
    /// An injected set is the whole answer when there is one, so a test never
    /// reaches the resolver; production injects nothing and the resolver reads
    /// `glab auth status` (cached, and short-circuited for github.com before
    /// any subprocess).
    private nonisolated func isGitLabHost(_ host: String, repoPath: String) async -> Bool {
        if gitLabHosts.contains(host.lowercased()) { return true }
        guard let gitLabHostResolver else { return false }
        return await gitLabHostResolver.isGitLabHost(host, repoPath: repoPath)
    }

    /// The credential refusal last observed for a host, or nil if its most
    /// recent call succeeded. The report is per host because the fault is:
    /// every project on that instance goes dark together.
    public func lastUndeterminedCause(forHost host: String) -> String? {
        forgeAuthFailures[host.lowercased()]
    }

    /// Record — or, on `failed: false`, retract — a host's credential refusal.
    /// A single successful call is proof the token works again, which is the
    /// only evidence this actor ever accepts for authentication (never status
    /// text; see `GitLabHostResolver`).
    private func setForgeAuthFailure(_ failed: Bool, host: String) {
        let key = host.lowercased()
        if failed {
            forgeAuthFailures[key] = PRUndeterminedCause.forgeAuthFailed(host: host)
        } else {
            forgeAuthFailures.removeValue(forKey: key)
        }
    }

    /// Record one attempt's outcome and persist it — unless a newer attempt is
    /// already on record.
    ///
    /// **An attempt is an attempt whether or not it resolved.** `fetchAll`
    /// stamps its outcomes with `batchStartedAt` and skips any worktree a
    /// *successful* direct refresh touched mid-batch (`directRefreshLanded`),
    /// but only the success path writes `lastDirectUpdate`. Without this guard a
    /// batch that started at T0 would land its `.none` over a `pr.refresh` that
    /// failed at T1 > T0: `observedAt` would move backwards, the "the last check
    /// did not resolve" clause would vanish from the tooltip, and the freshness
    /// label would report an age older than the most recent attempt.
    ///
    /// The value is deliberately left to its own rules — a batch that resolved a
    /// pull request still applies it, because it is the newest value anyone
    /// holds. Only the *outcome* is monotonic, which is exactly the split this
    /// type's two facts are for.
    ///
    /// Equal stamps still write: two attempts on one instant are ordered by
    /// call, not by clock resolution.
    private func record(_ outcome: PRObservation.Outcome, for worktreeID: UUID, at observedAt: Date) async {
        if let existing = observations[worktreeID], existing.observedAt > observedAt {
            logger.debug("skipping an outcome for worktree \(worktreeID, privacy: .public): a newer attempt is already on record")
            return
        }
        let observation = PRObservation(outcome: outcome, observedAt: observedAt)
        observations[worktreeID] = observation
        await onObservationPersist?(worktreeID, observation)
    }

    /// Seed the cache from persisted DB state at startup. Writes directly (not via
    /// `apply`) so it never fires `onMergedTransition` or `onStatusPersist`.
    /// `.merged` is never persisted (see `apply`), so in practice nothing here is
    /// ever `.merged`; the direct write is still required so that a real merge
    /// observed after startup is detected against the correct hydrated baseline.
    public func hydrate(_ statuses: [UUID: PRStatus]) {
        for (id, status) in statuses { cache[id] = status }
    }

    /// Assigns `status` to the cache and fires `onMergedTransition` when the
    /// state moves from non-merged (or absent) to `.merged`. Also fires
    /// `onStatusPersist` whenever a NON-merged status actually changes, so the
    /// new value is written to the DB. All cache writes route through here
    /// (except the startup `hydrate`, which writes the cache directly) so the
    /// transition and persistence are detected uniformly.
    ///
    /// The cache is hydrated from the DB at startup via `hydrate`, so PR icons
    /// survive a restart. Crucially, `.merged` is NEVER persisted (see the gate
    /// below): merged is the terminal state that triggers auto-archive. If it
    /// were persisted and the archive failed/early-returned (momentarily-active
    /// child, effective=false, error) before a daemon crash, `hydrate` would
    /// restore `.merged` and the next poll would see `wasMerged == true` and
    /// never re-fire `onMergedTransition` — permanently losing the auto-archive
    /// (a regression vs #295's in-memory-only cache). By not persisting
    /// `.merged`, a still-active merged worktree is hydrated with its last
    /// non-merged status (or nothing), so the next post-restart poll re-observes
    /// the merge as a non-merged→merged transition and re-fires — preserving the
    /// merge-while-daemon-down recovery guarantee. Re-archive loops are still
    /// prevented because archived worktrees leave the active poll set and revive
    /// disarms the override.
    ///
    /// **The change that triggers a write is a change of *value*, never of
    /// stamp.** `PRStatus` is `Equatable` including `observedAt`, which advances
    /// on every poll, so writing on `previous != status` would write one SQLite
    /// transaction per worktree per cadence forever — on a forty-worktree fleet
    /// whose steady state is zero. `sameValue(as:)` is the comparison for this
    /// job and says why on the type itself.
    ///
    /// The cache still takes the fresh stamp either way, so the freshness a
    /// surface ages by is current in the answer `pr.list` returns. What lags is
    /// only the *persisted* stamp, between a value change and the next one —
    /// and only until the first poll after a restart re-reads the pull request
    /// and refreshes it. `PRObservation` covers that window directly: it is
    /// written on every attempt, it is the fact that says when TBD last looked,
    /// and it hydrates at startup beside this one.
    private func apply(_ status: PRStatus, for worktreeID: UUID) async {
        let previous = cache[worktreeID]
        let wasMerged = (previous?.state == .merged)
        cache[worktreeID] = status
        // Persist every non-terminal change so the PR icon survives restart, but
        // deliberately skip `.merged` (the auto-archive trigger) — see the doc
        // comment above for why persisting it would break #295's recovery.
        if previous?.sameValue(as: status) != true && status.state != .merged {
            await onStatusPersist?(worktreeID, status)
        }
        if !wasMerged && status.state == .merged {
            await onMergedTransition?(worktreeID, status.number)
        }
    }

    /// Clear the cached status of every head-ref-mismatched worktree and persist
    /// the clear (nil), so `hydrate` can't resurrect it after a daemon restart.
    ///
    /// Entries a user-initiated `refresh` (or `invalidate`) touched after this
    /// batch started are skipped, exactly as the apply loop skips them: that
    /// data is fresher than the batch's, and clearing it would delete the result
    /// of a gesture the user just made. Returns the IDs actually cleared.
    ///
    /// No `lastDirectUpdate` write of its own: a cleared worktree is dropped
    /// from `matches` in the same pass, so no later `apply` can touch it.
    @discardableResult
    private func clearHeadRefMismatches(
        _ entries: [(worktreeID: UUID, headRefName: String, url: String, candidates: [String])],
        batchStartedAt: Date,
        source: String
    ) async -> Set<UUID> {
        var cleared: Set<UUID> = []
        for entry in entries {
            if let direct = lastDirectUpdate[entry.worktreeID], direct > batchStartedAt {
                logger.debug("fetchAll: skipping head-ref heal for worktree \(entry.worktreeID, privacy: .public): a direct refresh landed after this batch started")
                continue
            }
            cleared.insert(entry.worktreeID)
            let candidates = entry.candidates.joined(separator: ", ")
            logger.debug("fetchAll: clearing head-ref-mismatched PR status for worktree \(entry.worktreeID, privacy: .public) (\(source, privacy: .public)): PR head is \(entry.headRefName, privacy: .public) but the worktree matches only [\(candidates, privacy: .public)]")
            cache.removeValue(forKey: entry.worktreeID)
            await onStatusPersist?(entry.worktreeID, nil)
        }
        return cleared
    }

    /// What one poll pass discovered and what it disproved.
    ///
    /// Two lists because a poll moves bindings in both directions, and the
    /// caller owns the policy for each. `discovered` is the branch-match
    /// emitter; `disproved` is the heal emitter, without which a heal could
    /// clear the cache while the binding it wrote on an earlier pass survived
    /// and kept driving the icon (and, on a merge, auto-archive).
    public struct PollOutcome: Sendable {
        /// Branch-matched PRs, for `PRBindingCoordinator.bind(…, source: .branch)`.
        public var discovered: [(worktreeID: UUID, parsed: ParsedPRURL)] = []
        /// PRs a heal positively showed do NOT belong to the worktree. The
        /// caller removes the corresponding `branch`-sourced binding; a `hook`
        /// or `manual` binding is direct evidence or an explicit user statement
        /// and is never undone by an inference.
        public var disproved: [(worktreeID: UUID, parsed: ParsedPRURL)] = []
    }

    /// Fetch all viewer PRs in one GraphQL call and update cache for all known worktrees.
    /// worktrees: one `PollWorktree` per active non-main worktree.
    ///
    /// Returns the branch-matched PRs as `ParsedPRURL`s in `discovered` — the
    /// branch-match emitter, for the poll to hand to
    /// `PRBindingCoordinator.bind(…, source: .branch)`. Only matches produced by
    /// `matchUnnumbered` are emitted, and only those that survived the head-ref
    /// heal: a match the heal cleared is one this worktree was positively shown
    /// to be mis-attached to, and binding it would make that mis-attachment
    /// durable in a way the heal cannot reach. A worktree resolved by number was
    /// bound by whatever supplied the number, so it is not a branch discovery
    /// and is never emitted.
    ///
    /// Every heal — both head-ref passes and the cross-repo poisoned-cache heal
    /// — also emits the PR it cleared in `disproved`, because clearing the cache
    /// alone is not enough: a binding written by an earlier pass's branch match
    /// is re-queried by number and neither heal can see it.
    ///
    /// Every worktree this pass *considered* also leaves with a recorded
    /// `PRObservation` — `.observed`, `.none`, or `.undetermined(cause:)` — and
    /// the three are never interchanged. The exception is a worktree a
    /// user-initiated refresh touched mid-batch, whose own attempt is newer than
    /// this one:
    ///
    /// - a refresh that **landed a value** is skipped outright by
    ///   `directRefreshLanded`, so this pass leaves both its value and its
    ///   outcome alone;
    /// - a refresh that **failed** wrote no value to protect, so this pass may
    ///   still apply its own — but `record` is monotonic, so the newer failure's
    ///   outcome and stamp stand.
    @discardableResult
    public func fetchAll(worktrees: [PollWorktree]) async -> PollOutcome {
        var outcome = PollOutcome()
        guard !worktrees.isEmpty else { return outcome }
        guard !fetchAllInProgress else { return outcome }   // a previous poll is still running; skip to avoid interleaved generations
        fetchAllInProgress = true
        defer { fetchAllInProgress = false }
        let batchStartedAt = now()
        // Outcomes accrue here and are recorded in one pass at the end, so the
        // "every considered worktree gets exactly one observation" rule is
        // visible in one place instead of spread across six early exits.
        var outcomes: [UUID: PRObservation.Outcome] = [:]
        // Worktrees may span multiple repos. repoPath is only gh's working
        // directory for the viewer batch (gh auth is host-scoped, so any
        // checkout works); by-number lookups resolve each worktree's own repo.
        // Any entry's path serves, and every entry has a real directory —
        // `RPCRouter.pollWorkingDirectory` is where that is guaranteed.
        let repoPath = worktrees[0].worktreePath

        // Worktrees created from a PR row carry its number; resolve those
        // directly (a fork PR's head never appears in the viewer-authored batch).
        // Everything else uses the viewer-batch branch-name matching, scoped to
        // each worktree's own repo (see `matchUnnumbered`).
        let (numbered, unnumbered) = Self.partitionByPRNumber(worktrees) { $0.prNumber }

        // Do NOT clear entries for missing worktrees — the batch query is
        // limited to 100 PRs across all repos, so older PRs may not appear.
        // Those entries may have been populated by a targeted `refresh` call.
        var matches: [(worktreeID: UUID, node: PRNode)] = []

        // Which of `matches` came from the branch matcher, so the emitter can
        // tell a branch discovery from a by-number resolution. The two sets are
        // disjoint by construction (the fallback only re-queries worktrees the
        // batch left unmatched).
        var branchMatchedIDs: Set<UUID> = []

        // Numbered path: one aliased by-number query (skipped when none stored).
        if !numbered.isEmpty {
            matches += await fetchNumberedMatches(numbered)
        }

        // Legacy path: viewer-authored batch + branch-name matching, scoped to
        // each worktree's own repo (the batch spans every repo the viewer
        // authored PRs in, and the same branch name can exist in several). On a
        // fetch or parse failure it contributes no matches, but the numbered
        // path above has already resolved independently.
        var batchSucceeded = false
        /// Which failure class the viewer batch hit, when it hit one. Retained
        /// rather than collapsed to a Bool so an unnumbered worktree's
        /// `.undetermined` names what actually went wrong.
        var batchFailureCause = PRUndeterminedCause.queryFailed
        /// Which unnumbered worktrees are on a GitLab host, which of those a
        /// project query actually answered for, and — for the ones it matched —
        /// whether their project gates merges on the pipeline. The GitLab side
        /// is judged per project rather than by one fleet-wide batch, so
        /// `batchSucceeded` cannot speak for it.
        var gitLabUnnumberedIDs: Set<UUID> = []
        var gitLabAnsweredIDs: Set<UUID> = []
        var gitLabPipelineGated: [UUID: Bool] = [:]
        var gitLabFailureCause = PRUndeterminedCause.queryFailed
        if !unnumbered.isEmpty {
            // Resolve each unnumbered worktree's own repo once, mirroring the
            // numbered path's `resolved` dictionary. TTL-cached, so the poll
            // doesn't spawn a `gh repo view` subprocess per worktree per tick.
            // The host rides along because it is what decides which forge to ask.
            var unnumberedRepos: [String: (owner: String, name: String)] = [:]
            var unnumberedHosts: [String: String] = [:]
            for path in Set(unnumbered.map(\.worktreePath)) {
                if let ownerRepo = await cachedNameWithOwner(repoPath: path) {
                    unnumberedRepos[path] = (owner: ownerRepo.owner, name: ownerRepo.name)
                    unnumberedHosts[path] = ownerRepo.host
                } else {
                    logger.debug("fetchAll: could not resolve owner/name for unnumbered worktree at \(path, privacy: .public)")
                }
            }

            // Heal entries poisoned by the pre-repo-scoping branch match: a
            // cached status whose PR URL belongs to a different repo than the
            // worktree's own. This MUST run before `cachedNumberFallback` is
            // computed below: a poisoned entry carries the OTHER repo's PR
            // number, and the fallback would re-resolve that number scoped to
            // the worktree's own repo, where it can land on an unrelated PR
            // (worst case a MERGED one, firing auto-archive on the wrong
            // worktree). Clearing the cache first makes that path unreachable.
            // The clear is persisted (nil status) so `hydrate` can't resurrect
            // it after a daemon restart. No `lastDirectUpdate` write: this runs
            // inside fetchAll itself, and the worktree stays unmatched by
            // construction, so no later apply() in this pass can touch it.
            let poisoned = Self.poisonedCacheEntries(
                unnumbered: unnumbered,
                resolveRepo: { unnumberedRepos[$0] },
                cachedStatus: { cache[$0] })
            for entry in poisoned {
                logger.debug("fetchAll: clearing cross-repo PR status for worktree \(entry.worktreeID, privacy: .public): cached PR is in \(entry.cachedRepo, privacy: .public) but worktree repo is \(entry.worktreeRepo, privacy: .public)")
                cache.removeValue(forKey: entry.worktreeID)
                await onStatusPersist?(entry.worktreeID, nil)
            }
            // The binding table is not reached by the cache clear above: a
            // binding is re-queried by (host, owner, repo, number) and never
            // re-validated against the worktree's repo, so a remote that was
            // later re-pointed leaves a live cross-repo binding behind.
            outcome.disproved += Self.bindablePRURLs(
                poisoned.map { (worktreeID: $0.worktreeID, url: $0.cachedURL) },
                context: "cross-repo heal")

            // Split the by-branch path by forge. A worktree whose repo would
            // not name itself has no host either, so it stays on the GitHub
            // side — the pre-GitLab behavior, where it simply matches nothing.
            var gitLabPaths: Set<String> = []
            for (path, host) in unnumberedHosts where await isGitLabHost(host, repoPath: path) {
                gitLabPaths.insert(path)
            }
            let gitLabUnnumbered = unnumbered.filter { gitLabPaths.contains($0.worktreePath) }
            let gitHubUnnumbered = unnumbered.filter { !gitLabPaths.contains($0.worktreePath) }
            gitLabUnnumberedIDs = Set(gitLabUnnumbered.map(\.id))

            // The viewer batch is GitHub's only branch-matching route, and it is
            // skipped outright when no worktree is on GitHub — a GitLab-only
            // fleet never spawns `gh`.
            if !gitHubUnnumbered.isEmpty {
                if let jsonData = await runGHGraphQL(repoPath: repoPath) {
                    if let nodes = try? Self.parsePRNodes(from: jsonData) {
                        batchSucceeded = true   // empty nodes is still a valid answer (viewer has no PRs)
                        let branchMatches = Self.matchUnnumbered(gitHubUnnumbered, nodes: nodes,
                                                                 resolveRepo: { unnumberedRepos[$0] })
                        branchMatchedIDs.formUnion(branchMatches.map(\.worktreeID))
                        matches += branchMatches
                    } else {
                        logger.warning("Failed to parse GraphQL response")
                        batchFailureCause = PRUndeterminedCause.unparseableResponse
                    }
                } else {
                    batchFailureCause = forgeCLIAvailable
                        ? PRUndeterminedCause.queryFailed
                        : PRUndeterminedCause.cliUnavailable
                }
            }

            // GitLab asks the server for the branches instead, one query per
            // project — author-blind, so a merge request opened through the web
            // UI or by a teammate is found, which the viewer batch can never do.
            if !gitLabUnnumbered.isEmpty {
                let gitLab = await fetchGitLabBranchMatches(
                    gitLabUnnumbered, repos: unnumberedRepos, hosts: unnumberedHosts)
                branchMatchedIDs.formUnion(gitLab.matches.map(\.worktreeID))
                matches += gitLab.matches
                gitLabAnsweredIDs = gitLab.answeredIDs
                gitLabPipelineGated = gitLab.pipelineGated
                gitLabFailureCause = gitLab.failureCause
            }
        }

        // Fallback: unnumbered worktrees a *successful* batch left unmatched
        // whose cached status still carries a PR number — resolve those by
        // number (one extra aliased round trip, only when such worktrees
        // exist). See `cachedNumberFallback` for the gating rationale.
        //
        // GitHub worktrees only: both this fallback and the head-ref
        // verification below resolve their numbers through the `gh` by-number
        // query, which would offer a GitLab project path to GitHub. A GitLab
        // worktree therefore keeps its cached status when the branch query
        // leaves it unmatched, which is the conservative direction.
        let gitHubUnnumberedEntries = unnumbered.filter { !gitLabUnnumberedIDs.contains($0.id) }
        let fallback = Self.cachedNumberFallback(
            unnumbered: gitHubUnnumberedEntries,
            matchedIDs: Set(matches.map(\.worktreeID)),
            batchSucceeded: batchSucceeded,
            cachedStatus: { cache[$0] })
        if !fallback.isEmpty {
            matches += await fetchNumberedMatches(fallback)
        }

        // Head-ref heal, pass 1: drop (and clear) any unnumbered match this
        // worktree can be positively shown to be mis-attached to — the PR's head
        // is a branch the worktree merely TRACKS (its base, or a stacked
        // branch's parent), not one it owns. `headRefMismatchedMatches` states
        // the full evidence rule, including why a failed `@{push}` lookup can
        // never produce a clear. Dropping the match here — before the apply loop
        // — is what keeps a mis-attached MERGED PR from firing
        // `onMergedTransition` (auto-archive/auto-hibernate) on the wrong
        // worktree. The clear is persisted (nil) so `hydrate` can't resurrect
        // it after a restart.
        let mismatched = Self.headRefMismatchedMatches(matches, unnumbered: unnumbered)
        if !mismatched.isEmpty {
            let healedIDs = await clearHeadRefMismatches(
                mismatched, batchStartedAt: batchStartedAt, source: "resolved match")
            outcome.disproved += Self.bindablePRURLs(
                mismatched.filter { healedIDs.contains($0.worktreeID) }
                    .map { (worktreeID: $0.worktreeID, url: $0.url) },
                context: "head-ref heal")
            matches.removeAll { healedIDs.contains($0.worktreeID) }
        }

        // Head-ref heal, pass 2: the entries pass 1 can never see. A cached
        // status in a terminal state (`.closed`) is deliberately never
        // re-queried by `cachedNumberFallback`, so a worktree mis-attached to a
        // closed PR has no freshly-resolved node to judge and would display it
        // forever. Resolve those cached numbers once per daemon run purely to
        // read `headRefName`; the resolved nodes are never applied, so a
        // terminal cached status still isn't refreshed by the poll (and no
        // merged transition can fire from this path).
        // Worktrees the fallback already tried to resolve by number this pass
        // count as covered even if that resolution failed — re-querying the same
        // numbers a second time in the same tick would buy nothing. They are
        // retried on the next poll like any other unresolved entry.
        let verificationTargets = Self.headRefVerificationTargets(
            unnumbered: gitHubUnnumberedEntries,
            matchedIDs: Set(matches.map(\.worktreeID)).union(fallback.map(\.id)),
            batchSucceeded: batchSucceeded,
            verifiedIDs: headRefVerifiedIDs,
            cachedStatus: { cache[$0] })
        if !verificationTargets.isEmpty {
            // Mark every ATTEMPTED target, not just the ones that resolved: a
            // number that can never resolve would otherwise be re-queried on
            // every poll for the life of the daemon (see `headRefVerifiedIDs`).
            headRefVerifiedIDs.formUnion(verificationTargets.map(\.id))
            let resolved = await fetchNumberedMatches(verificationTargets)
            let verificationMismatches = Self.headRefMismatchedMatches(resolved, unnumbered: unnumbered)
            let healedIDs = await clearHeadRefMismatches(
                verificationMismatches,
                batchStartedAt: batchStartedAt, source: "cached PR verification")
            outcome.disproved += Self.bindablePRURLs(
                verificationMismatches.filter { healedIDs.contains($0.worktreeID) }
                    .map { (worktreeID: $0.worktreeID, url: $0.url) },
                context: "head-ref heal")
        }

        // Fetch per-PR signals concurrently; only non-green OPEN PRs need the query.
        let signalsByID = await withTaskGroup(of: (UUID, (failing: Bool, pending: Bool)?).self,
                                              returning: [UUID: (failing: Bool, pending: Bool)?].self) { group in
            for match in matches {
                let node = match.node
                let id = match.worktreeID
                // A GitLab node carried its pipeline status in the same batch,
                // so it never pays for GitHub's per-request check query.
                if node.forge != .github || node.state != "OPEN"
                    || !Self.aggregateRollupIsNonSuccess(node.statusCheckRollupState) {
                    group.addTask { (id, (failing: false, pending: false)) }
                } else {
                    group.addTask {
                        (id, await self.fetchCheckSignals(url: node.url, number: node.number, repoPath: repoPath))
                    }
                }
            }
            var out: [UUID: (failing: Bool, pending: Bool)?] = [:]
            for await (id, signals) in group { out[id] = signals }
            return out
        }

        for match in matches {
            // A user-initiated refresh (or invalidate) landed after this batch's snapshot —
            // its data is fresher than ours; don't clobber it.
            if directRefreshLanded(match.worktreeID, after: batchStartedAt) { continue }
            let signals: (failing: Bool, pending: Bool)
            if let fetched = signalsByID[match.worktreeID] ?? nil {
                signals = fetched
            } else if cache[match.worktreeID] != nil {
                // Transient failure: keep the previous status rather than
                // guessing — and say so. The value stands because it is still
                // the newest anyone has; the outcome records that this attempt
                // did not reconfirm it. Both halves, together, are the point.
                outcomes[match.worktreeID] = .undetermined(cause: PRUndeterminedCause.checkQueryFailed)
                continue
            } else {
                signals = Self.aggregateFallbackSignals(match.node.statusCheckRollupState)
            }
            let (state, reason) = Self.mapStateAndReason(
                forge: match.node.forge,
                ghState: match.node.state,
                mergeVerdictRaw: match.node.mergeVerdictRaw,
                reviewVerdictRaw: match.node.reviewVerdictRaw,
                isDraft: match.node.isDraft,
                requiredChecksFailing: signals.failing,
                requiredChecksPending: signals.pending,
                pipelineGated: gitLabPipelineGated[match.worktreeID] ?? false,
                pipelineStatus: match.node.statusCheckRollupState
            )
            let status = PRStatus(number: match.node.number, url: match.node.url, state: state, reason: reason,
                                  mergeQueuePosition: match.node.mergeQueuePosition,
                                  observedAt: batchStartedAt)
            await apply(status, for: match.worktreeID)
            outcomes[match.worktreeID] = .observed
        }

        // Everything this pass considered but did not resolve. The split is the
        // whole point of `PRObservation`, so it is stated rather than implied:
        //
        // - A NUMBERED worktree that did not resolve is always `.undetermined`.
        //   It carries a PR number, so "this branch has no PR" is a conclusion
        //   the evidence cannot support — only the lookup failing can explain it.
        // - An UNNUMBERED worktree is `.none` only when the viewer batch
        //   actually parsed. `batchSucceeded` is exactly the "the forge
        //   answered" predicate the fallback and the head-ref heals already
        //   gate on: with a failed batch, "unmatched" means nothing at all.
        //
        // Worktrees cleared by a head-ref heal land here unmatched and, on a
        // succeeded batch, correctly read `.none`: the heal's evidence is that
        // the PR belonged to a branch this worktree merely tracks, so this
        // worktree has none of its own.
        for wt in numbered where outcomes[wt.id] == nil && !directRefreshLanded(wt.id, after: batchStartedAt) {
            outcomes[wt.id] = .undetermined(cause: PRUndeterminedCause.queryFailed)
        }
        for wt in unnumbered where outcomes[wt.id] == nil && !directRefreshLanded(wt.id, after: batchStartedAt) {
            if gitLabUnnumberedIDs.contains(wt.id) {
                // Judged by the project query that covered THIS worktree, never
                // by the viewer batch — which was not asked about it, and on a
                // GitLab-only fleet was not run at all.
                outcomes[wt.id] = gitLabAnsweredIDs.contains(wt.id)
                    ? PRObservation.Outcome.none
                    : .undetermined(cause: gitLabFailureCause)
            } else {
                outcomes[wt.id] = batchSucceeded ? PRObservation.Outcome.none
                                                 : .undetermined(cause: batchFailureCause)
            }
        }
        for (id, observedOutcome) in outcomes {
            await record(observedOutcome, for: id, at: batchStartedAt)
        }

        // The branch-match emitter. Derived from the post-heal `matches`, so a
        // cleared mis-attachment is absent here too. Deliberately NOT filtered
        // by `lastDirectUpdate`: that guard protects the *cache* from stale
        // batch data, while a binding records that a PR belongs to a worktree —
        // a fact a fresher status for the same worktree does not contradict.
        outcome.discovered = Self.branchMatchedPRURLs(
            matches.filter { branchMatchedIDs.contains($0.worktreeID) })
        return outcome
    }

    /// Whether a user-initiated refresh (or an invalidate) touched this
    /// worktree after `batchStartedAt`. Such an entry has a newer attempt of its
    /// own, so this pass overwrites neither its value nor its outcome.
    private func directRefreshLanded(_ worktreeID: UUID, after batchStartedAt: Date) -> Bool {
        guard let direct = lastDirectUpdate[worktreeID] else { return false }
        return direct > batchStartedAt
    }

    /// Render matched PR nodes as `ParsedPRURL`s for `PRBindingCoordinator`.
    static func branchMatchedPRURLs(
        _ matches: [(worktreeID: UUID, node: PRNode)]
    ) -> [(worktreeID: UUID, parsed: ParsedPRURL)] {
        bindablePRURLs(matches.map { (worktreeID: $0.worktreeID, url: $0.node.url) },
                       context: "branch match")
    }

    /// Render `(worktree, PR URL)` pairs as `ParsedPRURL`s for
    /// `PRBindingCoordinator`, in both directions — a discovery to bind and a
    /// heal to unbind.
    ///
    /// Parsing goes through `PRBindingExtractor.parsePRURLs` rather than a local
    /// split so the poll obeys exactly the host lock and path-segment rules the
    /// hook and manual-attach paths do; a URL that fails them yields no binding
    /// rather than a half-parsed one — and, on the heal side, no removal, which
    /// is the conservative direction (a URL the extractor rejects can never have
    /// produced a binding either).
    static func bindablePRURLs(
        _ entries: [(worktreeID: UUID, url: String)],
        context: String
    ) -> [(worktreeID: UUID, parsed: ParsedPRURL)] {
        entries.compactMap { entry in
            guard let parsed = PRBindingExtractor.parsePRURLs(in: entry.url).first else {
                logger.debug("fetchAll: \(context, privacy: .public) PR URL \(entry.url, privacy: .public) is not a bindable GitHub PR URL")
                return nil
            }
            return (entry.worktreeID, parsed)
        }
    }

    // MARK: - Per-binding refresh

    /// One binding's freshly observed facts.
    ///
    /// `headBranch` / `baseRef` are nil exactly when this pass did NOT resolve
    /// the PR — the transient-failure paths that carry the binding's previous
    /// status forward. A nil there means "not observed", never "the PR has no
    /// base branch", so the caller keeps whatever it already had rather than
    /// clearing a column a `gh` outage hid.
    public struct PRBindingObservation: Sendable, Equatable {
        public let status: PRStatus
        public let headBranch: String?
        public let baseRef: String?

        public init(status: PRStatus, headBranch: String? = nil, baseRef: String? = nil) {
            self.status = status
            self.headBranch = headBranch
            self.baseRef = baseRef
        }
    }

    /// Refresh the status of a set of PR bindings, keyed by **binding id**.
    ///
    /// The binding-keyed sibling of `fetchAll`'s worktree-keyed path, and
    /// deliberately not a replacement for it: one worktree may own several PRs,
    /// so its answer cannot be a `[worktreeID: PRStatus]`. Bindings already
    /// carry their own `owner`/`repo`, so this needs neither the viewer batch
    /// nor `gh repo view` — one aliased `pullRequest(number:)` query per
    /// (host, owner, repo) group, through the same `numberedPRQuery` /
    /// `parseNumberedPRNodes` / `mapStateAndReason` / `fetchCheckSignals` path
    /// the by-number poll uses.
    ///
    /// `nonisolated` on purpose: this path must not touch `cache`,
    /// `lastDirectUpdate`, `headRefVerifiedIDs`, `onStatusPersist` or
    /// `onMergedTransition`. Persisting a binding's status — and deciding what a
    /// merge means across several of them — belongs to the caller.
    ///
    /// A transient failure at any stage (gh did not launch, no data, the number
    /// did not resolve, the check query failed) yields the binding's PREVIOUS
    /// status rather than a guess, exactly as `fetchAll` keeps its cached value.
    /// A binding with no previous status and no fresh data is simply absent from
    /// the result, so a caller writing the map back cannot clear a row it failed
    /// to observe.
    ///
    /// `repoPath` is only `gh`'s working directory; owner and name are bound as
    /// GraphQL variables and `gh` auth is host-scoped, so any checkout — or the
    /// daemon's own cwd — answers identically.
    public nonisolated func refreshBindings(
        _ bindings: [PRBinding],
        repoPath: String? = nil
    ) async -> [UUID: PRBindingObservation] {
        guard !bindings.isEmpty else { return [:] }
        let cwd = repoPath ?? FileManager.default.currentDirectoryPath
        var result: [UUID: PRBindingObservation] = [:]
        for group in Self.groupBindingsByRepo(bindings) {
            result.merge(await refreshBindingGroup(group, repoPath: cwd)) { _, fresh in fresh }
        }
        return result
    }

    /// Group bindings by their own `(host, owner, repo)` so each group needs one
    /// aliased query. Owner and repo are compared lowercased (GitHub treats them
    /// case-insensitively) and the group carries the lowercased pair, matching
    /// what `PRBindingStore` persists. Group order follows first appearance so
    /// the query sequence is deterministic.
    static func groupBindingsByRepo(
        _ bindings: [PRBinding]
    ) -> [(host: String, owner: String, name: String, bindings: [PRBinding])] {
        var order: [String] = []
        var groups: [String: (host: String, owner: String, name: String, bindings: [PRBinding])] = [:]
        for binding in bindings {
            let host = binding.host.lowercased()
            let owner = binding.owner.lowercased()
            let name = binding.repo.lowercased()
            let key = "\(host)\u{1}\(owner)\u{1}\(name)"
            if groups[key] == nil {
                groups[key] = (host, owner, name, [])
                order.append(key)
            }
            groups[key]?.bindings.append(binding)
        }
        return order.compactMap { groups[$0] }
    }

    /// One repo group's aliased round trip plus its per-PR check queries.
    ///
    /// The alias table reuses `parseNumberedPRNodes`, whose tuple slot is named
    /// `worktreeID`; here it carries a BINDING id. That is the whole point of
    /// this path — several bindings of one worktree must stay distinguishable.
    ///
    /// `group.host` chooses the forge. `groupBindingsByRepo` already keys on it,
    /// so a group is one repo on one host and the whole group takes one path:
    /// a GitLab host goes to `refreshGitLabBindingGroup`, everything else stays
    /// on `gh`, whose auth is host-scoped and therefore needs no host argument.
    private nonisolated func refreshBindingGroup(
        _ group: (host: String, owner: String, name: String, bindings: [PRBinding]),
        repoPath: String
    ) async -> [UUID: PRBindingObservation] {
        if await isGitLabHost(group.host, repoPath: repoPath) {
            return await refreshGitLabBindingGroup(group, repoPath: repoPath)
        }
        let aliased = group.bindings.enumerated().map {
            (alias: "pr\($0.offset)", bindingID: $0.element.id, number: $0.element.number)
        }
        let query = Self.numberedPRQuery(aliases: aliased.map { ($0.alias, $0.number) })
        let args = [
            "api", "graphql",
            "-f", "query=\(query)",
            "-f", "owner=\(group.owner)",
            "-f", "name=\(group.name)"
        ]
        guard let result = await runGHResult(args: args, repoPath: repoPath),
              let data = Self.graphQLOutputData(stdout: result.stdout) else {
            logger.debug("refreshBindings: by-number query produced no data for \(group.owner, privacy: .public)/\(group.name, privacy: .public); keeping previous statuses")
            return Self.previousStatuses(group.bindings)
        }
        // `gh api graphql` exits non-zero when ONE aliased PR errors while still
        // emitting usable `data` for the others — parse whatever came back
        // (same tolerance as `fetchNumberedMatches`, regression guard PR #208).
        if result.exitStatus != 0 {
            let errSuffix = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.debug("refreshBindings: by-number query exited \(result.exitStatus, privacy: .public) with partial data for \(group.owner, privacy: .public)/\(group.name, privacy: .public): \(errSuffix, privacy: .public)")
        }
        let nodesByBindingID = Dictionary(
            Self.parseNumberedPRNodes(from: data, aliases: aliased.map { ($0.alias, $0.bindingID) })
                .map { ($0.worktreeID, $0.node) },
            uniquingKeysWith: { first, _ in first })

        // Only non-green OPEN PRs need the per-check query; run those together.
        let signalsByBindingID = await withTaskGroup(of: (UUID, (failing: Bool, pending: Bool)?).self,
                                                     returning: [UUID: (failing: Bool, pending: Bool)?].self) { taskGroup in
            for (bindingID, node) in nodesByBindingID {
                if node.state != "OPEN" || !Self.aggregateRollupIsNonSuccess(node.statusCheckRollupState) {
                    taskGroup.addTask { (bindingID, (failing: false, pending: false)) }
                } else {
                    taskGroup.addTask {
                        (bindingID, await self.fetchCheckSignals(url: node.url, number: node.number,
                                                                 repoPath: repoPath))
                    }
                }
            }
            var out: [UUID: (failing: Bool, pending: Bool)?] = [:]
            for await (bindingID, signals) in taskGroup { out[bindingID] = signals }
            return out
        }

        var observations: [UUID: PRBindingObservation] = [:]
        for binding in group.bindings {
            guard let node = nodesByBindingID[binding.id] else {
                // Deleted, inaccessible, or a sibling alias's error swallowed it.
                logger.debug("refreshBindings: PR #\(binding.number, privacy: .public) did not resolve by number; keeping previous status")
                observations[binding.id] = binding.status.map { PRBindingObservation(status: $0) }
                continue
            }
            let signals: (failing: Bool, pending: Bool)
            if let fetched = signalsByBindingID[binding.id] ?? nil {
                signals = fetched
            } else if let previous = binding.status {
                // Transient failure: keep the previous status rather than
                // guessing. The refs still resolved, so report them — they are
                // descriptive and independent of the check query that failed.
                observations[binding.id] = PRBindingObservation(
                    status: previous, headBranch: Self.refOrNil(node.headRefName),
                    baseRef: Self.refOrNil(node.baseRefName))
                continue
            } else {
                signals = Self.aggregateFallbackSignals(node.statusCheckRollupState)
            }
            let (state, reason) = Self.mapStateAndReason(
                ghState: node.state,
                mergeVerdictRaw: node.mergeVerdictRaw,
                reviewVerdictRaw: node.reviewVerdictRaw,
                isDraft: node.isDraft,
                requiredChecksFailing: signals.failing,
                requiredChecksPending: signals.pending
            )
            observations[binding.id] = PRBindingObservation(
                // Stamped, like every other freshly observed status: a binding's
                // status reaches the sidebar dot and the toolbar help through
                // `worktree.prStatus`, and a value with no `observedAt` renders
                // as "last checked at an unknown time" there. The failure paths
                // above deliberately do NOT re-stamp — they carry a previous
                // value forward, and its stamp says when it was actually read.
                status: PRStatus(number: node.number, url: node.url, state: state,
                                 reason: reason, mergeQueuePosition: node.mergeQueuePosition,
                                 observedAt: now()),
                headBranch: Self.refOrNil(node.headRefName),
                baseRef: Self.refOrNil(node.baseRefName))
        }
        return observations
    }

    /// One GitLab project group: one batched `mergeRequests(iids:)` read, then a
    /// fire-and-forget mergeability recheck.
    ///
    /// Structurally the twin of the `gh` arm above, with one shape difference
    /// that is the point of the GitLab transport: the pipeline status rides in
    /// the same response, so there is no per-request check query and no second
    /// round trip to fail separately.
    private nonisolated func refreshGitLabBindingGroup(
        _ group: (host: String, owner: String, name: String, bindings: [PRBinding]),
        repoPath: String
    ) async -> [UUID: PRBindingObservation] {
        let projectPath = "\(group.owner)/\(group.name)"
        let iids = group.bindings.map(\.number)
        let fetched = await fetchGitLabNodes(
            query: GitLabQueries.mergeRequestsByIIDQuery(iids: iids),
            host: group.host, projectPath: projectPath, repoPath: repoPath)
        guard case .success(let nodes, let pipelineGated) = fetched else {
            if case .failure(let cause) = fetched {
                logger.debug("refreshBindings: GitLab query for \(projectPath, privacy: .public) settled nothing (\(cause, privacy: .public)); keeping previous statuses")
            }
            // Including the authentication path: an expired token proves
            // nothing about the merge requests, so every binding keeps the
            // value it had rather than being cleared.
            return Self.previousStatuses(group.bindings)
        }

        // GitLab computes mergeability asynchronously and never recomputes on
        // read, so a merge request can report UNCHECKED indefinitely. This asks
        // it to recompute; the answer is deliberately dropped, and its failure
        // cannot disturb the poll — the value it produces is read by the NEXT
        // tick's GraphQL call, not by this one.
        //
        // Detached, and that is load-bearing rather than tidy. `runCLI` imposes
        // no timeout, `refreshBindings` walks its groups one at a time, and
        // `fetchAll` skips the next poll while one is still in flight — so a
        // `glab` that hangs here stalls PR polling for the entire fleet, with no
        // deadline to end it. Hanging is the plausible failure for this call in
        // particular: it exists to queue work on someone else's server. Nothing
        // in this pass reads the result, so nothing in this pass may wait for
        // it.
        //
        // Only non-terminal merge requests are asked. A merged or closed one has
        // a mergeability nobody will recompute and nobody will read, so
        // including it spends a server-side job to learn nothing.
        let recheckIIDs = nodes.filter { !Self.isTerminalGitLabState($0.state) }.map(\.number)
        if !recheckIIDs.isEmpty {
            let host = group.host
            let recheckPath = GitLabQueries.recheckPath(projectPath: projectPath, iids: recheckIIDs)
            Task.detached { [self] in
                _ = await runGLResult(args: ["api", "--hostname", host, recheckPath],
                                      repoPath: repoPath)
            }
        }

        let byIID = Dictionary(nodes.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var observations: [UUID: PRBindingObservation] = [:]
        for binding in group.bindings {
            guard let node = byIID[binding.number] else {
                logger.debug("refreshBindings: merge request !\(binding.number, privacy: .public) did not resolve by iid; keeping previous status")
                observations[binding.id] = binding.status.map { PRBindingObservation(status: $0) }
                continue
            }
            let (state, reason) = Self.mapStateAndReason(
                forge: .gitlab,
                ghState: node.state,
                mergeVerdictRaw: node.mergeVerdictRaw,
                isDraft: node.isDraft,
                pipelineGated: pipelineGated,
                pipelineStatus: node.statusCheckRollupState)
            observations[binding.id] = PRBindingObservation(
                status: PRStatus(number: node.number, url: node.url, state: state,
                                 reason: reason, mergeQueuePosition: node.mergeQueuePosition,
                                 observedAt: now()),
                headBranch: Self.refOrNil(node.headRefName),
                baseRef: Self.refOrNil(node.baseRefName))
        }
        return observations
    }

    /// Whether a merge request's state is settled for good.
    ///
    /// Compared case-insensitively because the two GitLab transports disagree:
    /// GraphQL answers `merged`/`closed` in lower case and REST in upper, and
    /// `PRNode.state` carries whichever the response used.
    static func isTerminalGitLabState(_ state: String) -> Bool {
        let normalized = state.lowercased()
        return normalized == "merged" || normalized == "closed"
    }

    /// What one GitLab GraphQL read settled.
    private enum GitLabFetchOutcome {
        case success(nodes: [PRNode], pipelineGated: Bool)
        /// A failure class from `PRUndeterminedCause`.
        case failure(cause: String)
    }

    /// Run one GitLab GraphQL query and classify what came back.
    ///
    /// `--hostname` is on every invocation and must stay there: outside a GitLab
    /// checkout `glab api` silently defaults to gitlab.com, so a missing flag
    /// does not fail — it confidently answers about the wrong instance.
    /// `fullPath` is bound as a variable because it is user data; iids and
    /// branches are quoted into the query by `GitLabQueries`.
    private nonisolated func fetchGitLabNodes(
        query: String, host: String, projectPath: String, repoPath: String
    ) async -> GitLabFetchOutcome {
        let args = ["api", "graphql", "--hostname", host,
                    "-f", "query=\(query)", "-f", "fullPath=\(projectPath)"]
        guard let result = await runGLResult(args: args, repoPath: repoPath) else {
            return .failure(cause: gitLabCLIAvailable
                ? PRUndeterminedCause.queryFailed
                : PRUndeterminedCause.cliUnavailable)
        }
        if Self.isForgeAuthFailure(result) {
            await setForgeAuthFailure(true, host: host)
            logger.debug("GitLab host \(host, privacy: .public) refused the credentials")
            return .failure(cause: PRUndeterminedCause.forgeAuthFailed(host: host))
        }
        guard let data = Self.graphQLOutputData(stdout: result.stdout) else {
            let errSuffix = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.debug("GitLab query for \(projectPath, privacy: .public) produced no output (exit \(result.exitStatus, privacy: .public)): \(errSuffix, privacy: .public)")
            return .failure(cause: PRUndeterminedCause.queryFailed)
        }
        // The call reached the host and the host answered, which is the only
        // evidence this actor accepts that the credentials work.
        await setForgeAuthFailure(false, host: host)
        switch GitLabQueries.parseMergeRequests(from: data) {
        case .answered(let nodes, let pipelineGated):
            return .success(nodes: nodes, pipelineGated: pipelineGated)
        case .unreadable:
            // The same outcome the `gh` arm reaches when `parsePRNodes` throws.
            // A response nobody could read settles nothing, so the worktrees it
            // covers record undetermined rather than "no merge request".
            logger.warning("GitLab query for \(projectPath, privacy: .public) returned a response this build could not read")
            return .failure(cause: PRUndeterminedCause.unparseableResponse)
        }
    }

    /// Whether a forge invocation was refused for want of valid credentials.
    ///
    /// Two shapes, because `glab` reports the same fault two ways: a transport
    /// refusal exits non-zero with the status line on stderr, while a request
    /// that reached GraphQL comes back exit-zero with an error object. Both are
    /// an expired token, and neither may read as "this project has no merge
    /// requests".
    static func isForgeAuthFailure(_ result: GHCommandResult) -> Bool {
        let stderr = result.stderr.lowercased()
        if result.exitStatus != 0 && (stderr.contains("401") || stderr.contains("unauthorized")) {
            return true
        }
        return graphQLReportsUnauthenticated(result.stdout)
    }

    private static func graphQLReportsUnauthenticated(_ stdout: String) -> Bool {
        guard let data = graphQLOutputData(stdout: stdout),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = root["errors"] as? [[String: Any]] else { return false }
        return errors.contains { error in
            let code = ((error["extensions"] as? [String: Any])?["code"] as? String)?.lowercased() ?? ""
            let message = (error["message"] as? String)?.lowercased() ?? ""
            return code.contains("unauthenticated") || code.contains("authentication")
                || message.contains("unauthenticated")
        }
    }

    /// A branch name the response actually carried, or nil. An empty string is
    /// the absent case (`baseRefName` degrades to "" when a response omits it),
    /// and nil is what tells the caller "not observed — keep what you have".
    private static func refOrNil(_ ref: String) -> String? {
        ref.isEmpty ? nil : ref
    }

    /// Each binding's last observed status, for the failure paths that keep it.
    /// A binding that never resolved contributes nothing rather than a nil entry.
    private static func previousStatuses(_ bindings: [PRBinding]) -> [UUID: PRBindingObservation] {
        var out: [UUID: PRBindingObservation] = [:]
        for binding in bindings {
            out[binding.id] = binding.status.map { PRBindingObservation(status: $0) }
        }
        return out
    }

    /// The aggregate rollup classifies a per-check query as worthwhile when it is NOT a settled
    /// success — i.e. it is failing or pending (or any other non-success/non-nil value). SUCCESS
    /// or nil means no required check can be failing or pending → skip the query.
    private static func aggregateRollupIsNonSuccess(_ state: String?) -> Bool {
        guard let state else { return false }
        return state != "SUCCESS"
    }

    /// Refresh a single worktree via `gh api graphql`. Used for on-select refresh.
    ///
    /// Deliberately NOT `gh pr view --json`: that field set exposes neither
    /// `isInMergeQueue` nor `mergeQueueEntry`, so a manual refresh through it
    /// would clobber `mergeQueuePosition` back to nil and flicker the bus away
    /// until the next batch poll. The GraphQL path requests the same
    /// merge-queue field set the batch query does. `gh repo view` resolves the
    /// checkout's `owner/name` so the query can scope to this repo+branch —
    /// which, unlike the 100-PR viewer batch, always finds an old PR.
    public func refresh(worktreeID: UUID, branch: String, upstreamBranch: String?, defaultBranch: String?,
                        pushBranch: GitManager.PushBranchResolution,
                        repoPath: String, prNumber: Int? = nil) async -> PRStatus? {
        // A GitLab worktree must never be answered by `gh`. Both routes below
        // speak GitHub's API alone, and on a FLAT GitLab namespace the
        // worktree's owner/name are valid GitHub coordinates too: with a
        // same-named repository on github.com, `applyRefreshedNode` would write
        // a GitHub pull request's status onto a GitLab worktree and, on a merged
        // one, run the merged-transition machinery — auto-archive included —
        // against a pull request from another forge. `poisonedCacheEntries`
        // compares owner and name only, so it cannot catch that either.
        //
        // The cache is left exactly as it was; only the outcome is recorded, and
        // it says the forge cannot be asked rather than that the query failed.
        if let identity = await cachedNameWithOwner(repoPath: repoPath),
           await isGitLabHost(identity.host, repoPath: repoPath) {
            logger.debug("refresh: worktree \(worktreeID, privacy: .public) is on GitLab host \(identity.host, privacy: .public); its merge request is refreshed through its bindings, not by gh")
            await record(.undetermined(cause: PRUndeterminedCause.forgeNotQueryableDirectly),
                         for: worktreeID, at: now())
            return cache[worktreeID]
        }

        // A stored PR number (fork PRs, or a PR whose head we renamed locally)
        // can't be found by head branch — resolve it directly, mirroring
        // fetchAll's number-first path. Only fall back to the branch path when no
        // number is stored.
        if let prNumber {
            return await refreshByNumber(worktreeID: worktreeID, number: prNumber, repoPath: repoPath)
        }
        guard let ownerRepo = await cachedNameWithOwner(repoPath: repoPath) else {
            // Can't resolve owner/name → leave cache unchanged, and say the
            // attempt settled nothing rather than letting the unchanged value
            // pass for a fresh one.
            await record(.undetermined(cause: PRUndeterminedCause.queryFailed),
                         for: worktreeID, at: now())
            return cache[worktreeID]
        }
        let candidates = Self.branchCandidates(localBranch: branch, upstreamBranch: upstreamBranch,
                                               defaultBranch: defaultBranch, pushBranch: pushBranch)
        // "The forge answered, and this branch has no PR" and "we could not ask"
        // both used to fall out of the same `continue`. They are tracked apart
        // here so the outcome recorded at the end can tell them apart.
        var failureCause: String?
        for candidate in candidates {
            let args = Self.prByBranchArgs(owner: ownerRepo.owner, name: ownerRepo.name, branch: candidate)
            let result = await runGHResult(args: args, repoPath: repoPath)
            guard let result,
                  result.exitStatus == 0,
                  let data = Self.graphQLOutputData(stdout: result.stdout) else {
                let exit = result?.exitStatus ?? -1
                let errSuffix = result?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? "gh not launched"
                logger.debug("refresh: gh graphql failed for branch \(candidate, privacy: .private) (exit \(exit, privacy: .public)): \(errSuffix, privacy: .public); trying next candidate")
                failureCause = (result == nil && !forgeCLIAvailable)
                    ? PRUndeterminedCause.cliUnavailable
                    : PRUndeterminedCause.queryFailed
                continue
            }
            // `try?` would flatten the throw and the nil into one optional —
            // exactly the collapse this whole path exists to undo. A malformed
            // response is ignorance; an empty node list is an answer.
            let parsed: GHPRViewResult?
            do {
                parsed = try Self.parsePRByBranch(from: data)
            } catch {
                logger.debug("refresh: gh graphql response was unparseable for branch \(candidate, privacy: .private); trying next candidate")
                failureCause = PRUndeterminedCause.unparseableResponse
                continue
            }
            guard let obj = parsed else {
                // A parsed, empty node list: the forge answered, and this
                // branch has no PR. Not a failure — try the next candidate.
                continue
            }

            return await applyRefreshedNode(
                worktreeID: worktreeID, number: obj.number, url: obj.url, state: obj.state,
                mergeStateStatus: obj.mergeStateStatus, reviewDecision: obj.reviewDecision ?? "",
                isDraft: obj.isDraft, mergeQueuePosition: obj.mergeQueuePosition, repoPath: repoPath)
        }

        // No candidate yielded a PR — leave the cache unchanged either way, but
        // record which kind of "no" this was.
        logger.debug("refresh: no candidate branch yielded a PR for worktree \(worktreeID, privacy: .public); keeping cached status")
        let cached = cache[worktreeID]
        if let failureCause {
            await record(.undetermined(cause: failureCause), for: worktreeID, at: now())
        } else if cached != nil {
            // Every candidate answered "no PR", yet one is cached — so it lives
            // on a branch this query could not name. Nothing was settled.
            await record(.undetermined(cause: PRUndeterminedCause.branchQueryFoundNothing),
                         for: worktreeID, at: now())
        } else {
            await record(.none, for: worktreeID, at: now())
        }
        return cached
    }

    /// Refresh a single worktree by its stored PR number — one aliased
    /// `pullRequest(number:)` lookup (the only way to reach a fork PR, whose head
    /// never appears in a branch query). Tolerant of a non-zero `gh` exit that
    /// still carries usable `data` (a sibling batch error). Leaves the cache
    /// untouched on any failure to resolve the number.
    private func refreshByNumber(worktreeID: UUID, number: Int, repoPath: String) async -> PRStatus? {
        guard let ownerRepo = await cachedNameWithOwner(repoPath: repoPath) else {
            await record(.undetermined(cause: PRUndeterminedCause.queryFailed),
                         for: worktreeID, at: now())
            return cache[worktreeID]
        }
        let query = Self.numberedPRQuery(aliases: [(alias: "pr0", number: number)])
        let args = [
            "api", "graphql",
            "-f", "query=\(query)",
            "-f", "owner=\(ownerRepo.owner)",
            "-f", "name=\(ownerRepo.name)"
        ]
        guard let result = await runGHResult(args: args, repoPath: repoPath),
              let data = Self.graphQLOutputData(stdout: result.stdout) else {
            logger.debug("refresh: by-number query produced no data for PR #\(number, privacy: .public); keeping cached status")
            await record(.undetermined(cause: forgeCLIAvailable
                                        ? PRUndeterminedCause.queryFailed
                                        : PRUndeterminedCause.cliUnavailable),
                         for: worktreeID, at: now())
            return cache[worktreeID]
        }
        if result.exitStatus != 0 {
            let errSuffix = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.debug("refresh: by-number query exited \(result.exitStatus, privacy: .public) with partial data for PR #\(number, privacy: .public): \(errSuffix, privacy: .public)")
        }
        let matches = Self.parseNumberedPRNodes(from: data, aliases: [(alias: "pr0", worktreeID: worktreeID)])
        guard let node = matches.first?.node else {
            logger.debug("refresh: PR #\(number, privacy: .public) did not resolve by number; keeping cached status")
            // A stored number that will not resolve — deleted, inaccessible, or
            // a partial batch error — is ignorance, never "this worktree has no
            // pull request": it demonstrably had one, by number.
            await record(.undetermined(cause: PRUndeterminedCause.queryFailed),
                         for: worktreeID, at: now())
            return cache[worktreeID]
        }
        return await applyRefreshedNode(
            worktreeID: worktreeID, number: node.number, url: node.url, state: node.state,
            mergeStateStatus: node.mergeVerdictRaw, reviewDecision: node.reviewVerdictRaw,
            isDraft: node.isDraft, mergeQueuePosition: node.mergeQueuePosition, repoPath: repoPath)
    }

    /// Compute check signals for a resolved PR node, map to a `PRStatus`, write it
    /// to the cache via `apply`, and mark the direct-update timestamp. Shared by
    /// both refresh paths (by-number, by-branch) so their signal/apply logic
    /// can't drift. When per-check signals are
    /// unavailable it keeps the prior cached status (transient failure) or, with
    /// no cache to keep, bootstraps with no-signal state (the next poll corrects).
    private func applyRefreshedNode(
        worktreeID: UUID, number: Int, url: String, state: String,
        mergeStateStatus: String, reviewDecision: String, isDraft: Bool,
        mergeQueuePosition: Int?, repoPath: String
    ) async -> PRStatus {
        let observedAt = now()
        let signals: (failing: Bool, pending: Bool)
        if state != "OPEN" {
            signals = (false, false)   // mapState ignores signals for MERGED/CLOSED
        } else if let fetched = await fetchCheckSignals(url: url, number: number, repoPath: repoPath) {
            signals = fetched
        } else if let cached = cache[worktreeID] {
            // Transient failure: keep the previous status rather than guessing,
            // and record that this attempt did not reconfirm it.
            await record(.undetermined(cause: PRUndeterminedCause.checkQueryFailed),
                         for: worktreeID, at: observedAt)
            return cached
        } else {
            signals = (false, false)   // bootstrap with no data; the next poll corrects it
        }
        let (mappedState, reason) = Self.mapStateAndReason(
            ghState: state,
            mergeVerdictRaw: mergeStateStatus,
            reviewVerdictRaw: reviewDecision,
            isDraft: isDraft,
            requiredChecksFailing: signals.failing,
            requiredChecksPending: signals.pending
        )
        let status = PRStatus(number: number, url: url, state: mappedState, reason: reason,
                              mergeQueuePosition: mergeQueuePosition, observedAt: observedAt)
        await apply(status, for: worktreeID)
        await record(.observed, for: worktreeID, at: observedAt)
        lastDirectUpdate[worktreeID] = observedAt
        return status
    }

    /// For tests only: seed a cache entry. Routes through `apply` so the
    /// merge-transition logic is exercised exactly as in production.
    public func seedForTesting(worktreeID: UUID, status: PRStatus) async {
        await apply(status, for: worktreeID)
    }

    /// For tests only: the exact predicate an in-flight `fetchAll` consults
    /// before it overwrites an entry.
    ///
    /// Exposed rather than re-derived in the test, because the property worth
    /// pinning is that `invalidate`'s stamp is visible **to this question** by
    /// the time the first persist callback suspends it — and a test that
    /// reimplemented the comparison could agree with itself while disagreeing
    /// with `fetchAll`.
    func directRefreshLandedForTesting(_ worktreeID: UUID, after batchStartedAt: Date) -> Bool {
        directRefreshLanded(worktreeID, after: batchStartedAt)
    }

    // MARK: - State mapping (internal but static for testability)

    /// Unified function that produces both state and reason in one pass — the single
    /// source of truth that `mapState()` and `computeReason()` delegate to, so they can't drift.
    /// Required-check awareness: a failing *required* check is red and a pending *required*
    /// check is yellow regardless of merge state; non-required checks never color the icon.
    public static func mapStateAndReason(
        forge: Forge = .github,
        ghState: String,
        mergeVerdictRaw: String,
        reviewVerdictRaw: String = "",
        isDraft: Bool = false,
        requiredChecksFailing: Bool = false,
        requiredChecksPending: Bool = false,
        pipelineGated: Bool = false,
        pipelineStatus: String? = nil
    ) -> (state: PRMergeableState, reason: String) {
        switch forge {
        case .github:
            return mapGitHubStateAndReason(
                ghState: ghState,
                mergeVerdictRaw: mergeVerdictRaw,
                reviewVerdictRaw: reviewVerdictRaw,
                isDraft: isDraft,
                requiredChecksFailing: requiredChecksFailing,
                requiredChecksPending: requiredChecksPending)
        case .gitlab:
            return mapGitLabStateAndReason(
                state: ghState,
                detailed: mergeVerdictRaw,
                isDraft: isDraft,
                pipelineGated: pipelineGated,
                pipelineStatus: pipelineStatus)
        }
    }

    private static func mapGitHubStateAndReason(
        ghState: String,
        mergeVerdictRaw: String,
        reviewVerdictRaw: String,
        isDraft: Bool,
        requiredChecksFailing: Bool,
        requiredChecksPending: Bool
    ) -> (state: PRMergeableState, reason: String) {
        switch ghState {
        case "MERGED": return (.merged, "Merged")
        case "CLOSED": return (.closed, "Closed")
        default:
            if isDraft || mergeVerdictRaw == "DRAFT" { return (.draft, "Draft") }
            if reviewVerdictRaw == "CHANGES_REQUESTED" { return (.changesRequested, "Changes requested") }
            // Uniform precedence: failing required check → red, pending required check → yellow,
            // regardless of merge state. With no required checks both are false and the
            // merge-verdict switch below decides (see checkSignals).
            if requiredChecksFailing { return (.checksFailed, "Checks failing") }
            if requiredChecksPending { return (.pending, "Checks pending") }

            switch mergeVerdictRaw {
            case "CLEAN", "HAS_HOOKS", "UNSTABLE":
                // UNSTABLE = mergeable with only non-required checks failing → not red.
                return (.mergeable, "Ready to merge")
            case "BLOCKED":
                // Checks are settled and passing; the only blocker is a not-yet-given review.
                return reviewVerdictRaw == "REVIEW_REQUIRED" ? (.mergeable, "Ready to merge") : (.blocked, "Blocked")
            case "DIRTY":
                return (.blocked, "Merge conflicts")
            case "BEHIND":
                return (.blocked, "Behind base branch")
            case "UNKNOWN":
                return (.pending, "Checks pending")
            default:
                return (.blocked, "Blocked")
            }
        }
    }

    /// GitLab's merge vocabulary.
    ///
    /// The CI signal is computed independently of `detailedMergeStatus`, which
    /// reports only ONE blocker by a precedence GitLab owns and in which CI
    /// ranks below approval, draft and unchecked. Field measurement: 33 failing
    /// pipelines across 71 merge requests on a pipeline-gated project produced
    /// zero CI_MUST_PASS. Reading CI off the merge status would therefore show
    /// red essentially never, and — since NOT_APPROVED maps to .mergeable —
    /// would render a merge request with a failing pipeline as "Ready to merge".
    ///
    /// Precedence mirrors the GitHub arm exactly: terminal, then draft, then
    /// the CI signal, then the merge-status switch.
    private static func mapGitLabStateAndReason(
        state: String,
        detailed: String,
        isDraft: Bool,
        pipelineGated: Bool,
        pipelineStatus: String?
    ) -> (state: PRMergeableState, reason: String) {
        switch state.lowercased() {
        case "merged": return (.merged, "Merged")
        case "closed": return (.closed, "Closed")
        default: break
        }

        if isDraft || detailed == "DRAFT_STATUS" { return (.draft, "Draft") }

        // `onlyAllowMergeIfPipelineSucceeds` is the faithful analogue of
        // GitHub's "required check". A failing pipeline on a project that does
        // not gate merges is GitHub's UNSTABLE, which TBD does not colour.
        if pipelineGated, let pipelineStatus {
            switch pipelineStatus {
            case "FAILED": return (.checksFailed, "Pipeline failed")
            case "RUNNING", "PENDING", "CREATED", "WAITING_FOR_RESOURCE", "PREPARING":
                return (.pending, "Pipeline running")
            case "MANUAL": return (.pending, "Pipeline awaiting manual action")
            default: break
            }
        }

        switch detailed {
        case "MERGEABLE": return (.mergeable, "Ready to merge")
        // Checks are settled and the only blocker is an approval nobody has
        // given — the same reading the GitHub arm gives BLOCKED + REVIEW_REQUIRED.
        case "NOT_APPROVED": return (.mergeable, "Ready to merge")
        case "DISCUSSIONS_NOT_RESOLVED": return (.changesRequested, "Unresolved discussions")
        case "REQUESTED_CHANGES": return (.changesRequested, "Changes requested")
        case "CONFLICT": return (.blocked, "Merge conflicts")
        case "NEED_REBASE": return (.blocked, "Behind base branch")
        case "BLOCKED_STATUS": return (.blocked, "Blocked by another merge request")
        case "CHECKING", "PREPARING": return (.pending, "Checks pending")
        // Not transient: GitLab leaves a stale merge request unchecked until
        // something re-triggers the computation, so the wording must not imply
        // it is about to resolve.
        case "UNCHECKED": return (.pending, "Mergeability not checked")
        default:
            // The enum grows between releases. Unknown means unknown — treating
            // it as blocked would let a future GitLab version paint merge
            // requests red for saying something new.
            return (.pending, "Mergeability not checked")
        }
    }

    public static func mapState(
        forge: Forge = .github,
        ghState: String,
        mergeVerdictRaw: String,
        reviewVerdictRaw: String = "",
        isDraft: Bool = false,
        requiredChecksFailing: Bool = false,
        requiredChecksPending: Bool = false
    ) -> PRMergeableState {
        Self.mapStateAndReason(
            forge: forge,
            ghState: ghState,
            mergeVerdictRaw: mergeVerdictRaw,
            reviewVerdictRaw: reviewVerdictRaw,
            isDraft: isDraft,
            requiredChecksFailing: requiredChecksFailing,
            requiredChecksPending: requiredChecksPending
        ).state
    }

    /// Conclusions (CheckRun) that count as a failing check.
    private static let failingCheckRunConclusions: Set<String> = [
        "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"
    ]
    /// States (StatusContext) that count as a failing check.
    private static let failingStatusContextStates: Set<String> = ["FAILURE", "ERROR"]
    /// CheckRun `status` values that mean the check is still running / not yet concluded.
    private static let pendingCheckRunStatuses: Set<String> = [
        "QUEUED", "IN_PROGRESS", "WAITING", "PENDING", "REQUESTED"
    ]
    /// StatusContext `state` values that count as a pending check.
    private static let pendingStatusContextStates: Set<String> = ["PENDING", "EXPECTED"]

    /// A single status-check context for one PR's last commit. Unifies the GraphQL `CheckRun`
    /// and `StatusContext` shapes.
    struct CheckContext {
        let name: String          // CheckRun.name, or StatusContext.context
        let status: String?       // CheckRun.status (nil for StatusContext)
        let conclusion: String?   // CheckRun.conclusion (nil for StatusContext)
        let state: String?        // StatusContext.state (nil for CheckRun)
        let isRequired: Bool?     // absent in the JSON → nil
    }

    /// Whether a context counts as failing (regardless of required-ness).
    static func contextIsFailing(_ ctx: CheckContext) -> Bool {
        if let conclusion = ctx.conclusion, Self.failingCheckRunConclusions.contains(conclusion) {
            return true
        }
        if let state = ctx.state, Self.failingStatusContextStates.contains(state) {
            return true
        }
        return false
    }

    /// Whether a context counts as pending (regardless of required-ness).
    static func contextIsPending(_ ctx: CheckContext) -> Bool {
        if let status = ctx.status, Self.pendingCheckRunStatuses.contains(status), ctx.conclusion == nil {
            return true
        }
        if let state = ctx.state, Self.pendingStatusContextStates.contains(state) {
            return true
        }
        return false
    }

    /// Compute the (failing, pending) signals for one PR's check contexts.
    /// Only checks GitHub marks `isRequired` for this PR ever color the icon. A PR with no
    /// required checks (stacked PR targeting an unprotected feature branch, or a repo without
    /// branch protection) gets no CI coloring from checks — the mergeStateStatus refinement in
    /// mapState decides instead, matching GitHub's own merge verdict.
    /// `aggregateRollupState` EXPECTED covers the post-push window: a required check that
    /// hasn't reported a context yet can't be seen in `contexts`.
    static func checkSignals(contexts: [CheckContext], aggregateRollupState: String?) -> (failing: Bool, pending: Bool) {
        let required = contexts.filter { $0.isRequired == true }
        return (
            required.contains(where: contextIsFailing),
            required.contains(where: contextIsPending) || aggregateRollupState == "EXPECTED"
        )
    }

    /// Signals derived from the aggregate rollup alone — used when per-check data is
    /// unavailable (query failure) or incomplete (contexts truncated past first page).
    /// The aggregate counts non-required checks too, so this can over-report; it is a
    /// bootstrap/degraded mode, not the normal path.
    static func aggregateFallbackSignals(_ rollupState: String?) -> (failing: Bool, pending: Bool) {
        (["FAILURE", "ERROR"].contains(rollupState ?? ""),
         ["PENDING", "EXPECTED"].contains(rollupState ?? ""))
    }

    /// Result of the combined per-PR check query.
    struct PRCheckDetail {
        let contexts: [CheckContext]
        let rollupState: String?
        let truncated: Bool   // contexts has more than one page; per-check view is incomplete
    }

    /// Pure parse of a single PR's last-commit status-check detail.
    ///
    /// Walks `data.repository.pullRequest.commits.nodes[].commit.statusCheckRollup`: reads
    /// `state`, `contexts.pageInfo.hasNextPage`, and the context nodes (CheckRun via
    /// name/status/conclusion/isRequired; StatusContext via context/state/isRequired; nameless
    /// nodes are skipped). Throws `PRStatusError.invalidJSON` if the outer shape can't be parsed.
    /// A null `statusCheckRollup` (no checks at all) yields empty contexts, nil state, not truncated.
    static func parsePRCheckDetail(fromJSON data: Data) throws -> PRCheckDetail {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let repository = dataObj["repository"] as? [String: Any],
              let pullRequest = repository["pullRequest"] as? [String: Any],
              let commits = pullRequest["commits"] as? [String: Any],
              let commitNodes = commits["nodes"] as? [Any] else {
            throw PRStatusError.invalidJSON
        }

        var result: [CheckContext] = []
        var rollupState: String?
        var truncated = false

        for commitNode in commitNodes.compactMap({ $0 as? [String: Any] }) {
            guard let commit = commitNode["commit"] as? [String: Any],
                  let rollup = commit["statusCheckRollup"] as? [String: Any] else {
                continue
            }
            if let state = rollup["state"] as? String {
                rollupState = state
            }
            guard let contexts = rollup["contexts"] as? [String: Any] else { continue }
            if let pageInfo = contexts["pageInfo"] as? [String: Any],
               pageInfo["hasNextPage"] as? Bool == true {
                truncated = true
            }
            guard let contextNodes = contexts["nodes"] as? [Any] else { continue }

            for context in contextNodes.compactMap({ $0 as? [String: Any] }) {
                let isRequired = context["isRequired"] as? Bool
                if let name = context["name"] as? String {
                    // CheckRun
                    result.append(CheckContext(
                        name: name,
                        status: context["status"] as? String,
                        conclusion: context["conclusion"] as? String,
                        state: nil,
                        isRequired: isRequired
                    ))
                } else if let name = context["context"] as? String {
                    // StatusContext
                    result.append(CheckContext(
                        name: name,
                        status: nil,
                        conclusion: nil,
                        state: context["state"] as? String,
                        isRequired: isRequired
                    ))
                }
                // else: no name/context — skip.
            }
        }

        return PRCheckDetail(contexts: result, rollupState: rollupState, truncated: truncated)
    }

    /// Parse `owner` and `name` from a pull- or merge-request URL.
    ///
    /// GitHub: `/owner/name/pull/<n>`, matched positionally.
    /// GitLab:  `/<namespace…>/<project>/-/merge_requests/<n>`, split at the
    /// `/-/` separator so nesting depth is irrelevant — the namespace may run
    /// to twenty levels, and nesting is the common case rather than the edge.
    static func parseOwnerRepo(fromURL url: String) -> (owner: String, name: String)? {
        guard let components = URLComponents(string: url) else { return nil }
        let path = components.path
        if let range = path.range(of: "/-/merge_requests/") {
            let project = path[path.startIndex..<range.lowerBound]
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard project.count >= 2 else { return nil }
            return (owner: project.dropLast().joined(separator: "/"),
                    name: project[project.count - 1])
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        // Expect: [owner, name, "pull", <n>]
        guard parts.count >= 4, parts[2] == "pull" else { return nil }
        return (owner: String(parts[0]), name: String(parts[1]))
    }

    /// Combined per-PR query: aggregate rollup state + every check context with its
    /// isRequired flag + pagination flag, in one round trip.
    /// The literal number must appear in both pullRequest(number:) and isRequired(pullRequestNumber:).
    static func prCheckQuery(owner: String, name: String, number: Int) -> String {
        """
        { repository(owner: "\(owner)", name: "\(name)") { pullRequest(number: \(number)) {
          commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) {
            pageInfo { hasNextPage }
            nodes {
              __typename
              ... on CheckRun { name status conclusion isRequired(pullRequestNumber: \(number)) }
              ... on StatusContext { context state isRequired(pullRequestNumber: \(number)) }
            }
          } } } } } } } }
        """
    }

    /// Single-PR refresh query: the same per-PR field set as the batch query
    /// (including `mergeQueueEntry { position }`), scoped to one repo + head
    /// branch. Ordered newest-first so `parsePRByBranch` can pick the best node
    /// without a separate `createdAt` tiebreak. `first: 10` covers a branch
    /// reused across a closed+reopened PR pair.
    ///
    /// `owner`/`name`/`branch` are GraphQL **variables**, never interpolated
    /// into the query text: a git ref may legally contain `"`, and interpolating
    /// `headRefName: "\(branch)"` for a branch like `foo"bar` produced a
    /// malformed query (a regression from the old `gh pr view <branch>` execve
    /// arg). `prByBranchArgs` binds the values as raw-string fields.
    static func prByBranchQuery() -> String {
        """
        query($owner: String!, $name: String!, $branch: String!) {
          repository(owner: $owner, name: $name) {
            pullRequests(headRefName: $branch, first: 10,
                         orderBy: {field: CREATED_AT, direction: DESC}) {
              nodes {
                number url state mergeStateStatus reviewDecision isDraft
                mergeQueueEntry { position }
              }
            }
          }
        }
        """
    }

    /// The `gh api graphql` argument vector for the single-PR refresh, binding
    /// `owner`/`name`/`branch` as GraphQL variables. Uses `-f` (raw string), not
    /// `-F` (typed): the variables are declared `String!`, and `-F` would coerce
    /// a branch that looks like a number or `true`/`false`/`null` into the wrong
    /// JSON type and be rejected. Passing them as fields — not interpolated text
    /// — also makes a `"` in any value harmless.
    static func prByBranchArgs(owner: String, name: String, branch: String) -> [String] {
        [
            "api", "graphql",
            "-f", "query=\(prByBranchQuery())",
            "-f", "owner=\(owner)",
            "-f", "name=\(name)",
            "-f", "branch=\(branch)"
        ]
    }

    /// Compute human-readable reason string for the PR merge state.
    /// Delegates to mapStateAndReason() for the single source of truth.
    public static func computeReason(
        forge: Forge = .github,
        ghState: String,
        mergeVerdictRaw: String,
        reviewVerdictRaw: String = "",
        isDraft: Bool = false,
        requiredChecksFailing: Bool = false,
        requiredChecksPending: Bool = false
    ) -> String {
        Self.mapStateAndReason(
            forge: forge,
            ghState: ghState,
            mergeVerdictRaw: mergeVerdictRaw,
            reviewVerdictRaw: reviewVerdictRaw,
            isDraft: isDraft,
            requiredChecksFailing: requiredChecksFailing,
            requiredChecksPending: requiredChecksPending
        ).reason
    }

    /// Priority for choosing between multiple PRs on the same branch.
    /// Higher value = preferred.
    private static func prPriority(_ ghState: String) -> Int {
        switch ghState {
        case "OPEN": return 3
        case "MERGED": return 2
        case "CLOSED": return 1
        default: return 0
        }
    }

    /// Head-branch names to try when matching a worktree to a PR, in priority
    /// order (the worktree's own branch first).
    ///
    /// Beyond the local branch there are two possible candidates, each guarding
    /// a different failure:
    ///
    /// - The **tracked branch**, but only when it names neither the local branch
    ///   nor the repo's default branch. It is what finds a rename-push — a local
    ///   branch pushed to a remote branch under a different name, whose PR is
    ///   only findable there (PR #212). Excluding the default branch is the fix
    ///   for the mis-attachment this whole path exists to prevent:
    ///   `branch.<name>.merge` records the *base* a branch was cut from, so
    ///   offering it as a head ref attached whatever PR someone once opened FROM
    ///   the base branch to every worktree whose own branch had no PR yet.
    /// - The **push branch**, when `@{push}` resolved — subject to the same
    ///   default-branch exclusion. It is what finds a triangular workflow, where
    ///   a push refspec sends the branch somewhere neither name predicts. The
    ///   exclusion is not optional: under `push.default = upstream`, `@{push}`
    ///   IS the upstream, so a base-tracking branch resolves straight to the
    ///   default branch (measured on real git) and an unfiltered push candidate
    ///   would reopen this very bug for anyone using that config.
    ///
    /// A nil `defaultBranch` leaves the local branch alone as the only candidate:
    /// without knowing the base, no other name can be shown not to be one, and a
    /// wrong head-ref candidate is the whole bug.
    ///
    /// KNOWN RESIDUALS, all narrow and all deliberately not addressed here:
    ///
    /// - A **stacked branch** tracking a non-default feature base keeps its
    ///   tracked-branch candidate (that base is not the default branch), so it
    ///   can still be attached to the base's PR. Same class as the bug this
    ///   fixes, narrower, unobserved in the field.
    /// - A **stale or wrong `repo.defaultBranch`** makes the exclusion miss, so
    ///   the fix silently does not apply on that repo. The stored value is
    ///   written once at repo registration and never refreshed. It is usually
    ///   right: `GitManager.detectDefaultBranch` reads
    ///   `refs/remotes/origin/HEAD`, which `git clone` writes and most checkouts
    ///   therefore carry (36 of 44 local repos, measured). The gap is its
    ///   fallback — with no `origin/HEAD` it reports whichever branch is checked
    ///   out, which is a different fact wearing the same name.
    ///
    ///   Re-probing periodically does not fix that, it spreads it: on exactly
    ///   the repos whose stored value can be wrong, the probe is a current-
    ///   branch reader, so a main checkout parked on a feature branch would
    ///   rewrite the stored value on every daemon start and flip it back on the
    ///   next. The fact is not local to PR matching — it also picks the base for
    ///   every new worktree, the fresh-revive base, the periodic fetch, and the
    ///   conflict sweep (`WorktreeLifecycle+Reconcile`) — so a value that
    ///   thrashes is worse than one that is occasionally stale.
    /// - A **rename-push whose target is named like the default branch** (e.g. a
    ///   fork PR pushed as `fix-thing:main`) is indistinguishable from a base
    ///   attachment: the tracked branch is `main`, the repo default is
    ///   legitimately `main`, and every heal condition holds on a PR that really
    ///   is this branch's own. That loss is durable, not a missed poll — the
    ///   candidate list will never offer `main` again, so neither
    ///   `matchUnnumbered` nor `refresh()` can rediscover it. It needs the push
    ///   target's name to equal the repo default, which is why it is accepted.
    static func branchCandidates(
        localBranch: String,
        upstreamBranch: String?,
        defaultBranch: String?,
        pushBranch: GitManager.PushBranchResolution
    ) -> [String] {
        var candidates = [localBranch]
        guard let defaultBranch else { return candidates }
        var pushed: String?
        if case .resolved(let name) = pushBranch { pushed = name }
        for name in [upstreamBranch, pushed].compactMap({ $0 }) {
            guard name != defaultBranch, !candidates.contains(name) else { continue }
            candidates.append(name)
        }
        return candidates
    }

    /// `branchCandidates` for one poll entry — the single derivation the matcher
    /// and the heal share, so the heal can never judge against a list the
    /// matcher did not use.
    static func candidatesFor(_ wt: PollWorktree) -> [String] {
        branchCandidates(localBranch: wt.branch, upstreamBranch: wt.upstreamBranch,
                         defaultBranch: wt.defaultBranch, pushBranch: wt.pushBranch)
    }

    // MARK: - JSON parsing (internal but static for testability)

    public struct PRNode: Sendable {
        public let number: Int
        public let url: String
        public let state: String
        public let mergeVerdictRaw: String
        /// The forge's own verdict on review state, in whatever vocabulary that
        /// forge speaks — never normalized here.
        public let reviewVerdictRaw: String
        public let headRefName: String
        public let createdAt: String        // ISO 8601, e.g. "2026-03-24T15:58:27Z"
        public let isDraft: Bool
        public let statusCheckRollupState: String?
        /// 1-indexed merge-queue position (`mergeQueueEntry.position`), or nil
        /// when the PR is not queued or reports a null position.
        public let mergeQueuePosition: Int?
        /// The PR's base branch. Descriptive only — nothing matches on it — so
        /// it defaults to empty rather than being a required parse field, and a
        /// response that omits it degrades to "unknown" instead of dropping the
        /// whole node. Declared late so the memberwise init stays
        /// source-compatible.
        public let baseRefName: String
        /// The forge that produced this node. Declared last with a default so
        /// the memberwise init stays source-compatible, the same reason
        /// `baseRefName` is declared where it is.
        public let forge: Forge

        init(number: Int, url: String, state: String, mergeVerdictRaw: String,
             reviewVerdictRaw: String, headRefName: String, createdAt: String, isDraft: Bool,
             statusCheckRollupState: String?, mergeQueuePosition: Int?,
             baseRefName: String = "", forge: Forge = .github) {
            self.number = number
            self.url = url
            self.state = state
            self.mergeVerdictRaw = mergeVerdictRaw
            self.reviewVerdictRaw = reviewVerdictRaw
            self.headRefName = headRefName
            self.createdAt = createdAt
            self.isDraft = isDraft
            self.statusCheckRollupState = statusCheckRollupState
            self.mergeQueuePosition = mergeQueuePosition
            self.baseRefName = baseRefName
            self.forge = forge
        }
    }

    /// Split poll inputs by whether the worktree carries a stored PR number.
    /// Numbered entries resolve via a direct `pullRequest(number:)` lookup (the
    /// only way to reach a fork PR, whose head never appears in the viewer batch);
    /// the rest fall through to the legacy viewer-authored branch-name matching.
    static func partitionByPRNumber<T>(_ items: [T], prNumber: (T) -> Int?) -> (numbered: [T], unnumbered: [T]) {
        var numbered: [T] = []
        var unnumbered: [T] = []
        for item in items {
            if prNumber(item) != nil { numbered.append(item) } else { unnumbered.append(item) }
        }
        return (numbered, unnumbered)
    }

    /// Select the unnumbered worktrees the viewer batch left unmatched whose
    /// cached status still carries a PR number, rewriting each with that number
    /// so `fetchNumberedMatches` can resolve it directly. Once 100 newer PRs
    /// exist, an old PR falls out of the viewer-authored batch (first 100 by
    /// CREATED_AT DESC) and the cached number is the only remaining handle —
    /// without it the stale cached status (e.g. "in merge queue") persists
    /// forever and the merged transition / auto-archive never fires. Batch
    /// matches always win: a branch re-pointed to a NEW PR must not get pinned
    /// to the stale cached number, so only unmatched worktrees fall back.
    ///
    /// `batchSucceeded` must reflect whether the viewer batch actually parsed
    /// (empty nodes still counts — the viewer legitimately has no PRs). On a
    /// fetch/parse failure "unmatched" means nothing, and falling back would
    /// resolve stale cached numbers for branches that may point at NEW PRs
    /// (worst case: a stale MERGED number fires auto-archive off an unrelated
    /// PR) — keeping the stale cache on failure is the pre-existing, safe
    /// behavior, so a failed batch yields no fallback at all.
    ///
    /// Terminal cached states are excluded: `.merged` has no further transition
    /// to observe, and `.closed` would otherwise be a permanent per-poll
    /// by-number re-query — a reopened PR is recovered by the on-select
    /// `refresh()` path (or a restored batch match), not this fallback. The
    /// merged-transition case is unaffected: the pre-transition cached state is
    /// non-terminal by definition.
    static func cachedNumberFallback(
        unnumbered: [PollWorktree],
        matchedIDs: Set<UUID>,
        batchSucceeded: Bool,
        cachedStatus: (UUID) -> PRStatus?
    ) -> [PollWorktree] {
        guard batchSucceeded else { return [] }
        return unnumbered.compactMap { wt in
            guard !matchedIDs.contains(wt.id),
                  let cached = cachedStatus(wt.id),
                  cached.state != .merged, cached.state != .closed else { return nil }
            return (wt.id, wt.branch, wt.upstreamBranch, wt.defaultBranch, wt.pushBranch,
                    wt.worktreePath, cached.number)
        }
    }

    /// Lookup key scoping a branch name to one repo. Owner/name are lowercased
    /// because GitHub treats them case-insensitively (URLs and `gh repo view`
    /// may disagree on casing); the branch stays as-is (git refs are
    /// case-sensitive). U+0001 cannot appear in a GitHub owner or repo name,
    /// so keys can never collide across repos.
    static func repoBranchKey(owner: String, name: String, branch: String) -> String {
        "\(owner.lowercased())\u{1}\(name.lowercased())\u{1}\(branch)"
    }

    /// Build the (repo, branch) → best-PR lookup used by the legacy (unnumbered)
    /// path. The viewer batch spans every repo the viewer authored PRs in, and
    /// the same branch name can legitimately exist in several of them; keying on
    /// branch alone handed one repo's PR to another repo's worktree (and
    /// persisted it) — the cross-repo collision this fix removes. Nodes whose
    /// URL doesn't parse to owner/name are dropped: they cannot be scoped, and
    /// an unscoped match is exactly the bug. When multiple PRs share a
    /// repo+branch, pick the best: highest state priority
    /// (OPEN > MERGED > CLOSED), then newest `createdAt` within the same state.
    static func bestNodeByRepoBranch(_ nodes: [PRNode]) -> [String: PRNode] {
        var byKey: [String: PRNode] = [:]
        for node in nodes {
            guard let repo = parseOwnerRepo(fromURL: node.url) else { continue }
            let key = repoBranchKey(owner: repo.owner, name: repo.name, branch: node.headRefName)
            if let existing = byKey[key] {
                let nodePriority = prPriority(node.state)
                let existingPriority = prPriority(existing.state)
                if nodePriority > existingPriority {
                    byKey[key] = node
                } else if nodePriority == existingPriority && node.createdAt > existing.createdAt {
                    byKey[key] = node
                }
            } else {
                byKey[key] = node
            }
        }
        return byKey
    }

    /// Match unnumbered worktrees against the viewer batch, scoped to each
    /// worktree's own repo: a node only matches when its URL's owner/name
    /// equals the worktree's resolved repo. Candidate order is preserved
    /// (own branch first, then any tracked/push branch — see `branchCandidates`). A worktree
    /// whose repo can't be resolved gets NO match, so the caller keeps its
    /// cached status — the same degrade behavior as the numbered path
    /// (`groupNumberedByRepo`); matching it unscoped could apply another
    /// repo's PR.
    static func matchUnnumbered(
        _ unnumbered: [PollWorktree],
        nodes: [PRNode],
        resolveRepo: (String) -> (owner: String, name: String)?
    ) -> [(worktreeID: UUID, node: PRNode)] {
        let byRepoBranch = bestNodeByRepoBranch(nodes)
        return unnumbered.compactMap { wt in
            guard let repo = resolveRepo(wt.worktreePath) else { return nil }
            let candidates = candidatesFor(wt)
            for candidate in candidates {
                if let node = byRepoBranch[repoBranchKey(owner: repo.owner, name: repo.name, branch: candidate)] {
                    return (wt.id, node)
                }
            }
            return nil
        }
    }

    /// Detect cache entries poisoned by the pre-repo-scoping branch match: an
    /// unnumbered worktree whose cached PR URL belongs to a DIFFERENT repo than
    /// the worktree's own. Without this heal a poisoned entry would display
    /// forever (the repo-scoped match above never touches it again) and, worse,
    /// feed its wrong-repo PR number into `cachedNumberFallback`.
    ///
    /// BOTH sides must resolve before an entry is judged: an unresolvable
    /// worktree repo (gh offline/missing) or an unparseable cached URL is
    /// absence of evidence, not proof of poisoning, so the entry is kept.
    /// Owner/name compare case-insensitively (GitHub identifiers are).
    /// Returns the poisoned entries with both repos rendered as
    /// "owner/name" for the caller's log line, plus the cached PR URL so the
    /// caller can name the binding this heal disproves.
    static func poisonedCacheEntries(
        unnumbered: [PollWorktree],
        resolveRepo: (String) -> (owner: String, name: String)?,
        cachedStatus: (UUID) -> PRStatus?
    ) -> [(worktreeID: UUID, cachedRepo: String, worktreeRepo: String, cachedURL: String)] {
        unnumbered.compactMap { wt in
            guard let repo = resolveRepo(wt.worktreePath),
                  let cached = cachedStatus(wt.id),
                  let cachedRepo = parseOwnerRepo(fromURL: cached.url) else { return nil }
            let sameRepo = cachedRepo.owner.lowercased() == repo.owner.lowercased()
                && cachedRepo.name.lowercased() == repo.name.lowercased()
            guard !sameRepo else { return nil }
            return (wt.id, "\(cachedRepo.owner)/\(cachedRepo.name)", "\(repo.owner)/\(repo.name)",
                    cached.url)
        }
    }

    /// Matches this worktree can be *positively shown* to be mis-attached to.
    ///
    /// A clear deletes state a user cannot recreate once the PR ages out of the
    /// 100-PR viewer batch, so "not a candidate" alone is not enough to justify
    /// one. `matches` reaches here from two producers with different strengths:
    /// the viewer batch matches BY CANDIDATE, but `cachedNumberFallback` →
    /// `fetchNumberedMatches` resolves BY NUMBER and never consults candidates.
    /// So a momentarily narrower candidate list would otherwise turn a
    /// conservative failure-to-attach into a destructive delete.
    ///
    /// Four conditions must therefore all hold:
    ///
    /// - The `@{push}` lookup ran to an answer. `.lookupFailed` means the
    ///   candidate list may be narrower than the truth — skip the worktree.
    /// - The PR's head ref is not a candidate.
    /// - The PR's head ref IS the branch this worktree merely *tracks*
    ///   (`upstreamBranch`) rather than one it owns.
    /// - That tracked branch IS the repo's default branch — positive evidence
    ///   that the attachment is to a BASE, not to the worktree's own work. This
    ///   is load-bearing precisely when the default branch is unknown: in a
    ///   rename-push the tracked branch is the worktree's own PR head, and with
    ///   no known default `branchCandidates` cannot offer it, so the three
    ///   conditions above would all hold for a perfectly valid attachment and
    ///   delete it. Stated directly rather than leaned on as a consequence of
    ///   how candidates happen to be built today.
    ///
    /// Note the asymmetry with `branchCandidates`, which is what makes leaning
    /// on a stored `repo.defaultBranch` tolerable here even though it can be
    /// stale (see the residuals listed there): a wrong value almost always costs
    /// a MISSED heal, and what it buys is silence — on such a repo this fix
    /// simply does not apply. One case escapes that: the clear fires on
    /// `tracked == head == defaultBranch`, so a wrong stored default that
    /// happens to name some branch's rename-push target produces the same
    /// durable clear as the third residual at `branchCandidates`, which reaches
    /// it with a *correct* default. Contrived — but it is why "a wrong default
    /// can only cost a missed heal" is not stated flatly. Do not "simplify" the
    /// two uses into one shared gate.
    ///
    /// A head ref that is neither a candidate nor the tracked default branch is
    /// left alone: unexplained, but not demonstrably wrong.
    ///
    /// Scoped to unnumbered worktrees by construction: only IDs present in
    /// `unnumbered` are judged, so a worktree created from a PR row (which
    /// carries that PR's number and legitimately points at a head ref its local
    /// branch does not equal — every fork PR) is never touched.
    static func headRefMismatchedMatches(
        _ matches: [(worktreeID: UUID, node: PRNode)],
        unnumbered: [PollWorktree]
    ) -> [(worktreeID: UUID, headRefName: String, url: String, candidates: [String])] {
        let byID = Dictionary(unnumbered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return matches.compactMap { match in
            guard let wt = byID[match.worktreeID], wt.pushBranch != .lookupFailed else { return nil }
            let candidates = candidatesFor(wt)
            let head = match.node.headRefName
            guard !candidates.contains(head),
                  let tracked = wt.upstreamBranch, tracked == head,
                  let defaultBranch = wt.defaultBranch, tracked == defaultBranch else {
                return nil
            }
            return (match.worktreeID, head, match.node.url, candidates)
        }
    }

    /// Unnumbered worktrees whose cached PR still needs its head ref checked:
    /// this pass produced no match for them (so no fresh node exists to judge),
    /// they carry a cached status, and this daemon run hasn't verified them yet.
    /// Each is rewritten with the cached PR number so `fetchNumberedMatches` can
    /// resolve it.
    ///
    /// In practice these are the terminal-state entries `cachedNumberFallback`
    /// deliberately never re-queries — precisely the ones that would otherwise
    /// display a mis-attached PR forever.
    ///
    /// `batchSucceeded` gates it for the same reason the fallback is gated: on a
    /// fetch/parse failure every worktree is "unmatched" and the word means
    /// nothing. Absence of evidence is not proof of mis-attachment.
    ///
    /// Worktrees that could never satisfy `headRefMismatchedMatches` — a
    /// `.lookupFailed` push resolution, no known tracked branch, or no known
    /// default branch — are skipped before the query rather than after it: their
    /// answer could not be acted on, so the round trip would buy nothing.
    static func headRefVerificationTargets(
        unnumbered: [PollWorktree],
        matchedIDs: Set<UUID>,
        batchSucceeded: Bool,
        verifiedIDs: Set<UUID>,
        cachedStatus: (UUID) -> PRStatus?
    ) -> [PollWorktree] {
        guard batchSucceeded else { return [] }
        return unnumbered.compactMap { wt in
            guard !matchedIDs.contains(wt.id),
                  !verifiedIDs.contains(wt.id),
                  wt.pushBranch != .lookupFailed,
                  wt.upstreamBranch != nil, wt.defaultBranch != nil,
                  let cached = cachedStatus(wt.id) else { return nil }
            return (wt.id, wt.branch, wt.upstreamBranch, wt.defaultBranch, wt.pushBranch,
                    wt.worktreePath, cached.number)
        }
    }

    /// The per-PR field selection shared by the viewer batch and the by-number
    /// aliased query, so the two can't drift and both parse into `PRNode`.
    static let prNodeFieldSelection =
        "number url state mergeStateStatus reviewDecision headRefName baseRefName createdAt isDraft "
        + "statusCheckRollup { state } mergeQueueEntry { position }"

    /// One aliased query resolving several worktrees' stored PR numbers in a
    /// single round trip: `pr0: pullRequest(number: 454) { … }` etc. under the
    /// repo object. Numbers are Int literals (injection-safe); `owner`/`name`
    /// are GraphQL variables bound at the call site.
    static func numberedPRQuery(aliases: [(alias: String, number: Int)]) -> String {
        let selections = aliases
            .map { "\($0.alias): pullRequest(number: \($0.number)) { \(prNodeFieldSelection) }" }
            .joined(separator: "\n    ")
        return """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            \(selections)
          }
        }
        """
    }

    /// Pure parse of the by-number aliased response. Each alias maps to a
    /// worktree; a null/absent `pullRequest` (deleted or inaccessible PR) or a
    /// malformed shape yields no match for that worktree — never a crash.
    static func parseNumberedPRNodes(from data: Data, aliases: [(alias: String, worktreeID: UUID)]) -> [(worktreeID: UUID, node: PRNode)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let repository = dataObj["repository"] as? [String: Any] else {
            logger.debug("fetchAll: malformed by-number GraphQL response, resolving no numbered worktrees")
            return []
        }
        return aliases.compactMap { alias, worktreeID in
            guard let prObj = repository[alias] as? [String: Any],
                  let node = prNode(from: prObj) else { return nil }
            return (worktreeID, node)
        }
    }

    public static func parsePRNodes(from data: Data) throws -> [PRNode] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let viewer = dataObj["viewer"] as? [String: Any],
              let prs = viewer["pullRequests"] as? [String: Any],
              let nodes = prs["nodes"] as? [Any] else {
            throw PRStatusError.invalidJSON
        }

        return nodes.compactMap { $0 as? [String: Any] }.compactMap(prNode(from:))
    }

    /// Extract one `PRNode` from a GraphQL PR object, shared by the viewer-batch
    /// parse and the by-number parse (same `prNodeFieldSelection`).
    static func prNode(from node: [String: Any]) -> PRNode? {
        guard let number = node["number"] as? Int,
              let url = node["url"] as? String,
              let state = node["state"] as? String,
              let mergeStateStatus = node["mergeStateStatus"] as? String,
              let headRefName = node["headRefName"] as? String,
              let createdAt = node["createdAt"] as? String else { return nil }
        let reviewDecision = node["reviewDecision"] as? String ?? ""
        let isDraft = node["isDraft"] as? Bool ?? false
        let statusCheckRollup = node["statusCheckRollup"] as? [String: Any]
        let statusCheckRollupState = statusCheckRollup?["state"] as? String
        // A null/absent mergeQueueEntry (not queued) yields nil; only a real
        // entry carrying an Int position gates the bus icon.
        let mergeQueueEntry = node["mergeQueueEntry"] as? [String: Any]
        let mergeQueuePosition = mergeQueueEntry?["position"] as? Int
        return PRNode(number: number, url: url, state: state,
                      mergeVerdictRaw: mergeStateStatus,
                      reviewVerdictRaw: reviewDecision,
                      headRefName: headRefName,
                      createdAt: createdAt,
                      isDraft: isDraft,
                      statusCheckRollupState: statusCheckRollupState,
                      mergeQueuePosition: mergeQueuePosition,
                      baseRefName: node["baseRefName"] as? String ?? "")
    }

    /// Pure parse of the `repo.listOpenPRs` GraphQL response
    /// (`openPRsQuery`). Never throws — any malformed/unexpected shape
    /// (network hiccup, schema drift, truncated output) degrades to an
    /// empty list with a `.debug` log line, matching the RPC's own
    /// never-error-just-degrade contract (spec §1).
    public static func parseOpenPRNodes(from data: Data) -> [OpenPRInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let repository = dataObj["repository"] as? [String: Any],
              let prs = repository["pullRequests"] as? [String: Any],
              let nodes = prs["nodes"] as? [Any] else {
            logger.debug("listOpenPRs: malformed GraphQL response, returning empty list")
            return []
        }

        if nodes.count >= 100 {
            logger.debug("listOpenPRs: hit the 100-PR page cap; list may be truncated")
        }

        return nodes.compactMap { $0 as? [String: Any] }.compactMap { node -> OpenPRInfo? in
            guard let number = node["number"] as? Int,
                  let title = node["title"] as? String,
                  let headRefName = node["headRefName"] as? String else { return nil }
            let isDraft = node["isDraft"] as? Bool ?? false
            let isCrossRepository = node["isCrossRepository"] as? Bool ?? false
            let headOwner = (node["headRepositoryOwner"] as? [String: Any])?["login"] as? String ?? ""
            return OpenPRInfo(number: number, title: title, headRefName: headRefName,
                              headOwner: headOwner, isCrossRepository: isCrossRepository, isDraft: isDraft)
        }
    }

    /// Repo-scoped query for `repo.listOpenPRs`: every OPEN PR (own, teammates',
    /// fork), newest-updated first, capped at one page of 100 (spec §1 non-goal:
    /// no pagination in v1).
    static func openPRsQuery() -> String {
        """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            pullRequests(states: [OPEN], first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes { number title headRefName isDraft isCrossRepository headRepositoryOwner { login } }
            }
          }
        }
        """
    }

    /// Fetch all open PRs for the repo at `repoPath` (`repo.listOpenPRs` RPC).
    /// Every failure path (gh missing, unauthenticated/offline, non-zero exit,
    /// unparseable response) degrades to `[]` with a `.debug` log — never
    /// throws, matching the picker's "PR data is best-effort" contract.
    public nonisolated func fetchOpenPRs(repoPath: String) async -> [OpenPRInfo] {
        guard let ownerRepo = await cachedNameWithOwner(repoPath: repoPath) else {
            logger.debug("listOpenPRs: could not resolve owner/name for \(repoPath, privacy: .public)")
            return []
        }
        if await isGitLabHost(ownerRepo.host, repoPath: repoPath) {
            // Not merely fruitless — actively wrong. What follows is a GitHub
            // GraphQL query, and on a flat GitLab namespace the same owner/name
            // is a valid GitHub coordinate: a same-named repository on
            // github.com would fill the picker with pull requests this repo has
            // nothing to do with, and creating a worktree from one would check
            // out a branch from another forge.
            //
            // Listing GitLab merge requests is not built, so the picker is empty
            // for a GitLab repo — but not silently: `.warning` is recorded by
            // default where `.debug` is not, so "the picker shows nothing" has
            // an answer in the log without turning debug logging on first.
            logger.warning("listOpenPRs: \(repoPath, privacy: .public) lives on GitLab host \(ownerRepo.host, privacy: .public); listing merge requests is not implemented, so the picker stays empty")
            return []
        }
        let args = [
            "api", "graphql",
            "-f", "query=\(Self.openPRsQuery())",
            "-f", "owner=\(ownerRepo.owner)",
            "-f", "name=\(ownerRepo.name)"
        ]
        guard let result = await runGHResult(args: args, repoPath: repoPath) else {
            logger.debug("listOpenPRs: gh did not launch for \(repoPath, privacy: .public)")
            return []
        }
        guard let data = Self.graphQLOutputData(stdout: result.stdout) else {
            let errSuffix = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.debug("listOpenPRs: gh graphql produced no data (exit \(result.exitStatus, privacy: .public)): \(errSuffix, privacy: .public)")
            return []
        }
        // `gh api graphql` exits non-zero when ANY node errors (a stale/deleted/
        // inaccessible fork PR) yet still emits usable `data` for the rest. Parse
        // whatever came back rather than discarding the whole batch — mirrors
        // `runGHGraphQL`'s partial-results tolerance (regression guard, PR #208).
        if result.exitStatus != 0 {
            let errSuffix = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.debug("listOpenPRs: gh graphql exited \(result.exitStatus, privacy: .public) with partial data: \(errSuffix, privacy: .public)")
        }
        return Self.parseOpenPRNodes(from: data)
    }

    /// Parse the single-PR refresh response (`prByBranchQuery`).
    ///
    /// Walks `data.repository.pullRequests.nodes` and returns the best node —
    /// highest state priority (OPEN > MERGED > CLOSED), and, because the query
    /// orders newest-first, the first node seen at that priority. Returns nil
    /// when the branch has no PR (empty nodes). Throws `PRStatusError.invalidJSON`
    /// only when the outer shape can't be parsed at all.
    static func parsePRByBranch(from data: Data) throws -> GHPRViewResult? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let repository = dataObj["repository"] as? [String: Any],
              let prs = repository["pullRequests"] as? [String: Any],
              let nodes = prs["nodes"] as? [Any] else {
            throw PRStatusError.invalidJSON
        }

        var best: GHPRViewResult?
        var bestPriority = Int.min
        for node in nodes.compactMap({ $0 as? [String: Any] }) {
            guard let number = node["number"] as? Int,
                  let url = node["url"] as? String,
                  let state = node["state"] as? String,
                  let mergeStateStatus = node["mergeStateStatus"] as? String else { continue }
            let priority = Self.prPriority(state)
            // Nodes are newest-first, so the first node seen at a priority is the
            // newest; only a strictly higher priority displaces it.
            guard priority > bestPriority else { continue }
            let mergeQueueEntry = node["mergeQueueEntry"] as? [String: Any]
            best = GHPRViewResult(
                number: number,
                url: url,
                state: state,
                mergeStateStatus: mergeStateStatus,
                reviewDecision: node["reviewDecision"] as? String,
                isDraft: node["isDraft"] as? Bool ?? false,
                mergeQueuePosition: mergeQueueEntry?["position"] as? Int
            )
            bestPriority = priority
        }
        return best
    }

    // MARK: - Shell helpers

    /// Resolve the checkout's `owner/name` and the host it lives on, for
    /// repo-scoped queries and for composing a reference from a bare number.
    ///
    /// Two sources, in this order, and the order is the whole design:
    ///
    /// 1. `gh repo view`, which is asked for `url` alongside `nameWithOwner` so
    ///    the host is gh's own answer rather than an assumption. gh resolves a
    ///    *base* repo, not merely `origin` — with an `upstream` remote present
    ///    it names the parent, which is where a fork's pull requests actually
    ///    live — so replacing it with a remote parse would silently break every
    ///    fork checkout.
    /// 2. The `origin` remote, parsed directly, and **only when gh cannot serve
    ///    this checkout at all** — it is not installed, or it ran and disowned
    ///    the checkout because no remote names a GitHub host it knows. That is
    ///    the case every GitLab checkout is in, and it is the only route by
    ///    which one can ever name itself.
    ///
    /// A gh failure that says nothing about the checkout — an expired token, a
    /// 401, a rate limit, a network blip — is NOT licence to parse the remote.
    /// The two sources disagree on exactly the checkout where it matters: on a
    /// fork with an `upstream` remote gh names the parent, where the fork's pull
    /// requests live, while `origin` names the fork. And this answer is cached
    /// for fifteen minutes (`cachedNameWithOwner`), while a nil is not cached at
    /// all — so a wrong answer is durable and a deferral self-heals on the next
    /// tick. Deferring is therefore the only safe reading of a transient
    /// failure.
    ///
    /// Returns nil when neither source yields a host — a caller that cannot
    /// name the repo defers, and must never fall back to guessing `github.com`.
    private nonisolated func resolveNameWithOwner(
        repoPath: String
    ) async -> (owner: String, name: String, host: String)? {
        switch await resolveViaGH(repoPath: repoPath) {
        case .resolved(let owner, let name, let host):
            return (owner: owner, name: name, host: host)
        case .transientFailure:
            logger.debug("gh could not name the repo at \(repoPath, privacy: .public) this time; deferring rather than reading its origin remote")
            return nil
        case .unservable:
            break
        }
        guard let remote = await readRemoteURL(repoPath: repoPath),
              let identity = Self.parseRemoteIdentity(remote) else {
            logger.debug("could not name the repo at \(repoPath, privacy: .public) from gh or from its origin remote")
            return nil
        }
        return identity
    }

    /// What one `gh repo view` settled about a checkout.
    private enum GHRepoResolution {
        case resolved(owner: String, name: String, host: String)
        /// gh cannot serve this checkout at all: no binary, or it ran and said
        /// none of the checkout's remotes name a GitHub host it knows. The only
        /// state in which the `origin` remote may speak for the repo instead.
        case unservable
        /// gh ran and failed at something it does serve. Says nothing about the
        /// checkout, so it settles nothing about the checkout.
        case transientFailure
    }

    private nonisolated func resolveViaGH(repoPath: String) async -> GHRepoResolution {
        let args = ["repo", "view", "--json", "nameWithOwner,url"]
        guard let result = await runGHResult(args: args, repoPath: repoPath) else {
            // gh never launched — it is absent, or the spawn itself failed.
            // There is nobody to ask, on this checkout or any other.
            return .unservable
        }
        let errSuffix = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitStatus == 0 else {
            if Self.ghDisownsCheckout(errSuffix) {
                logger.debug("gh does not speak for the repo at \(repoPath, privacy: .public): \(errSuffix, privacy: .public)")
                return .unservable
            }
            logger.debug("gh repo view exited \(result.exitStatus, privacy: .public) for \(repoPath, privacy: .public): \(errSuffix, privacy: .public)")
            return .transientFailure
        }
        guard let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nameWithOwner = root["nameWithOwner"] as? String,
              let url = root["url"] as? String,
              let host = URLComponents(string: url)?.host, !host.isEmpty else {
            logger.debug("gh repo view answered for \(repoPath, privacy: .public) in a shape this build could not read")
            return .transientFailure
        }
        let parts = nameWithOwner.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
        guard parts.count == 2 else { return .transientFailure }
        return .resolved(owner: String(parts[0]), name: String(parts[1]), host: host)
    }

    /// Whether gh's own refusal says it does not serve this checkout, as opposed
    /// to failing at something it does serve.
    ///
    /// A whitelist of gh's disownment messages, deliberately not a blacklist of
    /// failures: an unrecognised message must read as "ask again later", because
    /// the alternative reading is cached for fifteen minutes and points every
    /// query at the wrong repository (see `resolveNameWithOwner`). A message gh
    /// rewords therefore costs a GitLab checkout one poll's deferral until this
    /// list is updated; the opposite default would cost a fork checkout a wrong,
    /// cached identity on every transient 401.
    static func ghDisownsCheckout(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        // "none of the git remotes configured for this repository point to a
        // known GitHub host" — every GitLab checkout, and the steady state this
        // fallback exists for.
        return text.contains("known github host")
            // Nothing to point anywhere, and nothing for gh to be authoritative
            // about; the remote parse will fail too, harmlessly.
            || text.contains("no git remotes found")
            || text.contains("not a git repository")
    }

    private nonisolated func readRemoteURL(repoPath: String) async -> String? {
        if let remoteURLReader { return await remoteURLReader(repoPath) }
        return await GitManager().getRemoteURL(repoPath: repoPath)
    }

    /// The host, namespace and project of a git remote URL.
    ///
    /// Accepts the three shapes a remote that names a NETWORK HOST can take —
    /// `https://host/a/b`, `ssh://git@host:22/a/b`, and the scp-like
    /// `git@host:a/b` — and keeps the FULL namespace, because a GitLab project
    /// can nest (`acme/platform/api`) and the owner is everything before the
    /// last segment.
    ///
    /// A remote that names no host is rejected outright rather than having its
    /// first path segment read as one. `file:///Users/me/repo.git` would
    /// otherwise resolve to the host "Users" and `/srv/git/acme/repo.git` to
    /// "srv" — identities that are not merely useless but harmful. They are
    /// cached like any other; `Forge.forHost` classifies anything that is not
    /// `github.com` as GitLab, so `tbd pr attach` composes merge-request URLs
    /// against them; and `poisonedCacheEntries` rests on "both sides resolved"
    /// meaning both sides are KNOWN, so a fabricated identity turns a
    /// legitimately cached PR status into a cross-repo poisoning and clears it,
    /// persistently.
    ///
    /// `RemoteRepoMatching` in TBDShared parses the same three shapes and is
    /// deliberately not reused: it drops the host by design, and it keeps only
    /// the last two segments, so it reads `acme/platform/backend/api` as
    /// `backend/api`. Both choices are correct for what it does — matching a
    /// provider's `meta["repo"]` against registered repos — and wrong for
    /// naming a repo to its own forge.
    static func parseRemoteIdentity(_ remote: String) -> (owner: String, name: String, host: String)? {
        var rest = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        if let scheme = rest.range(of: "://") {
            // Only the schemes that carry a network host. `file://` names a
            // path on this machine, and a path's first segment is not a host.
            guard Self.networkRemoteSchemes.contains(String(rest[..<scheme.lowerBound]).lowercased()) else {
                return nil
            }
            rest = String(rest[scheme.upperBound...])
        } else if let colon = rest.firstIndex(of: ":"), !rest[..<colon].contains("/"),
                  colon != rest.startIndex {
            // scp-like syntax puts ':' where a URL puts the first '/'. The
            // colon must come before any '/', or this is a local path with a
            // colon somewhere in it rather than `host:namespace/project`.
            rest.replaceSubrange(colon...colon, with: "/")
        } else {
            // A bare local path — `/srv/git/acme/repo.git`, `../sibling` — names
            // no host at all, and its first segment must never be read as one.
            return nil
        }
        var segments = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count >= 3 else { return nil }
        var host = segments.removeFirst()
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        // An `ssh://git@host:22/…` port is not part of the host name.
        if let portColon = host.firstIndex(of: ":") { host = String(host[host.startIndex..<portColon]) }
        var name = segments.removeLast()
        if name.lowercased().hasSuffix(".git") { name = String(name.dropLast(4)) }
        let owner = segments.joined(separator: "/")
        guard !host.isEmpty, !owner.isEmpty, !name.isEmpty else { return nil }
        return (owner: owner, name: name, host: host.lowercased())
    }

    /// The URL schemes that put a network host where this parser reads one.
    /// `file` is deliberately absent, and so is every scheme nobody has seen on
    /// a forge remote: an unknown scheme is not evidence of a host.
    private static let networkRemoteSchemes: Set<String> = ["ssh", "git", "git+ssh", "http", "https"]

    /// `resolveNameWithOwner` behind a ~15-min TTL cache so the periodic poll
    /// (by-number query) and picker (open-PR query) stop spawning a `gh repo
    /// view` subprocess on every call. A checkout's owner/name is effectively
    /// immutable, so a stale entry is harmless within the TTL.
    private func cachedNameWithOwner(repoPath: String) async -> (owner: String, name: String, host: String)? {
        if let entry = ownerRepoCache[repoPath], entry.expiry > Date() {
            return entry.value
        }
        guard let resolved = await resolveNameWithOwner(repoPath: repoPath) else { return nil }
        ownerRepoCache[repoPath] = (value: resolved, expiry: Date().addingTimeInterval(15 * 60))
        return resolved
    }

    /// The checkout's own `owner`/`name` and the host they live on, through the
    /// same TTL cache the poll and picker use. Exposed for PR *binding*
    /// validation, which has to ask the same question on every hook fire and
    /// manual attach — resolving it independently would both double the `gh
    /// repo view` subprocesses and let the two answers disagree inside a TTL
    /// window. The host rides along because a bare number has to be composed
    /// into a reference, and the shape of that reference is the host's to
    /// decide.
    public func repoIdentity(repoPath: String) async -> (owner: String, name: String, host: String)? {
        await cachedNameWithOwner(repoPath: repoPath)
    }

    /// Group by-number poll entries by their worktree's own repo. The daemon
    /// manages worktrees across multiple repos, so one repo's owner/name must
    /// never be applied to another worktree's PR number: the number usually
    /// resolves to nothing in the wrong repo (silently dropping the match), but
    /// can land on an unrelated PR — whose MERGED state would fire auto-archive
    /// on the wrong worktree. Entries whose repo can't be resolved are dropped
    /// (the caller keeps their cached status), matching the existing degrade
    /// behavior. Group order follows first appearance; `cwd` is the first
    /// grouped worktree's path, used as gh's working directory.
    static func groupNumberedByRepo(
        _ numbered: [PollWorktree],
        resolve: (String) -> (owner: String, name: String)?
    ) -> [(owner: String, name: String, cwd: String, entries: [(worktreeID: UUID, number: Int)])] {
        var order: [String] = []
        var groups: [String: (owner: String, name: String, cwd: String, entries: [(worktreeID: UUID, number: Int)])] = [:]
        for wt in numbered {
            guard let number = wt.prNumber, let repo = resolve(wt.worktreePath) else { continue }
            let key = "\(repo.owner)/\(repo.name)"
            if groups[key] == nil {
                groups[key] = (repo.owner, repo.name, wt.worktreePath, [])
                order.append(key)
            }
            groups[key]?.entries.append((wt.id, number))
        }
        return order.compactMap { groups[$0] }
    }

    /// Resolve stored PR numbers directly via aliased `pullRequest(number:)`
    /// queries — the only way to reach a fork PR, whose head branch never
    /// appears in the viewer-authored batch. Each worktree's number is scoped
    /// to its OWN repo: one aliased query per repo group (see
    /// `groupNumberedByRepo`), with the TTL cache keeping `gh repo view`
    /// spawns bounded. Degrades per group to no matches on any failure
    /// (owner/name unresolved, gh missing, non-zero exit, unparseable); the
    /// caller keeps prior cached status for those worktrees.
    private nonisolated func fetchNumberedMatches(
        _ numbered: [PollWorktree]
    ) async -> [(worktreeID: UUID, node: PRNode)] {
        var resolved: [String: (owner: String, name: String)] = [:]
        for path in Set(numbered.map(\.worktreePath)) {
            guard let ownerRepo = await cachedNameWithOwner(repoPath: path) else {
                logger.debug("fetchAll: could not resolve owner/name for numbered PRs at \(path, privacy: .public)")
                continue
            }
            // The by-number query is GitHub's. Offering a GitLab checkout's
            // coordinates to it is not merely fruitless on a flat namespace —
            // a same-named GitHub repository answers, and a MERGED answer fires
            // auto-archive on a worktree whose merge request is somewhere else
            // entirely. Dropping the entry degrades exactly as an unresolvable
            // repo does: the worktree keeps its cached status.
            guard !(await isGitLabHost(ownerRepo.host, repoPath: path)) else {
                logger.debug("fetchAll: not offering the stored number at \(path, privacy: .public) to gh — \(ownerRepo.host, privacy: .public) is a GitLab host")
                continue
            }
            resolved[path] = (owner: ownerRepo.owner, name: ownerRepo.name)
        }
        var matches: [(worktreeID: UUID, node: PRNode)] = []
        for group in Self.groupNumberedByRepo(numbered, resolve: { resolved[$0] }) {
            let aliased = group.entries.enumerated().map {
                (alias: "pr\($0.offset)", worktreeID: $0.element.worktreeID, number: $0.element.number)
            }
            let query = Self.numberedPRQuery(aliases: aliased.map { ($0.alias, $0.number) })
            let args = [
                "api", "graphql",
                "-f", "query=\(query)",
                "-f", "owner=\(group.owner)",
                "-f", "name=\(group.name)"
            ]
            guard let result = await runGHResult(args: args, repoPath: group.cwd),
                  let data = Self.graphQLOutputData(stdout: result.stdout) else {
                logger.debug("fetchAll: by-number query produced no data for \(group.owner, privacy: .public)/\(group.name, privacy: .public)")
                continue
            }
            // `gh api graphql` exits non-zero when ONE aliased PR errors (stale,
            // deleted, or inaccessible — likeliest for a fork PR) while still emitting
            // usable `data` for the others. Parse whatever came back regardless of
            // exit status; log the partial failure (regression guard, PR #208).
            if result.exitStatus != 0 {
                let errSuffix = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                logger.debug("fetchAll: by-number query exited \(result.exitStatus, privacy: .public) with partial data for \(group.owner, privacy: .public)/\(group.name, privacy: .public): \(errSuffix, privacy: .public)")
            }
            matches += Self.parseNumberedPRNodes(from: data, aliases: aliased.map { ($0.alias, $0.worktreeID) })
        }
        return matches
    }

    /// Branch matching on GitLab: one `sourceBranches` query per project.
    ///
    /// The counterpart of `runGHGraphQL` + `matchUnnumbered`, and deliberately
    /// shaped differently. GitHub can only be asked for the *viewer's* pull
    /// requests, so branch matching there is a local join over whatever the
    /// authenticated account happens to have authored. GitLab takes the branch
    /// list as a query argument with no author filter, so the instance does the
    /// matching and a merge request opened by a teammate or through the web UI
    /// is found — the coverage gap that makes this the discovery route worth
    /// having.
    ///
    /// Degrades per project: a project whose query fails contributes no matches
    /// and no answered ids, so its worktrees keep whatever they had and record
    /// `.undetermined` rather than "no merge request".
    private nonisolated func fetchGitLabBranchMatches(
        _ unnumbered: [PollWorktree],
        repos: [String: (owner: String, name: String)],
        hosts: [String: String]
    ) async -> (matches: [(worktreeID: UUID, node: PRNode)],
                answeredIDs: Set<UUID>,
                pipelineGated: [UUID: Bool],
                failureCause: String) {
        var matches: [(worktreeID: UUID, node: PRNode)] = []
        var answered: Set<UUID> = []
        var gated: [UUID: Bool] = [:]
        var failureCause = PRUndeterminedCause.queryFailed

        // One query per project, so several worktrees on one project cost one
        // round trip — the same economy the aliased by-number query buys on the
        // GitHub side.
        var order: [String] = []
        var groups: [String: (host: String, owner: String, name: String, entries: [PollWorktree])] = [:]
        for wt in unnumbered {
            guard let repo = repos[wt.worktreePath], let host = hosts[wt.worktreePath] else { continue }
            let key = "\(host.lowercased())\u{1}\(repo.owner.lowercased())\u{1}\(repo.name.lowercased())"
            if groups[key] == nil {
                groups[key] = (host, repo.owner, repo.name, [])
                order.append(key)
            }
            groups[key]?.entries.append(wt)
        }

        for key in order {
            guard let group = groups[key] else { continue }
            let branches = Self.orderedUniqueBranches(group.entries.flatMap(Self.candidatesFor))
            guard !branches.isEmpty else { continue }
            let fetched = await fetchGitLabNodes(
                query: GitLabQueries.mergeRequestsByBranchQuery(branches: branches),
                host: group.host,
                projectPath: "\(group.owner)/\(group.name)",
                repoPath: group.entries[0].worktreePath)
            switch fetched {
            case .failure(let cause):
                failureCause = cause
            case .success(let nodes, let pipelineGated):
                answered.formUnion(group.entries.map(\.id))
                let groupMatches = Self.matchUnnumbered(group.entries, nodes: nodes,
                                                        resolveRepo: { repos[$0] })
                for match in groupMatches { gated[match.worktreeID] = pipelineGated }
                matches += groupMatches
            }
        }
        return (matches, answered, gated, failureCause)
    }

    /// The branch list one project query asks about: every candidate of every
    /// worktree in it, first-seen order kept and duplicates dropped — several
    /// worktrees legitimately share a candidate.
    static func orderedUniqueBranches(_ branches: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for branch in branches {
            guard !branch.isEmpty, seen.insert(branch).inserted else { continue }
            out.append(branch)
        }
        return out
    }

    private nonisolated func runGHGraphQL(repoPath: String) async -> Data? {
        let query = """
        {
          viewer {
            pullRequests(first: 100, states: [OPEN, MERGED, CLOSED],
                         orderBy: {field: CREATED_AT, direction: DESC}) {
              nodes { \(Self.prNodeFieldSelection) }
            }
          }
        }
        """
        let args = ["api", "graphql", "-f", "query=\(query)"]
        guard let result = await runGHResult(args: args, repoPath: repoPath),
              let data = Self.graphQLOutputData(stdout: result.stdout) else {
            return nil
        }

        if result.exitStatus != 0 {
            let errSuffix = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if errSuffix.isEmpty {
                logger.debug("gh graphql exited \(result.exitStatus, privacy: .public) with partial stdout")
            } else {
                logger.debug("gh graphql exited \(result.exitStatus, privacy: .public) with partial stdout: \(errSuffix, privacy: .public)")
            }
        }

        return data
    }

    /// One combined GraphQL round trip for a PR's check signals.
    /// Returns nil on any failure (gh missing, non-zero exit, parse error) — callers keep
    /// the previous cached status rather than guessing.
    private nonisolated func fetchCheckSignals(url: String, number: Int, repoPath: String) async -> (failing: Bool, pending: Bool)? {
        guard let ownerRepo = Self.parseOwnerRepo(fromURL: url) else {
            logger.debug("Cannot parse owner/repo from PR URL \(url, privacy: .public)")
            return nil
        }
        let query = Self.prCheckQuery(owner: ownerRepo.owner, name: ownerRepo.name, number: number)
        let args = ["api", "graphql", "-f", "query=\(query)"]
        guard let result = await runGHResult(args: args, repoPath: repoPath),
              result.exitStatus == 0,
              let data = Self.graphQLOutputData(stdout: result.stdout),
              let detail = try? Self.parsePRCheckDetail(fromJSON: data) else {
            logger.debug("Check signal query failed for PR #\(number, privacy: .public)")
            return nil
        }
        if detail.truncated {
            // Can't see every check — trust the aggregate instead of a partial view.
            logger.debug("PR #\(number, privacy: .public) has >100 check contexts; using aggregate fallback")
            return Self.aggregateFallbackSignals(detail.rollupState)
        }
        return Self.checkSignals(contexts: detail.contexts, aggregateRollupState: detail.rollupState)
    }

    static func graphQLOutputData(stdout: String) -> Data? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return stdout.data(using: .utf8)
    }

    private nonisolated func runGHResult(args: [String], repoPath: String) async -> GHCommandResult? {
        if let ghRunner {
            return await ghRunner(args, repoPath)
        }
        guard let ghPath = Self.resolvedGHPath else {
            logger.debug("gh CLI not found in PATH")
            return nil
        }
        return await Self.runCLI(executable: ghPath, args: args, repoPath: repoPath)
    }

    /// One `glab` invocation, through the injected seam when a test supplied one.
    private nonisolated func runGLResult(args: [String], repoPath: String) async -> GHCommandResult? {
        if let glRunner {
            return await glRunner(args, repoPath)
        }
        return await Self.runGlab(args: args, repoPath: repoPath)
    }

    /// The real `glab` subprocess. Static because `GitLabHostResolver` is handed
    /// this same runner while the manager is still being initialized, so there
    /// is no instance yet for it to capture.
    private static func runGlab(args: [String], repoPath: String) async -> GHCommandResult? {
        guard let glabPath = resolvedGlabPath else {
            logger.debug("glab CLI not found in PATH")
            return nil
        }
        return await runCLI(executable: glabPath, args: args, repoPath: repoPath)
    }

    private static func runCLI(executable: String, args: [String], repoPath: String) async -> GHCommandResult? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { p in
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: GHCommandResult(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitStatus: p.terminationStatus
                ))
            }

            do {
                try process.run()
            } catch {
                logger.debug("Failed to launch \(executable, privacy: .public): \(error)")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Resolved once per process — a CLI's location doesn't change mid-process.
    private static let resolvedGHPath: String? = resolveCLIPath("gh")

    private static let resolvedGlabPath: String? = resolveCLIPath("glab")

    private static func resolveCLIPath(_ tool: String) -> String? {
        let candidates = ["/usr/local/bin/\(tool)", "/opt/homebrew/bin/\(tool)", "/usr/bin/\(tool)"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        // Fall back to PATH search
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let full = "\(dir)/\(tool)"
                if FileManager.default.isExecutableFile(atPath: full) { return full }
            }
        }
        return nil
    }
}

/// One `gh` invocation's outcome. Internal (not private) so the injected-runner
/// seam below can be driven from tests without a real `gh` on PATH.
struct GHCommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitStatus: Int32

    init(stdout: String, stderr: String = "", exitStatus: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }
}

// MARK: - Supporting types

/// Result of the single-PR refresh query, populated by `parsePRByBranch`.
/// (No longer `Codable`: the refresh path moved from `gh pr view --json` to
/// `gh api graphql`, whose nested `mergeQueueEntry { position }` shape is hand
/// parsed like the batch response.) Internal so tests can assert the decode.
struct GHPRViewResult {
    let number: Int
    let url: String
    let state: String
    let mergeStateStatus: String
    let reviewDecision: String?
    let isDraft: Bool
    /// 1-indexed merge-queue position, or nil when not queued.
    let mergeQueuePosition: Int?
}

public enum PRStatusError: LocalizedError {
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "the GitHub response could not be parsed as the expected PR-status JSON shape"
        }
    }
}
