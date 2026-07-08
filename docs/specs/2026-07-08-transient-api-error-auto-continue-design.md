# Transient API-Error Auto-Continue — Design

**Date:** 2026-07-08
**Status:** Approved design, pre-implementation
**Branch:** `transient-api-error-auto-continue`
**Parent feature:** [Session-Limit Auto-Resume](2026-07-03-session-limit-auto-resume-design.md) (PR #341, race fix PR #375)

## Problem

Claude Code turns die intermittently on transient API errors —
"API Error: Connection closed mid-response. The response above may be
incomplete." — and the session parks until a human types `continue`.
Fleet telemetry from the live TBD database shows this is a daily-plus
occurrence: in one 24h window (2026-07-07/08) there were 4 connection-closed
deaths, 1 bare `server_error`, and 2 transient-429 deaths across different
worktrees. Each one stopped an agent project mid-flight.

The session-limit auto-resume pipeline (detection → `scheduled_resumes` →
`LimitResumeScheduler` → `LimitResumeActuator`) already does everything
needed except classify these errors as retryable. This feature extends it:
auto-type `continue` after a short backoff, behind a separate opt-in toggle.

## Evidence (captured from the 2026-07-08 14:13 incident)

Transcript record for a connection-closed death:

- `isApiErrorMessage: true`
- `error: "server_error"` (coarse class — same field the CLI already reads)
- `rate_limit_info: null`
- message text: `API Error: Connection closed mid-response. The response
  above may be incomplete.`
- Single error record; the turn died immediately (no internal-retry records
  after it).

A same-day counterexample (2026-07-07 20:57) produced the fallback
notification "Claude stopped: API error (server_error)" — i.e. **no message
text was recoverable**. The classifier must handle the text-absent case.

Non-retryable counterexample from the same window: two agent runs died on an
**expired OAuth token**. Auto-continuing those is useless — every attempt
fails identically. This motivates the allowlist.

## Classification

New shared classifier in `TBDShared` alongside `RateLimitDetection`,
splitting StopFailures three ways, checked in order:

1. **Hard limit** — existing `RateLimitDetection` path, byte-for-byte
   unchanged, always checked first.
2. **Transient** (new) — schedules an auto-continue when either:
   - the message text matches the transient allowlist:
     - `Connection closed mid-response`
     - `temporarily limiting requests` (the "(not your usage limit)" 429)
     - `API Error: 5xx` — 500 / 502 / 503 / 529 — and `Overloaded`
     - request-timeout wordings (`timed out`, `timeout`)
   - **or** the error class field is `server_error` (definitionally 5xx;
     covers the text-absent case observed live).
3. **Other** — notification only, behavior unchanged. Includes: auth errors
   (OAuth / 401 / 403 / invalid API key), billing (`credit balance`),
   `rate_limit` class without hard-limit text (could be a hard limit whose
   text we failed to read — never blind-retry it), and anything
   unrecognized. Unknown errors are excluded by construction (allowlist,
   not denylist).

Detection mechanics reuse the PR #375 shape exactly: payload text fields
first (`last_assistant_message`, `error_details` — race-free), then the
recency-floored, bounded-retry transcript read. The classifier gains
outcomes; the read path does not change.

**Why this doesn't conflict with the parent spec's transient exclusion.**
The parent spec excluded transient errors because community tools raced
Claude Code's *internal* retry loop. StopFailure fires only when the turn
has already died (internal retries exhausted), and the actuator's
user-already-continued and foreground checks catch any session that
recovered during the backoff window. The parent's exclusion applied to
*scheduling a limit-reset resume* off transient errors — that rule stands;
this feature schedules a *short-delay continue* instead, which is what a
human does today.

## RPC and backoff

New RPC `claude.transientApiErrorDetected` with
`{terminalID, errorClass, rawMessage}`. **No `resetsAt` from the CLI** —
the CLI is stateless and cannot know the attempt number. The daemon
computes `fireAt = now + step`.

Backoff steps: **60s → 2m → 5m → 10m**, then give up.

- **Consecutive counting:** the attempt number = count of this terminal's
  `api_error` rows with status `sent` or `failed` created within a 30-minute
  lookback window. (A `sent` row followed by another transient StopFailure
  inside the window = our continue was typed and the turn died again.)
- **Give-up:** past the 4th consecutive attempt, no row is inserted;
  instead an attention notification: "Auto-continue gave up after 4
  attempts — <error text>".
- **Reset:** a resume whose turn survives simply stops producing
  StopFailures; once the lookback window slides past the old rows, the
  chain restarts at 60s. No explicit reset bookkeeping.

Existing `claude.rateLimitDetected` RPC is untouched.

## State

**No migration.** Rows reuse `scheduled_resumes` verbatim with
`limitType = "api_error"`, `rawMessage` = the error text,
`resetsAt` = computed fire time. Existing status lifecycle
(`pending`/`sent`/`cancelled`/`failed`) and `attemptCount` apply.

- **Shared one-pending-per-terminal latch** — deliberate: a pending
  limit-reset resume blocks a redundant `api_error` row and vice versa
  (whichever fires will revive the session; the other would double-send).
- **Config:** `autoResumeOnApiError` (bool, default **false**), daemon-side
  next to `autoResumeOnLimitReset`, set from the app via the existing
  config RPC. Detection and notification always run; only scheduling is
  gated (same convention as the parent).
- `Terminal.pendingResumeAt` broadcast works unchanged.

## Actuation

Byte-identical to the limit path — same `LimitResumeActuator` code:

1. Eligibility ladder unchanged: terminal alive → toggle on → row still
   pending → user-already-continued (transcript newer than incident) →
   Claude foreground (`ps -o stat=` `+`) → copy-mode reschedule.
   The toggle check reads **`autoResumeOnApiError` for `api_error` rows**
   and `autoResumeOnLimitReset` for the rest.
2. Send sequence unchanged: `Escape` → 150ms → `send-keys -l "continue"` →
   150ms → separate `Enter`. (Escape is harmless here — no
   `/rate-limit-options` menu — and still protects against UI-transition
   key drops.)
3. Verify unchanged: ~20s for activity/transcript signal, one full
   re-checked retry, then `failed` + attention notification.

## Cancellation

Same choke points as the parent, plus toggle scoping:

- `UserPromptSubmit` for the terminal, terminal close/suspend, hibernation
  parking, explicit "Cancel scheduled resume" — cancel any pending row
  regardless of type (unchanged).
- **`autoResumeOnApiError` switched off cancels pending `api_error` rows
  only**; `autoResumeOnLimitReset` off cancels only limit rows.

## UI

- Settings toggle under the existing one: "Auto-continue after transient
  API errors (connection drops, server errors)" — default off.
- Notifications: toggle on → "API error — auto-continue in 60s
  (attempt 2/4)"; toggle off → today's error notification, unchanged.
- Terminal badge reuses the existing `pendingResumeAt` badge
  ("⏳ resumes 2:34pm").

## Testing

- **Classifier fixtures from real captures:** connection-closed with
  `error: server_error`; text-absent `server_error`; OAuth/401 and
  credit-balance exclusions; transient-429 text vs hard-limit 429
  (hard-limit precedence); unknown error class → excluded.
- **Backoff:** consecutive counting across the lookback window; step
  progression 60s→2m→5m→10m; give-up at cap emits notification and no row;
  window-slide reset; latch interaction (pending limit row blocks
  `api_error` insert).
- **Toggle gates, both branches** (CLAUDE.md rule): off → notification
  only, no row; on → row scheduled. For BOTH toggles independently —
  api_error rows must not fire when only `autoResumeOnLimitReset` is on,
  and vice versa.
- **Debug seam:** `tbd hooks fake-rate-limit` grows an `--api-error` mode
  (injects at the RPC seam, exercises schedule → actuate → verify).
- **Real-hook E2E (PR #375 lesson):** at least one verification feeds a
  synthetic StopFailure payload through `tbd hooks stop-failure` stdin —
  the seam-injected test validates nothing upstream of the RPC.

## Out of scope (v1)

- Per-terminal/per-worktree enable overrides.
- Retrying auth/billing errors, or any denylist-based broadening.
- Codex terminals.
- Draft-text protection (same accepted risk as parent).
- Distinct badge wording for short retries ("⏳ retrying in 1m").

## Sources

- Live captures: TBD `state.db` notification log 2026-07-07/08; transcript
  `8C72C1FC-…EE0C.jsonl` (worktree `20260708-crucial-porcupine`) record at
  `2026-07-08T14:13:16.555Z`.
- Parent design + mined community-tool gotchas:
  [2026-07-03-session-limit-auto-resume-design.md](2026-07-03-session-limit-auto-resume-design.md).
