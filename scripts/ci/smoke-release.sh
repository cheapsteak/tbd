#!/usr/bin/env bash
# Smoke-test a packaged release the way a machine that did not build it will
# run it. Run by .github/workflows/release.yml before anything is published.
#
#   scripts/ci/smoke-release.sh <archive> <commit> <checkout_root>
#
# The failure this exists to catch is invisible on the machine that compiled
# the binaries: SwiftPM's generated `Bundle.module` accessor falls back to an
# absolute path into the build tree, which exists here and on no user's
# machine. So the build tree is moved aside for the whole test, the archive is
# unpacked somewhere unrelated, and three things are checked:
#
#   1. Every resource bundle a shipped executable names by build path is
#      present beside that executable, where its Bundle.main looks first.
#   2. Every shipped executable starts (dyld resolves it) and does not die
#      looking for a resource bundle.
#   3. The daemon, run from the unpacked tree against a scratch home, gets as
#      far as serving its socket — which means it found its SQL migrations in
#      TBD_TBDDaemonLib.bundle and applied them.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../update-release-lib.sh"

archive="${1:?archive}"
commit="${2:?commit}"
checkout="$(cd "${3:?checkout root}" && pwd -P)"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tbd-smoke.XXXXXX")"
hidden="$checkout/.build-hidden-for-smoke"
daemon_pid=""

cleanup() {
    [ -n "$daemon_pid" ] && kill "$daemon_pid" 2>/dev/null || true
    if [ -d "$hidden" ] && [ ! -e "$checkout/.build" ]; then
        mv "$hidden" "$checkout/.build"
    fi
    rm -rf "$work"
}
trap cleanup EXIT

failures=0
check_fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
check_pass() { echo "ok:   $*"; }

# The build path every accessor bakes in. Real path, since that is what
# SwiftPM records.
build_prefix="$checkout/.build/"

mkdir -p "$work/unpack"
tar -xzf "$archive" -C "$work/unpack"
tree="$work/unpack/tbd-$commit-macos-$RELEASE_ARCH"
[ -d "$tree" ] || { echo "FAIL: archive does not contain tbd-$commit-macos-$RELEASE_ARCH/"; exit 1; }
if reason="$(verify_manifest "$tree" "$commit" "$RELEASE_ARCH")"; then
    check_pass "manifest matches every file"
else
    check_fail "manifest: $reason"
fi

# From here on, no absolute build path resolves.
mv "$checkout/.build" "$hidden"

# 1. Bundles named by build path are beside the executable.
for product in "${RELEASE_PRODUCTS[@]}"; do
    names="$(strings -a "$tree/$product" | grep -oE "${build_prefix//./\\.}[^\"[:space:]]*\\.bundle" \
        | sed 's#.*/##' | sort -u || true)"
    if [ -z "$names" ]; then
        check_pass "$product names no resource bundle by build path"
        continue
    fi
    while IFS= read -r name; do
        if [ -d "$tree/$name" ]; then
            check_pass "$product finds $name beside itself"
        else
            check_fail "$product looks for $name, which is not beside it in the archive"
        fi
    done <<< "$names"
done

# 2. Each executable starts. An argument none of them accepts makes each exit
# quickly on its own; a ten-second alarm bounds any that does not.
for product in "${RELEASE_PRODUCTS[@]}"; do
    [ "$product" = TBDDaemon ] && continue
    status=0
    out="$(HOME="$work/home" TBD_HOME="$work/home/tbd" \
        perl -e 'alarm shift; exec @ARGV' 10 "$tree/$product" --tbd-release-smoke-invalid-argument 2>&1)" \
        || status=$?
    if printf '%s' "$out" | grep -qE 'dyld|Library not loaded|could not load resource bundle'; then
        check_fail "$product did not start: $(printf '%s' "$out" | head -3)"
    elif [ "$status" -gt 128 ] && [ "$status" -ne 142 ]; then
        check_fail "$product died on signal $((status - 128)): $(printf '%s' "$out" | head -3)"
    else
        check_pass "$product starts (exit $status)"
    fi
done

# 3. The daemon serves its socket from the unpacked tree.
mkdir -p "$work/home/tbd"
socket="/tmp/tbd-smoke-$$.sock"
rm -f "$socket"
HOME="$work/home" TBD_HOME="$work/home/tbd" TBD_SOCKET_PATH="$socket" \
    "$tree/TBDDaemon" > "$work/daemon.log" 2>&1 &
daemon_pid=$!
served=false
for _ in $(seq 1 120); do
    if [ -S "$socket" ]; then served=true; break; fi
    kill -0 "$daemon_pid" 2>/dev/null || break
    sleep 0.5
done
if [ "$served" = true ]; then
    check_pass "the relocated daemon applied its migrations and serves its socket"
else
    check_fail "the relocated daemon never served its socket. Log tail:"
    tail -30 "$work/daemon.log" || true
fi
kill "$daemon_pid" 2>/dev/null || true
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=""
rm -f "$socket"

if [ "$failures" -gt 0 ]; then
    echo "$failures smoke check(s) failed — not publishing"
    exit 1
fi
echo "every smoke check passed"
