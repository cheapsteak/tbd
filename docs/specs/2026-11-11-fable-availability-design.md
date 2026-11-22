# Fable availability

TBD knows, per profile, whether the account can run a Fable model right now,
and balancing never places a Fable spawn on an account known to be out.

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
(`FableProbeClassifier.classify(resultJSON:now:)`, pure, in `TBDShared`) reads:

| Reply | State |
| --- | --- |
| `is_error: false`, a non-empty string `result`, no `api_error` | `available` |
| `api_error: "model_requires_usage_credits"` (HTTP 429, nothing billed), or no `api_error` and a `result` saying "out of usage credits" | `out` |
| `api_error: "usage_limit_reached"` (the 5-hour or weekly window), network, auth, anything else | `unknown` |
| empty output, malformed or truncated JSON, a non-object, a missing or non-boolean `is_error`, a mistyped `api_error`, a missing result | `unknown` |

A second signal needs no probe: a live session whose model is a Fable model
shows "You're out of usage credits. Run /usage-credits to keep using Fable 5.2
or /model to switch models." The StopFailure hook forwards that line
(`claude.fableCreditsOut`); the daemon re-classifies it
(`classify(screenText:now:)`), checks the terminal's model is Fable, and marks
the terminal's profile `out` with source `session`.

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
reading that is missing or past its TTL: a Fable spawn that balances,
`tbd profile fable-check`, or `tbd profile list --refresh-fable`. Limits: one
probe at a time per profile (a second ask joins the one in flight), at most two
at once across profiles, 60 seconds each, then SIGTERM and SIGKILL. The probe
runs in the environment `tbd profile exec` builds
(`ProfileExecEnvironmentBuilder`, shared with that verb), and it does not move
the profile's last-used time. The daemon never logs the environment or the
output.

## Cost

A probe is a few tokens when the account has credits and bills nothing when it
does not. With `n` accounts the steady state is at most about `n` probes per
6 hours for accounts that stay available, and about `n` per 30 minutes while
one is out and Fable spawns keep arriving: a few probes per account per day.
Each probe also leaves one tiny session transcript under the profile's config
directory.

## Balancing

A spawn asks for Fable when its per-spawn model (an alias such as `fable`, or
an id containing `fable`) says so. For a balanced pick:

1. Pool profiles whose reading is missing or stale are probed first, waiting at
   most 45 seconds. **A profile still unchecked after that is eligible but
   unverified**: it is not refused, and the spawn is not delayed further.
2. `ProfilePoolPicker` gives a profile whose reading is `out` and fresh the
   verdict `.fableOut`, before any usage-reading rule. It is never chosen and
   never reaches the fallback tiers (`aboveCeiling`, `staleReading`, `full`),
   which only name profiles turned away for their usage reading.
3. If nothing is eligible and nothing is a fallback but some profile was
   `.fableOut`, the spawn fails with `FableUnavailableError` naming those
   profiles. It does not run another model and does not land on an out
   account. The same check guards the global-default step.

A non-Fable request is unaffected. An **explicit pin** (the picker's chosen
profile, a repo or scratch override) is the person's choice and is not
second-guessed; the reading is shown in `tbd profile list` for them to see.

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

## Not verified yet

The StopFailure hook's delivery of the credits line for a Fable turn has not
been observed on a real session; the probe path is the reliable signal.
