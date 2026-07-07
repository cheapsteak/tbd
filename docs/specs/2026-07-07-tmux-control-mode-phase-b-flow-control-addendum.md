# tmux control mode — Phase B addendum (flow control)

**Date:** 2026-07-07
**Status:** Implemented (M1–M3 of Phase B). Extends [`2026-05-17-tmux-control-mode-design.md`](./2026-05-17-tmux-control-mode-design.md) §"Flow control — Policy B" and [`2026-07-02-tmux-control-mode-phase-a-addendum.md`](./2026-07-02-tmux-control-mode-phase-a-addendum.md) §3. Tracking: #318 · dogfood evidence that pulled this forward: #376 · Phase A: #364.

## 1. What changed versus the base spec — and why

The base spec's Policy B state machine assumed tmux **buffers server-side while paused** and drains the backlog as `%extended-output` after `%continue` (`Streaming → Backpressured → Paused → Draining → Streaming`). Phase A's live matrix already refuted the premise, and this phase re-probed it directly:

**Probe findings (tmux 3.6a, 6/6 trials, throttled ~100 tokens/s AND unthrottled full-blast):**

1. **Pause discards.** A paused pane (`refresh-client -A '%X:pause'`) delivers **nothing** — zero bytes even with ~500k tokens emitted while paused. `continue` resumes delivery from the pane's *current* position; the paused-window output is never delivered to this client. It does land in the pane's history/screen, reachable via `capture-pane`.
2. **An atomic command list `[captures…, continue]` has a seam gap of exactly zero.** The first live token delivered after the batched continue is contiguous with the capture's last token (`firstLive == capturedLast + 1` in every trial, under both load profiles). tmux executes the batched commands back-to-back with no pane-output interleave.

Finding 1 kills the spec's `Draining` state: there is no backlog to drain. The replacement is the Phase A addendum §3 reserved design — **re-capture on pause** (iTerm2's shape for `%pause`) — which finding 2 upgrades from "converges eventually" to **provably gapless**: capture and continue in one atomic batch, with the post-continue output parked behind a fence until the recapture replay is in the pipe.

The 32 KB resume-hysteresis knob from the base spec's defaults table is gone with the `Draining` state: the resume gate is now *pipe writability* (the app reader caught up), because the local queue is **cleared** at overflow — its content is already in pane history and the recapture supersedes it.

## 2. The unified queue/fence machinery (`PaneFanout`)

One per-sink byte queue (cap **128 KB**, chunk-granular, generation-scoped) serves three roles:

- **M1 — backpressure queue.** `route()` no longer drops on `EAGAIN` (the #376 corruption source): the unwritten remainder queues, an async drain task (10 ms pacing, write-under-lock with sink+generation re-validation per pass) flushes as the reader catches up, and while *anything* is queued, new chunks enqueue behind it — live bytes can never overtake queued bytes.
- **M2 — attach fence.** During the attach sequence, output routed for the pane queues behind the closed gate instead of dropping; `markReady` clears the fence and arms the drain, so fenced bytes follow the replay in order. This closes Phase A's accepted 0.2–0.5 s attach boundary gap (measured 3–25 lost tokens under load; now **zero**, pinned by the live matrix's strict `firstLive == lastReplayed + 1` assertion).
- **M3 — repair fence.** The same fence parks post-continue output behind a mid-session recapture replay (below).

`route()`'s behavior table (documented in-source) is the state machine's concrete form:

| Sink state | `route()` behavior |
|---|---|
| no sink | count unattached drop |
| fenced (any ready state) | enqueue; **never** arm the drain (the flush belongs to `markReady`/`endRepair`) |
| !ready, !fenced | drop — pre-fence attach window; the bytes are in the attach's capture |
| ready, repairing, !fenced | drop with counters — pre-pause repair window; the recapture includes them |
| ready, queue non-empty | enqueue + arm drain |
| ready, queue empty | direct write; `EAGAIN` remainder → enqueue + arm drain |

Everything is **generation-scoped**, the invariant carried from Phase A's eleven review rounds: a superseded attach's queued/fenced bytes die with its sink; the drain, the fence, and every repair step re-validate `(key, generation)` and abort silently on mismatch.

Telemetry (issue #376's explicit ask — the old `.debug` drop counters weren't persisted and we flew blind): backpressure entry, overflow, drain recovery, and repair completion log at rate-limited `.info`; `PaneFlowStats` exposes the counters.

## 3. Why the attach/repair sequences batch in two phases

Command replies and `%output` reach the daemon on paths that do **not** preserve relative order end-to-end: output events are routed synchronously on the connection reader thread (`outputSink` → `PaneFanout.route`), while command replies hop `AsyncStream` → supervisor actor → correlator actor → completion. So "arm the fence when the pause reply completes" cannot, by itself, split pre-pause from post-continue output — a post-continue chunk could race ahead of the reply's actor hops and hit a not-yet-armed fence.

The fence is therefore armed only at a **provably silent** moment:

1. **Batch 1: the pause alone, awaited.** By stream order, everything pre-pause has already been routed (and dropped — it is in the capture; no loss). From the pause reply onward the pane delivers nothing (probe finding 1). No race window exists.
2. Arm the fence.
3. **Batch 2: captures + continue, one atomic list, continue last.** Zero seam (probe finding 2); post-continue output flows into the armed fence.
4. Write the replay behind the fence (the drain never runs while fenced), then clear the fence and arm the flush.

The batch split adds one supersession window (between batches), guarded by the same generation re-check discipline as Phase A's R10-3, with R11's rule intact: a superseded sequence sends nothing further and never unpauses — the successor's own FIFO-ordered sequence owns the pane's pause state.

## 4. The M3 repair cycle (`PaneRepairCoordinator`)

Steady-state queue overflow (ready, unfenced, not repairing) no longer drops. Instead:

1. The fanout **clears the queue** (its content is in pane history; the recapture supersedes it — nothing counts as dropped), flips the sink to `repairing` (routed output now drops-with-counters: pre-pause bytes the capture will include), and signals the coordinator outside the lock.
2. The coordinator pauses the pane (batch 1), then **waits for the app reader to catch up** (nonblocking `POLLOUT` probe, 50 ms pacing, 30 s deadline) — a recapture replayed into a still-full pipe would just re-overflow.
3. Repair fence → atomic captures+continue (shared `PaneCaptureReplay` construction, byte-identical to the attach's batch 2) → recapture replay via `writeReplay` → `endRepair` flushes the fenced bytes in order.

The repair replay resets the terminal (reset prelude + full history) mid-session — accepted and intentional: iTerm2 re-captures on `%pause` for the same reason, and a one-frame repaint beats permanently corrupt cells on a differential renderer.

**Deliberate policies:**

- **Wedged reader (30 s deadline exceeded):** leave the pane *paused* and the sink `repairing`. A continue would just re-overflow; tmux holds the content server-side, and a later attach replaces the sink and re-runs the full sequence, healing everything. (Wedged-*tmux* detection is separate, still-open Phase B scope.)
- **Repair failure while still owner** (capture `%error`, replay write failure): unpause + `abortRepair` — the stream resumes with a possible hole; a pane frozen behind a fence that never flushes is worse than a hole.
- **Overflow while fenced or already repairing:** keeps the M1 whole-chunk drop + telemetry. A repair launched during a fence would race the in-flight attach/repair sequence on the same pane's pause state. Bounded residual, rare (requires a blast pane overflowing 128 KB *during* replay assembly).

## 5. Defaults (updated from the base spec's table)

| Knob | Value | Notes |
|---|---|---|
| Per-pane local-queue cap | 128 KB | overflow enters the repair cycle (was: drop) |
| Resume gate | pipe writable | replaces the 32 KB drain hysteresis — the queue is cleared at overflow, so there is nothing to drain below a threshold |
| Drain pacing | 10 ms | async task; nonblocking writes under the fanout lock |
| Repair reader-wait | 50 ms poll / 30 s deadline | deadline → pane stays paused; later attach heals |
| Repair recapture depth | 50 000 | matches the attach's `history-limit` |
| `pause-after` safety nets | **not yet set** | remaining Phase B scope, below |

## 6. Remaining Phase B scope (not in this change)

- **`pause-after` safety nets + `%pause`-triggered repair** (base spec: 5 s visible / 250 ms non-visible, per window). Note: once `pause-after` is set, tmux can pause a pane *unprompted*, so `%pause` must trigger the repair cycle (the coordinator is built for it — `repairIfNeeded` is the entry point) or a pane freezes until the next attach. Do not set the option before wiring that trigger. Also revisit the fence-arm silence argument: under `pause-after`, a small `%extended-output` trickle can precede `%pause`; the probes above ran without the flag.
- **Non-visible pane sampling** for notification heuristics (periodic continue → sample → re-pause).
- **Wedged-tmux detection** (mute-but-alive `-CC`, the write-block thread pinning) — crash recovery scope (#364 known gaps).
- **Router epochs vs server death; per-server input consumers** (#364 known gaps).
- **Grouped-sessions fallback removal** — the "default-on" cleanup (Phase A addendum §5).

## References

- Base: [`2026-05-17-tmux-control-mode-design.md`](./2026-05-17-tmux-control-mode-design.md) · Phase A: [`2026-07-02-tmux-control-mode-phase-a-addendum.md`](./2026-07-02-tmux-control-mode-phase-a-addendum.md)
- Issues: #318 (tracking), #376 (dogfood corruption evidence), #364 (Phase A PR, known-gaps list)
- iTerm2 (local checkout `~/projects/iTerm2/sources/`): `PTYSession.m` `handleTmuxData:` backpressure rationale; `TmuxController.m` re-capture-on-`%pause`
