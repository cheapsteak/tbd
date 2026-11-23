# Launch the daemon outside any app's coalition

On macOS 26 and later, quitting a GUI app can kill every process that app started, however
detached. TBD's daemon inherits the launchd coalition of whatever starts it, TBD.app or a
terminal app, and so does every holder and agent the daemon spawns. This spec starts the daemon
through a small, stable helper app, **TBD Server**, as a one-shot launchd job. The daemon and its
sessions then sit in a coalition of their own. The helper is also the privacy (TCC) identity the
user grants protected-folder and Local Network access to, so agents keep working.

The behavior ships behind `daemon_launch_helper_enabled`, default off.

The maintainer chose the helper-app approach over the alternatives below, ad-hoc signing with a
build-once install, and onboarding by documentation and a CLI check during the soak, with an
onboarding UI as a precondition for graduation.

## Why

### The incident

On 2026-11-22 an unattended `tbd update --auto` killed live Claude session
`85F0BF14-3777-4E44-B844-36ECA4537919`. Its holder (pid 60212) and agent (pid 60213) had been
spawned by a daemon that TBD.app auto-started, so both were in the app's coalition. The unified
log shows the kill:

- **14:00:57.627** – loginwindow: `applicationDeath: app=… "TBD" (63631), has related coalition
  pids [ 60051/tmux, 60052/zsh, 60212/TBDHolder, 60213/2.1.330, … ]`.
- **14:00:57.633** – backgroundtaskmanagementd: `bundle … node has changed`, then
  `BTMCodeSignInfo initWithURL: result=-67028` ("bundle format unrecognized, invalid, or
  unsuitable"), then `checkTasksAllowedInBackgroundForAppURL: result=invalid parameter (-98)`.
  update.sh was swapping `/Applications/TBD.app` while Background Task Management (BTM) read it.
- **14:00:57.634** – loginwindow: `askBTM: Error -98 … so not allowed to run in the
  background` → `scheduling its subordinates' termination`.
- **14:00:58.701** – loginwindow: `… not allowed by BTM so terminating its subordinates` →
  `_LSForceQuitApplication` → `quitOrKillSubordinateProcesses`.
- **14:00:58.709** – the agent enters its exit handler. The holder dies by SIGTERM's default
  action and leaves its socket behind, so the new daemon's probe gets `ECONNREFUSED` at 59.493.

An hour earlier the same kind of update quit the app too. That time BTM read a whole bundle and
answered "unknown to BTM … temporarily allowed … because record not found", and nothing died.
Sessions spawned by a daemon that update.sh had started from a terminal survived both quits:
they sat in the terminal's coalition, not the app's.

### The mechanism

- **macOS polices processes that outlive their app.** WWDC25 session 246 announced that macOS
  Tahoe detects processes an app started with fork, exec or `posix_spawn` that keep running after
  it exits. Apple documents the user-facing policy in "Managing ongoing background processes in
  your Mac" and nothing below it.
- **loginwindow decides from BTM's answer.** When a foreground app dies with other processes in
  its coalition, loginwindow asks BTM whether the app may run in the background:
  - "allowed", or "unknown, temporarily allowed": the processes are kept.
  - "not allowed": about a second later loginwindow SIGTERMs every process in the coalition.
  - An error, such as -98: treated as "not allowed".
- **Force Quit takes a path with no BTM question** (`terminateAppAndSubprocesses`, reported in
  herdr#5205). Switching the app off in Login Items & Extensions also terminates its subordinates
  (t3code#26604).
- **Coalition membership survives every detachment a process can do to itself.** fork,
  `posix_spawn`, `setsid`, a double fork and `responsibility_spawnattrs_setdisclaim` all leave
  the child in its parent's coalition (diri#648 measured this with `lsappinfo`). A launchd job
  that the coalition bootstraps and that keeps running is unloaded with it (diri#742, Kaku#591,
  herdr#4920).
- **A one-shot launchd job whose process exits at once does escape.** launchd gives each job a
  coalition of its own. herdr#5236 starts its server as a job whose process forks the server and
  exits, and its maintainer verified that the server survives Cmd-Q of the terminal.

### What a fixed update does not fix

update.sh keeps a complete, validly signed bundle at `/Applications/TBD.app` until
loginwindow's check is over (`docs/updating.md`, "The app's exit and the bundle at its path").
That removes this incident's trigger and nothing else. Sessions in an app's coalition still die
when:

- the user Force Quits the app;
- the user switches off TBD's background activity, which the Dock menu offers after the first
  background run, so every later quit reads "not allowed";
- BTM fails for any other reason;
- a GUI app an agent launched is force-quit and takes the coalition with it (agterm#985,
  diri#693, herdr#5784).

The same holds for a terminal app's coalition. On the machine that lost the session, measured
with `proc_pidinfo(PROC_PIDCOALITIONINFO)`, the running daemon, all six holders and their
agents shared resource coalition 106897 with iTerm2. Quitting iTerm2 under a "not allowed"
answer would have killed every session.

## Constraints

### Privacy identity

macOS grants protected-folder access (`~/Documents`, `~/Desktop`, `~/Downloads`, removable
volumes), Full Disk Access and Local Network access to a process's **responsible process**, not
to the process itself.

- **Children inherit responsibility** through fork, exec and `posix_spawn` (DTS, forum 805245).
  Today an agent uses the grants of whatever started the daemon: iTerm2's, or TBD.app's.
- **A launchd job is its own responsible process.** It does not inherit the grants of the app
  that bootstrapped it. After herdr moved its server to a launchd job, its panes lost Local
  Network, Files & Folders and removable volumes (herdr#808).
- **Inheriting another app's grants requires being spawned by that app,** which puts the process
  in that app's coalition. No source found offers both.
- **Attribution reportedly breaks once the responsible process exits.** In herdr#808, LAN access
  flipped mid-run when the spawner exited; claude-code#59065 and herdr#3239 report "Failed to
  create Attribution Chain" for a daemon re-parented to launchd. These are reports, not Apple
  documentation.
- **An ad-hoc signature identifies one exact build** (TN3127), so rebuilding an ad-hoc binary
  drops its grants. Local Network also keys on the main executable's UUID (TN3179).
- **Local Network fails silently for a process with no bundle.** There is no prompt and no
  Settings entry, and connections fail with `EHOSTUNREACH` (herdr#808, forum 778457). A bundle
  with `NSLocalNetworkUsageDescription` gets a prompt that names it.

### Cost of a launchd launch

- **Latency:** about 60 ms median, 115 ms at worst, per job (herdr-core#98). TBD launches one job
  per daemon start.
- **launchd can accept a job and never run it** (diri#716). The launcher needs a deadline and a
  fallback.
- **Finished jobs stay registered until something boots them out** (wmux#2003).

## Design

### Components

**TBD Server.app**, a new helper bundle:

- built from a new executable target, `Sources/TBDServer`, with its own `Info.plist`: bundle
  identifier `com.github.cheapsteak.tbd.server`, `LSUIElement`, and an
  `NSLocalNetworkUsageDescription` that says agents in TBD sessions reach hosts on the local
  network;
- installed at `$TBD_HOME/helper/<HelperVersion>/TBD Server.app`, outside the bundle that updates
  replace;
- ad-hoc signed once at install and never rebuilt in place, so a grant made to it lasts as long as
  that version stays installed;
- versioned by `HelperVersion`, a constant shared with the daemon. A test hashes
  `Sources/TBDServer` and fails when the sources change while `HelperVersion` does not, so a
  changed helper always installs as a new version.

The helper has three modes:

- **`--launch`** runs in the launcher's process tree. It submits the job, waits for the daemon's
  pid, cleans up and prints the pid.
- **`--job`** is the launchd job's program. It spawns `--serve` and exits.
- **`--serve`** is the daemon's parent and the sessions' privacy identity. It lives until nothing
  else is left in its coalition.

### Launch sequence

1. The launcher runs `TBD Server --launch` with the daemon's path, the log path and its own
   environment, which includes `TBD_HANDOVER_FROM_PID` during a handover.
2. `--launch` creates `$TBD_HOME/helper/launches/<uuid>/` with mode `0700` and writes
   `job.plist` into it. The plist carries the launcher's environment, which can hold tokens, so
   it and every other file `--launch` and `--serve` write in that directory are mode `0600`:
   - `Label` `com.github.cheapsteak.tbd.daemon.<uuid>`;
   - `ProgramArguments`: the helper executable, `--job`, the launch directory, the daemon path
     and the log path;
   - `RunAtLoad` true, `KeepAlive` false, `AbandonProcessGroup` true, `ProcessType`
     `Interactive`;
   - `EnvironmentVariables`: the launcher's whole environment, minus any inherited
     `TBD_LAUNCH_FALLBACK_REASON`, plus `TBD_LAUNCH_MODE=helper` and `TBD_HELPER_VERSION`;
   - `WorkingDirectory`, `Umask` and the soft and hard `NumberOfFiles` limits: the launcher's
     own.
3. `--launch` runs `launchctl bootstrap gui/<uid> <job.plist>`. launchd starts `--job` in a new
   coalition.
4. `--job` spawns `--serve` with `POSIX_SPAWN_SETSID` and responsibility disclaimed, through
   `responsibility_spawnattrs_setdisclaim`, a private symbol it looks up with `dlsym`. Then
   `--job` exits.
   - **Why `--job` exits at once:** a job whose own process keeps running is unloaded with the
     coalition that bootstrapped it, and its process is SIGTERMed. Only a job whose process has
     already exited has been shown to survive.
   - **Why `--serve` disclaims:** without it, `--serve` inherits `--job` as its responsible
     process, and `--job` is about to exit. Disclaimed, `--serve` is its own responsible process
     for as long as it lives, and it stays in the job's coalition.
5. `--serve` first claims the launch: it creates the launch directory's `claim` file with
   `O_CREAT | O_EXCL`. If the file already exists, or the launch directory is gone, `--launch`
   has given up on this launch, and `--serve` exits without spawning anything. Having claimed it, `--serve` opens the log path for
   writing, spawns the daemon with that file as stdout and stderr, and writes the daemon's pid to
   the `pid` file (written to a temporary name, then renamed). If the spawn fails, it writes
   `error: <reason>` there instead and exits.
6. `--launch` checks for the `pid` file every 20 ms until a 5-second deadline on an injected
   clock. launchd starts a job in tens of milliseconds, and missing the deadline costs only a
   fallback. At the deadline `--launch` tries to create `claim` itself, the same way:
   - **It creates it:** no daemon can start from this launch, so it fails and the launcher falls
     back.
   - **`--serve` holds it already:** the spawn is under way. `--launch` waits up to a further 5
     seconds for the `pid` or `error:` result. Past that it fails anyway, and the daemon's
     pid-file gate is the backstop against a second daemon.

   The claim is what keeps a late helper launch and a direct fallback from both starting a
   daemon. The pid-file gate alone cannot: during a handover both carry `TBD_HANDOVER_FROM_PID`,
   which is the way past that gate.
7. On success `--launch` boots out the finished job, removes the launch directory and prints the
   pid. The launcher waits on that pid exactly as it waits on `$!` today.

The daemon spawns holders, and holders spawn agents, as they do today. Each one inherits the
job's coalition and has `--serve` as its responsible process. Quitting TBD.app or a terminal
cannot reach them through coalition membership, and their privacy grants are the ones the user
gives TBD Server.

### Lifetime of `--serve`

- **It waits on the daemon** with `waitpid` and logs the exit status under subsystem
  `com.tbd.server`, so a daemon crash leaves a record without a log file to reclaim.
- **It stays while anything else is in its coalition.** Every 30 seconds, on an injected clock, it
  lists processes and reads each one's coalition with `PROC_PIDCOALITIONINFO`, which needs no
  root. When it is the only member left, it exits. If the listing fails, it stays.
  - Parentage cannot answer this question. Holders outlive their daemon across handovers and
    re-parent to launchd, but they stay in the coalition.
  - A process an agent left running, a dev server say, keeps `--serve` alive. That is correct:
    the process still relies on `--serve` for its privacy attribution.
- **It forwards no signals.** Launchers stop a daemon by the daemon's own pid. A SIGTERM to
  `--serve`, at logout for example, ends only `--serve`. The sessions keep running, at worst
  without their privacy attribution.

### The flag and the launch paths

**The flag.** A `.sql` migration runs
`ALTER TABLE config ADD COLUMN daemon_launch_helper_enabled INTEGER;` with no SQL default. NULL
means nobody chose. `ConfigRecord.toModel()` resolves it as `?? Config.daemonLaunchHelperDefault`,
which is `false`. The user sets it with `tbd config set daemon-launch-helper on|off`. A change
takes effect at the next daemon launch and never moves a running daemon.

**Reading the flag before a daemon runs.** A launch happens when no daemon runs (app auto-start)
or when one is about to be replaced (handover), so a launcher cannot ask over RPC.
`TBDDaemon --launch-mode --home <path>` reads the flag and exits. `<path>` is the real TBD home,
from which it derives the database and the helper path.

Launchers run this probe fenced, the way `scripts/test.sh` fences a test run. `TBD_HOME`,
`TBD_SOCKET_PATH`, `HOME` and `CFFIXED_USER_HOME` point into an empty temporary directory, and
`TBD_HANDOVER_FROM_PID` is removed. A probe still running after 5 seconds is killed. The fence is
for a daemon binary from before `--launch-mode`, which ignores the arguments and starts serving.
Fenced, it claims no real pid file or socket, writes nothing in a real place, and retires no
predecessor, and the time limit ends it. Launchers and binaries normally come from one build, so
this guards only mixed states, such as a script newer than the binary beside it.

- It opens the database read-only and reads only `daemon_launch_helper_enabled`. The launching
  binary is newer than the database it reads, so a database the column has not reached yet reads
  as NULL. So does a missing database.
- It resolves NULL through `Config.daemonLaunchHelperDefault`, the same constant
  `ConfigRecord.toModel()` uses. A test holds the two readers to the same answer for NULL, 0 and 1.
- It prints `direct`, or `helper` followed by the path of the helper executable for the
  `HelperVersion` it was built with, under `<path>`.

**Launchers.** Three places start a daemon, and each branches on `--launch-mode`:

- `restart_daemon_by_handover` in `scripts/restart-bundle-lib.sh`, which `scripts/restart.sh`
  uses;
- the handover launch in `scripts/update.sh`, both interactive and `--auto`;
- `DaemonClient.launchDaemon` in `Sources/TBDApp/DaemonClient.swift`, the app's auto-start.

In `direct` mode each launches as it does today, except that it removes `TBD_LAUNCH_MODE`,
`TBD_HELPER_VERSION` and `TBD_LAUNCH_FALLBACK_REASON` from the daemon's environment. A daemon
passes its environment on to what it starts, so without that, an update a helper-launched daemon
started would label its direct launch `helper`. In `helper` mode each runs `TBD Server --launch`
and takes the daemon's pid from its output. Handover waits, readiness checks and stop-on-failure
keep working on that pid unchanged. A failing `--launch-mode` reads as `direct`.

The app's auto-start keeps no daemon log today, and passes `/dev/null` as the log path.

Tests, `scripts/test.sh`, mock-mode daemons and CI never go through a launcher and are
unaffected.

### Failure and fallback

A launcher falls back when no helper is installed at the path `--launch-mode` printed, or when
`--launch` fails. `--launch` exits non-zero, with its reason on stderr, when:

- `launchctl bootstrap` fails, as it does over SSH with no GUI session;
- the disclaim symbol is missing;
- `--serve` reports a spawn error;
- the pid deadline passes and `--launch` takes the claim, or the further wait after `--serve`
  took it passes.

`--launch` boots out the job and removes the launch directory before it exits. The launcher logs the
reason and launches the daemon directly, removing the inherited labels as any direct launch does
and setting `TBD_LAUNCH_FALLBACK_REASON` in the daemon's environment. A failed helper launch therefore costs exactly today's exposure, and never leaves
the user without a daemon.

### Handover and existing sessions

- **Every launch creates its own job, coalition and `--serve`.** A handover's successor runs under
  a new `--serve`. The previous `--serve` lingers until its last holder ends, so after a few
  updates a few idle `--serve` processes may run, each bounded by its own sessions.
- **A process keeps its coalition for life.** After the flag goes on, a session that a directly
  launched daemon spawned stays exposed until it ends or the user parks and wakes it. A wake
  spawns a new holder under the current daemon. `tbd doctor sessions` lists the sessions still
  exposed.
- **update.sh runs inside the helper's coalition** when the daemon's `UpdateLauncher` starts it,
  and its own `--launch` gives the successor a fresh coalition. Quitting TBD.app during an
  update reaches neither.

### Installing the helper

update.sh and restart.sh install the helper when `$TBD_HOME/helper/<HelperVersion>/` is missing,
and only then:

1. Build the `TBDServer` product with the rest of the build. A release download carries it with
   the other products. The install learns the version from `TBD Server --helper-version`.
2. Assemble `TBD Server.app` from the binary and `Sources/TBDServer/Info.plist`, in a temporary
   `.install-*` directory beside the version directory.
3. Sign it ad hoc and verify the signature.
4. Rename it into place, then register it with Launch Services (`lsregister -f`), so that the
   Local Network prompt and System Settings show it by name.

Keying by version, rather than replacing one copy, keeps grants when the user switches between
worktrees on different helper versions. A running `--serve` of an older version also keeps its
binary.

The app never installs the helper. When it is missing, the app's auto-start falls back to a
direct launch.

`--launch` touches `$TBD_HOME/helper/<HelperVersion>/last-used` on every launch.

### Durable resources and their reconcilers

- **launchd job registrations and launch directories.** `--launch` removes its own on success
  and on failure. A `--launch` killed partway leaves both behind. `OrphanGC`, under `gcEnabled`,
  boots out any job labelled `com.github.cheapsteak.tbd.daemon.` that is not running and whose
  launch directory is older than `gcGraceSeconds`, then removes the directory. Each half is
  judged on its own: a registration with no launch directory is booted out when it is not
  running, and a launch directory with no registration is removed once it is older than
  `gcGraceSeconds`.
  - Booting out a finished job must leave `--serve` and the daemon running, and a live test
    proves it before this ships. If the test shows otherwise, nothing boots out finished jobs:
    they are inert and vanish at logout, and `OrphanGC` removes only the directories.
- **Helper version directories.** `OrphanGC`, under `gcEnabled`, removes one only when no running
  process executes from it and its `last-used` stamp is 30 days old. A directory with no stamp is
  dated by its own modification time. A process listing that fails, or a TBD Server process
  whose executable path cannot be read, counts as in use. Only TBD Server executes from a
  version directory, so other processes do not count. The 30 days spare the grants of a version
  that a worktree launches now and then. An install killed partway leaves its `.install-*`
  directory, which is reclaimed under the same rule as a version directory no process uses.
- **`--serve` processes.** No reconciler covers them, because an orphan cannot arise: a `--serve`
  lives only while some other process in its coalition lives, and that process depends on it.

### Diagnostics

- **`daemon.status`** gains optional `launchMode`, `launchFallbackReason` and `helperVersion`.
  The daemon fills them from `TBD_LAUNCH_MODE`, `TBD_LAUNCH_FALLBACK_REASON` and
  `TBD_HELPER_VERSION`.
- **`tbd doctor sessions`** is a new check. The existing `tbd doctor` keeps checking the CLI
  install. It reports:
  - how the daemon was launched, and why it fell back if it did;
  - the daemon's coalition, the coalition of each live holder TBD has a row for, and any GUI
    app that shares a holder's coalition. A GUI app is a process whose executable sits in an
    `.app` bundle's `Contents/MacOS`, other than TBD Server. A holder is protected when a
    `--serve` of any helper version is in its coalition and no GUI app is. After a handover,
    older holders stay under the previous `--serve`, and they are protected too. Any other holder
    is exposed, and doctor suggests parking and waking it;
  - doctor's own responsible process, read through the private
    `responsibility_get_pid_responsible_for_pid` when it resolves, or "unknown";
  - whether it can list `~/Documents` and `~/Desktop`;
  - whether a TCP connect to the default gateway on port 80 is allowed, with a 2-second
    timeout: refused or connected means allowed, `EHOSTUNREACH` means denied, a timeout means
    unknown.

  Doctor knows it runs inside a TBD session when a `--serve` shares its coalition. There it has
  `--serve` as its responsible process and shares the sessions' privacy identity, so its privacy
  answers are the sessions' real ones. Run anywhere else, it says that its answers
  describe its own context, not the sessions'. The first run inside a TBD tab may raise the macOS
  prompts that name TBD Server, which is how the user grants them.

## Placement

- **Leaving the coalition is mechanism.** No project wants its sessions killed when a terminal
  quits, and no shell construct leaves a coalition. The helper compiles because user-land cannot
  spawn with responsibility disclaimed, read coalition membership, or stay alive as a privacy
  identity.
- **The flag's resolution compiles once,** in `Config`. `--launch-mode` exposes it as a fact to
  launchers, so no script parses the database.
- **The launch decision and its fallback live in the launchers,** and two of the three launchers
  are scripts. Falling back to a direct launch is a "what instead". No consumer has asked to fail
  closed, so this spec sets the fallback and a script can change it.
- **The numbers are cost bounds, not policy.** The 30-second coalition poll costs one process
  listing. The 5-second pid deadline is far past launchd's tens of milliseconds. The 30-day
  version retention only decides when a disk directory goes.
- **Diagnosis stays in the CLI.** `tbd doctor sessions` adds facts (launch mode, coalitions,
  responsible process, probe results) and no policy.

## Residual risks

- **GUI apps that agents launch still join the daemon's coalition.** Force-quitting one, or
  loginwindow terminating one, can take the coalition with it (herdr#5784, diri#693). Giving each
  holder a launchd job of its own would contain that at about 60 ms per spawn. That is follow-up
  work.
- **The design leans on private SPI.** `responsibility_spawnattrs_setdisclaim` is looked up at
  runtime, and its absence falls back to a direct launch.
- **The privacy evidence is partly reported, not documented.** Local Network under this pattern
  was measured by one user. Full Disk Access was not measured. The soak checks both.
- **Each helper version needs its grants again.** The helper's sources rarely change, and the
  release notes say so when they do.

## Rejected alternatives

- **A plain one-shot job that forks the daemon and exits** (herdr#5236). It leaves the coalition,
  but agents become their own privacy identity, an ad-hoc binary rebuilt on every update, and
  lose protected folders and the LAN (herdr#808).
- **Staying in TBD.app's coalition** and always launching from the app. Agents keep TBD.app's
  grants, but Force Quit, a revoked background permission and agent-launched GUI apps still kill
  sessions.
- **An `SMAppService` agent registered by TBD.app.** It needs a TBD.app signature that survives
  updates, and TBD.app is re-signed ad hoc on each one. The registration shows in Login Items as a
  persistent item. Local Network attribution on that path is unproven, and ad-hoc registrations
  reportedly pin to the build that registered them.
- **`AssociatedBundleIdentifiers` in the job plist.** It requires the job and the app to share a
  Team ID, which ad-hoc code lacks, and a DTS test found Local Network ignores it (forum 774160).
- **Disclaiming responsibility per agent,** the iTerm2 and Chromium pattern. Each agent binary
  becomes its own identity, and Claude Code's versioned install path re-prompts on every update.
- **`setsid`, a double fork, `launchctl submit`, or a job whose process keeps running.** None
  leaves the coalition, or the job is unloaded with it.
- **`open` of a background-only app bundle.** The process gets its own coalition, but it becomes an
  application loginwindow polices in its own right, and one never shown and not allowed is
  terminated with its subordinates (agterm#985).
- **One long-lived `--serve` that spawns each successor daemon on request.** It adds a protocol
  and helper-daemon version skew, and buys nothing over a `--serve` per launch.
- **Leaving the fallback race to the daemon's pid-file gate.** During a handover both a late
  helper daemon and the direct fallback carry `TBD_HANDOVER_FROM_PID`, the way past that gate, so
  it cannot pick one. Having `--serve` kill a daemon it spawned after the deadline was rejected
  too: a daemon that starts and is killed can disturb a handover in progress.
- **A marker file beside the binaries saying they understand `--launch-mode`.** It is one more
  artifact to keep in step with the binary, where the fenced probe makes an old binary harmless
  whatever it does.
- **Forwarding SIGTERM from `--serve` to the daemon.** It gives anything that signals `--serve` a
  path to stop the daemon. Launchers already stop the daemon by its pid.
- **A self-signed certificate, or an Apple Development identity, for the helper.** Either could
  keep grants across helper rebuilds. The maintainer chose ad-hoc signing with a build-once
  install: it needs no keychain setup, and helper changes are rare enough that re-granting is
  cheap.

## Testing

Every branch the flag gates is tested in both states, as `CLAUDE.md` requires.

**Unit tests**

- **Flag states:** a pre-migration row reads NULL. An explicit `false` survives a change to the
  default constant, and NULL follows it. `--launch-mode` prints `direct` for no database, a
  database without the column, NULL and `0`, and `helper` for `1`.
- **Job plist builder:** every key in step 2 of the launch sequence, with a unique label, an
  inherited fallback reason dropped, and modes `0700` and `0600`.
- **`--launch` failures,** with an injected `launchctl` runner and clock: bootstrap refused,
  disclaim symbol missing, spawn error, deadline passed with the claim taken by `--launch`, and
  deadline passed with the claim taken by `--serve` but no result. Each boots out the job,
  removes the directory and exits non-zero with its reason.
- **The claim:** `--serve` that finds `claim` already created spawns nothing. `--launch` that
  finds it taken by `--serve` waits for the result instead of failing at the first deadline.
- **`--serve` lifetime,** with an injected coalition lister and clock: it stays while another
  member remains, exits when alone, and stays when the listing fails.
- **`OrphanGC`,** with an injected `launchctl` runner, so no test registers or boots out a real
  job:
  - job registrations and launch directories: a young one kept, a running one kept, a stale one
    removed;
  - version directories: one in use kept, one with a recent stamp kept, one with unreadable
    process information kept, an old unused one removed;
  - both legs off when `gcEnabled` is off.
- **Helper-version guard:** changing `Sources/TBDServer` without bumping `HelperVersion` fails.
- **Graduation tripwire:** a test pins `Config.daemonLaunchHelperDefault == false`. Its failure
  message names the onboarding precondition under "Graduation" below.

**Script harnesses** (`scripts/restart-bundle-lib.test.sh`, `scripts/update.test.sh`)

- `direct` launches with the unchanged line, less any inherited `TBD_LAUNCH_*` labels.
- `helper` invokes the helper with the environment and the log path, and waits on the pid it
  prints.
- A missing helper, or a failed helper launch, falls back to a direct launch, logs the reason and
  sets `TBD_LAUNCH_FALLBACK_REASON`.
- A failing `--launch-mode` launches directly.
- The probe runs fenced: a stand-in daemon that ignores `--launch-mode` and starts serving sees
  only the temporary home, no `TBD_HANDOVER_FROM_PID`, and is killed at the time limit.
- An install runs only when the version directory is missing.

**App**

- `DaemonClient` takes the direct branch, the helper branch and the fallback, through an injected
  launcher.

**Live tests,** opt-in with `TBD_LIVE_LAUNCHD=1`, using the label prefix
`com.github.cheapsteak.tbd.test.` so the live install's `OrphanGC` never touches them. Results
are recorded in the implementing PR.

- A process spawned directly stays in its caller's coalition. A helper-launched stand-in runs in
  another coalition and launchd does not restart it when it exits.
- Booting out the finished job leaves `--serve` and the stand-in running.
- `--serve` exits after the last other member of its coalition exits.
- `--serve` is its own responsible process, and the stand-in's is `--serve`. The test is skipped
  when the private reader is missing.

## Rollout

**Soak.** Enable with `tbd config set daemon-launch-helper on`, then `scripts/restart.sh` or
`tbd update`. Run these checks on macOS 27 and record each result in this spec:

- Cmd-Q of TBD.app with live sessions: they survive.
- Quitting the terminal app that ran the restart: they survive.
- Force Quit of TBD.app: they survive.
- A `tbd update --auto` handover: they survive, and the previous `--serve` exits once its sessions
  end.
- `tbd doctor sessions` in a TBD tab: the prompts name TBD Server. After granting, it lists
  `~/Documents` and reaches the LAN, and both still work after an update that leaves
  `HelperVersion` unchanged.
- A launch over SSH falls back to a direct launch and says why.
- Nothing TBD started remains after logout.

**Graduation.** The flag graduates when every one of these holds:

- every soak check passes;
- normal use records no fallback, and no TBD holder appears in loginwindow's
  `quitOrKillSubordinateProcesses` lines;
- **the onboarding UI ships.** It tells the user which grants TBD Server needs and opens the
  matching System Settings panes, and it gets a spec of its own.

Graduating means editing the tripwire test and changing `Config.daemonLaunchHelperDefault` to
`true`. The column has no SQL default, so no reset migration runs, and a user who turned the flag
off stays off. Deleting the flag later leaves the direct launch in place as the fallback.

## References

- Apple: WWDC25 session 246; "Managing ongoing background processes in your Mac"; TN3127
  (code-signing requirements); TN3179 (Local Network privacy); Developer Forums threads 731504,
  756510, 774160, 778457, 799162 and 805245.
- herdr: issues #808, #3239, #4228, #4920, #5205, #5784; PRs #5236 and #5406; herdr-core PR #98.
- diri: PRs #648, #693, #716, #742. Also agterm#985, Kaku#591, t3code#26604, wmux#2003,
  claude-code#59065.
- `docs/research/2026-10-30-herdr/runtime.md` §2 predicted the coalition risk this spec
  addresses.
- `docs/updating.md`, "The app's exit and the bundle at its path".
- `docs/specs/2026-08-15-named-reconciler-doctrine-design.md`.
