# YYYYMMDD-adjective-animal naming for worktrees

## Posture: Make

A naming convention. ~20 lines of code with word lists.

## The problem

Worktrees need unique, human-friendly names that don't collide and are easy to type in a terminal. Branch names derived from ticket numbers or descriptions are either cryptic or conflict-prone.

## The technique

Auto-generate names as `YYYYMMDD-adjective-animal` (e.g., `20260321-fuzzy-penguin`). The date prefix groups worktrees chronologically. The adjective-animal suffix is drawn from large randomized word pools, making collisions vanishingly unlikely. The git branch is `tbd/<name>`.

Users can rename the display name in the sidebar without changing the branch or directory name.

## Why not alternatives

- **Sequential numbers:** `worktree-1`, `worktree-2` — no semantic meaning, confusing across repos.
- **Ticket-based names:** Requires ticket system integration, names are ugly in terminals.
- **UUID-based:** Impossible to type or remember.

## Where this applies

Any system that auto-generates human-facing identifiers where uniqueness and typability both matter.
