# Installer-seeded tmux fallback — design

Status: **approved, not yet implemented**.

Extends [`2026-08-11-tmux-executable-resolution-design.md`](2026-08-11-tmux-executable-resolution-design.md),
which defines how TBD resolves tmux (inherited `PATH` first, then the saved fallback
file) and why it never searches fixed installation directories. This document changes
only who may write the saved fallback. Resolution order, validation rules, the Locate
tmux prompt and the Settings surface are unchanged.

## Problem

The installer records its shell's `PATH` in the app bundle's `LSEnvironment.PATH` and
passes the same value explicitly when it launches the app. LaunchServices does not
apply `LSEnvironment.PATH` when it relaunches the app at login: the relaunched app, and
the daemon it spawns, inherit launchd's default `PATH`
(`/usr/bin:/bin:/usr/sbin:/sbin`). `scripts/restart-bundle-lib.sh` records the same
observation where it launches the bundle.

A package-manager tmux — Homebrew's `/opt/homebrew/bin/tmux`, for example — is absent
from that default `PATH`. On an installation that has never saved a fallback, a login
relaunch therefore resolves no tmux: the app raises the Locate tmux prompt and existing
terminals fail to attach, although the installation is healthy and the installer's
shell found tmux without difficulty.

## Design

The installer knows which tmux its shell resolves. When the saved fallback is absent or
unusable, the installer writes that executable's path to it. A later launch with a
deficient `PATH` then resolves the installer's tmux through the existing fallback step.

### Seeding rule

`scripts/restart-bundle-lib.sh` gains one function, `seed_tmux_fallback <tbd_home>`.
Both `scripts/restart.sh` and `scripts/update.sh` call it before launching the app,
with `<tbd_home>` resolved as `${TBD_HOME:-$HOME/tbd}`. The function:

1. Reads `<tbd_home>/tmux-executable-path`. If its trimmed content is an absolute path
   that resolves, after following symlinks, to a regular executable file, the function
   returns without writing.
2. Otherwise resolves `tmux` on the installing shell's `PATH` (`command -v tmux`). If
   the result is an absolute path that resolves to a regular executable file, it
   writes that path — the path as found on `PATH`, not the symlink target — to the
   fallback file, creating `<tbd_home>` if needed and replacing the file atomically.
3. If the shell resolves no usable tmux, prints one warning line saying the app will
   ask to locate tmux, writes nothing, and returns success.

The function never fails the install. A missing tmux is recoverable in the app, and
refusing to install would block updates on a machine whose tmux is briefly broken, for
example mid-upgrade.

### Precedence and ownership

A valid saved path is never overwritten. A path the user chose through the Locate
prompt or Terminal Settings therefore always survives an install, and so does an
earlier seeded path that still works. The file carries no record of who wrote it:
installer-seeded and user-chosen values behave identically, appear identically in
Settings, and can be edited or cleared the same way.

Because resolution still consults `PATH` first, a seeded fallback changes nothing on a
launch whose `PATH` contains tmux. It takes effect only when `PATH` resolution fails.

A stale seed — the user later moves to a different tmux installation while the old one
remains executable — keeps pointing at the old executable until it stops being
executable or the user edits it. This only matters on launches whose `PATH` lacks
tmux.

### Placement

Seeding lives in the install scripts rather than in the app, the daemon or the CLI.
The daemon and app see only the launch `PATH`, which is exactly the deficient one after
a login relaunch, so neither can learn the installer's tmux. A CLI subcommand could
reuse the Swift resolver's validation, but it would add a public verb and require the
scripts to execute the freshly built CLI mid-install. The shell function repeats one
small rule — absolute, regular executable after symlink resolution — and is tested
beside the existing bundle helpers.

### Existing installations

An installation gains a seeded fallback on its next `tbd update` or `scripts/restart.sh`.
Until then, choosing tmux once in the Locate prompt writes the same file.

### Durable resources

The function writes one file at a fixed path that the resolver already owns. It cannot
accumulate orphans, so no reconciler is needed.

## Rejected alternatives

- **Search fixed installation directories** – rejected in the 2026-08-11 design and
  still rejected: it adds a hidden precedence policy that can select a different tmux
  than the installer's.
- **Refresh the fallback on every install** – would track the installer's tmux
  exactly, but silently replaces a path the user chose in Settings.
- **Seed only when the file is missing** – leaves a fallback whose target has since
  disappeared in place, so the user still meets the prompt.
- **Fail the install when the shell has no tmux** – loud, but blocks updates for a
  condition the app already recovers from.
- **Seed from the daemon or app at startup** – they see only the launch `PATH`, so
  they cannot know the installer's tmux.

## Verification contract

`scripts/restart-bundle-lib.test.sh` exercises `seed_tmux_fallback` against a temporary
`TBD_HOME`, a fake tmux executable and a controlled `PATH`:

- writes the file when it is missing;
- rewrites the file when its target is missing or not executable;
- leaves a valid saved path unchanged, including one that differs from the shell's tmux;
- warns, writes nothing and succeeds when the shell resolves no tmux;
- treats a symlinked tmux whose target is a regular executable as valid, and writes the
  path as found on `PATH`.
