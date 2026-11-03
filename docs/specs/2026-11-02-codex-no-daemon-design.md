# Codex tabs launch with `--no-daemon`

## Summary

TBD starts every Codex tab with `codex --no-daemon`. Codex then runs the tab's
hooks and tool commands inside the tab's own process tree, with the tab's own
environment, and never starts or joins Codex's shared background server. With
that guaranteed, the hook-caller guard treats a Codex tab like any other tab:
a hook RPC proven to come from outside a Codex tab is refused.

TBD supports only the current release of each agent CLI it launches, so it
passes the flag unconditionally. A Codex too old to know `--no-daemon` (before
0.156.0) stops at launch with its own error, and the fix is to update Codex.

## Background

The hook-caller guard (`docs/specs/2026-11-01-env-marker-attribution-design.md`,
"Part 2: checking hook callers by descent") checks that the process sending a
hook RPC descends from the job of the tab it names, using the socket's kernel
peer pid and one `KERN_PROC_ALL` read. It refuses only on proof.

Without `--no-daemon`, the guard cannot check a Codex tab by descent. Codex can
host sessions in a shared background server, and herdr's research
(herdrdev/herdr#4649, #4814) reports that this server runs hooks with the
environment of whichever pane started it. A Codex tab's own SessionStart can
then come from outside its tree, and the guard cannot tell it from a
stranger's.

## What Codex does

Measured on codex-cli 0.166.0 against a throwaway `CODEX_HOME`, a loopback
fake of the Responses API, and a hook that recorded only its own ancestry
(pid, ppid, command name) and a test marker set per tab. Each tab ran one turn
with one shell tool call and had SessionStart, PreToolUse and Stop hooks.

- **Plain `codex` starts the shared server itself.** The `daemon_auto_start`
  feature is stable and on by default. The TUI spawns
  `codex app-server --listen unix:// --managed-daemon`, with its control socket
  at `$CODEX_HOME/app-server-control/app-server-control.sock`, and copies its
  own binary under `$CODEX_HOME/packages/app-server-daemon/`. The server
  outlives the tab that started it and moves under launchd.
  `codex app-server daemon stop` stops the server but leaves its
  `pid-update-loop` process running.
- **In shared mode, hooks and tool commands run in the server, with the
  starting tab's environment.** A second tab's SessionStart, PreToolUse, tool
  command and Stop all ran as children of the server and carried the first
  tab's marker. While the first tab lives, the server is still its child, so
  the guard would accept those events as the first tab's. After the first tab
  exits, they come from a process under launchd and still name the first tab.
- **With `--no-daemon`, everything runs inside the tab.** Hooks and the tool
  command ran as children of the tab's own `codex`, with the tab's own marker,
  even while a shared server was running on the same `CODEX_HOME`.
- **TBD's other launch flags avoid the server too, by an unstated rule.**
  Codex's startup policy (`exclusion` in `codex-rs/tui/src/daemon_startup.rs`)
  runs embedded for `--no-daemon`, `--profile`, any `-c` override that is not a
  feature toggle, `--strict-config` and `--dangerously-bypass-hook-trust`. TBD
  passes `--profile tbd` and `--dangerously-bypass-hook-trust` on every launch.
  A launch with those flags printed "Running without the shared background
  server: --dangerously-bypass-hook-trust requires embedded mode", and its hooks
  ran inside the tab, with or without a server already running.

That last rule is Codex's implementation, not a promise, and Codex has been
narrowing it: openai/codex#46529 lets feature overrides use the shared server,
and #46498 lets worktree sessions use an existing one. `--no-daemon` is the
stated contract: "Explicit embedded launches never discover or start a daemon."
The flag first shipped in a stable release in 0.156.0 (openai/codex#46088).

By default, TBD runs Codex against the user's global `~/.codex` with a `tbd`
profile; `tbd terminal create --codex-home` gives one tab its own home. A shared
server there would also serve every Codex the user runs outside TBD.

## Design

### Launch

`CodexSpawnCommandBuilder` adds `--no-daemon` to the execution-mode flags every
TBD-launched Codex carries, beside `--dangerously-bypass-approvals-and-sandbox`
and `--dangerously-bypass-hook-trust`. Every path that launches Codex in a tab
builds its command there, so all of them get the flag:

- worktree create with a Codex primary tab;
- `terminal.create` of a Codex tab;
- continue-in-Codex;
- relaunching Codex in a tab whose window died;
- restoring Codex after a failed continue-in-Claude.

The flag precedes the `resume` subcommand, as `--disable` does; Codex parses it
there. TBD checks no Codex version for this flag and records nothing per tab:
the flag is part of every launch.

`CodexUsageFetcher` and `CodexSessionImporter` start `codex app-server --stdio`
themselves. They are servers, not TUIs, and `--no-daemon` does not apply.

### Guard

`HookCallerDescent` has no Codex exception, in the per-tab verdict or in the
per-worktree verdict for calls such as `pr.attach`, and `HookCallerUncertainty`
has no Codex case. A Codex tab anchors a walk by the same rules as any holder
row, and the answer is inside, proven foreign, or "can't tell" for one of the
other reasons.

A Codex tab running without the flag, started by an older TBD build, needs no
special case. On current Codex it already runs embedded, as measured above. A
Codex tab on the tmux transport cannot anchor a walk and stays "can't tell",
like any tmux row.

### Docs

- The env-marker spec's Part 2 says Codex tabs launch with `--no-daemon`, so
  their hooks run inside the tab and the guard treats them like any other tab.
  Its "can't tell" list names no Codex case.
- The doc comments on `HookCallerDescent` and on the execution-mode flags say
  why the flag is there.
- `CLAUDE.md` section "Support only the current agent CLIs" rules out version
  checks, `--help` probes and fallbacks for older releases of Claude Code or
  Codex.

## Why no flag

On Codex 0.166.0 TBD's other launch flags already make Codex run embedded, so
`--no-daemon` changes nothing a user can see. Checking Codex tabs by descent
applies the theory the guard already holds — a hook speaks for the tab it runs
in — to one more kind of tab, and the guard still refuses only on proof and
logs each refusal at `.info`. The env-marker spec ships the guard unflagged on
the same reasoning.

## Resources

The design creates no durable resource, and it closes a path to one: a TBD tab
never starts Codex's shared server, which would outlive the tab, install a
binary under the Codex home, and leave a `pid-update-loop` process behind.

## Failure modes

- **Codex older than 0.156.0.** Codex prints
  `error: unexpected argument '--no-daemon' found` and the tab's job exits. The
  user updates Codex.
- **A hook still running after its Codex died.** Its parent is gone, so it sits
  under launchd and reads as proven foreign. That costs the one event, as it
  does for a Claude tab.

## Testing

- **Command builder.** Every expected Codex command string carries
  `--no-daemon`, and a test checks that it precedes `resume`.
- **Descent.** A caller whose complete ancestry passes outside a Codex tab's
  job is `.provenForeign`, for the per-tab and per-worktree verdicts. A caller
  inside a Codex tab's job is `.inside`.
- **Handler.** A SessionStart for a Codex tab from a proven-foreign caller is
  refused: the tab's session ID and activity stay as they were, as for a
  Claude tab (`HookCallerGuardHandlerTests`).

## Rejected alternatives

- **Rely on the implicit rule and only drop the exemption.** No launch change,
  but the guard's soundness would rest on Codex's internal exclusion list, which
  Codex is narrowing release by release.
- **Add the flag only when `codex --help` lists it, and record per tab whether
  it was used.** Supports older Codex at the cost of a probe, a stored field
  that every launch path must keep true, and an exemption that survives for
  unrecorded tabs. TBD supports only the current agent CLIs.
- **Read the running job's argv for `--no-daemon`.** macOS hides the argv of
  Apple binaries such as `/bin/zsh`, and a tab's job can be that shell, so the
  answer would often be "can't tell".
- **Add the flag but keep the exemption.** Insurance without the benefit: the
  guard would still never refuse an event for a Codex tab.
