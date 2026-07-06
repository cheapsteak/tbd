# tmux control mode — Phase A addendum (input + resize + replay)

**Date:** 2026-07-02
**Status:** Design addendum. Extends [`2026-05-17-tmux-control-mode-design.md`](./2026-05-17-tmux-control-mode-design.md) with the transport and ordering decisions for Phase A (the spec's phases 3+4+5, shipped as one PR) plus two learnings from the Phase 1–2 implementation (#317). Validated against iTerm2's production `-CC` client (local checkout, `sources/tmux/` — `TmuxGateway.m`, `TmuxController.m`, `TmuxWindowOpener.m`, `PTYSession.m`). Tracking: #318.
**Phase grouping:** Phase A = input + resize + replay (the usability line: gate-on daily driving is viable). Phase B = flow control + crash recovery (the default-on line).

## 1. Command transport: everything over the `-CC` stream

All tmux commands issued on behalf of control-mode panes — `send-keys`, `resize-window`, the replay's capture sequence, pause/continue — go down the control connection's stdin, **never** through a `TmuxManager` subprocess. Two reasons:

- **Latency.** A fork+exec per keystroke costs 5–15 ms against a 50 ms perceptibility budget (spec §Input, telemetry thresholds).
- **Ordering.** Commands written to the stream are processed in order *with respect to `%output`*. This is what makes the replay sequence in §3 airtight — a property no subprocess can provide.

**Correlation layer** (`TmuxControlCommandClient`, wrapping Phase 1's `sendCommand` writer): a FIFO queue of pending commands with completion handlers. `%begin` marks the queue head in-flight; `%end`/`%error` completes it (success/failure) and delivers the response lines. The `%begin` sequence number is validated, not matched — correlation is order-based. Multi-command **command lists** are batched into one stream write so a group of commands is atomic in the FIFO. Per-command flags: *tolerate-errors* (failure completes the command without killing the connection) and *wants-data* (response lines are retained for the caller). A protocol violation (`%begin` with an empty queue, `%end` with no open block) tears the connection down — the crash-recovery path (Phase B, and today's stream-ended handling) owns rebuilding it; limping along a desynced FIFO delivers wrong responses to wrong callers.

This is iTerm2's `commandQueue_`/`currentCommand_` design (`TmuxGateway.m`), carried for 13 years.

*Rework implied:* the parser's `commandSucceeded`/`commandFailed` events currently flow to the supervisor's logging loop; they become the correlator's completion feed. `TmuxManager` subprocess calls remain for everything outside control mode.

## 2. Input path

### App → daemon transport: the sidecar becomes a bidirectional framed channel

The FD-vending sidecar (persistent, connected at app startup) is promoted to the control-mode **data channel**, with length-prefixed framing in both directions: daemon→app FD vends (unchanged semantics, now framed), app→daemon keystroke and paste frames tagged `(worktreeID, paneID)`. Rationale:

- The existing JSON-RPC socket uses one-shot connections per call — unusable per keystroke.
- Framing was already a hardening item (a split header today desyncs the sidecar); paying for it once buys both robustness and input.
- No third socket to manage, and Phase B gets a free liveness signal (sidecar EOF = app died → close pane write ends; most of crash-recovery Mode C).

Resize requests do **not** ride this channel — they're low-rate and go through the ordinary RPC socket (§4).

### Daemon → tmux encoding: `send-keys -H` for everything, chunked

Every input byte is sent as `send-keys -H -t %<pane> <hex bytes…>` via the correlation layer. The spec chose `-H` for control chars; iTerm2's implementation sharpens the rationale into a requirement:

- **tmux ≥ 3.5 regression** (iTerm2 issue 12845): without `-H`, hex-token control bytes (`0xNN`) are silently rewritten to literal text `"0xNN"` once a pane enables modifyOtherKeys — which Claude Code's fullscreen renderer does. `-H` (tmux ≥ 3.0a; our floor is 3.2) round-trips every byte 0x00–0xFF regardless of pane mode.
- iTerm2's three-way encoding split (literal / hex-token / `-H`) exists only to support tmux ≤ 3.0, which we don't carry. `-H`-everything is both simpler and correct at our floor.
- **Command length cap:** tmux crashes on very long commands (historically >1024 bytes). Chunk input batches so each `send-keys -H` stays under ~1000 command characters (≈330 input bytes at 3 chars/byte). Pastes never approach this: while attached, **every** paste — any size — is intercepted at the SwiftTerm **view level** — BEFORE SwiftTerm brackets the content — and shipped as a dedicated `.paste` frame on the same sidecar (`SidecarFrameType.paste`, sharing the `.input` payload sub-format). The daemon runs it through the correlator as `load-buffer` + `paste-buffer -d -p`, so it is **ordered with keystrokes end-to-end**: a keystroke enqueued after a paste is FIFO-behind the paste-buffer command through the one `-CC` stream. `-p` hands bracketed-paste wrapping to **tmux**, the single authority on the pane's mode — because the app intercepts before SwiftTerm adds markers, the payload arrives bare and tmux wraps it with `ESC[200~`/`ESC[201~` iff the pane enabled bracketed paste (verified live: a DECSET-2004 pane gets wrapped, a bare pane does not). tmux must be the **sole** bracketing authority: stock tmux (our 3.2 floor) exposes no bracketed-paste format variable, so §3's replay cannot restore SwiftTerm's DECSET-2004 tracking after a tab-switch re-attach — SwiftTerm's own bracketing decision on the keystroke path can be stale-wrong, which rules out routing any paste through it (this supersedes the earlier ≤4 KB keystroke-path rider). The paste has a documented cap (`SidecarFrameCodec.maxPasteBytes`, ≈4 MiB — under the scanner's 4 MiB hard cap with header/framing headroom); a paste larger than the cap is **refused**: a user-visible error log and the paste is dropped. It is **not** split across frames (each `.paste` frame is its own `paste-buffer` call, which tmux would bracket as a separate paste; a reassembly protocol is new desync surface for a pathological >4 MiB case) and it does **not** fall back to the keystroke path (the same stale-bracketing hazard).

No local echo: SwiftTerm renders only what returns via `%output`. The spec's p99 keystroke latency telemetry (soft 50 ms / hard 200 ms) ships with the first input commit; keystroke coalescing remains deferred until telemetry says otherwise.

*App side:* `TerminalPanelView`'s coordinator branches its send path exactly where rendering branches — control-mode attach present → keystroke frame on the sidecar; otherwise → local PTY as today.

### Input-failure UX: passive indicator (user ruling)

The plumbing stays tolerant — a pane dying mid-keystroke is a race, not an error, so `send-keys` failures complete silently and never tear anything down. But silence must not reach the user: the daemon tracks per-pane input delivery health **edge-triggered** — first failure after health pushes one "input failing" event, first success after failure pushes one "recovered" event, no per-keystroke spam — and pushes transitions to the app, which shows an unobtrusive "input not being delivered" indicator on the affected pane, cleared on recovery or detach. (Semantics-level contract; wire and view details are implementation's.)

Alternatives held in reserve:

- **Silent status quo.** Rejected: typing into a dead pane with zero feedback is the worst failure mode a terminal can have.
- **Auto-fallback to the grouped-session viewer after N consecutive failures.** Rejected *for now*: seamless for the user, but it masks exactly the control-mode failures Phase A dogfooding exists to surface (§5 keeps the grouped session alive precisely so fallback stays cheap). Becomes attractive post-Phase-B, when control mode is default-on and hiding its faults is a feature rather than a bug.

## 3. Replay ordering: pause-gated, no interleave buffer

The spec's attach sequence (§Scrollback, §Flow control "attach interactions with pause state") is implemented with **pause as the serialization mechanism**, following iTerm2's `TmuxWindowOpener` shape:

1. Pane is paused — either auto-paused (Phase B's `pause-after`) or explicitly paused as the attach's first command.
2. The 4-command capture goes down the stream as **one command list**: main-screen history (`capture-pane -peqJN -S -<N>`), alt screen (`-a`), pane state (`list-panes -F` with cursor/mode/`alternate_on` format), pending output (`capture-pane -p -P -C`).
3. The orchestrator assembles and writes the replay into the pane's pipe (spec's byte order: reset prelude → history → mode escapes → scroll region → alt screen → pending → cursor), then opens the write gate.
4. **Unpause is the last command** (`refresh-client -A '%<pane>:continue'`, tolerate-errors — it must no-op when the pane wasn't paused or was already unpaused). **Pause discards — it does not queue.** Live-verified on tmux 3.6a (M4 integration matrix): `continue` resumes delivery from the pane's *current* position; output the pane emitted while paused is never delivered to this client (even under `pause-after`, tmux flushes at most a row or two of `%extended-output` before jumping). This is exactly why iTerm2 re-captures the pane on a `%pause` notification instead of trusting a drain.

Consequences:

- **No interleave buffer — and an accepted boundary gap (user ruling, Phase A).** Pause is the *serialization* mechanism, not a *losslessness* mechanism. The serialization property holds: live output physically cannot race or corrupt the replay, because the pane delivers nothing between pause and the unpause sent only after the replay bytes are in the pipe. But output the pane emits between the capture and the unpause (~0.2–0.5 s under load) is lost from *this attach's view*. The accepted contract, pinned by the live matrix: the gap is **boundary-only** (attach time, never steady-state), **forward-only** (never duplication, reordering, or corruption), and **self-healing** — the lost output still lands in tmux history, so the next attach's snapshot includes it, and fullscreen (alt-screen) apps repaint themselves current on their next frame. Phase 2's "not ready → drop" rule stays; the `Replaying` FSM state reduces to bookkeeping.
- **Generations still guard identity.** The fanout's per-attach generation (added in #317 for the ready-timeout race) tags the replay too — a superseded attach's in-flight replay must not write into its successor's pipe.
- **Fullscreen Claude is the primary replay path, not the exotic one.** TBD spawns Claude with `CLAUDE_CODE_NO_FLICKER=1` (alt-screen renderer) by default, so `alternate_on=1` + alt-screen capture is the common case. The Phase A test plan must include attaching to a fullscreen Claude session mid-stream. (Alt screens have no tmux history; for these panes replay is a cheap screen snapshot + mode flags, and the reflow-on-resize win applies to primary-screen content.)
- Pre-implementation smoke test (spec's open verification item): confirm SwiftTerm applies the synthesized mode escapes (`\e[?1h`, `\e[?1049h`, `\e[?7l`, DECKPAM, bracketed paste, mouse modes) via `feed`.

**What we deliberately do differently from iTerm2:** they parse capture output into structured screen lines (`TmuxHistoryParser` → their own LineBuffer). We feed bytes through SwiftTerm per the base spec's verified α approach — no structural parsing, no emulator fork.

### Alternatives held in reserve (revisit in Phase B or if dogfooding hurts)

Two designs that close the boundary gap, rejected for Phase A but documented for pickup:

- **Scoped interleave buffer.** The fanout buffers live output events for the pane between capture-fence completion and gate-open, flushing them into the pipe after the replay bytes. This is the *correct* fix — no gap at all — but the cost is a state machine in the exact spot where attach-generation races live (a review-caught critical bug class in #317's lineage), plus generation-scoped buffer invalidation so a superseded attach's buffered output can't leak into its successor. Deferred because Phase B's flow-control work rebuilds this area anyway; building the buffer twice is worse than living with a sub-second boundary gap once.
- **iTerm2's shape: re-capture on `%pause`.** Don't pause explicitly at attach; instead treat the `%pause` notification as "my view is stale" and re-run the capture sequence. Converges to correct without a buffer, at the cost of a second full capture round-trip and re-entrant replay orchestration. Becomes more attractive in Phase B, where `pause-after` is on and `%pause` handling must exist regardless.

## 4. Resize: daemon arbitration with echo suppression

Per the base spec: daemon is the sole size authority; `window-size manual` is set **per window** at control-mode attach (the same server hosts grouped-session viewers for other windows — never set it server-wide); resizes are issued as `resize-window -t @<id> -x W -y H` (`refresh-client -C @<id>:WxH` on ≥ 3.4) through the correlation layer.

Echo suppression, concretized from iTerm2's `numOutstandingWindowResizes_`: each resize command list chains a `list-windows`; the counter increments at send and decrements when the `list-windows` response completes; **layout notifications are ignored entirely while the counter is > 0** (stale echoes are discarded, not reconciled). App sends desired `(cols, rows)` per window over the RPC socket, debounced on geometry change; `AttachRequestParams.windowID` (already on the wire since #317) becomes load-bearing.

Open question deferred to implementation: whether detach restores `window-size latest` for the window (so a grouped viewer regains sizing control after control-mode detach) — decide when the fallback interplay (§5) is testable.

## 5. Grouped-sessions fallback: keep through Phase A, remove in Phase B

Pane creation continues to build the grouped view session, and any attach failure falls back to it invisibly (as in #317). The dual bookkeeping is redundant once control mode is trustworthy, but during Phase A dogfooding it converts every control-mode bug into a cosmetic blip instead of a dead terminal. Removing it — and skipping grouped-session creation for control-mode panes — is a Phase B / default-on cleanup.

## 6. Sequencing within Phase A

1. **Command correlation layer** (§1) — unblocks everything below; testable against live tmux immediately.
2. **Input** (§2) — sidecar framing v2, keystroke frames, `-H` chunked sends, latency telemetry. First dogfoodable milestone.
3. **Resize** (§4) — independent of input; second dogfoodable milestone.
4. **Replay** (§3) — last, it's the delicate one; gated on the SwiftTerm mode-escape smoke test and the fullscreen mid-stream attach test.
5. **Settings toggle** (optional tail, per #318): daemon-side persisted flag, `gate = env || flag`, `daemon.capabilities` carries the tmux version for the "requires ≥ 3.2" UI state.

## References

- Base design: [`2026-05-17-tmux-control-mode-design.md`](./2026-05-17-tmux-control-mode-design.md)
- Tracking issue: #318 (includes the full iTerm2 validation notes) · Phases 1–2: #317
- iTerm2 (local checkout `~/projects/iTerm2/sources/`): `tmux/TmuxGateway.m` (FIFO correlation, send-keys encodings, length caps), `tmux/TmuxWindowOpener.m` (capture command list + unpause-last), `tmux/TmuxController.m` (`numOutstandingWindowResizes_`), `PTYSession/PTYSession.m` (`handleTmuxData:` backpressure-pipe rationale)
