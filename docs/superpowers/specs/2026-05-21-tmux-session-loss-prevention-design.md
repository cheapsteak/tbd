# Prevent Claude session loss on tmux server death

## Problem

When a TBD-managed tmux server dies and is recreated, reconcile permanently
deletes the `terminal` rows whose windows lived on the previous server
instance. For `claude`/`codex` terminals this destroys the only database link
to the session — the transcript JSONL survives on disk in
`~/.claude/projects/`, but TBD can no longer show or resume it.

On 2026-05-21 this destroyed ~40 Claude session links in the longeye-app repo
in a single incident. The user reported it as "lost a bunch of Claude
sessions".

## Root cause

Two independent defects combine to turn a recoverable event (a tmux server
restart) into permanent data loss.

### Defect 1 — reconcile deletes recoverable terminals

`Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift:160-178`. The
dead-window cleanup pass:

```swift
if serverAlive {
    let alive = await tmux.windowExists(server: wt.tmuxServer, windowID: terminal.tmuxWindowID)
    if !alive {
        try? await db.terminals.delete(id: terminal.id)   // line 166
        await pendingQuestions.clear(terminalID: terminal.id)
    }
} else {
    try await recreateAfterReboot(terminal: terminal, worktree: wt)
}
```

The reboot-recovery path (which re-spawns stranded windows instead of deleting
them) is gated on `serverExists == false`. But a **freshly recreated server
still "exists"** — it simply contains none of the old windows. So reconcile
takes the `serverAlive == true` branch, finds every pre-restart terminal's
window absent, and silently deletes the row. A single boolean cannot
distinguish "same server, one window died" from "server was replaced, all
windows stranded". Confirmed by `0` "Reboot recovery" log lines on the
incident day.

### Defect 2 — tmux server runs under a 256 file-descriptor limit

`launchctl limit maxfiles` is **256**. TBD raises `RLIMIT_NOFILE` nowhere
(no `setrlimit` call in `Sources/` or `scripts/`). The TBDApp is launched by
LaunchServices (default 256-fd soft limit), spawns the daemon as a child
(`DaemonClient.swift:144`), which inherits 256, and the daemon spawns tmux,
which inherits 256.

A tmux server hosting many panes (the longeye-app server had 65 — each pane is
a pty master fd, plus a socket fd per attached client, plus per-operation
spikes when spawning new panes) can exhaust 256 descriptors. tmux handles
fd-allocation failure with `fatal()` → `exit(1)`. A clean `exit(1)` produces
no crash report, which matches the evidence: no `DiagnosticReports` entry, no
`jetsam` log, no machine reboot, and the failure was size-correlated (only the
largest server died — other repos' servers, all single-digit pane counts,
survived the same daemon restarts).

This is a strong, evidence-consistent hypothesis rather than a defect caught
in the act; the daemon kept no persisted logs at the time (see Diagnostics).

## Design

Three changes, in `Sources/TBDDaemon/`. Parts A and C are independent and can
land in either order. Diagnostics should land with them so a recurrence is
observable.

### Part A — reconcile suspends recoverable terminals instead of deleting

In the dead-window branch (`reconcile.swift:165-168`), replace the
unconditional delete with a decision keyed solely on `claudeSessionID`:

- Terminal **has a `claudeSessionID`**: mark it suspended via
  `db.terminals.setSuspended(id:sessionID:snapshot:)` with `snapshot: nil`.
  Do **not** delete.
- Terminal **has no `claudeSessionID`** (plain `shell`, custom-cmd, or a
  `codex` terminal that never recorded a session id): keep the existing
  `db.terminals.delete(id:)` — there is nothing the resume path can act on.

`claudeSessionID` is the right discriminator because `resumeTerminal` keys
entirely off it (`guard let sessionID = terminal.claudeSessionID`). A
terminal without one cannot be resumed even if kept, so suspending it would
only produce a permanently un-resumable row. Suspending happens exactly when
a session *can* be brought back.

`pendingQuestions.clear(terminalID:)` runs in both cases, unchanged.

Why this is sufficient and correct:

- A suspended terminal is exactly the existing "session exists, no live
  window, resume on demand" state. reconcile's dead-window pass already skips
  `terminal.suspendedAt != nil`, so a suspended terminal is never re-examined
  or deleted by a later pass.
- `SuspendResumeCoordinator.resumeTerminal` rebuilds a window from just the
  `claudeSessionID` (`claude --resume`). It does not depend on the stale
  `tmuxWindowID`/`tmuxPaneID` — step 1 probes the old pane, finds no Claude
  process, and proceeds to `createWindow`. So a terminal stranded by a server
  restart resumes cleanly.
- `selectionChanged → scheduleResume` auto-resumes a worktree's suspended
  terminals when the user selects it. After the fix, a worktree whose server
  died shows its Claude terminal as suspended and resumes it on selection — no
  manual step, no data loss.

This makes server death non-catastrophic regardless of *why* the server died,
including causes not addressed by Part C.

### Part C — daemon raises its file-descriptor limit at startup

Add `Daemon.raiseFileDescriptorLimit()`, a static method mirroring the
existing `Daemon.scrubInheritedTBDEnv()` pattern, called at the very start of
`Daemon.start()` (before any tmux server can be spawned).

Behavior:
- Read the current limit with `getrlimit(RLIMIT_NOFILE, &limit)`.
- Raise `rlim_cur` to `min(rlim_max, 8192)` — 8192 is comfortably above any
  realistic pane count; `rlim_max` is the ceiling we cannot exceed without
  privilege.
- Apply with `setrlimit(RLIMIT_NOFILE, &limit)`.
- Log the before/after values at `.info` (subsystem `com.tbd.daemon`,
  category `startup`).
- A `getrlimit`/`setrlimit` failure is non-fatal — log a `.warning` and
  continue. The daemon must still start.

The tmux server, spawned as a daemon child, inherits the raised limit. This
removes the most likely trigger of server death.

### Diagnostics

So the next occurrence is diagnosable in seconds rather than reconstructed
forensically:

1. **Log tmux server lifecycle events.** Add `.info` log lines (subsystem
   `com.tbd.daemon`, category `tmux`) at:
   - `TmuxManager.killServer` — log the server name and caller context.
   - `TmuxManager.ensureServer` when it actually creates a new server (not
     when it finds an existing one) — log the server name.
   - `reconcile.swift:166` path — log when a terminal is suspended-by-reconcile
     vs deleted-by-reconcile, with terminal id, kind, and worktree id.
2. **Persist daemon logs across restarts.** `scripts/restart.sh:92` truncates
   `/tmp/tbdd.log` on every restart (`>`), and `os.Logger` output is not
   persisted by default. Change the redirect to append (`>>`) and rotate, OR
   document the one-time `sudo log config --subsystem com.tbd.daemon --mode
   "level:debug,persist:debug"` in `docs/diagnostics-strategy.md` as the
   supported way to retain daemon logs. Pick the append-and-rotate option —
   it needs no privileged one-time setup and survives unattended.

## Testing

- **Part A — claude terminal, dead window, live server:** construct a
  `claude`-kind terminal with a `claudeSessionID` and a stale window id; run
  the dead-window reconcile pass against a live server that lacks that
  window; assert the terminal still exists and `suspendedAt != nil`.
- **Part A — shell terminal, dead window, live server:** same setup with a
  `shell` terminal and no `claudeSessionID`; assert the terminal row is
  deleted (unchanged behavior).
- **Part A — live window untouched:** terminal whose window *does* exist on
  the live server is neither suspended nor deleted.
- **Part C:** unit-test `raiseFileDescriptorLimit()` raises `rlim_cur` toward
  the target and never above `rlim_max`; a simulated `setrlimit` failure does
  not throw.
- Diagnostics log lines need no automated test; verify manually via
  `log stream`.

## Out of scope

- **Recovery of already-lost sessions.** The 40 transcripts from the
  2026-05-21 incident remain intact on disk; the user will resume them
  manually. No recovery script.
- **The 187 orphaned `tab` rows.** A separate, pre-existing vestigial-feature
  artifact (`worktree.tabOrder` is empty everywhere; all labels are `"Hello"`).
  Unrelated to session loss. Leave for a follow-up.
- **The deleted `cda230f5` model profile.** 28 terminals still reference a
  profile removed from `model_profiles`; they resume under keychain login
  (logged warning, no data loss). Separate issue.
- **`window-style` neutralization in TBD.** The user's `~/.tmux.conf`
  gray-cell styling was resolved by editing the user's config directly
  (lines removed). TBD will not auto-neutralize `window-style`.
- **Reboot-detection refinement.** Teaching reconcile to recognize a recreated
  server (e.g. tracking a server instance id) and route all its terminals
  through recovery would be a cleaner model, but Part A already makes the
  outcome correct. Deferred.
