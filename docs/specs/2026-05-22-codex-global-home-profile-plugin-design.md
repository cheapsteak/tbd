# Codex global home with TBD profile plugin

**Date:** 2026-05-22
**Status:** Design
**Upstream checked:** `openai/codex` `932f72c225889102257493f57460251016cbfdc2`

## Problem

TBD currently launches Codex with an isolated per-repo `CODEX_HOME` under
`~/tbd/agents/codex/<repoID>/`. That keeps TBD's `hooks.json` and `skills/tbd`
out of the user's normal `~/.codex`, but it also splits Codex user state:

- a user who signed in with normal Codex may appear unsigned-in inside TBD;
- token refreshes or login changes outside TBD can leave TBD stale;
- user-level Codex config, plugins, skills, and model preferences do not
  naturally apply inside TBD-launched Codex;
- TBD has to mimic parts of Codex home management instead of letting Codex use
  its own global home.

The desired behavior is the opposite: TBD-launched Codex should use the user's
normal Codex environment, while TBD-specific hooks/skills should only be active
inside TBD sessions.

## Goals

- Use the user's real `~/.codex` as `CODEX_HOME` for TBD-launched Codex.
- Preserve normal Codex behavior outside TBD.
- Activate TBD-specific Codex integration only for TBD launches.
- Run every enabled hook in a TBD-launched session (TBD's plugin hooks, the
  repository's project hooks, the user's own) with no interactive trust step,
  so a session never waits on a review screen nobody is watching.
- Persist no hook trust on TBD's behalf, so a plain `codex` launch keeps
  Codex's normal trust behavior.
- Leave room for users to keep their normal Codex config, plugins, auth, and
  profile choices.

## Non-goals

- Reimplement Codex plugin loading.
- Write TBD-specific hooks into the user's base `~/.codex/config.toml`.
- Mark any hook trusted in the user's Codex config, base or profile.
- Continue maintaining per-repo isolated Codex homes as the primary launch mode.

## Upstream Codex facts

These facts were checked against upstream `openai/codex` commit
`932f72c225889102257493f57460251016cbfdc2`.

### `CODEX_HOME`

Codex resolves its home from `CODEX_HOME`, defaulting to `~/.codex`
(`codex-rs/utils/home-dir/src/lib.rs`). File auth is stored at
`$CODEX_HOME/auth.json` (`codex-rs/login/src/auth/storage.rs`). Keyring auth is
also keyed by the canonical Codex home path, so changing `CODEX_HOME` changes
the keyring identity.

This is why isolated TBD homes cause separate auth state.

### Profiles

Codex supports `--profile/-p`, which layers
`$CODEX_HOME/<name>.config.toml` on top of the base user config. For TBD,
`codex --profile tbd` means:

- base user layer: `~/.codex/config.toml`
- TBD overlay layer: `~/.codex/tbd.config.toml`

This gives us exactly the desired merge behavior: normal Codex settings apply,
and TBD-only config lives in the `tbd` profile.

### Plugin hooks

Codex plugins can provide hooks:

- plugin manifests accept a `hooks` field;
- hooks may be inline or in files such as `hooks/hooks.json`;
- session hook construction loads enabled plugin hook sources.

So TBD can be represented as a Codex plugin rather than writing global
`hooks.json` into the Codex home.

### Plugin activation

Plugin activation is not a pure runtime override. Codex loads configured
plugins from the merged **user config layers** via `effective_user_config()`.
Runtime `-c key=value` overrides are session layers, not user layers, so
`codex -c 'plugins."tbd@tbd".enabled=true'` should not be treated as a
reliable plugin activation mechanism.

The profile overlay file is therefore the right activation point.

### Hook trust

`--dangerously-bypass-hook-trust` is session-wide. It marks all enabled
unmanaged hooks runnable, including all plugin hooks. It is not scoped to one
plugin.

The bypass lasts for that one invocation and writes nothing. It skips only
the trust check: a hook whose state is `enabled = false` stays off. The flag
exists from Codex 0.131, and the TUI honors it at startup (no review screen)
from 0.135.

Codex hook state supports per-hook `trusted_hash` entries. Plugin hook keys
include plugin/source identity, so Codex can persist trust for the TBD plugin
without trusting unrelated user hooks or other plugins.

## Design

### Launch shape

TBD should launch Codex with the user's normal Codex home:

```sh
CODEX_HOME="$HOME/.codex" codex --profile tbd ...
```

The rest of TBD's launch env stays:

- `TBD_WORKTREE_ID`
- `TBD_TERMINAL_ID`

Remove the per-repo `CODEX_HOME` export from Codex terminal creation and
recreation once the profile/plugin path is in place.

### TBD Codex profile

TBD owns a profile overlay:

```text
~/.codex/tbd.config.toml
```

The minimal profile enables the TBD plugin:

```toml
[plugins."tbd@tbd"]
enabled = true
```

It may also contain hook state entries for the TBD plugin hooks:

```toml
[hooks.state."<hook-key>"]
trusted_hash = "sha256:..."
```

TBD may choose to make `~/.codex/tbd.config.toml` a symlink to a file under
`~/tbd/agents/codex/tbd.config.toml`, but Codex must see it as the profile
file inside `CODEX_HOME` so it is loaded as a user profile layer.

### TBD Codex plugin

Create a real Codex plugin with a manifest:

```text
<tbd-owned-source>/codex-plugin/
  .codex-plugin/plugin.json
  skills/tbd/SKILL.md
  hooks/hooks.json
```

The manifest name must be `tbd` so it can be activated as `tbd@tbd`.

Install it into Codex's plugin cache path:

```text
~/.codex/plugins/cache/tbd/tbd/local/
```

Codex's plugin store resolves active plugins from
`$CODEX_HOME/plugins/cache/<marketplace>/<plugin>/<version>/`; `local` is a
valid default version for local plugins.

The plugin contains:

- the TBD skill content currently written to `$CODEX_HOME/skills/tbd/SKILL.md`;
- TBD lifecycle hooks currently written to `$CODEX_HOME/hooks.json`;
- any future TBD-specific Codex MCP/app connector integration.

### Hook trust flow

TBD launches Codex with `--dangerously-bypass-hook-trust`, next to
`--dangerously-bypass-approvals-and-sandbox`, and writes no hook trust entries.

The two flags belong together. A TBD session already runs any command without
approval and outside the sandbox, so a hook can do nothing the session's agent
could not do on its own; per-hook trust adds no protection inside that session.
What it does add is a stop. An untrusted hook (TBD's own on a new machine or
after TBD changes a hook command, or any project hook in a repository's
`.codex/hooks.json`, re-keyed whenever the repository edits it) gives a TBD
session one of two outcomes:

- The session opens on Codex's startup hook-review screen and waits there.
  TBD's initial prompt and any message typed into the terminal land on that
  screen instead of reaching the agent, and a session nobody is watching
  stays parked.
- Someone continues without trusting, and the hook silently never runs. For a
  repository whose project hook is a guardrail (a check before each tool
  call), the session then runs without it.

So the trust flow is:

1. Ensure the TBD plugin is installed in the Codex plugin cache.
2. Ensure `~/.codex/tbd.config.toml` enables `tbd@tbd`.
3. Launch with `--profile tbd` and both bypass flags. Every enabled hook runs
   from the first session on, with no prompt and nothing persisted.

A user who wants a hook off inside TBD switches it off (`enabled = false` in
`tbd.config.toml`, or Codex's hooks browser in a TBD session), and the bypass
leaves it off.

### Rejected: one-time interactive trust

Persisting trust once per machine was considered and rejected. On the first
TBD-launched session, Codex's startup review offers:

```text
1. Review hooks
2. Trust all and continue
3. Continue without trusting (hooks won't run)
```

Trust persisted inside a `codex --profile tbd` session lands in
`tbd.config.toml`, and plugin hook keys carry no `cwd`, session or worktree
dimension, so one trust would cover TBD's plugin hooks machine-wide. It still
fails TBD in three ways:

- It needs a person at the review screen, the first time on each machine and
  again whenever a trusted hook's command string changes (the stored
  `trusted_hash` stops matching and Codex flips the hook to `Modified`).
- Project hooks are keyed by their `hooks.json` path and hashed by command, so
  every repository with Codex hooks, and every edit to them, brings the screen
  back.
- The review screen is a toggle list: keystrokes meant for the agent (a
  queued prompt, an automated nudge) land in it and can switch hooks on or off.

Writing the trust entries programmatically instead is not possible today.
`config/batchWrite` (the RPC Codex's TUI uses to persist `[hooks.state]`)
writes to whatever `LoaderOverrides.user_config_path` resolves to at
app-server startup, and rejects an explicit `file_path` that differs
(`ConfigLayerReadonly`). The standalone `codex app-server` exposes no
`--profile` flag and the protocol carries no per-connection profile selection,
so a side-channel app-server would write trust into base `~/.codex/config.toml`,
against the non-goal of keeping TBD state out of base config. Replicating
Codex's hook hashing in Swift is fragile; the upstream key format is marked
unstable.

Making TBD's hooks `managed` would also skip the prompt
(`HookTrustStatus::Managed` needs no trust), but managed hooks come only from
system/MDM-level managed config, which requires admin-level global writes.

### User config merging

This design intentionally lets TBD sessions inherit the user's Codex setup:

- auth and token refreshes;
- base config;
- model defaults;
- user plugins;
- user skills;
- MCP configuration;
- normal Codex history/state behavior.

The only TBD-specific additions are in the `tbd` profile and the `tbd@tbd`
plugin. A normal `codex` launch that does not pass `--profile tbd` will not see
the TBD plugin activation or TBD hook trust entries.

## Implementation plan

### Phase 1 — plugin/profile writer

Replace `CodexHomeManager`'s isolated-home setup with a new manager that:

- resolves the global Codex home, normally `~/.codex`;
- creates the Codex home if needed;
- writes or updates the TBD plugin source/cache;
- writes or updates `tbd.config.toml`;
- preserves existing user config files.

While porting the hook definitions into the plugin, **minimize the hook
count**, so each event spawns as few processes as possible and the plugin
adds few entries to Codex's hooks browser. The current overlay ships three
handlers: one `SessionStart` and two `Stop`. Merge the two `Stop` handlers
(`tbd notify ...` and `tbd hooks stop-rename-check`) into a single `Stop`
command so the plugin presents two hooks instead of three. The merged command
should run both steps and preserve their existing best-effort/non-blocking
behavior (`... 2>/dev/null || true`).

Candidate type names:

- `CodexIntegrationManager`
- `CodexProfileManager`
- `CodexPluginWriter`

### Phase 2 — verify hooks run without a trust step

- Confirm a first-run `codex --profile tbd` session, launched the way TBD
  launches it, opens straight to the composer with no hook-review screen.
- Confirm TBD's plugin hooks and a repository's project hooks both run in
  that session.
- Confirm a hook set to `enabled = false` stays off.
- Confirm the session writes no `[hooks.state]` entries, and that a plain
  `codex` launch in the same repository still asks for trust.

### Phase 3 — launch with global home and profile

Change Codex launch command from:

```sh
unset CODEX_CI CODEX_THREAD_ID; codex --dangerously-bypass-approvals-and-sandbox
```

to:

```sh
unset CODEX_CI CODEX_THREAD_ID; codex --profile tbd --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust
```

The two bypass flags are one execution mode (see Hook trust flow): drop both or
neither.

Stop exporting isolated `CODEX_HOME` for Codex tabs. Either do not set
`CODEX_HOME`, letting Codex default to `~/.codex`, or explicitly set it to the
global path if TBD needs deterministic behavior.

### Phase 4 — migration and cleanup

For existing isolated homes:

- do not delete them automatically;
- stop writing `hooks.json` and `skills/tbd/SKILL.md` there;
- optionally surface a cleanup command later.

If an existing TBD Codex session has useful history in the isolated home, it
will not automatically appear in global Codex history. That is acceptable for
the first migration unless users report needing history migration.

## Risks

### Trust key stability

TBD computes no hook keys or hashes and persists no trust (see Hook trust
flow), so an upstream key-format change cannot break it, and changing a TBD
hook command string prompts nobody.

### Profile file ownership

Users may edit `~/.codex/tbd.config.toml`. TBD should preserve unknown fields
and only own the TBD plugin enablement. Codex owns hook-state entries.

### Plugin cache mutation

Installing into `~/.codex/plugins/cache` mutates the user's Codex home. This is
acceptable because the plugin is inactive unless the `tbd` profile enables it,
but the writer should be careful and only touch the `tbd/tbd` plugin path.

### Existing global hooks

When running with `--profile tbd`, normal user hooks from base config still
exist. This is intentional user-config merging, and the hook-trust bypass runs
them in TBD sessions whether or not the user has trusted them. That matches the
session's execution mode, which already runs any command unprompted. A user
hook that should not run inside TBD is switched off with `enabled = false`.

## Open questions

- ~~Does Codex expose a stable endpoint to list hooks with keys and hashes?~~
  Resolved: `hooks/list` returns live keys/hashes, and `config/batchWrite`
  persists trust — but only into the file selected by the writing process's
  `user_config_path` override, which the standalone `codex app-server` cannot
  set. The design therefore persists no trust at all (see Hook trust flow).
- Should `~/.codex/tbd.config.toml` be a real file or a symlink into `~/tbd`?
  A real file is simpler and more native to Codex; a symlink centralizes TBD
  cleanup.
- Should TBD support a setting to disable Codex profile/plugin integration and
  fall back to plain global Codex?

## Success criteria

- A user signed into Codex outside TBD is signed in inside TBD without another
  login.
- Updating Codex auth outside TBD is immediately reflected in TBD sessions.
- Normal `codex` does not load TBD's plugin hooks.
- `codex --profile tbd` loads the TBD plugin and its skill.
- Every enabled hook (TBD's plugin hooks and the repository's project hooks)
  runs in every TBD-launched Codex session from the first one, with no
  hook-review screen.
- A hook switched off stays off, and no hook is marked trusted in the user's
  Codex config.
