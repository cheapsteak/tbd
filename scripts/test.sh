#!/usr/bin/env bash
#
# `swift test`, with the developer's real `~/tbd` fenced off.
#
# Two independent layers, because neither alone is enough:
#
#   1. CONTAINMENT — `TBD_HOME` points at a fresh scratch dir for the whole
#      run, so any code path that resolves a TBD-owned path lands there
#      instead of in `~/tbd`. This catches leaks nobody has diagnosed yet,
#      including ones in code that has no injection seam at all.
#   2. DETECTION — `~/tbd` is fingerprinted before and after, and a changed
#      fingerprint fails the run even when every test passed. Containment can
#      be defeated (a path built by hand from `$HOME` ignores `TBD_HOME`
#      entirely — `WorktreeLayout.basePath` used to do exactly that), so the
#      run is also *checked*, not merely fenced.
#
# All arguments are forwarded to `swift test`:
#   scripts/test.sh
#   scripts/test.sh --parallel -j 2 --filter '^TBDDaemonTests\.'
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fingerprint_before="$(scripts/tbd-home-fingerprint.sh)"

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
scratch_home="$(mktemp -d /tmp/tbd-test-home.XXXXXXXX)"
cleanup() { rm -rf "$scratch_home"; }
trap cleanup EXIT

export TBD_HOME="$scratch_home"
export TBD_SOCKET_PATH="$scratch_home/sock"

set +e
swift test "$@"
test_status=$?
set -e

fingerprint_after="$(scripts/tbd-home-fingerprint.sh)"

if [ "$fingerprint_before" != "$fingerprint_after" ]; then
  echo >&2
  echo "=======================================================================" >&2
  echo "  THE TEST RUN WROTE INTO ~/tbd" >&2
  echo "=======================================================================" >&2
  echo >&2
  echo "CLAUDE.md: \"Tests must not touch ~/tbd\". Something resolved a real" >&2
  echo "config path despite TBD_HOME=$scratch_home." >&2
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
