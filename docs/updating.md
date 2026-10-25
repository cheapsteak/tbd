# Updating TBD

TBD is built from source. `tbd update` moves the whole installation — daemon,
app and CLI — to the head of `main`, building out of place and handing the
running daemon over to its successor without killing the sessions underneath
it. It can instead install the build CI published for that commit, compiling
only the app. This page is the operator's view: what the command does, what
happens to live sessions while it runs, the three modes it can run in, where
the binaries come from, and how to get back to the build you were on.

The design behind it is
[`docs/specs/2026-09-04-automatic-version-updates-design.md`](specs/2026-09-04-automatic-version-updates-design.md),
and the release download is
[`docs/specs/2026-09-23-release-pipeline-design.md`](specs/2026-09-23-release-pipeline-design.md).

## The short version

```bash
tbd version                      # what is running, and whether main has moved
tbd update                       # build the latest main and hand over
tbd update --from-release        # install CI's verified build instead
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
  `scripts/update.sh`, or of any library it sources (`restart-bundle-lib.sh`,
  `restart-environment-lib.sh`, `restart-build-lib.sh` and
  `update-release-lib.sh`), differs from the copy that was running before the
  fetch, the fetched script takes over with the same arguments. The running
  copies are kept aside before the fetch because on an installation that has
  updated before, the script runs from the update clone itself, and the fetch
  rewrites those very files in place. That is how the procedure updates
  itself, and an environment marker holds it to a single hop.
- **Builds** the same products `scripts/restart.sh` builds — `TBDDaemon`,
  `TBDApp`, `TBDCLI`, `TBDHolder` and `TBDPeerHelper` — through
  `scripts/swift-safe`, with the same shared module cache. With the update
  source at `release`, it downloads and verifies the published build instead
  and compiles only `TBDApp`; see "Where the binaries come from". A failed build
  stops here and the running installation, and the clone's own build
  identity sidecar (below), are both untouched. The run's full compiler output
  is kept in `~/tbd/updates/build.log`, overwritten by the next run; a failure
  logs the first `error:` lines and that path. When `scripts/swift-safe` exits
  75 the build never got the machine-wide build slot, so nothing was compiled,
  and the log says so rather than calling it a failed build.
- **Stamps the build identity**, once the build above actually succeeded.
  `TBDBuildIdentity.json` lands in the build directory recording the commit,
  the branch, the build time, the clone's path, whether the tree was dirty,
  and the tree's schema epoch. Every binary reads the sidecar beside it, which
  is how `tbd version` knows what is running, and a later daemon reads the
  epoch from the kept bundle before it drops a retired column. Stamping only
  after success matters because `~/tbd/updates/src` is one long-lived clone
  every update reuses: a build that failed here left old binaries in place,
  and had the sidecar been written first, it would have named the commit that
  never actually built, with nothing to correct it until the clone's next
  successful build.
- **Assembles and signs** the new `TBD.app`, using the same code
  `scripts/restart.sh` uses (`scripts/restart-bundle-lib.sh`). The bundle
  carries the sidecar and a `SourceWorktreePath.txt` naming the update clone.
- **Stops the app**, unless you pass `--no-app`, and waits for it to exit:
  SIGTERM, five seconds, then SIGKILL, each outcome logged. Nothing before this
  step touches the running installation, so a failed build, a dry run or a
  failed signature leaves the app up. It goes before the daemon because an app
  still running during the handover reconnects to the new daemon and
  re-attaches the session it shows, and the new daemon keeps that claim after
  the app is replaced, refusing the replacement's attach. From here on, every
  way the run ends launches the app again, but two: an interruption while the
  bundle is being installed and the daemon handed over, and a failed handover
  whose rollback does not complete, both described under "Going back to the
  previous build".
- **Installs** `/Applications/TBD.app`. The bundle being replaced is moved to
  `~/tbd/updates/previous/TBD.app` first, and stays there — it is what a failed
  handover puts back, and afterwards it is the quickest way to return to the
  build you were on.
- **Hands the daemon over**, as described below, and waits until the new
  daemon is the one answering: the old daemon's process has exited, and
  `tbd daemon status` then reports the new binary's path. The path alone
  cannot say which daemon answered. A local build runs the old and the new
  daemon from the same file, the update clone's `.build/release/TBDDaemon`,
  and the old one goes on answering for the seconds its shutdown takes, after
  it has let go of every session. The new daemon binds its socket only once
  the old one is gone, so from that exit on the answer is the new daemon's,
  and the app launch and the wake below reach it. If either has not happened
  within two minutes, one budget covering both, the run stops the new daemon
  and rolls back as described under "Going back to the previous build". With
  no daemon running when the update starts, it waits only for the status.
- **Seeds the saved tmux fallback** on a manual run, with or without
  `--no-app`; an `--auto` run skips this step. When
  `~/tbd/tmux-executable-path` is missing or names no usable executable, the
  update writes the tmux its shell finds on `PATH` there. A login relaunch
  ignores the bundle's recorded `PATH`, and this file is how that launch still
  finds a package-manager tmux. A valid saved path is never replaced. An
  `--auto` run's `PATH` is the daemon's plus fixed Homebrew directories, so a
  tmux it found would be a guess rather than your shell's choice. See
  [the design](specs/2026-09-22-tmux-fallback-install-seeding-design.md).
- **Launches the app** again, unless you pass `--no-app`. The app is a viewer;
  nothing in it holds a session, so the seconds it is down cost no work.
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
`tbd config get`, or use the picker in the app's Settings. The change lands on
the daemon already running: turning the check on starts it right away, turning
it off quiets it at the next tick. Nothing here waits for a restart.

## The log

Every step of every run is timestamped into `~/tbd/updates/update.log`, and the
log is appended to rather than replaced, so an unattended `auto` run is
readable afterwards. An interactive run also prints as it goes; `--auto`
writes only to the log, because the daemon has already pointed its output
there.

The run ends with a summary naming the previous commit, the new commit, how
many commits it advanced, how many sessions the reconcile parked, how many were
woken, and how many could not be.

## Where the binaries come from

By default `tbd update` compiles every product in the update clone. The
release workflow (`.github/workflows/release.yml`) also publishes a release
build for every commit on `main` whose tests passed: `TBDDaemon`, `TBDCLI`,
`TBDHolder` and `TBDPeerHelper`, with their resource bundles,
in the `main-builds` prerelease on GitHub. With the update source set to
`release`, `tbd update` installs that build and compiles only `TBDApp`, which
cannot yet run from a build made on another machine.

The update source is `build` or `release`. The first of these that is set
decides it:

- `--from-release` — this run only.
- `TBD_UPDATE_SOURCE=release` in the environment.
- `~/tbd/updates/update-source` containing `release` — every run, `auto`
  included. Remove the file to go back.
- The shipped default, `build`.

A release install does this:

- **Finds the newest published commit**, walking back up to ten commits along
  `main` when the head's build is not published yet. When the running build is
  already that commit or newer, it installs nothing.
- **Verifies before it unpacks anything.** The archive must match its
  published SHA-256. Its build-provenance attestation must verify with `gh
  attestation verify`, which proves it was built by `release.yml` in this
  repository. Every file must match the archive's manifest. An `--auto` run
  that cannot check the attestation — no `gh`, or not signed in — refuses. A
  manual run warns and continues on the checksum. A check that fails stops
  the run in every mode, and nothing is built or installed in its place.
- **Unpacks to `~/tbd/updates/prebuilt/<commit>/`**, builds `TBDApp` into it,
  and points the update clone's `.build/release` at it. The handover, the
  app's reboot respawn and the CLI link all look there, so everything after
  this is the same as after a local build. The build identity records
  `provenance: release` and the CI run it came from.
- **Keeps two trees**: the one now running and the one it replaced, which is
  what `~/tbd/updates/previous/TBD.app` pairs with. Every run reconciles
  `~/tbd/updates/prebuilt/` at its start and on every exit, so a dry run or a
  failed run keeps nothing it downloaded and older trees are deleted.

When nothing is published, a manual run builds locally as it always has, and
an `--auto` run logs it and waits for the next check. A machine that is not
Apple silicon always builds locally. `--debug` always builds locally.

While the standing source is `release`, the update writes
`~/tbd/updates/check-ref`, and the daemon's check compares against the
`main-builds` tag instead of `main`, so "update available" means a published
build exists. `tbd update --check` writes it too.

## Useful flags

- `--check` — report the comparison and stop. Changes nothing, creates no
  clone.
- `--dry-run` — fetch and build, install nothing. The last step before the
  running installation changes. With the release source it downloads,
  verifies and builds the app, then stops.
- `--from-release` — install the published build for this run; see "Where
  the binaries come from".
- `--debug` — build the debug configuration instead of release.
- `--no-app` — leave the running app alone, neither stopping it for the
  handover nor restarting it; hand the daemon over anyway.
- `--no-wake` — install and hand over, but wake nothing.
- `--wake-only` — wake every recovery-parked session against the running
  daemon, and do nothing else.
- `--remote <url>` — fetch from this URL instead of the resolved default.

## Running it from inside another project's dev shell

A terminal inside a nix/direnv (or similar) dev shell exports variables that
point the compiler at that shell's own SDK — `SDKROOT`, `DEVELOPER_DIR`,
`CPATH`, `LIBRARY_PATH`, the `NIX_CFLAGS_*`/`NIX_LDFLAGS*` family, and
`IN_NIX_SHELL`. Left in place, they make a dependency fail to build with an
error such as `'sqlite3.h' file not found`. `tbd update` (and `scripts/restart.sh`,
around its build) clears them and says so in the log, for example
`note: ignoring inherited compiler-environment variables for the build
(SDKROOT, IN_NIX_SHELL)`. Your own shell is not touched.

Left alone on purpose: `TBD_SWIFT_BIN`, `TOOLCHAINS`, and an `SDKROOT` or
`DEVELOPER_DIR` that points into an installed Xcode or the Command Line Tools.
That covers an Xcode under `/Applications`, the Command Line Tools, anything
under the developer directory `xcode-select -p` reports (so an Xcode installed
elsewhere counts once it is selected), and a symlink that resolves to any of
those.
`TBD_KEEP_BUILD_ENV=1` turns the clearing off entirely. `PATH` is not edited,
so a dev shell that puts a different compiler first on it still wins.

The same shells often put GNU coreutils first on `PATH`. The install copies
the app bundle with `/bin/cp -cR` by absolute path, because `-c` (an APFS
clone) is BSD-only and GNU `cp` rejects it. The rollback command below spells
`/bin/cp` for the same reason.

## Going back to the previous build

There is no automated rollback, by design. Three routes back exist instead, in
the order you would reach for them.

- **From the kept bundle**, the fastest, because it needs no build. Every
  update moves the app bundle it is replacing to
  `~/tbd/updates/previous/TBD.app` and leaves it there. An update that finds
  nothing installed keeps nothing, and leaves a bundle an earlier update kept
  where it is. Put it back with
  `rm -rf /Applications/TBD.app && /bin/cp -cR ~/tbd/updates/previous/TBD.app
  /Applications/TBD.app`, then relaunch. That bundle's
  `Contents/SourceWorktreePath.txt` names the tree the previous daemon came
  from, so `scripts/restart.sh --release` run from inside that tree completes
  the rollback for the daemon as well.
- **From the update clone.** `~/tbd/updates/src` keeps its full history. Check
  out the commit you want (`git -C ~/tbd/updates/src checkout --detach
  <commit>`) and run `scripts/restart.sh --release` from inside it. That
  rebuilds and reinstalls from that commit exactly as an update would. Slower
  than the kept bundle, and the only route to a commit that is neither the one
  you are on nor the one you came from.
- **From any worktree.** `scripts/restart.sh` still works from any TBD
  checkout, and still wins `/Applications` and the `tbd://` handler for
  whichever tree ran it most recently. This is the route back when the update
  clone is the thing that is broken.

An update that gets as far as installing and then cannot bring the new daemon
up performs the first of those itself: it moves the kept bundle back, tells
LaunchServices about it, logs `restored previous app bundle`, puts the update
clone's `.build/release` link back the way the run found it, relaunches the
app it stopped before the handover, and exits non-zero. That is the case the
kept bundle exists for — a new app driving the old daemon is a state nobody
should be left in. The relaunch also covers a handover that failed after the
old daemon had already exited: an app that finds no daemon starts one.

The relaunch waits on both halves of that rollback. When either fails — the
run kept no bundle to move back because nothing was installed when it began,
as on the first update, or the bundle or the `.build/release` link cannot be
put back — the new build may still be what an app would launch, or what it
would start a daemon from, so the run leaves the app it stopped not running.
It logs which half failed, then an error saying the rollback of the failed
install did not complete, and the recovery steps below.

The rollback only ever moves back the bundle the same run kept. A bundle an
earlier update left at `~/tbd/updates/previous/TBD.app` is not the build the
run replaced, and installing it would put some older app in front of
whichever daemon is left, so a run that kept nothing leaves it where it is and
logs that it did not restore it. The new build stays in `/Applications`, as on
the first update, so that it is there to open once it and the daemon are the
same build.

A run interrupted while it installs the bundle and hands the daemon over —
Ctrl-C, a signal, or a step that exits — does not launch the app again
either. At that point the run cannot tell which bundle is in `/Applications`
or which daemon is serving, and putting the kept bundle back is no safer than
relaunching, because the new daemon may already be up. So it leaves the app
it stopped not running and logs an error saying the run was interrupted
mid-handover and the app is not running.

To recover from either:

- **Check what is running.** `tbd version` names the daemon's commit, and
  `/Applications/TBD.app/Contents/TBDBuildIdentity.json` names the bundle's.
- **Run `tbd update` again.** A run that completes its handover leaves the
  bundle and the daemon on the same build and launches the app at the end.
- **Or open `/Applications/TBD.app` yourself** once it and the daemon are the
  same build.
- **Or go back** with the kept bundle at `~/tbd/updates/previous/TBD.app`,
  as described above, if the run got far enough to keep one. A run that found
  nothing installed kept none, and a bundle there is an earlier update's.

An interruption before the install starts, or after the handover has
completed, launches the app again as usual: before, nothing has moved; after,
the bundle and the daemon are the same new build.

Either way, run the script from the worktree you want installed — never an
absolute path to another tree's copy — or you will build one tree and leave
another tree's processes running.

The kept bundle stays compatible with your database. The daemon drops a
column a build has retired only once the kept bundle was built from a tree that
had retired it too, so that bundle never names a column that is gone. The
other two routes back, the update clone and any worktree, carry no such
guarantee: a build of an older commit may still read or write a column the
daemon has since dropped, and then fails every insert and update into that
table. Before its first drop the daemon copies the database to
`~/tbd/state.db.pre-column-drop.<UTC-timestamp>`, which still holds the dropped
columns and their data; delete it by hand once you no longer need it. See
[the design](specs/2026-10-24-column-retirement-design.md).

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
