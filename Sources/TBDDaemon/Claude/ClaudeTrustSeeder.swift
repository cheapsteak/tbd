import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "claude-trust")

/// Pre-accepts Claude Code's "Do you trust the files in this folder?" dialog for
/// directories whose trust answer TBD already holds.
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
/// The same argument covers a repo's **`.main` worktree**, which TBD did not
/// create: pointing `tbd repo add` at a checkout is itself a deliberate
/// operator trust gesture, so that directory is "one you trust" even though it
/// is not "one TBD made".
///
/// It does **not** cover contents TBD merely *hosted*. A worktree flagged
/// `foreignHead` was checked out from a pull-request head TBD fetched
/// (`refs/pull/<n>/head`) rather than from a branch already present in the
/// operator's repo. TBD created the directory, but the `.claude/settings.json`,
/// hooks, MCP config and `CLAUDE.md` inside it came in with that fetched ref —
/// which may be a third-party fork's. That is precisely what the dialog exists
/// to gate, so these worktrees are never seeded and Claude asks as usual.
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
///   guaranteed. Not user-configurable, and not subject to the `foreignHead`
///   exclusion: a scratch space has no git contents at all.
/// - **Non-scratch worktrees seed only when `autoTrustWorktrees` is on**
///   (`config.auto_trust_worktrees`, default ON) **and the worktree is not
///   `foreignHead`.** These live in real repos with real contents, so an
///   operator who wants Claude to ask anyway can turn the setting off. Turning
///   it off never un-trusts an already seeded path; it only stops future
///   seeding, including for worktrees that were never seeded before.
///
/// This is a separate gate from `--dangerously-skip-permissions`, which does NOT
/// suppress the trust dialog. There is no CLI flag or env var for it; pre-seeding
/// the JSON key is the only mechanism.
///
/// **Concurrency.** `.claude.json` is a single shared file that many worktrees
/// target at once (the six seed call sites fire on create, extra-session
/// restore, terminal create, revive, profile swap and hibernation wake, across
/// unrelated repos and therefore unrelated `RepoSerializer` lanes). The
/// read-merge-write is not atomic on its own, so it runs inside
/// `ClaudeTrustSeeder.writer`, an actor whose critical section covers read →
/// parse → merge → atomic rename. That makes TBD's own seeds safe against each
/// other: two worktrees can never both read the same base and have the loser's
/// key dropped by the winner's rename. See `writer` for what it does *not*
/// cover.
///
/// Known limitation (degrades gracefully to the status quo): when a user sets
/// `CLAUDE_CONFIG_DIR` only in their interactive shell rc (e.g. `.zshrc`) and uses
/// no TBD model profile, the daemon can't observe that value — it isn't in the
/// daemon's own environment. The seed then lands in `~/.claude.json` while the
/// spawned pane reads config from the shell-rc dir, so the trust prompt still
/// appears. This is no worse than the pre-seeder behavior and is unresolvable from
/// the daemon side, so we accept it.
enum ClaudeTrustSeeder {
    /// Pre-accept Claude Code's folder-trust dialog for a worktree whose trust
    /// answer TBD holds, by writing `projects["<path>"].hasTrustDialogAccepted
    /// = true` into the effective config dir's `.claude.json`.
    ///
    /// - Parameter autoTrustNonScratch: the resolved
    ///   `config.autoTrustWorktrees` value (default ON). Governs non-scratch
    ///   worktrees only — scratch spaces seed regardless. The four call sites
    ///   that read config with `try?` pass `config?.autoTrustWorktrees ?? true`,
    ///   so a config-read failure keeps the shipped default rather than
    ///   silently reinstating the stall; the two create-path sites pass a
    ///   non-optional `config.autoTrustWorktrees` from a throwing read that
    ///   already aborts worktree creation on failure, so there is nothing to
    ///   fall back from.
    ///
    /// Best-effort: never throws (logs on failure). Idempotent. Preserves all
    /// existing top-level keys and all existing keys inside the target project
    /// entry via read-merge-write. Leaves a malformed `.claude.json` untouched.
    ///
    /// `async` only because the read-merge-write hops onto `writer` to
    /// serialize; the gate and path resolution below are pure and stay on the
    /// caller.
    static func ensureTrusted(
        worktree: Worktree,
        autoTrustNonScratch: Bool,
        profileConfigDir: String?,
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        // Two-tier gate (see the type doc comment for the full argument):
        // scratch spaces are TBD-owned empty dirs and always seed; a non-scratch
        // worktree's contents come from a repo the operator registered — so the
        // trust answer is equally known — but the operator can opt out of
        // seeding them via `config.auto_trust_worktrees`.
        //
        // The `foreignHead` exclusion is the boundary of the whole argument:
        // TBD vouches for the directory it created, NOT for contents fetched
        // from a ref that was not already in the operator's repo. The flag means
        // exactly that — the contents came from a pull-request head TBD fetched
        // (`refs/pull/<n>/head`) rather than from a local branch. That covers a
        // fork contributor's PR, and also a colleague's same-repo PR whose head
        // branch has not been fetched locally (see `PickerItem` in
        // BranchPickerMerge.swift: every PR-only row sets `checkoutPRHead`).
        // Either way the ref brings its own `.claude/settings.json`, hooks, MCP
        // config and `CLAUDE.md` into a directory TBD made, which is what the
        // trust dialog exists to gate — so let it render. Erring toward asking
        // on a same-repo PR head is the safe direction. Note this is deliberately
        // NOT keyed on `prNumber`: a decorated same-repo PR row stamps a number
        // while checking out an ordinary local branch, and must still seed.
        // It applies to the non-scratch tier only — a scratch space has no git
        // contents to be foreign, and its unconditional tier stays absolute.
        guard worktree.isScratch || (autoTrustNonScratch && !worktree.foreignHead) else { return }

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
        var projectKeys = [worktree.localPath]
        let resolvedPath = URL(fileURLWithPath: worktree.localPath).resolvingSymlinksInPath().path
        if resolvedPath != worktree.localPath {
            projectKeys.append(resolvedPath)
        }

        await writer.seed(
            projectKeys: projectKeys,
            configDirURL: configDirURL,
            claudeJSONPath: claudeJSONPath,
            worktreePath: worktree.localPath)
    }

    /// The process-wide lane every seed's read-merge-write runs on.
    ///
    /// One lane rather than one per config dir: the early return below collapses
    /// writes to at most once per newly-seen path, so contention is negligible
    /// and a lane table would be state to keep for no measurable gain.
    private static let writer = TrustSeedWriter()

    /// Serializes the read → parse → merge → write critical section.
    ///
    /// **What this covers:** TBD's own concurrent seeds. The six call sites fire
    /// from unrelated `RepoSerializer` lanes (and wake / revive / terminal-create
    /// are not serialized against creates at all), so without this two seeds could
    /// read the same base and the loser's key would vanish under the winner's
    /// atomic rename — leaving that worktree stalled on the trust dialog, exactly
    /// the machine-invisible failure the seeder exists to prevent.
    ///
    /// **What this does NOT cover:** an ambient Claude Code process writing the
    /// same `.claude.json`. That is a different OS process; in-process
    /// serialization cannot order against it, and no file lock is taken. The
    /// mitigation there is frequency, not exclusion — see the early return in
    /// `seed(projectKeys:configDirURL:claudeJSONPath:worktreePath:)`.
    actor TrustSeedWriter {
        fileprivate init() {}

        /// Read-merge-write, preserving every existing key. Runs to completion
        /// without suspending, so the actor's serial execution makes the whole
        /// read-through-rename window atomic against other seeds.
        ///
        /// Best-effort: never throws (logs on failure). If the file exists but is
        /// malformed JSON, do NOT clobber it — log and return.
        func seed(
            projectKeys: [String],
            configDirURL: URL,
            claudeJSONPath: URL,
            worktreePath: String
        ) {
            let fm = FileManager.default

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

            // Skip the write entirely when every target key is already trusted,
            // so a repeat spawn / wake / revive of an already-seeded path does no
            // I/O at all. Beyond saving work, this is the only mitigation left for
            // the CROSS-PROCESS case the actor cannot reach: an ambient Claude
            // Code process writes this same shared file, and our atomic rename
            // from a slightly-stale read would drop whatever it wrote (history,
            // numStartups, project state) between our read and our write.
            // Collapsing writes to at most once per newly-seen path — scratch or
            // worktree — instead of once per spawn shrinks that window; it does
            // not close it.
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
                logger.debug("seeded folder-trust for \(worktreePath, privacy: .public) in \(claudeJSONPath.path, privacy: .public)")
            } catch {
                logger.warning("failed to seed folder-trust at \(claudeJSONPath.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
