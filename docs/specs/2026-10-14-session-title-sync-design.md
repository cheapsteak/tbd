# Session title sync

## Problem

A Claude Code session has a display name. It shows in the Remote Control list on claude.ai and in the Claude app, in the `/resume` picker, in the terminal title, and in the peer registry that `ListAgents` / `SendMessage` read. TBD sets that name at spawn with `--name <worktree display name>` (`ClaudeSpawnCommandBuilder`).

The name is fixed at spawn. A worktree usually starts with its generated folder name (`20261014-zippy-hamster`) as its display name and is renamed later, often by the agent itself in its first turn. The running session keeps the generated name until it is respawned or resumed. So Remote Control lists sessions under names nobody chose and nobody can read.

Two further gaps:

- Every Claude terminal in a worktree gets the same `--name`, so two Claude tabs in one worktree look the same in Remote Control and share one peer address.
- Nothing reacts to `worktree.rename` except the `.worktreeRenamed` state delta to the app.

## Goal

A Claude session's name follows its worktree's display name, including after a rename, without TBD ever typing into the session.

Out of scope: Codex sessions, TBD remote (cloud) sessions, and renaming a session that receives no further prompts.

## What Claude Code offers

- **No out-of-band rename.** Claude Code 2.1.299 has no CLI, IPC or file mechanism to rename a running session from outside it.
- **Hook output can set the title.** `UserPromptSubmit` and `SessionStart` hooks may return `hookSpecificOutput.sessionTitle`. It has the same effect as `/rename`.
- **A hook title overrides `--name`, Remote Control included.** Field test on 2.1.299: a session launched with `--name rc-test-ORIGINAL --remote-control` and a `UserPromptSubmit` hook returning `sessionTitle: "rc-test-RENAMED-by-hook"` took the new title on its first prompt. That covered the TUI title bar, the peer registry entry (`sessions/<pid>.json`: `"name": "rc-test-RENAMED-by-hook"`, `"nameSource": "hook"`, the old name under `formerNames`) and the Remote Control session list on claude.ai. Claude Code's documented Remote Control naming order ranks `--name` above `/rename`, but in practice a later hook title wins.

## Design

### Delivery: the existing `UserPromptSubmit` hook

TBD's hook overlay (`ClaudeHookOverlay`) already runs `tbd terminal-activity working` on every `UserPromptSubmit`, which sends one `terminal.activityEvent` RPC to the daemon. The title rides that existing round trip:

- The Claude overlay's `UserPromptSubmit` command gains a flag: `tbd terminal-activity working --session-title 2>/dev/null || tbd terminal-activity working 2>/dev/null || true`. A `tbd` older than the flag rejects it with a usage error on stderr, and the plain command after it keeps the working indicator alive; such a CLI simply never sets a title. Codex hooks share `terminal-activity` and do not pass the flag, so they never receive a title.
- With the flag, the RPC request asks for a title. The response carries an optional `sessionTitle`.
- When the response has a title, the CLI prints `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"<title>"}}` to stdout. Otherwise it prints nothing, exactly as today.
- Every failure path (daemon down, RPC error, no `TBD_TERMINAL_ID`) prints nothing and exits 0, as the command does today. A failed title lookup must never block or fail the user's prompt.

There is no new process, no new RPC and no input sent to the session.

Placement: the hook and the CLI are user-land, but the title has to be computed where terminal rows, tab names and display names live, which is the daemon. The daemon exposes the fact (the wanted title), and the hook acts on it.

### The wanted title

One function computes a Claude terminal's wanted title. Both the spawn path (`--name`) and the hook path use it, so a spawn name and a later hook title never disagree.

- **Base:** the worktree's display name, sanitized by `ClaudeSpawnCommandBuilder.sanitizedSessionName`.
- **Counted terminals:** the worktree's Claude terminals, by creation order. Parked (hibernated) Claude terminals count, because they resume under their name. Profile login terminals (label `login`) do not: a login tab is a short credentials errand, and counting it would shift every later tab's number while it is open. A login terminal is never titled either: it spawns with the bare display name as its `--name`, records no title, and gets none on a prompt.
- **Suffix:** the first counted terminal gets none. Each later one gets ` · <tab name>` when the user has renamed its tab, otherwise ` · <n>`, where `n` is its 1-based position among the counted terminals.
- **Tab names:** the name comes from the `tab` table (`tab.setLabel`), not from the terminal row's `label`, which every Claude spawn sets to a daemon identity (`Claude Code`, `claude`, `login`). A tab's id is the id of the terminal it was opened for, so a terminal that roots a tab finds its name by its own id. Split layouts live in the app, not the daemon, so a terminal split into another tab's layout roots no tab of its own and is numbered.
- **Uniqueness:** the wanted title must not equal the title last given to any other terminal that still has a row in the worktree, nor a title reserved by another spawn still in flight (see below), whose row is not written yet. When it does, the number is bumped (` · 3`, ` · 4`, …; ` · <tab name> 2`, … for a named tab; ` · 2`, … for the bare name) until it is unique. Without this rule a spawn made after a tab closes takes the same ` · n` as a surviving tab that has not prompted since, and the two share a peer address until it does.
- **Length:** the result fits Claude Code's 64-character name cap without cutting the suffix, since two tabs whose suffixes were cut off would share a name. A long tab name is shortened first, so the display name keeps at least 24 characters (all of itself when shorter); the display name then gives up whatever room the suffix still needs.
- A title can shift when an earlier Claude terminal closes or a tab is renamed. The shifted title is then sent on that terminal's next prompt.

The suffix also gives each Claude tab in a worktree its own peer address, which without it they would share.

### When a title is sent: only on change

The daemon keeps, per terminal, the last title it gave that session (`lastAppliedTitle`), in memory.

- **Reserve, confirm, release.** A spawn (or wake, swap, revive, or Continue in Claude) reserves its `--name` in the store at the moment it computes it, in the same actor call, so a concurrent spawn into the same worktree sees the reservation and takes the next number. Once the session has really launched, the spawn site confirms the reservation and it becomes that terminal's `lastAppliedTitle`. On every other outcome — a spawn that throws, a respawn that fails, or a holder wake that adopts a session already running and so launches nothing — the spawn site releases it, which puts back the entry the reservation displaced. A title that never reached a session can therefore neither suppress a later send nor block another tab's title, and the next prompt of a session that kept its old name delivers the wanted title. A release touches only its own reservation, so it never erases a newer entry.
- On a `UserPromptSubmit` that asks for a title, the daemon computes the wanted title. If it equals `lastAppliedTitle`, the response carries no title. If it differs, the response carries it and `lastAppliedTitle` is updated. The title counts as sent once the hook returns it; a Claude Code too old to honour `sessionTitle` keeps its launch name until the wanted title changes again.
- A user's own `/rename` therefore survives until the wanted title next changes, through a worktree rename, a tab rename or a suffix shift. TBD does not fight a manual rename.
- The entry is dropped on every path that deletes terminal rows: `terminal.delete`, a hook tab's teardown, and the per-worktree bulk deletes (archive, forget, reconcile, creation recovery, scratch removal, Watch Desk close). A row removed by a cascade from a deleted worktree or repo leaves its entry behind; that entry is inert, because the uniqueness rule only reads confirmed entries whose terminal still has a row. A reservation blocks a title whether or not its row exists, and lasts only until its spawn confirms or releases it. The prompt path never prunes entries.

Not persisted: after a daemon restart `lastAppliedTitle` is empty, so each live session gets its wanted title once, on its next prompt. That undoes a manual `/rename` at most once per daemon restart. Persisting it would need a `terminal` column and a migration for a rare, cosmetic case.

### Timing

The new title lands on the session's next prompt after the change, not at the moment of the rename. TBD's `Stop` hook (`tbd hooks stop-rename-check`) prompts the agent to rename a still-default worktree at the end of its first turn, so in the usual flow the title catches up on the second prompt.

### No feature flag

This adds no autonomous action, sends no input, kills nothing and moves no UI. It changes what the session's own title says, the same thing `--name` already sets at spawn. Per the flag rule in `CLAUDE.md`, it ships ungated.

## Tests

- **Wanted title:** first Claude terminal gets the bare display name; a later terminal whose tab was renamed gets ` · <tab name>`, and the terminal row's own label is never used; unnamed later terminals get ` · 2`, ` · 3`; closing the first terminal renumbers the rest; non-Claude and login terminals are ignored when counting; parked terminals are counted; sanitization applies; a long tab name is shortened before the display name drops below 24 characters.
- **Uniqueness:** a number, a tab name or the bare name another live terminal was last given is bumped; a confirmed entry for a terminal with no row blocks nothing; a title reserved by a spawn in flight blocks whether or not its row exists.
- **Reservations:** two spawns reserved before either row exists get different titles; confirm keeps a reservation as the title given and release drops it; a release restores the entry its reservation displaced and never erases a newer reservation; a confirm after the terminal was forgotten brings nothing back; a holder wake that adopts a running session leaves the recorded title as it was.
- **Spawn uses it:** the second Claude terminal in a worktree spawns with the suffixed `--name`; a spawn after the first tab closed skips the ` · 2` the surviving tab still carries; the spawn helper holds its title as a reservation, a `terminal.create` made while another spawn holds ` · 2` takes ` · 3`, and a successful `terminal.create` confirms the name it used.
- **Change rule:** the first prompt after spawn returns no title; a prompt after `worktree.rename` returns the new title once and the following prompt returns none; a prompt after `tab.setLabel` returns the tab-named title once; with no `lastAppliedTitle` (daemon restart) the first prompt returns the title; a prompt leaves the reservation of a spawn whose row is not written yet.
- **Login terminals:** a login spawn passes the bare display name and reserves nothing, whether flagged by its caller or recognized by its row's label; a prompt from a login tab gets no title and records none; an open login tab takes no number.
- **Request gate:** an activity event without the title request returns no title, even after a rename, so Codex hooks are unaffected.
- **CLI:** with a title in the response it prints valid hook JSON naming `UserPromptSubmit`; with none, or on any failure, it prints nothing and exits 0.
- **Overlay:** the generated overlay's `UserPromptSubmit` command asks with `--session-title` and falls back to the plain command.

## Rejected alternatives

- **Type `/rename <name>` into idle sessions on rename.** Immediate, but it sends input to sessions, which risks mixing with what the user is typing and would need a default-off flag. The hook gets the same result one prompt later with none of that risk.
- **Append a `custom-title` entry to the transcript JSONL.** Undocumented, and nothing shows that a running session or Remote Control rereads it.
- **Reset the title on every prompt.** Simpler, but it would undo a user's `/rename` within one prompt.
- **`SessionStart` hook title.** Spawn and resume already pass the current name through `--name`, and `SessionStart` also fires on `/clear` and `/compact`, where a title change is not wanted.
