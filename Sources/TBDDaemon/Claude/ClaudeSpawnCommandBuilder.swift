import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "claudeSpawn")

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
/// the command is prefixed with `CLAUDE_CODE_OAUTH_TOKEN='<value>' `. The token is
/// asserted to be alphanumeric / `-` / `_` only — Claude OAuth tokens and Anthropic
/// API keys both fit this charset, so a value with anything else indicates a bug
/// or corrupted entry and traps loudly rather than producing a broken shell line.
/// The token is single-quoted defensively even though it cannot contain quotes.
///
/// The token is **not** injected when the resolved path is `cmd` or `shellFallback`,
/// since those branches are for non-claude shells.
enum ClaudeSpawnCommandBuilder {
    static func build(
        resumeID: String?,
        freshSessionID: String?,
        appendSystemPrompt: String?,
        initialPrompt: String?,
        tokenSecret: String?,
        tokenKind: ClaudeTokenKind? = nil,
        cmd: String?,
        shellFallback: String
    ) -> String {
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
            return cmd
        } else {
            return shellFallback
        }

        guard let secret = tokenSecret else { return base }
        guard secret.allSatisfy({ ch in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_"
        }) else {
            logger.error("Claude token contains unexpected characters; falling back to keychain login without env injection")
            return base
        }
        // Defensive single-quote escape; tokens never contain `'`.
        let escaped = secret.replacingOccurrences(of: "'", with: "'\\''")
        let envVar = tokenKind == .apiKey ? "ANTHROPIC_API_KEY" : "CLAUDE_CODE_OAUTH_TOKEN"
        return "\(envVar)='\(escaped)' \(base)"
    }
}
