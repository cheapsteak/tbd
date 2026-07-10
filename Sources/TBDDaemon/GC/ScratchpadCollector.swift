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
    /// path. Returns a `ReapRecord` on success, or `nil` if the scratchpad did
    /// not exist, or if removal failed (directory still exists).
    public func cleanUp(forRemovedWorktreePath path: String, now: Date) async -> ReapRecord? {
        let slug = Self.slug(forWorktreePath: path)
        let dir = base.appendingPathComponent(slug)

        guard FileManager.default.fileExists(atPath: dir.path) else {
            return nil
        }

        let bytes = await Self.apparentBytes(path: dir.path)

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
            kind: .scratchpad, repoPath: "", worktreePath: dir.path,
            apparentBytes: bytes, reapedAt: now
        )
    }

    /// Reconciliation: for each known path whose directory no longer exists,
    /// delete its scratchpad. Unrelated directories in the base are untouched.
    /// Returns an array of `ReapRecord` for paths that were successfully cleaned.
    ///
    /// If the base directory does not exist, this is a no-op (returns empty array).
    public func reconcile(knownPaths: [String], now: Date) async -> [ReapRecord] {
        guard FileManager.default.fileExists(atPath: base.path) else {
            return []
        }

        let gonePaths = knownPaths.filter { !FileManager.default.fileExists(atPath: $0) }
        var records: [ReapRecord] = []
        for path in gonePaths {
            if let record = await cleanUp(forRemovedWorktreePath: path, now: now) {
                records.append(record)
            }
        }
        return records
    }

    // MARK: - Helpers

    /// `du -sk`'s apparent-size measurement for `path`, in bytes (the
    /// reported KB * 1024). `nil` on any failure — spawn error, non-zero
    /// exit, timeout, or unparseable output — since a missing byte count is
    /// never worth blocking or retrying a reap over.
    private static func apparentBytes(path: String) async -> Int64? {
        guard let outcome = try? await runBoundedProcess(
            executable: "/usr/bin/du", arguments: ["-sk", path], currentDirectory: nil, timeout: .seconds(60)
        ) else {
            return nil
        }
        guard case .completed(let status, let stdout, _) = outcome, status == 0 else { return nil }
        guard let text = String(data: stdout, encoding: .utf8) else { return nil }
        guard let firstToken = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first,
            let kilobytes = Int64(firstToken)
        else {
            return nil
        }
        return kilobytes * 1024
    }
}
