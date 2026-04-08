import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "WorktreeLayout")

/// Single source of truth for where TBD stores worktree directories on disk.
///
/// Phase A introduces this helper without wiring it into the create/reconcile
/// paths. Phase C switches `WorktreeLifecycle+Create.swift` and
/// `WorktreeLifecycle+Reconcile.swift` to call it.
///
/// See `docs/worktree-location-design.md` §4a / §5a.
public struct WorktreeLayout: Sendable {

    /// Current on-disk layout version. Bumped when a future release ships a
    /// new filesystem migration. Persisted in the `tbd_meta` table under key
    /// `layout_version` once the migration sweep completes end-to-end.
    public static let currentVersion: Int = 1

    public init() {}

    /// Sanitize a repo display name into a filesystem-safe slot.
    ///
    /// Rules (per design §4a):
    /// - Lowercase everything.
    /// - Replace any char outside `[a-z0-9._-]` with `-`.
    /// - Collapse runs of `-`.
    /// - Trim leading/trailing `-`.
    ///
    /// Empty / `.` / `..` / leading-dot results return empty string; callers
    /// must substitute a fallback (e.g. `repo-<uuid-prefix>`).
    public static func sanitize(_ displayName: String) -> String {
        let lowered = displayName.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        for scalar in lowered.unicodeScalars {
            let c = Character(scalar)
            if c.isASCII, let ascii = c.asciiValue {
                let isAllowed =
                    (ascii >= 0x61 && ascii <= 0x7A) ||  // a-z
                    (ascii >= 0x30 && ascii <= 0x39) ||  // 0-9
                    ascii == 0x2E || ascii == 0x5F || ascii == 0x2D  // . _ -
                out.append(isAllowed ? c : "-")
            } else {
                out.append("-")
            }
        }
        while out.contains("--") {
            out = out.replacingOccurrences(of: "--", with: "-")
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        if out == "." || out == ".." || out.hasPrefix(".") {
            return ""
        }
        return out
    }

    /// The canonical base directory for fresh worktrees of the given repo.
    ///
    /// - Returns `repo.worktreeRoot` verbatim if the override is set.
    /// - Otherwise returns `~/tbd/worktrees/<slot>`.
    public func basePath(for repo: Repo) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let override = repo.worktreeRoot, !override.isEmpty {
            return override
        }
        if let slot = repo.worktreeSlot, !slot.isEmpty {
            return "\(home)/tbd/worktrees/\(slot)"
        }
        // Should never happen — v14 backfills worktree_slot for every existing
        // row and RepoStore.create always assigns one. But a precondition in a
        // long-running daemon is a hard kill, so log loudly and fall back to a
        // UUID-derived path instead.
        logger.fault("Repo \(repo.id, privacy: .public) has neither worktreeRoot nor worktreeSlot — falling back to UUID-derived path")
        let fallbackSlot = "repo-\(repo.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        return "\(home)/tbd/worktrees/\(fallbackSlot)"
    }

    // LEGACY-WORKTREE-LOCATION: remove after 2026-06-01
    // Reads worktrees from <repo>/.tbd/worktrees/ for backward compatibility with
    // worktrees created before the canonical-location switch. New worktrees are
    // always created under ~/tbd/worktrees/<repo>/<name>. After 2026-06-01, all
    // pre-switch worktrees will have archived naturally and this path can be deleted.
    /// Both the canonical (new-layout) and legacy (`<repo>/.tbd/worktrees`)
    /// prefixes a worktree could currently live under. Reconcile matches
    /// against either until the user has fully migrated. Canonical first.
    public func legacyAndCanonicalPrefixes(for repo: Repo) -> [String] {
        let canonical = basePath(for: repo)
        let legacy = (repo.path as NSString).appendingPathComponent(".tbd/worktrees")
        return [canonical, legacy]
    }
}
