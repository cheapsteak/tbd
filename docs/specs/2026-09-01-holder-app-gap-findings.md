# What a holder-backed session actually does in the app today

An evidence report, not a design. Every claim below was produced by driving a
real daemon, a real `TBDHolder`, a real child process and the real SwiftUI app
against an isolated `TBD_HOME`, and is backed by a database row, a process
listing, a log line, or a screenshot.

The subject is Milestone A of the pty-holder session transport
([`2026-08-30-pty-holder-session-transport-design.md`](2026-08-30-pty-holder-session-transport-design.md)),
merged and gated behind the default-off `pty_holder_enabled` flag. Milestone B —
teaching the app the transport — is not built. This report establishes what
"not built" costs at runtime, so Milestone B can be designed against measured
behavior rather than a summary.

## Headline: the destructive half of the standing claim is refuted

The claim on record was that the app, being transport-blind, classifies a
holder row as `.windowMissing`, **fires automatic recovery, and reparks a live
session as hibernated while its holder and child keep running**.

- **Confirmed:** the app is transport-blind, and it does classify a
  holder row as `.windowMissing` and fire automatic recovery unprompted.
- **Refuted:** nothing is reparked. The daemon refuses
  `terminal.recreateWindow` for a holder row before it touches any state, so
  recovery fails harmlessly. Across the whole probe the row's `suspendedAt`,
  `hibernatedAt` and `hibernateReason` stayed NULL, `transport` stayed
  `holder`, and the holder, its child shell and the job it forked kept running
  and kept emitting output.

That distinction decides whether the flag is safe to soak, so it is worth
stating precisely: **automatic recovery fires, is refused, and changes
nothing.** The failure is cosmetic and recoverable, not a silent loss of a
running session.

## How the evidence was produced

- Isolated `TBD_HOME` at `/private/tmp/hgap1` with its own socket, database,
  holders directory and tmux socket directory. The developer's live `~/tbd`
  and its daemon were untouched throughout.
- One tmux-backed worktree (`wt-tmux`) created with the flag off, then
  `config.setPtyHolderEnabled` true, then one holder-backed worktree
  (`wt-holder`). Both worktrees share the repo's single tmux server — that
  detail turns out to be load-bearing, see "The classification depends on an
  unrelated tmux server". A second repository (`srcrepo2`) with a single
  holder-backed worktree and no tmux server covers the other case.
- `claude` was shimmed by a Python job that prints its pty size, counts
  `SIGWINCH`, echoes anything read from stdin, and writes every line to a file
  under `$TBD_JOBLOG` as well as to stdout — so no claim about the job depends
  on an emulator's rendering.
- Daemon and app logs captured live with
  `/usr/bin/log stream --level debug --predicate 'subsystem BEGINSWITH "com.tbd"'`.
- Screenshots and raw captures live under the probe scratchpad
  (`.../scratchpad/hgap-shots/`, `.../scratchpad/hgap-logstream.txt`); they are
  referenced by path and deliberately not committed.

The row under test, confirmed holder-backed before the app ever saw it:

```
             id = C342DFDC-F5FC-47AB-89A8-F2EC8752A063
      transport = holder
   tmuxWindowID = ''
     tmuxPaneID = ''
     holder_pid = 42934      (TBDHolder --session C342DFDC-… , state Ss)
      child_pid = 42935      (/bin/sh -i -l -c … claude …    , state Ss)
    suspendedAt = NULL
   hibernatedAt = NULL
claudeSessionID = 68267D49-0B18-4627-850B-A0B5EC8C4D36
```

with the job (pid 42940) a live grandchild of the holder, and
`terminal.output` already rendering its output through the daemon's own
emulator.

## Claim by claim

### The session list shows the worktree correctly, with no transport tell

`wt-tmux` and `wt-holder` render identically in the sidebar — same row shape,
same activity glyph, same treatment. Nothing marks one as holder-backed.
Selecting `wt-holder` opens it normally: correct title (`srcrepo wt-holder`),
correct path and branch in the status bar (`/private/tmp/hgap1/worktrees/srcrepo/wt-holder`,
`tbd/wt-holder`), a `Claude` tab and a `Notes` tab, and a working Changes pane.
Screenshot: `hgap-shots/10-holder-worktree-open.png`.

Everything outside the terminal pane is already correct. The gap is confined to
the pane itself.

### The terminal pane renders an error, not the session

The pane is a black grid containing one line of fed text and nothing else:

> `Automatic terminal recovery failed. Retry manually or close the tab.`

with the same sentence repeated in an orange banner above the grid, carrying a
**Retry** button. No session output appears, even though the daemon was
serving that same session's output over RPC at the same moment.

Screenshot: `hgap-shots/10-holder-worktree-open.png`.

### Automatic recovery fires — confirmed

The full chain, from the captured log stream, in the 800 ms after the tab
opened:

```
17:30:57.761  TBDApp[76709]  [com.tbd.app:TmuxBridge] Preparation failed at selectWindow: can't find session: tbd-view-c342dfdc
17:30:57.988  TBDApp[76709]  [com.tbd.app:TerminalPanel] terminal preparation failed terminal=C342DFDC-… stage=selectWindow category=windowMissing
17:30:57.988  TBDApp[76709]  [com.tbd.app:AppState+Terminals] Claimed automatic terminal recovery attempt 1 for C342DFDC-…
17:30:58.504  TBDApp[76709]  [com.tbd.app:AppState+Terminals] Automatic terminal recreation attempt 1 failed for C342DFDC-…: RPC error: Terminal C342DFDC-… runs on the pty-holder transport, which has no tmux window to recreate. Its session is unchanged.
17:30:58.504  TBDApp[76709]  [com.tbd.app:TerminalPanel] automatic terminal recovery terminal=C342DFDC-… stage=selectWindow category=failed attempt=1
```

No user gesture preceded this. The app classified the row `.windowMissing` and
called `terminal.recreateWindow` on its own.

### Nothing was reparked — refuted

The daemon's holder guard in `handleTerminalRecreateWindow` returns before the
worktree lookup and before any state is touched, so the two downstream branches
— park-as-suspended for a resumable row, or stand up a fresh tmux window — are
never reached. Measured immediately after the recovery attempt:

```
=== AFTER OPENING HOLDER TAB IN APP ===
      transport = holder
   tmuxWindowID = ''      tmuxPaneID = ''
     holder_pid = 42934      child_pid = 42935
    suspendedAt = NULL    hibernatedAt = NULL    hibernateReason = NULL
claudeSessionID = 68267D49-0B18-4627-850B-A0B5EC8C4D36

42934  Ss  TBDHolder --session C342DFDC-… (alive)
42935  Ss  /bin/sh -i -l -c … claude …   (alive)
42940  S+  python3 -u /private/tmp/hgap1/bin/job.py (alive)

joblog tail:  TICK 312 … / TICK 313 … / TICK 314 …
```

The job kept ticking straight through the recovery attempt. Raw capture:
`scratchpad/hgap-after-open.txt`.

Pressing **Retry** produces the same refusal on the manual path
(`Failed to recreate terminal window: Error Domain=TBDApp.DaemonClientError Code=3`)
and leaves the row equally untouched — the refusal is idempotent, not a
one-shot. Screenshot: `hgap-shots/12-after-retry.png`.

A second, independent rail backs this up in the shared model:
`Terminal.isManuallyHibernatable` refuses `transport == .holder` outright, so
the manual and automatic hibernation paths cannot repark a holder row either.
The app's recovery path and the hibernation path are both closed.

### The daemon can already serve the session's content read-only

`terminal.output` has a working holder branch that renders the daemon's own
emulator. Against the same row the app was showing an error for:

```
HOLDERJOB-START pid=42940 size=30x100
TICK 1 size=30x100 winches=0
…
TICK 9 size=30x100 winches=0
```

This is the most encouraging finding in the report. The read path is not a gap
at all — the content exists, is live, and is one RPC away. What is missing is
an app-side consumer: nothing in `Sources/TBDApp` calls `terminal.output` for
rendering, because the tmux path renders by attaching a viewer subprocess to a
tmux session rather than by polling content.

A read-only holder tab is therefore close: it needs a render surface fed from
`terminal.output` (or a push equivalent), not new daemon capability.

### Typing does not reach the job

With the tab focused, 21 characters were typed into the pane. The job's own
log recorded **zero** `GOT-INPUT` lines, and the daemon's emulator screen was
unchanged apart from its ticking clock. This is expected and consistent: the
tmux path delivers keystrokes through the viewer subprocess's pty, and no
viewer subprocess exists for a holder row. `terminal.send` also refuses holder
rows by design in Milestone A ("which has no key-send path yet").

### Resize reaches the job — the daemon leg is done, the app never asks

Two separate things, and conflating them would misreport the state:

- **The daemon leg works.** Calling `app.setMainAreaSize` with 123x41 directly
  over RPC produced, in the job's own log,
  `SIGWINCH #1 size=41x123` followed by `TICK 375 size=41x123 winches=1`. The
  wiring from #779 (`HolderReader.resize` reshapes the emulator and sets the
  pty window size) is genuinely live, and the child really is signalled.
- **The app never broadcast one.** Across three window resizes — 1200x800 to
  952x652, back out to 1192x642, and down again — the daemon logged exactly one
  `setMainAreaSize` for the whole run: the one sent by hand over RPC. The app
  emitted none.

The documented reason is that `scheduleMainAreaSizeBroadcast()` is gated on
`enableTerminalAutoResize`, an experimental UserDefaults key that is off by
default. **Boundary of this finding:** writing that key true in the app's
defaults domain before a fresh launch still produced no broadcast, and this
probe did not establish why — whether the running app had picked the key up,
or whether the main area's geometry never reaches `mainAreaSize` when the pane
is showing a preparation error, was not determined. What is certain is the
negative result and the positive one: no broadcast was ever observed from the
app, and the daemon's holder leg signals the child correctly when asked.

So resize is not primarily a holder gap. The holder half is already correct
underneath; what is undecided is what drives it.

## The classification depends on an unrelated tmux server

Worth stating because it changes what a soak would see. `.windowMissing` is
only returned when the window-inventory probe **succeeds** and omits the
expected window id. A holder row's `tmuxWindowID` is the empty string, so it is
never in any inventory — but the probe itself only succeeds if a tmux server is
running for that repo, and the tmux server is per-repo, shared by all its
worktrees.

Both cases were measured, in one daemon, by adding a second repository whose
only session is holder-backed and therefore has no tmux server at all:

- **A repo with any tmux-backed session alive** (`srcrepo`, holding both
  `wt-tmux` and `wt-holder`) has a live server, the probe succeeds, and the
  holder row classifies as `.windowMissing` → automatic recovery fires and is
  refused, as documented above.

  ```
  TmuxBridge  Preparation failed at selectWindow: can't find session: tbd-view-c342dfdc
  TerminalPanel  terminal preparation failed terminal=C342DFDC-… stage=selectWindow category=windowMissing
  ```

- **A repo whose sessions are all holder-backed** (`srcrepo2`, holding only
  `wt-holder2`) has no tmux server. The probe fails, and a failed probe is
  deliberately treated as ambiguous, so the failure classifies as
  `.commandFailed` → no recovery is attempted at all.

  ```
  TmuxBridge  Preparation failed at selectWindow: no server running on …/tbd-cd061a04
  TerminalPanel  terminal preparation failed terminal=E39F9719-… stage=selectWindow category=commandFailed
  ```

  The pane shows *"TBD couldn't attach to this terminal. The terminal was left
  unchanged. Check diagnostics for details or close the tab."* with **no**
  orange banner and **no** Retry button.
  Screenshot: `hgap-shots/13-holder-no-tmux-server.png`.

The second case is the one a fresh install with the flag on would hit, and it
is the quieter of the two. Both end at a broken pane; they differ only in
whether a doomed RPC is fired first. Both left their row and processes
untouched — at the end of the run both holder rows still read `transport =
holder` with NULL `suspendedAt` / `hibernatedAt` / `hibernateReason`, and both
holders, child shells and jobs were alive and ticking
(`scratchpad/hgap-final.txt`).

## Two incidental observations from standing the app up

Neither is about the holder transport, but both cost time and would cost a
soak participant the same time.

- **The app is transport-blind in the literal sense**: `Sources/TBDApp`
  contains zero references to `TerminalTransport`, and the `Terminal` model's
  `transport` field is never read anywhere in the app target. Every holder
  refusal the user sees today is authored by the daemon and surfaced as an
  opaque RPC error string.
- **A first-launch modal blocks the whole UI.** `CLIInstallerCoordinator`
  presents an app-modal `NSAlert` from `connectAndLoadInitialState()`; until it
  is dismissed the main window renders but accepts no input, with the main
  thread parked in `-[NSAlert runModal]`. It looks exactly like a hang.

## What Milestone B must close, ordered by what blocks a working screenshot

1. **Give the app a holder-aware preparation path.** Today
   `TmuxBridge.prepare` is the only route to a rendered pane, and it can only
   ever fail for a holder row. Until the app branches on `terminal.transport`
   before preparing, nothing else on this list is reachable.
2. **Stop firing automatic recovery at holder rows.** The daemon's refusal
   makes this harmless today, but it is a doomed RPC per tab open plus two
   scary error banners, and it burns the recovery budget for the tab. The fix
   belongs on the app side of the classification, not as a second daemon guard.
3. **Render holder output read-only.** The content already exists over
   `terminal.output`; what is missing is a surface that consumes it. This is
   what produces the first screenshot of a working holder terminal, and it is
   achievable without any new daemon capability.
4. **Replace the misleading copy.** "Automatic terminal recovery failed. Retry
   manually or close the tab." describes a tmux window that died. Nothing died;
   the session is healthy and the app simply cannot draw it. A holder-aware
   message should say so, and Retry should not be offered for an action that
   cannot succeed.
5. **Build the key-send path.** Input is the difference between a viewer and a
   terminal. The daemon refuses `terminal.send` for holder rows today, so this
   needs both halves.
6. **Decide how resize is driven.** The daemon leg is done and correct. What is
   undecided is whether a holder pane's size follows the app's main area (which
   today requires the default-off `enableTerminalAutoResize`, and which this
   probe could not get to fire at all) or is driven by the render surface
   directly, the way SwiftTerm drives a tmux pane.

Items 1 through 4 are the ones a soak participant would notice. Items 5 and 6
are what separate a viewer from a terminal.

## Surprises

- **The daemon's refusal rails are considerably more complete than the summary
  implied.** `recreateWindow`, `attachCommand`, `send` and the in-place profile
  swap each refuse holder rows with their own named, tested message, and
  `isManuallyHibernatable` refuses in the shared model. The app being blind is
  survivable precisely because the daemon is not.
- **`terminal.output` already works end to end for a holder row.** Read-only
  rendering is much closer than "the app cannot render a holder-backed tab"
  suggests.
- **Resize already reaches the child process.** A real `SIGWINCH` with the
  right dimensions arrives at the job, which the tmux path achieves through an
  entirely different mechanism.
- **Everything outside the terminal pane already works.** Title, path, branch,
  tabs, Notes, Changes — the holder-backed worktree is a normal worktree to the
  rest of the app. The blast radius of Milestone B is one pane.
