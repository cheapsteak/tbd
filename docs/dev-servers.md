# Dev servers

A repo often runs several long-lived local servers while someone works on it: a web app, a backend API, Storybook. TBD runs many worktrees of one repo at once, so the same servers may be up in several worktrees. This document is the contract between a repo and TBD: how the repo declares its servers, how a running server tells TBD where it can be reached, and what TBD does with that. The design rationale is in [`docs/specs/2026-10-11-dev-servers-design.md`](specs/2026-10-11-dev-servers-design.md).

## What TBD does with dev servers

A repo declares its servers in a file. Someone starts and stops them from `tbd server` or the toolbar's Servers button; each runs in an ordinary terminal tab. A running server reports its URLs by writing a *running file*, and TBD uses those to offer an Open button and to show a green dot on the worktree's sidebar row.

Two things TBD deliberately does not do. It never allocates or probes a port: the repo owns its ports. And nothing starts on its own: every start is a click or a `tbd server start`. A repo with no declaration sees no button, no dot and no change in behavior.

## Declaring servers

TBD reads three sources, each fresh from the worktree being acted on:

- **`.claude/launch.json`** in the worktree, if present.
- **`tbd.toml`** at the worktree root, committed by the repo.
- **`~/tbd/repos/<repoID>/servers.toml`**, the user's personal file, for repos they cannot or do not want to commit to. It honors `TBD_HOME`.

Sources layer by server name, in that order. A server in a later source replaces the same-named server from an earlier one as a whole, with no field-level merge. Servers with other names are kept from every source. Declared servers keep the order in which their names first appear — within a TOML file, the order of its `[servers.<name>]` sections; a replaced server keeps its original position.

A source that fails to parse is named, with its error, in `tbd server list` and at the bottom of the toolbar menu. It contributes nothing and never hides servers from the other sources.

### `tbd.toml` and `servers.toml`

Both files use the same format:

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

- **`command`** – required, and non-empty. Run with `sh -c`.
- **`cwd`** – optional. Must be relative and stay inside the worktree; an absolute path, or one that escapes through `..`, is a parse error for that server.
- **`env`** – optional table of strings. Keys must be shell identifiers (`[A-Za-z_][A-Za-z0-9_]*`); any other key is a parse error naming it, and is dropped. The file is usually committed, so never put secrets in it.
- **`label`** – optional display name; defaults to the server name.
- **`stop`** – optional shell command, run in the server's `cwd`. It replaces TBD's process-group kill when you stop the server, and has a 60-second budget. It runs only when someone stops the server; archive never runs it.
- **`status`** – optional shell command, run in the server's `cwd`. Exit 0 means running. It has a 5-second budget and only answers running or not; it is never parsed for URLs.
- `stop` and `status` run with TBD's `PATH` plus the common package-manager directories (`~/.local/bin`, Homebrew, `/usr/local/bin` and the like), so they find tools even when TBD was relaunched with a bare system `PATH`.
- **Names** – the TOML keys: lowercase letters, digits and `-`.
- **Unknown keys** are ignored, so a newer file works with an older TBD.

There are no `port`, `url`, `dependsOn` or `autostart` fields. Ports and URLs belong to the running file.

### Reading `.claude/launch.json`

Many repos already carry this file for Claude Code's preview. Each entry of `configurations[]` becomes a declared server:

- **`name`** becomes the server name as a slug: lowercased, each run of characters outside `a-z0-9` collapsed to one `-`, leading and trailing `-` trimmed. The original `name` is kept as the label, so "Web App" is the server `web-app`, shown as "Web App". An entry whose slug is empty, or that repeats an earlier slug, is a parse error.
- **`runtimeExecutable`**, `runtimeArgs`, `program` and `args` become the `command` in VS Code's order — runtime (`node` when `runtimeExecutable` is absent), runtime arguments, program, program arguments — each argument shell-quoted.
- **`cwd` and `env`** carry over. `${workspaceFolder}` resolves to the worktree root. A `cwd` outside the worktree is a parse error for that entry.
- **`port`, `url` and `autoPort`** are ignored.

The file may contain comments and trailing commas, as VS Code writes it. A repo that has only `launch.json` still gets the Servers button and Start/Stop; it gets open buttons once its servers write running files.

## The running file

The running file is how a server tells TBD it is up and where. Any process may write one: a server TBD started, one an agent started with `pnpm dev &`, or one started in an unrelated terminal.

### Location

`~/.local/state/dev-servers/`, overridden by the `DEV_SERVERS_DIR` environment variable. The directory and format are not TBD-branded on purpose: any tool can read or write them. The directory is outside the worktree because a file inside it vanishes when the worktree is removed, while the server may keep running.

### Format

One JSON file per running server, with a name ending in `.json`:

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

- **`version`** – `1`. A file with a higher version is not read.
- **`root`** – the absolute worktree path. This attributes the file to a worktree; a file whose `root` matches no known worktree is not shown.
- **`server`** – the server name. If it matches a declared server, the file reports that server's state; otherwise the server is listed as undeclared, with its URLs and a Stop item. A server TBD started whose declaration was later removed is also listed as undeclared while its tab exists; stopping it signals its tab's process group.
- **`endpoints`** – one or more named, absolute URLs; full URLs, because scheme and host matter. The first is the main URL.
- **`pid`** and **`startTime`** – the server process, and its start time in Unix seconds. Both are required.

Write the file atomically (temp file in the same directory, then rename) and delete it when the server exits cleanly. Readers ignore unknown fields. A running file never contains a command, and TBD never executes anything read from one.

### Liveness

A file is live when a process with `pid` exists, is not a zombie, and its start time, read from the kernel, is within one second of `startTime`. Any other file is stale and ignored. The start-time check makes a reused pid harmless and keeps the record correct when the writer was killed without cleaning up.

`pid` must be the server itself, not a launcher that backgrounds it and exits; that leaves a file that reads stale while the server runs.

### Process groups

To stop a server, TBD signals the process group of `pid` only when `pid` leads that group (`getpgid(pid) == pid`). Otherwise it signals `pid` alone and says so in the stop report: a server started with `pnpm dev &` from a shell without job control shares that shell's group, which may belong to an agent session, so the group is not the server's to end. A server whose children must stop with it should lead its own group (`setsid`, or `set -m` in a start script), or declare a `stop` command.

## `tbd server report`

`tbd server report <name> --pid <pid> --url <url> [--url <name>=<url> ...]` writes a correct file, reading `startTime` from the kernel and `root` from the worktree. `--pid` is required so the caller names the server process deliberately. A `--url name=url` names an endpoint; an unnamed `--url` is called `main`, and further unnamed ones `main-2`, `main-3`. The first endpoint is the main URL. `tbd server report <name> --clear` deletes the file.

An example start script:

```bash
#!/bin/sh
pnpm dev --port "$PORT" &
server=$!
tbd server report "$DEV_SERVER_NAME" --pid "$server" --url "http://localhost:$PORT"
wait "$server"
tbd server report "$DEV_SERVER_NAME" --clear
```

The file format is the contract; the command is a convenience. A repo that does not want a dependency on `tbd` can write the JSON itself.

## How TBD runs a server

A start opens a terminal tab titled with the server's label, running `exec /bin/sh -c '<command>'` in `cwd`. The `exec` makes the command the tab's own process, so a group signal reaches its children and its exit status is the tab's. The environment is the usual one plus `env` from the declaration and these variables:

- `DEV_SERVER_NAME`, `DEV_SERVERS_DIR`
- `TBD_WORKTREE_ID`, `TBD_WORKTREE_NAME`, `TBD_WORKTREE_PATH`
- `TBD_REPO_PATH`, `TBD_TERMINAL_ID`

Starting a server that is already running does nothing and says so. Start with no name starts every declared server. A server that reads Unknown is not started, rather than risk a second copy of a server that may still be running: when TBD cannot read the state of its tab — a tmux query that timed out or failed without saying the pane is gone — the start fails and asks you to try again, and when its `status` command timed out the start fails with "state unknown (status command timed out); try again or stop it first".

### States

A server's state is the first of these that applies:

1. **Running, with URLs** – a live running file for this worktree and server.
2. **Running** – its `status` command exits 0, or TBD's tab is still running the command. No Open button, since no URL was reported.
3. **Exited (code N)** – the command TBD last started has ended. The code is omitted when the terminal transport could not observe it.
4. **Unknown** – TBD could not read its tab's state, or the `status` command timed out, and nothing above applies. A server also reads Unknown, rather than Stopped or a saved Exited, when TBD could not read the worktree's tab records at all, unless a live running file or its `status` command says it runs; start and stop then fail and ask you to try again.
5. **Stopped** – none of the above.

`status` commands run only when you ask: by `tbd server list` and `tbd server status`, and in the app after each Start, Stop or Restart and when you pick **Refresh status** in the Servers menu. Selecting a worktree never runs them, because a `status` command is the repo's own shell and a branch you are only looking at could change it. Between runs, the app shows the answer the last run gave for a server whose state its `status` command decided: over a server known only through that command, which would otherwise read Stopped, and over a server TBD started whose command detached, such as `docker compose up -d db` with `status = "docker compose ps db"` — its tab exits at once and would otherwise read Exited. If you start it again and the new run exits, including from the CLI, the new exit is what the menu shows until the next `status` run. The app forgets an answer once the server or its `status` command is gone from the declarations, and forgets a worktree's answers when the worktree is archived, disappears from TBD, or goes with its repo. Until a `status` command has run in the app, such a server reads Stopped (or Exited, by its tab). Because the app remembers the last answer, a server stopped from the CLI with `tbd server stop` can keep reading Running in the app until its next `status` run. This applies to a server known only through its `status` command and to a server TBD started whose command detached. Archiving a worktree never runs them. They never run on a timer or for the sidebar dot. TBD watches the running-file directory and, every 10 seconds, re-checks the liveness of known files and of its own server tabs, so a server that died without cleaning up drops out of the sidebar dot.

### Stopping

- If the server declares `stop`, TBD runs it with a 60-second budget. A `stop` that exits non-zero or runs out of time is a failed stop; TBD does not fall back to signalling.
- Otherwise TBD signals the server's process, taken from its tab process (read again at stop time) or the live file's `pid`: SIGTERM, then SIGKILL after 5 seconds; the grace runs out in full even if the request that asked for the stop goes away. It signals the whole process group only when the pid leads it, and the pid alone otherwise (see "Process groups"). It re-verifies the pid's start time before signalling, and a pid it cannot verify fails the stop instead of being signalled.
- A server that reads running only through its `status` command, with no `stop` declared, has nothing TBD may signal; stopping it fails and asks for a `stop` command.
- Then it closes the server's tab, keeping the scrollback the way archive does, and deletes the running file once the process it names is gone. If a `stop` command exits 0 but that process is still alive, the file is kept and the server still reads Running until the process exits; the stale-file sweep then removes it.

Stopping an exited server closes its tab and clears its Exited state without signalling anything or running its `stop`, since nothing is running. Stopping a server whose tab's state cannot be read fails and asks you to try again; nothing is signalled, run or closed.

`restart` is stop, then start; with no name it restarts exactly the declared servers that were running. An undeclared server is stopped and not started again, since nothing declares how to start it. Ctrl+C in the server's tab is not a stop through TBD: the command exits on its own and the server reads Exited.

Archiving a worktree never runs the repo's code: archive can happen without a click, such as auto-archive when a pull request merges, and a branch could change a `stop` or `status` command. So archive runs neither, and stops the servers TBD can see only by signalling them — a server tab still running its command or reading Unknown has its process group signalled, and a live running file has the pid it names signalled, re-verified against its recorded start time, under the rules above — whether or not the server declares `stop`. Signalling is acceptable where running repo code is not: a running file is the server's own report of being this worktree's server, checked by pid and start time; the worktree it serves is going away; and TBD never signals its own pid or a group it leads. This happens before the worktree's tabs are torn down and before the archive hook runs, forced archives included. A server only its declared `stop` can end keeps running after archive: one known only through its `status` command, or one TBD started whose command detached, such as `docker compose up -d`, since its tab has already exited. Stop it before archiving, or let your repo's own tooling clean it up. A server that fails to stop, or is left running, is logged and the archive continues. Afterwards no server in the worktree reads Exited.

## Exited servers and their last output

A crashed server's final screen is usually the only explanation of the crash, so it stays readable.

- **tmux transport** – TBD sets `remain-on-exit` on the server's window in the same tmux invocation that creates it, so the tab keeps its final screen and exit code even when the command dies at once. "Show last output" focuses that tab.
- **holder transport** (`pty_holder_enabled`) – when the command exits, the daemon saves the final screen and scrollback into Session History, Closed Terminals, with the exit code. Both survive a daemon restart. "Show last output" opens that entry.

Start opens a fresh tab, and Start or Stop detaches the saved entry from the server; it stays in Closed Terminals as an ordinary entry. An exit caused by Stop is never recorded as the server's last output.

## CLI reference

Every command takes `--worktree` (a name, display name or UUID; defaults to `TBD_WORKTREE_ID`, then the current directory) and `--json`.

- **`tbd server list`** – every declared or reported server with its state, URLs and source, plus any source that failed to parse.
- **`tbd server start [name...]`** – start the named servers, or all declared ones.
- **`tbd server stop [name...]`** – stop the named servers, or every running one.
- **`tbd server restart [name...]`** – stop, then start. With no name, restarts every running declared server (undeclared ones are stopped and left stopped); when none is running it says so and starts nothing.
- **`tbd server status <name>`** – print the server's state and URLs; exits 0 only when it is running, so a script can wait on it.
- **`tbd server open [name] [--endpoint <name>]`** – open the main URL, or a named endpoint, in the default browser. Without a name, the first running server with a URL.
- **`tbd server report <name> ...`** – write or `--clear` a running file, as above.

Logs need no command: each server is an ordinary tab, read with `tbd terminal output <terminal-id>`.

## Who reclaims what

- **Server processes TBD started** are tab processes, each leading its own group, covered by tab teardown, archive and the terminal reconcilers. A process that leaves its group (`setsid`, a daemonizing server) escapes the group kill, so such a server should write a running file for its real pid or declare `stop`.
- **Stale running files** are deleted by `OrphanGC` under `gcEnabled`, when the process is gone and the file is older than `gcGraceSeconds`. It never signals a process, and keeps malformed or newer-version files. See [`orphan-gc.md`](orphan-gc.md).
- **Saved last output** is an ordinary Closed Terminals entry, bounded by that store's limits.
