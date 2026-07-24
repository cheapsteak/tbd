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
   deadline (`waitFor` style). The clock seam and the `no_raw_task_sleep`
   lint rule are landing in a later slice, so today this rule is enforced by
   review, not mechanically.
4. **Timeout errors must report observed state, not just expected.**
   (`fileBytesMismatch(expected: 6150, actual: 6150)` re-read the file
   *after* the deadline and therefore lied about what it saw;
   `fileBytesUnmatched(expected:observed:correctPrefix:)` is the corrected
   shape.)

Full rationale: `docs/specs/2026-07-24-test-hardening-design.md` §6.
