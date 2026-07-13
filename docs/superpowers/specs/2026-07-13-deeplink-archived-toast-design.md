# Deep-link toast + cancellable countdown for archived worktrees

**Date:** 2026-07-13
**Status:** Approved

## Problem

Clicking a `tbd://open?worktree=<uuid>` deep link whose target worktree is archived gives no feedback for several seconds, then abruptly navigates to the archived row after the user may have moved on. The delay is the archived-worktree lookup (`listWorktrees(status: .archived)` RPC) plus, on cold start, app launch and initial state load. There is no indication that (a) the app is looking, (b) the target is archived, or (c) navigation is about to happen. A deep link with a stale/deleted UUID fails completely silently.

Current flow: `DeepLinkHandler.handle` → `AppState.navigateToWorktree` → active-list miss → `navigateToArchivedWorktree` (`Sources/TBDApp/AppState+Worktrees.swift:480-511`) → select repo, flash-highlight the archived row for ~0.9s. The app is only activated after the lookup completes. No revive is triggered (reviving stays a manual action from the archive list).

## Goals

- Immediate feedback ("Looking for worktree…") when a deep-link target is not in the active worktree list.
- A visible, cancellable 5-second countdown before navigating to the archive entry, so navigation is never a surprise.
- Hovering the toast cancels the countdown **permanently**; the toast then offers an explicit "Go to archive entry" CTA and a dismiss button.
- Surface the previously-silent not-found and RPC-failure cases.

## Non-goals

- Auto-reviving the archived worktree (stays a manual action; explicitly decided).
- Toast queueing/stacking (one toast at a time; a new toast replaces the current one).
- Scratch-space deep links (deep links carry repo-worktree UUIDs only today).
- A third-party toast dependency (evaluated SimpleToast/AlertToast; the shell they provide is ~50 lines of SwiftUI and the interactive content — hover-cancel, countdown, CTA — is custom regardless).
- A feature flag (small additive UI; countdown-gated navigation is a softer version of the navigation that already ships).

## Design

### Behavior state machine

1. **Active hit** — target found in active worktrees → navigate immediately, no toast (unchanged).
2. **Active miss** — activate the app immediately (today activation waits for the lookup; the toast must be visible to be useful), show toast in **looking** state: spinner + "Looking for worktree…". Run the archived lookup.
3. **Found archived** — toast transitions to **countdown** state: "'{display name}' is archived — showing its archive entry in {n}…", n counting 5→1 at 1s intervals.
   - **Countdown expires** → perform the existing navigation tail (select repo, populate archived rows, scroll to + highlight the row), dismiss the toast.
   - **Pointer enters the toast** → cancel the countdown permanently (no resume on exit). Toast transitions to **cancelled** state: same message minus the countdown, plus a **"Go to archive entry"** CTA button and a ✕ dismiss button. CTA click → navigate + dismiss. ✕ → dismiss only.
4. **Not found** (stale/deleted UUID) — toast transitions to **error** state: "Worktree not found — it may have been deleted." Auto-dismisses after ~4s.
5. **Lookup RPC failure** — same error state with the failure message.

A new deep link arriving while a toast is active cancels the in-flight countdown task and replaces the toast (restart the state machine for the new UUID).

Cold-start deep links keep the existing buffering (`pendingDeepLinkID`); the toast flow begins when the buffered link is drained after initial state load.

### Components

**`ToastState`** (new, `Sources/TBDApp/`) — a value published on `AppState` (e.g. `@Published var activeToast: Toast?`). `Toast` carries: `id`, message text, style (`.progress`, `.countdown(secondsRemaining:)`, `.action(ctaLabel:)`, `.error`), optional CTA action, dismissability. Deliberately minimal and reusable — deep-link is the first client; future banners (Nightwatch-style advisories) can adopt it, but no queueing until a second client needs it.

**`ToastOverlay`** (new view) — attached via `.overlay(alignment: .bottom)` on `ContentView`. Rounded-rect material background, `.transition(.move(edge: .bottom).combined(with: .opacity))`, `onHover` forwarded to AppState (the view reports hover; AppState decides state transitions). Spinner for `.progress`, live seconds for `.countdown`, CTA + ✕ buttons for `.action`.

**Countdown ownership** — the 5→1 tick loop is a `Task` owned by AppState (injectable tick duration for tests), not the view, so expiry navigation fires even if the view rebuilds. Hover-cancel and link-replacement cancel this task.

**Touched existing code** — `navigateToArchivedWorktree` grows the toast transitions and moves its navigation tail behind the countdown; app activation moves to the start of the miss path. `DeepLinkHandler` and the daemon are untouched. No RPC or DB changes.

### Error handling

- RPC failure or worktree-not-found → error toast (auto-dismiss ~4s); never silent.
- Countdown task cancellation on: hover, toast replacement, ✕ dismiss, CTA click.
- If navigation-on-expiry runs while the user has since navigated elsewhere manually, it still performs the archive navigation (same as today's late navigation, but now announced).

## Testing

- Unit tests on the state machine with injectable tick duration (no real 5s sleeps):
  - active miss → `.progress` toast shown, app activation requested
  - found archived → `.countdown` starting at 5
  - tick progression 5→1 → navigation callback fired exactly once, toast dismissed
  - hover during countdown → task cancelled, state becomes `.action` with CTA; no navigation ever fires
  - CTA click → navigation fired + dismissed; ✕ → dismissed, no navigation
  - not-found / RPC error → `.error` state, auto-dismiss
  - second deep link mid-countdown → first task cancelled, state machine restarted for new UUID
- Live verification (per project lesson: transcript/UI bugs are live-only): trigger `open "tbd://open?worktree=<archived-uuid>"` against a running bundled app, screenshot the toast in looking/countdown/cancelled states, verify hover-cancel with a real pointer.

## Open questions

None.
