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
/// The overlay registers six event types:
/// - `SessionStart` (matcher `*`): calls `tbd session-event`, which
///   relays the new session ID + transcript path to the daemon. This is
///   what fixes the post-`/clear`/`/compact` transcript freeze. Also
///   sets the terminal activity state to idle.
/// - `Stop` (two entries):
///   - `tbd notify` for response-complete notifications, matching the
///     legacy globally-installed hook. Also sets activity to idle.
///   - `tbd hooks stop-rename-check`, which prompts the agent to rename
///     a still-default worktree/branch at end-of-turn.
/// - `StopFailure`: runs `tbd hooks stop-failure` to read the verbatim
///   API-error text from the transcript, then pipes that into
///   `tbd notify --type error` — `Stop` fires only on normal completion.
///   Also sets activity to idle.
/// - `UserPromptSubmit`: sets activity to working so the thinking
///   indicator appears in the sidebar while Claude processes a prompt.
/// - `PreToolUse:AskUserQuestion` / `PostToolUse:AskUserQuestion`:
///   bridge tool input and `tool_use_id` so the transcript pane can
///   render the question before Claude flushes the assistant message
///   to the JSONL. Pre sets activity to waiting_for_user; post sets
///   it back to working (Claude continues processing after user answers).
/// - `PostToolUse:Bash`: greps the payload for `pr create` and, only on
///   a match, pipes it to `tbd pr bind --from-hook` to bind any PR the
///   command reported. The grep prefilter keeps every other Bash call
///   (the overwhelming majority) from spawning a `tbd` process. It is a
///   cost optimization, not a gate — `PRBindingExtractor`'s tokenizer
///   decides what actually counts as a create.
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
    /// Also initializes terminal activity to idle.
    static let sessionStartCommand =
        #"tbd session-event 2>/dev/null || true; tbd terminal-activity idle 2>/dev/null || true"#

    /// The shell command for the Stop hook. Mirrors the legacy
    /// `setup-hooks --global` command so TBD can replace it without
    /// regressing notification behavior. Also clears the thinking indicator.
    static let stopCommand =
        #"MSG=$(jq -r '.last_assistant_message // empty' 2>/dev/null); tbd notify --type response_complete --message "$MSG" 2>/dev/null || true; tbd terminal-activity idle 2>/dev/null || true"#

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
    /// `MSG=$(…); tbd notify …` shape. Also clears the thinking indicator.
    /// Trailing `; true` keeps the hook exit 0 so it never wedges the agent.
    static let stopFailureCommand =
        #"MSG=$(tbd hooks stop-failure 2>/dev/null); [ -n "$MSG" ] && tbd notify --type error --message "$MSG" 2>/dev/null; tbd terminal-activity idle 2>/dev/null || true; true"#

    /// Bridges the `PreToolUse:AskUserQuestion` hook into TBD. Captures the
    /// tool input and tool_use_id so the transcript pane can render the
    /// question before Claude flushes the assistant message to the JSONL.
    /// Also signals waiting_for_user so the sidebar shows the correct state.
    static let askUserQuestionPreCommand =
        #"tbd ask-user-question pre 2>/dev/null || true; tbd terminal-activity waiting_for_user 2>/dev/null || true"#

    /// Bridges the `PostToolUse:AskUserQuestion` hook into TBD. Defensive
    /// only — see RPCRouter+TerminalHandlers.swift for why we rely on JSONL
    /// dedupe rather than eager cleanup. Also signals working since Claude
    /// continues processing after the user answers.
    static let askUserQuestionPostCommand =
        #"tbd ask-user-question post 2>/dev/null || true; tbd terminal-activity working 2>/dev/null || true"#

    /// Sets the terminal activity state to working (shows the thinking
    /// indicator in the sidebar while Claude processes a prompt).
    static let workingCommand =
        #"tbd terminal-activity working 2>/dev/null || true"#

    /// Sets the terminal activity state to waiting_for_user.
    static let waitingForUserCommand =
        #"tbd terminal-activity waiting_for_user 2>/dev/null || true"#

    /// The extended regex the prefilter greps a Bash hook payload for.
    ///
    /// **Deliberately permissive, and it must stay that way.** The prefilter is
    /// a COST OPTIMIZATION, never a gate: `PRBindingExtractor`'s tokenizer is
    /// the sole authority on what counts as a `gh pr create`, and it can only
    /// judge payloads this pattern lets through. A payload the grep drops never
    /// reaches `tbd` at all, so a false negative loses the bind in silence.
    ///
    /// **What it guarantees:** every command the tokenizer accepts with `pr` and
    /// `create` as *adjacent* subcommand words is admitted — however the segment
    /// is quoted, whichever global flags precede the subcommand, and whether or
    /// not `gh` is path-qualified. Two properties carry that, and neither is
    /// obvious from the pattern alone.
    ///
    /// It does not require `gh` adjacency, because
    /// `gh -R acme/acme-prod pr create` and `gh --repo acme/acme-prod pr create`
    /// are exactly the flagged forms the tokenizer was built to accept, and a
    /// `gh[[:space:]]+pr` requirement here silently dropped every one of them
    /// before the tokenizer ever ran.
    ///
    /// And it separates the two words by any run of non-alphanumeric characters
    /// rather than by whitespace, because the tokenizer *strips quotes* while
    /// splitting words: `gh "pr" create` and `gh pr 'create'` are real creates,
    /// yet the raw JSON this grep reads still carries the quote — and, for a
    /// double quote, JSON's own backslash — between them. `\t` and `\r` are
    /// spelled out alongside the class because JSON escapes a tab or carriage
    /// return to a backslash followed by an *alphanumeric* letter, which the
    /// class alone would reject. The run is unbounded on purpose: a length cap
    /// would reintroduce a false negative for nothing, since alphanumerics are
    /// excluded and so the run can never cross a word.
    ///
    /// **What it does not guarantee**, so the invariant is stated rather than
    /// implied: a flag word *between* the two subcommand words
    /// (`gh pr --draft create`, `gh pr -R acme/acme-prod create`), which the
    /// tokenizer skips over but which no pattern can span without also matching
    /// ordinary prose — the intervening flag and its value are alphanumeric
    /// words indistinguishable from any other; and quoting *inside* a word
    /// (`gh p"r" create`), where the literal `pr` never appears in the payload
    /// at all and only a tokenizer could recover it. Both fail closed to a lost
    /// fast path, not a lost binding: branch matching still binds the PR on the
    /// next poll, the same recovery a hook timeout relies on.
    ///
    /// The resulting over-match is the right trade and is accepted knowingly: a
    /// payload that merely mentions "pr create" now spawns one short-lived
    /// `tbd`, which reads the payload and correctly declines to bind. A false
    /// negative loses a PR binding silently; a false positive costs one
    /// process.
    ///
    /// Lives in its own constant so the test can grep with the same literal the
    /// shell command runs — hand-copying it into the test is how the two drift
    /// apart. It is embedded in a single-quoted shell word, so it must never
    /// contain a `'`.
    static let prBindGrepPattern = #"pr([^[:alnum:]]|\\[tr])+create"#

    /// Binds any PR created by a `gh pr create` in this session.
    ///
    /// The `grep -qE` is a deliberate prefilter: this hook fires on EVERY Bash
    /// tool call across the whole fleet, and without it each one would spawn a
    /// `tbd` process — a daemon round trip. With it, an unrelated Bash call
    /// costs the hook's own shell, the `$(cat)` command substitution that holds
    /// the payload, and one `grep` over it; no `tbd` runs and nothing reaches
    /// the daemon. It filters for cost only — see `prBindGrepPattern` for why
    /// it is deliberately wider than the rule it prefilters for. `-E` (extended
    /// regex) rather than a GNU-only `\+` in basic regex — BSD/macOS grep is the
    /// one this hook actually runs under. `|| true` guarantees the hook cannot
    /// fail the tool call it observes.
    static let prBindCommand =
        #"payload=$(cat); printf '%s' "$payload" | grep -qE '\#(prBindGrepPattern)' && printf '%s' "$payload" | tbd pr bind --from-hook || true"#

    /// Seconds Claude Code will wait for `prBindCommand` before killing it.
    ///
    /// Explicit because this is the first TBD hook matching a universally-used
    /// tool: it fires on EVERY Bash call across the whole fleet, so Claude
    /// Code's 60 s default would turn one wedged daemon socket into a 60 s stall
    /// on every shell command every agent runs. Three seconds is far more than
    /// the happy path needs — the common case is a `cat` and a `grep` that
    /// matches nothing, so no `tbd` is spawned — and the binding is re-derivable
    /// by branch matching on the next poll, so a timeout costs at most a
    /// delayed binding.
    static let prBindTimeoutSeconds = 3

    /// Build the JSON-encoded overlay body.
    ///
    /// When `fallbackModels` is non-nil and non-empty, a top-level
    /// `"fallbackModel"` array (the ordered model ids) is included alongside
    /// `hooks`. Claude Code's `--settings` flag takes the FIRST file's scalar
    /// keys (it does NOT merge across multiple `--settings` flags), so the
    /// fallback list MUST ride in the same file as the hooks — hence this
    /// merged body rather than a second overlay.
    ///
    /// `extraSettings`, when present, is DEEP-MERGED into the body after
    /// `fallbackModel`: object-valued keys present in both recurse; any other
    /// clash lets the `extraSettings` value win. This preserves TBD's `hooks`
    /// when the fragment only adds top-level keys (e.g. `skillOverrides`).
    public static func generateBody(
        fallbackModels: [String]? = nil,
        extraSettings: [String: Any]? = nil
    ) throws -> Data {
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
                "UserPromptSubmit": [
                    [
                        "hooks": [
                            ["type": "command", "command": workingCommand]
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
                    ],
                    [
                        "matcher": "Bash",
                        "hooks": [
                            ["type": "command", "command": prBindCommand,
                             "timeout": prBindTimeoutSeconds] as [String: Any]
                        ]
                    ]
                ]
            ]
        ]
        if let fallbackModels, !fallbackModels.isEmpty {
            body["fallbackModel"] = fallbackModels
        }
        if let extraSettings {
            deepMerge(&body, extraSettings)
        }
        return try JSONSerialization.data(
            withJSONObject: body,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Recursive dict merge: for a key present in both, if BOTH values are
    /// `[String: Any]` recurse; otherwise the `overlay` value wins.
    private static func deepMerge(_ base: inout [String: Any], _ overlay: [String: Any]) {
        for (key, overlayValue) in overlay {
            if var baseChild = base[key] as? [String: Any],
               let overlayChild = overlayValue as? [String: Any] {
                deepMerge(&baseChild, overlayChild)
                base[key] = baseChild
            } else {
                base[key] = overlayValue
            }
        }
    }

    /// Parse an `extraSettingsJSON` fragment into a settings dict. Returns nil
    /// for nil/empty input; also returns nil (with a warning) when the string
    /// isn't a valid JSON object, so a malformed fragment degrades to "no extra
    /// settings" rather than aborting the spawn.
    private static func parseExtraSettings(_ json: String?) -> [String: Any]? {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            logger.warning("Ignoring malformed claudeSettingsOverlay fragment (not a JSON object): \(json, privacy: .public)")
            return nil
        }
        return dict
    }

    /// Read the repo's Claude settings overlay fragment file
    /// (`~/tbd/repos/<repoID>/claude-settings.json`), fresh at spawn time.
    /// nil repoID (scratch spaces) or a missing/unreadable file → nil (inert).
    /// Malformed content is handled downstream by `resolveOverlayPath`
    /// (degrades to hooks-only, never aborts the spawn).
    public static func repoSettingsFragment(repoID: UUID?) -> String? {
        guard let repoID else { return nil }
        return try? String(
            contentsOfFile: TBDConstants.claudeSettingsOverlayPath(repoID: repoID),
            encoding: .utf8
        )
    }

    /// Resolve the `--settings` overlay path for a spawn.
    ///
    /// - Both fallback models AND `extraSettingsJSON` absent → returns the
    ///   shared global `overlayPath` unchanged (hooks-only, pre-existing behavior).
    /// - Fallback models present OR a non-empty `extraSettingsJSON` fragment
    ///   supplied → writes a PER-SESSION overlay file that merges hooks + the
    ///   `fallbackModel` array (per-profile) + the fragment (both are session-
    ///   specific, and the global overlay is shared across all sessions), then
    ///   returns that file's path.
    ///
    /// The per-session path is keyed by `sessionKey` (a session/terminal/
    /// worktree-unique string) so concurrent sessions with different profiles
    /// don't race on the same file. Writes are idempotent — the same key
    /// overwrites in place.
    ///
    /// Never throws: if the per-session overlay write fails for any reason
    /// (unwritable runtime dir, disk full, …), the error is logged and the
    /// shared global `overlayPath` is returned instead. This guarantees a
    /// spawn always has a usable `--settings` path — it degrades to "no
    /// fallback models" rather than aborting the spawn.
    ///
    /// `repoSettingsJSON` (the repo's file-backed fragment, read by callers
    /// via `repoSettingsFragment`) and
    /// `extraSettingsJSON` (the per-spawn param) are JSON OBJECT strings that
    /// also force a per-session overlay and are deep-merged into the body —
    /// repo fragment first, per-spawn fragment on top (per-spawn wins
    /// collisions). Each parses independently: a malformed one is logged and
    /// dropped without discarding the other, and a bad fragment must never
    /// abort the spawn.
    ///
    /// The repo fragment is read fresh from the repo's overlay file (see
    /// `repoSettingsFragment`) at actual spawn time, so it applies on ALL
    /// spawn paths (fresh create, resume, wake, profile swap) and edits made
    /// during a preSession hook wait are picked up. The per-spawn fragment
    /// applies at FRESH spawn only — callers gate it.
    public static func resolveOverlayPath(
        fallbackModels: [String]?,
        sessionKey: String,
        repoSettingsJSON: String? = nil,
        extraSettingsJSON: String? = nil
    ) -> String {
        let hasFallback = !(fallbackModels?.isEmpty ?? true)
        // A non-empty fragment string forces a per-session overlay even if it
        // later fails to parse — a malformed fragment degrades to hooks-only,
        // it must not silently fall back to (and mutate) the shared global file.
        let hasExtra = !(extraSettingsJSON?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(repoSettingsJSON?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasFallback || hasExtra else {
            return overlayPath
        }
        // Repo fragment first, per-spawn fragment deep-merged on top.
        var extraSettings = parseExtraSettings(repoSettingsJSON)
        if let perSpawn = parseExtraSettings(extraSettingsJSON) {
            var base = extraSettings ?? [:]
            deepMerge(&base, perSpawn)
            extraSettings = base
        }
        let path = perSessionOverlayPath(sessionKey: sessionKey)
        do {
            let data = try generateBody(fallbackModels: fallbackModels, extraSettings: extraSettings)
            let parent = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            logger.info("Wrote per-session Claude overlay at \(path, privacy: .public)")
            return path
        } catch {
            logger.error(
                "Failed to write per-session Claude overlay at \(path, privacy: .public); falling back to global overlay: \(error.localizedDescription, privacy: .public)"
            )
            return overlayPath
        }
    }

    /// Path of a per-session overlay file. Lives alongside the global overlay
    /// under `~/tbd/runtime/`. The `sessionKey` is sanitized to stay
    /// filesystem-safe.
    ///
    /// Callers MUST pass a unique opaque id (the terminal UUID). The
    /// character sanitization (non-`[A-Za-z0-9_-]` → `_`) is only
    /// collision-safe for such inputs — two distinct human-readable strings
    /// could sanitize to the same filename, but distinct UUIDs never do.
    static func perSessionOverlayPath(sessionKey: String) -> String {
        runtimeDir
            .appendingPathComponent("\(perSessionPrefix)\(sanitize(sessionKey))\(perSessionSuffix)")
            .path
    }

    /// Filename prefix/suffix for per-session overlay files. Shared between the
    /// path builder and the orphan-prune sweep so the two never drift.
    static let perSessionPrefix = "claude-overlay-session-"
    static let perSessionSuffix = ".json"

    private static var runtimeDir: URL {
        TBDConstants.configDir.appendingPathComponent("runtime")
    }

    /// Filesystem-safe rendering of `sessionKey` (non-`[A-Za-z0-9_-]` → `_`).
    static func sanitize(_ sessionKey: String) -> String {
        String(sessionKey.unicodeScalars.map { scalar -> Character in
            let isSafe = scalar == "-" || scalar == "_"
                || (scalar >= "0" && scalar <= "9")
                || (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
            return isSafe ? Character(scalar) : "_"
        })
    }

    /// Delete the per-session overlay file for `sessionKey`, if present.
    /// Best-effort — a missing file or removal error is ignored. Called on
    /// terminal teardown so per-session overlays don't accumulate under
    /// `~/tbd/runtime/`.
    static func removePerSessionOverlay(sessionKey: String) {
        let path = perSessionOverlayPath(sessionKey: sessionKey)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Startup sweep: delete every `claude-overlay-session-*.json` file whose
    /// (sanitized) session key is NOT in `liveSessionKeys`. This reclaims
    /// per-session overlays orphaned by crashes, worktree archive, or any
    /// teardown path that didn't call `removePerSessionOverlay` — so cleanup
    /// can't drift as new teardown paths are added. Best-effort.
    static func pruneOrphanedSessionOverlays(liveSessionKeys: [String]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: runtimeDir.path) else {
            return
        }
        let liveSanitized = Set(liveSessionKeys.map { sanitize($0) })
        for entry in entries where entry.hasPrefix(perSessionPrefix) && entry.hasSuffix(perSessionSuffix) {
            let key = String(entry.dropFirst(perSessionPrefix.count).dropLast(perSessionSuffix.count))
            if liveSanitized.contains(key) { continue }
            let path = runtimeDir.appendingPathComponent(entry).path
            try? fm.removeItem(atPath: path)
            logger.info("Pruned orphaned per-session Claude overlay \(entry, privacy: .public)")
        }
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
