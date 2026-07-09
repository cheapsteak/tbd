# Re-run the preSession hook from the worktree context menu

**Date:** 2026-07-08
**Status:** Approved, pending implementation

## Problem

The `preSession` hook runs exactly once per worktree lifecycle event — at create, at revive,
and on daemon-crash recovery. In practice it sometimes needs to run more than once: a `npm
install` that raced a lockfile change, a `brew bundle` that failed on a transient network
error, a hook the user just edited and wants to try again.

Today the only ways to re-run it are to archive and revive the worktree (destroying the live
Claude session) or to create a fresh worktree. Both are wildly disproportionate to "run that
script again".

Separately, the hook's terminal tab lingers forever. `preSessionCommand` ends in `exec $shell`,
so every worktree that has a hook carries a spent `pre-session` tab for the rest of its life.
With a re-run action that lingering becomes N tabs.

## Goals

- Add a **Re-run setup hook** item to the worktree context menu.
- Make the hook tab **ephemeral on success**, in both the create flow and the re-run flow.
- Keep the tab **on failure**, because that's where the error output is.
- Never disturb a running agent.

## Non-goals

- No CLI command (`tbd hook run preSession`). Not requested; the RPC makes it trivial later.
- No re-running of the other four hooks (`setup`, `archive`, `preMerge`, `postMerge`).
- No progress banner for the re-run. The existing banner exists to explain why the agent hasn't
  started yet; on a re-run the agent is already running, so there is nothing to explain.

## Behavior

Right-click a worktree row → **Re-run setup hook**, in its own section between the
spawning group and `Open in Finder`:

```
Rename...
Archive
─────────────────────
Wake
Hibernate now
─────────────────────
Fork session
Create Nested Worktree
New worktree from this branch…
─────────────────────
Re-run setup hook
─────────────────────
Open in Finder
Copy Path
```

- Shown on **regular worktree rows and scratch-space rows**. Absent from main/creating rows.
- Shown **only when a `preSession` hook resolves** for that worktree. No hook, no item.
- Clicking it spawns a `pre-session` tab that runs the hook. **Focus does not move to it**, and
  running agents are left completely alone — not killed, not parked.
- Exit 0 → the tab closes itself.
- Non-zero exit, timeout, or the user killing the pane → the tab stays open, dropped into a
  shell with the output on screen, and the existing `.error` notification fires.
- Clicking it while a run is already in flight → the daemon rejects it and the app shows
  `Setup hook is already running for this worktree.`

## Design

### 1. Ephemeral hook tab

`waitForPreSessionCompletion` (`WorktreeLifecycle+PreSession.swift:201-234`) already resolves the
marker-vs-pane-death race correctly: it re-reads the marker before concluding `.paneKilled`, and
again after the deadline before concluding `.timedOut`. Making the hook's shell command exit on
success would fight that machinery and reintroduce the race it was written to close.

So **`preSessionCommand` is unchanged**. Teardown happens at the observer instead.

In `runPreSessionPhase3`, after the outcome is known:

| Outcome | Tab | Notification |
| --- | --- | --- |
| `.completed(exitCode: 0)` | killed, row deleted, `.terminalRemoved` broadcast | none |
| `.completed(non-zero)` | kept | `.error` (existing) |
| `.timedOut` | kept | `.error` (existing) |
| `.paneKilled` | already gone | `.error` (existing) |

Ordering constraint: on the success path, **spawn the primary terminals first, then close the
hook tab**, so the worktree is never momentarily tab-less.

`spawnPrimaryTerminals(preSessionTerminalID:)` splices the hook tab into tab order at index 1
(`WorktreeLifecycle+Create.swift:735-736`). On the success path phase 3 passes `nil` instead, so
the tab is never inserted rather than inserted-then-removed.

Teardown reuses the kill-window + delete-row + broadcast sequence that `handleTerminalDelete`
(`RPCRouter+TerminalHandlers.swift:433`) already performs; that sequence is extracted into a
lifecycle helper both call sites share.

### 2. Manual re-run

New RPC method `worktree.rerunPreSession`, params `{ worktreeID: UUID }`.

Handler (`RPCRouter+WorktreeHandlers.swift`):

1. Load the worktree; resolve the hook. Unresolved → `RPCError`. (Defense in depth — the app
   already hides the item — but the app's view can be stale by a keystroke.)
2. Reject if a run is already in flight for this worktree ID (see §3).
3. `spawnPreSessionTerminal(...)`, reusing phase 2b.
4. Return `.ok()` immediately. A detached task awaits the outcome and applies §1's teardown or
   notification.

Two changes to `spawnPreSessionTerminal` to make it reusable:

- Lines 169-170 unconditionally call `setTabOrder(tabIDs: [terminalID])` and
  `setActiveTabID(...)`. That's correct for create — the hook tab is the *only* tab — and wrong
  for a re-run. Gate both behind a parameter (`claimsFocus: Bool`, true from phase 2b, false from
  the re-run path); the re-run path appends to the existing tab order and leaves `activeTabID`
  alone.
- The stale-marker delete at line 130 stays; it is exactly what a re-run needs.

The wait → teardown/notify tail becomes a shared `finishPreSessionRun(...)`. Phase 3 calls it and
then does its create/revive-specific work (primary spawn, status flip). The re-run path calls it
and stops. **The re-run path never touches worktree status and never spawns primary terminals.**

### 3. Concurrency guard

`WorktreeLifecycle` holds an in-memory `Set<UUID>` of worktree IDs with a pre-session run in
flight. Inserted before the terminal spawn, removed in the detached task's `defer`. The RPC
rejects a second run with a distinct error.

Explicitly **not** modeled as UI state. After §1, a lingering `pre-session` tab means "the last
run failed", not "a run is in progress", so the app cannot infer running-ness from the tab
existence it already tracks (`AppState+Terminals.swift:47`). A true disabled menu item would need
a new `StateDelta` case plus a transient field on the worktree snapshot to survive an app relaunch
mid-run — real state-sync plumbing for a grey row the user would rarely see, since the common
case is re-running *after* a failure, when nothing is in flight. A clear alert is the better
trade.

### 4. Sharing the resolver

`HookEvent` and `HookResolver` move from `Sources/TBDDaemon/Hooks/HookResolver.swift` to
`Sources/TBDShared/`. `resolve` is `FileManager` calls plus one JSON read — nothing
daemon-specific. `execute` moves with it and the app simply never calls it.

The daemon's call sites are unchanged. The app gains the ability to answer "does this worktree
have a preSession hook?" with the *identical* five-step chain (app config → `.worktree-hooks/` →
`conductor.json` → `.dmux-hooks/` → global default) rather than a copy that drifts.

Note `hooksLogger` uses subsystem `com.tbd.daemon`; it keeps that subsystem, category `hooks`, so
existing log predicates keep working.

### 5. App wiring

Following the existing data-driven menu split:

- `RowActionMenu.ActionKind.rerunPreSessionHook`, title `"Re-run setup hook"`.
- New `hasPreSessionHook: Bool` on the menu `Context`. `RowActionMenu.items(context:)` **stays
  pure** — the filesystem resolve happens in `SidebarContextMenu` while building the Context, not
  inside `items()`. Context menus are built on right-click, not per-frame, so a handful of
  `fileExists` calls is fine.
- Emitted as its own section in `regularItems` and `scratchItems`. Absent from `mainItems`.
- `RowActionMenuActions.run(.rerunPreSessionHook)` → `Task { await
  appState.rerunPreSessionHook(worktreeID:) }` → `DaemonClient.rerunPreSessionHook(worktreeID:)` →
  the new RPC.
- Failures surface through the existing `showAlert(_:isError:)` → `ContentView.swift:281` alert,
  matching `archiveWorktree`'s pattern.

Scratch rows may have no `repoID`, so `appHookPath` is nil for them; `resolve` handles that and
falls through to `.worktree-hooks/` in the scratch directory or the global default. A global
default hook therefore surfaces the item on every row — which is correct.

## Error handling

| Condition | Surface |
| --- | --- |
| No hook resolves | Item hidden. RPC also errors if called anyway. |
| Run already in flight | Alert: `Setup hook is already running for this worktree.` |
| Hook exits non-zero | Tab kept with output; `.error` notification. |
| Hook times out (600s) | Tab kept; `.error` notification. |
| User kills the pane | `.error` notification. |
| Worktree row vanishes mid-run | Existing phase-3 guard (`:272-285`) applies: kill the window, no notification, no spawn. |

Failure messages drop the create-path suffix "— starting the agent anyway", which is false on a
re-run. `notifyPreSessionProblem` takes the message already; the two call paths pass different text.

## Testing

Per CLAUDE.md, the new exit-code branch gates behavior, so both sides are tested.

**Daemon** (`Tests/TBDDaemonTests/PreSessionHookTests.swift` and a new re-run suite):

- Teardown gate, exit 0: terminal row deleted, `.terminalRemoved` broadcast, tab order excludes it.
- Teardown gate, non-zero: row survives, `.error` notification recorded.
- Create path still spawns primary terminals and flips `.active` / revive on **both** success and
  failure (regression guard on §1's reordering).
- Re-run isolation: spawns a hook terminal; does not flip worktree status; does not spawn primary
  terminals; does not reassign `activeTabID`.
- Re-run guards: no hook → error; second call while in flight → error.

**Shared:** `HookResolverTests` moves to `Tests/TBDSharedTests` with the type; chain behavior
unchanged.

**App** (`Tests/TBDAppTests`): item present iff `hasPreSessionHook`; present on regular and scratch
rows, absent on main; correct section position relative to `Open in Finder`.

**Live verification** (not assertable headlessly): closing the hook tab while it is the *focused*
tab. The create flow auto-follows to the pre-session tab, so on success the app is sitting on a
tab that is about to vanish. Confirm the app lands on the Claude tab, not an empty pane.

Daemon + shared code change, so full `scripts/restart.sh` (relative, from the worktree) and
`swift test` before commit.

## Files touched

| File | Change |
| --- | --- |
| `Sources/TBDShared/HookResolver.swift` | new — moved from `TBDDaemon/Hooks/` |
| `Sources/TBDShared/RPCProtocol.swift` | `RPCMethod.worktreeRerunPreSession` (`"worktree.rerunPreSession"`) + `WorktreeRerunPreSessionParams` |
| `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+PreSession.swift` | `claimsFocus`, `finishPreSessionRun`, teardown, in-flight set |
| `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift` | pass `nil` `preSessionTerminalID` on the success path |
| `Sources/TBDDaemon/Server/RPCRouter.swift` | dispatch |
| `Sources/TBDDaemon/Server/RPCRouter+WorktreeHandlers.swift` | `handleWorktreeRerunPreSession` |
| `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift` | extract shared teardown helper |
| `Sources/TBDApp/DaemonClient.swift` | `rerunPreSessionHook(worktreeID:)` |
| `Sources/TBDApp/AppState+Worktrees.swift` | `rerunPreSessionHook(worktreeID:)` + alert |
| `Sources/TBDApp/Helpers/RowActionMenu.swift` | `ActionKind`, `Context.hasPreSessionHook`, section |
| `Sources/TBDApp/Sidebar/RowActionMenuActions.swift` | dispatch |
| `Sources/TBDApp/Sidebar/SidebarContextMenu.swift` | resolve the hook when building Context |
| `docs/worktree-hooks.md` | document the re-run action and the ephemeral tab |
