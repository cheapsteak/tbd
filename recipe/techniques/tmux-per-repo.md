# One tmux server per repo

## Posture: Make

A naming convention and process isolation pattern. No dependencies.

## The problem

Multiple repos managed in one app need terminal isolation. A crash or misconfiguration in one repo's terminal sessions shouldn't affect another repo.

## The technique

Each repo gets its own tmux server, named `tbd-<hash>` where hash is derived from the repo's stable identifier. Selected via `tmux -L tbd-<hash>`. Each server has one session named `main`. Windows within the session correspond to individual terminal panels.

## Why not alternatives

- **Single shared server:** A crash takes down all repos. Window name collisions. No isolation.
- **Per-worktree servers:** Too many servers. Harder to share sessions between panels viewing the same repo.

## Where this applies

Any tool managing terminals across multiple independent projects in a single UI.
