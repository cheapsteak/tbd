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
/// The overlay registers two hooks:
/// - `SessionStart` (matcher `*`): calls `tbd session-event`, which
///   relays the new session ID + transcript path to the daemon. This is
///   what fixes the post-`/clear`/`/compact` transcript freeze.
/// - `Stop`: calls `tbd notify` for response-complete notifications,
///   matching the legacy globally-installed hook.
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
    ///
    /// Pass an absolute path to TBDCLI to bypass PATH entirely (avoids the
    /// stale-symlink-on-PATH bug where `tbd` resolves to a different
    /// worktree's older binary that doesn't know `session-event`). When
    /// `cliPath` is nil/empty, fall back to bare `tbd` for backward compat.
    static func sessionStartCommand(cliPath: String?) -> String {
        let bin = shellQuote(cliPath) ?? "tbd"
        return "\(bin) session-event 2>/dev/null || true"
    }

    /// The shell command for the Stop hook. Mirrors the legacy
    /// `setup-hooks --global` command so TBD can replace it without
    /// regressing notification behavior.
    ///
    /// Same rationale as `sessionStartCommand` for `cliPath`: bake an
    /// absolute path so we don't share the broken `tbd` PATH symlink.
    static func stopCommand(cliPath: String?) -> String {
        let bin = shellQuote(cliPath) ?? "tbd"
        return #"MSG=$(jq -r '.last_assistant_message // empty' 2>/dev/null); "# +
            #"\#(bin) notify --type response_complete --message "$MSG" 2>/dev/null || true"#
    }

    /// Single-quote-wrap a path for safe shell embedding. Returns nil when
    /// the input is nil/empty so callers can fall back to bare `tbd`.
    /// Embedded single quotes are escaped via the standard `'\''` trick.
    static func shellQuote(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let escaped = path.replacingOccurrences(of: "'", with: #"'\''"#)
        return "'\(escaped)'"
    }

    /// Build the JSON-encoded overlay body.
    ///
    /// `cliPath` should be the absolute path to the daemon's sibling TBDCLI
    /// binary (see `CLIInstaller.cliPath(forDaemonExecutable:)`). When nil,
    /// falls back to bare `tbd` (PATH lookup) — accepting the stale-symlink
    /// risk so notifications still have a chance to fire.
    public static func generateBody(cliPath: String? = nil) throws -> Data {
        let body: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    [
                        "matcher": "*",
                        "hooks": [
                            ["type": "command", "command": sessionStartCommand(cliPath: cliPath)]
                        ]
                    ]
                ],
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": stopCommand(cliPath: cliPath)]
                        ]
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(
            withJSONObject: body,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Write the overlay to `overlayPath`, creating the parent directory if
    /// needed. Atomic so a crash mid-write can't leave a half-written file
    /// that breaks the next Claude spawn. Returns true on success.
    ///
    /// `cliPath` is the absolute path to TBDCLI. When nil/empty, the overlay
    /// falls back to bare `tbd` and a warning is logged — the caller's
    /// responsibility to pass a real path on every healthy startup.
    @discardableResult
    public static func writeOverlay(cliPath: String? = nil) -> Bool {
        if cliPath == nil || cliPath?.isEmpty == true {
            logger.warning("Writing Claude overlay without absolute CLI path; falling back to bare `tbd` on PATH (may resolve to a stale symlink).")
        }
        do {
            let data = try generateBody(cliPath: cliPath)
            let parent = (overlayPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: overlayPath), options: .atomic)
            logger.info("Wrote Claude overlay at \(overlayPath, privacy: .public) (cli=\(cliPath ?? "<bare tbd>", privacy: .public))")
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
