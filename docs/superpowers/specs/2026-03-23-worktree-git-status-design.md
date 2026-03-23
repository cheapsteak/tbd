# Worktree Git Status Indicators

## Problem

TBD shows worktree lifecycle status (active/archived/main) but has no visibility into the git-level relationship between a worktree's branch and main. Users can't tell at a glance whether a branch has merge conflicts, is behind main, or has already been merged.

## Design

### Data Model

New enum added to `Models.swift`:

```swift
public enum GitStatus: String, Codable, Sendable {
    case current     // branch is ahead of or equal to main — no action needed
    case behind      // main has commits not on this branch
    case conflicts   // would conflict if merged into main
    case merged      // squash-merged into main (set by TBD's merge flow)
}
```

New column on the `worktree` table:

```sql
ALTER TABLE worktree ADD COLUMN gitStatus TEXT NOT NULL DEFAULT 'current';
```

Only meaningful for worktrees with `status == .active`. Main and archived worktrees ignore this field.

### Status Computation

**`merged`** is a terminal state set explicitly by the squash merge handler when TBD performs a merge. It is not computed — we don't detect squash merges done outside TBD.

**`behind` and `conflicts`** are computed by the daemon:

1. Skip worktrees that are `merged`, `main`, or `archived`.
2. `git merge-base --is-ancestor <main-ref> <branch-ref>` — if main is an ancestor of the branch, the branch is ahead of or equal to main → `current`.
3. Otherwise, `git merge-tree <merge-base> <main-ref> <branch-ref>` — if output contains conflicts → `conflicts`, otherwise → `behind`.

### Trigger Points

Status checks are **event-driven**, not periodic:

- **After squash merge** — recheck all other active worktrees in the same repo (main just moved).
- **After fetch/pull of main** — recheck all active worktrees in the repo.
- **On daemon startup** — recompute for all active worktrees across all repos (cold recovery).

### Non-blocking Execution

All git status computation is non-blocking:

- Merge/fetch handlers complete and respond to the client immediately.
- A background `Task` runs the git checks asynchronously.
- Per-worktree checks run concurrently via `TaskGroup`.
- Results are written to the DB and broadcast as a state delta when complete.
- On daemon startup, the daemon initializes and accepts connections first, then kicks off background recomputation. Worktrees show their last-persisted status until the refresh completes.

### UI Presentation

Git status is displayed as a small SF Symbol icon near the worktree name, **separate from** the existing notification badges (agent activity dots on the trailing side):

| Status | Icon | Color | Meaning |
|---|---|---|---|
| `current` | (none) | — | Default state, no indicator |
| `behind` | `arrow.down` | Secondary/subtle | Main has moved ahead |
| `conflicts` | `exclamationmark.triangle` | Orange | Merge into main would fail |
| `merged` | `checkmark.circle` | Green | Branch landed on main |

### Not in Scope

- Auto-archiving merged worktrees (merged status is informational only).
- Detecting squash merges performed outside TBD (e.g., via GitHub PR).
- Periodic background polling.
