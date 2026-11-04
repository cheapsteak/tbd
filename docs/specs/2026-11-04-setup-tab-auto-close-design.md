# Setup tab auto-close

Status: **on by default**, with its toggle kept.

## Problem

A repo's `setup` hook runs in its own tab beside the agent when a worktree is
created, and again when an archived worktree is revived. The hook is usually
slow, unattended work such as installing dependencies or warming caches. Once it
succeeds, its tab is clutter that every worktree's owner closes by hand. A
failed hook is the opposite case: its output is what the tab exists to show.

## Design

The `pre-session` tab already closes itself on success
([`docs/worktree-hooks.md`](../worktree-hooks.md)). The `setup` tab does the
same, through the same machinery.

- **Spawn.** With the setting on and a setup hook resolved, the setup tab runs
  a wrapped command: the hook, then its exit code written to a marker file at
  `~/tbd/runtime/setup/<worktreeID>`. A failed hook then `exec`s the interactive
  shell, so the tab stays usable with the output on screen. A clean run lets
  the pane exit.
- **Watch.** A detached watcher waits for the marker with the pre-session
  hook's marker polling, which also gives up on a dead pane and after 600
  seconds. It removes the marker whatever the outcome.
- **Close on exit 0 only.** A clean exit tears the tab down through the same
  `closeHookTerminal` the pre-session tab uses: the session ends in its
  transport's terms, the terminal and tab rows are deleted, the tab leaves the
  persisted order, and `terminalRemoved` is broadcast. A nonzero exit, a
  timeout or a killed pane leaves the tab alone.
- **Setting off, or no hook.** The tab runs the plain wrapped hook or a shell,
  with no marker and no watcher, exactly as it does without the feature.

The watcher starts only after the creation path has persisted the tab order, so
its teardown cannot race that write and bring the closed tab back.

## Setting and storage

The setting is `config.auto_close_setup_enabled`, shown in Settings → General →
Worktrees as **Auto-close the setup tab on success** and written through
`config.setAutoCloseSetup`. It is read when the setup tab spawns, so a change
applies to setup tabs spawned after it, never to one already running.

`ConfigRecord.toModel()` resolves it as
`auto_close_setup_enabled ?? Config.autoCloseSetupDefault`, and the shipped
default is `true`. NULL means nobody has chosen; `0` and `1` are explicit
choices.

## Rollout

The setting is on for every install, existing ones included.

The column was added by the frozen `v57_config_auto_close_setup` migration with
`defaults: false`, which backfilled `0` into the singleton `config` row. That
row is seeded by an earlier migration, so every install held a `0`, a fresh one
included, and a deliberate off could not be told apart from the backfill.
Changing `Config.autoCloseSetupDefault` alone would therefore have reached no
install.

So migration `20261104175902_auto_close_setup_default_on` runs
`UPDATE config SET auto_close_setup_enabled = NULL` once. It sets every
install's stored value to "never chose", and the shipped default then turns the
feature on. An earlier deliberate off is turned on once by that reset, because
nothing distinguishes it from the backfilled `0`. That cost is accepted and
disclosed, as the root `CLAUDE.md` requires of graduating a flag that carries
`defaults: false`. Whoever wants the tab kept open turns the setting off again.

From the reset on, the column has the third state. A `0` or `1` written after it
is an explicit choice, and it survives any later change to
`Config.autoCloseSetupDefault`.

Rolling back to a build without the reset leaves its NULL in place. Such a
build resolves NULL as off, its own default, so nothing breaks.

## Testing

- A stored `0`, and a stored `1`, both read on after the reset migration.
- A fresh database reads NULL, which resolves on.
- An explicit off written after the reset survives.
- A never-chosen config spawns the wrapped auto-close command, and an explicit
  off spawns the plain one.
- With no hook the tab is a plain shell, with the setting on.
- A marker of `0` deletes the terminal row and prunes the tab order; a nonzero
  marker keeps both.

## Rejected alternatives

- **Flip the default for new installs only.** Every install, a fresh one
  included, holds the same backfilled `0`, so leaving the column alone turns the
  feature on nowhere. Telling a database this build created from an older one
  would reach new installs only and leave every existing install off by a value
  nobody chose. The setting graduates because its owner wants it on for
  everyone.
- **Keep the default off.** Every worktree owner would keep closing a finished
  setup tab by hand, while a failed hook's tab stays open either way, which is
  the case the tab exists for.
