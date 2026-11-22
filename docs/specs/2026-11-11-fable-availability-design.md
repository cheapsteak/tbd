# Fable availability

TBD knows, per profile, whether the account can run a Fable model right now,
and balancing never places a session that would run Fable on a profile whose
fresh reading is `out`. A profile not read in time counts as eligible, so such
a session can still land on an account that is out but not yet read (see
Balancing).

## Why

Fable needs **usage credits**, a meter separate from the 5-hour and weekly
windows. An account with plenty of window headroom can still be unable to run
Fable, and nothing in the usage snapshot says so. (`ProfileUsageFetcher`
deliberately drops model-scoped buckets; this design does not change that.)
Without a signal, a Fable spawn that balancing places on an out-of-credits
account opens a tab that fails on its first turn.

## The signal

Run the same command `tbd profile exec` would, under the profile:

```
claude -p --model claude-fable-5-2 --output-format json "Reply with only the word ok"
```

It prints one JSON result object. The classifier
(`FableProbeClassifier.classify(resultJSON:now:)`, pure, in `TBDShared`) maps
it to a state:

- **`available`** – `is_error` is `false`, `result` is a non-empty string, and
  there is no `api_error`.
- **`out`** – `is_error` is `true`, and either `api_error` is
  `"model_requires_usage_credits"` (HTTP 429, nothing billed), or there is no
  `api_error` and `result` says "out of usage credits".
- **`unknown`** – everything else. That covers two kinds of reply:
  - An error that is not about credits: `api_error: "usage_limit_reached"`
    (the 5-hour or weekly window), a network or auth failure, or any other
    code.
  - A reply that cannot be read: empty output, malformed or truncated JSON, a
    value that is not an object, a missing or non-boolean `is_error`, an
    `api_error` that is not a string, or a missing result.

A second signal needs no probe: Claude Code's StopFailure hook. When a Fable
turn fails because the account has no credits, the error message
`tbd hooks stop-failure` builds from the hook's input (and the API-error record
in the session transcript that input names) is "You're out of usage credits.
Run /usage-credits to keep using Fable 5.2 or /model to switch models." The
hook command forwards that message (`claude.fableCreditsOut`); the daemon
re-classifies it (`classify(hookMessage:now:)`), checks that the session runs
a Fable model (the terminal's spawn model, else its profile's configured
model), and marks the terminal's profile `out` with source `session`. The
signal is hook payload, never text read off a terminal screen.

## Fail closed

`available` is produced only from an `is_error` that is exactly the JSON
boolean `false` plus a result. `out` is produced only from the credits signal
itself. **A window limit is never `out`**: when the credits code is absent, a
reply carrying any other `api_error` is `unknown` even if its text mentions
credits. Everything unrecognised is `unknown`, and `unknown` is "not known to
be out": balancing does not refuse it. The `reason` field holds the `api_error`
code (or a fixed TBD tag such as `probe_timeout`), never reply text.

## State, TTLs and when a probe runs

`FableAvailability {state, reason, checkedAt, source: probe|session}`, held per
profile in the daemon's `FableAvailabilityStore` (an actor, in memory only;
nothing secret is stored, and a restart costs one probe per account the next
time it is needed).

| State | Re-check after |
| --- | --- |
| `out` | 30 minutes |
| `available` | 6 hours |
| `unknown` | 10 minutes |

**Nothing probes on a timer.** A probe runs only when something asks for a
reading that is missing or past its TTL: a spawn that TBD places (a balanced
pick or the global default) on a profile where its session would run Fable,
`tbd profile fable-check`, or `tbd profile list --refresh-fable`. Limits: one
probe at a time per profile (a second ask joins the one in flight), at most two
at once across profiles, 60 seconds each, then SIGTERM and SIGKILL. The probe
runs in the environment `tbd profile exec` builds
(`ProfileExecEnvironmentBuilder`, shared with that verb), and it does not move
the profile's last-used time. The daemon never logs the environment or the
output.

**A session's reading outranks an older probe.** The StopFailure hook's
reading replaces whatever the store holds for that profile. A probe of the
same profile that began before it may have read the account before the
credits ran out, so that probe's result is dropped when it finishes. A probe
begins when it gets one of the two slots, right before it reads the account.
A probe that begins after the hook's reading replaces it as usual. The store
orders the two by counting hook readings per profile, not by `checkedAt`: a
probe stamps its reading when it finishes, so its time is always later than a
hook reading that landed while it ran.

## Cost

A probe is a few tokens when the account has credits and bills nothing when it
does not. With `n` accounts the steady state is at most about `n` probes per
6 hours for accounts that stay available, and about `n` per 30 minutes while
one is out and Fable spawns keep arriving: a few probes per account per day.
Each probe also leaves one tiny session transcript under the profile's config
directory.

## Balancing

The Fable rule is decided per profile, by the model a session placed on that
profile would run: the spawn's own model when it names one, else the profile's
configured model. A model counts as Fable when it is an alias such as `fable`
or an id containing `fable`. A profile with no configured model never counts
as Fable for a spawn that names no model, because the account's own default
model is not visible to TBD. This is the same model `claude.fableCreditsOut`
checks before it records a reading. Each pool candidate carries it as
`ProfilePoolCandidate.model`.

A spawn is held to the rule when it names a Fable model, or names no model and
may be balanced. A resume (`balance: false`) that names no model is not held
to it. For a balanced pick:

1. Pool profiles a session would run Fable on, and whose reading is missing or
   stale, are probed first, and the spawn waits at most 45 seconds for them.
   A probe can run for up to 60 seconds and at most two run at once, so the
   wait can end with profiles still unchecked, most often when more than two
   need a probe or one is slow. **A profile still unchecked when the wait
   ends counts as eligible**: it is not refused, and the spawn does not wait
   for it any longer. Its probe keeps running and records the result for
   later spawns.
2. `ProfilePoolPicker` gives the verdict `.fableOut` to a profile whose
   session would run Fable and whose reading is `out` and fresh, before any
   usage-reading rule. It is never chosen and never reaches the fallback
   tiers (`aboveCeiling`, `staleReading`, `full`), which only name profiles
   turned away for their usage reading. A profile whose session would run
   another model is ranked as usual, whatever its reading.
3. If nothing is eligible and nothing is a fallback but some profile was
   `.fableOut`, the spawn fails with `FableUnavailableError` naming those
   profiles. It does not run another model. The same check guards the
   global-default step when a session there would run Fable, after a wait of
   up to 45 seconds for that profile's own probe.

So the guarantee is narrow: a session that would run Fable, placed by TBD
itself by a balanced pick or at the global default, never lands on a profile
whose fresh reading is `out`. It can land on an account that is out of credits
but not yet read. That session fails on its first turn, and the profile reads
`out` once its probe finishes or the session's StopFailure hook reports the
credits error, so later Fable sessions avoid it. The design accepts that gap
rather than hold a spawn until every probe ends.

A session that would run another model is unaffected. An **explicit pin** (the
picker's chosen profile, a repo or scratch override) is the person's choice
and is not second-guessed; the reading is shown in `tbd profile list` for them
to see.

## Surfaces

- `tbd profile list`: a `FABLE` column beside `5H`/`RESET`/`WK`: `ok`, `out`,
  `?` plus the reading's age (`out 12m`), `—` when never checked.
- `tbd profile list --json`: per profile `fable: {state, reason, checkedAt,
  source}`, absent when never checked. Additive; see
  [capacity-facts](../capacity-facts.md).
- `tbd profile fable-check [NAME...]` (and `list --refresh-fable`): force a
  probe now; no names means every pool profile.
- RPC: `modelProfile.fableCheck`, `claude.fableCreditsOut`, and an optional
  `fable` on `ModelProfileWithUsage`, all backwards-compatible.

## No flag

This ships without a default-off flag. Here is each case in which the repo's
CLAUDE.md asks for one, checked against this design:

- **Acting without a user gesture** – a probe runs only when something asks
  for a reading: a spawn whose session would run Fable,
  `tbd profile fable-check`, or `tbd profile list --refresh-fable`. Nothing
  probes on a timer or in the background. The one signal that arrives
  unasked, the StopFailure hook's credits message, runs no probe; it only
  updates the in-memory reading.
- **Killing processes** – the only process TBD signals is its own probe. A
  `claude -p` probe still running after 60 seconds gets SIGTERM, then
  SIGKILL. No session and no other process is touched.
- **Deleting or changing persisted state** – readings live in memory only,
  and a probe does not move the profile's last-used time. A probe prepares
  the profile's config directory the way `tbd profile exec` does, and Claude
  Code leaves one small session transcript there (see Cost). Nothing is
  deleted or rewritten.
- **Sending input to a session** – none. A probe is its own headless process
  with no stdin, and the hook path only records a reading.
- **Replacing a load-bearing path** – balancing gains one verdict,
  `.fableOut`, which the picker gives only to a profile whose session would
  run Fable. The global-default step, which runs whether or not balancing is
  on, gains the same check by the same rule. So a spawn that names no model
  is also gated, but only on profiles configured for Fable. A spawn that names
  another model, a resume that names no model, and a spawn none of whose
  profiles would run Fable take the same path as before.
- **Moving existing UI** – the `FABLE` column is new, after the usage columns
  in `tbd profile list`, and `fable` is a new field in its JSON. Existing
  columns and fields keep their order and meaning; the trailing markers such
  as `[default]` come after the new column.

What it does cost:

- Each probe bills a few tokens on an account that has credits.
- A spawn is refused, not started, when every profile it could land on would
  run Fable and reads `out`.
- A spawn waits for probes of unchecked profiles it would run Fable on before
  it starts, at most 45 seconds per wait (see Balancing).

## Not verified yet

The StopFailure hook's delivery of the credits error message for a Fable turn
has not been observed on a real session; the probe path is the reliable signal.
