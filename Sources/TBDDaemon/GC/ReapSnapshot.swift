import Foundation
import TBDShared

/// Errors thrown by `ReapSnapshot`'s snapshot/restore orchestration.
public enum ReapSnapshotError: Error, CustomStringConvertible, Equatable {
    /// The snapshot ref was written but a subsequent `listRefs` read didn't
    /// find it — the caller must keep the worktree rather than delete it.
    case verificationFailed(String)
    /// `restore(record:)` was asked to recreate a worktree at a path that
    /// already exists on disk.
    case targetExists(String)
    /// `restore(record:)` had neither a live branch nor a `headSHA` to
    /// recreate the worktree from.
    case nothingToRestore

    public var description: String {
        switch self {
        case .verificationFailed(let ref):
            return "ReapSnapshot: wrote ref \(ref) but could not verify it via listRefs"
        case .targetExists(let path):
            return "ReapSnapshot: restore target already exists: \(path)"
        case .nothingToRestore:
            return "ReapSnapshot: record has neither a live branch nor a headSHA to restore from"
        }
    }
}

/// Orchestrates the orphan-GC "snapshot before delete, restore on demand"
/// lifecycle on top of the `GitManager` primitives from Task 3.
///
/// `snapshotIfNeeded` is the pre-delete safety gate: the spec invariant is
/// that the snapshot ref (when one is needed) is written AND verified
/// present via `listRefs` before returning — any thrown error anywhere in
/// the sequence means the caller must keep the worktree rather than reap it.
public struct ReapSnapshot: Sendable {
    let git: GitManager

    /// Snapshots `worktreePath` if it contains reviewable/unique dirty bytes
    /// or its HEAD isn't reachable from any branch, returning the created ref
    /// name. Because GC has no trusted out-of-worktree bootstrap registration
    /// yet, an in-worktree manifest remains advisory and all dirt is preserved.
    ///
    /// Ignored paths are neither classified nor staged. A snapshot ref is
    /// permanently reachable, so force-adding build trees would grow the
    /// user's repository without preserving any work.
    ///
    /// Throws on any git failure. The caller must treat a throw as "keep the
    /// worktree" — this function never returns having deleted anything.
    public func snapshotIfNeeded(
        worktreePath: String, repoPath: String, headSHA: String, worktreeName: String, now: Date
    ) async throws -> String? {
        let safety = await ArchiveSafetyClassifier(git: git).classify(
            worktreePath: worktreePath,
            knownPublished: true
        )
        let dirty = safety.requiresPreservation
        let reachable = await git.isReachableFromAnyBranch(repoPath: repoPath, sha: headSHA)
        if !dirty && reachable {
            return nil
        }

        let stamp = Self.refTimestamp(now)
        let ref = "refs/tbd/snapshots/\(worktreeName)-\(stamp)"

        if dirty {
            let tree = try await git.stageAllAndWriteTree(worktreePath: worktreePath)
            let commit = try await git.commitTree(
                repoPath: repoPath, tree: tree, parent: headSHA,
                message: "TBD reap snapshot: \(worktreePath) @ \(stamp)"
            )
            try await git.updateRef(repoPath: repoPath, ref: ref, sha: commit)
        } else {
            // Clean but unreachable from any branch: anchor the ref directly
            // at headSHA — a pure `update-ref`, no new commit object.
            try await git.updateRef(repoPath: repoPath, ref: ref, sha: headSHA)
        }

        // VERIFY before the caller may delete anything (spec invariant).
        guard try await git.listRefs(repoPath: repoPath, prefix: ref).contains(ref) else {
            throw ReapSnapshotError.verificationFailed(ref)
        }
        return ref
    }

    /// Recreates the worktree described by `record` (on its branch if the
    /// branch still exists, detached at `record.headSHA` otherwise) and, if
    /// a snapshot was captured, restores that snapshot's content over it.
    public func restore(record: ReapRecord) async throws {
        guard !FileManager.default.fileExists(atPath: record.worktreePath) else {
            throw ReapSnapshotError.targetExists(record.worktreePath)
        }

        var branchArg: String?
        if let branch = record.branch,
           await git.refExists(repoPath: record.repoPath, ref: "refs/heads/\(branch)") {
            branchArg = branch
        }
        guard branchArg != nil || record.headSHA != nil else {
            throw ReapSnapshotError.nothingToRestore
        }

        try await git.worktreeAdd(
            repoPath: record.repoPath,
            path: record.worktreePath,
            branch: branchArg,
            detachAt: branchArg == nil ? record.headSHA : nil
        )

        if let snapshotRef = record.snapshotRef {
            try await git.restoreFromRef(worktreePath: record.worktreePath, ref: snapshotRef)
        }
    }

    /// Formats `date` as `yyyyMMdd-HHmmss` in UTC with a fixed POSIX locale,
    /// so ref names are deterministic regardless of the host's locale/TZ.
    /// `date` is always caller-supplied — never the ambient `Date()` — so
    /// this function (and everything above it) stays reproducible in tests.
    static func refTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
