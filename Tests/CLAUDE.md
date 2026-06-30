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
