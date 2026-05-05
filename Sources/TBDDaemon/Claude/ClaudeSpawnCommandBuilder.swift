import Foundation
import TBDShared

/// Builds the shell command string for spawning (or respawning) a claude terminal.
///
/// Pure function — no DB, no Keychain, no tmux. Easy to unit-test. The caller is
/// responsible for resolving the token secret (if any) before invoking.
///
/// Behavior:
/// - `resumeID` non-nil → `claude --resume <id> --dangerously-skip-permissions`
/// - `freshSessionID` non-nil → `claude --session-id <id> --dangerously-skip-permissions`
///   with optional `--append-system-prompt` and trailing initial-prompt arg.
/// - Otherwise → `cmd` if set, else `shellFallback`.
///
/// If `tokenSecret` is non-nil AND we built a claude command (resume or fresh),
/// the token is returned in `sensitiveEnv` keyed by `CLAUDE_CODE_OAUTH_TOKEN`
/// (oauth) or `ANTHROPIC_API_KEY` (api key). The token is **never** embedded in
/// the returned `command` string — callers must pass `sensitiveEnv` through
/// `TmuxManager.createWindow(sensitiveEnv:)` so tmux's `-e KEY=VALUE` flag puts
/// it directly into the spawned window's environment without ever appearing in
/// the long-running shell command's `ps` argv.
///
/// The token is **not** returned when the resolved path is `cmd` or
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
        cmd: String?,
        shellFallback: String
    ) -> Result {
        let base: String
        if let resumeID {
            base = "claude --resume \(resumeID) --dangerously-skip-permissions"
        } else if let sessionID = freshSessionID {
            var b = "claude --session-id \(sessionID) --dangerously-skip-permissions"
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
        return Result(command: base, sensitiveEnv: env)
    }
}
