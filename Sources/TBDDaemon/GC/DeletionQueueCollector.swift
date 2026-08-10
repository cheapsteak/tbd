import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// An archive that never finished: a worktree row reads `.archived` but its
/// directory is still on disk. `allowedPrefixes` are the TBD-owned locations
/// this particular worktree could legitimately occupy.
public struct InterruptedArchive: Sendable, Equatable {
    public let worktreeID: UUID
    public let path: String
    /// `nil` for a scratch space, which belongs to no repo.
    public let repoPath: String?
    public let allowedPrefixes: [String]
    /// As reported by `git worktree list --porcelain`. A locked worktree is
    /// one the user pinned deliberately, and that outranks every other signal.
    public let locked: Bool

    public init(
        worktreeID: UUID, path: String, repoPath: String?,
        allowedPrefixes: [String], locked: Bool
    ) {
        self.worktreeID = worktreeID
        self.path = path
        self.repoPath = repoPath
        self.allowedPrefixes = allowedPrefixes
        self.locked = locked
    }
}

public enum DeletionQueueDecision: Sendable, Equatable {
    /// `reason` is one of `"locked"`, `"not-tbd-prefix"`, `"not-linked"`,
    /// `"no-repo"`, `"live-cwd"`. Each is a spec invariant with its own test.
    case keep(reason: String)
    case reap
}

/// Reclaims worktree directories that outlived their archive.
///
/// Two kinds of work. Entries already sitting in a pool's `.deleting/` queue
/// are unconditionally reclaimable — TBD put them there itself, and the rename
/// that placed them was the point at which the worktree stopped existing.
/// Interrupted archives are directories that a pre-queue archive failed to
/// remove; reclaiming one means finishing that archive with the same mechanism
/// a fresh archive uses, so there is one deletion path rather than two.
///
/// Every gate fails toward keeping. A database row is not proof that TBD
/// created a directory — `adoptWorktree` can point a row at a worktree TBD
/// never made, and adopted worktrees may live anywhere — so provenance must be
/// established from the filesystem, not from the row alone.
public struct DeletionQueueCollector: Sendable {
    let git: GitManager
    let queue: WorktreeDeletionQueue

    public init(git: GitManager, queue: WorktreeDeletionQueue = WorktreeDeletionQueue()) {
        self.git = git
        self.queue = queue
    }

    // MARK: - Queued entries

    public func pendingEntries(pools: [String]) -> [QueuedDeletion] {
        Array(Set(pools)).sorted().flatMap { queue.pending(pool: $0) }
    }

    @discardableResult
    public func drain(_ entry: QueuedDeletion) -> Bool {
        queue.drain(entry)
    }

    // MARK: - Interrupted archives

    /// Archived rows whose directory is still present. The inverse of the
    /// filter the sweep already applies when reconciling scratchpads.
    ///
    /// Resolves lock state with one `worktreeListDetailed` call per repo
    /// rather than one per candidate. A repo whose listing fails contributes
    /// no lock information, and its candidates are treated as locked — a
    /// listing failure must not read as "nothing is locked".
    public func interruptedArchives(
        worktrees: [Worktree],
        repoPathByID: [UUID: String],
        prefixesByRepoID: [UUID: [String]],
        scratchPrefix: String
    ) async -> [InterruptedArchive] {
        let surviving = worktrees.filter {
            $0.status == .archived && FileManager.default.fileExists(atPath: $0.path)
        }

        // repoPath -> (lockedPaths, listingSucceeded)
        var lockState: [String: (locked: Set<String>, ok: Bool)] = [:]
        for repoPath in Set(surviving.compactMap { $0.repoID.flatMap { repoPathByID[$0] } }) {
            if let entries = try? await git.worktreeListDetailed(repoPath: repoPath) {
                let locked = Set(entries.filter(\.locked).map { resolvedPath($0.path) })
                lockState[repoPath] = (locked, true)
            } else {
                lockState[repoPath] = ([], false)
                logger.warning("""
                gc: worktree listing failed for \(repoPath, privacy: .public) — \
                treating its archived leftovers as locked this sweep
                """)
            }
        }

        return surviving.map { wt in
            let repoPath = wt.repoID.flatMap { repoPathByID[$0] }
            let prefixes = wt.repoID.flatMap { prefixesByRepoID[$0] } ?? [scratchPrefix]
            var locked = false
            if let repoPath, let state = lockState[repoPath] {
                locked = !state.ok || state.locked.contains(resolvedPath(wt.path))
            }
            return InterruptedArchive(
                worktreeID: wt.id, path: wt.path,
                repoPath: repoPath, allowedPrefixes: prefixes, locked: locked
            )
        }
    }

    /// Gate order mirrors `AgentWorktreeCollector.decide`: locked, then
    /// namespace, then linkage, then live-cwd. Each check short-circuits the
    /// rest, and every direction favors keeping.
    public func decide(
        _ candidate: InterruptedArchive, liveCWDs: [String]
    ) async -> DeletionQueueDecision {
        if candidate.locked { return .keep(reason: "locked") }

        guard candidate.allowedPrefixes.contains(where: { isUnder(candidate.path, prefix: $0) })
        else {
            return .keep(reason: "not-tbd-prefix")
        }

        if let repoPath = candidate.repoPath, !repoPath.isEmpty {
            // The `.git` file must resolve into this repo's worktree
            // administration — that is what proves the directory is this
            // repo's linked worktree and not something that merely sits here.
            guard await git.isLinkedWorktree(candidatePath: candidate.path, repoPath: repoPath)
            else {
                return .keep(reason: "not-linked")
            }
        } else {
            // A scratch space is not a linked worktree of any repo, so linkage
            // cannot apply and the namespace is the available proof. The
            // prefix check above already established it; a repoless candidate
            // reaching here with a non-scratch prefix is unprovable.
            return .keep(reason: "no-repo")
        }

        if liveCWDs.contains(where: { isUnder($0, prefix: candidate.path) || $0 == candidate.path }) {
            return .keep(reason: "live-cwd")
        }

        return .reap
    }

    /// Finishes the interrupted archive: rename into the queue, then drop the
    /// stale git registration. Returns the queued entry, or `nil` when the
    /// rename failed (the sweep keeps the directory and retries next pass).
    public func reap(_ candidate: InterruptedArchive) async -> QueuedDeletion? {
        let entry: QueuedDeletion
        do {
            entry = try queue.enqueue(worktreePath: candidate.path)
        } catch {
            logger.error("""
            gc: could not queue interrupted archive \(candidate.path, privacy: .public): \
            \(error, privacy: .public)
            """)
            return nil
        }
        if let repoPath = candidate.repoPath, !repoPath.isEmpty {
            do {
                try await git.worktreePrune(repoPath: repoPath)
            } catch {
                logger.error("""
                gc: prune failed for \(repoPath, privacy: .public) after queueing \
                \(candidate.path, privacy: .public): \(error, privacy: .public)
                """)
            }
        }
        return entry
    }

    // MARK: - Helpers

    /// True when `path` is the prefix itself or sits beneath it. Compares
    /// resolved paths so a trailing slash, `..`, or a `/var` -> `/private/var`
    /// style automount symlink cannot smuggle a candidate past the gate.
    func isUnder(_ path: String, prefix: String) -> Bool {
        let p = resolvedPath(path)
        let root = resolvedPath(prefix)
        return p == root || p.hasPrefix(root + "/")
    }

    /// Resolves as much of `path` as exists on disk through `realpath(3)` —
    /// which, unlike `NSString.standardizingPath`, reliably follows macOS's
    /// `/var` -> `/private/var` style automount symlinks — then re-appends
    /// any trailing components that don't exist yet, so a live cwd one level
    /// below a worktree root still compares consistently with the worktree
    /// root itself. `NSString.standardizingPath` alone only performs that
    /// substitution when the full path already resolves, which makes an
    /// existing worktree root and a not-yet-existing path beneath it resolve
    /// to different prefixes — exactly the trap `GitManager.isLinkedWorktree`
    /// documents for `URL.resolvingSymlinksInPath()`.
    func resolvedPath(_ path: String) -> String {
        var suffix: [String] = []
        var current = (path as NSString).standardizingPath
        while !FileManager.default.fileExists(atPath: current), current != "/" {
            suffix.insert((current as NSString).lastPathComponent, at: 0)
            current = (current as NSString).deletingLastPathComponent
        }
        guard let real = realpath(current, nil) else {
            return (path as NSString).standardizingPath
        }
        defer { free(real) }
        let base = String(cString: real)
        return suffix.isEmpty ? base : ([base] + suffix).joined(separator: "/")
    }
}
