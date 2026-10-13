# Dev servers: repo-declared, TBD-run, file-reported

A repo often runs several long-lived local servers while someone works on it: a
web app, a backend API, Storybook. TBD runs many worktrees of the same repo at
once, so the same servers may be up in several worktrees at the same time. This
document defines how a repo declares its servers, how a running server tells TBD
where it can be reached, and what TBD does with that: start, stop and report
servers from the `tbd` CLI, show which worktrees have something running, and
open a running server in the browser.

## Principles

- **The repo owns ports.** TBD never allocates, assigns or probes a port. A repo
  that wants several worktrees running at once picks free ports itself, by any
  scheme it likes.
- **The repo reports what is running.** A running server's URLs reach TBD only
  through a file the repo writes (the *running file*, below). TBD never infers a
  URL from a listening socket, because the scheme and host matter (`https`,
  custom hostnames routed by `Host` header) and a guessed URL is a wrong button.
- **TBD runs servers by default; the repo can take over.** TBD starts a declared
  command in a terminal tab and stops it by signalling its process group. A
  repo whose servers TBD cannot stop that way (Docker, an external supervisor)
  declares its own `stop` and `status` commands.
- **No process scanning.** TBD learns about a server only from its own tabs, the
  repo's `status` command, and running files. A server nobody declared and that
  wrote no running file is invisible to TBD, by design: the contract is the
  file, and a scan would be a second, unreliable contract.
- **Nothing starts on its own.** Every start is a gesture: a click, or a `tbd
  server start` from a person or an agent.
- **Unattended stops touch only what TBD started.** Archive, which can run
  with no gesture, stops servers running in TBD's own tabs and nothing else;
  the repo's archive hook tears down the rest.

## Declaring servers

### Sources and layering

TBD reads three sources, each fresh from the worktree being acted on — never
from the main checkout and never from a cached path:

1. **`.claude/launch.json`** in the worktree, if present.
2. **`tbd.toml`** at the worktree root, committed by the repo. (`.tbd/` is not
   used: it is the legacy worktree location and is gitignored.)
3. **`~/tbd/repos/<repoID>/servers.toml`**, the user's personal file, for repos
   they cannot or do not want to commit to. The path helper lives in
   `TBDConstants` beside `hookPath` and honors `TBD_HOME`, per the per-repo file
   pattern.

Sources layer **by server name**: a server in a later source replaces the
same-named server from an earlier source as a whole (no field-level merge);
servers with other names are kept from every source. The result is the
worktree's *declared servers*.

A source that fails to parse is reported — in `tbd server list` and at the
bottom of the toolbar menu, naming the file and the error — and contributes
nothing. It never hides servers from the other sources.

### `tbd.toml` and `servers.toml`

Both use the same format:

```toml
[servers.web]
command = "pnpm dev"             # required; run with `sh -c`
cwd = "apps/web"                 # optional; relative to the worktree root
env = { FEATURE_X = "1" }        # optional; committed, so never secrets
label = "Web app"                # optional display name; defaults to the key

[servers.storybook]
command = "pnpm storybook"

[servers.localstack]
command = "docker compose up localstack"
stop = "docker compose stop localstack"    # optional; replaces the group kill
status = "scripts/dev/localstack-status"   # optional; exit 0 = running
```

- **`command`** is required. Everything else is optional.
- **`cwd`** must be relative and stay inside the worktree; an absolute `cwd`,
  or one that escapes the root through `..`, is a parse error for that server.
- **`stop`** and **`status`** are shell commands run with `sh -c` in the
  server's `cwd`. `status` answers only *running or not*, by exit code, within
  5 seconds; `stop` has 60 seconds. URLs come only from the running file, so
  `status` and the file can never disagree. Both run with the daemon's `PATH`
  plus the common package-manager directories appended (`~/.local/bin`,
  Homebrew, `/usr/local/bin` and the like), because a daemon relaunched by
  LaunchServices can inherit launchd's bare `PATH`. Both are repo-authored
  shell that a branch can change, so they run only on a user gesture: archive,
  which can fire with no click, runs neither (see "On archive").
- **`env`** keys must be shell identifiers (`[A-Za-z_][A-Za-z0-9_]*`); any
  other key is a parse error naming it, and that key is dropped.
- Server names are the TOML keys: lowercase letters, digits and `-`.
- Unknown keys are ignored, so later versions can add fields without breaking
  older TBD builds.

There are deliberately no `port`, `url`, `dependsOn` or `autostart` fields.
Ports and URLs belong to the running file; ordering and autostart are out of
scope (see "Not in this version").

### Reading `.claude/launch.json`

Many repos already carry this file for Claude Code desktop's preview. Each entry
of `configurations[]` becomes a declared server:

- `name` → the server name, as a slug: lowercased, every run of characters
  outside `a-z0-9` collapsed to one `-`, leading and trailing `-` trimmed. The
  original `name` becomes the `label`, so "Web App" is the server `web-app`
  shown as "Web App". An entry whose slug is empty is a parse error.
- `command` is built in VS Code's order: the runtime (`runtimeExecutable`,
  else `node`), `runtimeArgs`, `program` (when present), then `args`, each
  argument shell-quoted. An entry with neither `runtimeExecutable` nor
  `program` is a parse error.
- `cwd` and `env` carry over; `${workspaceFolder}` resolves to the worktree root.
  `env` keys follow the same identifier rule as in `tbd.toml`.
- `port`, `url` and `autoPort` are ignored: the repo owns ports and reports URLs
  through the running file.

The file is JSON with comments and trailing commas, as VS Code writes it; TBD
strips both before decoding.

Declared servers keep the order in which their names first appear across the
three sources — within a TOML file, the order of its `[servers.<name>]`
sections — and a server replaced by a later source keeps its original
position.

## The running file

The running file is how a server tells TBD it is up and where it can be
reached. Any process may write one — a server TBD started, one an agent started
with `pnpm dev &`, or one started in an unrelated terminal — so it is the single
way TBD sees servers it did not start.

### Location

`~/.local/state/dev-servers/`, overridden by the `DEV_SERVERS_DIR` environment
variable. The directory and the format are deliberately not TBD-branded: any
tool can read or write them.

The directory lives outside the worktree on purpose. A file inside the worktree
— or inside git's per-worktree directory, which `git worktree remove` and `git
worktree prune` delete — vanishes with the worktree while the server it
describes may keep running, and then nothing knows the server exists. Field
measurement on a large monorepo found two of five orphaned dev servers running
with a working directory that had already been deleted.

### Format

One JSON file per running server, with any file name ending in `.json`:

```json
{
  "version": 1,
  "root": "/Users/me/tbd/worktrees/acme/fix-login",
  "server": "web",
  "endpoints": [
    { "name": "app", "url": "https://localhost:24123" },
    { "name": "api", "url": "http://localhost:8004/api" }
  ],
  "pid": 81234,
  "startTime": 1760190000
}
```

- **`version`** – `1`. A file with a higher major version is ignored.
- **`root`** – the absolute worktree path. This is how TBD attributes the file
  to a worktree. A file whose `root` matches no known worktree is not shown.
- **`server`** – the server name. If it matches a declared server, the file
  reports that server's state; otherwise the server is shown as *undeclared*,
  with its URLs and a Stop item. A server TBD started whose declaration has
  since been removed is likewise shown as undeclared for as long as its tab
  exists, with the tab's state, and is stopped like any other: a signal to its
  tab's process group, since no declared `stop` remains.
- **`endpoints`** – one or more named, absolute URLs. The first is the server's
  main URL. Full URLs rather than ports, because scheme and host matter.
- **`pid`** and **`startTime`** – the server process and its start time in Unix
  seconds. Both are required. TBD derives the process group from `pid`; the
  writer does not report it.

Writers write atomically (temp file in the same directory, then rename) and
should delete their file when the server exits cleanly. Readers ignore unknown
fields. **A running file never contains a command**, and TBD never executes
anything read from one: stop behavior comes only from declarations, which are
committed or written by the user.

### Liveness

A running file is **live** when a process with `pid` exists, is not a zombie,
and its start time (read from the kernel) matches `startTime` within one
second. Any other file is **stale** and ignored. The start-time check is what
makes a reused pid harmless, and it keeps the record correct even when the
writer was SIGKILLed and never cleaned up — no heartbeat is needed.

`pid` must be the server, not a launcher. A launcher that backgrounds the
server and exits leaves a file that reads stale while the server runs.

### Helpers for writers

- Servers TBD starts receive `DEV_SERVER_NAME` and `DEV_SERVERS_DIR` in their
  environment, alongside the usual `TBD_WORKTREE_ID`, `TBD_WORKTREE_PATH` and
  related variables.
- `tbd server report <name> --pid <pid> --url <url> [--url <name>=<url>…]`
  writes a correct file (reading `startTime` from the kernel, `root` from the
  worktree) with one line in a start script. `--pid` is required, so the caller
  names the server process deliberately rather than inheriting a launcher's:
  Stop and Restart signal the pid a running file names (its group when it
  leads one), checked only against the start time the file recorded. TBD
  cannot tell whether that pid is really the server, so a file naming some
  other live process gets that process signalled when someone stops the
  server. Archive never signals it (see "On archive").
  `--url <name>=<url>` names an endpoint; an unnamed `--url` is called `main`,
  and further unnamed ones `main-2`, `main-3`.
- `tbd server report <name> --clear` deletes it.

The file format is the contract; the helper is a convenience. A repo that does
not want a dependency on the `tbd` binary writes the JSON itself.

## How TBD runs servers

### Starting

`tbd server start [name…]`, the toolbar's Start items, and "Start all" (all
declared servers, started side by side) do the same thing per server:

- TBD opens a terminal tab titled with the server's label, running `exec
  /bin/sh -c '<command>'` in `cwd` with `env` applied. The `exec` makes the
  command the tab's own process, so it leads the tab's process group, a group
  signal reaches every child, and the command's exit status is the tab's.
- The exit status is read from the terminal transport, never from a wrapper
  around the command: tmux's `#{pane_dead_status}`, or the holder's report of
  its child's exit.
- On the tmux transport TBD sets `remain-on-exit` on the server's window in
  the same tmux invocation that creates it (`new-window … ; set-option -w
  remain-on-exit on`), so the pane outlives the command — however fast it
  dies — and keeps its final screen and its exit status. tmux runs one
  invocation's commands back to back, before its event loop can reap the
  pane; a respawned exited tab keeps the option it was created with.
- On the holder transport the tab does not keep a dead screen, so TBD saves
  the server's final output instead (see "Exited servers keep their last
  output").
- The terminal row records the server's name in a new nullable `server_name`
  column on `terminal`, linking tab to server. That is a migration plus the GRDB
  record plus `Terminal` in `TBDShared/Models.swift`, in one commit.
- Starting a server that is already running does nothing and says so. A
  server that reads *Unknown* is not started, since its command may still be
  running: one whose tab's state cannot be read — a tmux query that timed out
  or failed without saying the pane is gone — fails and says to try again,
  and one whose `status` command timed out fails with "state unknown (status
  command timed out); try again or stop it first". Neither opens a second
  tab. A server
  whose tmux tab exited is started again in that same tab, so tabs do not pile
  up; a holder session cannot be respawned, so its exited tab is closed and a
  new one opened.

### State

Each server's state is derived, in this order:

1. **Running, with URLs** – a live running file for this worktree and server.
2. **Running** – the server's `status` command exits 0, or TBD's tab for it is
   still running the command. No open button: no URL has been reported.
3. **Exited (code N)** – the command TBD last started for it ended: its tab
   still shows the ended command, or its saved last output records the exit.
   The code is omitted when the transport could not observe it.
4. **Unknown** – TBD's tab for it could not be read (a tmux query that timed
   out or failed without tmux saying the pane is gone), or the `status`
   command timed out, and nothing above applies. Only tmux's own answer that
   the pane or its server is absent makes a tab gone. When the worktree's tab
   rows cannot be read from the database at all, every server not shown
   running by a live file or its `status` command reads *Unknown* — not
   *Stopped*, and not an *Exited* taken from a saved output, since TBD cannot
   tell whether a tab still runs it — and a start or stop fails with "try
   again" as for an unreadable tab.
5. **Stopped** – none of the above.

`status` commands run with a 5-second timeout, and only on a user's explicit
request: by `tbd server list` and `tbd server status`, and in the app after
every Start, Stop or Restart it issues and when someone picks "Refresh status"
in the Servers menu. A `status` command is repo-authored shell, and a branch
can change it, so merely looking at a worktree must not run it: the app's
automatic refreshes — when a single worktree becomes selected, and when the
daemon reports a dev-server change for it — fetch the list without `status`
commands. They never run on a timer, never for the sidebar dot, and never
during archive, which can happen with no click at all (see "On archive").

Between those requests the app shows the answers of the last run in the app.
In each server it lists, the daemon marks whether the `status` command decided
the state — it exited 0 (running) or timed out (unknown) and nothing ranked
above it — and whether the declaration has a `status` command at all. It also
reports the server's TBD tab whenever that tab has ended, whatever decided the
state: the tab's id (or, once the tab's row is gone, the id its saved last
output carries) and, on tmux, the process the dead pane ran. Starting a server
whose tmux tab has exited respawns that tab in place under the same id, so the
process id is what tells one run of the tab from the next. The app remembers
each answer the `status` command decided, together with the server's ended tab
at that moment, if it had one, and lays it over a list fetched without
`status` commands in two cases:

- **Stopped** – the server is known only through its `status` command, which
  that list did not run.
- **Exited, same run** – the server's TBD tab has ended, and its ended run is
  the one the remembered answer saw: the same tab and, on tmux, the same
  process. This is a command that detaches: `docker compose up -d db` exits at
  once and its tab reads exited, while `docker compose ps db` keeps answering
  running. A tab that was still running when the answer came and has ended
  since, an exited tab from a later start, and a respawn of the same tab that
  exited again are new facts and win.

Every other state comes from a running file or a running or unreadable TBD tab,
which are read on every refresh and always win. Each run replaces what the app
remembers for the worktree; a run that fails replaces nothing, and an older run
that answers after a newer one has answered is discarded. The app drops a
remembered answer once the newest list no longer has that server or its
declaration no longer has a `status` command, and drops everything it holds for
a worktree when the worktree leaves the app: archived, gone from the daemon's
worktree list, or removed with its repo. A refresh still in flight when that
happens writes nothing back. A server
whose `status` command has not run in the app since it launched reads stopped,
or exited by its tab, until someone starts, stops, restarts or refreshes it.
The remembered answers live in the app's memory only, so a stop from the CLI of
a server whose state its `status` command decided — one known only through
that command, or one TBD started whose command detached — shows in the app at
its next `status` run.

TBD watches the running-file directory for changes and every 10 seconds
re-checks the liveness of known running files and of its own server tabs, so a
server that died without cleaning up, or whose tab's command ended, drops out
of the sidebar dot. The re-check timer takes an injected clock.

### Exited servers keep their last output

A crashed server's last screen is usually the only explanation of the crash,
so an exited server's output stays readable:

- **tmux** – the dead pane is the record. Its screen and `#{pane_dead_status}`
  remain until the tab is closed or the server is started again.
- **holder** – when a server tab's child exits, the daemon saves the session's
  final screen and scrollback into Closed Terminals history (the store archive
  and tab close already write) before the holder registry releases the
  session's emulator, and records the exit code and server name on that
  history entry. The holder transport's release behavior is unchanged: the
  save happens in the step before the release, which always follows. Because
  the entry lives in the database, the exit code survives a daemon restart —
  including the reconcile that removes the ended holder tab.

The server's state reads *Exited* from the newest saved entry for its name
until it is started again or stopped; either detaches the entry from the
server, and the output stays in Closed Terminals as an ordinary entry. An exit
caused by a stop is never recorded as the server's last output: the save
applies only while the server's tab still exists, and a stop closes the tab
before it clears the server's entries.

The toolbar menu offers **Show last output** for an exited server. On the
holder transport it opens the saved entry in Session History's Closed
Terminals viewer; on tmux it focuses the server's tab, where the dead pane
shows the output.

### Stopping

`tbd server stop [name…]`, the Stop items and "Stop all" do, per server:

- If the server declares `stop`, run it, with a 60-second budget. A `stop`
  that exits non-zero or runs out of time is a failed stop; TBD does not fall
  back to signalling.
- Otherwise, signal the server's process — TBD's tab process, or the live
  running file's `pid`: SIGTERM, then SIGKILL after 5 seconds. The grace runs
  to the end even when the request that started the stop is cancelled, and a
  group whose only remaining members are zombies counts as gone. Before
  signalling, re-verify the pid's identity: a running file's pid against the
  start time it recorded; a tab's pid is read from the tab again at stop time.
  A tmux pane's start time is taken from the kernel at that moment. A holder
  tab's job is verified against the start time its terminal row recorded for
  that pid; a job with none recorded — whether or not the daemon has adopted
  the session — cannot be told apart from a reused pid, so it is reported as a
  failed stop and not signalled, and closing the tab ends it.
- The whole process group is signalled only when the pid leads it
  (`getpgid(pid) == pid`). Otherwise only the pid itself is signalled, and the
  stop report says so: a server started with `pnpm dev &` from a shell without
  job control shares that shell's group, which may be an agent's session or
  TBD's own, and only a group leader's group is the server's alone. TBD never
  signals its own pid or a group it leads. A server whose children must stop
  with it should lead its own group (`setsid`, or `set -m` in a start script)
  or declare `stop`; TBD's own tab process always leads its group.
- A server that reads running only through its `status` command — no running
  tab, no live running file — and declares no `stop` gives TBD nothing to
  signal. Stopping it is a failed stop that says to declare a `stop` command.
- Close the server's tab, capturing its scrollback the way archive does, delete
  its running file once the process the file names is gone, and detach its
  saved last output. A declared `stop` that exits 0 proves nothing about that
  process — it may only ask a supervisor to stop it — so a file whose process
  is still alive is kept, the server keeps reading running, and the
  stale-file sweep removes the file once the process exits.

Stop on an exited server closes its tab and clears its *Exited* state; it
neither signals anything nor runs a declared `stop`, since nothing is running
to stop. Stop on a server whose tab's state cannot be read fails and says to
try again, without signalling, running `stop` or closing the tab.

A start, and a stop of named servers, run only those servers' `status`
commands.
`restart` is stop, then start; a server with no declaration has nothing to
start it from, so a restart stops it and leaves it stopped. Pressing Ctrl+C in a server's tab is not a stop
through TBD: the command exits on its own, so the tab stays open and the server
reads *Exited*.

### On archive

Archive stops only the servers TBD started in its own tabs. It never runs a
declared `status` or `stop` command, and it never signals a pid because a
running file names it. Two facts decide this:

- **Archive can run with no user gesture.** Auto-archive fires when a pull
  request merges, and reconcile archives a worktree whose checkout has
  vanished. A declared `stop` or `status` is repo shell that a branch can
  change, so running it there would run a branch's code without anyone
  clicking anything.
- **Anything can write a running file.** Any process running as the user can
  write one naming any pid — the repo's tmux server, another worktree's
  shell. The start-time check stops a reused pid from being hit, but not a
  file that names the wrong live process on purpose or by mistake. A stop
  someone asks for accepts that risk; an unattended archive does not.

So archive does this, per server that reads running or *Unknown*:

- **A TBD tab still running the command, or whose state cannot be read** –
  its process group gets SIGTERM, then SIGKILL after 5 seconds, under the
  group-kill rules in "Stopping". A tab pid that cannot be verified — a holder
  job with no recorded start time — or a tab whose state cannot be read is not
  signalled; the tab teardown that follows ends it.
- **A server with both a TBD tab and a running file** is stopped through its
  tab only. The pid the running file names is not signalled, even when it is
  not the tab's job; if it is in the tab's process group, the group kill ends
  it anyway. The file is deleted once the pid it names is gone, and kept
  otherwise.
- **A server known only through a running file, or only through its `status`
  command** – nothing is signalled and no command runs. Archive logs it as
  left running. Its running file stays; the OrphanGC leg deletes it once the
  process is gone.

That holds whether or not the server declares `stop`. Signalling a tab's group
is safe where signalling a running file's pid is not: TBD spawned that
process itself, it leads its own group, and its pid comes from tmux or from
the holder's recorded start time rather than from a file anyone could write.

Archive does this in its first phase, right after the worktree's status flips
to archived — so a concurrent `server start` is refused — and before its tabs
are torn down, so group kills reach live tab processes. This happens before
the archive hook runs, and on forced archives too. A server that fails to stop
is logged and the archive continues; the tab teardown still ends what TBD
started. Once the tabs' rows are deleted, archive detaches every server's
saved last output, so no exit — including the one its own stop caused — leaves
a server reading *Exited* after a revive.

Reconcile's archive of a worktree whose checkout has vanished takes the same
two steps in the same order — stopping tab servers before its tab teardown
and detaching saved outputs once the tabs' rows are deleted.

#### Teardown belongs in the archive hook

Teardown for servers TBD did not start in a tab — a `docker compose` stack, a
server known only through a running file, one TBD started whose command
detached — belongs in the repo's archive hook (`.worktree-hooks/archive`, or
the per-repo hook under `~/tbd/repos/<repoID>/hooks/`; see
[`docs/worktree-hooks.md`](../worktree-hooks.md)). The order is: TBD stops its
tab servers, then the hook runs, then the worktree's directory is removed. A
forced archive skips the hook. The hook should be idempotent, because a
server may already be stopped. `tbd server stop` from the hook is a stop like
any other: it runs declared `stop` commands and signals running-file pids,
because the repo chose to run it.

## CLI

`tbd server` is a new command group. Every command takes `--worktree`
(defaulting to `TBD_WORKTREE_ID`, then the current directory) and `--json`.

- **`list`** – every declared or reported server: state, URLs, and the source
  that declared it; plus any source that failed to parse.
- **`start [name…]`** – no name starts all declared servers. Prints each tab's
  terminal ID.
- **`stop [name…]`** – no name stops all.
- **`restart [name…]`** – no name restarts every running server: it stops
  them, then starts exactly the declared ones among them; an undeclared one
  is stopped and reported as not started again. When none is running it says
  so and starts nothing.
- **`status <name>`** – exits 0 when the server is running and prints its URLs,
  so a script or an agent can wait on it.
- **`open [name] [--endpoint <name>]`** – opens the main URL, or a named
  endpoint, in the default browser. Fails with a clear message when no URL has
  been reported.
- **`report <name> …`** – the running-file helper above.

Logs need no command: each server is an ordinary tab, read with `tbd terminal
output`.

## UI

- **Toolbar "Servers" split button**, shown only when the worktree has at least
  one declared or reported server. It follows the PR split button's pattern
  (`ContentView.swift`) and the Liquid Glass grouping rules in
  `Sources/TBDApp/CLAUDE.md`.
  - When a running server has reported a URL, the button is a split button:
    its primary click opens the main URL of the first such server. Otherwise
    the whole button opens the menu, as the PR button does when no single PR
    URL applies; a toolbar `Menu` cannot disable its primary half alone.
  - The menu's first item is "Open <main URL>" whenever there is one. Then
    each server with its state and URLs and its Start, Stop and Restart items,
    plus "Show last output" for an exited server. A server with nothing
    running that still has its TBD tab — an exited one, declared or not —
    shows "Close" in place of Stop, which closes that tab. Then "Start all"
    and "Stop all", which acts on every server showing Stop or Close, and
    "Refresh status", which runs the worktree's `status` commands; then any
    parse errors and the last action's failures.
- **Sidebar dot** – a green dot on a worktree's row when any of its servers is
  running according to a live running file or a live TBD server tab. The dot
  never runs `status` commands. Stopped and exited servers show nothing.
- Exited servers are visible only in the menu, in their tab, and — on the
  holder transport — in Closed Terminals.

## No feature flag

CLAUDE.md asks for a default-off flag on behavior that kills processes. This
feature ships without one, on purpose. Declaring servers is the opt-in: a repo
with no `tbd.toml`, no personal `servers.toml` and no `.claude/launch.json` sees
no button, no dot and no behavior change. Every process TBD signals has a
consent source — a server someone started through TBD, or a server whose repo
wrote a running file claiming it, stopped by someone who asked. The background
parts touch no process: the liveness re-check reads, and the stale-file sweep
deletes only files whose process is gone.

A repo that has only `.claude/launch.json` counts as opted in: it gains the
Servers button and Start/Stop/logs with no extra setup, and gains open buttons
once it writes running files. Nothing runs until someone clicks Start, and
no repo `status` command runs until someone starts, stops, restarts or
refreshes the servers, or runs `tbd server list` or `tbd server status`, and a
declared `stop` runs only when someone stops the server. Archive, the one path
that can signal with no click, adds no repo code of its own and signals only
the process groups of servers TBD started in its own tabs — never a pid a
running file names — for the reasons in "On archive". The archive hook is
repo code and does run, but it is the repo's existing, opted-in teardown, not
something this feature adds.

## Who reclaims what

- **Server processes TBD started** are tab processes, so tab teardown and the
  existing terminal reconcilers cover them, and stop and archive kill the tab
  process's whole group, which it leads, rather than the pane pid alone. A
  process that leaves its group (`setsid`, a daemonizing server) escapes the
  group kill; a server like that should write a running file for its real pid
  or declare a `stop` command, and the repo's archive hook should stop it,
  since archive signals only tab process groups.
- **Running files** are a new durable resource. `OrphanGC` gains a leg that
  deletes files in the running-file directory that are stale (liveness above)
  and older than `gcGraceSeconds`, under `gcEnabled`. It never signals a
  process. Malformed files and files with a higher major version are kept:
  liveness is defined only for files TBD can read, and another tool may own a
  newer format.
- **Saved last output** is an ordinary Closed Terminals entry with two extra
  fields, so the history store's existing bounds cover it: the newest 50
  entries per worktree, removed with the worktree on hard delete.

## Errors

- **Parse errors** are reported per source and never hide other sources.
- **A start whose tab cannot be created** fails the command with the reason;
  nothing is recorded.
- **A `stop` command that exits non-zero or exceeds 60 seconds** is reported,
  and TBD does not fall back to signalling: the repo chose its stop path.
- **A kill aimed at TBD's own pid or a group TBD leads** is refused and
  reported; nothing is signalled.
- **A pid that does not lead its process group** is signalled alone, and the
  stop report names it.
- **A tab pid that cannot be verified as the tab's** fails the stop; nothing is
  signalled.
- **A tab whose state cannot be read** fails a start or a stop with "try
  again"; nothing is spawned, signalled or closed.
- **A status-only server with no `stop`** fails the stop with "nothing to
  stop".
- **A server archive does not stop** — one known only through a running file
  or its `status` command — is left running, and archive logs that it did.
- **A group kill that leaves the process alive after SIGKILL** is reported with
  the pid.
- **A malformed running file** is ignored and named in `tbd server list
  --json` diagnostics; it is never shown as a server.

## Testing

- Declaration parsing: each source alone; layering by name, including a later
  source replacing a server whole and keeping its position; a broken source
  alongside good ones; `launch.json` translation including comments, trailing
  commas, `${workspaceFolder}` and slugged names; a `cwd` that escapes the
  worktree.
- Running-file liveness: live, dead pid, reused pid with a mismatched start
  time, zombie, unknown version, malformed JSON.
- State derivation: each of the five states, and their precedence, including
  *Exited* read from a saved last output once the tab is gone.
- Stop: the declared-`stop` path and its 60-second budget, the group-kill path
  with an injected clock for the SIGKILL delay, the pid-only path for a pid
  that does not lead its group, the refusal of TBD's own pid and group, a tab
  pid re-read at stop time, an unverifiable tab pid, and a status-only server
  with no `stop`.
- Last output: the holder registry calls its session-ended step before the
  release, with the established status; a server tab's exit saves its screen
  and code, an ordinary tab's exit saves nothing, and an exit whose tab is
  already gone records no server state; start and stop detach the saved entry;
  "Show last output" opens the entry on the holder transport and focuses the
  tab on tmux.
- Archive, and reconcile's archive, kill the process group of a TBD tab still
  running its command and run no `status` or `stop` command — a tab server
  that declares `stop` is signalled, while a gesture Stop of the same server
  still runs its `stop`. A live running-file-only server is not signalled,
  no command runs and its file stays, while a gesture Stop of it still
  signals its pid. A server with both a tab and a running file is signalled
  through the tab only. A holder job with no recorded start time is not
  signalled. Archive leaves a server known only through its `status` command
  running, including one TBD started whose command detached and whose tab
  has exited, leaves other worktrees' servers alone, and leaves no server
  reading *Exited*.
- The tab inspector reads a holder job the daemon adopted but whose row
  recorded no start time as unverifiable, so no stop signals it.
- The daemon marks a state the `status` command decided, and whether a server
  declares a `status` command, and reports an ended tab with its process id.
  The app keeps a remembered answer over a stopped server and over an exited
  one whose ended run is the one the answer saw, not over a newer exited tab,
  a respawn of the same tab, or a tab that ended after the answer; drops it
  when the server or its `status` command is gone and when the worktree
  leaves the app, with no refresh in flight writing it back; and keeps an
  older run's answers when a newer run fails.
- The OrphanGC leg deletes stale files only, and only under `gcEnabled`.
- `scripts/test.sh` adds `DEV_SERVERS_DIR` to its fence, pointed at scratch, so
  no test reads or writes the real `~/.local/state/dev-servers/`.

## Not in this version

- **Ordering between servers** (`dependsOn`, "start api first"). A repo that
  needs order wraps its stack in one script or a process manager and declares
  it as one server that reports several endpoints.
- **Autostart** on worktree creation or revive. It would be background
  behavior, needing a flag and a trust rule for freshly cloned repos.
- **Readiness probes.** Writing the running file is the readiness signal.
- **An in-app browser pane.** Open uses the default browser.

## Rejected alternatives

- **TBD allocates a port block per worktree** (`$PORT`, base plus offset). It
  makes TBD a middleman for a decision only the repo can get right: fixed ports
  registered with an auth provider, servers that silently move to the next free
  port, hostnames that matter more than ports.
- **Inferring URLs from listening sockets.** A listening port says nothing about
  scheme or host, and many servers open several ports (live-reload sockets,
  debuggers). A wrong open button is worse than none.
- **Scanning processes to find servers TBD did not start.** It costs a scan per
  worktree on every refresh and is a second contract beside the running file. A
  repo that wants its servers seen writes the file.
- **Running files inside the worktree or git's per-worktree directory.** They
  die with the worktree while the server can outlive it.
- **`status` commands that print JSON with URLs.** Two sources of URLs could
  disagree; the running file is the only one.
- **Reading `.claude/launch.json` only.** It cannot express `stop`, `status` or
  servers that choose their own port per worktree.
