# tmux control mode integration (v2 design)

**Date:** 2026-05-17
**Status:** Design complete for the architecturally load-bearing questions. Architecture (A-lite + FD vending), scrollback (α replay + server-side `history-limit`), pipe-deadlock ordering (vend-and-ack handshake), RPC↔pipe ordering (dissolved by 1-pane-per-window), flow control (Policy B: EAGAIN-driven pause + aggressive auto-pause for non-visible panes), and crash recovery (tmux for liveness, SQLite for metadata; mode-specific reconnect flows) are all resolved. Pane lifecycle FSM, input path, notification-signal reconciliation, and `%layout-change` policy are still open but deferrable — none of them invalidate A-lite.
**Supersedes (in part):** [issue #1](https://github.com/cheapsteak/tbd/issues/1)
**Reviewed by:** [companion review file](./2026-05-17-tmux-control-mode-design-review.md) (codex) + three in-session subagent reviews (iTerm2 verifier, terminal-ecosystem lens, SwiftTerm API surveyor). Findings folded back in. Replay-mechanism design verified by direct experiment against tmux 3.6a.

## Problem

TBD's current terminal integration uses tmux **grouped sessions**: each visible pane spawns its own `tmux attach` PTY, and SwiftTerm reads bytes directly. This works but:

- One persistent tmux client per visible pane.
- No background-output signal for non-visible panes (notification badges rely entirely on Claude Code hooks).
- tmux's scrollback is hard-wrapped at write time, so scrolling up after a window resize shows "staircase" tearing.

A v1 attempt at **tmux control mode** (`tmux -CC attach`, single multiplexed connection per repo) was abandoned in March 2026. The five v1 blockers (size sync, `\n`-vs-`\r\n` from `capture-pane`, `send-keys` encoding, actor-thread starvation, SwiftUI view lifecycle) are documented in issue #1.

This doc resolves the **architectural** questions that v1 didn't have answers for. It does **not** spec out the full protocol layer — that's a follow-up.

## Goal

A control-mode design where:

1. The SwiftUI view lifecycle problem is structurally impossible (state doesn't live where SwiftUI can destroy it).
2. The "single connection per repo" win actually holds across TBD's two-process architecture.
3. Render-path bandwidth doesn't have to pay an extra IPC hop.
4. Scrollback reflows on resize.

## Out of scope (this doc)

- Per-pane `%pause`/`%continue` flow-control protocol details.
- Pane lifecycle state-machine messages.
- Crash recovery (daemon dies / tmux server dies / app dies, all combinations).
- IME, paste, and large-input handling for the keystroke path.
- Whether `%output` replaces or supplements the existing Claude Code Stop-hook for notifications.
- Multi-pane `split-window` support (still SwiftUI-side splits per current design).
- On-disk scrollback persistence.

These all need separate decisions. Each is referenced under "Open questions" below.

## Architecture: A-lite

The control connection is owned by the daemon. Bulk render bytes do **not** route through daemon user-space; they cross processes via vended pipe file descriptors.

### Process responsibilities

**Daemon (`tbdd`):**
- Owns the single `tmux -CC attach` connection per repo.
- Parses the control protocol (`%output`, `%begin`/`%end`, `%window-add`, `%window-close`, `%layout-change`, `%exit`, `%pause`, `%continue`).
- Authoritative for pane size, window lifecycle, and tmux session state.
- For each visible pane, creates a Unix pipe and writes the pane's decoded `%output` bytes into the write end.
- Vends the pipe **read end** to the app over the existing RPC Unix socket using `SCM_RIGHTS` (Darwin FD passing).
- Issues `send-keys -H` for keystrokes received from the app via RPC.
- Issues `resize-window` for size changes (app sends desired size via RPC; daemon arbitrates).

**App (`TBDApp`):**
- Reads pane bytes directly from the vended pipe FD into SwiftTerm.
- Holds no authoritative tmux state — pane registry, window IDs, sizes all come from daemon RPC.
- Sends keystrokes and resize requests to daemon via RPC.
- Receives `%window-add` / `%window-close` / `%layout-change` as RPC push notifications.

### Why this shape

Independently reviewed by two agents (industry-practitioner and research/literature lenses); both returned medium-high confidence. The pattern is "control-plane broker with capability-delegated data channels," well-established in:

- **macOS WindowServer / IOSurface** — vended via Mach ports (Darwin's FD-passing equivalent).
- **Wayland** — clients pass `wl_shm`/`dmabuf` FDs to compositor; pixel bytes never transit the socket.
- **systemd socket activation** — service manager passes listening FDs via `SCM_RIGHTS`.
- **Chromium / Mojo + GPU command buffer** — control plane carries IDs; bulk data via shared-memory regions registered through it.
- **OpenSSH privsep** (Provos 2003) — privileged broker, FD-passing for delegated authority.
- **Capsicum** (Watson 2010) — formalizes "FD = unforgeable capability."

The end-to-end argument supports parsing in the broker: control-protocol state (window layout, pane lifecycle, framing) is inherently global and entangled across all panes; terminal *emulation* is correctly an endpoint concern that stays in the renderer.

### What v1 blockers this resolves

| v1 blocker | Resolution |
|---|---|
| Size synchronization fights | Daemon is sole sizing authority; app sends *desired* sizes via RPC and daemon arbitrates with an outstanding-resize counter (cf. iTerm2's `numOutstandingWindowResizes_`). For per-window resize: `resize-window` with `window-size manual` always; `refresh-client -C @<id>:WxH` on tmux 3.4+ where preferred. Never `refresh-client -C` for per-pane resize. |
| `\n` vs `\r\n` from `capture-pane` | Use `capture-pane -peqJN` — `-J` joins wrapped lines (renderer can re-wrap to current width), `-N` preserves trailing spaces. v1 used `-p` alone. **Caveat:** the byte-stream output is still a *rendered snapshot* containing escape sequences; replaying it through the renderer is not safe in general — see Open Question §1 (replay mechanism). |
| `send-keys -l` can't handle control chars | Use `send-keys -H` (hex). Standard practice. |
| Actor read-loop starvation | Read loop runs on a real `Thread`, not a Swift actor. (Same fix v1 eventually landed; we keep it.) |
| SwiftUI view destruction loses `%output` handlers | Handlers and pane state live in the daemon, which has no SwiftUI. The app's view can be torn down freely — the pipe's read FD is held by an `@Observable` model (or a long-lived stream actor), not by the view. View destruction at worst means a brief pause until the new view picks up reading. |

### Wins over current grouped-sessions

- Single persistent tmux client per repo (was: one per visible pane).
- Background `%output` for non-visible panes — daemon already decodes them for notification heuristics, so the bytes are available even if no view exists.
- Programmatic window/layout lifecycle events (no more polling).
- Daemon CPU stays low: protocol framing demux + a single pipe write per `%output` chunk. Bulk bytes go pipe → app, not RPC → app — no re-encoding into RPC frames, no app-side RPC parse on the hot path.

### Trade-offs being accepted

- **"Single connection per repo" is a single point of failure for the repo.** If the daemon's control connection dies, every visible pane in that repo goes dark until reconnect. Grouped sessions degraded one pane at a time. See Open Question §5 (crash recovery) for the recovery story.
- **Head-of-line blocking on the `-CC` socket between tmux and daemon** is real and must be handled by per-pane `%pause`/`%continue` flow control. iTerm2 has lived with this for 13 years; tmux added `%pause` in 3.2 specifically to make it survivable. See Open Question §4.
- **The FD-vended-pipes-per-pane-for-control-mode shape is novel.** No prior implementation (iTerm2 is single-process; WezTerm encodes over its mux socket). Pattern itself (broker + FD-passing) is well-trodden (Wayland, systemd, OpenSSH privsep) — but the *combination* applied to `-CC` is new ground.
- **`SCM_RIGHTS` over a raw Unix socket** works fine for an unbundled developer tool. If TBD ever wants notarized/sandboxed distribution, XPC becomes the recommended path (handles FD passing + peer code-signing automatically). Not a redesign trigger; a one-line note for future-us.

## Scrollback

### What's decided

- **Live visible-pane scrollback lives in the renderer (SwiftTerm).** Reflow on resize is the whole point — that's what fixes the staircase bug.
- **tmux's `history-limit` is the authoritative scrollback source.** Set it server-side for TBD-managed sessions: proposed default **50,000 lines** (vs tmux's default 2,000). ~10–20 MB per pane in tmux server memory, fine.
- **No daemon-side ring buffer in MVP.** No disk persistence in MVP.
- **Hidden-pane bytes can be lost.** If a pane is non-visible long enough that its output wraps past `history-limit`, those bytes are unrecoverable on re-attach. iTerm2 ships with this limitation; we accept it for MVP.

### Replay mechanism — approach α

Verified by direct experiment against tmux 3.6a (see "Replay verification" appendix). On (re)attach the daemon performs a 4-command capture, then feeds bytes into the user-facing SwiftTerm via its existing `feedBuffer()` API. No SwiftTerm fork; no second emulator.

**Sequence per pane attach:**

1. Daemon issues `capture-pane -peqJN -S -<N> -t %<paneID>` for **main-screen** scrollback. Output is SGR escapes + literal text + newlines + spaces only — **no destructive escapes** (no `\e[2J`, no positioning, no mode changes; tmux rebuilds layout via whitespace).
2. Daemon issues `capture-pane -peqJN -a -t %<paneID>` for **alt-screen** contents (used when vim/less is active mid-attach).
3. Daemon issues `capture-pane -p -P -C -t %<paneID>` for **pending output** (bytes in flight between capture issuance and live `%output` resume).
4. Daemon issues `display-message -p -F …` (or `list-panes -F …`) for **pane state**: `#{cursor_x}`, `#{cursor_y}`, `#{alternate_on}`, `#{scroll_region_upper}`, `#{scroll_region_lower}`, plus mode flags (DECCKM, DECKPAM, DECAWM, mouse-mode, bracketed-paste, origin).
5. Daemon vends the pipe read FD to the app (FD must arrive *before* daemon writes anything substantial — see "Attach FD-vending order" below).
6. App opens the pipe FD on a long-lived stream actor. Once the app signals "reader is ready" via RPC, the daemon writes into the pipe, in this order:
   - A clean-slate prelude: `\ec` (full reset) and `\e[?1049l` (ensure normal buffer).
   - The main-screen capture from (1).
   - Synthesized mode-set escapes from (4): `\e[?<n>h` / `\e[?<n>l` for each mode flag.
   - Synthesized scroll-region escape if non-default: `\e[<top>;<bottom>r`.
   - If `#{alternate_on}` is 1: `\e[?1049h` then the alt-screen capture from (2).
   - The pending-output capture from (3).
   - Synthesized cursor position: `\e[<row>;<col>H`.
   - Transition to live `%output` for this pane.

The daemon does not parse capture-pane output structurally. SwiftTerm processes the byte stream as it would for any terminal — but the stream contains only escapes SwiftTerm already handles (SGR, mode-set/reset, cursor position, scroll region, alt-buffer toggle). No fork required.

### Attach FD-vending order (prevents pipe deadlock)

Darwin pipe buffers are small (16–64 KB). If the daemon writes anything to the pipe before the app has the read FD *and* a reader running, the write blocks. The attach protocol must therefore be:

1. Daemon creates the pipe.
2. Daemon vends the read FD to the app over the RPC socket via `SCM_RIGHTS`.
3. App opens the FD and starts its reader, then sends an `attach.ready{paneID}` RPC ack.
4. **Only after receiving the ack** does the daemon start writing the prelude/history/state bytes from (6) above.

This handshake is non-negotiable; without it the attach hangs for any pane whose replay exceeds the pipe buffer. Replay payloads under α are smaller than raw `capture-pane` output (no positioning escapes), so typical scrollback fits comfortably in the kernel buffer after the reader is running.

### What still needs verification before implementation

- **SwiftTerm mode-flag fidelity.** Does SwiftTerm correctly process `\e[?1h`/`\e[?1049h`/`\e[?7l` etc.? Almost certainly yes — these are standard CSI sequences — but worth a smoke test before locking in α. Failure mode would be "this mode doesn't take effect via byte feed"; mitigation would be either patching SwiftTerm for that specific mode, or accepting the mode resets to its default on attach (probably fine for most modes).

### Future work: per-pane ring in daemon

The A-lite architecture supports adding a daemon-side ring without refactor — `%output` bytes already flow through the daemon's parser; teeing into a per-pane buffer is a localized change.

**Add the ring when any of these holds:**

1. **Telemetry shows real truncation.** Daemon logs a counter every time a `capture-pane` response on attach hits the `history-limit` ceiling. Threshold: >5% of attaches truncated in steady-state usage, combined with user reports of missing output. Add this counter day one even though the ring isn't there — we want the data when the question comes up.
2. **A new feature needs more than tmux holds** — cross-pane search, "summarize last hour of this pane," background notification scanning.
3. **Daemon-restart UX becomes a real complaint.** A ring is the stepping stone to disk persistence; without one, daemon restart loses scrollback. (Currently rare and explicit, so probably tolerable.)

### `history-limit` migration

tmux's `history-limit` applies to **new** windows; existing windows keep the limit they had when created. So `set-option -g history-limit 50000` on an already-running tmux server doesn't retroactively expand existing pane scrollback.

This means we need to specify:

- Set the option **before any `new-window` call** in the daemon's session creation path.
- For tmux servers that already exist on TBD upgrade: existing windows keep their old limit (2K). Telemetry-truncation rates will be bimodal by pane age until those windows close. Acceptable for MVP; document it.

## Components

Roughly the same five components as issue #1, but with explicit process boundaries:

| Component | Process | Role |
|---|---|---|
| Protocol parser | daemon | Frames `%output`, `%extended-output` (tmux 3.2+ pause mode), `%begin/%end`, `%window-add`, `%window-close`, `%layout-change`, `%pause`, `%continue`, `%exit`. Real `Thread`, not actor. Handles octal-escape decoding of `%output` payload. |
| Pane registry | daemon | Authoritative pane↔FD↔window-id mapping. Backed by `TerminalStore` (SQLite) for durable fields (window ID, pane ID); in-memory for ephemeral fields (FDs, sizes, pause state). |
| Attach orchestrator | daemon | On pane (re)display: issue the 4-command capture sequence (main + alt-screen + pending output + pane state), establish the renderer's history + screen + mode state, transition to live `%output`. **Exact mechanism for how parsed history reaches SwiftTerm is open — see Open Question §1.** |
| Size arbiter | daemon | Tracks visible/desired sizes; emits `resize-window` (and `refresh-client -C @<id>:WxH` on tmux 3.4+) with an outstanding-resize counter to prevent echoed-resize fights. |
| Flow-control governor | daemon | Sets `pause-after=<age>` server-side; monitors per-pane buffer pressure (e.g. via `%extended-output` latency on 3.2+); issues `refresh-client -A` and handles `%pause`/`%continue`. See Open Question §4. |
| RPC streaming surface | daemon ↔ app | Existing JSON-RPC for control messages and lifecycle notifications; FDs vended via `SCM_RIGHTS` on the same Unix socket. Ordering rules between RPC and pipe are an open question (see Open Question §3). |
| SwiftTerm bridge | app | Reads from vended pipe FD on a long-lived stream actor (not view-owned). Feeds `Terminal.feedBuffer()` for live bytes. Handles structured "install history / set screen state" RPCs from the daemon. Captures keystrokes, sends to daemon via RPC. Sends desired size to daemon on geometry change. |

## Data flow examples

### Visible pane, steady-state output

```
tmux server ── %output[pane=42] ─► daemon parser
                                    ├── decode escapes
                                    └── write bytes → pipe[42] write end
                                                       │
                                                       ▼
                                          app reads pipe[42] read end
                                                       │
                                                       ▼
                                          SwiftTerm.feedBuffer()
```

No user-space byte routing in the daemon beyond decode-and-write.

### Pane first attached (approach α)

```
app: "open pane 42" ─RPC─► daemon
                            ├── issue 4-command capture sequence in parallel:
                            │     • capture-pane -peqJN -S -<N> -t %42  (main scrollback)
                            │     • capture-pane -peqJN -a -t %42        (alt screen)
                            │     • capture-pane -p -P -C -t %42         (pending output)
                            │     • display-message -F '#{...}' -t %42   (cursor + modes + alt_on)
                            ├── create pipe[42]
                            ├── vend pipe[42] read FD ─SCM_RIGHTS─► app
                            │
                            │   app: open FD, start reader actor
                            │   app: send attach.ready{42} ack ─RPC─► daemon
                            │
                            └── on ack: write into pipe[42] in order:
                                  1. \ec\e[?1049l                  (reset + normal buffer)
                                  2. main-scrollback capture bytes  (SGR-only, safe)
                                  3. synthesized mode escapes       (\e[?Nh / \e[?Nl)
                                  4. scroll-region escape if any    (\e[T;Br)
                                  5. if alt_on:
                                        \e[?1049h + alt-screen capture
                                  6. pending-output bytes
                                  7. \e[<row>;<col>H               (cursor)
                                  8. live %output[42] bytes (steady state)
```

App reader sees one byte stream, no special-casing needed beyond the `attach.ready` ack. All replay bytes are things SwiftTerm already knows how to process.

### Keystroke

```
SwiftTerm ── byte ─► app ─RPC─► daemon ─send-keys -H─► tmux ─► pty
```

Low-bandwidth, two-hop is fine. Latency is dominated by tmux's `send-keys` fork (one of the open questions).

### Resize

```
SwiftUI geometry ─► app ─RPC("desire size W×H for window @17")─► daemon
                                                                  │
                                                                  ├── update daemon's window size record
                                                                  ├── increment outstanding-resize counter for @17
                                                                  ├── issue `resize-window -t @17 -x W -y H`
                                                                  │     (or `refresh-client -C @17:WxH` on tmux 3.4+)
                                                                  └── on %layout-change reply: decrement counter,
                                                                       notify app of authoritative new size
```

App never directly drives tmux size. Daemon is the size arbiter. Outstanding-resize counter (modeled on iTerm2's `numOutstandingWindowResizes_`) prevents echoed-resize fights with concurrent user activity. **Note the target ID:** `resize-window` takes a window target (`@<windowID>`), not a pane target (`%<paneID>`). TBD's 1-pane-per-window model means there's always exactly one of each, but the syntax matters.

## Constraints this design imposes

- **Minimum tmux version: 3.2.** Needed for `%pause`/`%continue`, `%extended-output`, `window-size manual`, `pause-after`. Daemon startup checks the version; if below 3.2, fall back to the current grouped-sessions implementation (don't kill the user's workflow over a tmux version). Local dev tmux is currently 3.6a — the 3.2+ floor is comfortable, not theoretical.
- **macOS only.** `SCM_RIGHTS` for arbitrary FDs over Unix sockets works on Darwin; pipe defaults are smaller than Linux (~16–64 KB on darwin vs 64 KB+ on Linux), which makes per-pane flow control more important, not less.
- **Distribution shape: unbundled developer tool.** Raw Unix sockets with `SCM_RIGHTS` are fine here. If TBD ever pursues notarized/sandboxed distribution (App Store or Developer ID with hardened runtime restrictions on socket usage), XPC becomes the recommended IPC path — it handles FD passing and peer code-signing automatically. Switching transports is a localized change, but worth tracking as a future-distribution gate.

## Flow control — Policy B

tmux multiplexes every pane onto one FIFO into the daemon. Without per-pane `%pause`/`%continue`, a single slow pane stalls the parser, and every pane in the repo goes dark. This is iTerm2's #1 production complaint.

**Key insight that simplifies the design:** because our renderer is in a different process across a pipe, `write()` to a full pipe returns `EAGAIN` synchronously. That's not a prediction — it's authoritative "this pane's reader cannot keep up, right now." iTerm2's predictive system (`iTermTmuxBufferSizeMonitor`, linear regression on `%extended-output` latency) exists because they don't have this signal — they're single-process. We do; we don't need the prediction.

### Mechanics

**Server-side setup (on tmux server creation or first attach):**

- `set-option -s pause-after <N>` — global safety net. Use **5s for visible panes**, **250ms for non-visible panes** (set per-window via `set-window-option`). The visible value is generous (we expect to pause via EAGAIN before tmux fires this); the non-visible value is aggressive to keep flooding background panes from saturating the daemon parser.

**Per-pane state machine (visible panes only):**

```
Streaming → Backpressured → Paused → Draining → Streaming
   │            │              │         │
   │ EAGAIN     │ queue > 128KB │%pause   │ queue < 32KB
   │            │              │         │ (after %continue
   │            │              │         │  drains via %extended-output)
```

- **Streaming**: nonblocking `write()` to pipe succeeds; no local queue.
- **Backpressured**: write returned `EAGAIN`; daemon queues bytes locally in a per-pane buffer (target: 128 KB cap). Retries write on next event-loop tick.
- **Paused**: local queue hit 128 KB; daemon issues `refresh-client -A '%X:continue'` to flip tmux into pause mode for this pane. (Confusing naming: `refresh-client -A` sets the *requested* state; "continue" means "send me output," "pause" means "stop.") tmux replies with `%pause %X`. Daemon stops draining local queue (tmux is now buffering server-side).
- **Draining**: app reader caught up; local queue is below 32 KB hysteresis threshold. Daemon issues `refresh-client -A '%X:continue'`; tmux replies with `%continue %X` and starts emitting accumulated output as `%extended-output`. Daemon writes those bytes through the local queue → pipe.
- Back to **Streaming** once `%extended-output` stream ends (tmux switches back to regular `%output`).

**Non-visible panes:** no pipe → no EAGAIN signal → can't use the same trigger. Instead, server-side `pause-after=250ms` causes tmux to auto-pause them after any sustained output burst. To keep notification heuristics fed, daemon periodically (every few seconds) issues `refresh-client -A '%X:continue'` to sample state, lets `%extended-output` drain a small window, then re-pauses. No local queue for non-visible panes — daemon decodes the bytes directly into its notification pipeline.

**Attach interactions with pause state:**

When attaching to a paused pane (e.g. tab-switching back to a non-visible pane that was auto-paused), the attach orchestrator must:

1. Issue `refresh-client -A '%X:continue'`.
2. Wait for `%continue %X` notification.
3. Drain any pending `%extended-output` (or use a short timeout to bound the wait).
4. Issue the 4-command capture sequence.
5. Run the α replay.
6. Transition to live `%output`.

If steps 1–3 are skipped, the capture races with the drain and bytes between "capture taken" and "live `%output` resumes" are lost. This is iTerm2's `unpausePanes:` ordering.

### Why not predictive

`iTermTmuxBufferSizeMonitor`'s linear regression on `%extended-output` latency is iTerm2's workaround for not having `EAGAIN`. Adopting it would mean inheriting iTerm2's known failure modes (false positives on bursty workloads, small-sample regression noise) for marginal benefit (50–100 ms earlier pause vs. our EAGAIN-driven one, in a context where the local-queue cost of the brief lag is bounded at 128 KB). Skipping it for MVP, adding later if telemetry shows real value — the predictive layer is a localized addition on top of Policy B's state machine, not a refactor.

### Defaults summary

| Knob | Value | Notes |
|---|---|---|
| `pause-after` for visible panes | 5 s | safety net; expect EAGAIN to fire first |
| `pause-after` for non-visible panes | 250 ms | aggressive — keeps background floods from saturating the parser |
| Per-pane local-queue cap | 128 KB | trigger explicit `refresh-client -A` pause when reached |
| Resume hysteresis | drain below 32 KB | ¼ of cap; prevents pause/continue thrash |
| Non-visible sampling interval | ~5 s | brief unpause window to sample state for notification heuristics |

All five values are starting points; tune via telemetry once we have it.

## Crash recovery

Three failure modes; each shaped by what survives.

### Source-of-truth rule (applies to all modes)

- **tmux is authoritative for what exists right now.** Liveness of windows/panes comes from `list-windows -F` / `list-panes -F`.
- **SQLite (`TerminalStore`) is authoritative for TBD-managed metadata.** Display names, repo↔window ownership, tab order, archive state.
- **Reconciliation:** for each pane in SQLite, check if tmux still has it. SQLite-only → mark `status='dead'` (process exited while daemon was down). tmux-only → ignore (manually-created window, not TBD's concern).

### Mode A — Daemon dies (tmux and app survive)

The common case. We change daemon code constantly.

**Survives:** tmux server + all pane processes, pane scrollback (in tmux server memory), app process + pipe read FDs (but EOF on those), SQLite.
**Dies:** daemon's in-memory pane registry, pipe FDs (write ends), pause-state machines, local backpressure queues.

**Recovery flow:**

1. Daemon discovers the still-running tmux server via its known **server name** (`tmux -L <name>`), where `<name>` is a deterministic djb2 hash of the repo path (`TmuxManager.serverName(forRepoPath:)`, stable across DB recreations and process restarts). Server name is also recorded per-worktree in SQLite (`worktree.tmuxServer`).
2. Daemon enumerates tmux state (`list-windows -F` / `list-panes -F`).
3. Daemon reconciles against `TerminalStore`; emits death notifications for any gone panes.
4. Daemon starts a fresh `tmux -CC attach` control connection.
5. App reconnects via existing RPC reconnect logic.
6. App re-requests attach for each visible pane.
7. Each attach runs the standard α flow (4-command capture → FD vend → reader-ready ack → replay → live `%output`).

User experience: blank panes for ~1 second, then everything pops back with full history. Scrollback survives because it's in the tmux server.

### Mode B — tmux dies (daemon and app survive)

Rare. tmux server crashes are unusual.

**Survives:** daemon (with stale pane registry), app, SQLite.
**Dies:** every pane process in the tmux server's process group (catastrophic for the repo), all scrollback.

**Recovery flow:**

1. Daemon notices `%exit` notification or socket EOF on the control connection.
2. Daemon marks every pane in the affected repo as `status='dead'` in SQLite.
3. Daemon pushes a UI notification to the app: "tmux server crashed for repo X. Panes lost. [Recreate from worktree?]"
4. User decides whether to recreate; if yes, daemon spawns a new tmux server and creates fresh windows for each worktree.
5. The "recreate" path reuses the existing initial-window-creation code — no special crash-recovery path needed.

**Explicit prompt, not silent auto-recreate.** Losing panes silently would be worse UX than surfacing the failure.

### Mode C — App dies (daemon and tmux survive)

The simplest case.

**Survives:** everything except the app.
**Dies:** app process and its pipe read ends.

**Recovery flow:**

1. Daemon detects RPC socket disconnect. Pipe writes start returning `EPIPE`/`SIGPIPE`.
2. Daemon closes all pipe write ends for the (now-orphaned) attachments.
3. Daemon transitions all panes to "no current viewer" — equivalent to "non-visible" for flow control purposes (aggressive auto-pause via `pause-after=250ms`).
4. App reconnects via existing RPC reconnect logic.
5. App re-requests visible panes; daemon runs standard α attach for each.

The visible↔non-visible transition drops cleanly out of the flow-control state machine. No special path required.

### Other invariants

- **App-restart while daemon mid-attach** (e.g. app dies during the 4-command capture sequence): daemon cancels the in-flight attach, tears down any partial pipe, waits for the next request. Never partially completes an attach.
- **"Pane in SQLite but not in tmux"** is not an error — happens whenever a pane's process exited while daemon was down. Surface as `status='dead'` with an "exited" indicator in the UI.

## Open questions (deferred to a follow-up round)

These need design work before implementation but don't change A-lite's architecture:

### §1 — Pane lifecycle state machine

`Requested → FDVended → ReaderReady → Streaming → Backpressured → Paused → Draining → Closed`. Define messages, legal transitions, error-path behavior. Will largely fall out of the flow-control state machine plus the attach handshake; this section will mostly be writing it down formally.

### §2 — Input path edge cases

IME pre-edit composition, paste of multi-KB buffers, dead-keys, latency budget per keystroke. Today's native PTY handles these for free; `send-keys -H` is byte-correct but the rest is unspecified. Likely needs a "structured keystroke" RPC for IME states, plus a paste path that batches into a single `send-keys -H` to avoid argv blowup.

### §3 — Notification signal reconciliation

Does `%output` for non-visible panes *replace* the existing Stop-hook pipeline, *supplement* it, or stay irrelevant? Stop-hook carries `last_assistant_message` and is a structured `response_complete` event; `%output` is raw bytes that need re-derivation via something like `ClaudeStateDetector`. The hook is strictly richer; `%output` is just earlier/more-frequent. Probably "supplement, not replace" — but the specific division of responsibilities is open.

### §4 — `%layout-change` policy for SwiftUI-split model

TBD does splits in SwiftUI; tmux always sees one pane per window. So `%layout-change` from tmux *should* be rare. But if a user runs `tmux split-window` from inside an attached session (or some tooling does), what happens? Three options: (a) treat additional panes as second-class — show only the first, log a warning; (b) collapse SwiftUI to a single pane and respect tmux's layout; (c) refuse to attach if a tmux-side split exists. (a) is least surprising; (b) is most general; (c) is most defensive.

## Replay verification (appendix)

Date: 2026-05-17. tmux version: 3.6a.

Test: start a tmux pane running a `bash -c` that emits `\e[31m`, `\e[1;33m`, `\e[2J`, `\e[H`, `\e[5;10H`, `\e[?7l`, a UTF-8 CJK char (日), and a few cursor moves; capture with `-peqJN -S -` and hex-dump.

Result: captured output contained only SGR escapes (`\e[31m`, `\e[1m`, `\e[33m`, `\e[0m`), literal printable characters, spaces (for horizontal positioning), and newlines (for vertical positioning). **No** `\e[2J`, **no** `\e[H` / `\e[5;10H`, **no** `\e[?7l`. tmux rebuilt the visual layout from the grid using only whitespace + SGR.

Conclusion: re-feeding `capture-pane -peqJN` output through SwiftTerm's `feedBuffer()` is **safe** — no destructive escapes to re-execute. Cursor position and mode flags must be queried separately (`display-message -p -F …`) and synthesized into byte form by the daemon, but those are well-defined CSI sequences SwiftTerm already handles.

## References

### Internal
- [`docs/tmux-integration.md`](../tmux-integration.md) — current grouped-sessions architecture
- [issue #1](https://github.com/cheapsteak/tbd/issues/1) — v1 retrospective and original "If we revisit" sketch (this doc supersedes the architecture portion)

### tmux
- [tmux Control Mode wiki](https://github.com/tmux/tmux/wiki/Control-Mode)
- [tmux issue #2217 — pause/continue for control mode](https://github.com/tmux/tmux/issues/2217)
- [`pipe(7)`](https://man7.org/linux/man-pages/man7/pipe.7.html) — pipe buffer behavior
- [`unix(7)` — SCM_RIGHTS](https://man7.org/linux/man-pages/man7/unix.7.html)

### Reference implementations
- iTerm2 `sources/TmuxWindowOpener.{m,h}`, `TmuxHistoryParser.{m,h}`, `TmuxController.{m,h}`, `VT100Screen*`, `LineBuffer.{m,h}` — local checkout at `/Users/chang/projects/iTerm2`
- [Wayland: shared memory buffers](https://wayland-book.com/surfaces/shared-memory.html), [linux-dmabuf](https://wayland-book.com/surfaces/dmabuf.html)
- [systemd `sd_listen_fds`](https://www.freedesktop.org/software/systemd/man/latest/sd_listen_fds.html)
- [Chromium GPU command buffer](https://chromium.googlesource.com/chromium/src/+/12a7862a280dbb36a57c5e6f38c4a21f3c77ea6c/docs/security/research/graphics/gpu_command_buffer.md)

### Background / research
- Saltzer, Reed & Clark, "End-to-End Arguments in System Design," ACM TOCS 1984 — [PDF](https://web.mit.edu/saltzer/www/publications/endtoend/endtoend.pdf)
- Druschel & Peterson, "Fbufs: A High-Bandwidth Cross-Domain Transfer Facility," SOSP 1993 — [ACM](https://dl.acm.org/doi/10.1145/173668.168634)
- Provos, "Preventing Privilege Escalation," USENIX Security 2003 — [PDF](https://www.usenix.org/legacy/events/sec03/tech/full_papers/provos_et_al/provos_et_al.pdf)
- Watson, Anderson, Laurie & Kennaway, "Capsicum: Practical Capabilities for UNIX," USENIX Security 2010 — [PDF](https://www.usenix.org/legacy/event/sec10/tech/full_papers/Watson.pdf)
- Cloudflare, "Know your SCM_RIGHTS" — [post](https://blog.cloudflare.com/know-your-scm_rights/)
