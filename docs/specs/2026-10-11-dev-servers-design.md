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
- **`stop`** and **`status`** are shell commands run with `sh -c` in the
  server's `cwd`. `status` answers only *running or not*, by exit code; URLs
  come only from the running file, so the two can never disagree.
- Server names are the TOML keys: lowercase letters, digits and `-`.
- Unknown keys are ignored, so later versions can add fields without breaking
  older TBD builds.

There are deliberately no `port`, `url`, `dependsOn` or `autostart` fields.
Ports and URLs belong to the running file; ordering and autostart are out of
scope (see "Not in this version").

### Reading `.claude/launch.json`

Many repos already carry this file for Claude Code desktop's preview. Each entry
of `configurations[]` becomes a declared server:

- `name` → the server name.
- `runtimeExecutable` + `runtimeArgs`, or `node <program> <args…>`, → `command`,
  each argument shell-quoted.
- `cwd` and `env` carry over; `${workspaceFolder}` resolves to the worktree root.
- `port`, `url` and `autoPort` are ignored: the repo owns ports and reports URLs
  through the running file.

The file is JSON with comments; TBD strips comments before decoding.

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
  with its URLs and a Stop item.
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
  names the server process deliberately rather than inheriting a launcher's.
- `tbd server report <name> --clear` deletes it.

The file format is the contract; the helper is a convenience. A repo that does
not want a dependency on the `tbd` binary writes the JSON itself.

## How TBD runs servers

### Starting

`tbd server start [name…]`, the toolbar's Start items, and "Start all" (all
declared servers, started side by side) do the same thing per server:

- TBD opens a terminal tab titled with the server's label, running `sh -c
  <command>` in `cwd` with `env` applied. The command is the tab's root process,
  so it leads its own process group and a group signal reaches every child.
- The command is wrapped so its exit code is recorded — the marker-file wrapper
  setup hooks already use on the tmux transport, or the holder's own child exit
  status on the holder transport.
- The tab keeps its final screen after the command exits, so a crash leaves
  its output readable.
- The terminal row records the server's name in a new nullable `server_name`
  column on `terminal`, linking tab to server. That is a migration plus the GRDB
  record plus `Terminal` in `TBDShared/Models.swift`, in one commit.
- Starting a server that is already running does nothing and says so. A server
  whose tab exited is started again in that same tab, so tabs do not pile up.

### State

Each server's state is derived, in this order:

1. **Running, with URLs** – a live running file for this worktree and server.
2. **Running** – the server's `status` command exits 0, or TBD's tab for it is
   still running the command. No open button: no URL has been reported.
3. **Exited (code N)** – TBD's tab for it exists and the command ended.
4. **Stopped** – none of the above.

The `status` command is run when the toolbar menu opens and by `tbd server
list` and `tbd server status`, with a 5-second timeout; a timeout reads as
*unknown*. It is never run on a timer.

TBD watches the running-file directory for changes and re-checks liveness of
known files every 10 seconds, so a server that died without cleaning up drops
out. The re-check timer takes an injected clock.

### Stopping

`tbd server stop [name…]`, the Stop items and "Stop all" do, per server:

- If the server declares `stop`, run it.
- Otherwise, signal the process group of the server — TBD's tab process, or the
  live running file's `pid`: SIGTERM, then SIGKILL after 5 seconds. Before
  signalling, re-verify the pid's start time and refuse process group 0 or 1.
- Close the server's tab, capturing its scrollback the way archive does, and
  delete its running file.

`restart` is stop, then start. Pressing Ctrl+C in a server's tab is not a stop
through TBD: the command exits on its own, so the tab stays open and the server
reads *Exited*.

### On archive

Before the archive hook runs, TBD stops every server in the worktree that it
started or that has a live running file, using the stop rules above.

## CLI

`tbd server` is a new command group. Every command takes `--worktree`
(defaulting to `TBD_WORKTREE_ID`, then the current directory) and `--json`.

- **`list`** – every declared or reported server: state, URLs, and the source
  that declared it; plus any source that failed to parse.
- **`start [name…]`** – no name starts all declared servers. Prints each tab's
  terminal ID.
- **`stop [name…]`** – no name stops all.
- **`restart [name…]`**
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
  - The primary part opens the main URL of the first running server that has
    one; it is disabled when none has.
  - The menu lists each server with its state and URLs, and Start, Stop and
    Restart items; then "Start all" and "Stop all"; then any parse errors.
- **Sidebar dot** – a green dot on a worktree's row when any of its servers is
  running according to a live running file or a live TBD server tab. The dot
  never runs `status` commands. Stopped and exited servers show nothing.
- Exited servers are visible only in the menu and in their tab.

## No feature flag

CLAUDE.md asks for a default-off flag on behavior that kills processes. This
feature ships without one, on purpose. Declaring servers is the opt-in: a repo
with no `tbd.toml`, no personal `servers.toml` and no `.claude/launch.json` sees
no button, no dot and no behavior change. Every process TBD signals has a
consent source — a server someone started through TBD, or a server whose repo
wrote a running file claiming it. The background parts touch no process: the
liveness re-check reads, and the stale-file sweep deletes only files whose
process is gone.

A repo that has only `.claude/launch.json` counts as opted in: it gains the
Servers button and Start/Stop/logs with no extra setup, and gains open buttons
once it writes running files. Nothing runs until someone clicks Start.

## Who reclaims what

- **Server processes TBD started** are tab processes, so tab teardown and the
  existing terminal reconcilers cover them, and stop and archive kill the
  whole process group rather than the pane pid alone. A process that leaves its
  group (`setsid`, a daemonizing server) escapes the group kill; a server like
  that should write a running file for its real pid or declare a `stop`
  command.
- **Running files** are a new durable resource. `OrphanGC` gains a leg that
  deletes files in the running-file directory that are stale (liveness above)
  and older than `gcGraceSeconds`, under `gcEnabled`. It never signals a
  process.

## Errors

- **Parse errors** are reported per source and never hide other sources.
- **A start whose tab cannot be created** fails the command with the reason;
  nothing is recorded.
- **A `stop` command that exits non-zero** is reported, and TBD does not fall
  back to signalling: the repo chose its stop path.
- **A group kill that leaves the process alive after SIGKILL** is reported with
  the pid.
- **A malformed running file** is ignored and named in `tbd server list
  --json` diagnostics; it is never shown as a server.

## Testing

- Declaration parsing: each source alone; layering by name, including a later
  source replacing a server whole; a broken source alongside good ones;
  `launch.json` translation including comments and `${workspaceFolder}`.
- Running-file liveness: live, dead pid, reused pid with a mismatched start
  time, zombie, unknown version, malformed JSON.
- State derivation: each of the four states, and their precedence.
- Stop: the declared-`stop` path, the group-kill path with an injected clock
  for the SIGKILL delay, and the refusal of group 0 and 1.
- Archive stops TBD-started and file-reported servers and leaves other
  worktrees' servers alone.
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
