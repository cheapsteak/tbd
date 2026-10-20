# Session usage from the session mod

## Summary

TBD learns a Claude session's context window — the denominator of "how full is
this session" — from a statusline tee: a wrapper installed as the
`statusLine.command` of Nightwatch desk sessions only, which saves Claude
Code's statusline stdin JSON to
`~/tbd/runtime/statusline-capture-<terminalID>.json`. The session mod's API now
reports the same figures directly. This design adds a `usage` feature to the
session mod that writes those figures to the session's own directory, makes it
the context source for every Claude session that loads it, stops installing the
tee on spawns that carry it, and ends with the tee deleted.

## Problem

A session's effective context window is a session fact, not a model fact.
Claude Code resolves it per session from the model id, a long-context suffix, a
beta header, environment overrides and a remote flag, so the same model can run
at 200k or at 1M. The fleet-supervision design
([`2026-07-26-fleet-supervision-design.md`](2026-07-26-fleet-supervision-design.md),
§2 and §15) refuses a model-to-window table because a table reports capability,
and capability errs in the unsafe direction: 1M claimed for a 200k session
reads one-fifth full at the boundary.

The tee was the one machine source for the resolved window, and it carries
three costs:

- **It is desk-only.** `statusLine` does not merge across settings scopes, and
  TBD's per-session `--settings` outranks every scope a person can write, so a
  fleet-wide tee would take over their status line in every session. Every
  non-desk session therefore reports its window as `unknown`.
- **It is intricate.** A POSIX shell script that buffers stdin, publishes
  atomically, delegates to the person's own statusline found by
  `OperatorStatuslineResolver`, and stays silent in every failure branch, plus a
  capture sweep for its leftovers — about 360 lines of source and 1,400 of
  tests.
- **It serves a deprecated consumer.** Its readers are the Nightwatch desk's
  relay script and `session.states`; Nightwatch desks do not run with the pty
  holder.

## Facts this design rests on

Measured against Claude Code 2.1.303 with the fake model API
(`scripts/claude-stub.py`), a probe mod and a plain statusline command in the
same session:

- `$.session.usage().context.window` and the `session.measure` event's
  `context.window` equal the statusline's `context_window.context_window_size`
  in every case tried: 1,000,000 for `claude-opus-5-5` and `claude-haiku-5-5`,
  200,000 for `claude-sonnet-4-5`, and 1,000,000 for `claude-sonnet-4-5[1m]`.
  The last two are the same model, so the mod reports the resolved window, not
  the model's capability.
- `context.tokens` equals the statusline's `current_usage` input +
  cache-creation + cache-read sum, and `context.percent` equals
  `used_percentage`. Before the first response both sources report no fill and
  a known window. The stub reports one input token per request, so a large
  fill was not exercised; the API documents `tokens` as the statusline's
  input-side figure.
- `session.measure` fires after each main-thread turn and when a rate-limit
  window moves a whole point. Its payload also carries `rateLimits` and `cost`.
- Settings-hook payloads carry no window and no usage. The transcript JSONL
  carries per-message usage and the model id, but no window. Claude Code's
  per-process session registry carries neither.

## Design

### The feature

A new session-mod feature, `usage`, in `SessionMod/hooks/features/usage.ts`,
wired through `register.ts` like `composer-draft`.

- **`session.start`** writes a baseline from `$.session.usage()`, so a session's
  window is known before its first turn — the point at which the tee's first
  statusline run made it known.
- **`session.measure`** writes the event's figures on every measurement.

Both write `<TBD_SESSIONS_DIR>/<claudeSessionID>/usage.json`, resolving the
directory from `$.session.id()` at each write as the shared session code does.
The handlers are exported named functions, so tests can call them directly.

### The file

`usage.json` holds:

- `schemaVersion`
- `claudeSessionID` and `incarnationID`
- `measuredAt` – milliseconds from `$.clock.now()`
- `context` – `window`, and `tokens` and `percent` when the engine has them
- `rateLimits` – a list of `kind`, `percentUsed`, and `resetsAt` when known;
  empty off a subscription
- `cost` – `usd`, when the engine keeps a ledger

A figure the engine does not have is left out, never zeroed. Readers ignore
fields they do not know, as the session-mod spec requires.

`$.fs` has no rename, so a reader can meet a torn file. Every reader treats a
file that does not parse, or a `context.window` that is not a positive integer
(a boolean included), as "not observed" and falls back. It never reads as zero.

Nothing in TBD reads `rateLimits` or `cost` yet. They are recorded because the
mod gets them at no extra cost and the account load-balancing work could use
per-session rate-limit readings; a reader for them gets its own design.

### The flag

`session_mod_usage_enabled INTEGER` on `config`, added with no SQL default so
unset stays a third state. `ConfigRecord.toModel()` reads it as
`?? Config.sessionModUsageDefault`, which ships `false`. The GRDB record and
the Codable `Config` gain the field in the same commit as the migration.
`SessionModFeature` gains `.usage`, listed by `enabled(in:)` when the flag is
on, and Settings gains a toggle beside composer-draft.

The flag is required because the feature loads the mod into every Claude
session and replaces how desk sessions are configured.

### Where the tee installs

A desk spawn installs the tee only when `usage` is absent from that spawn's
feature list. The decision reads the feature list the spawn was given, never a
fresh read of config, so a spawn and the readers that later consult its
`spawn.json` agree about which source it has. With `usage` on, a desk's overlay
leaves the person's own `statusLine` in force, as for any other session. With
it off, desk spawns are unchanged.

A fresh spawn runs `SessionModSpawn.prepare` before it resolves the overlay, so
the overlay is written once from the real feature list. A replacement spawn —
a wake, an in-place profile swap, Continue in Claude — learns its incarnation
only at launch, after its command and overlay are built. It resolves the
overlay from the features `prepare` is expected to return, then, once
`prepare` has run and before the process launches, rewrites that same overlay
file if the real list differs: a spawn record that could not be written, or a
flag changed in between. Every desk keeps a per-session overlay file whether or
not it carries the tee, so the path in the spawn command never changes.

A wake that adopts a holder process still running launches nothing, so the
correction never runs; the overlay follows the expected list. If that process
was spawned without `usage` and the flag has since been turned on, its tee is
dropped and its capture deleted, and its window reads as `unknown` until it
next respawns — never as a stale figure.

A reader trusts `usage.json` only when its `incarnationID` names the live
incarnation; a file left by an earlier process of the same session reads as
not yet written.

### Readers

**`ContextLoadReader`**, behind `session.states`, consults in order:

1. **`usage.json`**, when `SessionModLiveness` answers `confirmed` for `usage`
   and the file parses with a valid window. Window, tokens and percent were
   measured together, so the reading is paired. Its source is a new
   `FactSource.sessionMod`, and its observed-at is `measuredAt`.
2. **The tee capture**, when liveness answers `legacy` — a spawn made without
   `usage`. Unchanged from today.
3. **The transcript tail** for tokens, with the window `unknown`. The `why`
   names the case: `usage` was spawned but the mod has not confirmed this
   process; the usage file is missing or unreadable; or neither source applies
   to this session.

The reader's input changes from the desk role to the spawn's source: whether
`usage` was in its feature list, and the liveness answer.

**`handoff.py`**, the desk relay script in `NightwatchSkillContent.swift`,
reads `usage.json` through the `claudeSessionID` on the terminal row it already
fetches, then the tee capture, then its 600,000-token fallback, applying the
same validity rule at each step. It trusts the usage file only when its
`incarnationID` equals the script's own `TBD_TERMINAL_INCARNATION_ID`, which
every spawn that loads the mod sets. Wakes and swaps keep the session ID, so
without that check a file from an earlier process — one spawned while the flag
was on, say, before a swap to a smaller window — would outrank a fresh tee
capture and set the ceiling too high. A missing variable or a mismatch reads as
"not observed". It needs no heartbeat check: a matching incarnation means its
own process wrote the file. A `/clear` keeps the incarnation, so the file under
the row's session ID stays acceptable, and `/clear` does not change the window.

### Reclaim

`usage.json` lives in the per-session directory that the existing `OrphanGC`
session arm reclaims. No new reconciler.

### Placement

The producer is user-land: a feature file in the session mod. The compiled
parts are reads — the reader order and the liveness check, which the
session-mod design already keeps compiled — and the flag.

## Testing

**Mod**, in `SessionMod/tests/` under CI's "Session mod" job:

- `session.measure` writes every field it was given, and leaves out absent
  `tokens`, `percent` and `cost`.
- `session.start` writes a baseline with the window.
- A spawn without `usage` in `TBD_MOD_FEATURES` writes nothing.

**Daemon**, each flag branch:

- The column is three-state: a pre-migration row reads NULL, and an explicit
  `false` survives a change to `sessionModUsageDefault`.
- Flag off: a desk spawn installs the tee; no spawn lists `usage`; a non-desk
  overlay is byte-identical to the overlay produced without this change.
- Flag on: a desk spawn installs no tee, keeps the person's `statusLine`, and
  lists `usage` in `TBD_MOD_FEATURES` and `spawn.json` — on a fresh spawn, a
  wake, and an in-place profile swap.
- `ContextLoadReader`: confirmed with a valid file gives a paired `.observed`
  window sourced `sessionMod`; confirmed with a torn file falls back; unknown
  liveness gives `unknown` with its `why`; legacy reads the tee capture.
- A zero, negative or boolean window is refused by both the Swift and the
  Python reader.

**`handoff.py` selftest:** the usage file wins over the capture; torn, boolean,
zero and missing windows each fall through; the capture still serves when no
usage file exists.

**Live, before merge:** one desk spawn against the fake model API with the flag
on, on tmux and on the pty holder. `usage.json` appears with the window the
statusline reports, and the person's own statusline still renders.

## Soak and graduation

Soak with `session_mod_usage_enabled` on. Evidence to collect: `session.states`
reports `sessionMod`-sourced windows for non-desk sessions, and desks relay at
three quarters of their observed window rather than at the fallback.

Graduation sets `Config.sessionModUsageDefault` to `true`. A follow-up change
then deletes `StatuslineTee`, `OperatorStatuslineResolver`, the capture path
constants, the capture arm of the orphan sweep, the tee arm of both readers,
and their tests.

## Rejected alternatives

- **Read the tee first on desks during the soak.** The desk is the one consumer
  that acts on the window, so the soak would never exercise the new source
  where it matters.
- **Keep both sources and let the reader choose.** The spawn already decides
  which source it has; a second decision at read time can disagree with it.
- **Make the daemon the only reader**, with `handoff.py` asking over a CLI or
  RPC call. It adds a compiled surface and makes the desk's relay depend on the
  daemon being reachable, where a file read suffices.
- **Push figures from the mod to the daemon.** It needs the daemon-mod channel
  the session-mod design chose not to build, and no consumer needs a push.
- **Widen the tee to every session.** It takes over the person's status line in
  every session they open.
- **A model-to-window table.** It reports capability, not the resolved window.
- **Record only the context figures.** Rate limits and cost arrive in the same
  event at no cost, and recording them now spares a schema bump later.
