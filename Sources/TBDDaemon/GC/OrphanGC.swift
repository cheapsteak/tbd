import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// Errors thrown by `OrphanGC.restore(recordID:)`.
public enum OrphanGCError: Error, CustomStringConvertible, Equatable {
    /// No `ReapRecord` exists with the given id.
    case recordNotFound(UUID)
    /// `restore(recordID:)` only supports `.agentWorktree` records — scratchpads
    /// have no restore path (there's nothing to recreate a bare tmp dir from).
    case unsupportedKind(ReapKind)
    /// The record was already restored once; restoring twice would attempt to
    /// recreate a worktree that (probably) already exists on disk.
    case alreadyRestored(UUID)

    public var description: String {
        switch self {
        case .recordNotFound(let id):
            return "OrphanGC: no reap record with id \(id)"
        case .unsupportedKind(let kind):
            return "OrphanGC: restore is only supported for .agentWorktree records, got .\(kind.rawValue)"
        case .alreadyRestored(let id):
            return "OrphanGC: reap record \(id) was already restored"
        }
    }
}

// `OrphanGC.sweep` returns `TBDShared.GCSweepResult` (the Codable RPC wire
// type, RPCProtocol.swift) directly — a same-shaped local mirror type used to
// live here and silently module-shadow the shared one; it was consolidated
// away so the RPC handler needs no conversion.

/// Orchestrates one orphan-GC sweep: enumerates agent-worktree and scratchpad
/// candidates via the Task 5/6 collectors, gates them through the
/// `gcEnabled` master switch, reaps what's eligible, persists a `ReapRecord`
/// per reap, deletes expired snapshot refs whose branch anchor still exists,
/// and broadcasts `.reapRecordsChanged` whenever anything actually changed.
///
/// Every failure direction here is toward keeping/no-op: a DB read failure
/// short-circuits the whole sweep, an `lsof` timeout skips the whole sweep
/// (never treated as "no live processes"), and `dryRun` never touches disk or
/// the DB regardless of `gcEnabled`.
public actor OrphanGC {
    private let db: TBDDatabase
    private let git: GitManager
    private let broadcast: @Sendable (StateDelta) -> Void
    /// Optional-returning live-cwd provider. The provider returning `nil`
    /// means "live cwds could not be determined" and makes `sweep` skip
    /// entirely; the property itself being `nil` means "use the real lsof".
    private let liveCWDsProvider: (@Sendable () async -> [String]?)?
    private let scratchpadBase: URL
    private let now: @Sendable () -> Date

    private let snapshot: ReapSnapshot
    private let agentCollector: AgentWorktreeCollector
    private let scratchpadCollector: ScratchpadCollector
    private let deletionQueueCollector: DeletionQueueCollector

    /// Production seam: an injected `lsofProvider` returns a non-optional
    /// `[String]` — by definition authoritative, it can't signal
    /// "unavailable". Wraps into the internal optional-returning provider.
    public init(
        db: TBDDatabase,
        git: GitManager,
        broadcast: @escaping @Sendable (StateDelta) -> Void,
        lsofProvider: (@Sendable () async -> [String])? = nil,
        scratchpadBase: URL? = nil,
        now: (@Sendable () -> Date)? = nil
    ) {
        var wrapped: (@Sendable () async -> [String]?)?
        if let lsofProvider {
            wrapped = { await lsofProvider() }
        }
        self.init(
            db: db, git: git, broadcast: broadcast, liveCWDsProvider: wrapped,
            scratchpadBase: scratchpadBase, now: now
        )
    }

    /// Internal seam (tests): the provider may return `nil` to simulate the
    /// real lsof path's "unavailable" sentinel (timeout / spawn failure /
    /// non-zero exit), which must make `sweep` skip entirely rather than be
    /// treated as "no live processes". `liveCWDsProvider` has no default so
    /// this never collides with the public init's defaulted overload.
    init(
        db: TBDDatabase,
        git: GitManager,
        broadcast: @escaping @Sendable (StateDelta) -> Void,
        liveCWDsProvider: (@Sendable () async -> [String]?)?,
        scratchpadBase: URL? = nil,
        now: (@Sendable () -> Date)? = nil
    ) {
        let resolvedNow = now ?? Date.init
        let resolvedScratchpadBase = scratchpadBase ?? TBDConstants.claudeScratchpadBase
        let snap = ReapSnapshot(git: git)

        self.db = db
        self.git = git
        self.broadcast = broadcast
        self.liveCWDsProvider = liveCWDsProvider
        self.scratchpadBase = resolvedScratchpadBase
        self.now = resolvedNow
        self.snapshot = snap
        self.agentCollector = AgentWorktreeCollector(git: git, snapshot: snap, now: resolvedNow)
        self.scratchpadCollector = ScratchpadCollector(base: resolvedScratchpadBase)
        self.deletionQueueCollector = DeletionQueueCollector(git: git)
    }

    // MARK: - Sweep

    /// Runs one full orphan-GC pass. `dryRun` computes and returns `planned`
    /// without touching disk or the DB, regardless of `gcEnabled`. When
    /// `gcEnabled` is `false` and `dryRun` is also `false`, the sweep does
    /// nothing at all — not even the `lsof` pass.
    public func sweep(dryRun: Bool = false) async -> GCSweepResult {
        var planned: [String] = []
        var reaped = 0

        guard let config = try? await db.config.get() else { return .init(planned: [], reaped: 0) }
        guard config.gcEnabled || dryRun else { return .init(planned: ["gc disabled"], reaped: 0) }

        guard let live = await liveCWDs() else {
            logger.error("gc: lsof unavailable this sweep (timeout or spawn failure) — skipping entirely")
            return .init(planned: ["lsof unavailable - sweep skipped"], reaped: 0)
        }

        let repos = (try? await db.repos.list()) ?? []
        for repo in repos {
            let candidates = await agentCollector.candidates(repoPath: repo.path)
            for candidate in candidates {
                switch await agentCollector.decide(candidate, liveCWDs: live, graceSeconds: config.gcGraceSeconds) {
                case .keep(let reason):
                    planned.append("KEEP \(reason) \(candidate.path)")
                    logger.debug("gc: keep \(reason, privacy: .public) \(candidate.path, privacy: .public)")
                case .reap:
                    planned.append("REAP agent-worktree \(candidate.path)")
                    // The outer `gcEnabled || dryRun` guard means a non-dry
                    // run here always has gcEnabled == true.
                    guard !dryRun else { continue }
                    if let record = await agentCollector.reap(candidate, freshLiveCWDs: { await self.liveCWDs() }) {
                        await insertReapRecord(record)
                        reaped += 1
                        logger.info("""
                        gc: reaped agent worktree \(candidate.path, privacy: .public) \
                        snapshot=\(record.snapshotRef ?? "none", privacy: .public)
                        """)
                        // The reaped worktree may have had its own Claude Code
                        // scratchpad; clean that up too.
                        if let scratchRecord = await scratchpadCollector.cleanUp(
                            forRemovedWorktreePath: candidate.path, repoPath: candidate.repoPath, now: now()
                        ) {
                            await insertReapRecord(scratchRecord)
                            reaped += 1
                            planned.append("REAP scratchpad \(scratchRecord.worktreePath)")
                        }
                    } else {
                        planned.append("KEEP snapshot-failed \(candidate.path)")
                        logger.warning("gc: reap refused (late gate) for \(candidate.path, privacy: .public)")
                    }
                }
            }
        }

        await reclaimDeletionQueue(
            repos: repos, live: live, dryRun: dryRun,
            planned: &planned, reaped: &reaped
        )

        await reconcileScratchpads(repos: repos, dryRun: dryRun, planned: &planned, reaped: &reaped)

        // Snapshot retention never runs in dryRun; the outer guard already
        // establishes gcEnabled for any non-dry run.
        if !dryRun {
            await gcOldSnapshots(retentionDays: config.gcSnapshotRetentionDays)
        }

        if reaped > 0 { broadcast(.reapRecordsChanged) }
        return .init(planned: planned, reaped: reaped)
    }

    /// Reclaims worktree directories that outlived their archive: entries
    /// already queued in a pool's `.deleting/`, plus archives that a
    /// pre-queue release failed to remove.
    ///
    /// The archived-row scan is deliberately the mirror of
    /// `reconcileScratchpads`, which reads the same rows and keeps the ones
    /// whose directory is *gone*. The ones that remain are exactly this
    /// method's input.
    private func reclaimDeletionQueue(
        repos: [Repo], live: [String], dryRun: Bool,
        planned: inout [String], reaped: inout Int
    ) async {
        let layout = WorktreeLayout()
        let scratchPrefix = TBDConstants.scratchDir.path
        var repoPathByID: [UUID: String] = [:]
        var prefixesByRepoID: [UUID: [String]] = [:]
        var pools: Set<String> = []
        for repo in repos {
            repoPathByID[repo.id] = repo.path
            let prefixes = layout.legacyAndCanonicalPrefixes(for: repo)
            prefixesByRepoID[repo.id] = prefixes
            pools.formUnion(prefixes)
        }
        pools.insert(scratchPrefix)

        // 1. Entries already queued — unconditionally reclaimable.
        for entry in deletionQueueCollector.pendingEntries(pools: Array(pools)) {
            planned.append("REAP queued-deletion \(entry.path)")
            guard !dryRun else { continue }
            if deletionQueueCollector.drain(entry) {
                reaped += 1
                logger.info("gc: drained queued deletion \(entry.path, privacy: .public)")
            }
        }

        // 2. Archives that never finished.
        let allWorktrees = (try? await db.worktrees.list(status: .archived)) ?? []
        let candidates = await deletionQueueCollector.interruptedArchives(
            worktrees: allWorktrees,
            repoPathByID: repoPathByID,
            prefixesByRepoID: prefixesByRepoID,
            scratchPrefix: scratchPrefix
        )
        for candidate in candidates {
            switch await deletionQueueCollector.decide(candidate, liveCWDs: live) {
            case .keep(let reason):
                planned.append("KEEP \(reason) \(candidate.path)")
                logger.debug("""
                gc: keep \(reason, privacy: .public) \(candidate.path, privacy: .public)
                """)
            case .reap:
                planned.append("REAP archived-worktree \(candidate.path)")
                guard !dryRun else { continue }
                guard let entry = await deletionQueueCollector.reap(candidate) else {
                    planned.append("KEEP enqueue-failed \(candidate.path)")
                    continue
                }
                // The count and the record reflect the commit point (queued +
                // pruned from git), not confirmed byte removal — `drain`'s
                // result is intentionally not gating either one. If this
                // immediate drain doesn't finish, the entry stays in
                // `.deleting/` and step 1 above reclaims it on a later sweep.
                deletionQueueCollector.drain(entry)
                await insertReapRecord(ReapRecord(
                    kind: .archivedWorktree,
                    repoPath: candidate.repoPath ?? "",
                    worktreePath: candidate.path
                ))
                reaped += 1
                logger.info("""
                gc: reclaimed archived worktree \(candidate.path, privacy: .public)
                """)
            }
        }
    }

    /// Scratchpad reconciliation: archived TBD worktrees whose directory is
    /// already gone but whose Claude Code scratchpad survives. Mirrors the
    /// same keep-biased `dryRun`/`gcEnabled` gate as the agent-worktree loop.
    /// `repos` is the sweep's own already-loaded repo list, reused here to
    /// resolve each archived row's `repoID` to a `repo.path` without a second
    /// DB round trip; a row with no resolvable repo (deleted repo, no
    /// `repoID`) stamps `""` — fails toward the previous behavior rather than
    /// dropping the record.
    ///
    /// The mutating work is delegated to `ScratchpadCollector.reconcile` (the
    /// same entry point `reconcileScratchpadsBeforeRepoRemoval` uses) so
    /// there is exactly one implementation of "delete a scratchpad whose
    /// worktree is gone". `dryRun` short-circuits before calling it —
    /// `reconcile` always mutates, so dry-run planning recomputes the
    /// candidate list read-only instead.
    private func reconcileScratchpads(
        repos: [Repo], dryRun: Bool, planned: inout [String], reaped: inout Int
    ) async {
        let repoPathByID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.path) })
        let archived = (try? await db.worktrees.list(status: .archived)) ?? []
        let gone = archived
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
            .map { (worktreePath: $0.path, repoPath: $0.repoID.flatMap { repoPathByID[$0] } ?? "") }

        guard !dryRun else {
            for entry in gone {
                let slug = ScratchpadCollector.slug(forWorktreePath: entry.worktreePath)
                let dir = scratchpadBase.appendingPathComponent(slug)
                guard FileManager.default.fileExists(atPath: dir.path) else { continue }
                planned.append("REAP scratchpad \(dir.path)")
            }
            return
        }

        // The outer `gcEnabled || dryRun` guard means a non-dry run here
        // always has gcEnabled == true.
        let records = await scratchpadCollector.reconcile(knownPaths: gone, now: now())
        for record in records {
            await insertReapRecord(record)
            reaped += 1
            planned.append("REAP scratchpad \(record.worktreePath)")
            logger.info("gc: reaped scratchpad \(record.worktreePath, privacy: .public)")
        }
    }

    /// Entry point for `repo.remove` (review Medium 2): `db.worktrees.deleteForRepo`
    /// deletes EVERY worktree row for `repoID` — every status, including
    /// archived — with no further chance for the sweep's own reconciliation
    /// to catch up: once the rows are gone, nothing can resolve their paths
    /// to a scratchpad slug again. Fetches every row up front and runs them
    /// through the same `ScratchpadCollector.reconcile` the sweep's own
    /// reconciliation uses, stamped with `repoPath` (the caller already has
    /// the `Repo` in scope) so reclaimed scratchpads still surface in that
    /// repo's History UI even after the repo itself is gone. Call this
    /// BEFORE `db.worktrees.deleteForRepo`.
    ///
    /// Gated by `gcEnabled`, same as every other GC deletion path; a config
    /// read failure fails toward keeping (skip), and a worktree-list read
    /// failure likewise skips rather than risking a partial reconciliation.
    public func reconcileScratchpadsBeforeRepoRemoval(repoID: UUID, repoPath: String) async {
        guard let config = try? await db.config.get(), config.gcEnabled else {
            logger.debug("""
            gc: repo-removal scratchpad reconciliation skipped for \(repoPath, privacy: .public) — gc disabled
            """)
            return
        }
        guard let rows = try? await db.worktrees.list(repoID: repoID) else { return }
        let pairs = rows.map { (worktreePath: $0.path, repoPath: repoPath) }
        let records = await scratchpadCollector.reconcile(knownPaths: pairs, now: now())
        for record in records {
            await insertReapRecord(record)
            logger.info("gc: reaped scratchpad (repo removal) \(record.worktreePath, privacy: .public)")
        }
        if !records.isEmpty {
            broadcast(.reapRecordsChanged)
        }
    }

    // MARK: - Snapshot retention

    /// Deletes expired snapshot refs — never-restored records reaped before
    /// the retention window — but ONLY when the record's branch still exists.
    /// A record whose branch is gone keeps its ref forever: the ref is the
    /// only thing anchoring that commit reachable, so deleting it would make
    /// the snapshot unrecoverable garbage-collectable by git itself. Never
    /// called in `dryRun`.
    private func gcOldSnapshots(retentionDays: Int) async {
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86400)
        guard let records = try? await db.reapRecords.unrestoredOlderThan(cutoff) else { return }
        for record in records {
            guard let snapshotRef = record.snapshotRef else { continue }
            guard let branch = record.branch else {
                logger.debug("""
                gc: keeping snapshot \(snapshotRef, privacy: .public) — no branch on record, ref is sole guardian
                """)
                continue
            }
            guard await git.refExists(repoPath: record.repoPath, ref: "refs/heads/\(branch)") else {
                logger.debug("""
                gc: keeping snapshot \(snapshotRef, privacy: .public) — branch \(branch, privacy: .public) is gone
                """)
                continue
            }
            do {
                try await git.deleteRef(repoPath: record.repoPath, ref: snapshotRef)
                logger.info("gc: deleted expired snapshot ref \(snapshotRef, privacy: .public)")
            } catch {
                logger.warning("""
                gc: failed to delete expired snapshot ref \(snapshotRef, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            }
        }
    }

    // MARK: - Restore

    /// Restores a reaped agent worktree. Only valid for `.agentWorktree`
    /// records that haven't already been restored — scratchpads have no
    /// restore path, and restoring twice would try to recreate a worktree
    /// that (very likely) already exists on disk.
    public func restore(recordID: UUID) async throws {
        guard let record = try await db.reapRecords.get(id: recordID) else {
            throw OrphanGCError.recordNotFound(recordID)
        }
        guard record.kind == .agentWorktree else {
            throw OrphanGCError.unsupportedKind(record.kind)
        }
        guard record.restoredAt == nil else {
            throw OrphanGCError.alreadyRestored(recordID)
        }

        try await snapshot.restore(record: record)
        try await db.reapRecords.markRestored(id: recordID, at: now())
        logger.info("gc: restored \(record.worktreePath, privacy: .public)")
        broadcast(.reapRecordsChanged)
    }

    // MARK: - Event-driven scratchpad cleanup

    /// Entry point for the archive hook (Task 8): a TBD worktree at `path`
    /// was just removed, so its Claude Code scratchpad (if any) is cleaned up
    /// immediately rather than waiting for the next sweep's reconciliation.
    /// `repoPath` is the owning repo's root (the archive caller has `repo` in
    /// scope), stamped onto the resulting record; pass `""` when unknown.
    ///
    /// Verifies the worktree directory is actually gone before doing
    /// anything else. `completeArchiveWorktree` already fires this callback
    /// only once it has confirmed the path is gone — queued out of its pool
    /// slot on the success leg, or a verified `git.worktreeRemove` on the
    /// fallback leg — so this is defense in depth against a future caller
    /// that doesn't uphold that contract, not a workaround for a swallowed
    /// failure: a failed removal must never orphan-classify (and delete) a
    /// scratchpad that's still in active use.
    ///
    /// The `gcEnabled` master switch governs ALL GC deletion, including this
    /// event-driven path — one toggle covers both collectors. A config read
    /// failure also skips (fail toward keeping).
    public func scratchpadCleanup(forRemovedWorktreePath path: String, repoPath: String) async {
        guard !FileManager.default.fileExists(atPath: path) else {
            logger.debug("gc: scratchpad cleanup skipped for \(path, privacy: .public) — worktree dir still exists")
            return
        }
        guard let config = try? await db.config.get(), config.gcEnabled else {
            logger.debug("gc: scratchpad cleanup skipped for \(path, privacy: .public) — gc disabled")
            return
        }
        guard let record = await scratchpadCollector.cleanUp(
            forRemovedWorktreePath: path, repoPath: repoPath, now: now()
        ) else {
            return
        }
        await insertReapRecord(record)
        logger.info("gc: reaped scratchpad (event) \(record.worktreePath, privacy: .public)")
        broadcast(.reapRecordsChanged)
    }

    /// Persists a `ReapRecord`, never failing the caller: by the time this is
    /// called the disk reclaim already happened, so there is nothing left to
    /// roll back. A failure here only loses the *record* of what was
    /// reclaimed (and, for agent worktrees, the restorability pointer) — bad
    /// enough to log at `.error`, not bad enough to undo a deletion that
    /// already succeeded.
    private func insertReapRecord(_ record: ReapRecord) async {
        do {
            try await db.reapRecords.insert(record)
        } catch {
            logger.error("""
            gc: failed to persist reap record for \(record.worktreePath, privacy: .public) \
            (kind=\(record.kind.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)
            """)
        }
    }

    // MARK: - Live cwds (one lsof pass per sweep)

    /// Returns the canonicalized cwds of every currently-running process, or
    /// `nil` when that can't be determined reliably (lsof timed out or failed
    /// to spawn) — callers MUST treat `nil` as "skip the sweep", never as
    /// "no live processes".
    private func liveCWDs() async -> [String]? {
        if let liveCWDsProvider {
            return await liveCWDsProvider()
        }
        return await Self.realLiveCWDs()
    }

    /// Real `lsof`-backed live-cwd provider: runs `lsof -d cwd -Fn` under a
    /// 60s deadline and hands the outcome to `parseLiveCWDs`. A spawn failure
    /// is the same "unavailable" sentinel as a timeout: `nil`, skip the sweep.
    private static func realLiveCWDs() async -> [String]? {
        let outcome: BoundedProcessOutcome
        do {
            outcome = try await runBoundedProcess(
                executable: "/usr/sbin/lsof",
                arguments: ["-d", "cwd", "-Fn"],
                currentDirectory: nil,
                timeout: .seconds(60)
            )
        } catch {
            logger.error("gc: lsof spawn failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        return parseLiveCWDs(outcome)
    }

    /// Pure parser for the lsof outcome — extracted so the safety-relevant
    /// "unavailable ⇒ skip sweep" direction is directly unit-testable.
    ///
    /// `lsof -d cwd -Fn` prints one `p<pid>` header line per process followed
    /// by an `n<path>` line for its cwd. Lines are filtered to the
    /// `n`-prefixed ones, the prefix is stripped, each path is canonicalized
    /// (so it compares equal to git's always-canonical worktree paths), and
    /// the result is deduped preserving first-seen order.
    ///
    /// Returns `nil` — the "skip the entire sweep" sentinel — for:
    /// - `.timedOut`: a partial listing must never read as "no live processes".
    /// - non-zero exit: lsof's output on failure is not a complete cwd
    ///   picture, so it gets the same keep-biased treatment as a timeout.
    /// - non-UTF-8 stdout: unparseable output is no picture at all.
    static func parseLiveCWDs(_ outcome: BoundedProcessOutcome) -> [String]? {
        switch outcome {
        case .timedOut:
            logger.error("gc: lsof timed out after 60s")
            return nil
        case .completed(let status, let stdout, _):
            guard status == 0 else {
                logger.error("gc: lsof exited \(status, privacy: .public) — treating live cwds as unavailable")
                return nil
            }
            guard let text = String(data: stdout, encoding: .utf8) else {
                logger.error("gc: lsof output was not valid UTF-8")
                return nil
            }
            var seen = Set<String>()
            var result: [String] = []
            for line in text.split(separator: "\n") {
                guard line.hasPrefix("n") else { continue }
                let raw = String(line.dropFirst())
                guard !raw.isEmpty else { continue }
                let canonical = AgentWorktreeCollector.canon(raw)
                if seen.insert(canonical).inserted {
                    result.append(canonical)
                }
            }
            return result
        }
    }
}
