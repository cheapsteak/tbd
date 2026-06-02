# Distinguish session-limit API errors + distinct error sound

**Date:** 2026-06-02
**Status:** Approved (brainstorming → ready for implementation plan)
**Builds on:** `2026-06-02-claude-api-error-notification-design.md` (the `StopFailure` hook, merged in #248)

## Problem

PR #248 added a `StopFailure` hook so a turn killed by an API error raises an
`.error` notification instead of dying silently. Two gaps remain, surfaced by a
real session-limit event in the "⛏️ pyright-ratchet" worktree
(`You've hit your session limit · resets 3pm (America/Toronto)`):

1. **The message can't distinguish a session limit from a transient blip.**
   Verified against the installed Claude Code binary (v2.1.160): the only
   `error_type` values that exist are `authentication_failed`, `billing_error`,
   `invalid_request`, `max_output_tokens`, `model_not_found`,
   `oauth_org_not_allowed`, `rate_limit`, `server_error`. There is **no**
   `session_limit` / `usage_limit` type. A session limit and a transient 429
   both arrive as `error_type: rate_limit` (confirmed in the transcript:
   `isApiErrorMessage: true`, `apiErrorStatus: 429`, `error: "rate_limit"`). So
   the current generic `Claude stopped: API error (rate_limit)` message is
   actively misleading — it implies "retry soon" when the user is actually
   blocked for hours. The only signal that distinguishes the two is the verbatim
   error text Claude wrote to the transcript.

2. **Error notifications sound identical to routine completions.**
   `NotificationSoundPlayer.playIfEnabled()` plays one configured sound (default
   `Blow`) for every notification regardless of type, so an API-error death is
   as easy to miss as a "response complete" chime.

## Goal

Make an API-error turn death impossible to miss: surface the verbatim,
case-appropriate message ("You've hit your session limit · resets 3pm" vs.
"Server is temporarily limiting requests"), and play a distinct, user-configurable
error sound.

## Component A — Useful, distinct message

The `StopFailure` stdin payload includes `transcript_path`. The verbatim text is
the most recent transcript entry with `isApiErrorMessage: true`, under
`message.content[0].text`. Extracting that (plus a fallback) is real branching
that warrants unit tests — the established `stop-rename-check` shape.

### New subcommand `tbd hooks stop-failure`

File: `Sources/TBDCLI/Commands/StopFailureCommand.swift`. Mirrors
`StopRenameCheckCommand`:

- `run()`: read StopFailure JSON from stdin → `StopFailureMessage.compute(...)` →
  `print` the message if non-nil (nothing otherwise).
- Pure core `enum StopFailureMessage { static func compute(stdinData: Data, readFile: (String) -> Data?) -> String? }`:
  - Parse stdin JSON. Unparseable → return `nil` (print nothing → no notification).
  - Read `error_type` (default `"unknown"`) and `transcript_path`.
  - If `transcript_path` is present and `readFile` returns data: scan the lines
    from the end; for the first line that decodes to an object with
    `isApiErrorMessage == true`, extract the first `message.content` element of
    `type == "text"` and return its `text` (when non-empty).
  - Otherwise return the fallback `"Claude stopped: API error (\(errorType))"`.
- `readFile` is injected (production: `try? Data(contentsOf:)`); tests pass a
  fixture so no real filesystem or daemon is touched.

Register `StopFailureCommand.self` in `HooksCommand.configuration.subcommands`.

### Overlay command change

In `Sources/TBDDaemon/Hooks/ClaudeHookOverlay.swift`, replace the inline-`jq`
`stopFailureCommand` with the same `MSG=$(…); tbd notify …` composition the
existing `Stop` hook (`stopCommand`) already uses:

```sh
MSG=$(tbd hooks stop-failure 2>/dev/null); [ -n "$MSG" ] && tbd notify --type error --message "$MSG" 2>/dev/null; true
```

`tbd hooks stop-failure` inherits the hook's stdin (the StopFailure JSON). The
trailing `; true` guarantees exit 0 so the hook never wedges the agent. This
**reuses `tbd notify` wholesale** — worktree/terminal resolution, the
`RPCMethod.notify` call, `state.db` persistence, the broadcast, and the macOS
banner are all unchanged. The subcommand only computes the message string. Still
no matcher (catches every `error_type`), still `.error` severity.

Resulting banner: `⛏️ pyright-ratchet — You've hit your session limit · resets 3pm (America/Toronto)`.

## Component B — Distinct, configurable error sound

Independent of Component A; can ship as its own commit.

### `Sources/TBDApp/Services/NotificationSoundPlayer.swift`

- Add `import TBDShared` (for `NotificationType`).
- Add storage: `@AppStorage("errorNotificationSoundName") private var errorSoundName: String = "Sosumi"` and
  `@AppStorage("errorNotificationSoundCustomPath") private var errorCustomPath: String = ""`.
- Replace `playIfEnabled()` with `playIfEnabled(for type: NotificationType)`:
  resolve the error sound (`errorSoundName` / `errorCustomPath`) when
  `type == .error`, else the existing sound (`soundName` / `customPath`).
- Factor sound resolution to take the (name, customPath) pair so both the
  default and error paths share it. Keep `playTest()` for the default sound and
  add `playTestError()` (or `playTest(for:)`) for the error sound.

### `Sources/TBDApp/AppState.swift`

At the single call site in `handleNotificationDelta`, pass the type:
`notificationSoundPlayer.playIfEnabled(for: notification.type)`.

### `Sources/TBDApp/Settings/SettingsView.swift`

Add a second picker + Test button labeled "Error sound", shown under the
existing "Sound" picker when `enableSounds` is true, with the same
system-sounds + "Custom…" affordance bound to the new `@AppStorage` keys.

## Testing

- **`StopFailureMessage.compute`** (new test file, `TBDCLI` test target) — one
  test per branch:
  - session-limit fixture transcript → returns the verbatim
    `You've hit your session limit · resets 3pm (America/Toronto)`.
  - server-rate-limit fixture → returns the verbatim
    `API Error: Server is temporarily limiting requests …`.
  - `transcript_path` missing / file unreadable / no `isApiErrorMessage` line →
    returns `Claude stopped: API error (rate_limit)` (fallback uses `error_type`).
  - unparseable stdin → returns `nil`.
- **`ClaudeHookOverlayTests`** — update `registersStopFailureNotifyHook`: the
  `StopFailure` command now contains `tbd hooks stop-failure` and
  `tbd notify --type error`, and no longer contains an inline `error_type`.
- **`NotificationSoundPlayer`** — verify `.error` resolves the error sound and a
  non-error type resolves the default. Per CLAUDE.md's UserDefaults-isolation
  rule, drive `@AppStorage` through a `UserDefaults(suiteName:)` test suite and
  tear it down with `removePersistentDomain(forName:)` — never touch
  `UserDefaults.standard`. (If `@AppStorage` proves awkward to isolate, the
  resolution logic may be extracted to a pure helper that takes the
  name/custom-path pair and is tested directly.)

## Out of scope

- No reset-time parsing or message reformatting — the verbatim text already
  carries the reset time (explicit design choice).
- No new `NotificationType`, RPC method, or DB column.
- Codex sessions remain uncovered (separate hook system; deferred).

## Affected files

- Create: `Sources/TBDCLI/Commands/StopFailureCommand.swift`
- Modify: `Sources/TBDCLI/Commands/HooksCommand.swift` (register subcommand)
- Modify: `Sources/TBDDaemon/Hooks/ClaudeHookOverlay.swift` (`stopFailureCommand`)
- Modify: `Sources/TBDApp/Services/NotificationSoundPlayer.swift`
- Modify: `Sources/TBDApp/AppState.swift` (pass type at call site)
- Modify: `Sources/TBDApp/Settings/SettingsView.swift` (error-sound picker)
- Tests: new `StopFailureMessage` tests (TBDCLI test target);
  `Tests/TBDDaemonTests/ClaudeHookOverlayTests.swift`; `NotificationSoundPlayer` test.
