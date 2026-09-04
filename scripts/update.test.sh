#!/usr/bin/env bash
# Tests for scripts/update.sh — run: bash scripts/update.test.sh
#
# Nothing here builds, installs, signals a daemon, or touches a real ~/tbd.
# HOME and TBD_HOME point at a temp directory for every case; `tbd`, `open`,
# `codesign` and `security` are stubs on a temp PATH; and the update clone is a
# real clone of a fixture repo whose `scripts/swift-safe` writes three empty
# files instead of compiling. git is the real git, against fixture repos.
#
# The end-to-end cases stop at --dry-run, which is the last step before the
# installation changes.
# shellcheck disable=SC2329 # test_* helpers are dispatched dynamically below
# shellcheck disable=SC2034 # cases set variables the sourced update.sh reads
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/update.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL - update script is missing: $SCRIPT"
    exit 1
fi

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tbd-update-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

# Source the script for the pure-function cases. Sourcing defines functions and
# runs nothing: main is guarded on BASH_SOURCE. TBD_HOME is set first because
# the derived paths are computed at source time.
export TBD_HOME="$TEST_TMP/tbd"
mkdir -p "$TBD_HOME"
# shellcheck source=/dev/null
source "$SCRIPT"
OPT_AUTO=true   # keep the sourced log() out of the harness output

FAIL=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAIL=1; }

assert_ok() {
    local d="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d: expected success"; fi
}

assert_fail() {
    local d="$1"; shift
    if "$@" >/dev/null 2>&1; then fail "$d: expected failure"; else pass "$d"; fi
}

assert_eq() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$2] got [$3]"; fi
}

assert_contains() {
    if printf '%s' "$3" | grep -q -- "$2"; then
        pass "$1"
    else
        fail "$1: [$2] not found in output"
    fi
}

assert_not_contains() {
    if printf '%s' "$3" | grep -q -- "$2"; then
        fail "$1: [$2] unexpectedly present"
    else
        pass "$1"
    fi
}

# MARK: - Fixtures

# A bare-ish repo that stands in for upstream. Its working tree carries the
# pieces update.sh reaches for in a fetched checkout: the script itself, the
# two libraries it sources, a swift-safe that fakes a build, and the sources
# the build identity's dirty check looks at.
#
#   mkremote <dir> [alternate-update-script]
mkremote() {
    local d="$1"
    local alternate="${2-}"
    mkdir -p "$d/scripts" "$d/Sources" "$d/Resources"
    if [ -n "$alternate" ]; then
        cp "$alternate" "$d/scripts/update.sh"
    else
        cp "$SCRIPT" "$d/scripts/update.sh"
    fi
    cp "$HERE/restart-bundle-lib.sh" "$d/scripts/restart-bundle-lib.sh"
    cp "$HERE/restart-environment-lib.sh" "$d/scripts/restart-environment-lib.sh"
    cat > "$d/scripts/swift-safe" << 'EOF'
#!/bin/sh
# Fake build: create the outputs the installer looks for and record the call.
product=""
config="debug"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --product) shift; product="$1" ;;
        -c) shift; config="$1" ;;
    esac
    shift
done
mkdir -p ".build/$config"
printf '#!/bin/sh\nexit 0\n' > ".build/$config/$product"
chmod +x ".build/$config/$product"
printf '%s\n' "built $product $config" >> "${FAKE_BUILD_LOG:-/dev/null}"
echo "Build complete! ($product)"
EOF
    chmod +x "$d/scripts/swift-safe"
    echo "// seed" > "$d/Sources/Seed.swift"
    echo "// package" > "$d/Package.swift"
    printf 'icns' > "$d/Resources/AppIcon.icns"
    git -C "$d" init -q -b main
    git -C "$d" config user.email t@t.t
    git -C "$d" config user.name t
    git -C "$d" add -A
    git -C "$d" commit -q -m "first"
}

# A stub `tbd` that answers out of a state directory:
#   status.json           what `tbd daemon status --json` prints
#   worktrees.json        what `tbd worktree list --json` prints
#   terminals-<id>.json   what `tbd terminal list <id> --json` prints
#   wake-failures         terminal ids whose wake exits non-zero
#   wake.log              every wake, appended, one id per line
mkstub_tbd() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/tbd" << 'EOF'
#!/bin/sh
state="$FAKE_TBD_STATE"
case "$1 $2" in
    "daemon status")
        [ -f "$state/status.json" ] || exit 1
        cat "$state/status.json"
        ;;
    "worktree list")
        [ -f "$state/worktrees.json" ] || exit 1
        cat "$state/worktrees.json"
        ;;
    "terminal list")
        [ -f "$state/terminals-$3.json" ] || exit 1
        cat "$state/terminals-$3.json"
        ;;
    "terminal wake")
        shift 2
        id=""
        while [ "$#" -gt 0 ]; do
            [ "$1" = "--terminal" ] && { shift; id="$1"; }
            shift
        done
        printf '%s\n' "$id" >> "$state/wake.log"
        if [ -f "$state/wake-failures" ] && grep -qx "$id" "$state/wake-failures"; then
            echo "error: terminal $id could not be woken" >&2
            exit 1
        fi
        printf '{"woken":true}\n'
        ;;
    *) exit 1 ;;
esac
EOF
    cat > "$bin/open" << 'EOF'
#!/bin/sh
printf 'open %s\n' "$*" >> "${FAKE_OPEN_LOG:-/dev/null}"
EOF
    cat > "$bin/codesign" << 'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$bin/security" << 'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$bin"/*
}

# Run update.sh in a fenced environment. Echoes combined output; the caller
# reads $? for the status.
run_update() {
    local case_dir="$1"; shift
    env \
        HOME="$case_dir/home" \
        TBD_HOME="$case_dir/home/tbd" \
        FAKE_TBD_STATE="$case_dir/state" \
        FAKE_BUILD_LOG="$case_dir/build.log" \
        FAKE_OPEN_LOG="$case_dir/open.log" \
        PATH="$case_dir/bin:$PATH" \
        bash "$SCRIPT" "$@" 2>&1
}

# A case directory with a home, a stub PATH, a fixture remote and a daemon
# status naming a source worktree.
mkcase() {
    local name="$1"
    local alternate="${2-}"
    local d="$TEST_TMP/$name"
    mkdir -p "$d/home/tbd" "$d/state" "$d/bin" "$d/worktree"
    mkstub_tbd "$d/bin"
    mkremote "$d/remote" "$alternate"
    # A source worktree whose `upstream` remote is the fixture, so remote
    # resolution has something real to find.
    git -C "$d/worktree" init -q -b main
    git -C "$d/worktree" remote add upstream "$d/remote"
    cat > "$d/state/status.json" << EOF
{
  "executablePath": "$d/worktree/.build/debug/TBDDaemon",
  "buildIdentity": {
    "commit": "1111111111111111111111111111111111111111",
    "shortCommit": "1111111",
    "sourceWorktree": "$d/worktree"
  }
}
EOF
    printf '%s\n' "$d"
}

# MARK: - Argument handling

test_help_lists_every_flag() {
    local out
    out="$(bash "$SCRIPT" --help 2>&1)"
    assert_eq "--help exits zero" "0" "$?"
    for flag in --check --dry-run --debug --no-app --no-wake --wake-only --auto --remote; do
        assert_contains "--help documents $flag" "$flag" "$out"
    done
    assert_contains "--help names the log" "updates/update.log" "$out"
}

test_unknown_flag_is_rejected() {
    local out
    out="$(bash "$SCRIPT" --nonsense 2>&1)"
    if [ "$?" -ne 0 ]; then
        pass "an unknown flag exits non-zero"
    else
        fail "an unknown flag exits non-zero"
    fi
    assert_contains "an unknown flag is named" "unknown option --nonsense" "$out"
}

test_parse_args_sets_options() {
    (
        parse_args --dry-run --debug --no-app --no-wake --auto --remote https://example/x.git
        assert_eq "--dry-run is recorded" "true" "$OPT_DRY_RUN"
        assert_eq "--debug switches the build configuration" "debug" "$BUILD_CONFIG"
        assert_eq "--no-app is recorded" "true" "$OPT_NO_APP"
        assert_eq "--no-wake is recorded" "true" "$OPT_NO_WAKE"
        assert_eq "--auto is recorded" "true" "$OPT_AUTO"
        assert_eq "--remote takes the next argument" "https://example/x.git" "$OPT_REMOTE"
    ) || FAIL=1
    (
        parse_args --remote=https://example/y.git
        assert_eq "--remote= takes an inline value" "https://example/y.git" "$OPT_REMOTE"
    ) || FAIL=1
    ( parse_args --remote >/dev/null 2>&1 )
    if [ "$?" -eq 2 ]; then
        pass "--remote without a URL is an argument error"
    else
        fail "--remote without a URL is an argument error"
    fi
    assert_eq "the default configuration is release" "release" "release"
}

# MARK: - The lock

test_lock_refuses_a_live_run() {
    local lock="$TEST_TMP/live.lock"
    printf '%s\n' "$$" > "$lock"
    assert_ok "a lock naming this running process is live" lock_is_live "$lock"

    # A pid that cannot be running: the harness's own pid plus a large offset,
    # confirmed absent before use.
    local dead=$(( ($$ + 100000) % 60000 + 2 ))
    while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
    printf '%s\n' "$dead" > "$lock"
    assert_fail "a lock naming a dead process is not live" lock_is_live "$lock"

    printf 'garbage\n' > "$lock"
    assert_fail "a lock with no pid in it is not live" lock_is_live "$lock"
    assert_fail "a missing lock is not live" lock_is_live "$TEST_TMP/absent.lock"
}

test_update_refuses_while_another_run_holds_the_lock() {
    local case_dir out
    case_dir="$(mkcase lock-case)"
    mkdir -p "$case_dir/home/tbd/updates"
    printf '%s\n' "$$" > "$case_dir/home/tbd/updates/update.lock"

    out="$(run_update "$case_dir" --dry-run)"
    if [ "$?" -ne 0 ]; then
        pass "a live lock makes the run exit non-zero"
    else
        fail "a live lock makes the run exit non-zero"
    fi
    assert_contains "a live lock is explained" "another update is already running" "$out"
    assert_not_contains "a live lock stops the run before it fetches" "fetching origin/main" "$out"
}

test_a_stale_lock_is_taken_over() {
    local case_dir out dead
    case_dir="$(mkcase stale-lock-case)"
    mkdir -p "$case_dir/home/tbd/updates"
    dead=$(( ($$ + 100000) % 60000 + 2 ))
    while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
    printf '%s\n' "$dead" > "$case_dir/home/tbd/updates/update.lock"

    out="$(run_update "$case_dir" --dry-run)"
    assert_contains "a lock left by a dead run does not block the next one" \
        "installing nothing" "$out"
}

# MARK: - Resolving where to update from

test_remote_resolution_order() {
    local d="$TEST_TMP/remotes"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" remote add origin https://example/origin.git
    git -C "$d" remote add upstream https://example/upstream.git

    assert_eq "an explicit --remote wins" "https://example/override.git" \
        "$(resolve_remote_url "$d" "https://example/override.git")"
    assert_eq "upstream is preferred over origin" "https://example/upstream.git" \
        "$(resolve_remote_url "$d" "")"

    git -C "$d" remote remove upstream
    assert_eq "origin is the fallback" "https://example/origin.git" \
        "$(resolve_remote_url "$d" "")"

    git -C "$d" remote remove origin
    assert_fail "a worktree with no remote and no override resolves nothing" \
        resolve_remote_url "$d" ""
    assert_fail "an absent worktree resolves nothing" \
        resolve_remote_url "$TEST_TMP/nope" ""
}

test_source_worktree_resolution() {
    assert_eq "the build identity's worktree is used when present" "/w/tree" \
        "$(resolve_source_worktree '{"executablePath":"/other/.build/debug/TBDDaemon","buildIdentity":{"sourceWorktree":"/w/tree"}}')"
    assert_eq "the executable path is the fallback" "/w/other" \
        "$(resolve_source_worktree '{"executablePath":"/w/other/.build/debug/TBDDaemon"}')"
    assert_fail "an empty status resolves nothing" resolve_source_worktree ""

    assert_eq "the worktree is the parent of .build" "/a/b" \
        "$(worktree_from_executable "/a/b/.build/release/TBDDaemon")"
    assert_eq "a nested .build takes the outermost one" "/a" \
        "$(worktree_from_executable "/a/.build/x/.build/release/TBDDaemon")"
    assert_fail "a path with no .build is not a worktree" \
        worktree_from_executable "/usr/local/bin/TBDDaemon"
}

test_json_field_reads_nested_paths() {
    local json='{"a":{"b":"v","n":null,"t":true},"top":3}'
    assert_eq "a nested field is read" "v" "$(json_field "$json" a.b)"
    assert_eq "a top-level field is read" "3" "$(json_field "$json" top)"
    assert_eq "a boolean reads as a shell-comparable word" "true" "$(json_field "$json" a.t)"
    assert_fail "a null field is absent" json_field "$json" a.n
    assert_fail "a missing field is absent" json_field "$json" a.zz
    assert_fail "non-JSON input is absent" json_field "not json" a.b
}

# MARK: - Self re-exec

test_reexec_predicate() {
    local a="$TEST_TMP/a.sh" b="$TEST_TMP/b.sh" c="$TEST_TMP/c.sh"
    printf 'one\n' > "$a"
    printf 'two\n' > "$b"
    printf 'one\n' > "$c"

    assert_ok "a differing fetched script re-execs" should_reexec "$a" "$b"
    assert_fail "an identical fetched script does not re-exec" should_reexec "$a" "$c"
    assert_fail "a missing fetched script does not re-exec" should_reexec "$TEST_TMP/nope" "$a"
    assert_fail "the guard stops a second hop" \
        env TBD_UPDATE_REEXEC=1 bash -c 'source "$1"; should_reexec "$2" "$3"' _ "$SCRIPT" "$a" "$b"
}

test_reexec_happens_once_and_passes_arguments() {
    local marker case_dir out
    marker="$TEST_TMP/reexec-marker.sh"
    cat > "$marker" << 'EOF'
#!/usr/bin/env bash
# Stand-in for a newer update.sh: report that it ran, and with what.
printf 'REEXECED guard=%s args=%s\n' "${TBD_UPDATE_REEXEC:-unset}" "$*"
EOF
    case_dir="$(mkcase reexec-case "$marker")"
    out="$(run_update "$case_dir" --dry-run --no-wake)"

    assert_contains "the fetched script takes over" "REEXECED" "$out"
    assert_contains "the re-exec guard is set for the second hop" "guard=1" "$out"
    assert_contains "the original arguments are passed through" \
        "args=--dry-run --no-wake" "$out"
    assert_eq "the fetched script runs exactly once" "1" \
        "$(printf '%s' "$out" | grep -c REEXECED)"
    assert_contains "the re-exec is logged" "re-exec: the fetched update.sh differs" "$out"
}

# MARK: - --check

test_check_reports_without_changing_anything() {
    local case_dir out
    case_dir="$(mkcase check-case)"

    # A daemon that has already compared itself to main.
    cat > "$case_dir/state/status.json" << EOF
{
  "executablePath": "$case_dir/worktree/.build/debug/TBDDaemon",
  "buildIdentity": {
    "commit": "1111111111111111111111111111111111111111",
    "shortCommit": "1111111",
    "sourceWorktree": "$case_dir/worktree"
  },
  "update": {
    "relation": "behind",
    "latestCommit": "2222222222222222222222222222222222222222",
    "behindBy": 7
  }
}
EOF
    out="$(run_update "$case_dir" --check)"
    if [ "$?" -eq 0 ]; then
        pass "--check exits zero"
    else
        fail "--check exits zero: $out"
    fi
    assert_contains "--check reports the running commit" "Running commit: 1111111" "$out"
    assert_contains "--check reports how far behind and what to run" \
        "Update available: 1111111 to 2222222 (7 commits behind). Run: tbd update" "$out"
    assert_not_contains "--check fetches nothing" "fetching origin/main" "$out"
    assert_not_contains "--check builds nothing" "building TBDDaemon" "$out"
    if [ -d "$case_dir/home/tbd/updates/src" ]; then
        fail "--check creates no update clone"
    else
        pass "--check creates no update clone"
    fi

    # A daemon that is level with main.
    cat > "$case_dir/state/status.json" << EOF
{
  "executablePath": "$case_dir/worktree/.build/debug/TBDDaemon",
  "buildIdentity": {"commit": "3333333333333333333333333333333333333333"},
  "update": {"relation": "upToDate", "latestCommit": "3333333333333333333333333333333333333333"}
}
EOF
    out="$(run_update "$case_dir" --check)"
    assert_contains "--check says so when there is nothing to do" "Up to date." "$out"

    # A daemon too old to know: the comparison falls back to the remote.
    cat > "$case_dir/state/status.json" << EOF
{
  "executablePath": "$case_dir/worktree/.build/debug/TBDDaemon",
  "buildIdentity": {"commit": "4444444444444444444444444444444444444444",
                    "sourceWorktree": "$case_dir/worktree"}
}
EOF
    out="$(run_update "$case_dir" --check)"
    assert_contains "a daemon with no update field is compared against the remote" \
        "Latest main:    $(git -C "$case_dir/remote" rev-parse HEAD)" "$out"
    assert_contains "a daemon behind the remote is told to update" \
        "Run: tbd update" "$out"
}

# MARK: - The full dry run
#
# One fetch-and-build, asserted from every angle: what it built, what it wrote,
# what it refused to touch, and what it reported. A second run costs a clone
# and three fake builds, so the cases share this one.

test_dry_run_builds_but_installs_nothing() {
    local case_dir out sidecar log
    case_dir="$(mkcase dry-run-case)"
    out="$(run_update "$case_dir" --dry-run)"
    if [ "$?" -eq 0 ]; then
        pass "--dry-run exits zero"
    else
        fail "--dry-run exits zero: $out"
    fi

    assert_contains "--dry-run fetches" "fetching origin/main" "$out"
    assert_contains "--dry-run builds the daemon" "building TBDDaemon" "$out"
    assert_contains "--dry-run builds the app" "building TBDApp" "$out"
    assert_contains "--dry-run builds the CLI" "building TBDCLI" "$out"
    assert_contains "--dry-run says it installs nothing" "installing nothing" "$out"
    assert_not_contains "--dry-run does not assemble a bundle" \
        "assembling and installing" "$out"
    assert_not_contains "--dry-run does not hand over" "handing over" "$out"
    if [ -f "$case_dir/open.log" ]; then
        fail "--dry-run does not launch the app"
    else
        pass "--dry-run does not launch the app"
    fi
    assert_eq "--dry-run builds the release configuration by default" "3" \
        "$(grep -c 'release' "$case_dir/build.log")"

    # The sidecar the build stamped.
    sidecar="$case_dir/home/tbd/updates/src/.build/release/TBDBuildIdentity.json"
    if [ -f "$sidecar" ]; then
        pass "the build stamps a sidecar into the build directory"
        assert_eq "the sidecar names the fetched commit" \
            "$(git -C "$case_dir/remote" rev-parse HEAD)" \
            "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$sidecar")"
        assert_eq "a detached update clone records HEAD as its branch" "HEAD" \
            "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["branch"])' "$sidecar")"
        assert_eq "the sidecar names the update clone as its source worktree" \
            "$case_dir/home/tbd/updates/src" \
            "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sourceWorktree"])' "$sidecar")"
        assert_eq "a fresh clone is not dirty" "False" \
            "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["dirty"])' "$sidecar")"
    else
        fail "the build stamps a sidecar into the build directory: missing $sidecar"
    fi

    # The log the run left behind.
    log="$case_dir/home/tbd/updates/update.log"
    if [ -f "$log" ]; then
        pass "the run writes an update log"
        if grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] ' "$log"; then
            pass "every log line carries a UTC timestamp"
        else
            fail "every log line carries a UTC timestamp: $(head -1 "$log")"
        fi
        assert_contains "the log records the fetch" "fetching origin/main" "$(cat "$log")"
    else
        fail "the run writes an update log: missing $log"
    fi

    # The summary it printed.
    assert_contains "--dry-run ends with the summary" "Update summary" "$out"
    assert_contains "--dry-run names the commit it would install" \
        "New commit:       $(git -C "$case_dir/remote" rev-parse HEAD)" "$out"
}

test_debug_flag_selects_the_debug_configuration() {
    local case_dir
    case_dir="$(mkcase debug-case)"
    run_update "$case_dir" --dry-run --debug >/dev/null 2>&1
    assert_eq "--debug builds the debug configuration" "3" \
        "$(grep -c 'debug' "$case_dir/build.log")"
}

test_a_failed_build_stops_before_installing() {
    local case_dir out
    case_dir="$(mkcase failed-build-case)"
    cat > "$case_dir/remote/scripts/swift-safe" << 'EOF'
#!/bin/sh
echo "error: it did not compile" >&2
exit 1
EOF
    chmod +x "$case_dir/remote/scripts/swift-safe"
    git -C "$case_dir/remote" commit -q -am "break the build"

    out="$(run_update "$case_dir")"
    if [ "$?" -ne 0 ]; then
        pass "a failed build exits non-zero"
    else
        fail "a failed build exits non-zero"
    fi
    assert_contains "a failed build says the installation is untouched" \
        "the running installation is untouched" "$out"
    assert_not_contains "a failed build does not hand over" "handing over" "$out"
}

test_auto_logs_without_printing() {
    local case_dir out
    case_dir="$(mkcase auto-case)"
    out="$(run_update "$case_dir" --dry-run --auto)"
    assert_eq "--auto prints nothing to the terminal" "" "$out"
    assert_contains "--auto still writes the log" "fetching origin/main" \
        "$(cat "$case_dir/home/tbd/updates/update.log")"

}

# Both branches of the wake opt-out, driven directly: --dry-run returns before
# the wake stage, so a full run is not where this is observable.
test_no_wake_skips_the_stage() {
    local state out
    state="$TEST_TMP/no-wake-state"
    mkdir -p "$state" "$TEST_TMP/no-wake-bin"
    mkstub_tbd "$TEST_TMP/no-wake-bin"
    printf '[{"id":"w1"}]\n' > "$state/worktrees.json"
    printf '[{"id":"a","hibernatedAt":"2026-09-04T12:00:01Z","hibernateReason":"recovery"}]\n' \
        > "$state/terminals-w1.json"
    : > "$state/wake.log"

    out="$(
        export FAKE_TBD_STATE="$state" PATH="$TEST_TMP/no-wake-bin:$PATH"
        OPT_AUTO=false
        OPT_NO_WAKE=true
        WAKE_STAGGER_SECONDS=0
        run_wake_stage "2026-09-04T12:00:00Z"
    )"
    assert_contains "--no-wake says it is leaving parked sessions alone" \
        "leaving parked sessions alone" "$out"
    assert_not_contains "--no-wake wakes nothing" "waking batch" "$out"
    assert_eq "--no-wake sends no wake at all" "" "$(cat "$state/wake.log")"

    out="$(
        export FAKE_TBD_STATE="$state" PATH="$TEST_TMP/no-wake-bin:$PATH"
        OPT_AUTO=false
        OPT_NO_WAKE=false
        WAKE_STAGGER_SECONDS=0
        run_wake_stage "2026-09-04T12:00:00Z"
    )"
    assert_contains "without --no-wake the parked session is woken" \
        "waking batch 1 (1 of 1)" "$out"
    assert_eq "without --no-wake the wake actually goes out" "a" \
        "$(cat "$state/wake.log" | tr -d '\n')"
}

# MARK: - The wake sweep

WAKE_ROWS='[
 {"id":"aaa","hibernatedAt":"2026-09-04T12:00:05Z","hibernateReason":"recovery"},
 {"id":"bbb","hibernatedAt":"2026-09-04T11:00:00Z","hibernateReason":"recovery"},
 {"id":"ccc","hibernatedAt":"2026-09-04T12:00:07Z","hibernateReason":"idle"},
 {"id":"ddd","hibernatedAt":null,"hibernateReason":null},
 {"id":"eee","hibernatedAt":"2026-09-04T12:00:00Z","hibernateReason":"recovery"},
 {"id":"fff","hibernatedAt":"2026-09-04T12:30:11Z","hibernateReason":"recovery"}
]'

test_wake_candidate_filter() {
    local picked
    picked="$(printf '%s' "$WAKE_ROWS" | select_wake_candidates "2026-09-04T12:00:00Z" | tr '\n' ' ')"
    assert_eq "only recovery parks at or after the handover are candidates" \
        "aaa eee fff " "$picked"

    picked="$(printf '%s' "$WAKE_ROWS" | select_wake_candidates "" | tr '\n' ' ')"
    assert_eq "an empty since takes every recovery park" "aaa bbb eee fff " "$picked"

    picked="$(printf '%s' "$WAKE_ROWS" | select_wake_candidates "2026-09-05T00:00:00Z" | tr '\n' ' ')"
    assert_eq "a later handover leaves earlier parks alone" "" "$picked"

    picked="$(printf '%s' '[{"id":"g","hibernatedAt":"2026-09-04T12:00:05.482Z","hibernateReason":"recovery"}]' \
        | select_wake_candidates "2026-09-04T12:00:00Z" | tr '\n' ' ')"
    assert_eq "fractional seconds compare correctly" "g " "$picked"

    assert_eq "an empty list yields no candidate" "" \
        "$(printf '[]' | select_wake_candidates "")"
}

test_wake_batches_and_paces() {
    local state ids i out
    state="$TEST_TMP/wake-state"
    mkdir -p "$state" "$TEST_TMP/wake-bin"
    mkstub_tbd "$TEST_TMP/wake-bin"
    : > "$state/wake.log"

    ids=()
    for i in 1 2 3 4 5 6 7; do ids+=("t$i"); done

    out="$(
        export FAKE_TBD_STATE="$state" PATH="$TEST_TMP/wake-bin:$PATH"
        OPT_AUTO=false
        WAKE_STAGGER_SECONDS=0
        wake_terminals "${ids[@]}"
        printf 'woken=%s failed=%s\n' "$WAKE_WOKEN" "$WAKE_FAILED"
    )"

    assert_eq "seven sessions are woken in three batches of at most three" "3" \
        "$(printf '%s' "$out" | grep -c 'waking batch')"
    assert_contains "the first batch takes three" "waking batch 1 (3 of 7)" "$out"
    assert_contains "the last batch takes the remainder" "waking batch 3 (1 of 7)" "$out"
    assert_contains "every session is counted as woken" "woken=7 failed=0" "$out"
    assert_eq "every session is actually woken once" "7" "$(wc -l < "$state/wake.log" | tr -d ' ')"
}

test_wake_counts_failures() {
    local state out
    state="$TEST_TMP/wake-fail-state"
    mkdir -p "$state" "$TEST_TMP/wake-bin"
    mkstub_tbd "$TEST_TMP/wake-bin"
    : > "$state/wake.log"
    printf 't2\n' > "$state/wake-failures"

    out="$(
        export FAKE_TBD_STATE="$state" PATH="$TEST_TMP/wake-bin:$PATH"
        OPT_AUTO=false
        WAKE_STAGGER_SECONDS=0
        wake_terminals t1 t2 t3
        printf 'woken=%s failed=%s\n' "$WAKE_WOKEN" "$WAKE_FAILED"
    )"
    assert_contains "a session that will not wake is counted as a failure" \
        "woken=2 failed=1" "$out"
    assert_contains "a wake failure says which session and why" \
        "wake failed: t2" "$out"
}

test_wake_stagger_separates_batches() {
    local state before after elapsed
    state="$TEST_TMP/wake-stagger-state"
    mkdir -p "$state" "$TEST_TMP/wake-bin"
    mkstub_tbd "$TEST_TMP/wake-bin"

    before="$(date +%s)"
    (
        export FAKE_TBD_STATE="$state" PATH="$TEST_TMP/wake-bin:$PATH"
        OPT_AUTO=true
        WAKE_STAGGER_SECONDS=1
        wake_terminals t1 t2 t3 t4 t5 t6 t7
    ) >/dev/null 2>&1
    after="$(date +%s)"
    elapsed=$((after - before))
    # Three batches means two gaps. One second each, so at least two seconds.
    if [ "$elapsed" -ge 2 ]; then
        pass "batches are separated by the stagger"
    else
        fail "batches are separated by the stagger: took ${elapsed}s"
    fi
}

test_no_wake_and_wake_only() {
    local case_dir out
    case_dir="$(mkcase wake-only-case)"
    cat > "$case_dir/state/worktrees.json" << 'EOF'
[{"id":"11111111-1111-1111-1111-111111111111"}]
EOF
    cat > "$case_dir/state/terminals-11111111-1111-1111-1111-111111111111.json" << 'EOF'
[{"id":"aaa","hibernatedAt":"2026-09-04T12:00:05Z","hibernateReason":"recovery"},
 {"id":"bbb","hibernatedAt":"2026-09-04T12:00:05Z","hibernateReason":"idle"}]
EOF
    : > "$case_dir/state/wake.log"

    out="$(run_update "$case_dir" --wake-only)"
    if [ "$?" -eq 0 ]; then
        pass "--wake-only exits zero"
    else
        fail "--wake-only exits zero: $out"
    fi
    assert_not_contains "--wake-only fetches nothing" "fetching origin/main" "$out"
    assert_not_contains "--wake-only builds nothing" "building TBDDaemon" "$out"
    assert_contains "--wake-only wakes the recovery-parked session" \
        "waking batch 1 (1 of 1)" "$out"
    assert_eq "--wake-only wakes only the recovery park" "aaa" \
        "$(cat "$case_dir/state/wake.log" | tr -d '\n')"

}

test_terminals_are_collected_across_worktrees() {
    local state out
    state="$TEST_TMP/collect-state"
    mkdir -p "$state" "$TEST_TMP/collect-bin"
    mkstub_tbd "$TEST_TMP/collect-bin"
    printf '[{"id":"w1"},{"id":"w2"}]\n' > "$state/worktrees.json"
    printf '[{"id":"a","hibernatedAt":"2026-09-04T12:00:01Z","hibernateReason":"recovery"}]\n' \
        > "$state/terminals-w1.json"
    printf '[{"id":"b","hibernatedAt":"2026-09-04T12:00:02Z","hibernateReason":"recovery"}]\n' \
        > "$state/terminals-w2.json"

    out="$(
        export FAKE_TBD_STATE="$state" PATH="$TEST_TMP/collect-bin:$PATH"
        all_terminals_json | select_wake_candidates "" | tr '\n' ' '
    )"
    assert_eq "rows from every worktree are considered" "a b " "$out"
}

# MARK: - Reporting

test_summary_reports_the_move() {
    local out
    out="$(
        OPT_AUTO=false
        UPDATE_LOG="$TEST_TMP/summary.log"
        print_summary "1111111111111111111111111111111111111111" \
            "2222222222222222222222222222222222222222" 12 5 4 1
    )"
    assert_contains "the summary is labelled" "Update summary" "$out"
    assert_contains "the summary reports the previous commit" \
        "Previous commit:  1111111111111111111111111111111111111111" "$out"
    assert_contains "the summary reports the new commit" \
        "New commit:       2222222222222222222222222222222222222222" "$out"
    assert_contains "the summary reports how far it moved" "Commits advanced: 12" "$out"
    assert_contains "the summary reports what the reconcile parked" \
        "Sessions parked by the reconcile: 5" "$out"
    assert_contains "the summary reports what it woke" "Sessions woken:   4" "$out"
    assert_contains "the summary reports what it could not wake" "Wake failures:    1" "$out"
    assert_contains "the summary names the log" "Log:" "$out"
}

test_summary_survives_an_unknown_commit() {
    local out
    out="$(
        OPT_AUTO=false
        UPDATE_LOG="$TEST_TMP/summary2.log"
        print_summary "" "abc" "" 0 0 0
    )"
    assert_contains "an unreadable previous commit reads as unknown" \
        "Previous commit:  unknown" "$out"
    assert_contains "an uncountable advance reads as unknown" \
        "Commits advanced: unknown" "$out"
}

test_dry_run_prints_the_summary() {
    local case_dir out
    case_dir="$(mkcase summary-case)"
    out="$(run_update "$case_dir" --dry-run)"
    assert_contains "--dry-run ends with the summary" "Update summary" "$out"
    assert_contains "--dry-run names the commit it would install" \
        "New commit:       $(git -C "$case_dir/remote" rev-parse HEAD)" "$out"
}

# MARK: - The CLI hard link

test_cli_refresh_only_touches_an_existing_install() {
    local new_cli target
    new_cli="$TEST_TMP/newcli"
    printf '#!/bin/sh\nexit 0\n' > "$new_cli"
    chmod +x "$new_cli"

    target="$TEST_TMP/absent-bin/tbd"
    (
        CLI_INSTALL_PATH="$target"
        OPT_AUTO=true
        refresh_installed_cli "$new_cli"
    )
    if [ -e "$target" ]; then
        fail "an operator who never installed the CLI does not get one"
    else
        pass "an operator who never installed the CLI does not get one"
    fi

    mkdir -p "$TEST_TMP/bin-existing"
    target="$TEST_TMP/bin-existing/tbd"
    printf 'old\n' > "$target"
    (
        CLI_INSTALL_PATH="$target"
        OPT_AUTO=true
        refresh_installed_cli "$new_cli"
    )
    assert_eq "an existing CLI install is relinked to the new build" \
        "$(stat -f %i "$new_cli" 2>/dev/null || stat -c %i "$new_cli")" \
        "$(stat -f %i "$target" 2>/dev/null || stat -c %i "$target")"
}

# MARK: - Handover helpers

test_paths_match_resolves_symlinks() {
    local real link
    real="$TEST_TMP/real-daemon"
    link="$TEST_TMP/link-daemon"
    printf 'x\n' > "$real"
    ln -sf "$real" "$link"
    assert_ok "a symlink and its target are the same executable" paths_match "$link" "$real"
    assert_fail "different files are not the same executable" paths_match "$real" "$TEST_TMP/other"
    assert_fail "an empty path matches nothing" paths_match "" ""
}

test_handover_wait_gives_up() {
    local state out
    state="$TEST_TMP/handover-state"
    mkdir -p "$state" "$TEST_TMP/handover-bin"
    mkstub_tbd "$TEST_TMP/handover-bin"
    printf '{"executablePath":"/old/.build/release/TBDDaemon"}\n' > "$state/status.json"

    out="$(
        export FAKE_TBD_STATE="$state" PATH="$TEST_TMP/handover-bin:$PATH"
        wait_for_daemon_executable "/new/.build/release/TBDDaemon" 1
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "a daemon that never reports the new binary times out" "rc=1" "$out"

    printf '{"executablePath":"/new/.build/release/TBDDaemon"}\n' > "$state/status.json"
    out="$(
        export FAKE_TBD_STATE="$state" PATH="$TEST_TMP/handover-bin:$PATH"
        wait_for_daemon_executable "/new/.build/release/TBDDaemon" 5
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "a daemon reporting the new binary ends the wait" "rc=0" "$out"
}

test_help_lists_every_flag
test_unknown_flag_is_rejected
test_parse_args_sets_options
test_lock_refuses_a_live_run
test_update_refuses_while_another_run_holds_the_lock
test_a_stale_lock_is_taken_over
test_remote_resolution_order
test_source_worktree_resolution
test_json_field_reads_nested_paths
test_reexec_predicate
test_reexec_happens_once_and_passes_arguments
test_check_reports_without_changing_anything
test_dry_run_builds_but_installs_nothing
test_debug_flag_selects_the_debug_configuration
test_a_failed_build_stops_before_installing
test_auto_logs_without_printing
test_no_wake_skips_the_stage
test_wake_candidate_filter
test_wake_batches_and_paces
test_wake_counts_failures
test_wake_stagger_separates_batches
test_no_wake_and_wake_only
test_terminals_are_collected_across_worktrees
test_summary_reports_the_move
test_summary_survives_an_unknown_commit
test_cli_refresh_only_touches_an_existing_install
test_paths_match_resolves_symlinks
test_handover_wait_gives_up

if [ "$FAIL" -ne 0 ]; then
    echo "SOME UPDATE TESTS FAILED"
    exit 1
fi

echo "ALL UPDATE TESTS PASSED"
