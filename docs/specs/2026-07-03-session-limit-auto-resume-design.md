# Session-Limit Auto-Resume — Design

**Date:** 2026-07-03
**Status:** Approved design, pre-implementation
**Branch:** `session-limit-auto-resume`

## Problem

When a Claude Code session hits the subscription usage limit, the TUI parks on
"You've hit your session limit · resets 1pm (America/Toronto)" and the turn
dies. Claude Code has no native wait-and-continue (it is one of the
most-requested open features: anthropics/claude-code #18980, #36320, #38263,
#47276, #62788), so every affected TBD terminal sits dead until the user
notices and types `continue` by hand — hours later if they stepped away.

TBD should detect the limit the moment it happens, schedule a resume for the
reset time, and type `continue` into the still-open pane — unattended, across
every managed worktree.

## Constraints

- **No screen scraping.** Detection rides Claude Code hooks + the transcript
  JSONL only. TBD already removed pane-text matching once (see
  `SuspendResumeCoordinator.swift` history) because CLI display text churns
  across versions; the two community tools studied (claude-auto-retry,
  autoclaude) spent most of their bug-fix history on exactly that churn.
- **Actuation goes through the existing send API** (`handleTerminalSend` /
  `TmuxManager.sendKeys`/`sendKey`), never raw `tmux` invocations. The
  in-flight control-mode work (`tbd/control-mode-phase-a`) adds a sidecar path
  for *app* keystrokes but does not touch daemon-initiated sends; staying
  behind the API means a future phase that reroutes daemon sends carries this
  feature along.
- **Migration-number coordination:** control-mode-phase-a also adds a DB
  migration (`controlModeEnabled`). Whichever branch lands second renumbers
  its migration.
- **Gated, default OFF.** Global toggle, consistent with auto-suspend's
  opt-in convention. Detection/notification runs regardless; only the
  scheduled send is gated. Both branches get tests (CLAUDE.md rule).

## Detection

`StopFailure` is the signal: it fires when a turn dies on an API error, and
TBD's overlay hook (`ClaudeHookOverlay.swift`) already routes it through
`tbd stop-failure` (`TBDCLI/Commands/StopFailureCommand.swift`), which already
reads the last `isApiErrorMessage == true` record from the transcript.

Extend that command:

1. **Structured first.** If the last API-error record carries
   `rate_limit_info` (`status: "rejected"`, `resetsAt` epoch,
   `rateLimitType`), take `resetsAt` verbatim. No text parsing, no timezone
   math, weekly limits included for free.
2. **Text fallback.** If `rate_limit_info` is absent but the message matches a
   hard-limit pattern, parse the display text
   (`resets 3pm (America/Toronto)`): hour, optional `:MM`, optional am/pm,
   optional parenthesized IANA zone. Use Foundation `Calendar` +
   `TimeZone(identifier:)` for the conversion (not offset arithmetic — that
   was claude-auto-retry's nastiest bug, off by ~24h in UTC+10). Rules:
   - no am/pm and hour 1–12 → compute both candidates, take the nearest
     future one;
   - parsed instant already past → add a day;
   - unparseable → notify only, never schedule.
3. **Parse once, persist the absolute timestamp.** Never re-derive from
   display text later (autoclaude's flagship bug: re-parsing "resets 3pm"
   after 3pm rolls the deadline to tomorrow forever).

**Hard-limit vs transient discrimination.** Both arrive as
`error_type == rate_limit`. Schedule only when the message matches
`hit your <qualifier> limit` (qualifier drifts: *session* / *weekly* /
*5-hour* — allow a few arbitrary words, per claude-auto-retry issue #15) or
structured `rate_limit_info` marks a rejection with a reset. Explicitly
exclude `temporarily limiting requests (not your usage limit)` and transient
`429/5xx/529` — Claude Code retries those itself, and racing its internal
retry loop was a documented community-tool failure mode.

On a hit, the CLI calls a new RPC `rateLimitDetected` with
`{terminalID, resetsAt, limitType, rawMessage}`. Existing error notification
behavior is preserved for non-limit StopFailures.

## State

New migration (next free `vN` at land time):

- **`scheduled_resumes` table:** id, terminalID, worktreeID, claudeSessionID,
  resetsAt, limitType, rawMessage, createdAt, status
  (`pending` / `sent` / `cancelled` / `failed`), attemptCount.
  **At most one `pending` row per terminal** — the row is the double-send
  latch (double-sends were the worst production bug in both mined tools).
- **Daemon config:** `autoResumeOnLimitReset` (bool, default false), set from
  the app via RPC. Daemon-side because the daemon must act while the app is
  closed.
- **`Terminal.pendingResumeAt: Date?`** in `TBDShared/Models.swift`
  (optional — decode-compat rule), populated from the pending row and
  broadcast via delta for UI. Activity state machine is untouched.

Rows survive daemon restarts; on startup, `pending` rows reload into the
scheduler and past-due rows fire immediately (covers Mac sleep and multi-day
weekly-limit waits).

## Scheduler

New daemon actor `LimitResumeScheduler`, cloned from `ClaudeUsagePoller`'s
shape: min-deadline sleep via injected clock, `wake()` on insert/cancel.

Fire time = `resetsAt + 60s slack + jitter(0–30s per terminal)`.
Slack because server-side resets are not millisecond-precise (claude-auto-retry
ships 60s; autoclaude dropped its slack in a rewrite and fired too early);
jitter so N panes on the same account don't stampede the API at the same
second.

## Actuation

At fire time, in order — every step is a mined landmine:

1. **Terminal alive.** Terminal alive; toggle still on.
2. **User-already-continued.** If the transcript has any record newer than
   the limit record, mark `cancelled`, send nothing.
3. **Foreground.** Claude is the pane's foreground process — check
   `ps -o stat=` for the `+` flag, because tmux `#{pane_current_command}`
   reports `zsh` on macOS. Never type into a bare shell. Checked before
   copy-mode: a dead/backgrounded shell should classify `failed` rather than
   endlessly rescheduling on a stale copy-mode flag.
4. **Copy-mode.** If `#{pane_in_mode}` is set, the send would go to copy-mode,
   not Claude — and cancelling copy-mode would yank the user out of scrollback.
   Reschedule +2min, up to 15 attempts (~30min), then mark `failed` with an
   attention notification — don't cancel their scroll.
5. **Send sequence** (via `handleTerminalSend`-level API):
   `Escape` → sleep 150ms → `send-keys -l "continue"` → sleep 150ms →
   `Enter` as a separate named-key call.
   - Escape first: at the limit, newer Claude Code opens the
     `/rate-limit-options` menu whose *highlighted default can be "Upgrade
     your plan"* and whose option order varies by version — a blind Enter can
     confirm a paid upgrade. Escape dismisses and can never select.
   - The 150ms pauses: Claude's TUI drops keys during UI transitions
     (autoclaude shipped "ontinue"), and text+Enter in one send-keys call is
     treated as a bracketed paste — the Enter becomes a literal newline and
     nothing submits.
6. **Verify.** Within ~20s expect the activity hook to report `working` (or
   the transcript to grow). Success → status `sent` + success notification.
   No signal → one retry of steps 1–5 (eligibility is re-checked fresh on the
   retry — a copy-mode or user-continued state entered during the first
   attempt's verify window is caught before blindly resending), then status
   `failed` + attention notification. (autoclaude never verified; a swallowed
   send was silently
   lost.)

## Cancellation

A pending row is cancelled by: `UserPromptSubmit` hook firing for that
terminal (user continued manually), terminal close/suspend, global toggle
switched off (cancels all pending), or explicit user action ("Cancel
scheduled resume" in the terminal context menu / notification).

The scheduler also cancels early, before `fireAt`: on its own loop cadence it
runs step 2's **user-already-continued** predicate against every not-yet-due
row, so a session whose transcript grew (user typed, or Claude Code recovered
its own turn — which fires no `UserPromptSubmit`) drops its badge right away
instead of wearing "auto-resume scheduled" until fire time. Same verdict as
the fire-time check, reached sooner.

## UI

- New `NotificationType` case `limit_reached`: toggle on → "Session limit hit
  — auto-resume scheduled for 1:01pm"; toggle off → "Session limit hit —
  resets 1pm". Outcome notifications on `sent` / `failed`.
- Terminal row badge with countdown, driven by `pendingResumeAt`
  ("⏳ resumes 1:01pm").
- Settings toggle: "Auto-resume Claude sessions when the usage limit resets"
  (default off).

## Testing

- **Extraction fixtures** from real-world captures: `rate_limit_info`
  present/absent; delimiters `·` / `-` / `.`; wordings "You've hit your
  session limit · resets 4:50pm (Asia/Shanghai)", "…weekly limit · resets 9am
  (Europe/London)", "5-hour limit reached - resets 3pm (UTC)", "Claude usage
  limit reached. Resets at 2pm", "You're out of extra usage · resets 3pm";
  transient exclusions ("temporarily limiting requests (not your usage
  limit)", `API Error: 529`).
- **Text-fallback parsing:** day rollover, ambiguous am/pm → nearest future,
  invalid timezone → notify-only.
- **Scheduler:** injected clock; restart reload; past-due fires immediately;
  one-pending-per-terminal latch; cancellation paths.
- **Gate:** toggle off → row recorded + notification, no send scheduled;
  toggle on → scheduled. (Both branches, per CLAUDE.md.)
- **End-to-end seam:** debug RPC that fakes a `rateLimitDetected` with
  `resetsAt = now + 1min`, exercising schedule → actuate → verify without
  burning a real limit (autoclaude's `--test-pattern`, upgraded).
- **Live tmux test** for the send sequence (rc-free bootstrap, 15s deadlines),
  run with the control-mode flag off and on.

## Out of scope (v1)

- Respawning a dead pane at reset via `claude --resume` (the TUI stays alive
  at the limit screen; a dead pane gets a notification instead).
- Codex terminals.
- Per-terminal/per-worktree enable overrides.
- Cross-checking reset times against the usage API
  (`ModelProfileUsage.fiveHourResetsAt` — API-key profiles only).
- Draft-text protection (user's half-typed prompt in the input box when the
  resume fires; Escape does not clear a draft, so `continue` would append).
  Accepted risk in v1, noted for follow-up.

## Sources

- Codebase survey: `ClaudeHookOverlay.swift`, `StopFailureCommand.swift`,
  `ClaudeUsagePoller.swift`, `SuspendResumeCoordinator.swift`,
  `RPCRouter+TerminalHandlers.swift` (`handleTerminalSend`),
  `TmuxManager.swift`.
- Mined: `cheapestinference/claude-auto-retry` (18 commits; DESIGN-NOTES
  verified StopFailure payload/semantics against a decompiled v2.1.195
  binary) and `henryaj/autoclaude` (54 commits, tmux actuation lessons).
