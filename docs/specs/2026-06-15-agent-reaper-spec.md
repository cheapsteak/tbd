# Spec: autonomous reaping of orphaned / wedged agent processes (Approach 1)

Status: **approved design, ready for implementation planning**. Written 2026-06-15.

Companion to the problem brainstorm in
[`reaping-orphaned-agents-design.md`](reaping-orphaned-agents-design.md), which
characterizes the lifecycle, the three phenomena, and the ranked approaches. This spec
covers the implementation of **Approach 1** only.

---

## 1. Problem (one paragraph)

TBD spawns `claude`/`codex` agents inside per-repo tmux servers but tracks only tmux
window/pane IDs — never the OS PID — and has no process-level liveness or reaping. Its
sole teardown mechanism, `tmux kill-window`, closes the pane's PTY and sends `SIGHUP`.
A healthy agent exits; a **wedged** agent (busy-looping in `kevent` on a dead PTY — an
upstream Claude CLI bug TBD cannot fix) survives, loses its pane, and spins a core for
days, invisible to TBD and the UI.

**Empirically confirmed (2026-06-15):** a SIGHUP-ignoring busy-looper run in a tmux window
survives `kill-window` at ~99% CPU and reparents to launchd. So `kill-window` alone leaks
wedged processes — confirm-and-escalate is necessary, not belt-and-suspenders.

## 2. Goals / non-goals

**Goals**
- Reap windowless orphan agents that TBD spawned, autonomously and safely.
- Close the teardown gap at the moment orphans are created (archive, reconcile, kill-server).
- Run a background sweep (startup + periodic) to catch orphans left by prior builds.

**Non-goals (explicitly out of scope for v1)**
- Windowed-wedge CPU monitor (still-in-a-live-window high-CPU agent) — that is Approach 3;
  surface, don't auto-kill. Not built here.
- `tbd doctor` / `tbd reap` CLI.
- Daemonized `--bg-pty-host` children that `setsid` away from the agent's process group.
- Gravestone (`pane_dead=1`) pruning — `remain-on-exit on` is intentional (lets the user
  read an exited agent's final output); dead panes on archived worktrees are already killed
  by reconcile's orphan-window cleanup. Leaving them alone keeps v1 purely additive.
- Persisting the agent OS PID in the DB — not needed; pane_pids are captured live.

## 3. Safety model (the hard constraint: never kill what the user wants)

- **Structural detection is the primary safety guarantee.** An orphan is defined as a
  process that is a child of a TBD-owned tmux server **but is not the `pane_pid` of any live
  pane** in that server. No pane ⇒ the UI cannot show or resume it ⇒ reaping removes nothing
  the user can reach. Zero false positives by construction.
- **Ownership fingerprint (defense in depth).** Before signalling, require the process to
  carry a TBD spawn marker: argv contains `runtime/claude-overlay.json` or
  `--plugin-dir …/TBD/plugin`, **or** it is a child of a `tbd-*` server. Never reap by
  process name alone; never touch a user's own non-TBD `claude`.
- **Escalation only hits stuck processes.** A healthy agent exits on `kill-window`'s SIGHUP
  within ~1s; escalation fires only after the grace window, so SIGKILL never races a healthy
  agent mid transcript-flush.
- **PID-reuse / TOCTOU.** Re-verify the fingerprint immediately before signalling; never
  cache a pid across a long gap and kill it blind.
- **Live panes are never reaped.** Enforced by the set-difference and asserted in tests.

## 4. Architecture

Three units, each independently testable.

### 4.1 `ProcessSignaller` — injectable OS seam
A small protocol + production struct wrapping the OS, mirroring `TmuxManager`'s
dryRun/recorder pattern so reaper logic is unit-testable without real signals or `ps`.

```
protocol ProcessSignaller: Sendable {
    func isAlive(_ pid: Int32) -> Bool                 // kill(pid, 0) == 0
    func terminate(groupOf pid: Int32)                 // kill(-pid, SIGTERM)
    func kill(groupOf pid: Int32)                      // kill(-pid, SIGKILL)
    func children(ofServerPID pid: Int32) -> [Int32]   // ps -axo pid,ppid → ppid == pid
    func commandLine(_ pid: Int32) -> String?          // ps -o command= -p <pid>
}
```

- Group signalling (`kill(-pid, …)`): tmux runs each pane via `setsid`, so the pane process
  is a process-group leader; group-kill reaps in-group descendants (e.g. subagents) too.
- Production impl uses `kill(2)` directly for signals and `ps` for enumeration. A fake impl
  drives tests (scriptable alive/children/cmdline tables, records signals sent).

### 4.2 `AgentReaper` — detection + reaping logic
Depends on `ProcessSignaller` and `TmuxManager`. Pure logic over injected data.

- `serverPID(server) -> Int32?` — `tmux -L <server> display-message -p '#{pid}'`
  (new `TmuxManager` command builder + instance method, following existing conventions).
- `livePanePIDs(server) -> Set<Int32>` — `tmux -L <server> list-panes -a -F '#{pane_pid}'`
  (new `TmuxManager` method).
- `findStructuralOrphans(server) -> [Int32]` =
  `children(ofServerPID:) − livePanePIDs(server)`.
- `isTBDOwned(pid) -> Bool` — fingerprint check on `commandLine(pid)`.
- `reap(_ pid)` — escalation ladder:
  1. `terminate(groupOf: pid)` (SIGTERM)
  2. poll `isAlive` over the grace window
  3. if still alive, `kill(groupOf: pid)` (SIGKILL)
  - Log each reap at `.info` with evidence (pid, server, age/cmd snippet, which signal ended it).
- `sweep(servers:) async` — for each owned server: `findStructuralOrphans`, filter by
  `isTBDOwned`, `reap` each.

Grace defaults: SIGTERM, ~3s grace, then SIGKILL. (Named constants; tunable.)

### 4.3 Wiring into the daemon

**Teardown confirm-and-escalate** — capture `panePID` *before* `kill-window`, escalate after:
- `WorktreeLifecycle+Archive.swift:117` (archive window-kill loop).
- `WorktreeLifecycle+Reconcile.swift:124` (missing-worktree window kill).
- `WorktreeLifecycle+Reconcile.swift:242` (orphan-window cleanup).
- `WorktreeLifecycle+Reconcile.swift:223` (`kill-server`): reap the server's children
  *before* `killServer`, else they reparent to launchd and escape.

The shared helper: given `(server, windowID, panePID)`, run `kill-window`, then if
`panePID` is still alive past the grace, `AgentReaper.reap(panePID)`.

**Background sweep** — startup + periodic:
- Startup: invoke `AgentReaper.sweep` over all owned servers after the existing per-repo
  reconcile loop in `Daemon.start()`.
- Periodic: new `reaperTask: Task<Void, Never>?` stored as `nonisolated(unsafe) var`
  alongside `sshRefreshTask`/`gitFetchTask`/`gitStatusTask`, body
  `while !Task.isCancelled { sleep ~60s; sweep }`. Cancelled in `Daemon.stop()`.

## 5. Detection signal summary

| Signal | Use | FP risk |
|---|---|---|
| child-of-owned-server `−` live-pane-pids | primary orphan detection | none (structural) |
| argv fingerprint (overlay / plugin-dir path) | ownership gate before any kill | none |
| `isAlive` after `kill-window` past grace | teardown escalation trigger | none (only stuck procs) |

## 6. Testing (per CLAUDE.md: a test for each branch of new gated behavior)

Using the `ProcessSignaller` fake + `TmuxManager(dryRun:)` hooks:

- **Orphan set math**: children `{A,B,C}` with live panes `{B}` → orphans `{A,C}`.
- **Fingerprint gate**: orphan with TBD argv → reaped; orphan without → left alone.
- **Escalation ladder**:
  - dies on SIGTERM (isAlive→false within grace) → **no** SIGKILL sent.
  - survives SIGTERM (isAlive stays true) → SIGKILL sent.
- **Safety negatives**:
  - a pid that **is** a live pane_pid is never in the orphan set / never signalled.
  - a non-TBD process (no fingerprint) is never signalled.
- **Teardown escalation**: after `kill-window`, a still-alive panePID triggers `reap`; an
  already-dead panePID triggers no signals.
- **kill-server path**: children are reaped before `killServer` is called (assert ordering).
- **Sweep loop**: a sweep over multiple servers reaps orphans in each.

All tests isolate from `~/tbd` / `UserDefaults` per CLAUDE.md (no real signals — the fake
records intent).

## 7. Files (anticipated)

New:
- `Sources/TBDDaemon/Process/ProcessSignaller.swift` (protocol + production impl)
- `Sources/TBDDaemon/Process/AgentReaper.swift`
- `Tests/TBDDaemonTests/AgentReaperTests.swift`

Modified:
- `Sources/TBDDaemon/Tmux/TmuxManager.swift` (server-pid + list-all-pane-pids commands/methods)
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift` (teardown escalation)
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift` (teardown escalation ×3 + kill-server pre-reap)
- `Sources/TBDDaemon/Daemon.swift` (startup sweep + periodic `reaperTask` + stop() cancel)

No DB migration. No new RPC method. No shared-model change.

## 8. Open questions deferred to planning (do not expand v1 scope)

1. Exact periodic cadence (start at 60s; revisit if it shows in profiles).
2. Whether the startup sweep should run once globally or per-repo inside the reconcile loop
   (lean: once globally, after the loop, to avoid N enumerations of overlapping servers).
3. `display-message -p '#{pid}'` vs deriving server pid another way if a server has no
   sessions at the moment of query (edge case; the sweep simply skips servers it can't read).
