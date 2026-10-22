# Per-terminal Codex home

## Problem

An automation that needs a dedicated Codex configuration cannot give one TBD
terminal its own `CODEX_HOME`. Changing the environment of the daemon or the
user's shell would affect other terminals, while placing the setting in a
general repository override could replace it at spawn time. A caller also
needs an old daemon to refuse this request rather than silently launch Codex
with its ordinary home.

## Decision

Add an opt-in `--codex-home` option to `tbd terminal create --type codex`.
The CLI resolves a relative path against its current directory before sending
the request; the daemon accepts only a canonical absolute directory.
It applies to that terminal only and is never stored as a worktree default.
The CLI sends a distinct `terminal.createGuardedCodex` RPC when the option is
present. A daemon without that method rejects the request. The daemon checks
the supplied canonical directory, readable regular `hooks.json` and
`config.toml`, a command `PreToolUse` hook, and explicit hook disables in both
Codex config layers (a hook's `enabled = false`, or a hook feature turned off)
before creating a terminal. Codex CLI 0.163.0-alpha.10.2 reports `hooks` as
stable and enabled in `codex features list`; it does not list `codex_hooks`.
TBD still checks an explicit `codex_hooks` disable to fail closed if that key
appears in a config layer. It refuses `--codex-disable hooks` and
`--codex-disable codex_hooks` with `--codex-home`. It writes TBD's Codex profile
and plugin into the home, checks it again, and forces `CODEX_HOME` into the
launch environment after ordinary overrides are merged.

The home is recorded on the terminal row with the tab's other Codex launch
options (`Terminal.codexLaunchOptions`, in the `codex_launch_options` JSON
column that #1191 added, so this change adds no migration of its own). Every
relaunch of Codex in that tab reads it strictly
(`TerminalStore.codexLaunchOptionsForRelaunch`): a recorded value that no
longer decodes refuses the relaunch, since it may have named a home. The row
model still reads such a value as "none". The relaunches are
`terminal.recreateWindow`, and the rollback and startup recovery of
continue-in-Claude. Each one checks the home again before it touches the old
window and launches in it. A home that no longer passes is refused: the window
is left as it was, and a pending recovery stays pending. No relaunch falls back
to the shared home. Continue-in-Claude refuses a tab with a dedicated home,
because a Claude process would not run under its guard.

The normal `terminal.create` method and terminals without the option keep
their existing behavior. A non-Codex terminal rejects the option.

## Boundary and limits

This preflight establishes that a guard is present and configured to run. It
does not certify the hook command's behavior. TBD launches every Codex
terminal with `--dangerously-bypass-hook-trust`, so Codex runs the hook
without its startup trust review. When neither config layer names a hook
feature, the preflight relies on current Codex versions defaulting hooks on.
Older versions with hooks off by default require explicit enablement, and the
preflight cannot establish that behavior by file inspection. A live synthetic
denial in the terminal is required before relying on the guard. The disable
check reads the key Codex itself writes under `[hooks.state]` in `config.toml`:
`<hooks.json path>:<event>:<group>:<hook>` (for example
`/Users/me/.codex/hooks.json:post_tool_use:0:0`). Hook `matcher` patterns are
not interpreted, so a hook that never matches passes. Project-level `.codex`
configuration in the worktree is not read either: the caller owns the
worktree as well as the home. The caller must review
the command and verify its behavior in the actual terminal with a synthetic
denied tool call before relying on it; other tools outside the hook's surface
need their own boundary.

The caller owns the directory and everything in it for the terminal's
lifetime, including the profile and plugin TBD writes there. TBD never
deletes it, so no orphan of TBD's own can arise; the row's record of the path
goes when the tab stops running Codex (recreated as a shell). The caller can
still change the files after a check: the guard is only as fixed as the
caller keeps it, and the next relaunch checks it again.

## Rejected alternatives

- **Set `CODEX_HOME` on the daemon or in the user's shell.** Every Codex
  terminal would get the guarded home, not one.
- **Put `CODEX_HOME` in a repository or global env override.** Overrides
  apply to every terminal in that scope, and a later override can replace
  the value at spawn time.
- **Add `codexHome` to `terminal.create`.** An older daemon ignores an
  unknown field and would launch an unguarded terminal, so the guarded
  request has its own method.
- **Refuse every relaunch of a guarded tab.** Losing its window would strand
  the tab for good. Checking the home again on each relaunch keeps the tab
  recoverable without ever running it on the shared home.

## Verification

Test the CLI and daemon rejection paths, old and new RPC method selection,
malformed or disabled hook configuration, and propagation of the forced home
through spawn and over an env override. Test that a recreate relaunches in the
recorded home, and refuses before touching the window when the home lost its
guard; that continue-in-Claude refuses a guarded tab; and that a pending
recovery of a guarded row whose home lost its guard stays pending. Build both
executable and daemon targets. Verify an actual terminal separately with a
synthetic denied tool call before using it for protected work.
