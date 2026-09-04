# Updating TBD

TBD is built from source. `tbd update` moves the whole installation — daemon,
app and CLI — to the head of `main`, building out of place and handing the
running daemon over to its successor without killing the sessions underneath
it. This page is the operator's view: what the command does, what happens to
live sessions while it runs, the three modes it can run in, and how to get back
to the build you were on.

The design behind it is
[`docs/specs/2026-09-04-automatic-version-updates-design.md`](specs/2026-09-04-automatic-version-updates-design.md).

## The short version

```bash
tbd version                      # what is running, and whether main has moved
tbd update                       # build the latest main and hand over
tbd config set update-mode check # get told when main moves; act by hand
```

## What `tbd update` does

`tbd update` is a thin CLI command. It asks the daemon which worktree it was
built from and execs that worktree's `scripts/update.sh` with your arguments
and your environment, so the procedure runs under your login shell's `PATH`
rather than whatever launched the app. The script is the procedure, and it runs
these steps in order.

- **Takes the update lock.** A lock file under `~/tbd/updates/` names the
  running update. A second update refuses to start while the pid in that file
  is alive; a lock left behind by a crashed run is taken over.
- **Finds the update clone** at `~/tbd/updates/src`, cloning it on first use.
  This is a dedicated clone, not a worktree of your checkout: it never shows up
  in `git worktree list`, `scripts/reclaim-build.sh` does not scan it, and it
  is safe to detach at any moment. Its remote is the `upstream` of the daemon's
  source worktree, else that worktree's `origin`, else whatever `--remote` you
  pass.
- **Fetches and detaches onto `origin/main`.** If the fetched copy of
  `scripts/update.sh` differs from the one running, the fetched one takes over
  with the same arguments. That is how the procedure updates itself, and an
  environment marker holds it to a single hop.
- **Stamps the build identity.** `TBDBuildIdentity.json` lands in the build
  directory before the compiler runs, recording the commit, the branch, the
  build time, the clone's path, and whether the tree was dirty. Every binary
  reads the sidecar beside it, which is how `tbd version` knows what is
  running.
- **Builds** `TBDDaemon`, `TBDApp` and `TBDCLI` through `scripts/swift-safe`,
  with the same shared module cache `scripts/restart.sh` uses. A failed build
  stops here and the running installation is untouched.
- **Assembles, signs and installs** `/Applications/TBD.app`, using the same
  code `scripts/restart.sh` uses (`scripts/restart-bundle-lib.sh`). The bundle
  carries the sidecar and a `SourceWorktreePath.txt` naming the update clone.
- **Hands the daemon over.** See below.
- **Restarts the app**, unless you pass `--no-app`. The app is a viewer;
  nothing in it holds a session.
- **Wakes what the handover parked**, unless you pass `--no-wake`.
- **Prints a summary and writes the log.**

## What happens to your sessions

Sessions live in tmux, not in the daemon or the app, so neither restarting the
app nor replacing the daemon ends a session. What has hurt in the past is the
new daemon's startup reconcile: it probes every tmux window, and on a machine
still digesting a build a slow probe used to be treated the same as a missing
one, parking live sessions wholesale. Four things make the handover safe.

- **The successor claims the pid file first.** It starts with
  `TBD_HANDOVER_FROM_PID` naming its predecessor, writes its own pid over the
  pid file, then terminates the predecessor and waits for it to exit. From the
  first instant, anything that would spawn a rescue daemon — the app's
  two-second watchdog, a stray `restart.sh` — finds a live daemon named in that
  file and exits at the single-instance gate. There is a brief window with no
  socket, the same window every restart has always had, in which CLI calls fail
  and retry.
- **Reconcile no longer parks on an ambiguous answer.** The tmux probes report
  `alive`, `absent` or `unknown`, and only `absent` — tmux itself answering
  that the window is gone — parks a Claude row or deletes a non-Claude one. A
  timeout, a spawn failure or an unparseable answer leaves the row alone.
- **A second un-park pass runs after reconcile.** The first pass runs before
  reconcile, so it cannot repair a park the same boot creates. The second one
  can, and it clears any park whose pane demonstrably still runs Claude.
- **What is left gets woken, paced.** Whatever is still parked with reason
  `recovery` after the handover began is genuinely gone and needs a respawn.
  The script wakes those three at a time, two seconds apart, because N
  simultaneous `claude --resume` respawns have taken a machine down before
  (issues #284 and #367). The counts land in the summary, failures included.

`--wake-only` runs just that last step against a daemon that is already new,
for the case where an update finished but sessions were left parked.

## The three modes

The daemon holds one setting, `update-mode`, because the timer that runs a
periodic check needs a long-lived process and the daemon is the only one TBD
owns. Everything else — how many sessions to wake at once, whether to restart
the app, which configuration to build — is a constant at the top of
`scripts/update.sh` or a flag on it, so changing any of it is an edit rather
than a rebuild.

- **`off`** — the default. The daemon runs no check and spawns nothing.
- **`check`** — the daemon compares itself against the head of `main` on a
  timer (hourly, unless `TBD_UPDATE_CHECK_INTERVAL` says otherwise) using
  `git ls-remote`, which moves no objects and writes to no worktree. The result
  shows up in `tbd version`, in `tbd daemon status`, and as a one-line notice
  in the app. Nothing is built or installed.
- **`auto`** — the same check, and when `main` has moved the daemon launches
  `scripts/update.sh --auto` detached. A commit whose update attempt failed is
  not retried until `main` moves again; a manual `tbd update` always runs.

Set it with `tbd config set update-mode <off|check|auto>`, read it back with
`tbd config get`, or use the picker in the app's Settings. The daemon reads the
setting on each tick, so a change takes effect without a restart.

## The log

Every step of every run is timestamped into `~/tbd/updates/update.log`, and the
log is appended to rather than replaced, so an unattended `auto` run is
readable afterwards. An interactive run also prints as it goes; `--auto`
writes only to the log, because the daemon has already pointed its output
there.

The run ends with a summary naming the previous commit, the new commit, how
many commits it advanced, how many sessions the reconcile parked, how many were
woken, and how many could not be.

## Useful flags

- `--check` — report the comparison and stop. Changes nothing, creates no
  clone.
- `--dry-run` — fetch and build, install nothing. The last step before the
  running installation changes.
- `--debug` — build the debug configuration instead of release.
- `--no-app` — leave the running app alone; hand the daemon over anyway.
- `--no-wake` — install and hand over, but wake nothing.
- `--wake-only` — wake every recovery-parked session against the running
  daemon, and do nothing else.
- `--remote <url>` — fetch from this URL instead of the resolved default.

## Going back to the previous build

There is no automated rollback, by design. Two routes back exist instead.

- **From the update clone.** `~/tbd/updates/src` keeps its full history. Check
  out the commit you want (`git -C ~/tbd/updates/src checkout --detach
  <commit>`) and run `scripts/restart.sh --release` from inside it. That
  rebuilds and reinstalls from that commit exactly as an update would.
- **From any worktree.** `scripts/restart.sh` still works from any TBD
  checkout, and still wins `/Applications` and the `tbd://` handler for
  whichever tree ran it most recently. This is the route back when the update
  clone is the thing that is broken.

Either way, run the script from the worktree you want installed — never an
absolute path to another tree's copy — or you will build one tree and leave
another tree's processes running.

## Knowing what you are running

`tbd version` prints the CLI's commit, the daemon's commit and executable path,
the latest known commit on `main` with when it was observed, and one line
saying whether an update is available. `tbd daemon status` carries the same
facts in its `buildIdentity` and `update` fields, in both the text and `--json`
forms.

A binary learns its identity from the `TBDBuildIdentity.json` sidecar written
next to it at build time, or in `Contents/` for the app bundle. A build made by
some other route has no sidecar; the loader then falls back to the current
`HEAD` of the worktree it can derive from the executable's path, which may
be newer than the binary and is marked as such. The CLI installed at
`~/.local/bin/tbd` is a hard link with no sidecar of its own and reports that
fallback. The daemon's identity is the one that matters, and it always has a
sidecar when it was built by `scripts/restart.sh` or `tbd update`.
