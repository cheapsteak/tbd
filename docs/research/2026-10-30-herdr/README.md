# herdr: what TBD can learn from it

*Researched 2026-10-30. This is a read-only survey of herdr's source, with
its GitHub issues, pull requests, discussions and changelogs. One claim was
checked by direct measurement on a macOS 27 development machine; it is marked
as measured. This file is the index and the synthesis. The five reports below
hold the evidence and the citations.*

Commits studied:

- `herdrdev/herdr` ee5bfb50 (2026-10-29)
- `herdrdev/herdr-core` 9edb39d (2026-10-30)
- `herdrdev/herdr-app` 8180cbe (2026-10-30)
- `herdrdev/herdr-layout-examples` ed4eda7 (2026-10-30)
- `herdrdev/herdr-nix` 602c885 (2026-10-14)

Reports in this folder:

- **[`api.md`](api.md)** – the socket API: wire format, schema and
  versioning, events and subscriptions, `wait`, errors, and the CLI as an API
  client.
- **[`identity.md`](identity.md)** – how herdr identifies panes and the
  processes in them, how it detects which agent runs and what state it is in,
  and the macOS process-environment measurement.
- **[`runtime.md`](runtime.md)** – the server and holder process model,
  live upgrade, persistence and restore, the libghostty terminal engine, the
  render protocol, and remote machines.
- **[`extensibility.md`](extensibility.md)** – plugins, the marketplace,
  the third-party ecosystem, the split into herdr-core and herdr-app, mods and
  layouts.
- **[`history.md`](history.md)** – the release timeline, the biggest PRs,
  the most-discussed issues, rejected requests, the workspace and worktree
  model, and notifications.
- **[`procenv_probe.py`](procenv_probe.py)** – the read-only probe used for
  the environment measurement.

## What herdr is

herdr is an open-source Rust "runtime your coding agents live on". It shipped
56 releases in about 200 days. Three products now share the name:

- **herdr (v1)** – a terminal UI with one background server. The server
  owns every pty and does all the screen work, so when it dies, every pane
  dies.
- **herdr-core (`hc`)** – a headless runtime that "draws nothing". A holder
  process per build owns the terminals and restarts a crashed core. Its design
  is close to TBD's per-session pty-holder.
- **herdr-app** – a desktop client. Each pane runs its own libghostty-vt
  emulator, and most of the UI is user-editable JavaScript "mods" and JSON
  layouts. It has no plugin system.

herdr-core and herdr-app ("Herdr 2") became public on 2026-10-23. They are
rewrites, not refactors of v1.

## The socket API

herdr has two socket APIs, and the second exists because the first went
wrong.

- **herdr v1** sends one JSON object per line over a Unix socket. It is not
  JSON-RPC 2.0. Requests are `{id, method, params}`, errors are
  `{code: string, message}`, and each connection carries one request.
  Subscriptions and `wait` poll every 100 ms. The CLI refuses to run if the
  server's protocol number differs from its own.
  - The tracker records the cost: silently dropped events (#4178), about
    100 ms per request (#4572), idle CPU up about 12× with two subscribers
    (#5194), and protocol bumps that broke clients (#2276).
- **herdr-core** speaks JSON-RPC 2.0.
  - Its OpenRPC schema is generated from one method table.
  - A CI test fails any change that would break a client of the last release.
  - Each event carries a sequence number. A heartbeat comes every 15 s. A
    subscriber that falls behind gets a fresh snapshot instead of silent gaps.
  - `wait` reacts to events instead of polling. A timeout returns a normal
    "still running, wait again" result, not an error.
  - Errors carry a stable `kind` and a hint, and each kind maps to a fixed CLI
    exit code.

## How herdr identifies sessions and processes

The "random token in the environment, then find the processes that inherit
it" design is real, but it lives in herdr-core, not in herdr v1.

- **herdr-core** gives each program run a token,
  `HC_SCOPE=<monotonic-time>-<random>`, and saves it on the terminal's record.
  To find a terminal's processes it reads the environment of every process,
  keeps those that carry the token and started after it, then adds their child
  processes. The second step catches shells whose environment macOS hides. It
  uses this for one job only: killing everything a terminal started, after a
  holder dies or a crash.
- **herdr v1** finds a pane's processes through the pty's foreground process
  group. It mints a token only on Windows, for Git Bash. `HERDR_PANE_ID` works
  the other way round: the agent's hook reads it from its own environment and
  tells herdr which pane it is in.

**Measured on one macOS 27 machine: macOS does let a process read another
process's environment, with exceptions.** `sysctl(KERN_PROCARGS2)`, the call
`ps eww` uses, returned the environment a process had when it started for most
same-user processes. Every Apple platform binary tested returned none.

- **Readable:** `claude`, `node`, `pnpm`, and most binaries under `~`,
  `/opt/homebrew` and `/nix/store`. A TBD-spawned `claude` exposed
  `TBD_TERMINAL_ID` and `TBD_WORKTREE_ID`, despite its hardened-runtime
  signing.
- **Hidden, Apple:** `/bin/zsh`, `/bin/sleep`, `/usr/bin/perl` and anything
  under `/System` return their arguments but no environment.
- **Hidden, not Apple:** Dia, Chrome and Postgres.app also returned none.
  Postgres rewrites its argument and environment area to set its process
  title, which would explain its case. Why the Chromium-based apps return none
  was not established.
- **Other users:** their processes fail with EINVAL.
- **Escapees:** a process that escaped with `setsid` plus a double fork was
  found by its token alone. A full scan of about 945 processes took 33–150 ms
  from Python.

## Findings about TBD

Comparing the two code bases turned up three problems in TBD. Each came from
reading code and still needs a live reproduction.

- **Archive from the app can delete uncommitted work without asking.** The
  uncommitted-changes check exists only in the CLI
  (`Sources/TBDCLI/Commands/WorktreeCommands.swift`, `ArchiveUncommittedCheck`).
  The app's menu item and shortcut call the daemon directly, and the daemon
  runs `git worktree remove --force` with no such check. Auto-archive on merge
  takes the same path. herdr asks before it forces a removal.
- **No banner while TBD is in the background and the worktree is
  "visible".** `handleNotificationDelta` (`Sources/TBDApp/AppState.swift`)
  returns early for a selected or pinned worktree without checking whether the
  app is frontmost. So an agent that finishes while the user is in another app
  gives no banner and no sound. herdr fixed the same bug in 0.5.3, and its
  most-upvoted notification discussion (#864) describes it.
- **Several TBD docs and comments say macOS cannot read another process's
  environment.** The measurement above shows that holds for Apple binaries
  and a few others, not for agents and most dev tools. The claim appears in `docs/specs/2026-08-18-orphan-process-gc-design.md`
  (a rejected alternative), `docs/tmux-dependencies.md`, and comments in
  `TmuxManager.swift` and `PeerHelperOptions.swift`. The original test used
  `/bin/sleep`, one of the hidden cases.

## Ideas worth a spec

Each of these changes behaviour, so each needs a brainstormed spec before
anyone builds it. They are ordered by expected value to TBD.

1. **Save screens on a planned daemon restart.** Today `tbd update` and
   `restart.sh` bring detached sessions back with empty screens. herdr-core
   writes each screen to disk on SIGTERM and restores it in the next process.
   TBD can do this more simply: the kernel buffers the bytes between the old
   and new daemon, and `TerminalSnapshotWriter`'s format survives SwiftTerm
   upgrades. Read each snapshot only once; herdr #453 crash-looped on a
   replayed poison screen. See [`runtime.md`](runtime.md).
2. **Use an environment token as extra evidence for escaped processes.** Now
   that the measurement shows agents' environments are readable, OrphanGC's
   escaped-process work could match `TBD_WORKTREE_ID` in the environment. But
   the environment records where a process came from, not who owns it now:
   `dirmngr` and Claude Code's own `claude daemon run` / `--bg-pty-host`
   inherit arbitrary worktree ids. A token match must never be the only reason
   to kill a process. This needs a default-off flag. See
   [`identity.md`](identity.md).
3. **Make the RPC contract safe to evolve.** Publish the daemon's method list,
   give "unknown method" a distinct error code so the CLI and app can name a
   stale daemon instead of string-matching, and add a CI check that the
   contract only grows, modelled on herdr-core's compatibility test. Decide up
   front whether CLI `--json` output is part of that contract (herdr-core
   #33). See [`api.md`](api.md).
4. **Sequence `state.subscribe`, then build on it.** Add a per-boot id, a
   sequence number on each delta, a heartbeat, and a capped writer that says
   "you missed events" instead of buffering forever. On top of that:
   - a `tbd events` command for scripts;
   - a `tbd terminal wait` built on the OSC 7501 status TBD already has.
5. **Freeze the holder protocol's wire bytes in tests.** The holder protocol
   tests round-trip through the same code, so a renamed enum case would pass
   them and still silently break older holders that are still running. herdr
   freezes fixtures, and herdr-core's CI upgrades from the last release.
6. **Stable error kinds and CLI exit codes.** TBD has many error sites and few
   codes. herdr-core maps each error kind to one exit code.
7. **Small user-land surfaces.** All of these fit "compile only what
   user-land cannot do well":
   - short text values that scripts can put on sidebar rows;
   - user scripts that appear in Cmd-K and right-click menus, with the
     current worktree and terminal passed in;
   - a generated, test-checked guide to every file a user or agent can edit.
   See [`extensibility.md`](extensibility.md).
8. **Worktree options users asked herdr for.** See [`history.md`](history.md).
   - Expose the per-repo worktree location: `Repo.worktreeRoot` exists, but
     only tests set it. This was herdr's most-reacted worktree issue (#261).
   - A `--base` ref on `tbd worktree create`, for stacked PRs.
   - A sticky "Mark unread" and a short focus delay before auto-marking read.
9. **Product questions for a human.** These were the two biggest plugin
   categories in herdr's ecosystem, and TBD has neither:
   - phone or remote control of agents (the top plugin had about 1.7k stars);
   - diff review that sends comments back to the agent (about 959 stars).

## Risks to test

Each of these comes from a herdr issue, and none has been checked against
TBD.

- **Quitting an app may kill its agents.** In herdr #4920, quitting the
  terminal app sent SIGTERM to every process in its launchd coalition, and
  coalition membership survives `fork` and `setsid`. TBD's daemon starts from
  whatever shell runs `restart.sh`, or from TBD.app. If TBD is affected, the
  agents die directly and the holders do not help.
- **Agents may lose Local Network access.** In herdr #808, non-Apple binaries
  under a detached daemon got `EHOSTUNREACH` to LAN hosts. TBD's Info.plist
  has no `NSLocalNetworkUsageDescription`. A daemon that launchd starts from
  inside the signed TBD.app might fix this risk and the previous one, and
  would also give crash restart.
- **Codex hooks may report to the wrong pane.** Codex's shared app-server
  makes herdr's hooks report to the wrong pane (#4649). TBD's Codex hooks
  read `$TBD_TERMINAL_ID` from the environment, so the same could happen.
- **Hook events from inherited environments.** Claude Code's background
  daemons inherit the `TBD_TERMINAL_ID` of a terminal that may still exist.
  herdr's #2012 is this bug, and it is still open. TBD's socket layer
  captures the caller's pid, but the `terminalSessionEvent` route does not
  pass it to `handleTerminalSessionEvent`, which checks cwd and incarnation
  only. So an inherited environment could attribute a hook to another live
  terminal. Whether TBD's hooks fire inside those daemons is not verified.

## Claude hook gaps worth turning into tests

herdr reported agent state from Claude Code hooks first, then dropped them on
2026-06-02 because of gaps. Each gap is a regression test TBD could add:

- an Esc interrupt fires `StopFailure`, not `Stop` (#125);
- no hook fires after a rejected permission prompt (#349);
- a late `PostToolUse` sets the state back to "working" (#198);
- subagent events carry an `agent_id` and must not change the parent's state.

## What not to copy

- **Screen-scraping for agent state.** herdr v1's working, idle and blocked
  states come from regex rules over the rendered pane, updated from herdr.dev
  every 30 minutes. About 390 issue titles are wrongly detected states, 168 of
  them for Claude alone, many caused by Claude Code changing its spinner
  glyphs. Herdr 2 bans screen detection: status comes only from OSC 7501.
  This supports TBD's no-TUI-scraping rule.
- **A plugin manifest or marketplace.** About 2,000 plugins appeared in 4.5
  months; 841 repos have zero stars and many look machine-generated.
  herdr-app dropped plugins entirely.
- **An in-app scripted UI.** herdr-app's mods suit a product whose whole UI is
  user-editable; TBD's native SwiftUI app is not built that way.
- **herdr v1's exact-match protocol numbers.** Any version mismatch stops the
  CLI, and bumps broke clients.
- **herdr-core's "JSON whenever output is piped" default.** It would break
  TBD scripts such as `tbd link | pbcopy`.

## Where TBD is already ahead

- A holder per session, not one server for every pane.
- No extra processes on the attached keystroke path.
- No handing terminals between daemons during an upgrade.
- Exit status is always known.
- The daemon reads the caller's pid on the Unix socket and records who made
  each request.
- A person's half-typed draft is saved through Claude Code's own API. herdr's
  maintainer calls that problem unsolved.
- Users asked herdr for worktree features that TBD already has, and herdr
  refused them all:
  - an archive hook that runs before `git worktree remove` (#3849);
  - cleanup of checkouts whose workspace was closed (#4317);
  - adoption of worktrees an agent created with plain `git worktree add`
    (#2981);
  - deletion that does not freeze the UI (#1428).

## The libghostty question

Nothing here changes TBD's "not yet" decision
([`../2026-10-28-terminal-engine-libghostty.md`](../2026-10-28-terminal-engine-libghostty.md)).

- In 2026, herdr v1 bumped its vendored libghostty four times. One bump was a
  109k-line upgrade with "no blanket speedup", and v1 still carries five
  patches, one of them a server-crash fix.
- herdr-core and herdr-app run upstream unpatched with small bindings. That
  fits TBD's trigger of waiting for libghostty 1.0.
- herdr-app's renderer is about 3,750 lines of Rust. There is still no
  first-party Swift renderer.
- herdr #5017 found that most of its input bugs came from mismatched key
  encoders, and it unified on libghostty's encoder. That is a separate argument
  from rendering.
