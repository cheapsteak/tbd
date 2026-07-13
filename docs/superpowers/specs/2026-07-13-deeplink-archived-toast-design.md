# Deep-link toast for archived worktrees

**Date:** 2026-07-13
**Status:** Approved; amended 2026-07-13 — countdown dropped per user feedback, auto-navigate on lookup

## Problem

Clicking a `tbd://open?worktree=<uuid>` deep link whose target worktree is archived gives no feedback for several seconds, then abruptly navigates to the archived row after the user may have moved on. The delay is the archived-worktree lookup (`listWorktrees(status: .archived)` RPC) plus, on cold start, app launch and initial state load. There is no indication that (a) the app is looking, (b) the target is archived, or (c) navigation is about to happen. A deep link with a stale/deleted UUID fails completely silently.

Current flow: `DeepLinkHandler.handle` → `AppState.navigateToWorktree` → active-list miss → `navigateToArchivedWorktree` (`Sources/TBDApp/AppState+Worktrees.swift:480-511`) → select repo, flash-highlight the archived row for ~0.9s. The app is only activated after the lookup completes. No revive is triggered (reviving stays a manual action from the archive list).

## Goals

- Immediate feedback ("Looking for worktree…") when a deep-link target is not in the active worktree list.
- Navigate to the archive entry immediately once the lookup resolves, with a brief auto-dismissing notice explaining that the target is archived, so landing in the archive view is never a surprise.
- Surface the previously-silent not-found and RPC-failure cases.

## Non-goals

- Auto-reviving the archived worktree (stays a manual action; explicitly decided).
- Toast queueing/stacking (one toast at a time; a new toast replaces the current one).
- Scratch-space deep links (deep links carry repo-worktree UUIDs only today).
- A third-party toast dependency (evaluated SimpleToast/AlertToast; the shell they provide is ~50 lines of SwiftUI and the state machine — progress/notice/error styling plus the AppState-owned auto-dismiss — is custom regardless).
- A feature flag (small additive UI; the announced navigation is a softer version of the navigation that already ships).

## Design

### Behavior state machine

1. **Active hit** — target found in active worktrees → navigate immediately, no toast (unchanged).
2. **Active miss** — activate the app immediately (today activation waits for the lookup; the toast must be visible to be useful), show toast in **looking** state: spinner + "Looking for worktree…". Run the archived lookup.
3. **Found archived** — navigate immediately: perform the existing navigation tail (select repo, populate archived rows, scroll to + highlight the row), and show a **notice** toast "'{display name}' is archived — showing its archive entry" that auto-dismisses after ~4s so the archive landing is explained rather than surprising. No countdown, no CTA, no hover semantics.
4. **Not found** (stale/deleted UUID) — toast transitions to **error** state: "Worktree not found — it may have been deleted." Auto-dismisses after ~4s.
5. **Lookup RPC failure** — same error state with the failure message.

A new deep link arriving while a toast is active navigates immediately for the new UUID and replaces the toast (the previous toast's auto-dismiss task is cancelled).

Cold-start deep links keep the existing buffering (`pendingDeepLinkID`); the toast flow begins when the buffered link is drained after initial state load.

### Components

**`ToastState`** (new, `Sources/TBDApp/`) — a value published on `AppState` (e.g. `@Published var activeToast: Toast?`). `Toast` carries: `id`, message text, style (`.progress`, `.notice`, `.error`). Deliberately minimal and reusable — deep-link is the first client; future banners (Nightwatch-style advisories) can adopt it, but no queueing until a second client needs it.

**`ToastOverlay`** (new view) — attached via `.overlay(alignment: .bottomTrailing)` on `ContentView`. Rounded-rect material background, `.transition(.move(edge: .trailing).combined(with: .opacity))`. Purely presentational: spinner for `.progress`, archivebox icon for `.notice`, warning icon for `.error` — no interactive controls. Anchored bottom-**right**, not bottom-center: live verification found a bottom-center banner too disruptive (it sits over the content the user is reading), so the toast slides in from the trailing edge.

**Auto-dismiss ownership** — transient toasts (`.notice`, `.error`) schedule a `toastDismissTask` on AppState (injectable tick duration for tests), not the view, so the ~4-tick dismiss fires even if the view rebuilds. Showing or dismissing a toast cancels any prior dismiss task, so a replaced toast's timer can't clear its successor.

**Touched existing code** — `navigateToArchivedWorktree` navigates immediately once the lookup resolves and shows the notice toast; app activation moves to the start of the miss path. `DeepLinkHandler` is untouched.

Two guards protect the auto-navigation against races:

- **Request-generation guard (F1)** — two deep links (A then B) can have overlapping archived lookups that resolve out of order; without a guard, A's late resolution would navigate to A after B already won. A fresh `deepLinkRequestID` token is stamped at the start of every `navigateToArchivedWorktree` call; after the lookup resolves (success or throw), a stale resolution whose token no longer matches is dropped before it touches toast/navigation state. Mirrors the `revivingArchived` re-entrancy guard.
- **Reconcile-refresh (F2)** — navigation uses the archived snapshot captured at lookup time; with the fast deep-link lookup (`includeSessionCounts: false`) this snapshot skips per-row session-count enrichment, and can be briefly stale for since-deleted/revived worktrees. After the navigation tail runs, `performArchivedNavigation` kicks a `refreshArchivedWorktrees(repoID:)` to reconcile with fresh repo-scoped, paginated data (which also restores the per-row session-count enrichment).

**RPC change (additive, opt-out)** — `worktree.list` gains an additive `includeSessionCounts: Bool?` flag. The deep-link archived lookup passes `includeSessionCounts: false` so the daemon skips per-row Claude-session enrichment; this was added post-approval after live verification measured ~19s to enrich 1074 archived rows. Default (`nil`/`true`) preserves the enriched behavior for every existing caller. No DB changes.

### Error handling

- RPC failure or worktree-not-found → error toast (auto-dismiss ~4s); never silent.
- Auto-dismiss task cancellation on: toast replacement, explicit dismiss.
- Navigation runs as soon as the lookup resolves; if the user has since navigated elsewhere manually, the archive navigation still lands them on the target (announced by the notice toast).

## Testing

- Unit tests on the state machine with injectable tick duration (no real 4s sleeps):
  - active miss → `.progress` toast shown, app activation requested
  - active hit → no toast, worktree selected
  - found archived → navigates immediately (repo selected, row highlighted, archived rows populated) and shows a `.notice` toast naming the worktree, which then auto-dismisses
  - transient toasts (`.notice`, `.error`) auto-dismiss after ~4 ticks
  - showing a new toast cancels the prior toast's auto-dismiss task so it can't clear the replacement
  - not-found / RPC error → `.error` state, auto-dismiss. The `archivedLookupOverride` test seam is `throws`-typed so a thrown error exercises the same `showErrorToast("Couldn't look up the worktree: …")` branch as a real RPC failure.
  - second deep link → navigates immediately for the new UUID; only the newer link's repo is selected
  - stale lookup resolution (F1) → an older request resolving after a newer one superseded it is dropped by the request-generation guard (no navigation to the stale target, no stale toast)
- Live verification (per project lesson: transcript/UI bugs are live-only): trigger `open "tbd://open?worktree=<archived-uuid>"` against a running bundled app, confirm it lands on the archive entry immediately and the notice toast appears then auto-dismisses.

## Open questions

None.
