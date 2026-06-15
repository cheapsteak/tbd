# Detecting & reaping orphaned / wedged agent processes — design brainstorm

Status: **exploration / brainstorm** (no implementation). Written 2026-06-15.

This is a design exploration, not a plan. It characterizes the lifecycle, locates the
gap with code + live evidence, enumerates detection signals and reaping trigger points
with tradeoffs, flags safety risks, and ranks candidate directions.

> Repo names in the live evidence are scrubbed to placeholders (`repo-A`, `repo-B`) per
> project convention. The findings are independent of which repo they came from.

---

## 1. The problem, restated precisely

Over weeks, the per-repo tmux servers TBD owns accumulate agent (`claude`/`codex`)
processes that have lost their reason to exist. A small subset of these wedge **upstream**
in the Claude CLI — the main thread busy-loops in `kevent64` on a dead PTY file
descriptor (sampled), pinning a core at ~100% for days. Observed cases burned 20–39
CPU-hours each over 13–20 days. TBD cannot fix the upstream busy-loop. The question is
purely **detection + reaping**, because TBD *owns the process lifecycle*: it spawned these,
and it owns the teardown paths that are supposed to clean them up.

Crucially, the live snapshot taken for this doc shows the failure is **episodic**: there is
no actively-wedged 100%-CPU orphan right now (the historical ones were already reaped by
hand). What is measurable today is the *substrate that makes the failure possible and
invisible*. The design must therefore target the mechanism, not a process that happens to
be hot at sweep time.

---

## 2. Lifecycle map (code, with citations)

How TBD spawns and tracks agents:

- **Spawn**: `ClaudeSpawnCommandBuilder` builds a command string; `TmuxManager.createWindow`
  runs `tmux -L <server> new-window … <shell> -ic <cmd>`
  (`Sources/TBDDaemon/Tmux/TmuxManager.swift:128`). The shell exec's into `claude`, so the
  pane process *is* the agent (confirmed live: agent `ppid` == the tmux server pid, not a
  shell).
- **What TBD records**: only tmux identifiers — `Terminal.tmuxWindowID` (`@3`),
  `tmuxPaneID` (`%5`), `Worktree.tmuxServer` (`tbd-<hash>`), and the resumable
  `claudeSessionID` (`Sources/TBDShared/Models.swift`). **No OS PID is ever persisted.**
  `TmuxManager.panePID()` exists (`TmuxManager.swift:349`) but is used only transiently for
  session-id detection (`ClaudeStateDetector.swift:61`), never stored, never used for
  lifecycle.
- **Server naming**: deterministic `tbd-<djb2(repoPath)>` (`TmuxManager.serverName`,
  `TmuxManager.swift:50`) — stable across daemon restarts. One server per repo.
- **View sessions vs. agent windows are decoupled.** The app links agent windows into
  per-panel `tbd-view-*` sessions for display (`TmuxBridge.swift`); hiding a panel kills
  *only* the view session (`TmuxBridge.cleanupSession`), never the agent window. A keep-alive
  LRU (limit 8, `AppState.swift:385`) governs view mounting. So UI teardown and agent-process
  teardown are independent — this decoupling is central to the gap.
- **`remain-on-exit on` is set per-window** by the app when it links a window for display
  (`TmuxBridge.swift:70`, intent documented at `TerminalPanelView.swift:502`). Consequence:
  when an agent exits or is killed, its pane does **not** vanish — it becomes a *dead
  gravestone pane* ("[Process exited]") that holds the window open until something prunes it.

Teardown paths that *do* clean up:

- **Archive** (`WorktreeLifecycle+Archive.swift:117`): saves resumable session IDs, then
  `tmux kill-window` for each terminal, then deletes terminal/tab DB rows. It does **not**
  signal the OS process — it relies on `kill-window` to take the pane down.
- **Reconcile** (`WorktreeLifecycle+Reconcile.swift`): worktree gone from git → kill its
  windows + archive; *all* worktrees for a repo gone → `tmux kill-server`; orphaned windows
  (in DB, not in tmux) killed individually. On reboot (server absent) it *recreates* windows
  from stored session IDs.
- **Repo remove** (`RPCRouter+RepoHandlers.swift:76`): cascade-archives worktrees.

What is **absent** (verified by search across `Sources/`):

- No PID tracking, no `kill()`/SIGTERM/SIGKILL targeting agents, no process groups.
- No CPU/memory/liveness/health probe of agent processes. The only "health" checks are
  `RepoHealthValidator` (paths exist on disk) and `ModelProfileHealthProbe` (TCP to LLM
  endpoints) — neither touches agent processes.
- No reaper / stale-sweep / orphan-process cleanup. The daemon reasons about *tmux window
  state*, never about OS processes.

---

## 3. The gap, with the failure chain

`tmux kill-window` is TBD's only reaping mechanism, and it is **process-agnostic**: it
closes the pane's PTY master and sends `SIGHUP` to the pane process, then forgets the
window. For a healthy agent this is sufficient — it exits. For a **wedged** agent it is not:

```
kill-window  →  PTY master closed  +  SIGHUP sent
                     │
        agent is wedged / slow to handle the signal
                     │
        tmux removes the window from its tables and moves on
                     │
        process survives, now has NO pane referencing it,
        still a child of the (alive) server  → ppid == server, but windowless
                     │
        its event loop now spins on the closed-PTY fd  → ~100% CPU, for days
```

This produces exactly the historically-observed shape: "spawned by a TBD tmux server but
not attached to any live window." The daemon has no way to notice — it only knew the window
id, which is now gone, and it never knew the pid. The process is invisible to TBD and to the
user (no pane → the UI cannot even show it), and it burns a core unattended.

A second, milder failure exists: an agent wedges **while still in a live window** (no
teardown happened — the user just stopped using that worktree). It is technically reachable,
but nothing samples CPU, so a 100%-CPU spin sits undetected among dozens of idle siblings.

---

## 4. Live evidence (snapshot 2026-06-15)

- **Window accumulation is real and unbounded.** One repo's server (`repo-A`) has **105
  live agent windows** in its `main` session; another (`repo-B`) has 22. The oldest windows
  date to 25 days ago. Nothing prunes them except worktree-keyed archive/reconcile; an
  agent window outlives the user's interest in it indefinitely. This is the haystack the
  rare wedged needle hides in.
- **Gravestones confirm the `remain-on-exit` behavior.** The two historically-wedged PIDs
  (`91514`, `54881`) are **no longer running** (reaped by hand during the diagnosis) yet
  survive as `pane_dead=1` panes in `repo-A`'s server, still labeled with their old
  pane_pids. So even after reaping, dead windows linger and must be pruned separately.
- **No active wedge in this snapshot.** The hottest agents are an old (5.7-day) session at
  ~7–14% instantaneous CPU but only ~10 min *total* CPU time — i.e. mostly idle, currently
  mildly active, **not** a smoking-gun spin. This confirms the wedge is rare/episodic and
  that a naive "kill the hottest process" sweep would be wrong.
- **Structural orphan test came back clean.** Enumerating, per TBD-owned server, the child
  pids (`ppid == server`) minus the live pane_pids found **zero** windowless orphans right
  now — consistent with the historical ones having been reaped. The test itself is the
  important artifact (see §5.1): it is cheap and deterministic.
- **Secondary: view-session leakage.** `repo-A` has multiple stale *grouped* `tbd-view-*`
  sessions each mirroring all 105 windows (old grouped model), alongside newer single-window
  view sessions. Not the core concern, but it inflates apparent pane counts and suggests the
  keep-alive LRU teardown doesn't always fire. Worth a separate look; flagged, not solved
  here.

---

## 5. Three distinct phenomena (do not conflate them)

| Class | What it is | Danger | Visibility | Frequency |
|---|---|---|---|---|
| **A. Windowless orphan** | process survived `kill-window`, no pane, child of server (or reparented to launchd after server death) | **High** — can spin at 100% for days, fully unattended | Invisible to UI & daemon | Rare but expensive |
| **B. Windowed wedge** | agent pinned at high CPU while still in a live, idle window | Medium — burns a core but is reachable | Visible if you look | Rare |
| **C. Accumulation** | 100+ idle-but-alive windows + dead gravestone panes per server | Low — clutter, mild memory; the *substrate* | Visible in tmux | Constant/growing |

A good design treats these separately: A wants **autonomous reaping** (it's pure waste,
nothing references it), B wants **surfacing + confirmation** (it might be doing real work),
C wants **hygiene/pruning** (and partly upstream-of-the-other-two: less haystack).

---

## 6. Detection signals & tradeoffs

1. **Structural: "child of a TBD-owned server with no live pane."**
   For each `tbd-*` server the daemon owns, compute `{pids with ppid==server} − {live
   pane_pids}`. Members are orphans *by construction* — the server spawned them, no window
   references them, the UI cannot reach them.
   - *Tradeoff*: deterministic, **zero false positives** for class A (windowless). Cheap
     (`ps` + `tmux list-panes`). Best signal. Caveat: misses class B (still has a pane) and
     misses orphans whose server has since died (reparented to launchd) — see signal 2.

2. **Ownership fingerprint: TBD's spawn argv.** Every TBD-spawned agent carries
   `--settings …/runtime/claude-overlay.json --plugin-dir …/TBD/plugin` (and Codex its
   isolated `CODEX_HOME`). Combined with `ppid==1` (reparented) or "not a pane of any live
   server," this catches orphans that outlived their server (the historical `--bg-pty-host`
   case, 20 days, ppid=1).
   - *Tradeoff*: deterministic ownership marker — will not touch a user's own non-TBD
     `claude`. Near-zero FP. Needs an argv scan (`ps -o command`), slightly more work than
     signal 1. Pid-reuse risk handled by re-checking argv immediately before any kill.

3. **Dead gravestone pane age** (`pane_dead=1`, older than N hours).
   - *Tradeoff*: process is already gone — pruning is **risk-free**. Pure hygiene (class C).

4. **CPU sustained over time on a known pane_pid** (sample twice over minutes; flag if
   sustained > threshold *and* no attached client *and* no recent pane input).
   - *Tradeoff*: the only signal for class B, but **heuristic with real FP risk** — a healthy
     agent compiling/running tests spikes CPU legitimately. Must require a long sustained
     window + no client + (ideally) the kevent-spin stack signature via `sample`. Strong bias
     toward **surface, don't auto-kill**.

5. **PTY/fd-closed-but-alive probe** (e.g. `lsof` shows the pane's pts gone but process
   lives). Essentially a more expensive restatement of signals 1–2; not worth it standalone.

6. **Unresponsive-to-tmux** (send a no-op keystroke, watch for pane reaction). Intrusive,
   fragile, can corrupt a healthy session's input. **Reject.**

---

## 7. Reaping trigger points & tradeoffs

- **At teardown (archive/reconcile) — confirm-and-escalate.** Capture `pane_pid` *before*
  `kill-window`; after the kill, wait a short grace, check the pid still lives; if so
  `SIGTERM`, recheck, `SIGKILL`. This closes the gap **at the exact moment orphans are
  created**, where ownership is unambiguous. Smallest, highest-leverage change.
- **Daemon startup reconcile (extend existing path).** Reconcile already walks servers;
  add the signal-1/signal-2 sweep to reap pre-existing structural orphans (e.g. ones created
  by a previous build's teardown). Natural home, runs once per launch.
- **Periodic background sweep.** A slow tick (≈30–60s for the structural sweep; CPU sampling
  even slower) catches orphans that appear between restarts and the rare class-B wedge.
  Tradeoff: must be cheap and must never block the 2s state poll.
- **Manual `tbd doctor` / `tbd reap` CLI.** Lists suspects with evidence (age, CPU, server,
  fingerprint); `--kill` reaps. Transparent, user-controlled, great for the rare wedge
  without baking risk into an automatic hot path.
- **Restart-time (`scripts/restart.sh`).** Tempting but risky/duplicative — better to let
  the daemon's startup reconcile own it so logic lives in one place.

---

## 8. Safety risks (the hard constraint: never kill what the user wants)

- **Resumable / in-use sessions.** Class-A structural detection is inherently safe here: a
  process with no pane cannot be resumed or viewed through TBD, so reaping it removes nothing
  the user can reach. This is the main reason to lean on signal 1.
- **Healthy-but-busy agents (class B).** Highest FP risk. Mitigate with sustained-CPU + no
  client + spin-signature, and prefer surfacing over auto-kill.
- **Foreign `claude` processes.** Only ever act on processes carrying TBD's spawn
  fingerprint (signal 2). Never reap by name alone.
- **PID reuse / TOCTOU.** Re-verify the argv fingerprint immediately before sending any
  signal; never cache a pid across a long gap and kill it blind.
- **Gravestone vs. live.** Only prune `pane_dead=1` panes; never `kill-window` a live window
  on age alone (that *creates* the class-A risk for a wedged occupant).
- **Idle ≠ wedged.** A 14-day idle-but-alive session the user intends to resume must not be
  reaped. Age is not a kill signal; "no pane" and "sustained spin" are.

---

## 9. Candidate approaches (ranked)

### Approach 1 — Confirm-and-escalate teardown + structural orphan sweep  ★ recommended core
- Capture `pane_pid` before `kill-window`; escalate `SIGTERM`→`SIGKILL` if it survives the
  grace period. Add a startup + periodic sweep using signals 1 & 2 to reap pre-existing
  windowless orphans. Prune `pane_dead` gravestones older than N hours (signal 3).
- **Pros**: directly closes the creation gap; deterministic, near-zero FP; cheap; no DB
  migration strictly required (`TmuxManager.panePID()` already exists). Reaps the dangerous
  class A autonomously and safely.
- **Cons**: doesn't address class B (still-windowed wedge) — acceptable, that's rarer and
  visible; add via Approach 3 as a complement.

### Approach 2 — Persist the agent OS PID as a first-class lifecycle key
- Capture and store `Terminal.agentPID` at spawn (new DB column + model field, per the
  migration rules in CLAUDE.md). Liveness = `kill(pid,0)`; reaping = signal that pid;
  health = sample that pid.
- **Pros**: robust mapping that survives view-session confusion; the foundation that makes
  class-B CPU monitoring clean and attributable.
- **Cons**: more invasive (DB migration + Codable model change + spawn-path change);
  pid-reuse staleness (must re-verify argv); must confirm the pane_pid captured at spawn is
  the agent, not a transient shell. Best treated as an *optional foundation under* Approach 1,
  not a prerequisite.

### Approach 3 — Health monitor + UI surfacing (pairs with 1)
- Background CPU sampler flags sustained-spin, no-client windows; the app surfaces "this
  session appears wedged — kill / keep?" rather than auto-killing.
- **Pros**: safest possible handling of class B; respects "never kill what the user wants";
  turns an invisible burn into a visible, one-click decision.
- **Cons**: needs a human present to act — doesn't autonomously stop an unattended multi-day
  burn (so it complements, not replaces, Approach 1's autonomous class-A reaping).

### Approach 4 — `tbd doctor` / `tbd reap` CLI (+ optional launchd watchdog)
- Standalone command enumerating TBD-owned servers, listing orphans/wedges by signals 1–3,
  reaping on `--kill`; optionally scheduled via launchd.
- **Pros**: transparent, user-controlled, decoupled from the daemon hot path; ideal for the
  rare episodic wedge; trivial to run ad hoc.
- **Cons**: not automatic unless scheduled; duplicates detection logic that ought to live in
  the daemon. Best shipped as the *human-facing surface over the same detection module* used
  by Approach 1.

**Recommended shape**: build the detection as one shared module (signals 1–3), then layer:
Approach 1 for autonomous class-A safety (core), Approach 3 for class-B surfacing, Approach 4
as the manual/transparent surface. Approach 2 only if/when robust per-pid CPU monitoring is
wanted. Pruning class-C accumulation (gravestones + archived-worktree windows) falls out of
the same module and shrinks the haystack for everything else.

---

## 10. Open questions to resolve before any implementation

1. Does `kill-window` on a wedged occupant reliably orphan it, or does tmux force-reap after
   a timeout on some versions? (Reproduce by wedging a fake busy-looper and `kill-window`.)
2. Is the pane process always the agent (shell exec'd) on every spawn path, including Codex?
   If not, the structural/pid signals need to walk one level of children.
3. What grace period before SIGTERM→SIGKILL avoids killing an agent mid-flush of transcript
   JSONL? (Transcript integrity matters for resume.)
4. Class-B threshold tuning: what sustained CPU % over what window, and can we cheaply get
   the `kevent`-spin stack signature to distinguish spin from genuine work?
5. View-session leakage (stale grouped `tbd-view-*`) — same module, or a separate fix?
6. Relationship to the sibling `tbdapp-cpu-energy-investigation` worktree
   (`tbd/20260611-junior-elk`): that concerns **TBDApp's own** terminal-redraw CPU, a
   different process and concern. The only overlap is "high CPU in Activity Monitor under
   iTerm2"; no shared code path. Keep separate.
```
