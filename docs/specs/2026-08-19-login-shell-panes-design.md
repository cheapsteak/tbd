# Login-shell panes: design

Status: **implemented**.

## Problem

Every tmux pane TBD spawns runs the user's shell as an interactive non-login
shell (`$SHELL -ic <command>`). On macOS the directories most user-facing tools
live in are supplied by login-shell startup files: `/etc/zprofile` runs
`path_helper`, which prepends the `/etc/paths` and `/etc/paths.d` entries
(including `/usr/local/bin`), and `~/.zprofile` conventionally holds
`eval "$(brew shellenv)"` (which prepends `/opt/homebrew/bin`) plus
version-manager hooks. A non-login shell skips both files, so a pane sees only
the environment inherited from the tmux server plus whatever `~/.zshrc` adds.

The inherited base is deliberately minimal. The daemon passes its own
environment to the tmux server verbatim, and that environment is the
installation-captured `PATH` described in
[`2026-08-11-tmux-executable-resolution-design.md`](2026-08-11-tmux-executable-resolution-design.md),
or in degraded cases the bare LaunchServices default
(`/usr/bin:/bin:/usr/sbin:/sbin`). Field measurement on a live install
(2026-08-19): the tmux server's global `PATH` was the bare default, pane shells
ran as `/bin/zsh` (argv0 without the login dash), and `code` (a symlink in
`/usr/local/bin`) was unresolvable in every TBD tab, while nix and cargo
directories added by `~/.zshrc` were present. The asymmetry (rc-file
directories present, profile-file directories absent) is the fingerprint of a
non-login interactive shell.

A second-order effect compounds it. `scripts/restart.sh` captures the invoking
shell's `PATH` into the app bundle's `LSEnvironment.PATH`. When an agent runs
`restart.sh` from inside a TBD tab, the deficient pane `PATH` is captured and
becomes the daemon's `PATH` on subsequent launches: a self-sustaining loop.
The same field measurement found the live bundle carrying a captured `PATH`
with rc-file directories but no `/usr/local/bin` or `/opt/homebrew/bin`.

## Design

Spawned panes run the user's shell as an interactive **login** shell: the two
spawn builders in `TmuxManager` (`newWindowCommand` and
`respawnWindowCommand`) pass `-ilc` instead of `-ic`, through one shared
shell-invocation helper. Exception: `csh` and `tcsh` reject the clustered
`-ilc` (and tcsh accepts `-l` only as the sole flag, so login cannot be
combined with `-c` at all), so csh-family shells, detected by the shell
path's basename, keep `-ic`: their pre-change behavior, since the
alternative is a pane whose shell exits immediately. This is the convention
every terminal emulator follows (Terminal.app, iTerm2, the VS Code integrated
terminal), for exactly this reason: the base environment handed to a GUI-born
process is minimal, and the user's own profile is the authoritative,
per-user way to rebuild it. No hardcoded directory list, no second search
policy; nix, MacPorts, Homebrew, and hand-rolled setups all get whatever their
own profile says.

For zsh this adds `/etc/zprofile` and `~/.zprofile` (and the zlogin files) to
the existing zshenv/zshrc sequence. Bash is different: a login shell reads
`~/.bash_profile` (or `~/.profile`) **instead of** `~/.bashrc`, so a bash
user whose `.bash_profile` does not source `.bashrc` loses rc-only
configuration in panes. This is accepted deliberately: it is exactly what
Terminal.app already does to the same user, and sourcing `.bashrc` from
`.bash_profile` is the near-universal convention that terminal-emulator
behavior has enforced for decades.

This also removes the `restart.sh` poisoning loop at its root. A login pane
rebuilds `PATH` from profile files even over a bare inherited base
(`path_helper` and `brew shellenv` prepend their directories regardless), so a
`restart.sh` run from inside a TBD tab captures a healthy `PATH`.

### Preserved contracts

- **env overrides** (the `export KEY='…'; ` prefix inlined into the command
  string) still execute after every startup file, so they remain the last
  writer. Adding profile files to the sequence does not reorder them relative
  to the command.
- **sensitiveEnv** still lands via tmux `-e KEY=VALUE` in the process
  environment before the shell starts, and is therefore visible during all
  startup files, now including the profile files. Visibility widens, but
  survivability narrows: startup files could always overwrite a `-e` value
  before the command runs, and the profile files join that set. Profile
  routing keys are already defended by the inline re-export (which runs after
  every startup file and wins deterministically). Values that cannot be
  inlined without leaking into `ps` argv, such as `ANTHROPIC_API_KEY` and the
  env overrides that ride sensitiveEnv, accept the widened clobber surface: a
  user profile that exports the same variable wins, exactly as it always has
  for the rc files. Anyone adding a new `-e`-only key must weigh this; the
  inline re-export is the defense, and it is only available for non-secret
  values.
- **Pane identity**: `resolvePaneTerminalID` parses the
  `export TBD_TERMINAL_ID='…'` shape out of `#{pane_start_command}`. The
  command string is unchanged; only the shell's flag argument changes. Tests
  that assert the full argv update from `-ic` to `-ilc` in the same commit.
- **Daemon environment policy is untouched.** Installation-time `PATH`
  capture, the filesystem-only tmux executable resolver, and the saved tmux
  fallback stay exactly as specified in
  [`2026-08-11-tmux-executable-resolution-design.md`](2026-08-11-tmux-executable-resolution-design.md).
  That spec rejects login shells for *executable discovery inside the daemon*;
  this change runs the user's startup files inside the user's own interactive
  pane, where they are the intended mechanism. The two policies compose: the
  daemon finds its tools deterministically, and interactive shells build the
  interactive environment.

### Not gated by a flag

This is a bug fix, not new behavior: it restores the environment users already
get from every other terminal on the machine. The change is one flag at two
spawn sites. The risk it introduces (a slow or side-effectful `~/.zprofile`
now runs in TBD tabs) is identical to the risk the same profile already poses
in Terminal.app, and profile files are written to be idempotent because login
shells are the terminal-emulator default.

## Rejected alternatives

### Restore the daemon-side PATH augmenter

A hardcoded prepend of `/opt/homebrew/bin`, `/opt/homebrew/sbin`,
`/usr/local/bin`, `/usr/local/sbin` in the daemon (the deleted
`ToolPathAugmenter`) would incidentally fix panes too, but it is the hidden
second search policy the executable-resolution spec already rejects: wrong for
nix and MacPorts installs, and it covers only four directories rather than the
user's actual profile (version managers, `~/.zprofile` additions).

### Daemon login-shell PATH probe

Deriving the daemon's `PATH` once at startup from `$SHELL -lc 'echo $PATH'`
would cover daemon-spawned helpers (`git-lfs`, `gh`) even under a degraded
capture, but it executes user startup configuration inside the daemon, is
nondeterministic across shell health, and overturns an explicit rejection in
the executable-resolution spec. With login panes in place the remaining
exposure is small and recoverable, and capability migrates inward only on
field evidence.

### Guarding `restart.sh` against degraded capture

A refusal, warning, or capture-reuse rule in `restart.sh` for deficient
invoking `PATH`s defends against a state this change removes: the deficient
environments that fed the loop were TBD's own panes. The residual exposure
(a capture taken from some other profile-less context, such as a bare ssh
session) affects only daemon-side tool lookups and recovers with one restart
from any healthy shell, which does not justify standing machinery.

### Feature flag

A default-off config column would leave every install broken until
graduation, and a default-on one contradicts the flag doctrine. The change
does not meet the flag battery (no autonomous action, no destroyed state, no
wholesale path replacement), and terminal-emulator precedent makes the chosen
behavior the well-understood default.

## Risks

- **Profile side effects** now run once per spawned pane: identical to every
  new Terminal.app window. Profiles that print output add noise before the
  command starts; profiles that hang would hang the pane, as they would any
  terminal tab.
- **Pre-session hook panes** share the pane spawn path, so a profile that
  blocks (a passphrase prompt, a hung network mount) now consumes the hook's
  marker-wait budget; on timeout the existing behavior notifies and spawns
  agents on the unprepared tree anyway. Accepted: a profile that blocks
  breaks every terminal on the machine, so it does not survive long in the
  wild, and special-casing hook panes to non-login would silently deny hooks
  the same PATH repair this change exists to provide.
- **Nested shells**: a plain shell tab runs `$SHELL -ilc $SHELL`. The inner
  shell is interactive non-login, inherits the outer's exported environment,
  and re-runs only rc files. Directories can appear twice in `PATH`; harmless
  and already true of the rc-added directories today.
- **Existing tmux servers** keep their old global environment until they
  exit, but because the login shell rebuilds `PATH` itself, new panes are
  healed even on stale servers as soon as the new daemon binary spawns them.

## Verification

- Unit: `TmuxManagerTests` assert both spawn builders emit the login-shell
  invocation, that the flag choice branches correctly per shell basename
  (csh-family gets `-ic`, everything else `-ilc`), and that the env-export
  prefix and `-e` flag handling are unchanged.
- Field: after `scripts/restart.sh`, a new shell tab resolves `code` and
  `tmux`, and its `PATH` contains the `path_helper` and profile directories.
