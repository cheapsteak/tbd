import Foundation
import TBDShared

/// Finds the statusline the operator would have seen had TBD not overridden it.
///
/// TBD installs its tee through the per-session `--settings` file, and
/// `statusLine` is an object-valued key with no merge-across-scopes behavior:
/// the highest scope wins outright. A `--settings` file outranks
/// `.claude/settings.local.json`, `.claude/settings.json` and the user's global
/// `~/.claude/settings.json`, so on a desk session TBD's entry displaces every
/// statusline the operator can write. This resolver puts it back — whatever
/// would have won becomes the tee's delegate, and the operator sees the status
/// line they configured.
///
/// The scopes are checked in Claude Code's own descending precedence and the
/// first hit wins. Managed/enterprise settings are deliberately **not**
/// consulted: a managed `statusLine` outranks TBD's `--settings` file, so TBD's
/// entry is simply ignored there, the tee never runs, and the denominator stays
/// unknown. That is the correct outcome — the operator's organization owns the
/// slot — and it needs no handling beyond not pretending otherwise.
///
/// Pure and total: a missing, unreadable or malformed file is skipped, never
/// thrown from. A broken settings file must not change what a spawn does.
enum OperatorStatuslineResolver {
    /// - Parameters:
    ///   - perSpawnSettingsJSON: the per-spawn `--settings` fragment, highest.
    ///   - repoSettingsJSON: the per-repo `claude-settings.json` fragment.
    ///   - worktreePath: the session's cwd, for the two project scopes. nil
    ///     skips them.
    ///   - profileConfigDir: the session's `CLAUDE_CONFIG_DIR`, when it runs
    ///     under a model profile. **This is what the user scope means for that
    ///     session** — Claude Code reads its user-scope `settings.json` out of
    ///     `CLAUDE_CONFIG_DIR`, so a desk on a profile has its user scope in the
    ///     profile directory and none at all in the host store. nil (no profile,
    ///     the ambient install) falls back to `claudeHostHome`.
    ///   - environment: resolves `TBD_CLAUDE_HOST_HOME` for the user scope.
    ///   - readFile: injection seam so tests need no real home directory.
    /// - Returns: the `statusLine.command` string of the highest scope that has
    ///   one, or nil when no scope configures a statusline.
    static func resolve(
        perSpawnSettingsJSON: String? = nil,
        repoSettingsJSON: String? = nil,
        worktreePath: String? = nil,
        profileConfigDir: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readFile: (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    ) -> String? {
        // Descending precedence. The fragments come in as strings because they
        // are what the spawn path already holds; the file scopes are read here.
        for json in [perSpawnSettingsJSON, repoSettingsJSON] {
            if let command = command(inSettingsData: json.flatMap { Data($0.utf8) }) {
                return command
            }
        }
        var paths: [String] = []
        if let worktreePath {
            let claudeDir = URL(fileURLWithPath: worktreePath).appendingPathComponent(".claude")
            paths.append(claudeDir.appendingPathComponent("settings.local.json").path)
            paths.append(claudeDir.appendingPathComponent("settings.json").path)
        }
        // The user scope, resolved against the config dir this session will
        // actually run with. Exactly one directory is the user scope for a given
        // session — reading the host store for a profile-backed desk would
        // delegate to a statusline that session never sees, or to none while one
        // exists in the profile.
        let userScopeDir = profileConfigDir.map { URL(fileURLWithPath: $0) }
            ?? TBDConstants.claudeHostHome(environment: environment)
        paths.append(userScopeDir.appendingPathComponent("settings.json").path)
        for path in paths {
            if let command = command(inSettingsData: readFile(path)) {
                return command
            }
        }
        return nil
    }

    /// `statusLine.command` out of one settings document, or nil.
    ///
    /// nil covers all of: no data, not JSON, not an object, no `statusLine`, a
    /// `statusLine` that is not an object, no `command`, and an empty
    /// `command`. Each of those means "this scope configures no statusline we
    /// can delegate to", and the resolver moves on to the next.
    private static func command(inSettingsData data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        guard let statusLine = dict["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return command
    }
}
