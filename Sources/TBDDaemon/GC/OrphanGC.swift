import Foundation
import os
import Security
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// Errors thrown by `OrphanGC.restore(recordID:)`.
public enum OrphanGCError: LocalizedError, CustomStringConvertible, Equatable {
    /// No `ReapRecord` exists with the given id.
    case recordNotFound(UUID)
    /// `restore(recordID:)` only supports `.agentWorktree` records — scratchpads
    /// have no restore path (there's nothing to recreate a bare tmp dir from),
    /// and an `.orphanProcess` record describes a kill, which nothing can undo.
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

    public var errorDescription: String? { description }
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
    private let profileDirCollector: ProfileDirCollector
    private let hangStackCollector: HangStackCollector
    /// Deletes the path-keyed Claude Code credentials item belonging to a
    /// quarantined profile dir. Injected so tests never reach the real login
    /// keychain, which `scripts/test.sh` cannot fence.
    private let credentialsKeychain: any ClaudeCredentialsKeychainDeleting
    /// Test-only injection seam: awaited once inside `reclaimDeletionQueue`,
    /// after the interrupted-archive candidate list has been computed and
    /// before any candidate is reaped. That is the exact window the pre-reap
    /// row re-read closes, and nothing else in the sweep is slow or
    /// interruptible enough to land a concurrent `forgetWorktree` in it
    /// deterministically. `nil` in production (both public inits omit it), so
    /// the sweep is unchanged there.
    private let beforeInterruptedArchiveReap: (@Sendable () async -> Void)?
    /// Test-only injection seam, the profile-dir twin of
    /// `beforeInterruptedArchiveReap`: awaited once inside
    /// `reapOrphanProfileDirs`, after the candidate list and the row snapshot have
    /// been taken and before any candidate is reaped. That is the exact window
    /// the pre-reap row re-read closes, and nothing else in that phase is slow
    /// or interruptible enough to land a concurrent profile creation in it
    /// deterministically. `nil` in production (both public inits omit it), so
    /// the sweep is unchanged there.
    private let beforeProfileDirReap: (@Sendable () async -> Void)?
    /// Test seam for the pid-to-cwd half of the sweep's `lsof` pass. `nil` in
    /// production, where the map comes from the same single pass that produces
    /// `liveCWDsProvider`'s path list — no second subprocess, no per-pid
    /// syscall.
    private let processCWDsProvider: (@Sendable () async -> [Int32: String]?)?
    /// The `ps` snapshot reader. Returning `nil` means "the process graph
    /// could not be determined", which skips the orphan-process phase — never
    /// "there are no orphans". Injected in tests; the real `/bin/ps` reader in
    /// production. The same closure is handed to `OrphanProcessCollector`,
    /// which re-reads through it immediately before each signal volley.
    private let processSnapshotProvider: @Sendable () async -> [ProcessSnapshotEntry]?
    private let orphanProcessCollector: OrphanProcessCollector

    /// Production seam: an injected `lsofProvider` returns a non-optional
    /// `[String]` — by definition authoritative, it can't signal
    /// "unavailable". Wraps into the internal optional-returning provider.
    public init(
        db: TBDDatabase,
        git: GitManager,
        broadcast: @escaping @Sendable (StateDelta) -> Void,
        lsofProvider: (@Sendable () async -> [String])? = nil,
        scratchpadBase: URL? = nil,
        now: (@Sendable () -> Date)? = nil,
        profileDirBase: URL? = nil,
        hangStackBase: URL? = nil,
        credentialsKeychain: any ClaudeCredentialsKeychainDeleting = SecItemClaudeCredentialsKeychain(),
        signaller: any ProcessSignaller = ProductionProcessSignaller()
    ) {
        var wrapped: (@Sendable () async -> [String]?)?
        if let lsofProvider {
            wrapped = { await lsofProvider() }
        }
        self.init(
            db: db, git: git, broadcast: broadcast, liveCWDsProvider: wrapped,
            scratchpadBase: scratchpadBase, now: now,
            profileDirBase: profileDirBase, hangStackBase: hangStackBase,
            credentialsKeychain: credentialsKeychain,
            signaller: signaller
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
        now: (@Sendable () -> Date)? = nil,
        beforeInterruptedArchiveReap: (@Sendable () async -> Void)? = nil,
        profileDirBase: URL? = nil,
        hangStackBase: URL? = nil,
        credentialsKeychain: any ClaudeCredentialsKeychainDeleting = SecItemClaudeCredentialsKeychain(),
        beforeProfileDirReap: (@Sendable () async -> Void)? = nil,
        processCWDsProvider: (@Sendable () async -> [Int32: String]?)? = nil,
        processSnapshotProvider: (@Sendable () async -> [ProcessSnapshotEntry]?)? = nil,
        signaller: any ProcessSignaller = ProductionProcessSignaller(),
        orphanProcessGraceAttempts: Int = 30,
        orphanProcessPollInterval: Duration = .milliseconds(100),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        let resolvedNow = now ?? Date.init
        let resolvedScratchpadBase = scratchpadBase ?? TBDConstants.claudeScratchpadBase
        // `ClaudeProfileConfigDirManager` owns where profile dirs live (and
        // honors `TBD_HOME` through `TBDConstants`), so the collector's base is
        // read from it rather than rebuilt here.
        let resolvedProfileDirBase = profileDirBase
            ?? ClaudeProfileConfigDirManager().baseDirectory
        // `HangStackRetention` owns where the app writes hang stacks, so the
        // collector's base is read from it rather than rebuilt here — that is
        // what keeps the writer's cap and this sweep pointed at one directory.
        let resolvedHangStackBase = hangStackBase ?? HangStackRetention.defaultBaseDirectory
        let snap = ReapSnapshot(git: git)

        self.db = db
        self.git = git
        self.broadcast = broadcast
        self.liveCWDsProvider = liveCWDsProvider
        self.scratchpadBase = resolvedScratchpadBase
        self.now = resolvedNow
        self.snapshot = snap
        self.beforeInterruptedArchiveReap = beforeInterruptedArchiveReap
        self.beforeProfileDirReap = beforeProfileDirReap
        self.credentialsKeychain = credentialsKeychain
        self.agentCollector = AgentWorktreeCollector(git: git, snapshot: snap, now: resolvedNow)
        self.scratchpadCollector = ScratchpadCollector(base: resolvedScratchpadBase)
        self.deletionQueueCollector = DeletionQueueCollector(git: git, now: resolvedNow)
        self.profileDirCollector = ProfileDirCollector(
            base: resolvedProfileDirBase, now: resolvedNow)
        self.hangStackCollector = HangStackCollector(base: resolvedHangStackBase)
        self.processCWDsProvider = processCWDsProvider
        let resolvedSnapshotProvider: @Sendable () async -> [ProcessSnapshotEntry]? =
            processSnapshotProvider ?? { await OrphanProcessCollector.realProcessSnapshot() }
        self.processSnapshotProvider = resolvedSnapshotProvider
        self.orphanProcessCollector = OrphanProcessCollector(
            signaller: signaller, snapshotProvider: resolvedSnapshotProvider, now: resolvedNow,
            graceAttempts: orphanProcessGraceAttempts,
            pollInterval: orphanProcessPollInterval,
            clock: clock)
    }

    // MARK: - Sweep

    /// Runs one full orphan-GC pass. `dryRun` computes and returns `planned`
    /// without touching disk or the DB, regardless of `gcEnabled`. When
    /// `gcEnabled` is `false` and `dryRun` is also `false`, the sweep does
    /// nothing at all — not even the `lsof` pass.
    public func sweep(dryRun: Bool = false) async -> GCSweepResult {
        var planned: [String] = []
        var reaped = 0
        // Counted separately from `reaped` on purpose: hang-stack files produce
        // no `ReapRecord`, so they must NOT arm the `.reapRecordsChanged`
        // broadcast below, which stays keyed to the record-producing phases.
        // They are still added to the returned total so `tbd gc sweep` reports
        // honestly.
        var hangStacksReaped = 0

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
                switch await agentCollector.decide(
                    candidate, liveCWDs: live.paths, graceSeconds: config.gcGraceSeconds) {
                case .keep(let reason):
                    planned.append("KEEP \(reason) \(candidate.path)")
                    logger.debug("gc: keep \(reason, privacy: .public) \(candidate.path, privacy: .public)")
                case .reap:
                    planned.append("REAP agent-worktree \(candidate.path)")
                    // The outer `gcEnabled || dryRun` guard means a non-dry
                    // run here always has gcEnabled == true.
                    guard !dryRun else { continue }
                    if let record = await agentCollector.reap(
                        candidate, freshLiveCWDs: { await self.liveCWDs()?.paths }) {
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

        // One read of the archived rows for both consumers below: the deletion
        // queue wants the ones whose directory survives, scratchpad
        // reconciliation the ones whose directory is gone.
        let archived = (try? await db.worktrees.list(status: .archived)) ?? []

        await reclaimDeletionQueue(
            repos: repos, archived: archived, live: live.paths,
            graceSeconds: config.gcGraceSeconds, dryRun: dryRun,
            planned: &planned, reaped: &reaped
        )

        await reconcileScratchpads(
            repos: repos, archived: archived, dryRun: dryRun,
            planned: &planned, reaped: &reaped
        )

        await reclaimProfileDirs(
            config: config, dryRun: dryRun, planned: &planned, reaped: &reaped
        )

        await reclaimOrphanProcesses(
            config: config, repos: repos, live: live,
            dryRun: dryRun, planned: &planned, reaped: &reaped
        )

        await reclaimHangStacks(
            config: config, dryRun: dryRun, planned: &planned, reaped: &hangStacksReaped
        )

        // Snapshot retention never runs in dryRun; the outer guard already
        // establishes gcEnabled for any non-dry run.
        if !dryRun {
            await gcOldSnapshots(retentionDays: config.gcSnapshotRetentionDays)
        }

        if reaped > 0 { broadcast(.reapRecordsChanged) }
        return .init(planned: planned, reaped: reaped + hangStacksReaped)
    }

    /// Reclaims hang-stack diagnostic files under
    /// `~/Library/Logs/TBD/hang-stacks/` that are past the retention policy —
    /// older than `HangStackRetention.maxAge`, or outside the newest
    /// `HangStackRetention.maxFiles`
    /// (`docs/specs/2026-08-29-hang-stack-reclaimer-design.md`).
    ///
    /// Gated by `gcHangStacksEnabled` on top of `gcEnabled`, the same shape
    /// `reclaimProfileDirs` uses and for the same reason: this phase deletes
    /// persisted state from a background sweep, which the house rule puts
    /// behind a default-off flag until it has soaked. `dryRun` bypasses the
    /// flag exactly as `sweep` lets it bypass `gcEnabled` — someone deciding
    /// whether to enable a default-off flag needs to see what enabling it would
    /// reclaim first — and touches nothing either way.
    ///
    /// **Reports in aggregate, and persists no `ReapRecord`.** A hang stack is
    /// not restorable and belongs to no repo, so a record would never surface
    /// anywhere; and one row per file would write tens of thousands of rows
    /// into `reap_records` on a first sweep — a new unbounded table to record
    /// the end of an unbounded directory. For the same reason the plan gets one
    /// line rather than one per file: 25,000 lines in an RPC response is not a
    /// plan anyone reads.
    private func reclaimHangStacks(
        config: Config, dryRun: Bool, planned: inout [String], reaped: inout Int
    ) async {
        guard config.gcHangStacksEnabled || dryRun else { return }

        let selected = hangStackCollector.candidates(
            now: now(), graceSeconds: config.gcGraceSeconds)
        guard !selected.isEmpty else { return }

        let plannedBytes = selected.reduce(Int64(0)) { $0 + $1.sizeBytes }
        // The COLLECTOR's base, never the one that was injected: it resolves
        // its base at construction, so with a symlinked base the two spell
        // different directories — and a plan line that names a directory the
        // reap does not touch is the exact mismatch `resolvedDirectory` exists
        // to kill.
        planned.append("""
        REAP hang-stacks \(hangStackCollector.base.path) files=\(selected.count) \
        bytes=\(plannedBytes)
        """)
        // This phase's guard is `gcHangStacksEnabled || dryRun`, so every line
        // below runs only with the flag actually on.
        guard !dryRun else { return }

        let result = hangStackCollector.reap(selected)
        guard result.files > 0 else { return }
        reaped += result.files
        logger.info("""
        gc: reaped \(result.files, privacy: .public) hang-stack file(s) \
        (\(result.bytes, privacy: .public) bytes) from \
        \(self.hangStackCollector.base.path, privacy: .public)
        """)
    }

    /// Reclaims worktree directories that outlived their archive: entries
    /// already queued in a pool's `.deleting/`, archives that a pre-queue
    /// release failed to remove, and git registrations that outlived the
    /// directory they point at.
    ///
    /// The archived-row scan is deliberately the mirror of
    /// `reconcileScratchpads`, which reads the same rows and keeps the ones
    /// whose directory is *gone*. The ones that remain are exactly this
    /// method's step-2 input; the ones it keeps are step 3's.
    private func reclaimDeletionQueue(
        repos: [Repo], archived: [Worktree], live: [String], graceSeconds: Int, dryRun: Bool,
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
        // `WorktreeDeletionQueue.enqueue` derives the pool from the worktree's
        // own parent directory, and an adopted worktree can live anywhere — so
        // archiving one creates a `.deleting/` queue outside every layout
        // prefix, which an interrupted drain would otherwise leave in the
        // user's own directory forever. Every archived row's parent is
        // therefore a pool worth draining. This widens only what gets
        // DRAINED, never what step 2 may reclaim: an entry sitting in
        // `.deleting/<uuid>` is there because TBD renamed it there, so it
        // needs no provenance gate.
        for row in archived {
            let parent = (row.localPath as NSString).deletingLastPathComponent
            guard parent.hasPrefix("/"), parent != "/" else { continue }
            pools.insert(parent)
        }

        // 1. Entries already queued — unconditionally reclaimable.
        for entry in deletionQueueCollector.pendingEntries(pools: Array(pools)) {
            planned.append("REAP queued-deletion \(entry.path)")
            guard !dryRun else { continue }
            if await deletionQueueCollector.drain(entry) {
                reaped += 1
                logger.info("gc: drained queued deletion \(entry.path, privacy: .public)")
            }
        }

        // 2. Archives that never finished.
        let candidates = await deletionQueueCollector.interruptedArchives(
            worktrees: archived,
            repoPathByID: repoPathByID,
            prefixesByRepoID: prefixesByRepoID,
            scratchPrefix: scratchPrefix
        )
        await beforeInterruptedArchiveReap?()
        for candidate in candidates {
            switch await deletionQueueCollector.decide(
                candidate, liveCWDs: live, graceSeconds: graceSeconds
            ) {
            case .keep(let reason):
                planned.append("KEEP \(reason) \(candidate.path)")
                logger.debug("""
                gc: keep \(reason, privacy: .public) \(candidate.path, privacy: .public)
                """)
            case .reap:
                planned.append("REAP archived-worktree \(candidate.path)")
                guard !dryRun else { continue }
                // Measure BEFORE the reap, the same order
                // `ScratchpadCollector.cleanUp` and
                // `AgentWorktreeCollector.reap` use: `reap` renames the
                // directory into the queue and the drain below unlinks it, so
                // this is the last moment its size can be read. A `nil` here
                // (du failed or timed out) is the unmeasured record we would
                // have written anyway.
                let bytes = await GCDiskUsage.apparentBytes(path: candidate.path)
                // Re-read the row immediately before acting on it. The
                // candidate list above is a snapshot, and `forgetWorktree`
                // hard-deletes a row while promising the directory stays
                // put — so a forget landing between the snapshot and here
                // would otherwise still get its directory reaped, silently
                // breaking that promise. A revive (status back to `.active`)
                // is the same hazard through a different door. The check
                // lives here rather than in `DeletionQueueCollector`
                // deliberately: that type has no database access, and
                // keeping it that way is worth a round trip per reap. A read
                // failure reads as "skip", the keep-favoring direction every
                // other gate in this sweep takes.
                let refreshed = (try? await db.worktrees.get(id: candidate.worktreeID)) ?? nil
                guard refreshed?.status == .archived else {
                    planned.append("KEEP row-changed \(candidate.path)")
                    logger.info("""
                    gc: keep row-changed \(candidate.path, privacy: .public) — \
                    its row was deleted or left .archived after this sweep listed it
                    """)
                    continue
                }
                guard let entry = await deletionQueueCollector.reap(candidate) else {
                    planned.append("KEEP enqueue-failed \(candidate.path)")
                    continue
                }
                // The count and the record reflect the commit point (queued +
                // pruned from git), not confirmed byte removal — `drain`'s
                // result is intentionally not gating either one. If this
                // immediate drain doesn't finish, the entry stays in
                // `.deleting/` and step 1 above reclaims it on a later sweep.
                await deletionQueueCollector.drain(entry)
                await insertReapRecord(ReapRecord(
                    kind: .archivedWorktree,
                    repoPath: candidate.repoPath ?? "",
                    worktreePath: candidate.path,
                    apparentBytes: bytes,
                    reapedAt: now()
                ))
                reaped += 1
                logger.info("""
                gc: reclaimed archived worktree \(candidate.path, privacy: .public)
                """)
            }
        }

        // 3. Registrations that outlived their directory.
        await pruneStaleRegistrations(
            repoPathByID: repoPathByID, archived: archived,
            dryRun: dryRun, planned: &planned
        )
    }

    /// Prunes repos where an archived row's directory is gone but git still
    /// lists a worktree at that path.
    ///
    /// This is the exact failure the deletion queue exists to end, arriving
    /// through a narrower door: the archive renames the directory and then
    /// prunes, so a prune that throws — or a daemon killed between the two —
    /// leaves a registration with no directory. Nothing else recovers it.
    /// Step 1 only drains bytes, step 2 only sees candidates whose directory
    /// still *exists*, and revive's preflight throws `worktreeAlreadyRegistered`
    /// forever, so the worktree is permanently unrevivable until someone
    /// prunes by hand.
    ///
    /// `git worktree prune` is **repo-wide**, and there is no way to scope it
    /// to one worktree — git offers no such flag. So an archived row with a
    /// missing directory is only the *trigger*: the prune that follows drops
    /// every registration in that repo whose directory git finds missing,
    /// including ones this sweep never looked at. What bounds the blast radius
    /// is not the trigger but git itself. It re-checks directory existence at
    /// prune time rather than trusting this sweep's stale listing, it skips
    /// locked worktrees outright, and it removes only the administrative entry
    /// — never a directory. So the collateral entries it drops are ones whose
    /// directory is genuinely gone at that instant, which is the same
    /// wreckage this method exists to clear.
    ///
    /// The residual case is a worktree on a temporarily unmounted volume:
    /// git sees the directory as missing and prunes a registration the user
    /// still wants. `git worktree lock` is git's own designated mitigation for
    /// exactly that, and prune honors it.
    ///
    /// Repo selection is still narrow: a repo with no archived row whose
    /// directory is gone is never pruned at all.
    private func pruneStaleRegistrations(
        repoPathByID: [UUID: String], archived: [Worktree],
        dryRun: Bool, planned: inout [String]
    ) async {
        var goneByRepo: [String: [String]] = [:]
        for row in archived where !FileManager.default.fileExists(atPath: row.localPath) {
            guard let repoID = row.repoID, let repoPath = repoPathByID[repoID] else { continue }
            goneByRepo[repoPath, default: []].append(row.localPath)
        }

        for (repoPath, paths) in goneByRepo.sorted(by: { $0.key < $1.key }) {
            guard let entries = try? await git.worktreeListDetailed(repoPath: repoPath) else {
                logger.warning("""
                gc: worktree listing failed for \(repoPath, privacy: .public) — \
                cannot check for stale registrations this sweep
                """)
                continue
            }
            // Both sides through `resolvedPath`: git's listing is canonical,
            // while the row's path names a directory that no longer exists,
            // so a plain `realpath` on it would resolve nothing.
            let registered = Set(entries.map { deletionQueueCollector.resolvedPath($0.path) })
            let stale = paths.filter { registered.contains(deletionQueueCollector.resolvedPath($0)) }
            guard !stale.isEmpty else { continue }

            for path in stale {
                planned.append("PRUNE stale-registration \(path)")
            }
            guard !dryRun else { continue }
            do {
                try await git.worktreePrune(repoPath: repoPath)
                logger.info("""
                gc: pruned \(stale.count, privacy: .public) stale registration(s) \
                in \(repoPath, privacy: .public)
                """)
            } catch {
                logger.error("""
                gc: prune failed for \(repoPath, privacy: .public): \(error, privacy: .public)
                """)
            }
        }
    }

    /// Scratchpad reconciliation: archived TBD worktrees whose directory is
    /// already gone but whose Claude Code scratchpad survives. Mirrors the
    /// same keep-biased `dryRun`/`gcEnabled` gate as the agent-worktree loop.
    /// `archived` is the sweep's single read of the archived rows, shared with
    /// `reclaimDeletionQueue`, which wants the complementary half of the same
    /// list. `repos` is the sweep's own already-loaded repo list, reused here to
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
        repos: [Repo], archived: [Worktree], dryRun: Bool,
        planned: inout [String], reaped: inout Int
    ) async {
        let repoPathByID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.path) })
        // Narrowed to local rows, and that is load-bearing rather than
        // tidiness: "its directory is already gone" is the whole reap
        // criterion, and a remote row's path — the synthetic `remote://` URI —
        // is absent from disk by construction, so every archived remote lane
        // would otherwise be a standing reap candidate on every sweep. The
        // narrowing happens here rather than at the caller's shared read
        // because `reclaimDeletionQueue` consumes that same list and asks a
        // different question of it.
        let gone = archived
            .compactMap(LocalWorktree.init)
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

    /// Reclaims per-profile config directories under `~/tbd/profiles/` whose
    /// `model_profiles` row is gone, and purges quarantine entries past the
    /// retention window.
    ///
    /// The two halves answer to different switches, and that split is
    /// deliberate. **Classifying** an orphan is gated by
    /// `gcProfileDirsEnabled` on top of `gcEnabled`: unlike the other
    /// collectors' targets, these directories hold per-profile credentials and
    /// user content with no other copy, so reaping quarantines rather than
    /// deletes and the classifier soaks behind its own switch before
    /// graduating. **Purging** the quarantine is not classification of a user
    /// resource at all — it is cleanup of GC's own artifacts, of data this
    /// sweep already moved aside — so it runs whenever the sweep runs, i.e.
    /// under `gcEnabled` alone. Turning the classifier off ends a soak; it must
    /// never strand credentials in `.reaped/` indefinitely, since "the same
    /// sweep expires the quarantine" is the whole basis on which quarantining
    /// was preferred to deleting outright.
    ///
    /// `dryRun` bypasses the flag exactly as `sweep` lets it bypass
    /// `gcEnabled`: planning is read-only, and someone deciding whether to
    /// enable a default-off flag needs to see what enabling it would reclaim
    /// before flipping it. A NON-dry run still requires the flag.
    private func reclaimProfileDirs(
        config: Config, dryRun: Bool, planned: inout [String], reaped: inout Int
    ) async {
        if config.gcProfileDirsEnabled || dryRun {
            await reapOrphanProfileDirs(
                config: config, dryRun: dryRun, planned: &planned, reaped: &reaped
            )
        }

        // Quarantine expiry — the second half of the bargain. Without it the
        // quarantine grows unboundedly, which is the disease this phase treats.
        for path in profileDirCollector.expiredQuarantineEntries(
            retentionDays: config.gcSnapshotRetentionDays
        ) {
            planned.append("PURGE quarantine \(path)")
            guard !dryRun else { continue }
            _ = profileDirCollector.purge(quarantinePath: path)
        }
    }

    /// The classifier arm of the profile-dir phase: enumerate candidates, gate
    /// them, and quarantine what is eligible. Runs only with
    /// `gcProfileDirsEnabled` on (or in a dry run, which plans without acting).
    ///
    /// Every DB read lives here rather than in the collector (the same division
    /// as `DeletionQueueCollector`), and a failed read skips the whole arm —
    /// the keep-favoring direction every other gate in this sweep takes.
    /// Directories are enumerated BEFORE the rows are read, so a profile
    /// created mid-sweep is always in the row set and can never be classified
    /// as an orphan.
    private func reapOrphanProfileDirs(
        config: Config, dryRun: Bool, planned: inout [String], reaped: inout Int
    ) async {
        let candidates = profileDirCollector.candidates()
        guard let profiles = try? await db.modelProfiles.list(),
              let terminals = try? await db.terminals.list() else {
            logger.warning("gc: profile-dir phase skipped — DB read failed")
            return
        }
        let known = Set(profiles.map(\.id))
        // A terminal row keeps its `profile_id` after the profile is deleted,
        // so a live (or hibernated, resumable) session can still be pointing
        // `CLAUDE_CONFIG_DIR` at this directory. Deliberately stricter than the
        // interactive delete path: a background sweep yanking credentials out
        // from under a running session is worse than a user doing it knowingly.
        let referenced = Set(terminals.compactMap(\.profileID))

        for candidate in candidates {
            switch profileDirCollector.decide(
                candidate, knownProfileIDs: known, referencedProfileIDs: referenced,
                graceSeconds: config.gcGraceSeconds
            ) {
            case .keep(let reason):
                planned.append("KEEP \(reason) \(candidate.path)")
                logger.debug("""
                gc: keep \(reason, privacy: .public) \(candidate.path, privacy: .public)
                """)
            case .reap:
                planned.append("REAP profile-dir \(candidate.path)")
                // This arm's guard is `gcProfileDirsEnabled || dryRun`, so every
                // line below this point runs only with the flag actually on.
                guard !dryRun else { continue }
                await beforeProfileDirReap?()
                // Re-read immediately before acting: the candidate list and the
                // row snapshot above are exactly that, and a profile recreated
                // with this UUID in between must not have its directory pulled
                // out from under it. Both non-reap outcomes keep the directory,
                // and they are kept distinct on purpose — a row that exists
                // again, and a read that never answered. Collapsing a thrown
                // read into "no row" would reap on exactly the evidence that
                // says nothing, inverting this sweep's fail-toward-keeping
                // direction.
                do {
                    if try await db.modelProfiles.get(id: candidate.profileID) != nil {
                        planned.append("KEEP row-appeared \(candidate.path)")
                        logger.info("""
                        gc: keep row-appeared \(candidate.path, privacy: .public) — \
                        a profile row with this id exists again since this sweep listed it
                        """)
                        continue
                    }
                } catch {
                    planned.append("KEEP row-read-failed \(candidate.path)")
                    logger.warning("""
                    gc: keep row-read-failed \(candidate.path, privacy: .public) — \
                    the pre-reap profile-row re-read failed: \
                    \(String(describing: error), privacy: .public)
                    """)
                    continue
                }
                guard let record = await profileDirCollector.reap(candidate) else {
                    planned.append("KEEP quarantine-failed \(candidate.path)")
                    continue
                }
                // The Claude Code credentials item is keyed on the ORIGINAL
                // config dir path, which the rename just invalidated — delete it
                // now or it is unreachable garbage forever. `errSecItemNotFound`
                // is success: there was nothing to clean.
                let configDirPath = candidate.path + "/claude"
                let status = credentialsKeychain.deleteCredentials(forConfigDirPath: configDirPath)
                if status != errSecSuccess && status != errSecItemNotFound {
                    logger.warning("""
                    gc: failed to delete Claude credentials for \
                    \(configDirPath, privacy: .public): OSStatus \(status, privacy: .public)
                    """)
                }
                await insertReapRecord(record)
                reaped += 1
            }
        }
    }

    // MARK: - Orphaned processes

    /// Reclaims processes that outlived the worktree they were rooted in —
    /// `disown`ed and `nohup`ed jobs reparented to launchd, which no pane,
    /// tmux server or `AgentReaper` structure can reach
    /// (`docs/specs/2026-08-18-orphan-process-gc-design.md`).
    ///
    /// Gated by `gcOrphanProcessesEnabled` on top of `gcEnabled`, the same
    /// shape `reclaimProfileDirs` uses and for the same reason: this is the
    /// only GC phase that signals processes rather than moving bytes, and what
    /// it misjudges cannot be restored. `dryRun` bypasses the flag exactly as
    /// `sweep` lets it bypass `gcEnabled` — someone deciding whether to enable
    /// a default-off flag needs to see what enabling it would reclaim first —
    /// and touches nothing either way.
    ///
    /// Every input skips the phase rather than proceeding on a partial
    /// picture: a `ps` snapshot that could not be taken, and either of the two
    /// row reads. That is the keep-favoring direction every other gate in this
    /// sweep takes.
    ///
    /// Both row reads happen HERE rather than being handed down from `sweep`,
    /// and back to back, so the live list and the archived list are one view of
    /// one instant. The sweep's own `archived` list is taken before the
    /// deletion-queue, scratchpad and profile-dir phases have run — `du` shells
    /// and Keychain calls, so a wide window — and a worktree archived inside
    /// that window would be missing from the old `archived` list while already
    /// excluded from the fresh live list, leaving the phase to judge it on two
    /// readings that disagree. Reading both together closes that. A failure on
    /// either read skips the phase and says so, where `sweep`'s `try? … ?? []`
    /// would have read "no archived worktrees" and reported a clean sweep of a
    /// phase that never ran.
    private func reclaimOrphanProcesses(
        config: Config, repos: [Repo], live: LiveCWDs,
        dryRun: Bool, planned: inout [String], reaped: inout Int
    ) async {
        guard config.gcOrphanProcessesEnabled || dryRun else { return }

        // Stamped BEFORE the reading, so the start instants derived from it
        // sit no later than the truth — the direction that widens apparent
        // drift at signal time rather than hiding it.
        let processesCapturedAt = now()
        guard let processes = await processSnapshot() else {
            logger.error("gc: ps unavailable this sweep — skipping the orphan-process phase")
            planned.append("KEEP ps-unavailable orphan-processes")
            return
        }
        guard let liveRows = try? await db.worktrees.listLocal(excludeArchived: true),
              let archived = try? await db.worktrees.list(status: .archived) else {
            logger.warning("gc: orphan-process phase skipped — DB read failed")
            planned.append("KEEP db-unavailable orphan-processes")
            return
        }

        let (roots, repoPathByPool) = orphanProcessRoots(
            repos: repos, archived: archived, liveRows: liveRows)
        let candidates = orphanProcessCollector.candidates(
            processes: processes,
            cwdByPID: live.cwdByPID,
            cwdsCapturedAt: live.capturedAt,
            roots: roots,
            ourUID: getuid(),
            ourPID: getpid(),
            graceSeconds: config.gcGraceSeconds
        )
        guard !candidates.isEmpty else { return }

        let protected = orphanProcessCollector.protectedPIDs(
            processes: processes, ourPID: getpid(), ourUID: getuid())
        // Every tree is planned from the ONE snapshot before anything is
        // signalled, so the plan is a single consistent reading of the process
        // graph rather than one that interleaves with its own destruction.
        // It does not by itself bound how stale a pid can be by the time it is
        // signalled — each reap below blocks for up to
        // `graceAttempts × pollInterval` before the next one starts — which is
        // why `reap` re-reads identities immediately before each volley.
        let plan = candidates.map { candidate in
            (candidate, orphanProcessCollector.descendantClosure(
                of: candidate.pid, processes: processes, protected: protected))
        }
        // The start instant recorded for every pid in the plan. `reap` refuses
        // to signal a pid whose live start instant no longer matches, which is
        // what keeps a pid the kernel reissued mid-sweep — to a descendant slot
        // or to a late candidate's root — out of the volley.
        let plannedStarts = OrphanProcessCollector.startInstants(
            processes, capturedAt: processesCapturedAt)
        for (candidate, tree) in plan {
            planned.append(
                "REAP orphan-process pid=\(candidate.pid) tree=\(tree.count) \(candidate.rootPath)")
        }
        // This phase's guard is `gcOrphanProcessesEnabled || dryRun`, so every
        // line below runs only with the flag actually on.
        guard !dryRun else { return }
        for (candidate, tree) in plan {
            guard let record = await orphanProcessCollector.reap(
                candidate, tree: tree, plannedStarts: plannedStarts,
                repoPath: Self.repoPath(forRoot: candidate.rootPath, in: repoPathByPool)
            ) else {
                planned.append("KEEP nothing-signalled \(candidate.rootPath)")
                continue
            }
            await insertReapRecord(record)
            reaped += 1
        }
    }

    /// The TBD-managed path universe this sweep classifies cwds against, plus
    /// a pool-to-repo map so a reap record can still name the owning repo.
    ///
    /// Every path goes through `DeletionQueueCollector.resolvedPath`, which
    /// walks up to the deepest ancestor that exists and canonicalizes that.
    /// Both sides have to be resolved because `lsof` reports fully resolved
    /// paths (`/private/var/...`), and a plain `realpath` would resolve nothing
    /// for an archived row whose directory is already gone.
    private func orphanProcessRoots(
        repos: [Repo], archived: [Worktree], liveRows: [LocalWorktree]
    ) -> (TBDProcessRoots, [String: String]) {
        let layout = WorktreeLayout()
        var pools: [String] = []
        var repoPathByPool: [String: String] = [:]
        var repoPathByID: [UUID: String] = [:]
        for repo in repos {
            repoPathByID[repo.id] = repo.path
            for prefix in layout.legacyAndCanonicalPrefixes(for: repo) {
                let resolved = deletionQueueCollector.resolvedPath(prefix)
                pools.append(resolved)
                repoPathByPool[resolved] = repo.path
            }
        }
        // The scratch-worktree pool is TBD's outright, and belongs to no repo —
        // hence no `repoPathByPool` entry, which stamps the record with `""`
        // the same way the scratchpad phase does.
        pools.append(deletionQueueCollector.resolvedPath(TBDConstants.scratchDir.path))
        // The Claude scratchpad base is SHARED, not owned. Claude Code creates
        // one directory there per project it has ever run in, and TBD manages
        // almost none of them — a single census of one developer machine found
        // 86 entries, of which 9 named no worktree at all (plain checkouts, a
        // home directory, and loose files). A pool is where TBD's own
        // `.deleting/` queues live and the only place an entry carrying no row
        // is reclaimable at all; TBD queues no deletions here, so listing this
        // base as a pool would extend that claim over a tree that is mostly
        // other software's. `ScratchpadCollector.reconcile` already takes the
        // whitelist side here for a merely destructive operation ("Unrelated
        // directories in the base are untouched"); this phase kills processes,
        // so it takes the same side.
        var sharedRoots = [deletionQueueCollector.resolvedPath(scratchpadBase.path)]

        // `adoptWorktree` inserts a row at a path the user chose, so an adopted
        // worktree sits under no pool at all. `ownership(ofCWD:roots:)` gates on
        // pool-or-shared-root membership BEFORE it consults `dead`, so without
        // an entry here a process inside an archived adopted worktree would
        // classify `.outside` forever — the exact leak this phase exists to
        // close, for that whole class of worktree.
        //
        // The row's own path goes in as a SHARED root, never as a pool, and
        // never its parent directory. A pool means "TBD owns this tree
        // outright" — it is where TBD's own `.deleting/` queues live, and the
        // only place an entry carrying no row is reclaimable at all — and that
        // is false of a directory the user picked: its neighbours are a home
        // directory's, a projects folder's, someone else's checkouts. A shared
        // root classifies only what an explicit `live`/`dead` entry names,
        // which is precisely the adopted worktree itself and nothing beside
        // it, the same line the Claude scratchpad base above is drawn on.
        //
        // `reclaimDeletionQueue` widens its own set from adopted rows for the
        // same reason; it can take the parent because draining a `.deleting/`
        // entry TBD itself renamed needs no provenance gate, while killing a
        // process does.
        for row in liveRows + archived.compactMap(LocalWorktree.init) {
            let resolved = deletionQueueCollector.resolvedPath(row.path)
            guard !pools.contains(where: { Self.isUnder(resolved, prefix: $0) }) else { continue }
            sharedRoots.append(resolved)
            // No pool contains this path, so `repoPath(forRoot:in:)` would
            // stamp the reap record with `""`. The row names its repo directly,
            // so map the worktree path itself; longest-prefix lookup means the
            // entry answers for exactly this worktree and nothing above it.
            if let repoID = row.repoID, let repoPath = repoPathByID[repoID] {
                repoPathByPool[resolved] = repoPath
            }
        }

        // A worktree's Claude scratchpad answers to the same owner as the
        // worktree itself — `ScratchpadCollector`'s slug is derived from the
        // worktree path, so the owner is always recoverable. Classifying the
        // scratchpad alongside its worktree is what makes an archived
        // worktree's scratchpad reclaimable and a live one's explicitly not,
        // rather than leaving a directory the sweep can see go unjudged.
        func scratchpadPath(forWorktreePath path: String) -> String {
            deletionQueueCollector.resolvedPath(
                scratchpadBase.appendingPathComponent(
                    ScratchpadCollector.slug(forWorktreePath: path)).path)
        }
        let livePaths = liveRows.flatMap {
            [deletionQueueCollector.resolvedPath($0.path), scratchpadPath(forWorktreePath: $0.path)]
        }
        let deadRoots = archived
            .compactMap(LocalWorktree.init)
            .flatMap {
                [
                    DeadWorktreeRoot(
                        path: deletionQueueCollector.resolvedPath($0.path),
                        archivedAt: $0.archivedAt),
                    DeadWorktreeRoot(
                        path: scratchpadPath(forWorktreePath: $0.path),
                        archivedAt: $0.archivedAt),
                ]
            }
        return (
            TBDProcessRoots(
                pools: pools, sharedRoots: sharedRoots, live: livePaths, dead: deadRoots),
            repoPathByPool
        )
    }

    /// The repo whose pool owns `root`, or `""` when none does (a scratch
    /// worktree, a scratchpad, or a repo row that has since been removed).
    /// Longest matching pool wins, so nested pools resolve to the inner one.
    private static func repoPath(forRoot root: String, in repoPathByPool: [String: String]) -> String {
        var best: (pool: String, repo: String)?
        for (pool, repo) in repoPathByPool where root == pool || root.hasPrefix(pool + "/") {
            if best == nil || pool.count > best!.pool.count {
                best = (pool, repo)
            }
        }
        return best?.repo ?? ""
    }

    /// `path` is `prefix` itself or strictly below it. Component-wise, so
    /// `/a/pool-2` is never read as living under `/a/pool` — the same rule
    /// `OrphanProcessCollector` classifies with, so a row this method judges
    /// pool-covered is exactly one the collector would too.
    private static func isUnder(_ path: String, prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        return path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }

    /// The sweep's planning `ps` snapshot, or `nil` when it could not be
    /// taken — which skips the orphan-process phase, never "there are no
    /// orphans".
    private func processSnapshot() async -> [ProcessSnapshotEntry]? {
        await processSnapshotProvider()
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
        // `listLocal` for the same reason the sweep's own reconciliation
        // narrows: a remote row's synthetic `remote://` path is absent from
        // disk by construction, which is exactly the shape `reconcile` reads
        // as "the worktree is gone, reap its scratchpad".
        guard let rows = try? await db.worktrees.listLocal(repoID: repoID) else { return }
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
        // Exhaustive and default-less on purpose: a new `ReapKind` must not
        // silently inherit either answer — it has to be classified here.
        switch record.kind {
        case .agentWorktree:
            break
        case .scratchpad, .archivedWorktree, .profileDir:
            // Directory-shaped kinds with no way back: a bare tmp dir has
            // nothing to recreate it from, an archived worktree's directory was
            // drained, and a quarantined profile dir's row is already gone.
            throw OrphanGCError.unsupportedKind(record.kind)
        case .orphanProcess:
            // A killed process cannot be restored at all. The record is an
            // audit trail, not an undo.
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
    private func liveCWDs() async -> LiveCWDs? {
        if let liveCWDsProvider {
            guard let paths = await liveCWDsProvider() else { return nil }
            // Two seams rather than one so every existing test keeps injecting
            // a plain `[String]`. An injected path list with no injected map
            // yields an EMPTY map, which makes the orphan-process phase find no
            // candidates — the keep-favoring reading. It is never read as "this
            // process is not in a worktree", because candidacy requires a cwd
            // that IS under a dead root; a missing entry can only subtract.
            guard let processCWDsProvider else {
                return LiveCWDs(paths: paths, cwdByPID: [:], capturedAt: now())
            }
            guard let map = await processCWDsProvider() else { return nil }
            return LiveCWDs(paths: paths, cwdByPID: map, capturedAt: now())
        }
        return await Self.realLiveCWDs(capturedAt: now())
    }

    /// Real `lsof`-backed live-cwd provider: runs `lsof -d cwd -Fn` under a
    /// 60s deadline and hands the outcome to `parseLiveCWDs`. A spawn failure
    /// is the same "unavailable" sentinel as a timeout: `nil`, skip the sweep.
    private static func realLiveCWDs(capturedAt: Date) async -> LiveCWDs? {
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
        return parseLiveCWDs(outcome, capturedAt: capturedAt)
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
    static func parseLiveCWDs(
        _ outcome: BoundedProcessOutcome, capturedAt: Date = Date()
    ) -> LiveCWDs? {
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
            var cwdByPID: [Int32: String] = [:]
            // The `p<pid>` header the old parser discarded. Retaining it yields
            // a pid-to-cwd map for every process on the machine at no
            // additional cost, which is what the orphan-process phase runs on.
            var currentPID: Int32?
            for line in text.split(separator: "\n") {
                if line.hasPrefix("p") {
                    currentPID = Int32(line.dropFirst())
                    continue
                }
                guard line.hasPrefix("n") else { continue }
                let raw = String(line.dropFirst())
                guard !raw.isEmpty else { continue }
                let canonical = AgentWorktreeCollector.canon(raw)
                if let pid = currentPID {
                    cwdByPID[pid] = canonical
                }
                if seen.insert(canonical).inserted {
                    result.append(canonical)
                }
            }
            return LiveCWDs(paths: result, cwdByPID: cwdByPID, capturedAt: capturedAt)
        }
    }
}

/// One sweep's reading of `lsof -d cwd -Fn`, in both shapes its consumers
/// need: the deduped path list the directory collectors gate on, and the
/// pid-to-cwd map the orphan-process collector classifies against. Both come
/// from the SAME single pass — the pid header was always in the output and was
/// simply discarded.
///
/// The whole value being `nil` is the "unavailable" sentinel that skips the
/// sweep. It is never partially available: a timeout, a non-zero exit or
/// unparseable output invalidate both halves together.
struct LiveCWDs: Sendable, Equatable {
    /// Canonicalized cwds, deduped, in first-seen order.
    var paths: [String]
    /// Canonicalized cwd per pid.
    var cwdByPID: [Int32: String]
    /// When the pass was read. The orphan-process phase joins `cwdByPID` to a
    /// `ps` snapshot taken later in the same sweep, by pid alone, and macOS
    /// recycles pids — so it needs to know how stale this reading is before it
    /// trusts a pid to still mean the same process.
    var capturedAt: Date
}
