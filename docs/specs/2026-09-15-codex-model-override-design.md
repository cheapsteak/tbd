# Per-create Codex model override

**Date:** 2026-09-15
**Status:** Design

## Problem

TBD starts every Codex terminal as `codex --profile tbd
--dangerously-bypass-approvals-and-sandbox`, so every terminal inherits the
model from the user's Codex configuration: `$CODEX_HOME/config.toml`, with
`$CODEX_HOME/tbd.config.toml` layered on top. That shared default is useful,
but it cannot express a one-terminal choice. A user cannot start one terminal
on a stronger model while leaving the rest on the configured default.

Claude already has a separate model concept in TBD: `ModelProfile.model` and
`WorktreeCreateParams.model` feed `ANTHROPIC_MODEL`. Reusing either for Codex
would conflate two agents with different configuration mechanisms.

## How switching a running Codex terminal already works

Codex's built-in `/model` command works inside a TBD Codex terminal; TBD does
nothing that blocks or reverts it. Reproduced against a scratch copy of a
Codex home launched exactly as TBD launches it: `/model` switches the live
session, and Codex persists the choice as top-level `model` and
`model_reasoning_effort` keys in the active profile layer,
`$CODEX_HOME/tbd.config.toml`, leaving `config.toml` untouched. TBD's own
writer (`CodexProfileWriter.ensureProfile`) only upserts the
`[plugins."tbd@tbd"]` section and preserves every other line, so the persisted
choice survives TBD's profile maintenance.

Two properties follow, and neither is a defect:

- **The persisted choice is shared.** Every TBD Codex terminal launches with
  the same `tbd` profile, so `/model` in one terminal becomes the default for
  every Codex terminal TBD starts afterwards. Terminals already running keep
  their own model.
- **A recreated terminal starts fresh.** Recreating a Codex terminal
  (`terminal.recreateWindow`) launches a new `codex` process rather than
  `codex resume`, so it takes whatever the profile says at that moment.

This design therefore adds no TBD-level switch. Changing a running terminal's
model is Codex's `/model`; what TBD lacks is a way to choose the model for a
single terminal when it is created.

## Goals

- Let `tbd terminal create --type codex --model <id>` select the model for that
  fresh Codex terminal.
- Let `tbd worktree create --codex-model <id>` select the model for the fresh
  primary terminal when that worktree's resolved primary agent is Codex.
- Preserve every existing command byte-for-byte when no override is supplied.

## Non-goals

- A TBD-level live model switch. Codex's `/model` covers it.
- Persisting the override. It lives exactly as long as the Codex process it
  was passed to; a recreated terminal falls back to the profile's model.
- A model picker in the app.
- Selecting Codex as the primary worktree agent. `--codex-model` modifies a
  Codex primary selected by the existing preference; it does not select the
  agent kind.
- Validating model identifiers against a TBD-owned list. Codex owns that
  vocabulary and reports unsupported values.
- Changing Claude model selection.

## Design

### CLI surface and validation

`TerminalCreate` gains an optional `--model <id>`. The option is valid only
when `--type codex` is explicit. Supplying it with `--type claude`, `--type
shell`, or no type fails argument validation before the CLI opens the daemon
socket. The error says that `--model` requires `--type codex`, that Claude
models come from TBD model profiles, and that shell terminals have no model.
The daemon repeats the same check with the same message, so a caller that
bypasses the CLI gets the same refusal rather than a silently dropped value.

`WorktreeCreate` gains an optional `--codex-model <id>`. Worktree creation
resolves its primary agent in the daemon, so the CLI cannot validate the agent
kind. The lifecycle consumes the value only in the `.codex` primary-spawn
branch; Claude and shell primaries ignore it.

Both options reject an empty or whitespace-only value. Otherwise the values
are opaque strings: TBD escapes them but does not normalize, alias, or verify
them.

### RPC and data flow

The CLI sends the terminal option as an optional `model` field on
`TerminalCreateParams`, and the worktree option as an optional `codexModel`
field on `WorktreeCreateParams`; the distinct name keeps the existing
Claude-only `model` field unambiguous.

The terminal handler passes `params.model` only to its `.codex` spawn. The
worktree handler carries `params.codexModel` through `completeCreateWorktree`,
the pre-session phase when a pre-session hook exists, and
`spawnPrimaryTerminals`, whose `.codex` arm is its only consumer.

Both fields are optional and default to `nil` in their public initializers.
Older clients omit them and newer daemons decode that as the current behavior;
older daemons ignore the extra JSON keys. No value is written to the terminal,
worktree, repository, profile, or config tables.

### Codex command construction

`CodexSpawnCommandBuilder` accepts an optional model for launches. When
present, it inserts `-c` and one assignment argument immediately after the
profile selection and before `--dangerously-bypass-approvals-and-sandbox`:

```text
codex --profile tbd -c 'model="<id>"' --dangerously-bypass-approvals-and-sandbox [prompt]
```

Codex parses a `-c` value as TOML and only falls back to the raw text when
that parse fails, so an unquoted identifier that happens to be valid TOML
(`1.5`) would arrive as a number. The builder therefore writes the identifier
as a TOML basic string, escaping `"`, `\`, and control characters, and then
shell-escapes the whole `model="<id>"` assignment as one argument. `-c` is
used rather than Codex's `-m` so the override is expressed in the same
configuration layer the profile uses.

When the model is `nil` or empty, the builder emits exactly the string it
emits today: the same executable quoting, detected profile flag, argument
order, and prompt placement.

### Documentation

The `tbd` skill in `TBDSkillContent.swift` gains a paragraph beside the
`terminal create --type codex` example. It documents `--model <id>` as a
one-terminal override, names `worktree create --codex-model <id>` as the
equivalent for a Codex-primary worktree, and notes that Codex's `/model`
switches a running session but saves the choice to the shared `tbd` profile.

## Error handling

Both layers refuse `--model` on Claude, shell, or an unspecified type. Once
accepted, TBD treats the identifier as Codex input; if Codex rejects it, the
terminal shows Codex's own launch error through the existing spawn behavior.

Worktree creation does not fail merely because `--codex-model` accompanies a
non-Codex primary. The resolved primary kind is configuration-dependent, and
the option is scoped to the `.codex` branch rather than made into a second
agent-selection mechanism.

## Tests and verification

- **`CodexSpawnCommandBuilderTests`** – an absent or empty model produces a
  command byte-identical to the existing one; a present model lands between
  the profile flag and the bypass flag, before a prompt or a `resume`
  argument; shell-significant and TOML-significant characters stay inside one
  argument and one TOML string.
- **`ModelProfileSpawnTests`** – a Codex primary with `codexModelOverride`
  carries `-c 'model="<id>"'`; one without carries no `-c`; a Claude primary
  ignores the override; `terminal.create` passes the model to a Codex launch
  and refuses it, before touching tmux or the terminal table, for no type,
  `claude`, and `shell`.
- **`CodexModelOptionParsingTests`** – `--model` parses with `--type codex`
  and is refused with `claude`, `shell`, no type, or an empty value;
  `--codex-model` parses and refuses an empty value; both params structs
  decode from JSON that omits the new fields.

Verification runs `scripts/swift-safe build` and `scripts/test.sh`.

## Placement and rollout

This behavior belongs in the compiled CLI-to-daemon spawn path because only
that path has the per-create request, the resolved terminal kind, and the
command construction. A user-authored wrapper could add `-c` only by bypassing
TBD's Codex spawn and its instrumentation.

No feature flag is warranted. The behavior requires an explicit create-time
option, performs no autonomous action, destroys no state, and leaves the spawn
path unchanged when the option is absent. It creates no new durable resource,
so the reconciler doctrine does not apply.

## Alternatives considered

### Explicit optional RPC fields – chosen

Carry the one-shot value on the existing create requests and apply it at the
two fresh Codex spawn sites. This matches the lifetime of the user's choice,
keeps old clients compatible, and makes the no-override branch identical to
today.

### A TBD-level live switch – rejected

Restarting a terminal on a new model would need a `codex resume` replacement
path that TBD does not have, plus a stored model to reapply, for something
Codex's `/model` already does in place without losing the session.

### Store the model on the terminal row – rejected

Reapplying a stored model on recreate would need a schema column and would
compete with `/model`: after a user switches in-session, the stored value is
stale, and reapplying it would silently undo their choice.

### Reuse `ModelProfile.model` or `WorktreeCreateParams.model` – rejected

Those fields describe Claude routing and ultimately set `ANTHROPIC_MODEL`.
Reuse would make a Claude profile silently control Codex and would leave
`worktree create --model` ambiguous between agents.

### Mutate Codex config or inject a shared environment value – rejected

Editing `tbd.config.toml`, `config.toml`, or shared spawn environment would
outlive one create request and affect unrelated terminals, and restoring the
old value would race concurrent creates. A command-line override has the
required one-process lifetime without shared mutation.
