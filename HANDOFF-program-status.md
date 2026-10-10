# Handoff: Program Status Protocol (OSC 7501) — local verification

**Delete this file before merging.** It is a working note for the local agent
session that picks this branch up; the durable record is the spec.

- **Branch:** `claude/program-status-protocol-dwcqcg`
- **Spec:** [`docs/specs/2026-10-10-program-status-protocol-design.md`](docs/specs/2026-10-10-program-status-protocol-design.md)
- **Flag:** `program_status_enabled` (default off). Settings → Experimental.

## What was done, and where

The branch was written in a cloud container with no Swift toolchain. Every
build and test result below comes from GitHub CI (`Test` workflow, dispatched
by hand on this branch). Nothing has been run interactively: no app launch,
no real Claude Code session, no holder session.

Commits, oldest first:

- **Spec** – the design, plus the requirement that the probe is answered
  synchronously so the reply lands before the DA1 reply.
- **Parser** – `Sources/TBDShared/ProgramStatus.swift`: report types, parser,
  `ProgramStatusGate`, probe reply constant.
- **State model** – `.done`, `.error`, `.needsAuth` on `SessionStateValue`;
  `ProgramStatusBlock` on `AwaitingInputReason`; `FactSource.programStatus`.
- **Flag** – migration `20261010043448_config_program_status.sql` (no SQL
  default), `Config.programStatusEnabledDefault`, setter RPC, capability
  field, Settings toggle.
- **Store and roll-up** – `ProgramStatusRollup` (shared) and the daemon's
  `ProgramStatusStore` actor; `StateDelta.terminalProgramStatusChanged`.
- **RPCs and resolver** – `terminal.programStatusReport`,
  `terminal.programStatusList`; resolver rung below gone/parked/rate-limited.
- **Daemon reader** – `HolderEmulator` answers the probe from
  `registerOscHandler` and taps reports into the store; silent while a
  preamble replays.
- **App reader** – `TBDTerminalView` answers the probe synchronously and
  forwards reports via the `observeOscEvents` stream; silent during snapshot
  replay (`OscReplayMute`).
- **Liveness** – drops on child exit, park, wake (stale incarnation only) and
  flag off; a per-terminal drop watermark and generation reject reports that
  race a drop.
- **UI** – `.done`/`.error`/`.needsAuth` badges, background-task count, and a
  tooltip on the row's status badge listing title, msg, progress and tasks.

## CI status

CI_STATUS_PLACEHOLDER

## What only a local session can verify

Run these with a Claude Code build of v2.1.295 or later.

1. `scripts/restart.sh`, then confirm one `TBDDaemon` and one `TBDApp` from
   this worktree (see `CLAUDE.md`).
2. Turn on the pty-holder transport and **Settings → Experimental → "Read Claude's
   own session status (holder sessions)"**.
3. Start a new Claude session in a holder terminal. Confirm the protocol
   enabled: `log stream --level debug --predicate 'subsystem == "com.tbd.daemon" AND category == "programStatus"'`
   should show program-status reports being accepted. If nothing arrives, the
   probe was not answered in time — capture the session's first bytes and
   check that `ESC ] 7501 ; ?` precedes the DA1 query (`ESC [ c`) and that
   TBD's reply precedes the DA1 reply.
4. Walk the states and compare the sidebar row with what the session shows:
   - a running turn → working;
   - a tool permission prompt → awaiting input, the moment it appears, and
     back to working the moment it is answered;
   - a finished turn → the new "finished" badge, not plain idle;
   - `/logout` or a revoked token → needs-auth badge;
   - a background subagent still running after the parent's turn ends →
     working with a background count.
5. Hover the status badge: title, msg, progress and one line per background
   task.
6. Detach the app (close the panel) while Claude works, change its state,
   reattach: the row must reflect the change (the daemon reader saw it).
7. Kill the Claude process with `kill -9`: the row must fall back to hook
   state, not stay on its last OSC state.
8. Park and wake the terminal: no stale state survives the park; the woken
   session's first report is not dropped.
9. Turn the flag off: rows return to today's behavior immediately; new Claude
   sessions do not enable the protocol.
10. Check the new SF Symbols render (they fail silently if misspelled):
    search `RowStatusIndicator.swift` for the three new cases.
11. A tmux-transport terminal must look and behave exactly as on `main`.

## Known open questions

- **Partial entry writes.** The store replaces an entry whole on each
  report. If Claude Code sends only changed keys, `title`/`msg` will flicker
  to empty; switch to a key-wise merge.
- **Bare `clear` wipes task entries too.** If Claude Code does not re-send
  its tasks after restoring terminal modes, keep tasks on a bare clear.
- **Panels built before capabilities load** do not answer the probe, so a
  Claude started in that window runs without the protocol (accepted in the
  spec).
- **Drop watermark uses wall-clock time.** A backwards clock step would
  reject reports until the clock passes the watermark.
