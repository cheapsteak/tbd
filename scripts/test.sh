#!/usr/bin/env bash
#
# `swift test`, with the developer's real `~/tbd` and `~/.claude` fenced off.
#
# Two independent layers, and they can now be used separately:
#
#   1. CONTAINMENT — always on. `TBD_HOME`, `TBD_SOCKET_PATH` and
#      `TBD_CLAUDE_HOST_HOME` point at a fresh scratch dir for the whole run,
#      so any code path that resolves a TBD-owned path — or the host Claude
#      store a profile dir mirrors — lands there instead of in the real one.
#      This catches leaks nobody has diagnosed yet, including ones in code that
#      has no injection seam at all.
#   2. DETECTION — on by default, off with `--no-fingerprint`. The real `~/tbd`
#      and `~/.claude` are fingerprinted before and after, and a changed
#      fingerprint fails the run even when every test passed. Containment can be
#      defeated (a path built by hand from `$HOME` ignores `TBD_HOME` entirely —
#      `WorktreeLayout.basePath` used to do exactly that), so where the detector
#      runs, the run is *checked* and not merely fenced.
#
# WHY DETECTION IS CI-ONLY. It is trustworthy only where nothing else writes to
# those directories, and that means a CI runner: no live daemon, no real
# worktrees, no sibling checkouts. The fingerprint brackets a build plus a full
# suite — minutes, on a developer box where a running daemon legitimately
# creates `worktrees/<slot>/<name>`, `scratch/`, `notes/` and `channels/`
# entries, any sibling worktree running `scripts/restart.sh` drops a top-level
# `state.db.pre-migration.<ts>`, and Claude Code writes into `~/.claude`
# throughout. Those are real writes by real software, not leaks, and a guard
# that reddens on them gets switched off inside a week. So the pre-push hook
# passes `--no-fingerprint` and keeps the fence only; CI runs both layers, where
# a red is always a real finding. The fence is the layer that actually *stops*
# leaks, and it is never optional.
#
# The three env vars are OVERWRITTEN, not defaulted: an inherited value is
# discarded for the duration of the run. That is the point — a fence you can
# disable by exporting something first is not a fence — but it does mean this
# wrapper cannot be pointed at a config dir of your own.
#
# `--no-fingerprint` is consumed wherever it appears; every other argument is
# forwarded to `swift test` untouched. Position-independent on purpose: a
# leading-only strip forwards a late `--no-fingerprint` to `swift test`, which
# errors out. That is loud rather than silent, but a positional collision is
# impossible — `swift test` has no flag of that name — so filtering it out
# everywhere is strictly safer at no cost.
#   scripts/test.sh
#   scripts/test.sh --parallel -j 2 --filter '^TBDDaemonTests\.'
#   scripts/test.sh --no-fingerprint --parallel -j 2
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fingerprint=1
swift_test_args=()
for arg in "$@"; do
  case "$arg" in
    --no-fingerprint) fingerprint=0 ;;
    *) swift_test_args+=("$arg") ;;
  esac
done

fingerprint_before=""
if [ "$fingerprint" -eq 1 ]; then
  fingerprint_before="$(scripts/tbd-home-fingerprint.sh)"
fi

# `/tmp`, not `mktemp -d`'s default `$TMPDIR`: on darwin TMPDIR is a ~50-char
# path under /var/folders, and `sun_path` for a unix socket caps at ~104 bytes,
# so `$TMPDIR/<scratch>/sock` can overflow. `/tmp/tbd-test-home.XXXXXXXX/sock`
# is ~34 bytes and cannot.
#
# TBD_SOCKET_PATH is set anyway — it is the sanctioned escape hatch for that
# cap (see `TBDConstants.socketPath`) and pinning it here means a future move
# of this scratch dir to a deeper path cannot silently reintroduce the
# overflow. It is set to exactly the value TBD_HOME would derive, so
# `ConstantsTests.ProductionVarSmokeSuite.socketPathSuffix` — which asserts a
# `/sock` suffix — still holds under this wrapper.
#
# TBD_CLAUDE_HOST_HOME is the third leg and is easy to forget, because fencing
# `TBD_HOME` alone looks complete: a default-constructed
# `ClaudeProfileConfigDirManager` then gets a scratch `baseDirectory` and the
# developer's REAL `~/.claude` as its `hostBaseDirectory`, which
# `ensureMirrorSlot` creates directories in, moves whole subtrees within, and
# writes symlinks into.
scratch_home="$(mktemp -d /tmp/tbd-test-home.XXXXXXXX)"
cleanup() { rm -rf "$scratch_home"; }
# EXIT alone is sufficient, including when this wrapper is killed:
# `scripts/nightly-flake-stress.sh` TERMs it when its outer deadline fires, and
# bash runs an EXIT trap on a fatal signal as well as on a normal exit —
# measured here, the scratch dir is gone either way. No INT/TERM handler needed.
#
# The other half of that interaction lives in the harness: it kills the process
# tree LEAVES FIRST, so `swift test` is already dead before bash gets round to
# this `rm -rf`. A parent-first kill would have this deleting a `TBD_HOME` an
# orphaned test run was still writing into.
trap cleanup EXIT

export TBD_HOME="$scratch_home"
export TBD_SOCKET_PATH="$scratch_home/sock"
export TBD_CLAUDE_HOST_HOME="$scratch_home/claude-host"

# `${a[@]+"${a[@]}"}` — macOS ships bash 3.2, where a bare `"${a[@]}"` on an
# EMPTY array is an unbound-variable error under `set -u`.
set +e
swift test ${swift_test_args[@]+"${swift_test_args[@]}"}
test_status=$?
set -e

if [ "$fingerprint" -eq 0 ]; then
  exit "$test_status"
fi

fingerprint_after="$(scripts/tbd-home-fingerprint.sh)"

if [ "$fingerprint_before" != "$fingerprint_after" ]; then
  echo >&2
  echo "=======================================================================" >&2
  echo "  THE TEST RUN WROTE INTO ~/tbd OR ~/.claude" >&2
  echo "=======================================================================" >&2
  echo >&2
  echo "CLAUDE.md: \"Tests must not touch ~/tbd\". Something resolved a real" >&2
  echo "config path despite TBD_HOME=$scratch_home and" >&2
  echo "TBD_CLAUDE_HOST_HOME=$scratch_home/claude-host." >&2
  echo >&2
  echo "Entries added (+) or removed (-):" >&2
  diff <(printf '%s\n' "$fingerprint_before") <(printf '%s\n' "$fingerprint_after") \
    | grep -E '^[<>]' | sed 's/^</  - /; s/^>/  + /' >&2 || true
  echo >&2
  echo "Usual causes: a static/ambient helper that ignores its caller's" >&2
  echo "injected seam, or a path hand-built from \$HOME instead of going" >&2
  echo "through TBDConstants. Fix the leak — do not delete the entries and" >&2
  echo "move on; ~/tbd holds real state (see \"NEVER delete ~/tbd/state.db\")." >&2
  echo >&2
  exit 1
fi

exit "$test_status"
