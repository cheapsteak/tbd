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

/// Result of one `OrphanGC.sweep(dryRun:)` pass: a human-readable log of every
/// decision made (`KEEP <reason> <path>` / `REAP <kind> <path>`) and a count
/// of directories actually removed (always `0` when `dryRun` is `true`).
public struct GCSweepResult: Sendable, Equatable {
    public var planned: [String]
    public var reaped: Int

    public init(planned: [String], reaped: Int) {
        self.planned = planned
        self.reaped = reaped
    }
}

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
        // OrphanGC always passes live cwds explicitly to `decide(_:liveCWDs:graceSeconds:)`
        // per sweep (one lsof pass), so the collector's own stored closure is
        // never consulted here — it's a harmless placeholder.
        self.agentCollector = AgentWorktreeCollector(git: git, snapshot: snap, liveCWDs: { [] }, now: resolvedNow)
        self.scratchpadCollector = ScratchpadCollector(base: resolvedScratchpadBase)
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
                    if let record = await agentCollector.reap(candidate) {
                        try? await db.reapRecords.insert(record)
                        reaped += 1
                        logger.info("""
                        gc: reaped agent worktree \(candidate.path, privacy: .public) \
                        snapshot=\(record.snapshotRef ?? "none", privacy: .public)
                        """)
                        // The reaped worktree may have had its own Claude Code
                        // scratchpad; clean that up too.
                        if let scratchRecord = await scratchpadCollector.cleanUp(
                            forRemovedWorktreePath: candidate.path, now: now()
                        ) {
                            try? await db.reapRecords.insert(scratchRecord)
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

        await reconcileScratchpads(dryRun: dryRun, planned: &planned, reaped: &reaped)

        // Snapshot retention never runs in dryRun; the outer guard already
        // establishes gcEnabled for any non-dry run.
        if !dryRun {
            await gcOldSnapshots(retentionDays: config.gcSnapshotRetentionDays)
        }

        if reaped > 0 { broadcast(.reapRecordsChanged) }
        return .init(planned: planned, reaped: reaped)
    }

    /// Scratchpad reconciliation: archived TBD worktrees whose directory is
    /// already gone but whose Claude Code scratchpad survives. Mirrors the
    /// same keep-biased `dryRun`/`gcEnabled` gate as the agent-worktree loop.
    private func reconcileScratchpads(
        dryRun: Bool, planned: inout [String], reaped: inout Int
    ) async {
        let knownPaths = ((try? await db.worktrees.list(status: .archived)) ?? []).map(\.path)
        let gonePaths = knownPaths.filter { !FileManager.default.fileExists(atPath: $0) }
        for path in gonePaths {
            let slug = ScratchpadCollector.slug(forWorktreePath: path)
            let dir = scratchpadBase.appendingPathComponent(slug)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            planned.append("REAP scratchpad \(dir.path)")
            // The outer `gcEnabled || dryRun` guard means a non-dry run here
            // always has gcEnabled == true.
            guard !dryRun else { continue }
            if let record = await scratchpadCollector.cleanUp(forRemovedWorktreePath: path, now: now()) {
                try? await db.reapRecords.insert(record)
                reaped += 1
                logger.info("gc: reaped scratchpad \(record.worktreePath, privacy: .public)")
            }
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
    ///
    /// The `gcEnabled` master switch governs ALL GC deletion, including this
    /// event-driven path — one toggle covers both collectors. A config read
    /// failure also skips (fail toward keeping).
    public func scratchpadCleanup(forRemovedWorktreePath path: String) async {
        guard let config = try? await db.config.get(), config.gcEnabled else {
            logger.debug("gc: scratchpad cleanup skipped for \(path, privacy: .public) — gc disabled")
            return
        }
        guard let record = await scratchpadCollector.cleanUp(forRemovedWorktreePath: path, now: now()) else {
            return
        }
        try? await db.reapRecords.insert(record)
        logger.info("gc: reaped scratchpad (event) \(record.worktreePath, privacy: .public)")
        broadcast(.reapRecordsChanged)
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
