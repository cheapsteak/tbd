# Session usage from the session mod

## Summary

TBD learns a Claude session's context window — the denominator of "how full is
this session" — from the session mod. The session-mod API reports the window
Claude Code resolved, with the tokens and percent beside it. This design adds a
`usage` feature to the session mod that writes those figures to the session's
own directory and makes it the context source for every Claude session that
loads it. A session spawned without it reports its numerator from the
transcript tail and its window as `unknown`.

## Problem

A session's effective context window is a session fact, not a model fact.
Claude Code resolves it per session from the model id, a long-context suffix, a
beta header, environment overrides and a remote flag, so the same model can run
at 200k or at 1M. The fleet-supervision design
([`2026-07-26-fleet-supervision-design.md`](2026-07-26-fleet-supervision-design.md),
§2 and §15) refuses a model-to-window table because a table reports capability,
and capability errs in the unsafe direction: 1M claimed for a 200k session
reads one-fifth full at the boundary.

The other surface where Claude Code tells a third party the resolved window is
the statusline's stdin JSON, and it is the wrong one to build on:

- **It cannot cover the fleet.** `statusLine` does not merge across settings
  scopes, and TBD's per-session `--settings` outranks every scope a person can
  write, so a TBD statusline wrapper on every session would take over their
  status line in every session. A wrapper confined to a few sessions leaves
  every other one reporting its window as `unknown`.
- **It is intricate.** A wrapper is a POSIX shell script that buffers stdin,
  publishes atomically, delegates to the person's own statusline, and stays
  silent in every failure branch, plus a capture sweep for its leftovers. One
  built for TBD ran to about 360 lines of source and 1,400 of tests.

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
  window is known before its first turn.
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

A reader trusts `usage.json` only when its `incarnationID` names the live
incarnation; a file left by an earlier process of the same session reads as
not yet written.

### The flag

`session_mod_usage_enabled INTEGER` on `config`, added with no SQL default so
unset stays a third state. `ConfigRecord.toModel()` reads it as
`?? Config.sessionModUsageDefault`, which ships `false`. The GRDB record and
the Codable `Config` gain the field in the same commit as the migration.
`SessionModFeature` gains `.usage`, listed by `enabled(in:)` when the flag is
on, and Settings gains a toggle beside composer-draft.

The flag is required because the feature loads the mod into every Claude
session.

### Readers

**`ContextLoadReader`**, behind `session.states`, consults in order:

1. **`usage.json`**, when `SessionModLiveness` answers `confirmed` for `usage`
   and the file parses with a valid window. Window, tokens and percent were
   measured together, so the reading is paired. Its source is a new
   `FactSource.sessionMod`, and its observed-at is `measuredAt`. The file is
   read only under that `confirmed` answer, and only when its `incarnationID`
   names the row's live incarnation; every `unknown` answer, a stale heartbeat
   included, reads the window as `unknown`. A parked row whose session's
   `spawn.json` lists `usage` reads the window as `unknown` with a `why` saying
   the session is parked and no process is reporting its window, and takes its
   numerator from the transcript. Parking replaces the agent with an inert
   shell that never runs the mod, and `spawn.json` is shared by every spawn of
   the session and overwritten by each, so it cannot say which process wrote a
   usage file still on disk.
2. **The transcript tail** for tokens, with the window `unknown`. The `why`
   names the case: the session is parked; `usage` was spawned but the mod has
   not confirmed this process; the usage file is missing or unreadable; or the
   session was spawned without `usage`, so nothing reports its window.

The reader's input is the spawn's source: whether `usage` was in its feature
list, and the liveness answer.

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
- Flag off: no spawn lists `usage` in `TBD_MOD_FEATURES` or `spawn.json`.
- Flag on: a spawn lists `usage` in `TBD_MOD_FEATURES` and `spawn.json` — on a
  fresh spawn, a wake, and an in-place profile swap.
- `ContextLoadReader`: confirmed with a valid file naming the live
  incarnation gives a paired `.observed` window sourced `sessionMod`;
  confirmed with a torn file or another incarnation's falls back; every
  unknown liveness, a stale heartbeat included, gives `unknown` with its
  `why`; legacy gives the transcript numerator and an `unknown` window. A row
  parked through the production park write whose spawn listed `usage` reads
  `unknown` saying it is parked, even beside a usage file.
- A zero, negative or boolean window is refused by the reader.

**Live, before merge:** one spawn against the fake model API with the flag on,
on tmux and on the pty holder. `usage.json` appears with the window the
statusline reports, and the person's own statusline still renders.

## Soak and graduation

Soak with `session_mod_usage_enabled` on. Evidence to collect: `session.states`
reports `sessionMod`-sourced windows for the sessions that load the mod.

**Accepted risk: a session whose mod never runs has no window source.** When
the mod does not run in a process spawned with `usage` — a Claude Code too old
for mods, plugins disabled by managed settings, a module that fails at load, or
a write to the sessions directory that fails — nothing reports its window, and
`session.states` says `unknown`. The risk is accepted rather than designed out,
because every cause breaks the mod for every session at once, the flag ships
off, and the soak watches for exactly this: a session whose `session.states`
window stays `unknown`.

Graduation sets `Config.sessionModUsageDefault` to `true`.

## Rejected alternatives

- **Push figures from the mod to the daemon.** It needs the daemon-mod channel
  the session-mod design chose not to build, and no consumer needs a push.
- **A statusline wrapper on every session.** It takes over the person's status
  line in every session they open.
- **A model-to-window table.** It reports capability, not the resolved window.
- **Record only the context figures.** Rate limits and cost arrive in the same
  event at no cost, and recording them now spares a schema bump later.
