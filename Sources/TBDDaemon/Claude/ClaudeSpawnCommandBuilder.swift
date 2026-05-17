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
/// - `freshSessionID` non-nil → `claude --session-id <id> --dangerously-skip-permissions`
///   with optional `--append-system-prompt` and trailing initial-prompt arg.
/// - Otherwise → `cmd` if set, else `shellFallback`.
///
/// If we built a claude command (resume or fresh), `sensitiveEnv` carries the
/// auth + routing env vars for the spawned session:
/// - oauth: `CLAUDE_CODE_OAUTH_TOKEN=<secret>`
/// - api key (direct or proxy): `ANTHROPIC_API_KEY=<secret>` (+ `ANTHROPIC_BASE_URL`,
///   `ANTHROPIC_MODEL`, `ANTHROPIC_CONFIG_DIR` as applicable)
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
        /// Env vars containing secrets OR routing config. Keep using tmux's
        /// `-e KEY=VALUE` flag for all of these to avoid leaking via `ps`.
        let sensitiveEnv: [String: String]
    }

    static func build(
        resumeID: String?,
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

        let base: String
        if let resumeID {
            base = "claude --resume \(resumeID) --dangerously-skip-permissions\(settingsFlag)\(pluginFlag)"
        } else if let sessionID = freshSessionID {
            var b = "claude --session-id \(sessionID) --dangerously-skip-permissions\(settingsFlag)\(pluginFlag)"
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
        if profileKind == .bedrock {
            env["CLAUDE_CODE_USE_BEDROCK"] = "1"
            if let r = profileAwsRegion { env["AWS_REGION"] = r }
            if let p = profileAwsProfile { env["AWS_PROFILE"] = p }
            if let m = profileModel { env["ANTHROPIC_MODEL"] = m }
            // Intentionally no ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN /
            // ANTHROPIC_BASE_URL / ANTHROPIC_CONFIG_DIR for bedrock.
        } else {
            if let secret = profileSecret {
                // Secrets flow through tmux's `-e KEY=VALUE` (argv, no shell
                // parsing), so we don't need shell-escape allowlists here.
                // Storage-time validation rejects newlines / NULL bytes that would
                // break tmux's single-line arg parsing.
                let envVar = profileKind == .apiKey ? "ANTHROPIC_API_KEY" : "CLAUDE_CODE_OAUTH_TOKEN"
                env[envVar] = secret
            }
            if let baseURL = profileBaseURL { env["ANTHROPIC_BASE_URL"] = baseURL }
            if let model = profileModel { env["ANTHROPIC_MODEL"] = model }
            // Only inject ANTHROPIC_CONFIG_DIR for proxy profiles. For direct
            // (claude.ai) profiles, the spawned `claude` should keep reading
            // `~/.claude` so the user's OAuth login works. For proxy profiles,
            // isolating the config dir prevents Claude Code's >=2.1.x "Auth
            // conflict: Both a token (claude.ai) and an API key (ANTHROPIC_API_KEY)
            // are set" warning from firing.
            if let configDir = profileConfigDir, profileBaseURL != nil {
                env["ANTHROPIC_CONFIG_DIR"] = configDir
            }
        }
        return Result(command: base, sensitiveEnv: env)
    }
}
