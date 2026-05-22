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
- Avoid `--dangerously-bypass-hook-trust`, because it trusts all enabled
  unmanaged hooks in the session.
- Keep TBD's hook trust scoped to TBD's own plugin hooks.
- Leave room for users to keep their normal Codex config, plugins, auth, and
  profile choices.

## Non-goals

- Reimplement Codex plugin loading.
- Write TBD-specific hooks into the user's base `~/.codex/config.toml`.
- Trust all user/plugin hooks globally.
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

Codex hook state supports per-hook `trusted_hash` entries. Plugin hook keys
include plugin/source identity, so TBD can trust only the hooks from the TBD
plugin by writing trust entries into the `tbd` profile.

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

Install or link it into Codex's plugin cache path:

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

Do not launch with `--dangerously-bypass-hook-trust`.

TBD does **not** write hook trust entries itself. The trust state is persisted
by Codex into the `tbd` profile when the user trusts TBD's hooks once, through
Codex's own hook-review UI.

Why TBD cannot write trust into the profile programmatically:

- `config/batchWrite` (the RPC Codex's TUI uses to persist `[hooks.state]`)
  writes to whatever `LoaderOverrides.user_config_path` resolves to at
  app-server startup. An explicit `file_path` argument is rejected unless it
  equals that already-allowed path (`ConfigLayerReadonly` otherwise).
- The in-process TUI sets that override to `<profile>.config.toml` when launched
  with `--profile`, so trust written *inside* a `codex --profile tbd` session
  lands in `tbd.config.toml`.
- The standalone `codex app-server` binary exposes no `--profile` flag and the
  app-server protocol carries no per-connection profile selection, so a
  side-channel app-server TBD might spawn to pre-trust hooks would write to base
  `~/.codex/config.toml` — which violates the non-goal of keeping TBD state out
  of base config.

So the trust flow is:

1. Ensure the TBD plugin is installed in the Codex plugin cache.
2. Ensure `~/.codex/tbd.config.toml` enables `tbd@tbd`.
3. On the first TBD-launched Codex session, Codex surfaces TBD's plugin hooks as
   untrusted. The user trusts them once via Codex's hook-review UI.
4. Codex persists `trusted_hash` entries under `[hooks.state]` in
   `tbd.config.toml` (because the `--profile tbd` session's
   `user_config_path` override points there).

This is **one-and-done and machine-global**: plugin hook keys carry no `cwd`,
session, tab, or worktree dimension, so a single trust applies to every
TBD-launched Codex session on the machine, forever after. It scopes trust to
the TBD plugin — other user hooks and other plugin hooks remain subject to
normal Codex trust behavior.

The one re-prompt trigger: if TBD changes a plugin hook's command string, its
`current_hash` changes, the stored `trusted_hash` no longer matches, and Codex
flips the hook to `Modified` — prompting the user to re-trust once. TBD should
therefore treat the Codex hook command strings as a stable interface, change
them rarely, and document the expected one-time re-trust in any release that
must change them.

### Trust UX

On the first TBD-launched Codex session, Codex's startup hook-review prompt
offers three choices:

```text
1. Review hooks
2. Trust all and continue
3. Continue without trusting (hooks won't run)
```

`Trust all` is broader than TBD: it trusts every untrusted unmanaged hook in
the session, not only TBD's. Two facts make this acceptable:

- Under `--profile tbd`, the untrusted-hook set is the merge of base
  `config.toml` and the `tbd` profile. For a user with no custom hooks of
  their own — the common case — the only untrusted hooks present are TBD's, so
  `Trust all` trusts only TBD. The over-trust risk materializes solely when the
  user already has their own untrusted hooks in base config.
- `Review hooks` opens the hooks browser, which supports **per-hook** trust:
  drilling into an event and pressing `t` trusts only that one handler
  (`trust_selected_hook`), versus `t` on the events page which trusts all
  (`trust_all_hooks`). A user with custom hooks can therefore trust exactly
  TBD's handlers and nothing else.

Guidance TBD should surface to users (e.g. in onboarding docs or a first-run
note):

- No custom Codex hooks → `Trust all and continue` is correct; it trusts only
  TBD.
- Has custom Codex hooks → `Review hooks`, then per-hook `t` on TBD's handlers.

TBD should also keep its own hook count minimal so the review surface is small
(see Phase 1). Making TBD's hooks `managed` would skip the prompt entirely
(`HookTrustStatus::Managed` needs no trust), but managed hooks come only from
system/MDM-level managed config, which requires admin-level global writes —
exactly the invasive mutation this design avoids. Rejected.

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
count** to keep the trust-review surface small (see Trust UX). The current
overlay ships three handlers: one `SessionStart` and two `Stop`. Merge the two
`Stop` handlers (`tbd notify ...` and `tbd hooks stop-rename-check`) into a
single `Stop` command so the plugin presents two hooks instead of three. The
merged command should run both steps and preserve their existing
best-effort/non-blocking behavior (`... 2>/dev/null || true`).

Candidate type names:

- `CodexIntegrationManager`
- `CodexProfileManager`
- `CodexPluginWriter`

### Phase 2 — verify hook trust UX

TBD writes no hook trust entries. This phase verifies the interactive trust
flow instead:

- Confirm a first-run `codex --profile tbd` session surfaces the TBD plugin
  hooks as untrusted in Codex's hook-review UI.
- Confirm trusting them once persists `[hooks.state]` entries into
  `tbd.config.toml` (not base `config.toml`).
- Confirm subsequent TBD-launched Codex sessions — other tabs, other
  worktrees — load the hooks without re-prompting.
- Confirm that changing a plugin hook command string flips the hook to
  `Modified` and triggers exactly one re-trust prompt.

If TBD ever needs the `[hooks.state]` entries written into `tbd.config.toml`
without an interactive prompt, that is a separate, currently-unsupported path
— it would require either replicating Codex's hook hashing in Swift (fragile;
the upstream key format is marked unstable) or an upstream change letting
`codex app-server` select a profile. Out of scope here.

### Phase 3 — launch with global home and profile

Change Codex launch command from:

```sh
unset CODEX_CI CODEX_THREAD_ID; codex --dangerously-bypass-approvals-and-sandbox
```

to:

```sh
unset CODEX_CI CODEX_THREAD_ID; codex --profile tbd --dangerously-bypass-approvals-and-sandbox
```

Keep `--dangerously-bypass-approvals-and-sandbox` if TBD still wants that
execution mode, but do not add `--dangerously-bypass-hook-trust`.

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

This risk is now largely sidestepped: TBD does not compute hook keys or hashes
(see Hook trust flow), so an upstream key-format change cannot break a TBD
trust writer — there is none. Codex owns trust persistence end to end. The
residual exposure is only the `Modified` re-prompt when TBD itself changes a
hook command string, which is under TBD's control.

### Profile file ownership

Users may edit `~/.codex/tbd.config.toml`. TBD should preserve unknown fields
and only own the plugin enablement and hook-state entries it manages.

### Plugin cache mutation

Installing into `~/.codex/plugins/cache` mutates the user's Codex home. This is
acceptable because the plugin is inactive unless the `tbd` profile enables it,
but the writer should be careful and only touch the `tbd/tbd` plugin path.

### Existing global hooks

When running with `--profile tbd`, normal user hooks from base config still
exist. This is intentional user-config merging. TBD must not bypass hook trust
globally, so untrusted user hooks remain blocked until the user trusts them.

## Open questions

- ~~Does Codex expose a stable endpoint to list hooks with keys and hashes?~~
  Resolved: `hooks/list` returns live keys/hashes, and `config/batchWrite`
  persists trust — but only into the file selected by the writing process's
  `user_config_path` override, which the standalone `codex app-server` cannot
  set. The design therefore uses interactive trust instead of programmatic
  writes (see Hook trust flow, Phase 2).
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
- After a one-time interactive trust, TBD plugin hooks run in every TBD-launched
  Codex session — across tabs and worktrees — without re-prompting and without
  `--dangerously-bypass-hook-trust`.
- Other untrusted hooks remain untrusted in TBD sessions.
