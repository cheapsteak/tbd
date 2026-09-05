# Benchmarking TBD's terminal render path with a real agent as the producer

**Audit record.** Measured 2026-08-26 against `/Applications/TBD.app` built at
14:09 from the temporary signpost branch described below, on a 12-core Apple
Silicon machine carrying ~40 concurrent agent sessions (load average 30–92
across the runs; no Swift builds active). Numbers are that machine on that day;
the method is what generalizes.

## What problem this solves

TBD's embedded terminals feel laggy under heavy output. Measuring that honestly
needs a producer that is both *realistic* (a real agent TUI, not a synthetic
byte stream) and *deterministic* (the same bytes every run, so an A/B compares
renderers rather than two different workloads).

Driving a live agent against the real API gives realism and no determinism: the
token stream differs every run, costs money, and carries network jitter. A
synthetic `printf` loop gives determinism and no realism: it emits byte patterns
no TUI produces, and its own overhead can silently become the bottleneck.

Pointing Claude Code at a local fake Anthropic endpoint gives both. The real TUI
does the rendering; a scripted SSE stream decides exactly what it renders, at a
rate we choose, for free and offline.

## How it works

Claude Code honours `ANTHROPIC_BASE_URL`, so it can be aimed at a local server.
`ANTHROPIC_AUTH_TOKEN` set to any dummy string bypasses the OAuth flow, and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` silences background chatter that
would otherwise hit the fake server. Verified against Claude Code 2.1.246, which
ships as a Bun-compiled native binary rather than a `cli.js`.

The pieces:

- **`scripts/diag/fake-anthropic-server.py`** — a stdlib HTTP server answering
  `POST /v1/messages` with a scripted SSE stream. `FA_DELTAS`, `FA_RATE`,
  `FA_TEXT` and `FA_NEWLINE` control length, pace, delta size, and how often a
  newline is emitted (which decides whether the TUI scrolls).
- **`scripts/diag/bench-cc-render.sh`** — spawns a TBD terminal running Claude
  Code against that server, optionally switches renderer, foregrounds the tab,
  submits a prompt, captures signposts, and reports.
- **`scripts/diag/signpost-report.py`** — summarizes a capture.

Injection must go through `tbd terminal create --cmd`. TBD's `envOverrides` is
repo-wide, so using it would silently point *real* sessions at the fake endpoint.

```
scripts/diag/bench-cc-render.sh --worktree <worktree-id> --label cc-fs --mode fullscreen
scripts/diag/bench-cc-render.sh --worktree <worktree-id> --label cc-def --mode default
```

### Prerequisite: the signpost build

The scripts read three `os_signpost` intervals that exist only on a temporary
instrumentation branch (`diag: signpost the terminal render path`), which is
deliberately unmerged. Confirm the running app carries it before trusting a run:

```
strings /Applications/TBD.app/Contents/MacOS/TBDApp | grep -c RenderLatencySignposts   # must be 1
```

Rebuilding from a branch without the instrumentation destroys the instrument.

## Reading the three intervals

Each measures something different, and conflating them produces wrong
conclusions:

- **`mainThreadHop`** — the main-thread *queueing delay* for a pty chunk, from
  just before `DispatchQueue.main.async` to the block running. It is waiting,
  not work. A large value means the main thread was busy with something else.
- **`feed`** — the nested `TerminalView.feed()` call: parse plus damage
  tracking. Synchronous and nested, so this is the **trustworthy cost signal**.
- **`displayPass`** — an **upper bound** on one AppKit display pass. It begins in
  `viewWillDraw()` and ends on the next main-queue turn, so a backed-up main
  queue inflates it. A large `displayPass` does not mean drawing was slow.

The derived figure that matters most is **`feed` work per wall-second**: total
`feed` time divided by the span. Above ~1.0 the main thread is saturated by
parsing alone, before any drawing happens.

## Results

Two producers, same machine, same instrument. `chunks/s` is `mainThreadHop`
count over the window span.

    producer                            renderer      chunks/s  feed p50  feed work/s  passes/s
    Claude Code, 40 deltas/s            fullscreen        38.9   0.12 ms       0.01        5.4
    Claude Code, 40 deltas/s (repeat)   fullscreen        37.7   0.12 ms       0.01        5.0
    Claude Code, 40 deltas/s            default           36.5   0.12 ms       0.01        6.2
    Claude Code, 400 deltas/s           default           30.0   0.10 ms       0.00        7.1
    synthetic, 2637 lines/s             alt-screen       354.8   0.38 ms       0.13       22.7
    synthetic, 2637 lines/s (repeat)    alt-screen       364.1   0.38 ms       0.14       21.2
    synthetic, 2637 lines/s             scrolling        274.3   6.15 ms       0.96        1.1
    synthetic, 2637 lines/s (repeat)    scrolling        226.8   6.30 ms       0.96        1.0

Three findings:

**An agent cannot saturate TBD.** Claude Code emits ~30–40 screen updates per
second regardless of renderer, and raising the token rate tenfold (40 → 400
deltas/s) *lowered* the chunk rate to 30/s — it coalesces repaints internally.
Feed work stays at 0.01 s/s, leaving the main thread ~99% idle. The renderer
choice makes no material difference either.

**Full-viewport repaint is cheap; scrolling line-append is expensive.** At
matched volume (2,637 lines/s, ~320 KB/s), alt-screen repaint costs 0.38 ms per
chunk while scrolling append costs 6.2 ms — about 10x per byte. The scrolling
case consumes 0.96 s of parse work per wall-second and the view drops to ~1
display pass per second. This is the opposite of the intuition that redrawing
every visible row must cost more than appending one line.

**The cost is upstream of drawing.** It lands in `feed` — parse and damage
tracking — not in `drawTerminalContents`. Optimizing the per-row
`NSAttributedString` rebuild would target a path that is not the bottleneck.

Together these point away from agent output as the lag source and toward
high-rate scrolling output in ordinary tabs: build logs, test runs, `cat` of a
large file.

## Pitfalls that have produced wrong answers here

Every one of these produced a confident, wrong number during this work.

- **A capture with no `displayPass` intervals is void.** Those only occur if the
  view actually draws, which requires the tab to be on screen. A hidden terminal
  feeds and parses happily and yields a plausible table that means nothing. The
  bench script now aborts loudly below 20 passes.
- **A fixed `sleep` after spawning loses keystrokes.** Under load, Claude Code
  took longer than 10 s to boot; the mode command and the prompt both went
  nowhere, producing a capture containing no load at all. Wait on machine
  signals instead: `HEAD /api/hello` in the server log proves the TUI booted, and
  `POST /v1/messages` proves the prompt submitted.
- **Verify the renderer actually switched.** `/tui default` applies reliably when
  sent programmatically; `/tui fullscreen` often does not. Check tmux's
  `alternate_on` (1 = alternate screen, 0 = normal screen) rather than assuming.
  Note that `default` is the *name* of the inline/scrolling renderer, so "already
  using the default renderer" is a statement about mode, not about your config.
- **The producer can be the bottleneck.** A naive Python loop building strings
  per line capped at ~345 lines/s and was misread as pty backpressure. A `cat` of
  1.92 MB completes in 0.095 s (~20 MB/s), which settles it: the pipe is not the
  constraint. Precompute the frame buffers and report achieved throughput.
- **Rates must divide by the span actually covered by data.** `log stream` starts
  mid-flight, so intervals whose `begin` predates the first captured
  `mainThreadHop` must be excluded, and a load period that ends early must not be
  divided by the nominal window width. Getting both wrong once inflated a figure
  from 0.75 to 0.97 s/s by coincidence.
- **Take more than one window, and note the load.** A single window produced a
  wrong committed conclusion earlier in this investigation. Run the A/B
  back-to-back so both halves share machine state, and record the load average.
- **`pgrep -f` matches your own command line**, which once produced a phantom
  "the app restarted eight times" reading.

## Limits

The fake stream removes network jitter by construction, so this measures render
cost, not end-to-end perceived latency. It also drives text deltas; a real
session additionally renders tool-use blocks and their results, and Claude Code
buffers bulk tool output rather than painting it — which is why pointing the
harness at an agent's *tool* output does not reproduce heavy load either.
