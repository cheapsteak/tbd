import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "claude-trust")

/// Pre-accepts Claude Code's "Do you trust the files in this folder?" dialog for
/// TBD-owned scratch spaces.
///
/// Claude Code persists the folder-trust decision per-directory in
/// `<CLAUDE_CONFIG_DIR>/.claude.json` under
/// `projects["<absolute-cwd-path>"].hasTrustDialogAccepted = true`. Scratch dirs
/// are brand new, TBD-created, empty directories each time, so that key is always
/// absent and Claude prompts on every launch. Since TBD owns the directory, the
/// trust gate has no security value there — this seeder pre-writes the accepted
/// flag so the prompt never appears.
///
/// This is a separate gate from `--dangerously-skip-permissions`, which does NOT
/// suppress the trust dialog. There is no CLI flag or env var for it; pre-seeding
/// the JSON key is the only mechanism.
///
/// Known limitation (degrades gracefully to the status quo): when a user sets
/// `CLAUDE_CONFIG_DIR` only in their interactive shell rc (e.g. `.zshrc`) and uses
/// no TBD model profile, the daemon can't observe that value — it isn't in the
/// daemon's own environment. The seed then lands in `~/.claude.json` while the
/// spawned pane reads config from the shell-rc dir, so the trust prompt still
/// appears. This is no worse than the pre-seeder behavior and is unresolvable from
/// the daemon side, so we accept it.
enum ClaudeTrustSeeder {
    /// Pre-accept Claude Code's folder-trust dialog for a scratch worktree by
    /// writing `projects["<path>"].hasTrustDialogAccepted = true` into the
    /// effective config dir's `.claude.json`. No-op for non-scratch worktrees.
    ///
    /// Best-effort: never throws (logs on failure). Idempotent. Preserves all
    /// existing top-level keys and all existing keys inside the target project
    /// entry via read-merge-write. Leaves a malformed `.claude.json` untouched.
    static func ensureTrustedForScratch(
        worktree: Worktree,
        profileConfigDir: String?,
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        // THE gate: only scratch spaces get pre-seeded. Non-scratch worktrees
        // live in real repos where the user may legitimately want the trust
        // prompt, so we never touch their config.
        guard worktree.isScratch else { return }

        // Resolve the effective config dir the same way Claude Code does:
        // an explicit profile config dir wins, then CLAUDE_CONFIG_DIR, then the
        // home directory (where Claude reads `~/.claude.json` by default).
        // Mirror `claudeProjectsRoot`'s empty-string guard so a blank profile
        // path falls through to the env/home fallback.
        let effectiveConfigDir: String
        if let profileConfigDir, !profileConfigDir.isEmpty {
            effectiveConfigDir = profileConfigDir
        } else if let envConfigDir = environment["CLAUDE_CONFIG_DIR"], !envConfigDir.isEmpty {
            effectiveConfigDir = envConfigDir
        } else {
            effectiveConfigDir = homeDirectory
        }

        let configDirURL = URL(fileURLWithPath: effectiveConfigDir, isDirectory: true)
        let claudeJSONPath = configDirURL.appendingPathComponent(".claude.json")

        // Project keys to seed. `worktree.path` is the cwd tmux launches the pane
        // in. If the symlink-resolved form differs, seed both — harmless, and it
        // defends against a cwd/symlink mismatch between what TBD stores and what
        // Claude derives at runtime.
        var projectKeys = [worktree.path]
        let resolvedPath = URL(fileURLWithPath: worktree.path).resolvingSymlinksInPath().path
        if resolvedPath != worktree.path {
            projectKeys.append(resolvedPath)
        }

        let fm = FileManager.default

        // Read-merge-write, preserving every existing key. If the file exists but
        // is malformed JSON, do NOT clobber it — log and return (best-effort).
        var topLevel: [String: Any] = [:]
        if fm.fileExists(atPath: claudeJSONPath.path) {
            guard let existing = try? Data(contentsOf: claudeJSONPath) else {
                logger.warning("could not read \(claudeJSONPath.path, privacy: .public); skipping trust seed")
                return
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                logger.warning("malformed .claude.json at \(claudeJSONPath.path, privacy: .public); leaving untouched")
                return
            }
            topLevel = parsed
        }

        // Skip the write entirely when every target key is already trusted. The
        // early return avoids clobbering a concurrently-running ambient Claude's
        // write to this SHARED file: our atomic rename from a slightly-stale read
        // would drop whatever that process wrote (history, numStartups, project
        // state) between our read and our write. Returning here collapses writes
        // to at most once per new scratch path instead of once per spawn, keeping
        // us within the same infrequent-writer envelope Claude's own multi-instance
        // writes already tolerate.
        let existingProjects = (topLevel["projects"] as? [String: Any]) ?? [:]
        let allAlreadyTrusted = projectKeys.allSatisfy { key in
            (existingProjects[key] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true
        }
        if allAlreadyTrusted { return }

        var projects = existingProjects
        for key in projectKeys {
            var entry = (projects[key] as? [String: Any]) ?? [:]
            entry["hasTrustDialogAccepted"] = true
            projects[key] = entry
        }
        topLevel["projects"] = projects

        do {
            try fm.createDirectory(at: configDirURL, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: topLevel, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: claudeJSONPath, options: [.atomic])
            logger.debug("seeded folder-trust for scratch worktree at \(claudeJSONPath.path, privacy: .public)")
        } catch {
            logger.warning("failed to seed folder-trust at \(claudeJSONPath.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
