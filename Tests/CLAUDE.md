# Tests

## Never reap background jobs with `jobs -p` in the tool shell

When simulating CI load to reproduce a flaky test, do NOT spawn background load
and reap it with `kill $(jobs -p)`. Job control is OFF in the non-interactive
tool shell, so `jobs -p` returns nothing, `kill` reaps nothing, and every
backgrounded `&` child orphans to launchd and runs forever (this once leaked 22
`yes` processes at ~850% CPU for a week).

Instead, guard the whole script with `trap 'kill 0' EXIT` (kills the process
group on exit), or capture each PID explicitly (`p=$!; ...; kill "$p"`) with
`pkill -P $$` as a backstop. For a long-lived helper, prefer the Bash tool's
`run_in_background` option, which the harness tracks and reaps.

This is also enforced mechanically by the `background-jobs` rule in
`.claude/hooks/guardrails`, which blocks the broken shape at PreToolUse time.

## Test tiers

Three tiers, defined by what a test may touch: tier 1 (deterministic,
in-process state only — no real sleeps, subprocesses, tmux, network, or
`~/tbd`), tier 2 (in-process integration — real concurrency, real filesystem,
real git subprocesses, deadlines only via bounded waits), tier 3
(live-external — real tmux server, real `ps`, spawned processes, the replay
firehose). Full taxonomy: `docs/specs/2026-07-24-test-hardening-design.md` §3.

Tier 3 suites live in `Tests/TBDDaemonLiveTests/`. A suite belongs there if
and only if its runtime depends on an external process it does not fully
control: it spawns a real tmux server, shells out to `ps`, spawns a child
racing a deadline, or drives the replay firehose. CI runs that target
serially on an otherwise-idle machine, in a separate step from the fast
parallel pass.

That step passes `--no-parallel` explicitly. Omitting `--parallel` is **not**
equivalent: SwiftPM's `--parallel` governs XCTest's process-level sharding,
while Swift Testing parallelizes suites in-process regardless. Measured here,
the difference is all 17 live suites starting simultaneously versus running
one at a time.

The failure asymmetry is the thing reviewers get wrong: leaving a heavy suite
in the parallel pass is merely the status quo, but moving a fast
deterministic suite into the serial pass taxes every PR forever. When in
doubt, leave it in the parallel pass.

New tests should state their tier. Tier-1 tests contain no real sleeps.

## Assertion hygiene

Four rules. Each traces to a real flake — provenance kept so the rule sticks.

1. **Assert contracts, not incidents.** Prefer membership (`contains`) over
   `.last` or positional/ordering assertions unless ordering is the
   documented contract. (The paste-failure flake: `delete-buffer` and the
   follow-up keystroke are order-independent effects, so pinning `.last`
   pinned an incident.)
2. **No wall-clock freshness windows.** Bracket with `[before, after]`
   captured around the call, or inject the date. (`resolve_success_bumpsLastUsedAt`
   blew a 5-second window by 0.11 s under CI load.)
3. **No bare `Task.sleep(for:)` as a synchronization primitive in tests.**
   Tier 1 advances a test clock; tiers 2–3 use bounded polling with a
   deadline (`waitFor` style). In `Sources/` this is now mechanical — the
   `no_raw_task_sleep` SwiftLint rule rejects any unsuppressed `Task.sleep`.
   In `Tests/` it stays a review rule: the lint rule deliberately does not
   cover test code, where tier-2/3 bounded polling is legitimate. See
   "Clock and date seams" below for the seam the rule pushes you toward.
4. **Timeout errors must report observed state, not just expected.**
   (`fileBytesMismatch(expected: 6150, actual: 6150)` re-read the file
   *after* the deadline and therefore lied about what it saw;
   `fileBytesUnmatched(expected:observed:correctPrefix:)` is the corrected
   shape.)

Full rationale: `docs/specs/2026-07-24-test-hardening-design.md` §6.

## Clock and date seams

Governing rule: **`Duration` is behavior, `Date` is data.** The two seams are
not interchangeable — picking the wrong one is how a test ends up measuring
elapsed wall time on a loaded runner instead of asserting behavior.

### Behavior — delays, debounces, timers, polling intervals, timeouts

```swift
init(..., clock: any Clock<Duration> = ContinuousClock())
```

Last initializer parameter, named `clock`, defaulted so no call site changes
and the migration is behavior-preserving by construction. **Existential, not
generic**, and not named `scheduler`: these subsystems are actors carrying
`Sendable` conformances, and a generic parameter would infect their types.

Tests pass `TestClock` and drive time with `advanceWhenSuspended(by:)` — no
sleeping, no load sensitivity, and exact virtual timings instead of tolerance
windows.

**The existential pins `Duration`, not `Instant`** — so it can express delays
but not deadlines:

| Compiles | Does **not** compile (`#ExistentialMemberAccess`) |
|---|---|
| `try await clock.sleep(for: .seconds(1))` | `clock.sleep(until:tolerance:)` |
| `clock.now`, storage in an `actor` | `instant.duration(to:)` |

Write timeout-shaped code duration-relative, as a task-group race:

```swift
group.addTask { try await work() }
group.addTask { try await clock.sleep(for: limit); return nil }
let first = try await group.next()
group.cancelAll()
```

This is also the better *test* shape: "time out after X" is directly
advanceable on a `TestClock`, while "sleep until instant Y" invites `Instant`
arithmetic that drifts back toward wall-clock reasoning. If you hit a case
that genuinely needs `Instant` math, raise it rather than switching the
subsystem to a generic clock parameter.

### Data — timestamps that get persisted or compared

Two shapes, also not interchangeable:

- **One-shot stamp** (`lastUsedAt`, hibernation stamps): a defaulted method
  parameter, `func touchLastUsed(at date: Date = Date())`. Tests pass a
  literal. No clock object needed to stamp a row.
- **Repeated "what time is it now" reads**: `now: @Sendable () -> Date` on the
  type. Tests back it with `TestDateSource`.

### Shared test helpers — `Tests/TestSupport/ClockTestSupport.swift`

Don't roll your own test clock wrapper, advance helper, `.timeLimit` default,
or date box. This file is the whole shared surface:

- `@Suite(.clockDriven)` — a one-minute time limit (Swift Testing's floor
  granularity). A hang-catcher, not a perf budget.
- `await clock.advanceWhenSuspended(by:)` — the one you want by default.
- `await clock.waitForSuspension()` — the same wait without advancing.
- `TestDateSource` — a lock-guarded box behind the `now: @Sendable () -> Date`
  seam. Deliberately a class with a lock rather than an actor, because that
  seam is a *synchronous* `() -> Date`.

**The failure mode to design against:** a tier-1 test awaiting a `TestClock`
sleep that nobody advances hangs forever. Two mitigations, use both —
`.clockDriven` on the suite bounds the hang, and `advanceWhenSuspended` turns
"the code under test never armed its timer" from an infinite hang into a named
failure. Convention: **put the advance immediately next to the assertion it
unblocks**, not in a setup block far away.

One caution on those two helpers: they record an `Issue` and continue rather
than throwing, which is safe *only* because neither returns a value. A
non-throwing waiter that does return something — `ControlModeTestSupport.waitFor`
(PR #415) — also keeps going after recording, so anything you index out of its
result must be `#require`-guarded or the test crashes instead of failing
cleanly. Don't generalize "non-throwing" into "no `#require` needed".

`PollerClock` is **not** this seam and must not be copied as a template — see
its doc comment. Full rationale:
`docs/specs/2026-07-24-test-hardening-design.md` §5.
