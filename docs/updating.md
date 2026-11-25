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
- **Installs** `/Applications/TBD.app`, with the app still running. Nothing
  before this step touches the running installation, so a failed build, a dry
  run or a failed signature leaves everything as it was. First it copies the
  installed bundle to `~/tbd/updates/previous/TBD.app`, where it stays — it
  is what a failed handover puts back, and afterwards it is the quickest way
  to return to the build you were on. (Not when the installed bundle already
  is the build being installed; see "Going back to the previous build".)
  Then it copies the new bundle in beside
  the installed one, to a hidden `/Applications/.TBD-install-incoming`, and
  swaps the two with two renames back to back: the installed bundle to
  `/Applications/.TBD-install-outgoing`, the new one to `TBD.app`. The
  replaced bundle is then renamed to `/Applications/.TBD-install-discard` and
  deleted there, so a delete cut short never leaves part of a bundle under
  the outgoing name. So `/Applications/TBD.app` holds a whole
  bundle throughout, save the moment between the two renames, which matters
  because the app can quit at any time (see the next step). A copy that fails
  leaves the installed bundle untouched, removes what it copied and ends the
  run, with the app still up. Each copy is an APFS clone where the volume
  allows, which costs almost no disk space. The running app does not notice
  the swap: it keeps running the program it started from. An install
  interrupted part-way can leave any of the three hidden directories behind,
  and the next install removes them before it starts; if nothing is installed
  and a whole bundle (with `Contents/Info.plist` and an executable
  `Contents/MacOS/TBDApp`) sits at `.TBD-install-outgoing`, the last run
  stopped between its two renames, so that bundle is put back first rather
  than removed.
  `scripts/restart.sh` installs the same way.
- **Stops the app**, unless you pass `--no-app`, and waits for it to exit:
  SIGTERM, five seconds, then SIGKILL, each outcome logged. It comes after the
  install because the bundle has to be whole when the app quits. On macOS 27,
  quitting an app makes macOS check whether the app may keep running in the
  background, and it answers by reading the app's bundle in `/Applications`.
  If the bundle is missing or half-copied at that moment, the check fails, and
  about a second later macOS force-quits every process grouped with the app —
  which can include the daemon, every pty holder and every agent session
  under them. TBD is allowed in the background, so a complete bundle passes,
  the new build as well as the old. Measured on a run that stopped the app
  first and then moved the old bundle aside, macOS read the path 12 ms after
  the app quit, 1 ms after the old bundle had gone, found nothing, and killed
  31 pty holders and their sessions; on other runs the read landed after the
  new copy had finished, and passed. With the new bundle already whole in
  place there is nothing to race. Nothing moves the bundle in the seconds
  after the app quits either: a handover that completes leaves it alone, and
  the rollback after one that fails waits three seconds from the app's exit
  before it starts (`APP_EXIT_SETTLE_SECONDS` in `scripts/update.sh`), well
  past the measured read 12 ms after the quit and the force-quit about a
  second later. The app stops before the daemon is handed over because an app
  still running during the handover reconnects to the new daemon and
  re-attaches the session it shows, and the new daemon keeps that claim after
  the app is replaced, refusing the replacement's attach. From here on, every
  way the run ends launches the app again, but two: an interruption while the
  bundle is being installed and the daemon handed over, and a failed handover
  whose rollback does not complete, both described under "Going back to the
  previous build".
- **Hands the daemon over**, as described below, and waits until the new
  daemon is the one answering: the old daemon's process has exited, and
  `tbd daemon status` then reports the new binary's path. The path alone
  cannot say which daemon answered. A local build runs the old and the new
  daemon from the same file, the update clone's `.build/release/TBDDaemon`,
  and the old one goes on answering for the seconds its shutdown takes, after
  it has let go of every session. The new daemon binds its socket only once
  the old one is gone, so from that exit on the answer is the new daemon's,
  and the app launch and the wake below reach it. If either has not happened
  within two minutes, one budget covering both, or the answer names another
  binary, the run stops the new daemon and rolls back as described under
  "Going back to the previous build". A new daemon that exits before then
  fails the handover at once, down the same path: it would never stop the old
  one, and waiting out the budget would keep the app down for nothing. Each
  status call is cut off after ten seconds, so a daemon that accepts a
  connection and never replies cannot hold the run. With no daemon running
  when the update starts, the run waits only for the status.
- **Seeds the saved tmux fallback** on a manual run, with or without
  `--no-app`; an `--auto` run skips this step. When
  `~/tbd/tmux-executable-path` is missing or names no usable executable, the
  update writes the tmux its shell finds on `PATH` there. The leftover-tmux
  probe reads this file to recognize a tmux server by the name of the binary
  it runs from. A valid saved path is never replaced. An
  `--auto` run's `PATH` is the daemon's plus fixed Homebrew directories, so a
  tmux it found would be a guess rather than your shell's choice. See
  [the design](specs/2026-09-22-tmux-fallback-install-seeding-design.md).
- **Launches the app** again, unless you pass `--no-app`. The app is a viewer;
  nothing in it holds a session, so the seconds it is down cost no work.
- **Wakes what the handover parked**, unless you pass `--no-wake`.
- **Prints a summary and writes the log.**

## What happens to your sessions

Sessions live in pty holders — one `TBDHolder` process per session — not in
the daemon or the app, so neither restarting the app nor replacing the daemon
ends a session: the outgoing daemon lets go of each holder and the new one
adopts it again. The app is stopped only once the new bundle is complete in
`/Applications`, because macOS checks that bundle when the app quits (see
"Stops the app" above). The remaining risk is the new daemon's startup
reconcile. One that read a slow answer on a machine still digesting a build
as a missing session would park live sessions wholesale. Four things make the
handover safe.

- **The successor claims the pid file first.** It starts with
  `TBD_HANDOVER_FROM_PID` naming its predecessor, writes its own pid over the
  pid file, then terminates the predecessor and waits for it to exit. From the
  first instant, anything that would spawn a rescue daemon — the app's
  two-second watchdog, a daemon started by hand — finds a live daemon named in
  that file and exits at the single-instance gate. `scripts/restart.sh`
  replaces the daemon through this same handover. There is a brief window with
  no socket, the same window every restart has always had, in which CLI calls
  fail and retry.
- **Reconcile parks only on positive evidence.** A holder row is parked only
  when its holder's exit probe answers that the holder is gone; a round trip
  that merely failed leaves the row alone. A row still on tmux is parked only
  when every place this daemon can find its tmux server's socket is missing
  or refuses connections and no tmux process of this user names that server;
  any other answer, a timeout included, leaves it live; see
  [the design](specs/2026-10-11-holder-transport-migration-design.md#a-live-row-whose-tmux-server-outlived-the-update).
- **A second un-park pass runs after reconcile.** The first pass runs before
  reconcile, so it cannot repair a park the same boot creates. The second one
  can, and it undoes any park left over a holder child that is still running.
- **What is left gets woken, paced.** Whatever is still parked with reason
  `recovery` after the handover began is genuinely gone and needs a respawn.
  The script wakes those three at a time, two seconds apart, because N
  simultaneous `claude --resume` respawns have taken a machine down before
  (issues #284 and #367). The counts land in the summary, failures included.
  Only sessions on the pty holder are woken. A session parked on the tmux
  transport is left parked and not counted: the daemon starts sessions only on
  the holder, so waking it would move it there, and moving a session is its
  owner's choice, not an update's, so the update itself never moves one.
  Selecting it in the app, clicking its parked pane or sending to it moves it
  and resumes it; **Move to Holder (No tmux)** in the tab's menu, or
  `tbd terminal migrate`, moves it, and a wake after that resumes it.

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
build exists. `tbd update --check` writes it too. The file is written by an
update run, so a source set by hand takes effect for the check after the next
run. The daemon reads the file on every check, and its status reports which ref
it compared against (`comparedRef`). An install that already runs the newest
published commit is up to date even when `main` has moved on; an install that
compiles from `main` is compared against `main`, and keeps its notice.

## When the notice stays quiet

The app's "A newer TBD is available" notice only appears when someone has to
act on it. It is hidden while updates install on their own, which is either of:

- **`update-mode` is `auto`.**
- **An external auto-updater is on.** It signals that by creating
  `~/tbd/updates/external-auto-enabled` (under `TBD_HOME` when that is set) and
  removing it when it turns off. Only the file's existence matters. The daemon
  checks it each time it reports status, so toggling it needs no restart.

In place of the notice, the app shows a small dismissable line, "Update
installs when idle", but only when a newer build has been waiting for more than
a day while auto-update is on. The daemon tracks when it first saw the latest
commit, in memory, so a daemon restart restarts that clock. Dismissing the line
or the notice hides it for that commit; the next commit shows it again.

Checking by hand always works and always reports the truth. The "Check for
Updates…" menu item, `tbd version --check`, and the version label in the status
bar answer the same way whether or not auto-update is on. With auto-update on,
the menu item's answer adds that the update installs when idle. The Settings
caption under the picker says when an external auto-updater is hiding the
notice.

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
- `--wake-only` — wake every recovery-parked session on the pty holder
  against the running daemon, and do nothing else.
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
  update copies the app bundle it is replacing to
  `~/tbd/updates/previous/TBD.app` and leaves it there. An update that finds
  nothing installed keeps nothing, and leaves a bundle an earlier update kept
  where it is. So does one that finds installed the very build it is
  installing — the same commit, update clone and dirty flag in the bundle's
  `Contents/TBDBuildIdentity.json` — as a run cut short after its swap leaves
  it, or a re-run over a completed update: a copy of that build is no way
  back, and would replace the kept bundle, which may be. Any other bundle is
  kept, even one of the same commit built from another worktree or from a
  dirty tree. Put it back the way an install does, so that
  `/Applications/TBD.app` is never missing if the app quits meanwhile (see
  "Stops the app" above).

  First look for `/Applications/.TBD-install-outgoing` (`ls -a /Applications`
  lists it). If it is there with nothing at `/Applications/TBD.app`, an
  install stopped between its two renames, and it is the bundle that was
  installed, whole. Rename it back before anything else:
  `mv /Applications/.TBD-install-outgoing /Applications/TBD.app`. If it is
  there beside an installed bundle, it is left over from an earlier install:
  rename it to `/Applications/.TBD-install-discard` and delete it there. The
  command below does nothing while that name is taken. Then:

  ```bash
  ( cd /Applications &&
    [ ! -e .TBD-install-outgoing ] &&
    rm -rf .TBD-install-incoming .TBD-install-discard &&
    /bin/cp -cR ~/tbd/updates/previous/TBD.app .TBD-install-incoming &&
    { [ ! -e TBD.app ] || mv TBD.app .TBD-install-outgoing; } &&
    mv .TBD-install-incoming TBD.app &&
    if [ -e .TBD-install-outgoing ]; then
      mv .TBD-install-outgoing .TBD-install-discard && rm -rf .TBD-install-discard
    fi )
  ```

  - **The `rm`** – clears what an interrupted install may have left at the
    incoming and discard names, neither of which holds a bundle anything puts
    back.
  - **The copy** – puts the kept bundle beside the installed one; a copy that
    fails stops the command before the installed bundle moves.
  - **The two `mv`s** – swap it in back to back, so the installed path is
    empty only between them. With nothing installed, only the second runs.
  - **The last step** – removes the bundle it replaced by way of the discard
    name.

  Then relaunch. The restored bundle's `Contents/SourceWorktreePath.txt`
  names the tree the previous daemon came from, so `scripts/restart.sh
  --release` run from inside that tree completes the rollback for the daemon
  as well.
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
up rolls back by itself. The daemon it started with is still the one
running, so the rollback puts back the bundle that matches the running
daemon, going by the commit in each bundle's `Contents/TBDBuildIdentity.json`
and the commit the daemon reported when the run began. When the installed
bundle already is that build — a re-run over the build the daemon runs —
there is nothing to put back. When the kept bundle is, the run waits until
three seconds have passed since the app it stopped exited, so that nothing
moves the bundle while macOS may still be checking it, then swaps the kept
bundle back in the same way an install does — copied in beside the new one,
then two renames — and tells LaunchServices about it. It logs `restored
previous app bundle` (with a note when LaunchServices could not register it,
which fails nothing but can leave `tbd://` links and the icon stale). The
kept copy is spent: it is the bundle now installed. When the daemon reported
no build, the run puts back the kept bundle only if it kept that bundle
itself. Either way it then puts the update clone's `.build/release` link back
the way the run found it, relaunches the app it stopped before the handover,
and exits non-zero. That is the case the kept bundle exists for — a new app
driving the old daemon is a state nobody should be left in. The relaunch
also covers a handover that failed after the old daemon had already exited:
an app that finds no daemon starts one. Under `--no-app` the app was never
stopped, so the swap back runs without the wait.

An install that fails, because the copy into `/Applications` does not
complete, has changed nothing there: the installed bundle is the one the run
started with, whole. The run removes what it copied, puts the `.build/release`
link back, and exits non-zero, but relaunches nothing: the install comes
before the app is stopped, so the app is still running. The one install
failure that can change `/Applications` is a swap whose second rename fails
and whose first cannot then be undone, which leaves nothing at
`/Applications/TBD.app` with the app still running in front of the empty path.
The run tries the rename back once more, and if that works it ends as an
install that changed nothing. If it fails again, the error names
`/Applications/.TBD-install-outgoing`, where the bundle that was installed is,
and a `WARNING` line says not to quit TBD until a whole bundle is back, with
the command that puts it back:
`mv "/Applications/.TBD-install-outgoing" "/Applications/TBD.app"`. The next
install does that itself before it starts. Only a tree there that looks like
a whole bundle — `Contents/Info.plist` present and `Contents/MacOS/TBDApp`
executable, the test the put-back makes — gets that command. For any other,
the warning points at the kept bundle instead, and says to rename the tree
out of the way to `/Applications/.TBD-install-discard` first, since the way
back under "Going back to the previous build" runs only once that name is
free. A rollback whose swap leaves nothing installed gets the same second
try and the same warning.

The relaunch waits on both halves of that rollback. When either fails — no
bundle of the daemon's build is at hand, as on a first update, or the bundle
or the `.build/release` link cannot be put back — the new build may still be
what an app would launch, or what it would start a daemon from, so the run
leaves the app it stopped not running. It logs which half failed, then an
error saying the rollback of the failed install did not complete, and the
report and recovery steps below. A kept bundle of another build than the
daemon's, such as an older one an earlier update kept, stays where it is,
and the new build stays in `/Applications`, as on the first update, so that
it is there to open once it and the daemon are the same build.

A run interrupted while it installs the bundle and hands the daemon over —
Ctrl-C, a signal, or a step that exits — does not launch the app again
either. It leaves the app as it is: not running if the run had stopped it,
still running if the interruption came before the stop. Putting the kept
bundle back is no safer than relaunching, because once the handover has
begun the new daemon may already be up. What the run does first is what is
safe whatever the interruption cut short:

- **The installed bundle** – one left at `/Applications/.TBD-install-outgoing`
  with nothing installed, by an interruption between the swap's two renames,
  goes straight back. A run killed outright there leaves that to the next
  install.
- **The kept bundle** – one an interruption between the two renames that
  keep a copy left at a hidden name beside `~/tbd/updates/previous/TBD.app`
  is renamed back. The next update does the same before it clears anything,
  and installs nothing when it cannot.
- **The release link** – if the swap had not yet run, the update clone's
  `.build/release` goes back as after a failed install. The run points it at
  the new build before the install begins, and an app starts its next daemon
  from it.

Then the run logs an error saying it was interrupted while installing, a
line saying the app is not running when the run had stopped it, or may not
be running when the interruption came while the run was still stopping it,
and reports what is installed, what the daemon runs and where the kept
bundle is:

- **New build** – the commit the run was installing.
- **Installed bundle** – the build `/Applications/TBD.app` holds, read from
  its `Contents/TBDBuildIdentity.json`, or none.
- **Daemon** – the build it reported when the run began, or unknown once the
  handover had begun.
- **Kept bundle** – where it is and its build, or none.
- **Release link** – where `.build/release` points and the build it holds.

When the installed bundle and the daemon are known to be the same build and
`.build/release` holds that build too, nothing needs recovering, and the run
says so. An interruption before the swap leaves that on a run that installs
a downloaded build, when app and daemon were the same build to begin with. A
local build has written the new build into `.build/release` itself, which no
link undoes, and an interruption after the swap leaves the new build
installed in front of the daemon the run started with or, once the handover
has begun, one it cannot name, so each of those gets the recovery steps,
which name the kept bundle where it is. The next update clears what else the
run left beside either bundle.

To recover from either:

- **Check what is running.** `tbd version` names the daemon's commit, and
  `/Applications/TBD.app/Contents/TBDBuildIdentity.json` names the bundle's.
- **Run `tbd update` again.** A run that completes its handover leaves the
  bundle and the daemon on the same build and launches the app at the end.
- **Or open `/Applications/TBD.app` yourself** once it and the daemon are the
  same build.
- **Or go back** with the kept bundle, at the path the report names, as
  described above, once the build the report gives for it is the one the
  daemon runs.

An interruption before the install starts leaves the app running, because
nothing has moved and the app has not been stopped. One after the handover
has completed launches the app again as usual, because the bundle and the
daemon are then the same new build.

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
columns and their data. The daemon keeps the newest three copies of each kind
(`pre-column-drop` and `pre-migration`) beside the database and deletes older
ones, so copy it elsewhere if you need it longer. It prunes a kind only after
the step that writes it succeeds — migrations for `pre-migration`, a column-drop
run with no failures for `pre-column-drop` — and a prune never deletes the copy
just written, so a migration that keeps failing keeps every copy. A column-drop
run that dropped nothing, because every drop it tried failed, deletes the copy
it wrote, which holds nothing the database lacks, so a drop that keeps failing
does not add a copy at every start. See
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
