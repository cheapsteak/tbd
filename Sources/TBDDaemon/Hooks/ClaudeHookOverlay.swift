import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "claude-overlay")

/// Generates and maintains the TBD-owned Claude Code settings overlay file.
///
/// Claude Code's `--settings <path>` flag merges array settings (like the
/// `hooks` dict's matchers) with the user's `~/.claude/settings.json` —
/// concatenated and deduplicated, not replaced. That means TBD can ship
/// its own overlay file pinned at spawn time without touching the user's
/// settings.json at all.
///
/// The overlay registers five event types:
/// - `SessionStart` (matcher `*`): calls `tbd session-event`, which
///   relays the new session ID + transcript path to the daemon. This is
///   what fixes the post-`/clear`/`/compact` transcript freeze.
/// - `Stop` (two entries):
///   - `tbd notify` for response-complete notifications, matching the
///     legacy globally-installed hook.
///   - `tbd hooks stop-rename-check`, which prompts the agent to rename
///     a still-default worktree/branch at end-of-turn.
/// - `StopFailure`: runs `tbd hooks stop-failure` to read the verbatim
///   API-error text from the transcript, then pipes that into
///   `tbd notify --type error` — `Stop` fires only on normal completion.
/// - `PreToolUse:AskUserQuestion` / `PostToolUse:AskUserQuestion`:
///   bridge tool input and `tool_use_id` so the transcript pane can
///   render the question before Claude flushes the assistant message
///   to the JSONL.
///
/// The overlay is regenerated on every daemon startup so changes to the
/// shape (new hooks, new commands) take effect on the next worktree open.
/// Idempotent — repeated writes with the same content are safe.
public enum ClaudeHookOverlay {
    /// Path of the TBD-owned overlay file. Lives under `~/tbd/runtime/` so
    /// it cohabits with state.db and other daemon-managed files.
    public static let overlayPath: String = {
        TBDConstants.configDir
            .appendingPathComponent("runtime")
            .appendingPathComponent("claude-overlay.json")
            .path
    }()

    /// The shell command for the SessionStart hook. Reads stdin (Claude's
    /// hook payload) into `tbd session-event`, which RPCs the daemon. The
    /// command tolerates `tbd` not being on PATH — silent failure is fine.
    static let sessionStartCommand =
        #"tbd session-event 2>/dev/null || true"#

    /// The shell command for the Stop hook. Mirrors the legacy
    /// `setup-hooks --global` command so TBD can replace it without
    /// regressing notification behavior.
    static let stopCommand =
        #"MSG=$(jq -r '.last_assistant_message // empty' 2>/dev/null); tbd notify --type response_complete --message "$MSG" 2>/dev/null || true"#

    /// Second Stop hook: prompt the agent to rename its worktree/branch at
    /// end-of-turn while the work is fresh and context is highest. Reads
    /// the Stop payload from stdin and may emit a `{"decision":"block",...}`
    /// JSON response. Silent failure so we never wedge the agent.
    static let stopRenameCheckCommand =
        #"tbd hooks stop-rename-check 2>/dev/null || true"#

    /// The shell command for the StopFailure hook. Delegates to
    /// `tbd hooks stop-failure`, which reads the verbatim API-error text from
    /// the transcript (so a session limit reads "You've hit your session limit
    /// · resets 3pm" rather than a generic "rate_limit"), then pipes the
    /// message into `tbd notify --type error`. Mirrors the `Stop` hook's
    /// `MSG=$(…); tbd notify …` shape. Trailing `; true` keeps the hook exit 0
    /// so it never wedges the agent.
    static let stopFailureCommand =
        #"MSG=$(tbd hooks stop-failure 2>/dev/null); [ -n "$MSG" ] && tbd notify --type error --message "$MSG" 2>/dev/null; true"#

    /// Bridges the `PreToolUse:AskUserQuestion` hook into TBD. Captures the
    /// tool input and tool_use_id so the transcript pane can render the
    /// question before Claude flushes the assistant message to the JSONL.
    static let askUserQuestionPreCommand =
        #"tbd ask-user-question pre 2>/dev/null || true"#

    /// Bridges the `PostToolUse:AskUserQuestion` hook into TBD. Defensive
    /// only — see RPCRouter+TerminalHandlers.swift for why we rely on JSONL
    /// dedupe rather than eager cleanup.
    static let askUserQuestionPostCommand =
        #"tbd ask-user-question post 2>/dev/null || true"#

    /// Build the JSON-encoded overlay body.
    ///
    /// When `fallbackModels` is non-nil and non-empty, a top-level
    /// `"fallbackModel"` array (the ordered model ids) is included alongside
    /// `hooks`. Claude Code's `--settings` flag takes the FIRST file's scalar
    /// keys (it does NOT merge across multiple `--settings` flags), so the
    /// fallback list MUST ride in the same file as the hooks — hence this
    /// merged body rather than a second overlay.
    public static func generateBody(fallbackModels: [String]? = nil) throws -> Data {
        var body: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": sessionStartCommand]
                        ]
                    ]
                ],
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": stopCommand]
                        ]
                    ],
                    [
                        "hooks": [
                            ["type": "command", "command": stopRenameCheckCommand]
                        ]
                    ]
                ],
                "StopFailure": [
                    [
                        "hooks": [
                            ["type": "command", "command": stopFailureCommand]
                        ]
                    ]
                ],
                "PreToolUse": [
                    [
                        "matcher": "AskUserQuestion",
                        "hooks": [
                            ["type": "command", "command": askUserQuestionPreCommand]
                        ]
                    ]
                ],
                "PostToolUse": [
                    [
                        "matcher": "AskUserQuestion",
                        "hooks": [
                            ["type": "command", "command": askUserQuestionPostCommand]
                        ]
                    ]
                ]
            ]
        ]
        if let fallbackModels, !fallbackModels.isEmpty {
            body["fallbackModel"] = fallbackModels
        }
        return try JSONSerialization.data(
            withJSONObject: body,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Resolve the `--settings` overlay path for a spawn.
    ///
    /// - No fallback models (nil/empty) → returns the shared global
    ///   `overlayPath` unchanged (hooks-only, the pre-existing behavior).
    /// - Fallback models present → writes a PER-SESSION overlay file that
    ///   merges hooks + the `fallbackModel` array (because `fallbackModel` is
    ///   per-profile and the global overlay is shared across all sessions),
    ///   then returns that file's path.
    ///
    /// The per-session path is keyed by `sessionKey` (a session/terminal/
    /// worktree-unique string) so concurrent sessions with different profiles
    /// don't race on the same file. Writes are idempotent — the same key
    /// overwrites in place.
    public static func resolveOverlayPath(
        fallbackModels: [String]?,
        sessionKey: String
    ) throws -> String {
        guard let fallbackModels, !fallbackModels.isEmpty else {
            return overlayPath
        }
        let path = perSessionOverlayPath(sessionKey: sessionKey)
        let data = try generateBody(fallbackModels: fallbackModels)
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        logger.info("Wrote per-session Claude overlay at \(path, privacy: .public)")
        return path
    }

    /// Path of a per-session overlay file. Lives alongside the global overlay
    /// under `~/tbd/runtime/`. The `sessionKey` is sanitized to stay
    /// filesystem-safe.
    static func perSessionOverlayPath(sessionKey: String) -> String {
        let safe = sessionKey.unicodeScalars.map { scalar -> Character in
            let isSafe = scalar == "-" || scalar == "_"
                || (scalar >= "0" && scalar <= "9")
                || (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
            return isSafe ? Character(scalar) : "_"
        }
        return TBDConstants.configDir
            .appendingPathComponent("runtime")
            .appendingPathComponent("claude-overlay-session-\(String(safe)).json")
            .path
    }

    /// Write the overlay to `overlayPath`, creating the parent directory if
    /// needed. Atomic so a crash mid-write can't leave a half-written file
    /// that breaks the next Claude spawn. Returns true on success.
    @discardableResult
    public static func writeOverlay() -> Bool {
        do {
            let data = try generateBody()
            let parent = (overlayPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: overlayPath), options: .atomic)
            logger.info("Wrote Claude overlay at \(overlayPath, privacy: .public)")
            return true
        } catch {
            logger.error("Failed to write Claude overlay: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Verify the overlay exists. Used by `tbd hooks status` and as a
    /// belt-and-braces check before we add `--settings` to the spawn command.
    public static func overlayExists() -> Bool {
        FileManager.default.fileExists(atPath: overlayPath)
    }
}
