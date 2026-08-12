# tmux executable resolution and saved fallback — design

Status: **implemented**.

## Problem

TBD is installed from an interactive shell but normally launched by macOS. Those
launch contexts can have different `PATH` values. A tmux executable that was
available during installation can therefore become unavailable after a crash or a
LaunchServices relaunch, even though the installation itself is otherwise healthy.

TBD needs one predictable way to find tmux without inventing a second environment
policy. It also needs a user-controlled recovery path for installations whose launch
environment genuinely does not expose tmux.

## Design goals

- Preserve the installation shell's exact `PATH` for initial and subsequent app
  launches.
- Resolve tmux from that inherited `PATH` before consulting any fallback.
- Let a user locate tmux when it is absent from `PATH`, and inspect, edit, or clear
  that choice later.
- Make a changed saved fallback visible to the running app and daemon on subsequent
  operations without requiring them to restart.
- Run every multi-command terminal preparation and viewer attachment with one stable
  executable snapshot.
- Keep executable discovery explicit, narrow, and safe.

## Launch environment authority

The installer captures its current, non-empty `PATH` in the generated app bundle's
`LSEnvironment.PATH`. It also supplies that same value explicitly when opening the
freshly installed app. The bundle value lets macOS apply the installation environment
again when LaunchServices relaunches the app after the original process exits.

The app passes its inherited environment to the daemon. The daemon does not append
directories, invoke a shell, or otherwise reinterpret `PATH`. This gives the app and
daemon one installation-defined search path instead of competing policies.

This policy is daemon-wide, not limited to tmux. Every process the daemon starts
inherits the captured installation `PATH`. The daemon launches the `git` executable
at its existing fixed `/usr/bin/git` path, while helpers that `git` invokes, such as
`git-lfs`, depend on the inherited `PATH`. Tmux alone has the explicit
saved-executable fallback described below; other daemon descendants do not gain
per-tool fallbacks.

Only `PATH` is captured. TBD does not persist the installation shell's whole
environment.

## Resolution order

Every fresh resolution applies this precedence:

1. Split the inherited `PATH` in order.
2. Ignore empty and relative entries.
3. For each absolute entry, look for a regular executable file named `tmux`.
4. Return the first qualifying PATH candidate.
5. If no PATH candidate qualifies, read and validate the saved executable fallback.
6. If neither source produces a valid executable, report tmux as unavailable.

`PATH` always wins, including when a saved fallback exists. A fallback is therefore a
recovery mechanism for a deficient launch environment, not a user override of a valid
installation path.

Resolution performs filesystem inspection only. It does not start a subprocess to
discover an executable.

## Saved fallback

The fallback is a UTF-8 file named `tmux-executable-path` in TBD's configuration
directory. It follows `TBD_HOME`, so app and daemon processes agree on the location
and tests can isolate it from the user's real configuration.

The file stores one trimmed absolute path. Saving validates the value before replacing
the prior file. An invalid edit leaves the previous valid value intact. Clearing the
setting removes the file and is idempotent when no file exists.

A saved value is usable only when it resolves to a regular executable file. Symlinks
are allowed when their resolved target is a regular executable. A missing,
non-executable, relative, directory, or otherwise invalid target is treated as absent.

The file contains only the selected executable path. It does not store `PATH`, other
environment variables, or shell initialization output.

## Startup experience

After app startup, TBD performs a fresh resolution. When tmux is available from
`PATH` or the saved fallback, startup proceeds without interruption.

When resolution fails, TBD presents a Locate tmux prompt. The user can choose an
executable with the system file picker or dismiss the prompt. The prompt appears at
most once during one app-state lifetime; clearing or invalidating the value later does
not repeatedly interrupt the same running session.

The same once-per-lifetime startup check emits a diagnostic that reports the resolved
tmux path and whether it came from `PATH` or the saved fallback, or reports that tmux
is unavailable. It does not log the complete `PATH` or any other environment value.
This makes field regressions in LaunchServices relaunches diagnosable, but does not
replace an OS-level crash-and-relaunch test.

A successful selection is validated, saved, and immediately reflected in app state.
Cancelling the picker or dismissing the prompt does not write configuration.

## Settings experience

Terminal Settings shows three distinct facts and controls:

- **Active executable** — the currently resolved executable and whether it came from
  `PATH` or the saved fallback.
- **Fallback executable** — an editable absolute path with Save, Choose, and Clear
  actions.
- **Backing file** — the tilde-abbreviated path to the fallback configuration file,
  with an affordance that copies the full absolute path.

The active executable remains read-only because it reports the outcome of precedence,
not an override. Editing the fallback while tmux is present on `PATH` does not change
the active source; the saved value becomes relevant only when PATH resolution fails.

## Live behavior

App and daemon owners keep a resolver configured with their inherited environment and
the shared fallback-file location. They resolve again at operation boundaries instead
of permanently caching the selected path.

This means a Settings save or clear affects later terminal preparation, later daemon
tmux commands, and later control-mode gate or capability decisions. Control-mode gate
and capability decisions resolve the executable and detect its version again for each
decision, so replacing the executable in place at an unchanged path also takes effect
without a daemon restart.

Within one terminal preparation, TBD resolves exactly once. The absolute executable
path is carried through session creation, window selection, confirmation, cleanup,
and viewer attachment. A Settings change during that sequence cannot split one
operation across two different tmux executables. The next operation resolves again.

## Failure behavior

An unresolved executable fails closed. TBD does not substitute `/usr/bin/env`, guess a
location, or create terminal state through a different tmux installation. The app
offers the Locate tmux recovery surface, while daemon operations that require tmux
report their existing unavailable or failed result.

An invalid saved path is ignored during resolution and remains visible for correction
in Settings. It never outranks a valid PATH candidate.

## Security and validation

- Only absolute paths are accepted for saved fallbacks and PATH entries.
- Candidates must be executable regular files after resolving symlinks.
- The resolver never evaluates shell syntax or expands variables from saved content.
- The executable is launched directly with an argument array; its path is not
  interpolated into a shell command.
- Diagnostics may report resolution source or success, but must not log the complete
  `PATH` or other environment contents.
- Tests use temporary executable fixtures and configuration files rather than the
  developer's PATH or saved fallback.

## Rejected alternatives

### Fixed installation directories

Searching package-manager or system directories outside `PATH` creates a second,
hidden precedence policy and can silently select a different tmux than the installer
selected. There is no universal directory list across package managers, architectures,
or user-managed toolchains. TBD searches only the authoritative inherited `PATH` and
the explicit saved tmux fallback. Restoring fixed-directory augmentation for `git-lfs`
or other daemon descendants would reintroduce the same hidden policy daemon-wide and
could make subprocess behavior differ from the installation environment.

### Login shell or `path_helper`

Starting a login shell or invoking `path_helper` would execute user-controlled startup
configuration, add latency, and produce an environment that may differ from the one
used to install TBD. It also makes binary selection depend on shell choice and startup
file health. Installation-time `PATH` capture is deterministic and does not run shell
initialization during app startup.

### Persisting the whole environment

An environment snapshot would retain unrelated and potentially sensitive values long
after installation. TBD needs only executable discovery, so persisting anything beyond
the bundle's launch `PATH` and the optional tmux fallback path is unnecessary.

### Making the saved value override PATH

An override would make Settings silently diverge from the installation environment and
could pin TBD to a removed or outdated executable while a healthy `PATH` candidate is
available. PATH-first precedence keeps installation intent authoritative and makes the
fallback's role unambiguous.

### Requiring restart after edits

The fallback file is shared configuration, and resolving it at operation boundaries is
cheap. Restart-only behavior would make Settings appear stale and would leave the app
and daemon disagreeing until both processes restarted. Live re-resolution provides
consistent subsequent behavior while stable per-operation snapshots prevent mid-flight
changes.

## Verification contract

- The installation-path shell harness verifies the plist-generation helper's exact
  round trips, replacement, invalid input, source plist preservation, and generated
  plist validity. It does not exercise an OS-level crash and LaunchServices relaunch
  end to end; the once-per-startup resolution diagnostic is the explicit field
  observability mitigation for that automation gap.
- Resolver tests verify PATH order, executable validation, ignored entries, paths with
  spaces, fallback precedence, and absence of implicit directory search.
- App tests verify startup prompting, saving, clearing, PATH authority, live
  re-resolution, and stable preparation/viewer snapshots.
- Daemon tests verify PATH-only execution, saved-fallback updates, executable/version
  pairing, and hermetic control-mode gate decisions.
- Settings presentation tests verify that the displayed backing path is
  tilde-abbreviated while copying retains the full absolute path.
