import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// Enumerates, gates, and reaps Claude Code scratchpad directories
/// (`/private/tmp/claude-<uid>/<slug>`) that TBD's orphan-GC sweep may safely
/// delete.
///
/// Every failure path fails toward KEEPING the scratchpad — this type never
/// deletes anything it isn't certain about. The caller (Task 7's `OrphanGC`
/// actor) persists whatever `cleanUp(_:)` and `reconcile(_:)` return.
public struct ScratchpadCollector: Sendable {
    let base: URL

    public init(base: URL) {
        self.base = base
    }

    /// Computes the slug for a worktree path by replacing all forward slashes
    /// with hyphens. For example: `/Users/chang/tbd` → `-Users-chang-tbd`.
    public static func slug(forWorktreePath path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    /// Event-driven: delete the scratchpad for one known, just-removed worktree
    /// path. `repoPath` is the owning repo's root, stamped onto the resulting
    /// record so it surfaces in the per-repo History UI (`gc.list(repoPath:)`);
    /// pass `""` when the owning repo can't be resolved (fails toward the
    /// record simply not appearing per-repo rather than dropping it).
    /// Returns a `ReapRecord` on success, or `nil` if the scratchpad did
    /// not exist, or if removal failed (directory still exists).
    public func cleanUp(forRemovedWorktreePath path: String, repoPath: String, now: Date) async -> ReapRecord? {
        let slug = Self.slug(forWorktreePath: path)
        let dir = base.appendingPathComponent(slug)

        guard FileManager.default.fileExists(atPath: dir.path) else {
            return nil
        }

        let bytes = await GCDiskUsage.apparentBytes(path: dir.path)

        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            logger.warning(
                "gc: rm failed for \(dir.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return nil
        }

        // Verify the removal actually took. If the directory is still there,
        // fail toward keeping so the retry on the next sweep starts from a
        // consistent state.
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            logger.warning("gc: rm failed for \(dir.path, privacy: .public), will retry next sweep")
            return nil
        }

        logger.info("gc: reaped scratchpad \(dir.path, privacy: .public)")
        return ReapRecord(
            kind: .scratchpad, repoPath: repoPath, worktreePath: dir.path,
            apparentBytes: bytes, reapedAt: now
        )
    }

    /// Reconciliation: for each known `(worktreePath, repoPath)` pair whose
    /// worktree directory no longer exists, delete its scratchpad. Unrelated
    /// directories in the base are untouched. Returns an array of `ReapRecord`
    /// for paths that were successfully cleaned, each stamped with the
    /// `repoPath` of its own pair.
    ///
    /// If the base directory does not exist, this is a no-op (returns empty array).
    public func reconcile(
        knownPaths: [(worktreePath: String, repoPath: String)], now: Date
    ) async -> [ReapRecord] {
        guard FileManager.default.fileExists(atPath: base.path) else {
            return []
        }

        let gone = knownPaths.filter { !FileManager.default.fileExists(atPath: $0.worktreePath) }
        var records: [ReapRecord] = []
        for entry in gone {
            if let record = await cleanUp(
                forRemovedWorktreePath: entry.worktreePath, repoPath: entry.repoPath, now: now
            ) {
                records.append(record)
            }
        }
        return records
    }
}
