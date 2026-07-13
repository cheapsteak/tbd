import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// A Claude Code agent worktree (`<repo>/.claude/worktrees/<name>`) proven —
/// via `GitManager.isLinkedWorktree` — to be a bona fide linked worktree of
/// `repoPath`, and cross-referenced against `git worktree list --porcelain`
/// for its HEAD/branch/lock state.
public struct AgentWorktreeCandidate: Sendable, Equatable {
    public var path: String
    public var repoPath: String
    public var branch: String?
    public var headSHA: String
    public var locked: Bool

    public init(path: String, repoPath: String, branch: String?, headSHA: String, locked: Bool) {
        self.path = path
        self.repoPath = repoPath
        self.branch = branch
        self.headSHA = headSHA
        self.locked = locked
    }
}

/// The outcome of gating a single `AgentWorktreeCandidate`. Every `.keep`
/// reason below is a spec invariant with a dedicated test: the gate order
/// (locked -> live-cwd -> grace -> reap) always fails toward keeping, and a
/// snapshot failure during `reap(_:)` is reported the same way even though it
/// happens after `decide(_:liveCWDs:graceSeconds:)` already said `.reap`.
public enum GCDecision: Sendable, Equatable {
    /// `reason` is one of: `"locked"` | `"live-cwd"` | `"grace"` |
    /// `"not-linked"` | `"snapshot-failed"`. Only the first three are
    /// produced by `decide(_:liveCWDs:graceSeconds:)` itself — `"not-linked"`
    /// describes directories `candidates(repoPath:)` silently drops, and
    /// `"snapshot-failed"` describes a `reap(_:)` that returned `nil`; both
    /// are surfaced as this same reason vocabulary by callers (Task 7) that
    /// log/persist a decision for every directory they looked at.
    case keep(reason: String)
    case reap(AgentWorktreeCandidate)
}

/// Enumerates, gates, and reaps Claude Code agent worktrees
/// (`<repo>/.claude/worktrees/<name>`) that TBD's orphan-GC sweep may safely
/// delete.
///
/// Every gate in `decide(_:liveCWDs:graceSeconds:)` and every failure path in
/// `reap(_:)` fails toward KEEPING the worktree — this type never deletes
/// anything it isn't certain about. `candidates(repoPath:)` never touches the
/// DB; the caller (Task 7's `OrphanGC` actor) persists whatever `reap(_:)`
/// returns.
public struct AgentWorktreeCollector: Sendable {
    let git: GitManager
    let snapshot: ReapSnapshot
    let now: @Sendable () -> Date

    public init(
        git: GitManager,
        snapshot: ReapSnapshot,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.git = git
        self.snapshot = snapshot
        self.now = now
    }

    /// Lists every directory under `<repoPath>/.claude/worktrees/` that is
    /// proven — via `GitManager.isLinkedWorktree` — to be a linked git
    /// worktree of `repoPath`, cross-referenced against
    /// `git worktree list --porcelain` for its HEAD/branch/lock state.
    ///
    /// A directory that fails the linkage proof (plain `mkdir`'d decoy, a
    /// symlink to the repo root itself, anything without a `gitdir:`-style
    /// `.git` file resolving under `<repoPath>/.git/worktrees/`) is silently
    /// skipped — never touched, never returned. A directory that passes
    /// linkage but isn't in git's own worktree list (already
    /// `git worktree prune`-eligible) is likewise skipped: that's `git
    /// worktree prune`'s job, not this sweep's.
    ///
    /// Both sides of every path comparison go through `canon(_:)` so a
    /// `repoPath` argument built from a symlinked parent (e.g. macOS's
    /// `/var` -> `/private/var`) still lines up with git's own
    /// already-canonical worktree-list output.
    public func candidates(repoPath: String) async -> [AgentWorktreeCandidate] {
        let base = repoPath + "/.claude/worktrees"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        guard let entries = try? await git.worktreeListDetailed(repoPath: repoPath) else { return [] }
        // `uniquingKeysWith:` rather than `uniqueKeysWithValues:` — this is
        // fail-soft, best-effort GC code, so a duplicate canonicalized path
        // (e.g. two `git worktree list` entries somehow resolving to the
        // same realpath) must never crash the sweep; keep the first entry
        // seen and move on.
        let byPath = Dictionary(entries.map { (Self.canon($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        var out: [AgentWorktreeCandidate] = []
        for name in names {
            let p = Self.canon(base + "/" + name)
            guard await git.isLinkedWorktree(candidatePath: p, repoPath: repoPath) else {
                logger.debug("gc: skip \(p, privacy: .public) — not a proven linked worktree")
                continue
            }
            guard let entry = byPath[p] else {
                logger.debug("gc: skip \(p, privacy: .public) — linked but not in worktree list (prune territory)")
                continue
            }
            out.append(AgentWorktreeCandidate(
                path: p, repoPath: repoPath, branch: entry.branch, headSHA: entry.headSHA, locked: entry.locked
            ))
        }
        return out
    }

    /// Gates a single candidate through the five keep-biased checks, in
    /// order, each one short-circuiting the rest: `locked` -> `live-cwd`
    /// (exact match or any path strictly below it) -> `grace` (recent HEAD or
    /// index activity) -> `reap`.
    public func decide(_ c: AgentWorktreeCandidate, liveCWDs: [String], graceSeconds: Int) async -> GCDecision {
        if c.locked {
            logger.debug("gc: keep \(c.path, privacy: .public) — locked")
            return .keep(reason: "locked")
        }
        let wt = c.path
        if liveCWDs.contains(where: { $0 == wt || $0.hasPrefix(wt + "/") }) {
            logger.debug("gc: keep \(c.path, privacy: .public) — live cwd")
            return .keep(reason: "live-cwd")
        }
        let nowDate = now()
        let age = nowDate.timeIntervalSince(Self.lastActivity(worktreePath: wt, now: nowDate))
        if age < Double(graceSeconds) {
            logger.debug("gc: keep \(c.path, privacy: .public) — within grace (age=\(age, privacy: .public)s)")
            return .keep(reason: "grace")
        }
        logger.info("gc: \(c.path, privacy: .public) eligible for reap")
        return .reap(c)
    }

    /// Executes one reap: snapshot-first (any throw here means "keep, don't
    /// touch the directory"), then measure, then delete, then verify the
    /// delete actually took, and only then prune git's stale registration.
    ///
    /// Returns the `ReapRecord` for the caller to persist, or `nil` if a late
    /// gate refused — either the snapshot step threw (kept, nothing was
    /// deleted) or the removal didn't actually take (kept for a retry on the
    /// next sweep).
    public func reap(_ c: AgentWorktreeCandidate) async -> ReapRecord? {
        let name = (c.path as NSString).lastPathComponent
        let ref: String?
        do {
            ref = try await snapshot.snapshotIfNeeded(
                worktreePath: c.path, repoPath: c.repoPath, headSHA: c.headSHA, worktreeName: name, now: now()
            )
        } catch {
            logger.warning(
                "gc: kept \(c.path, privacy: .public) — snapshot failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }

        let bytes = await GCDiskUsage.apparentBytes(path: c.path)
        try? FileManager.default.removeItem(atPath: c.path)

        // Verify the removal actually took BEFORE pruning: if the directory
        // is still there, git's worktree registration must stay intact too,
        // so the retry on the next sweep starts from a consistent state.
        guard !FileManager.default.fileExists(atPath: c.path) else {
            logger.warning("gc: rm failed for \(c.path, privacy: .public), will retry next sweep")
            return nil
        }

        try? await git.worktreePrune(repoPath: c.repoPath)

        logger.info("gc: reaped \(c.path, privacy: .public), snapshotRef=\(ref ?? "none", privacy: .public)")
        return ReapRecord(
            kind: .agentWorktree, repoPath: c.repoPath, worktreePath: c.path,
            branch: c.branch, headSHA: c.headSHA, snapshotRef: ref,
            apparentBytes: bytes, reapedAt: now()
        )
    }

    // MARK: - Helpers

    /// Resolves `path` through POSIX `realpath()`, following every symlink
    /// component (including macOS's `/var` -> `/private/var`, which
    /// `URL.resolvingSymlinksInPath()` does not follow). Falls back to the
    /// original `path` when `realpath()` fails (e.g. the path doesn't exist
    /// yet) so callers always get a usable string rather than `nil`.
    static func canon(_ path: String) -> String {
        guard let cString = realpath(path, nil) else { return path }
        defer { free(cString) }
        return String(cString: cString)
    }

    /// The most recent of two mtimes that change whenever the worktree is
    /// actually used: the `<worktreePath>/.git` file itself (rewritten by
    /// some git operations) and the admin gitdir's `index` file (rewritten by
    /// almost every git operation that touches the working tree — status,
    /// add, commit, checkout). Either file missing (but not both) still
    /// contributes what's readable via `max`.
    ///
    /// If NEITHER mtime is readable at all (both the `.git` file and the
    /// admin index are unreadable/missing), this returns `now` rather than
    /// `Date.distantPast`. `Date.distantPast` would make `decide(_:)`'s age
    /// computation enormous, making an unreadable worktree immediately
    /// grace-*eligible* for reap — exactly backwards for keep-biased GC.
    /// Returning `now` instead makes age ≈ 0, so an unreadable worktree is
    /// treated the same as one just touched: kept by the grace window like
    /// everything else uncertain, not silently fast-tracked for deletion.
    static func lastActivity(worktreePath: String, now: Date) -> Date {
        let gitFile = worktreePath + "/.git"
        let gitFileMtime = mtime(gitFile)

        var indexMtime: Date?
        if let contents = try? String(contentsOfFile: gitFile, encoding: .utf8) {
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "gitdir: "
            if trimmed.hasPrefix(prefix) {
                let gitdir = String(trimmed.dropFirst(prefix.count))
                indexMtime = mtime(gitdir + "/index")
            }
        }

        guard gitFileMtime != nil || indexMtime != nil else {
            return now
        }
        return max(gitFileMtime ?? .distantPast, indexMtime ?? .distantPast)
    }

    private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
