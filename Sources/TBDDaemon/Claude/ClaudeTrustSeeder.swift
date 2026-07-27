import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "claude-trust")

/// Pre-accepts Claude Code's "Do you trust the files in this folder?" dialog for
/// directories TBD itself created.
///
/// **Why pre-seeding is legitimate, not a bypass.** The dialog asks one
/// question: "is this a project you created, or one you trust?" For a worktree
/// TBD created — from a repo the operator explicitly registered with TBD — the
/// answer is yes *by construction*. TBD holds every fact the dialog is asking
/// about: it knows the directory is brand new, that it made it, and which
/// registered repo it came from. Seeding does not skip the question; it writes
/// the already-known answer through Claude's own config persistence, so the
/// prompt never renders.
///
/// **Why prevention is the only fix.** The trust dialog blocks *before*
/// SessionStart, so no Claude Code hook ever fires while it is up. A session
/// stalled on trust is machine-invisible to TBD — nothing can detect it, and
/// nothing can dismiss it. Fleet worktrees would simply sit there at first
/// spawn. There is no detect-and-recover path; there is only never rendering
/// the dialog.
///
/// Claude Code persists the decision per-directory in
/// `<CLAUDE_CONFIG_DIR>/.claude.json` under
/// `projects["<absolute-cwd-path>"].hasTrustDialogAccepted = true`. A fresh
/// worktree or scratch dir has never been seen at that path, so the key is
/// absent and Claude prompts.
///
/// **Two-tier gate** (`ensureTrusted`):
/// - **Scratch spaces seed unconditionally.** TBD created the directory, owns
///   it, and it is empty — there is nothing there a trust prompt could protect,
///   and the dir is new on every spawn so the prompt would otherwise be
///   guaranteed. Not user-configurable.
/// - **Non-scratch TBD-created worktrees seed only when `autoTrustWorktrees`
///   is on** (`config.auto_trust_worktrees`, default ON). These live in real
///   repos with real contents, so an operator who wants Claude to ask anyway
///   can turn the setting off. Turning it off never un-trusts an already
///   seeded path; it only stops future seeding.
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
    /// Pre-accept Claude Code's folder-trust dialog for a TBD-created worktree
    /// by writing `projects["<path>"].hasTrustDialogAccepted = true` into the
    /// effective config dir's `.claude.json`.
    ///
    /// - Parameter autoTrustNonScratch: the resolved
    ///   `config.autoTrustWorktrees` value (default ON). Governs non-scratch
    ///   worktrees only — scratch spaces seed regardless. Callers pass
    ///   `config?.autoTrustWorktrees ?? true` so a config read failure keeps
    ///   the shipped default rather than silently reinstating the stall.
    ///
    /// Best-effort: never throws (logs on failure). Idempotent. Preserves all
    /// existing top-level keys and all existing keys inside the target project
    /// entry via read-merge-write. Leaves a malformed `.claude.json` untouched.
    static func ensureTrusted(
        worktree: Worktree,
        autoTrustNonScratch: Bool,
        profileConfigDir: String?,
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        // Two-tier gate (see the type doc comment for the full argument):
        // scratch spaces are TBD-owned empty dirs and always seed; non-scratch
        // worktrees are still TBD-created from a registered repo — so the trust
        // answer is equally known — but the operator can opt out of seeding
        // them via `config.auto_trust_worktrees`.
        guard worktree.isScratch || autoTrustNonScratch else { return }

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
            logger.debug("seeded folder-trust for TBD-created worktree at \(claudeJSONPath.path, privacy: .public)")
        } catch {
            logger.warning("failed to seed folder-trust at \(claudeJSONPath.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
