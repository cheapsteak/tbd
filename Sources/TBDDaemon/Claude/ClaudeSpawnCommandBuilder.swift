import Foundation
import TBDShared

/// Builds the shell command string for spawning (or respawning) a claude terminal.
///
/// Pure function — no DB, no Keychain, no tmux. The only filesystem touch
/// is via the injectable `fileExists` parameter, which defaults to
/// `FileManager.default.fileExists(atPath:)`. Tests can pass a closure to
/// keep the function fully hermetic. The caller is responsible for
/// resolving the profile secret (if any) before invoking.
///
/// Behavior:
/// - `resumeID` non-nil → `claude --resume <id> --dangerously-skip-permissions`
///   with optional trailing initial-prompt arg (delivered atomically with the
///   resume — no post-spawn paste, so it can never land in the wrong process).
///   With `forkSession: true`, ` --fork-session` is appended: Claude Code's
///   `--resume` REUSES the original session ID unless that flag is passed, and
///   the `.fork` swap mode needs a genuinely new ID because the source session
///   stays live (otherwise both processes write the same session JSONL).
/// - `freshSessionID` non-nil → `claude --session-id <id> --dangerously-skip-permissions`
///   with optional `--append-system-prompt` and trailing initial-prompt arg.
/// - Otherwise → `cmd` if set, else `shellFallback`.
///
/// `sessionName`, when non-nil and not blank, adds ` --name <escaped>` to both
/// claude branches (never to `cmd` / `shellFallback`, which are not claude).
/// Callers pass the worktree's display name so the session announces itself
/// under the name the user sees in the app — that is the address peers use for
/// Claude Code's cross-session `ListAgents` / `SendMessage`. Without it a
/// session names itself after its working-directory folder slug, which never
/// matches an app-side rename. The name is fixed at spawn, so a later rename
/// applies at the next respawn or resume. Display names are unvalidated free
/// text, so the name is sanitized here rather than at the rename handler (see
/// `sanitizedSessionName`) — renaming must keep meaning what the user typed.
///
/// If we built a claude command (resume or fresh), `sensitiveEnv` carries the
/// auth + routing env vars for the spawned session (plus
/// `DISABLE_AUTO_UPDATE=true`, an rc-affecting toggle that must reach the
/// process env before .zshrc runs so oh-my-zsh's update prompt can't block
/// the agent spawn):
/// - oauth: `CLAUDE_CONFIG_DIR=<profileDir>` (no auth token; user `/login`s into this dir)
/// - oauth token: `CLAUDE_CODE_OAUTH_TOKEN=<secret>` + `CLAUDE_CONFIG_DIR=<profileDir>`
///   (same isolated dir as oauth; the stored `claude setup-token` authenticates
///   it instead of a `/login`). The token rides tmux's `-e` only — like
///   `ANTHROPIC_API_KEY` it is never a routing key, so it never lands in the
///   pane's `ps` argv.
/// - api key (direct or proxy): `ANTHROPIC_API_KEY=<secret>` + `CLAUDE_CONFIG_DIR=<profileDir>`
///   (+ `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL` for proxy)
/// - bedrock: `CLAUDE_CODE_USE_BEDROCK=1` + `AWS_REGION` + optional `AWS_PROFILE`
///   + `ANTHROPIC_MODEL` (no token; AWS SDK credential chain handles auth)
///
/// Secrets are **never** embedded in the returned `command` string — callers
/// must pass `sensitiveEnv` through `TmuxManager.createWindow(sensitiveEnv:)`
/// so tmux's `-e KEY=VALUE` flag puts it directly into the spawned window's
/// environment without appearing in the long-running shell command's `ps` argv.
///
/// `sensitiveEnv` is **not** populated when the resolved path is `cmd` or
/// `shellFallback`, since those branches are for non-claude shells.
enum ClaudeSpawnCommandBuilder {
    struct Result: Equatable {
        let command: String
        /// Env vars containing secrets, routing config, or rc-affecting
        /// toggles (DISABLE_AUTO_UPDATE). Keep using tmux's `-e KEY=VALUE`
        /// flag for all of these: secrets must not leak via `ps`, and rc
        /// toggles must be set before .zshrc runs.
        let sensitiveEnv: [String: String]
    }

    static func build(
        resumeID: String?,
        forkSession: Bool = false,
        freshSessionID: String?,
        appendSystemPrompt: String?,
        initialPrompt: String?,
        profileSecret: String?,
        profileKind: CredentialKind? = nil,
        profileBaseURL: String? = nil,
        profileModel: String? = nil,
        profileAwsRegion: String? = nil,
        profileAwsProfile: String? = nil,
        profileConfigDir: String? = nil,
        cmd: String?,
        shellFallback: String,
        settingsOverlayPath: String? = nil,
        pluginDirPath: String? = nil,
        envSettingOverrides: [String: ClaudeEnvValue] = [:],
        sessionName: String? = nil,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Result {
        // Optional --settings flag merged into the claude invocation.
        // Claude's --settings flag MERGES with ~/.claude/settings.json
        // (array settings concatenated + deduplicated). So we can ship
        // a TBD-owned overlay carrying the SessionStart hook etc. without
        // touching the user's settings.json. Only emitted when an overlay
        // path was supplied AND it exists on disk — otherwise the spawn
        // would fail with "settings file not found".
        let settingsFlag: String
        if let p = settingsOverlayPath, fileExists(p) {
            settingsFlag = " --settings \(SystemPromptBuilder.shellEscape(p))"
        } else {
            settingsFlag = ""
        }

        let pluginFlag: String
        if let p = pluginDirPath, fileExists(p) {
            pluginFlag = " --plugin-dir \(SystemPromptBuilder.shellEscape(p))"
        } else {
            pluginFlag = ""
        }

        // Session name for Claude Code's cross-session peer registry. Blank,
        // whitespace-only and control-character-only names are dropped rather
        // than passed through: `--name ''` would register an unaddressable
        // session.
        let nameFlag: String
        if let sanitized = sanitizedSessionName(sessionName) {
            nameFlag = " --name \(SystemPromptBuilder.shellEscape(sanitized))"
        } else {
            nameFlag = ""
        }

        let base: String
        if let resumeID {
            let forkFlag = forkSession ? " --fork-session" : ""
            var b = "claude --resume \(resumeID)\(forkFlag) --dangerously-skip-permissions\(nameFlag)\(settingsFlag)\(pluginFlag)"
            if let p = initialPrompt, !p.isEmpty {
                b += " \(SystemPromptBuilder.shellEscape(p))"
            }
            base = b
        } else if let sessionID = freshSessionID {
            var b = "claude --session-id \(sessionID) --dangerously-skip-permissions\(nameFlag)\(settingsFlag)\(pluginFlag)"
            if let prompt = appendSystemPrompt {
                b += " --append-system-prompt \(SystemPromptBuilder.shellEscape(prompt))"
            }
            if let p = initialPrompt, !p.isEmpty {
                b += " \(SystemPromptBuilder.shellEscape(p))"
            }
            base = b
        } else if let cmd {
            return Result(command: cmd, sensitiveEnv: [:])
        } else {
            return Result(command: shellFallback, sensitiveEnv: [:])
        }

        var env: [String: String] = [:]
        // Profile routing env assigned below is ALSO re-exported inline in
        // the returned command (see `inlineExports`); track its keys here.
        var routingKeys: Set<String> = []
        if profileKind == .bedrock {
            env["CLAUDE_CODE_USE_BEDROCK"] = "1"
            if let r = profileAwsRegion { env["AWS_REGION"] = r }
            if let p = profileAwsProfile { env["AWS_PROFILE"] = p }
            if let m = profileModel { env["ANTHROPIC_MODEL"] = m }
            routingKeys.formUnion(["CLAUDE_CODE_USE_BEDROCK", "AWS_REGION", "AWS_PROFILE", "ANTHROPIC_MODEL"])
            // Intentionally no ANTHROPIC_API_KEY / CLAUDE_CONFIG_DIR /
            // ANTHROPIC_BASE_URL for bedrock.
        } else {
            // Inject the profile's stored secret under the env var its kind
            // uses. Secrets flow through tmux's `-e KEY=VALUE` (argv, no shell
            // parsing), so we don't need shell-escape allowlists here.
            // Storage-time validation rejects newlines / NULL bytes that would
            // break tmux's single-line arg parsing.
            // NEVER a routing key — secrets must not be inlined into the
            // command string (visible in `ps` for the pane's lifetime).
            if let secret = profileSecret, let kind = profileKind {
                switch kind {
                case .apiKey:
                    env["ANTHROPIC_API_KEY"] = secret
                case .oauthToken:
                    env["CLAUDE_CODE_OAUTH_TOKEN"] = secret
                case .oauth, .bedrock:
                    // `.oauth` authenticates by a `/login` credential inside
                    // its isolated CLAUDE_CONFIG_DIR, so a secret that somehow
                    // reached us for one (a stale `<uuid>.token` file, say) is
                    // ignored rather than injected — injecting it would
                    // silently outrank the dir's own credential. `.bedrock`
                    // never reaches this branch.
                    break
                }
            }
            // For oauth profiles, no auth token — they use the isolated
            // CLAUDE_CONFIG_DIR to maintain an independent /login credential.
            if let baseURL = profileBaseURL { env["ANTHROPIC_BASE_URL"] = baseURL }
            if let model = profileModel { env["ANTHROPIC_MODEL"] = model }
            // Inject CLAUDE_CONFIG_DIR for all non-bedrock profiles that have
            // a config dir. The caller (resolveConfigDir) decides which kinds get
            // a dir, so if profileConfigDir is non-nil, inject it.
            if let configDir = profileConfigDir {
                env["CLAUDE_CONFIG_DIR"] = configDir
            }
            routingKeys.formUnion(["ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL", "CLAUDE_CONFIG_DIR"])
        }
        // Suppress oh-my-zsh's interactive "Would you like to update?" prompt.
        // It fires from .zshrc and would block the claude command until the
        // user answers — but an agent tab runs a command, not an interactive
        // shell for a human, so nothing should gate it. Plain shell tabs
        // (`cmd` / `shellFallback`, early-returned above) keep update checks.
        // Deliberately NOT a routing key: it must be in the process env
        // BEFORE .zshrc runs, which only tmux's `-e` flag achieves — an
        // inline export executes after all startup files and would be useless.
        env["DISABLE_AUTO_UPDATE"] = "true"
        // Registry-driven Claude spawn-env settings. This block only runs in
        // the Claude branches — the `cmd` / `shellFallback` branches return
        // earlier, before `env` exists — so non-Claude spawns are unaffected.
        for setting in ClaudeEnvRegistry.all {
            let value = envSettingOverrides[setting.id] ?? setting.defaultValue
            if let envValue = setting.emit(value) {
                env[setting.envVar] = envValue
            }
        }

        // Re-export the profile ROUTING env inline, ahead of the claude
        // invocation. tmux's `-e KEY=VALUE` seeds the pane's initial process
        // environment, but the window runs `$SHELL -i -l -c <command>`
        // (see TmuxManager.shellFlags(forShell:)) and an
        // interactive login shell sources profile and rc files (~/.zshenv,
        // /etc/zprofile, ~/.zprofile, ~/.zshrc) BEFORE the -c command — any
        // `export CLAUDE_CONFIG_DIR=...` in those files silently clobbers the
        // -e value. That is exactly what broke profile login sessions for
        // users running a shell-based Claude account switcher: every
        // "isolated" session inherited the rc file's config dir instead of
        // the profile's. Inline exports execute AFTER every startup file,
        // so they deterministically win.
        //
        // Scope: only the profile routing keys (config dir, base URL, model,
        // bedrock/AWS vars) — they are non-secret and are what account
        // switchers clobber. ANTHROPIC_API_KEY stays -e-only: inlining it
        // would leak the secret into the long-running shell's `ps` argv.
        let inlineExports = env
            .filter { routingKeys.contains($0.key) }
            .sorted(by: { $0.key < $1.key })
            .map { "export \($0.key)=\(SystemPromptBuilder.shellEscape($0.value));" }
            .joined(separator: " ")
        let command = inlineExports.isEmpty ? base : "\(inlineExports) \(base)"
        return Result(command: command, sensitiveEnv: env)
    }

    /// Longest `--name` value TBD will emit. Display names are free text with
    /// no length ceiling of their own, and the whole invocation ends up in
    /// `#{pane_start_command}` and in `ps` argv; a name long enough to matter
    /// there is not an address anyone types anyway.
    static let maxSessionNameLength = 64

    /// The `--name` value for a display name, or nil when nothing addressable
    /// survives.
    ///
    /// `shellEscape` single-quotes and handles embedded apostrophes, but a
    /// single-quoted newline is still a newline: it would split
    /// `#{pane_start_command}` across lines and corrupt anything that reads the
    /// pane's command back. Control and format characters are stripped rather
    /// than escaped — they carry no meaning in an address — then the result is
    /// trimmed, length-capped, and trimmed again so a cap landing mid-space
    /// cannot leave a trailing blank.
    ///
    /// Deliberately here and not in the rename handler: sanitizing there would
    /// change what a rename means to the user, and the display name has many
    /// consumers that are perfectly happy with newlines.
    static func sanitizedSessionName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let stripped = String(String.UnicodeScalarView(
            raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        ))
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let capped = String(trimmed.prefix(maxSessionNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }
}
