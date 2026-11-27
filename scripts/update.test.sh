#!/usr/bin/env bash
# Tests for scripts/update.sh — run: /bin/bash scripts/update.test.sh (macOS bash 3.2; any bash works)
#
# Nothing here builds, installs, signals a daemon, creates a key or keychain,
# or touches a real ~/tbd. HOME and TBD_HOME point at a temp directory for
# every case; `tbd`, `open`, `codesign` and `security` are stubs on a temp
# PATH, and openssl a stub behind its seam; and the update clone is a
# real clone of a fixture repo whose `scripts/swift-safe` writes five empty
# files instead of compiling. git is the real git, against fixture repos. The
# handover cases stand a copy of sleep named TBDDaemon in for the daemon being
# replaced, and signal only processes they started themselves.
#
# The end-to-end cases stop at --dry-run, which is the last step before the
# installation changes.
# shellcheck disable=SC2329 # test_* helpers are dispatched dynamically below
# shellcheck disable=SC2034 # cases set variables the sourced update.sh reads
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$HERE/update.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL - update script is missing: $SCRIPT"
    exit 1
fi

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tbd-update-test.XXXXXX")"
# Only this shell may delete TEST_TMP. A child bash forks for `sleep 30 &` keeps
# a copy of this trap until it execs, and runs it if a signal lands first, on
# bash 3.2 as well as bash 5.
HARNESS_PID="$$"
# True only in the harness's own shell. `$$` names the harness in every child it
# forks too, and bash 3.2 has no BASHPID, so ask a process this shell execs for
# its parent pid.
in_harness_shell() { [ "$(exec /bin/sh -c 'echo "$PPID"')" = "$HARNESS_PID" ]; }
trap 'in_harness_shell && rm -rf "$TEST_TMP"' EXIT

# Every nested `bash` — the cases' `bash "$SCRIPT"`, update.sh's own re-exec,
# and `#!/usr/bin/env bash` stubs — runs the same interpreter as this harness,
# so `/bin/bash scripts/update.test.sh` exercises macOS's bash 3.2 all the way
# down rather than whichever bash comes first on PATH.
mkdir -p "$TEST_TMP/bash-pin"
ln -s "$BASH" "$TEST_TMP/bash-pin/bash"
PATH="$TEST_TMP/bash-pin:$PATH"
export PATH

# A step that swaps the installed bundle while the app is down waits out
# macOS's two checks of the app's exit: APP_EXIT_SETTLE_SECONDS after it, and
# a window around APP_EXIT_RECHECK_SECONDS after it. No case here has a macOS
# reading that bundle, so every run skips the settle, save the cases that
# measure it and set their own. The second check stays at its 31 s: no case
# moves the bundle that long after a stop, and the cases that measure it set
# their own.
export TBD_UPDATE_APP_EXIT_SETTLE_SECONDS=0

# Source the script for the pure-function cases. Sourcing defines functions and
# runs nothing: main is guarded on BASH_SOURCE. TBD_HOME is set first because
# the derived paths are computed at source time.
export TBD_HOME="$TEST_TMP/tbd"
mkdir -p "$TBD_HOME"
# shellcheck source=/dev/null
source "$SCRIPT"
# main() sources this at run time; the function-level cases need it too.
# shellcheck source=/dev/null
source "$HERE/restart-bundle-lib.sh"
# shellcheck source=/dev/null
source "$HERE/update-release-lib.sh"
OPT_AUTO=true   # keep the sourced log() out of the harness output

# Nothing in this harness may signal a real process. The app stage resolves its
# target from INSTALLED_BUNDLE, so point that at a scratch path for every case
# and stub pkill/pgrep besides — a bare /Applications/TBD.app here would make
# an anchored pkill match the developer's running app.
INSTALLED_BUNDLE="$TEST_TMP/Applications/TBD.app"
mkdir -p "$INSTALLED_BUNDLE/Contents/MacOS"

# The library reaches LaunchServices by absolute path, so PATH cannot shadow
# it. Point its seam at a stub that records the call instead, or the harness
# would register its fixture bundles with the developer's LaunchServices.
export TBD_LSREGISTER="$TEST_TMP/stub-lsregister"
cat > "$TBD_LSREGISTER" << 'EOF'
#!/bin/sh
printf 'lsregister %s\n' "$*" >> "${FAKE_LSREGISTER_LOG:-/dev/null}"
EOF
chmod +x "$TBD_LSREGISTER"

# Signing reaches openssl by absolute path too, so PATH cannot shadow it
# either, and every case that runs the real sign_app_bundle with CI unset
# would make a real key with /usr/bin/openssl. Point the seam at a stub that
# records its arguments to FAKE_OPENSSL_LOG and fails, which sends signing to
# its ad-hoc fallback before any keychain is made; and never wait on a
# provisioning lock. The keychain and that lock derive from HOME, which every
# run fences to its case directory. The harness shell sourced the library with
# the real HOME, so its own copy of the keychain path points into TEST_TMP,
# unexported so that no run inherits it in place of its own.
export TBD_OPENSSL="$TEST_TMP/stub-openssl"
cat > "$TBD_OPENSSL" << 'EOF'
#!/bin/sh
printf 'openssl %s\n' "$*" >> "${FAKE_OPENSSL_LOG:-/dev/null}"
exit 1
EOF
chmod +x "$TBD_OPENSSL"
export TBD_SIGNING_LOCK_WAIT_SECONDS=0
unset TBD_SIGNING_KEYCHAIN
TBD_SIGNING_KEYCHAIN="$TEST_TMP/keychains/tbd-signing.keychain-db"

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

# The three matchers feed grep a here-string, never `printf … | grep -q`.
# `grep -q` leaves at its first match, and a printf still writing then dies of
# SIGPIPE (or, where SIGPIPE is ignored, exits 1 on `write error: Broken
# pipe`). Under pipefail that status is the pipeline's, so a match reads as a
# miss — and assert_not_contains passes with the text present. Which side wins
# is timing: the piped form measured about one failed run in a hundred, and
# `test_the_matchers_survive_output_longer_than_a_pipe` makes it fail every time.
assert_contains() {
    if grep -q -- "$2" <<< "$3"; then
        pass "$1"
    else
        fail "$1: [$2] not found in output"
    fi
}

# `stat` is not portable and its two dialects do not fail over cleanly: `-f`
# selects a format string on BSD and FILESYSTEM STATUS on GNU, so
# `stat -f %i x || stat -c %i x` succeeds on GNU with entirely the wrong
# answer. That is what reddened this harness on the Linux runner. `ls -di` is
# POSIX and says the same thing on both.
file_inode() {
    ls -di "${1-}" 2>/dev/null | awk '{print $1}'
}

# For output that is itself a regex — the anchored pkill pattern, say — where
# grep's default BRE would reinterpret the very escapes under test.
assert_contains_literal() {
    if grep -qF -- "$2" <<< "$3"; then
        pass "$1"
    else
        fail "$1: [$2] not found in output"
    fi
}

assert_not_contains() {
    if grep -q -- "$2" <<< "$3"; then
        fail "$1: [$2] unexpectedly present"
    else
        pass "$1"
    fi
}

# MARK: - Fixtures

# A bare-ish repo that stands in for upstream. Its working tree carries the
# pieces update.sh reaches for in a fetched checkout: the script itself, the
# two libraries it sources, a swift-safe that fakes a build, the sources the
# build identity's dirty check looks at, and the SchemaEpoch.swift it reads
# the schema epoch from.
#
#   mkremote <dir> [alternate-update-script]
mkremote() {
    local d="$1"
    local alternate="${2-}"
    mkdir -p "$d/scripts" "$d/Sources/TBDShared" "$d/Resources"
    if [ -n "$alternate" ]; then
        cp "$alternate" "$d/scripts/update.sh"
    else
        cp "$SCRIPT" "$d/scripts/update.sh"
    fi
    cp "$HERE/restart-bundle-lib.sh" "$d/scripts/restart-bundle-lib.sh"
    cp "$HERE/restart-environment-lib.sh" "$d/scripts/restart-environment-lib.sh"
    cp "$HERE/restart-build-lib.sh" "$d/scripts/restart-build-lib.sh"
    cp "$HERE/update-release-lib.sh" "$d/scripts/update-release-lib.sh"
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
# A product named in FAKE_BUILD_FAILS_PRODUCT fails to compile.
if [ -n "${FAKE_BUILD_FAILS_PRODUCT-}" ] && [ "$product" = "$FAKE_BUILD_FAILS_PRODUCT" ]; then
    echo "error: fake compile failure ($product)"
    exit 1
fi
# Like SwiftPM: outputs go to the triple directory, and .build/<config> is a
# link to it, re-pointed on every build.
mkdir -p ".build/arm64-apple-macosx/$config"
ln -sfn "arm64-apple-macosx/$config" ".build/$config.tmp" && mv -f ".build/$config.tmp" ".build/$config"
if [ "$product" = TBDDaemon ]; then
    # Launched as a handover's successor, it stays up the way a daemon that
    # started does when FAKE_SUCCESSOR_BIN names a copy of sleep called
    # TBDDaemon, recording its pid beside that copy; otherwise it exits at
    # once, like a daemon that failed to start.
    cat > ".build/$config/$product" << 'DAEMON'
#!/bin/sh
if [ -n "${FAKE_SUCCESSOR_BIN-}" ]; then
    printf '%s\n' "$$" > "$FAKE_SUCCESSOR_BIN.pid"
    exec "$FAKE_SUCCESSOR_BIN" 60
fi
exit 0
DAEMON
else
    printf '#!/bin/sh\nexit 0\n' > ".build/$config/$product"
fi
chmod +x ".build/$config/$product"
if [ "$product" = TBDApp ]; then
    mkdir -p ".build/$config/TBD_TBDApp.bundle"
    printf 'css' > ".build/$config/TBD_TBDApp.bundle/markdown-default.css"
fi
printf '%s\n' "built $product $config" >> "${FAKE_BUILD_LOG:-/dev/null}"
# What the compiler would have inherited, for the environment-scrub cases.
printf 'SDKROOT=%s DEVELOPER_DIR=%s IN_NIX_SHELL=%s CPATH=%s NIX_LDFLAGS=%s TOOLCHAINS=%s\n' \
    "${SDKROOT-unset}" "${DEVELOPER_DIR-unset}" "${IN_NIX_SHELL-unset}" "${CPATH-unset}" \
    "${NIX_LDFLAGS-unset}" "${TOOLCHAINS-unset}" >> "${FAKE_ENV_LOG:-/dev/null}"
echo "Build complete! ($product)"
EOF
    chmod +x "$d/scripts/swift-safe"
    echo "// seed" > "$d/Sources/Seed.swift"
    cp "$REPO_ROOT/Sources/TBDShared/SchemaEpoch.swift" "$d/Sources/TBDShared/SchemaEpoch.swift"
    echo "// package" > "$d/Package.swift"
    printf 'icns' > "$d/Resources/AppIcon.icns"
    # The real source plist, so a fixture build can be assembled into a bundle
    # the way an install does.
    cp "$REPO_ROOT/Resources/TBDApp.Info.plist" "$d/Resources/TBDApp.Info.plist"
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
#
# Beside it, stubs for open, pkill and pgrep that record their arguments and
# never touch a real process. With FAKE_APP_STATE naming a file, that file is
# a running app: pkill matches it and the app exits (the file goes), pgrep
# reports it while the file exists, and open starts it (the file comes back).
# Unset, nothing is ever running.
#
# With FAKE_BUNDLE_AT_STOP naming a bundle path as well, a pkill that stops
# the app first records what that path holds at that instant, the moment
# macOS reads the bundle of an app that quits: `bundle-at-stop` followed by
# the bundle's SourceWorktreePath.txt, or by `absent` when nothing is there,
# or `incomplete` when the bundle has no executable.
#
# And `bundle-cp`, for the library's TBD_BUNDLE_CP seam, through which every
# bundle copy goes (run_update_around_handover sets the seam once main has
# sourced the library). It copies with /bin/cp and records in
# FAKE_EVENTS_LOG what FAKE_INSTALLED_BUNDLE holds as the copy starts and once
# it has finished, in the same words as bundle-at-stop:
#   copy <source> -> <destination> at <epoch seconds> installed <what>
#   copied <destination> installed <what>
# With FAKE_COPY_FAILS=1, a copy into an install's incoming sibling fails
# once it has copied, as a copy that ran out of space at its last file would,
# leaving its tree behind for the install to remove. With
# FAKE_KEEP_COPY_INTERRUPTED=1, a copy into ~/tbd/updates/previous/ (the keep)
# writes part of a tree there and sends SIGTERM to the run that started it,
# the way an interruption mid-copy would, before it copies anything else.
# FAKE_STAGE_COPY_INTERRUPTED=1 does the same to a copy into an install's
# incoming sibling (the staging copy).
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
[ -z "${FAKE_APP_STATE-}" ] || : > "$FAKE_APP_STATE"
EOF
    cat > "$bin/pkill" << 'EOF'
#!/bin/sh
printf 'pkill %s\n' "$*" >> "${FAKE_KILL_LOG:-/dev/null}"
if [ -n "${FAKE_APP_STATE-}" ] && [ -f "$FAKE_APP_STATE" ]; then
    if [ -n "${FAKE_BUNDLE_AT_STOP-}" ]; then
        if [ ! -d "$FAKE_BUNDLE_AT_STOP" ]; then
            seen=absent
        elif [ ! -x "$FAKE_BUNDLE_AT_STOP/Contents/MacOS/TBDApp" ]; then
            seen=incomplete
        else
            seen="$(cat "$FAKE_BUNDLE_AT_STOP/Contents/SourceWorktreePath.txt" 2>/dev/null)"
        fi
        printf 'bundle-at-stop %s\n' "$seen" >> "${FAKE_KILL_LOG:-/dev/null}"
    fi
    rm -f "$FAKE_APP_STATE"
    exit 0
fi
exit 1
EOF
    cat > "$bin/pgrep" << 'EOF'
#!/bin/sh
printf 'pgrep %s\n' "$*" >> "${FAKE_KILL_LOG:-/dev/null}"
if [ -n "${FAKE_APP_STATE-}" ] && [ -f "$FAKE_APP_STATE" ]; then
    echo 4242
    exit 0
fi
exit 1
EOF
    cat > "$bin/codesign" << 'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$bin/security" << 'EOF'
#!/bin/sh
exit 1
EOF
    cat > "$bin/bundle-cp" << 'EOF'
#!/bin/sh
installed_state() {
    if [ ! -d "${FAKE_INSTALLED_BUNDLE-}" ]; then
        echo absent
    elif [ ! -x "$FAKE_INSTALLED_BUNDLE/Contents/MacOS/TBDApp" ]; then
        echo incomplete
    else
        cat "$FAKE_INSTALLED_BUNDLE/Contents/SourceWorktreePath.txt" 2>/dev/null
    fi
}
src=""
dst=""
for arg in "$@"; do
    src="$dst"
    dst="$arg"
done
log="${FAKE_EVENTS_LOG:-/dev/null}"
printf 'copy %s -> %s at %s installed %s\n' "$src" "$dst" "$(date +%s)" "$(installed_state)" >> "$log"
case "$dst" in
    */updates/previous/*)
        if [ "${FAKE_KEEP_COPY_INTERRUPTED:-0}" = 1 ]; then
            mkdir -p "$dst/Contents"
            printf 'half' > "$dst/Contents/half-copied"
            kill -TERM "$PPID"
            exit 1
        fi
        ;;
    *-install-incoming)
        if [ "${FAKE_STAGE_COPY_INTERRUPTED:-0}" = 1 ]; then
            mkdir -p "$dst/Contents"
            printf 'half' > "$dst/Contents/half-copied"
            kill -TERM "$PPID"
            exit 1
        fi
        ;;
esac
/bin/cp "$@" || exit $?
printf 'copied %s installed %s\n' "$dst" "$(installed_state)" >> "$log"
case "$dst" in
    *-install-incoming) [ "${FAKE_COPY_FAILS:-0}" != 1 ] || exit 1 ;;
esac
exit 0
EOF
    chmod +x "$bin"/*
}

# Run update.sh in a fenced environment. Echoes combined output; the caller
# reads $? for the status.
run_update() {
    local case_dir="$1"; shift
    run_update_from "$case_dir" "$SCRIPT" "$@"
}

# run_update with the update.sh at <script> instead of this checkout's — the
# update clone's own copy, say, which is the one `tbd update` runs on an
# installation that has updated before.
#
#   run_update_from <case_dir> <script> [args...]
run_update_from() {
    local case_dir="$1" script="$2"; shift 2
    env \
        HOME="$case_dir/home" \
        TBD_HOME="$case_dir/home/tbd" \
        FAKE_TBD_STATE="$case_dir/state" \
        FAKE_BUILD_LOG="$case_dir/build.log" \
        FAKE_ENV_LOG="$case_dir/build-env.log" \
        FAKE_OPEN_LOG="$case_dir/open.log" \
        PATH="$case_dir/bin:$PATH" \
        bash "$script" "$@" 2>&1
}

# The build the daemon of a case made by mkcase reports.
CASE_DAEMON_COMMIT=1111111111111111111111111111111111111111

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

# MARK: - The harness's own matchers

# The text sits on the first line of 384 KiB of output, six times what a pipe
# holds, so a piped matcher's grep always leaves while printf is still blocked
# writing. Against `printf … | grep -q` all three rows fail on every run, not
# one run in a hundred.
test_the_matchers_survive_output_longer_than_a_pipe() {
    local filler=$'filler line\n' long verdict
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do filler="$filler$filler"; done
    long=$'needle\n'"$filler"
    assert_contains "a match ahead of long output is found" "needle" "$long"
    assert_contains_literal "and found literally" "needle" "$long"
    # A subshell, so the FAIL this row expects to see is not counted as one.
    verdict="$(assert_not_contains "probe" "needle" "$long")"
    case "$verdict" in
        FAIL*) pass "and is never reported absent" ;;
        *) fail "assert_not_contains passed with the text present: $verdict" ;;
    esac
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

test_acquire_lock_recognises_its_own_lock() {
    local home
    home="$TEST_TMP/own-lock"
    mkdir -p "$home/updates"

    out="$(
        UPDATE_HOME="$home/updates"
        UPDATE_LOCK="$home/updates/update.lock"
        UPDATE_LOG="$home/updates/update.log"
        OPT_AUTO=true
        printf '%s\n' "$$" > "$UPDATE_LOCK"
        acquire_lock
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "a lock naming this very process is ours to keep" "rc=0" "$out"

    # A process this user owns but is not: `kill -0` on someone else's pid
    # fails with EPERM, which would read as a dead holder.
    local other
    sleep 30 &
    other=$!
    out="$(
        UPDATE_HOME="$home/updates"
        UPDATE_LOCK="$home/updates/update.lock"
        UPDATE_LOG="$home/updates/update.log"
        OPT_AUTO=true
        printf '%s\n' "$other" > "$UPDATE_LOCK"
        acquire_lock 2>/dev/null
        printf 'rc=%s\n' "$?"
    )"
    kill "$other" 2>/dev/null
    wait "$other" 2>/dev/null
    assert_contains "a lock naming another live process is refused" "rc=1" "$out"
    assert_contains "and names the process holding it" "another update is already running (pid $other)" \
        "$(cat "$home/updates/update.log")"
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

# THE REGRESSION: run from inside another project's dev shell, the build
# inherited its SDKROOT and failed in a dependency ("'sqlite3.h' file not
# found"). The compiler must not see those variables; a deliberate toolchain
# selection must survive; and the caller must be told what was ignored.
test_the_build_ignores_an_inherited_dev_shell_sdk() {
    local case_dir out seen
    case_dir="$(mkcase sdk-scrub-case)"
    out="$(SDKROOT=/nix/store/acme-apple-sdk/SDKs/MacOSX.sdk \
        DEVELOPER_DIR=/nix/store/acme-apple-sdk \
        IN_NIX_SHELL=impure CPATH=/nix/store/acme/include \
        NIX_LDFLAGS=-L/nix/store/acme/lib TOOLCHAINS=org.acme.swift \
        run_update "$case_dir" --dry-run --no-wake)"
    seen="$(cat "$case_dir/build-env.log")"
    assert_contains "the compiler sees no dev-shell SDKROOT" \
        "SDKROOT=unset DEVELOPER_DIR=unset IN_NIX_SHELL=unset CPATH=unset NIX_LDFLAGS=unset" "$seen"
    assert_contains "a deliberate TOOLCHAINS selection is left alone" "TOOLCHAINS=org.acme.swift" "$seen"
    assert_contains "the update says what it ignored" "ignoring inherited compiler-environment variables" "$out"
    assert_contains "and names the variable" "SDKROOT" "$out"
}

test_an_xcode_sdk_selection_is_kept() {
    local case_dir seen
    case_dir="$(mkcase sdk-keep-case)"
    SDKROOT=/Applications/Xcode-beta.app/Contents/Developer/SDKs/MacOSX.sdk \
        DEVELOPER_DIR=/Library/Developer/CommandLineTools \
        run_update "$case_dir" --dry-run --no-wake >/dev/null
    seen="$(cat "$case_dir/build-env.log")"
    assert_contains "an Xcode SDKROOT reaches the compiler" \
        "SDKROOT=/Applications/Xcode-beta.app/Contents/Developer/SDKs/MacOSX.sdk" "$seen"
    assert_contains "a Command Line Tools DEVELOPER_DIR reaches the compiler" \
        "DEVELOPER_DIR=/Library/Developer/CommandLineTools" "$seen"
}

test_keep_build_env_switch_turns_the_scrub_off() {
    local case_dir out seen
    case_dir="$(mkcase sdk-optout-case)"
    out="$(SDKROOT=/nix/store/acme-apple-sdk/SDKs/MacOSX.sdk TBD_KEEP_BUILD_ENV=1 \
        run_update "$case_dir" --dry-run --no-wake)"
    seen="$(cat "$case_dir/build-env.log")"
    assert_contains "TBD_KEEP_BUILD_ENV=1 passes SDKROOT through" \
        "SDKROOT=/nix/store/acme-apple-sdk/SDKs/MacOSX.sdk" "$seen"
    assert_not_contains "and nothing is reported as ignored" "ignoring inherited" "$out"
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

# The exclusivity the noclobber create buys: many runs starting at once, one
# winner. Each contender is a real process, because subshells of one shell all
# share their parent's `$$` and would every one of them read the first winner's
# lock as their own. They wait on a start file so the attempts genuinely
# overlap, and every winner stays alive until the fan-out is over — a winner
# that had already exited would leave a lock the next contender is right to
# take over. A check-then-write acquire admits more than one here.
test_simultaneous_acquire_lock_admits_exactly_one() {
    local dir runner i winners losers lock_pid
    dir="$TEST_TMP/lock-fanout"
    mkdir -p "$dir/updates" "$dir/results"

    runner="$dir/contend.sh"
    cat > "$runner" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail
export TBD_HOME="$1"
# shellcheck source=/dev/null
source "$2"
UPDATE_HOME="$3"
UPDATE_LOCK="$3/update.lock"
UPDATE_LOG="$3/update.log"
OPT_AUTO=true
until [ -f "$5" ]; do sleep 0.02; done
acquire_lock >/dev/null 2>&1
printf 'rc=%s pid=%s\n' "$?" "$$" > "$4"
sleep 1
EOF

    for i in 1 2 3 4 5 6 7 8; do
        bash "$runner" "$TEST_TMP/tbd" "$SCRIPT" "$dir/updates" \
            "$dir/results/$i" "$dir/start" &
    done
    sleep 0.5
    : > "$dir/start"
    wait

    winners="$(cat "$dir"/results/* | grep -c '^rc=0 ')"
    losers="$(cat "$dir"/results/* | grep -c '^rc=1 ')"
    assert_eq "exactly one of eight simultaneous acquires wins" "1" "$winners"
    assert_eq "the other seven are refused" "7" "$losers"

    lock_pid="$(lock_holder_pid "$dir/updates/update.lock")"
    if grep -qh "^rc=0 pid=$lock_pid\$" "$dir"/results/*; then
        pass "the lock names the process that won it"
    else
        fail "the lock names the process that won it: lock holds [$lock_pid]"
    fi
}

test_stale_lock_takeover_leaves_no_debris() {
    local home dead out
    home="$TEST_TMP/stale-debris/updates"
    mkdir -p "$home"
    dead=$(( ($$ + 100000) % 60000 + 2 ))
    while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done

    printf '%s\n' "$dead" > "$home/update.lock"
    out="$(
        UPDATE_HOME="$home"
        UPDATE_LOCK="$home/update.lock"
        UPDATE_LOG="$home/update.log"
        OPT_AUTO=true
        acquire_lock 2>/dev/null
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "a dead holder's lock is taken over" "rc=0" "$out"
    assert_eq "and the lock now names the taker" "$$" "$(lock_holder_pid "$home/update.lock")"

    # A lock with no pid in it at all is stale by the same route.
    printf 'garbage\n' > "$home/update.lock"
    out="$(
        UPDATE_HOME="$home"
        UPDATE_LOCK="$home/update.lock"
        UPDATE_LOG="$home/update.log"
        OPT_AUTO=true
        acquire_lock 2>/dev/null
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "a lock with no pid in it is taken over too" "rc=0" "$out"
    assert_eq "and that one names the taker as well" "$$" "$(lock_holder_pid "$home/update.lock")"

    assert_no_lock_debris "the takeover leaves no temporary files behind" "$home"

    # A run killed between writing its temp file and renaming it leaves a
    # `.new.<pid>` beside the lock. The next takeover holds the mutex, so it
    # is the one place that can know the file is a stray, and sweeps it.
    printf '%s\n' "$dead" > "$home/update.lock"
    printf '%s\n' "$dead" > "$home/update.lock.new.$dead"
    out="$(
        UPDATE_HOME="$home"
        UPDATE_LOCK="$home/update.lock"
        UPDATE_LOG="$home/update.log"
        OPT_AUTO=true
        acquire_lock 2>/dev/null
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "a takeover beside a stray temp file still succeeds" "rc=0" "$out"
    assert_no_lock_debris "and sweeps the stray a killed run left behind" "$home"
}

# Every scratch name the takeover can create: the temp file it renames onto the
# lock, the takeover mutex, and the rename-aside file an older design used. A
# successful takeover must leave none of them.
assert_no_lock_debris() {
    local description="$1" home="$2" found
    found="$(find "$home" -name 'update.lock.new.*' -o -name 'update.lock.stale.*' \
        -o -name 'update.lock.takeover' 2>/dev/null)"
    if [ -z "$found" ]; then
        pass "$description"
    else
        fail "$description: $found"
    fi
}

# Set a path's mtime ten minutes into the past. BSD and GNU date spell relative
# times differently, so try the BSD form first and fall back to the GNU one.
backdate_ten_minutes() {
    local path="${1-}" stamp
    stamp="$(date -v-10M +%Y%m%d%H%M.%S 2>/dev/null)"
    [ -n "$stamp" ] || stamp="$(date -d '-10 min' +%Y%m%d%H%M.%S 2>/dev/null)"
    [ -n "$stamp" ] || return 1
    touch -t "$stamp" "$path"
}

# The refusal branch: a lock we judged stale turns out to name a live process
# when we re-read it inside the takeover critical section, because a racer
# replaced the file in between. Simulated deterministically by counting calls
# to lock_is_live — false for the read that admits us to the section, true for
# the re-read inside it. A counter rather than a path test because both calls
# now look at the same path, and a file rather than a variable because
# acquire_lock runs in a command substitution, whose variables do not escape.
test_stale_lock_takeover_refuses_a_lock_that_turned_live() {
    local home dead out
    home="$TEST_TMP/stale-racer/updates"
    mkdir -p "$home"
    dead=$(( ($$ + 100000) % 60000 + 2 ))
    while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done

    printf '%s\n' "$dead" > "$home/update.lock"
    printf '0\n' > "$home/liveness-calls"
    out="$(
        UPDATE_HOME="$home"
        UPDATE_LOCK="$home/update.lock"
        UPDATE_LOG="$home/update.log"
        OPT_AUTO=true
        lock_is_live() {
            local n
            n="$(cat "$home/liveness-calls" 2>/dev/null)"
            n=$(( ${n:-0} + 1 ))
            printf '%s\n' "$n" > "$home/liveness-calls"
            [ "$n" -ge 2 ]
        }
        acquire_lock 2>/dev/null
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "a lock that turns live under us is not stolen" "rc=1" "$out"
    assert_contains "and the refusal names its holder" \
        "another update is already running (pid $dead)" "$(cat "$home/update.log")"
    assert_eq "the lock is left exactly as it was" "$dead" \
        "$(lock_holder_pid "$home/update.lock")"
    assert_no_lock_debris "and the refusal leaves nothing behind" "$home"
}

# The mutex cannot become a deadlock: a run that died inside the critical
# section leaves a takeover directory nobody will ever remove, so one older
# than a minute is reclaimed before the next run contends for it.
test_an_abandoned_takeover_mutex_is_reclaimed() {
    local home dead out
    home="$TEST_TMP/takeover-abandoned/updates"
    mkdir -p "$home/update.lock.takeover"
    dead=$(( ($$ + 100000) % 60000 + 2 ))
    while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
    printf '%s\n' "$dead" > "$home/update.lock"
    # The creator recorded itself and then died.
    printf '%s\n' "$dead" > "$home/update.lock.takeover/owner"

    if ! backdate_ten_minutes "$home/update.lock.takeover"; then
        fail "backdating a path needs a date that speaks BSD or GNU relative times"
        return
    fi

    out="$(
        UPDATE_HOME="$home"
        UPDATE_LOCK="$home/update.lock"
        UPDATE_LOG="$home/update.log"
        OPT_AUTO=true
        acquire_lock 2>/dev/null
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "an abandoned takeover mutex does not block the next run" "rc=0" "$out"
    assert_eq "and the stale lock is taken over" "$$" "$(lock_holder_pid "$home/update.lock")"
    assert_no_lock_debris "and the reclaimed mutex is gone" "$home"
}

# Age alone is not abandonment. A holder stalled inside the critical section
# by a suspended machine or a hung filesystem still owns it for as long as its
# process lives, and taking the mutex from under it would let two runs replace
# the lock at once — the race the mutex exists to prevent.
test_an_old_takeover_mutex_with_a_live_owner_is_kept() {
    local home dead out
    home="$TEST_TMP/takeover-stalled/updates"
    mkdir -p "$home/update.lock.takeover"
    dead=$(( ($$ + 100000) % 60000 + 2 ))
    while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
    printf '%s\n' "$dead" > "$home/update.lock"
    # This very process is the stalled holder.
    printf '%s\n' "$$" > "$home/update.lock.takeover/owner"

    if ! backdate_ten_minutes "$home/update.lock.takeover"; then
        fail "backdating a path needs a date that speaks BSD or GNU relative times"
        return
    fi

    out="$(
        UPDATE_HOME="$home"
        UPDATE_LOCK="$home/update.lock"
        UPDATE_LOG="$home/update.log"
        OPT_AUTO=true
        acquire_lock 2>/dev/null
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "an old mutex whose owner still runs refuses this run" "rc=1" "$out"
    assert_eq "and the stale lock is not clobbered" "$dead" \
        "$(lock_holder_pid "$home/update.lock")"
    if [ -d "$home/update.lock.takeover" ]; then
        pass "and the stalled holder keeps its mutex"
    else
        fail "and the stalled holder keeps its mutex"
    fi
    assert_eq "with its owner record intact" "$$" \
        "$(cat "$home/update.lock.takeover/owner")"
}

# A mutex whose creator died between the mkdir and writing its pid has no
# owner record at all; old and ownerless is abandoned.
test_an_old_ownerless_takeover_mutex_is_reclaimed() {
    local home dead out
    home="$TEST_TMP/takeover-ownerless/updates"
    mkdir -p "$home/update.lock.takeover"
    dead=$(( ($$ + 100000) % 60000 + 2 ))
    while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
    printf '%s\n' "$dead" > "$home/update.lock"

    if ! backdate_ten_minutes "$home/update.lock.takeover"; then
        fail "backdating a path needs a date that speaks BSD or GNU relative times"
        return
    fi

    out="$(
        UPDATE_HOME="$home"
        UPDATE_LOCK="$home/update.lock"
        UPDATE_LOG="$home/update.log"
        OPT_AUTO=true
        acquire_lock 2>/dev/null
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "an old ownerless mutex is reclaimed" "rc=0" "$out"
    assert_no_lock_debris "and nothing of it remains" "$home"
}

# The other half of the same rule: a mutex young enough to belong to a live
# takeover is left strictly alone, and the run that finds it refuses rather
# than replacing a lock somebody else is in the middle of replacing.
test_a_fresh_takeover_mutex_refuses_the_run() {
    local home dead out
    home="$TEST_TMP/takeover-held/updates"
    mkdir -p "$home/update.lock.takeover"
    dead=$(( ($$ + 100000) % 60000 + 2 ))
    while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
    printf '%s\n' "$dead" > "$home/update.lock"

    out="$(
        UPDATE_HOME="$home"
        UPDATE_LOCK="$home/update.lock"
        UPDATE_LOG="$home/update.log"
        OPT_AUTO=true
        acquire_lock 2>/dev/null
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "a takeover somebody else is running refuses this one" "rc=1" "$out"
    assert_contains "and says the lock could not be taken" \
        "could not take the update lock" "$(cat "$home/update.log")"
    assert_eq "the stale lock is not clobbered" "$dead" \
        "$(lock_holder_pid "$home/update.lock")"
    if [ -d "$home/update.lock.takeover" ]; then
        pass "and somebody else's takeover mutex is left alone"
    else
        fail "and somebody else's takeover mutex is left alone"
    fi
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
# Stand-in for a newer update.sh: report that it ran, with what, and what the
# lock file said when it arrived. `exec` keeps the pid, so a lock naming this
# process is the one the outgoing image was holding.
lock="${TBD_HOME:-$HOME/tbd}/updates/update.lock"
printf 'REEXECED guard=%s args=%s lock=%s pid=%s\n' \
    "${TBD_UPDATE_REEXEC:-unset}" "$*" "$(cat "$lock" 2>/dev/null)" "$$"
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

    # The lock is carried across rather than released and retaken: releasing it
    # first would leave a window in which a second update could start against
    # the same clone.
    local lock_pid own_pid
    lock_pid="$(printf '%s' "$out" | sed -n 's/.*lock=\([0-9]*\) .*/\1/p')"
    own_pid="$(printf '%s' "$out" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
    if [ -n "$lock_pid" ] && [ "$lock_pid" = "$own_pid" ]; then
        pass "the re-exec keeps the lock, still naming the same process"
    else
        fail "the re-exec keeps the lock, still naming the same process: lock=[$lock_pid] pid=[$own_pid]"
    fi
}

test_reexec_when_only_a_sourced_library_differs() {
    local case_dir out
    case_dir="$(mkcase reexec-lib-case)"
    # The fetched update.sh is byte-identical to the running one; only the
    # library it sources has moved on.
    printf "\n# a newer library\n" >> "$case_dir/remote/scripts/restart-bundle-lib.sh"
    git -C "$case_dir/remote" commit -q -am "library only"

    out="$(run_update "$case_dir" --dry-run --no-wake)"
    assert_contains "a library-only change re-execs" \
        "re-exec: the fetched restart-bundle-lib.sh differs" "$out"
    assert_contains "and the fetched script completes the dry run" \
        "installing nothing" "$out"
    assert_eq "the hop happens once" "1" \
        "$(printf "%s" "$out" | grep -c "re-exec: the fetched")"
}

# The layout `tbd update` runs in on an installation that has updated before:
# the daemon was built in the update clone, so the update.sh it runs, and the
# libraries that script sources, are the clone's own files, which the fetch
# then checks out at the new main in place.
test_reexec_when_the_script_runs_from_the_update_clone() {
    local case_dir clone out leftover
    case_dir="$(mkcase reexec-clone-case)"
    clone="$case_dir/home/tbd/updates/src"
    # The clone as an earlier update left it: detached at the remote's head,
    # and the source worktree of the daemon that update installed.
    git clone -q --no-checkout "$case_dir/remote" "$clone"
    git -C "$clone" checkout -q --detach origin/main
    cat > "$case_dir/state/status.json" << EOF
{
  "executablePath": "$clone/.build/release/TBDDaemon",
  "buildIdentity": {
    "commit": "$(git -C "$clone" rev-parse HEAD)",
    "sourceWorktree": "$clone"
  }
}
EOF
    # Upstream moves on in a library only.
    printf "\n# a newer library\n" >> "$case_dir/remote/scripts/restart-bundle-lib.sh"
    git -C "$case_dir/remote" commit -q -am "library only"

    # A TMPDIR of the case's own, so whatever the run leaves there is visible.
    mkdir -p "$case_dir/tmp"
    out="$(TMPDIR="$case_dir/tmp" \
        run_update_from "$case_dir" "$clone/scripts/update.sh" --dry-run --no-wake)"
    assert_contains "a library change re-execs when the script runs from the clone" \
        "re-exec: the fetched restart-bundle-lib.sh differs" "$out"
    assert_contains "and the fetched script completes the dry run" \
        "installing nothing" "$out"
    assert_eq "the hop happens once" "1" \
        "$(printf "%s" "$out" | grep -c "re-exec: the fetched")"
    leftover="$(find "$case_dir/tmp" -name 'tbd-update-running.*' 2>/dev/null)"
    assert_eq "neither image leaves its copy of the running scripts behind" "" "$leftover"
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

# The fallback used whenever the daemon has not compared itself to main — the
# normal state under the shipped `off` — must decide ancestry, not equality. A
# developer running a build ahead of main must not be told to replace it.
test_check_fallback_decides_ancestry_like_the_daemon() {
    local case_dir out remote_head local_head
    case_dir="$(mkcase check-ancestry-case)"
    remote_head="$(git -C "$case_dir/remote" rev-parse HEAD)"

    # Ahead: main plus one local commit the remote does not have.
    git -C "$case_dir/worktree" fetch -q upstream main
    git -C "$case_dir/worktree" checkout -q -b main FETCH_HEAD
    git -C "$case_dir/worktree" -c user.name=t -c user.email=t@example \
        commit -q --allow-empty -m "local work"
    local_head="$(git -C "$case_dir/worktree" rev-parse HEAD)"
    cat > "$case_dir/state/status.json" << EOF
{
  "executablePath": "$case_dir/worktree/.build/debug/TBDDaemon",
  "buildIdentity": {"commit": "$local_head", "sourceWorktree": "$case_dir/worktree"}
}
EOF
    out="$(run_update "$case_dir" --check)"
    assert_contains "a build ahead of main is up to date" "Up to date." "$out"
    assert_not_contains "and is not told to replace itself" "Run: tbd update" "$out"

    # Behind, with the objects local: the fetched main head is an ancestor's
    # descendant of the running commit.
    git -C "$case_dir/remote" -c user.name=t -c user.email=t@example \
        commit -q --allow-empty -m "main moved"
    git -C "$case_dir/worktree" fetch -q upstream main
    cat > "$case_dir/state/status.json" << EOF
{
  "executablePath": "$case_dir/worktree/.build/debug/TBDDaemon",
  "buildIdentity": {"commit": "$remote_head", "sourceWorktree": "$case_dir/worktree"}
}
EOF
    out="$(run_update "$case_dir" --check)"
    assert_contains "a build behind main with the objects local is told to update" \
        "Run: tbd update" "$out"

    # Undecidable: the source worktree is not a repository at all.
    rm -rf "$case_dir/worktree/.git"
    out="$(run_update "$case_dir" --check)"
    assert_contains "a worktree that cannot answer reports unknown" "Unknown" "$out"
    assert_not_contains "and does not invent an update" "Run: tbd update" "$out"

    assert_eq "local_relation: equal commits are up to date" "upToDate" \
        "$(local_relation "$case_dir/worktree" "$remote_head" "$remote_head")"
    assert_eq "local_relation: no running commit is unknown" "unknown" \
        "$(local_relation "$case_dir/worktree" "" "$remote_head")"
}

# MARK: - The full dry run
#
# One fetch-and-build, asserted from every angle: what it built, what it wrote,
# what it refused to touch, and what it reported. A second run costs a clone
# and one fake build per RUNTIME_PRODUCTS entry, so the cases share this one.

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
    assert_contains "--dry-run builds the pty holder" "building TBDHolder" "$out"
    assert_contains "--dry-run builds the peer helper" "building TBDPeerHelper" "$out"
    assert_contains "--dry-run says it installs nothing" "installing nothing" "$out"
    assert_not_contains "--dry-run does not assemble a bundle" \
        "assembling and installing" "$out"
    assert_not_contains "--dry-run does not hand over" "handing over" "$out"
    if [ -f "$case_dir/open.log" ]; then
        fail "--dry-run does not launch the app"
    else
        pass "--dry-run does not launch the app"
    fi
    assert_eq "--dry-run builds the release configuration by default" "5" \
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
        assert_eq "the sidecar records the release configuration" "release" \
            "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("configuration"))' "$sidecar")"
        # The bundle this build becomes is the next update's kept bundle, and
        # the daemon reads this value from it before dropping a retired column.
        assert_eq "the sidecar records the fetched tree's schema epoch" \
            "$(sed -n -E 's/^[[:space:]]*public static let current = ([0-9]+)[[:space:]]*$/\1/p' \
                "$case_dir/remote/Sources/TBDShared/SchemaEpoch.swift")" \
            "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["schemaEpoch"])' "$sidecar")"
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

# THE REGRESSION: a build identity stamp that failed only warned, and the
# build directory still held the sidecar of the build before, which the
# bundle assembled from it carried as its own: the keep, the rollback and the
# report then went by the wrong build. Now a failed stamp installs nothing,
# with an error, before the app is touched, and leaves no sidecar in the
# build directory to be read as the new build's. Here a dry run stamped the
# build directory first, and the commit the update then fetches has no
# schema epoch, so its stamp fails.
test_a_failed_identity_stamp_installs_nothing() {
    local case_dir out rc events sidecar
    case_dir="$(mkcase stamp-fails)"
    events="$case_dir/events.log"
    sidecar="$case_dir/home/tbd/updates/src/.build/release/TBDBuildIdentity.json"
    run_update "$case_dir" --dry-run >/dev/null
    if [ -f "$sidecar" ]; then
        pass "an earlier build left its sidecar in the build directory"
    else
        fail "an earlier build left its sidecar in the build directory: missing $sidecar"
    fi
    git -C "$case_dir/remote" rm -q Sources/TBDShared/SchemaEpoch.swift
    git -C "$case_dir/remote" commit -q -m "no schema epoch"
    out="$(run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed stamp fails the run" "1" "$rc"
    assert_contains_literal "with an error that says nothing is installed" \
        "ERROR: could not stamp the build identity of $case_dir/home/tbd/updates/src/.build/release — installing nothing" \
        "$out"
    assert_not_contains "nothing is installed" "^install " "$(cat "$events")"
    assert_not_contains "the app is never signalled" "^pkill" "$(cat "$events")"
    assert_not_contains "nothing is handed over" "^handover" "$(cat "$events")"
    if [ -f "$case_dir/app" ]; then
        pass "the app is still running"
    else
        fail "the app is still running"
    fi
    assert_eq "the earlier build's sidecar is not left to be read as the new build's" "gone" \
        "$(path_state "$sidecar")"
}

test_debug_flag_selects_the_debug_configuration() {
    local case_dir
    case_dir="$(mkcase debug-case)"
    run_update "$case_dir" --dry-run --debug >/dev/null 2>&1
    assert_eq "--debug builds the debug configuration" "5" \
        "$(grep -c 'debug' "$case_dir/build.log")"
    assert_eq "and stamps it as the debug configuration" "debug" \
        "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("configuration"))' \
            "$case_dir/home/tbd/updates/src/.build/debug/TBDBuildIdentity.json" 2>/dev/null)"
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

# THE REGRESSION: the update clone under $UPDATE_HOME is one long-lived
# checkout every update reuses (docs/updating.md), and its build identity
# sidecar used to be stamped BEFORE build_products ran. A build that then
# failed left that sidecar naming the commit it never finished building,
# right next to the still-old binaries a first, successful update had left
# there — and nothing ever wrote it again to put that right, since the only
# later write in the same clone is the next update's, success or failure.
# Reproduce exactly that: one good update stamps commit A, then a second,
# broken commit B fails to build, and the sidecar this clone carries must
# still say A — not B, and not disappear.
test_a_failed_build_leaves_the_previous_stamp_alone() {
    local case_dir sidecar commit_a commit_b out
    case_dir="$(mkcase stamp-on-failure-case)"
    sidecar="$case_dir/home/tbd/updates/src/.build/release/TBDBuildIdentity.json"

    run_update "$case_dir" --dry-run >/dev/null 2>&1
    commit_a="$(git -C "$case_dir/remote" rev-parse HEAD)"
    if [ -f "$sidecar" ]; then
        pass "the first, successful update stamps the sidecar"
    else
        fail "the first, successful update stamps the sidecar: missing $sidecar"
    fi
    assert_eq "the sidecar names the first build's commit" "$commit_a" \
        "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$sidecar")"

    cat > "$case_dir/remote/scripts/swift-safe" << 'EOF'
#!/bin/sh
echo "error: it did not compile" >&2
exit 1
EOF
    chmod +x "$case_dir/remote/scripts/swift-safe"
    git -C "$case_dir/remote" commit -q -am "break the build"
    commit_b="$(git -C "$case_dir/remote" rev-parse HEAD)"

    out="$(run_update "$case_dir" --dry-run 2>&1)"
    assert_contains "the second, broken update still fetches the new commit" \
        "latest main is $commit_b" "$out"
    assert_eq "the sidecar still names the commit that actually built" "$commit_a" \
        "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["commit"])' "$sidecar")"
}

# A failed compile names its first errors, not SwiftPM's last lines, and the
# full output survives in build.log next to update.log.
test_a_failed_build_reports_its_first_errors() {
    local case_dir out update_log build_log
    case_dir="$(mkcase first-errors-case)"
    cat > "$case_dir/remote/scripts/swift-safe" << 'EOF'
#!/bin/sh
echo "Compiling GRDBSQLite shim.h"
echo "shim.h:1:10: error: 'sqlite3.h' file not found" >&2
echo "CLIInstaller.swift:31:13: error: let 'logger' is not concurrency-safe" >&2
i=0
while [ "$i" -lt 30 ]; do echo "noise line $i"; i=$((i + 1)); done
exit 1
EOF
    chmod +x "$case_dir/remote/scripts/swift-safe"
    git -C "$case_dir/remote" commit -q -am "break the build"

    out="$(run_update "$case_dir")"
    if [ "$?" -ne 0 ]; then
        pass "a compile failure exits non-zero"
    else
        fail "a compile failure exits non-zero"
    fi
    update_log="$(cat "$case_dir/home/tbd/updates/update.log")"
    build_log="$case_dir/home/tbd/updates/build.log"
    assert_contains "the output names the first error" "sqlite3.h' file not found" "$out"
    assert_contains "the output names the second error" "is not concurrency-safe" "$out"
    assert_not_contains "the output skips the trailing noise" "noise line 29" "$out"
    assert_contains "update.log names the first error" "sqlite3.h' file not found" "$update_log"
    assert_contains "update.log points at the full output" "full build output: $build_log" "$update_log"
    assert_not_contains "a compile failure is not called a slot timeout" "waiting for the build slot" "$update_log"
    assert_contains "build.log keeps the full output" "noise line 29" "$(cat "$build_log")"
}

# swift-safe's 75 means the build never got the machine-wide slot. Nothing was
# compiled, and saying "failed" sends the reader hunting for a compile error.
test_a_slot_timeout_is_not_reported_as_a_compile_failure() {
    local case_dir out update_log
    case_dir="$(mkcase slot-timeout-case)"
    cat > "$case_dir/remote/scripts/swift-safe" << 'EOF'
#!/bin/sh
echo "swift-safe: timed out after 1800s waiting for the build lock" >&2
exit 75
EOF
    chmod +x "$case_dir/remote/scripts/swift-safe"
    git -C "$case_dir/remote" commit -q -am "hold the slot"

    out="$(run_update "$case_dir")"
    if [ "$?" -ne 0 ]; then
        pass "a slot timeout exits non-zero"
    else
        fail "a slot timeout exits non-zero"
    fi
    update_log="$(cat "$case_dir/home/tbd/updates/update.log")"
    assert_contains "a slot timeout says so" "timed out waiting for the build slot" "$out"
    assert_contains "update.log records the slot timeout" "nothing was compiled" "$update_log"
    assert_not_contains "a slot timeout is not called a compile failure" "failed (exit" "$update_log"
    assert_contains "a slot timeout still says the installation is untouched" \
        "the running installation is untouched" "$out"
}

test_build_failure_excerpt_with_auto_flag_goes_only_to_log() {
    local case_dir out update_log
    case_dir="$(mkcase auto-failure-case)"
    cat > "$case_dir/remote/scripts/swift-safe" << 'EOF'
#!/bin/sh
echo "Compiling module"
echo "source.swift:10:5: error: 'foo' is not defined" >&2
exit 1
EOF
    chmod +x "$case_dir/remote/scripts/swift-safe"
    git -C "$case_dir/remote" commit -q -am "break the build"

    out="$(run_update "$case_dir" --auto)"
    if [ "$?" -ne 0 ]; then
        pass "a build failure with --auto exits non-zero"
    else
        fail "a build failure with --auto exits non-zero"
    fi
    update_log="$(cat "$case_dir/home/tbd/updates/update.log")"
    assert_eq "--auto prints nothing to the terminal (silent)" "" "$out"
    assert_contains "the error excerpt goes to update.log when --auto is set" \
        "'foo' is not defined" "$update_log"
    assert_contains "the failure message goes to update.log when --auto is set" \
        "the running installation is untouched" "$update_log"
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
# Both branches of the app opt-out. The app stage runs after the handover, so a
# full run is not where this is observable either.
test_no_app_skips_the_relaunch() {
    local bin out
    bin="$TEST_TMP/no-app-bin"
    mkstub_tbd "$bin"

    out="$(
        export PATH="$bin:$PATH" FAKE_OPEN_LOG="$TEST_TMP/no-app-open.log"
        OPT_AUTO=false
        OPT_NO_APP=true
        run_app_stage
    )"
    assert_contains "--no-app says it is leaving the app alone" \
        "leaving the running app alone" "$out"
    if [ -f "$TEST_TMP/no-app-open.log" ]; then
        fail "--no-app launches nothing"
    else
        pass "--no-app launches nothing"
    fi

    out="$(
        export PATH="$bin:$PATH" FAKE_OPEN_LOG="$TEST_TMP/app-open.log" \
            FAKE_KILL_LOG="$TEST_TMP/app-kill.log"
        OPT_AUTO=false
        OPT_NO_APP=false
        run_app_stage
    )"
    assert_contains "without --no-app the app is restarted" "restarting the app" "$out"
    assert_contains "without --no-app the bundle is launched with the PATH" \
        "open --env PATH=" "$(cat "$TEST_TMP/app-open.log" 2>/dev/null)"
    assert_contains "the launch targets the installed bundle" \
        "$INSTALLED_BUNDLE" "$(cat "$TEST_TMP/app-open.log" 2>/dev/null)"
    assert_contains_literal "the stop is anchored on the installed bundle's binary" \
        "pkill -f ^$(escape_exec_pattern "$INSTALLED_BUNDLE/Contents/MacOS/TBDApp")\$" \
        "$(cat "$TEST_TMP/app-kill.log" 2>/dev/null)"
}

# A manual app stage seeds the saved tmux fallback on both branches of
# --no-app: the next login relaunch needs it whether or not this run
# relaunched. An --auto stage does not: its PATH carries fixed-directory
# guesses rather than the user's shell.
test_app_stage_seeds_the_tmux_fallback() {
    local bin tmuxbin opt
    bin="$TEST_TMP/seed-stage-bin"
    tmuxbin="$TEST_TMP/seed-stage-tmux"
    mkstub_tbd "$bin"
    mkdir -p "$tmuxbin"
    printf '#!/bin/sh\n' > "$tmuxbin/tmux"; chmod +x "$tmuxbin/tmux"

    for opt in true false; do
        rm -f "$TBD_HOME_DIR/tmux-executable-path"
        (
            export PATH="$tmuxbin:$bin:$PATH" FAKE_OPEN_LOG="$TEST_TMP/seed-open.log" \
                FAKE_KILL_LOG="$TEST_TMP/seed-kill.log"
            OPT_AUTO=false
            OPT_NO_APP="$opt"
            run_app_stage
        ) >/dev/null 2>&1
        assert_eq "the app stage seeds the tmux fallback (--no-app=$opt)" \
            "$tmuxbin/tmux" "$(cat "$TBD_HOME_DIR/tmux-executable-path" 2>/dev/null)"
    done

    rm -f "$TBD_HOME_DIR/tmux-executable-path"
    (
        export PATH="$tmuxbin:$bin:$PATH" FAKE_OPEN_LOG="$TEST_TMP/seed-open.log" \
            FAKE_KILL_LOG="$TEST_TMP/seed-kill.log"
        OPT_AUTO=true
        OPT_NO_APP=true
        run_app_stage
    ) >/dev/null 2>&1
    if [ -f "$TBD_HOME_DIR/tmux-executable-path" ]; then
        fail "an --auto app stage does not seed the tmux fallback"
    else
        pass "an --auto app stage does not seed the tmux fallback"
    fi
    rm -f "$TBD_HOME_DIR/tmux-executable-path"
}

test_no_wake_skips_the_stage() {
    local state out
    state="$TEST_TMP/no-wake-state"
    mkdir -p "$state" "$TEST_TMP/no-wake-bin"
    mkstub_tbd "$TEST_TMP/no-wake-bin"
    printf '[{"id":"w1"}]\n' > "$state/worktrees.json"
    printf '[{"id":"a","hibernatedAt":"2026-09-04T12:00:01Z","hibernateReason":"recovery","transport":"holder"}]\n' \
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
 {"id":"aaa","hibernatedAt":"2026-09-04T12:00:05Z","hibernateReason":"recovery","transport":"holder"},
 {"id":"bbb","hibernatedAt":"2026-09-04T11:00:00Z","hibernateReason":"recovery","transport":"holder"},
 {"id":"ccc","hibernatedAt":"2026-09-04T12:00:07Z","hibernateReason":"idle","transport":"holder"},
 {"id":"ddd","hibernatedAt":null,"hibernateReason":null,"transport":"holder"},
 {"id":"eee","hibernatedAt":"2026-09-04T12:00:00Z","hibernateReason":"recovery","transport":"holder"},
 {"id":"fff","hibernatedAt":"2026-09-04T12:30:11Z","hibernateReason":"recovery","transport":"holder"}
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

    picked="$(printf '%s' '[{"id":"g","hibernatedAt":"2026-09-04T12:00:05.482Z","hibernateReason":"recovery","transport":"holder"}]' \
        | select_wake_candidates "2026-09-04T12:00:00Z" | tr '\n' ' ')"
    assert_eq "fractional seconds compare correctly" "g " "$picked"

    assert_eq "an empty list yields no candidate" "" \
        "$(printf '[]' | select_wake_candidates "")"
}

# A recovery park on tmux is not this update's to wake: the daemon refuses it
# and names `tbd terminal migrate`. Absent and unrecognized transports read as
# tmux, as the app's decoder reads them. The holder row beside them is the
# positive control: the same park, on the holder, is taken.
test_wake_candidates_exclude_tmux_rows() {
    local picked
    picked="$(printf '%s' '[
 {"id":"tmx","hibernatedAt":"2026-09-04T12:00:05Z","hibernateReason":"recovery","transport":"tmux"},
 {"id":"nul","hibernatedAt":"2026-09-04T12:00:05Z","hibernateReason":"recovery","transport":null},
 {"id":"abs","hibernatedAt":"2026-09-04T12:00:05Z","hibernateReason":"recovery"},
 {"id":"unk","hibernatedAt":"2026-09-04T12:00:05Z","hibernateReason":"recovery","transport":"acme"},
 {"id":"hld","hibernatedAt":"2026-09-04T12:00:05Z","hibernateReason":"recovery","transport":"holder"}
]' | select_wake_candidates "2026-09-04T12:00:00Z" | tr '\n' ' ')"
    assert_eq "only the holder row of a recovery park is a candidate" "hld " "$picked"
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

# The handover starts the new daemon as a background child of this same shell,
# and the wake step runs after it. Waking must wait for its own wakes only: a
# wait that also covered the daemon would never return, and the run would hold
# the update lock for as long as the daemon lives.
test_wake_ignores_other_background_children() {
    local state out
    state="$TEST_TMP/wake-daemon-state"
    mkdir -p "$state" "$TEST_TMP/wake-bin"
    mkstub_tbd "$TEST_TMP/wake-bin"
    : > "$state/wake.log"

    out="$(
        export FAKE_TBD_STATE="$state" PATH="$TEST_TMP/wake-bin:$PATH"
        OPT_AUTO=false
        WAKE_STAGGER_SECONDS=0
        # Stands in for the daemon. Bounded so a regression fails slowly rather
        # than hanging the suite.
        sleep 20 &
        daemon=$!
        started=$SECONDS
        wake_terminals t1 t2
        printf 'elapsed=%s woken=%s failed=%s\n' "$((SECONDS - started))" "$WAKE_WOKEN" "$WAKE_FAILED"
        kill "$daemon" 2>/dev/null
        wait "$daemon" 2>/dev/null
    )"

    assert_contains "both sessions are counted as woken" "woken=2 failed=0" "$out"
    local elapsed
    elapsed="$(printf '%s' "$out" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
    if [ -n "$elapsed" ] && [ "$elapsed" -lt 10 ]; then
        pass "the wake returns without waiting for the daemon (${elapsed}s)"
    else
        fail "the wake returns without waiting for the daemon (took ${elapsed:-?}s)"
    fi
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
[{"id":"aaa","hibernatedAt":"2026-09-04T12:00:05Z","hibernateReason":"recovery","transport":"holder"},
 {"id":"bbb","hibernatedAt":"2026-09-04T12:00:05Z","hibernateReason":"idle","transport":"holder"}]
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
    printf '[{"id":"a","hibernatedAt":"2026-09-04T12:00:01Z","hibernateReason":"recovery","transport":"holder"}]\n' \
        > "$state/terminals-w1.json"
    printf '[{"id":"b","hibernatedAt":"2026-09-04T12:00:02Z","hibernateReason":"recovery","transport":"holder"}]\n' \
        > "$state/terminals-w2.json"

    out="$(
        export FAKE_TBD_STATE="$state" PATH="$TEST_TMP/collect-bin:$PATH"
        all_terminals_json | select_wake_candidates "" | tr '\n' ' '
    )"
    assert_eq "rows from every worktree are considered" "a b " "$out"
}

# Production output is pretty-printed and a tab label is free text. The merge
# must parse each worktree's document, not count brackets: one `[` in a label
# used to unbalance the count and silently drop every row after it.
test_terminals_survive_brackets_and_pretty_printing() {
    local state out
    state="$TEST_TMP/bracket-state"
    mkdir -p "$state" "$TEST_TMP/bracket-bin"
    mkstub_tbd "$TEST_TMP/bracket-bin"
    printf '[{"id":"w1"},{"id":"w2"}]\n' > "$state/worktrees.json"
    cat > "$state/terminals-w1.json" << 'EOF'
[
  {
    "id" : "a",
    "label" : "review [wip",
    "hibernatedAt" : "2026-09-04T12:00:01Z",
    "hibernateReason" : "recovery",
    "transport" : "holder"
  }
]
EOF
    cat > "$state/terminals-w2.json" << 'EOF'
[
  {
    "id" : "b",
    "label" : "plain",
    "hibernatedAt" : "2026-09-04T12:00:02Z",
    "hibernateReason" : "recovery",
    "transport" : "holder"
  }
]
EOF

    out="$(
        export FAKE_TBD_STATE="$state" PATH="$TEST_TMP/bracket-bin:$PATH"
        all_terminals_json | select_wake_candidates "" | tr '\n' ' '
    )"
    assert_eq "a bracket in a label drops no row, before or after it" "a b " "$out"
}

test_a_terminal_list_that_is_not_json_is_skipped_not_fatal() {
    local state out
    state="$TEST_TMP/badjson-state"
    mkdir -p "$state" "$TEST_TMP/badjson-bin"
    mkstub_tbd "$TEST_TMP/badjson-bin"
    printf '[{"id":"w1"},{"id":"w2"}]\n' > "$state/worktrees.json"
    printf 'not json\n' > "$state/terminals-w1.json"
    printf '[{"id":"b","hibernatedAt":"2026-09-04T12:00:02Z","hibernateReason":"recovery","transport":"holder"}]\n' \
        > "$state/terminals-w2.json"

    out="$(
        export FAKE_TBD_STATE="$state" PATH="$TEST_TMP/badjson-bin:$PATH"
        all_terminals_json 2>/dev/null | select_wake_candidates "" | tr '\n' ' '
    )"
    assert_eq "an unparseable worktree is skipped and the rest kept" "b " "$out"
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

# The rule itself — which installs are re-linked, and that a failure never
# fails the caller — is relink_installed_cli's, tested in
# scripts/restart-bundle-lib.test.sh. What is update.sh's own is the stage
# around it: that it passes CLI_INSTALL_PATH and the new CLI through, and that
# the outcome reaches the update log.
test_cli_refresh_only_touches_an_existing_install() {
    local new_cli target log_file
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
    log_file="$TEST_TMP/cli-refresh.log"
    printf 'old\n' > "$target"
    (
        CLI_INSTALL_PATH="$target"
        UPDATE_LOG="$log_file"
        OPT_AUTO=true
        refresh_installed_cli "$new_cli"
    )
    assert_eq "an existing CLI install is relinked to the new build" \
        "$(file_inode "$new_cli")" "$(file_inode "$target")"
    assert_contains_literal "the refresh is written to the update log" \
        "refreshed $target" "$(cat "$log_file" 2>/dev/null)"
}

# MARK: - Installing a published build

# A published build for <commit> under <case>/release: the archive, its
# checksum and a manifest, laid out as the release workflow publishes them.
# Echoes nothing; the stub curl serves files from that directory by name.
#
#   mkrelease <case_dir> <commit> [arch]
mkrelease() {
    local d="$1" commit="$2" arch="${3:-arm64}"
    local name="tbd-$commit-macos-arm64"
    local stage="$d/release-stage/$name"
    mkdir -p "$stage/TBD_TBDDaemonLib.bundle/Migrations" "$d/release"
    for product in "${RELEASE_PRODUCTS[@]}"; do
        printf '#!/bin/sh\necho %s\n' "$product" > "$stage/$product"
        chmod +x "$stage/$product"
    done
    printf 'select 1;\n' > "$stage/TBD_TBDDaemonLib.bundle/Migrations/0001.sql"
    python3 - "$stage" "$commit" "$arch" << 'EOF'
import hashlib, json, os, sys
stage, commit, arch = sys.argv[1:4]
files = {}
for root, _, names in os.walk(stage):
    for n in names:
        p = os.path.join(root, n)
        files[os.path.relpath(p, stage)] = hashlib.sha256(open(p, "rb").read()).hexdigest()
json.dump({"schema": 1, "commit": commit, "arch": arch,
           "builtAt": "2026-09-23T00:00:00Z",
           "runUrl": "https://example.invalid/runs/1", "files": files},
          open(os.path.join(stage, "manifest.json"), "w"))
EOF
    tar -czf "$d/release/$name.tar.gz" -C "$d/release-stage" "$name"
    printf '%s  %s\n' "$(shasum -a 256 "$d/release/$name.tar.gz" | awk '{print $1}')" \
        "$name.tar.gz" > "$d/release/$name.tar.gz.sha256"
}

# Stubs for the network and the machine: curl serves <case>/release by file
# name and 404s (exit 22) otherwise; gh answers `auth status` from
# FAKE_GH_AUTH and `attestation verify` from FAKE_GH_ATTEST; uname reports
# FAKE_ARCH.
mkstub_release_tools() {
    local bin="$1"
    cat > "$bin/curl" << 'EOF'
#!/bin/sh
out=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) shift; out="$1" ;;
        --connect-timeout|--max-time|--retry) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
printf 'curl %s\n' "$url" >> "${FAKE_CURL_LOG:-/dev/null}"
src="$FAKE_RELEASE_DIR/${url##*/}"
[ -f "$src" ] || exit 22
cp "$src" "$out"
EOF
    cat > "$bin/gh" << 'EOF'
#!/bin/sh
case "$1 $2" in
    "auth status") exit "${FAKE_GH_AUTH:-1}" ;;
    "attestation verify")
        printf 'gh %s\n' "$*" >> "${FAKE_GH_LOG:-/dev/null}"
        exit "${FAKE_GH_ATTEST:-1}"
        ;;
esac
exit 1
EOF
    cat > "$bin/uname" << 'EOF'
#!/bin/sh
[ "$1" = "-m" ] && { echo "${FAKE_ARCH:-arm64}"; exit 0; }
exec /usr/bin/uname "$@"
EOF
    chmod +x "$bin/curl" "$bin/gh" "$bin/uname"
}

# Run update.sh's main with the stages past the install stubbed out: the
# install, the handover, the app and the wake each have their own cases in
# this file, and a real handover would wait two minutes for a daemon the stub
# cannot start. What this drives is everything before it — source selection,
# download, verification, the link, the stamp — and the prune after it.
# INSTALLED_BUNDLE moves to a scratch path besides, so nothing here could
# reach a real /Applications/TBD.app even past the stubs. The stand-in bundle
# carries the build's identity, as an assembled one does.
# FAKE_INSTALL_FAILS=1 fails the stubbed install. FAKE_INSTALL_INTERRUPTED=1
# instead exits the whole run from inside it, as a signal during the staging
# copy does, leaving the exit trap to report it; FAKE_LINK_PUT_BACK_FAILS=1
# beside it fails every later point_release_link, so the trap cannot put
# the link back.
run_update_release() {
    local case_dir="$1"; shift
    env \
        HOME="$case_dir/home" \
        TBD_HOME="$case_dir/home/tbd" \
        FAKE_TBD_STATE="$case_dir/state" \
        FAKE_BUILD_LOG="$case_dir/build.log" \
        FAKE_OPEN_LOG="$case_dir/open.log" \
        FAKE_CURL_LOG="$case_dir/curl.log" \
        FAKE_GH_LOG="$case_dir/gh.log" \
        FAKE_RELEASE_DIR="$case_dir/release" \
        FAKE_INSTALLED_BUNDLE="$case_dir/Applications/TBD.app" \
        TBD_RELEASE_REPO="acme/tbd" \
        PATH="$case_dir/bin:$PATH" \
        bash -c '
            script="$1"; shift
            # shellcheck source=/dev/null
            source "$script"
            INSTALLED_BUNDLE="$FAKE_INSTALLED_BUNDLE"
            assemble_app_bundle() {
                mkdir -p "$2/TBD.app/Contents/MacOS"
                cp "$2/TBDBuildIdentity.json" "$2/TBD.app/Contents/" 2>/dev/null || true
            }
            sign_app_bundle() { :; }
            install_new_bundle() {
                printf "install-bundle %s\n" "$2"
                # What the keep would have kept (keep_installed_bundle): an
                # installed bundle of another build. The rollback record
                # goes by it.
                BUNDLE_STASHED=false
                if [ -d "$2" ] && ! same_build "$2" "$1"; then
                    BUNDLE_STASHED=true
                fi
                if [ "${FAKE_INSTALL_INTERRUPTED:-0}" = 1 ]; then
                    if [ "${FAKE_LINK_PUT_BACK_FAILS:-0}" = 1 ]; then
                        point_release_link() { return 1; }
                    fi
                    exit 143
                fi
                [ "${FAKE_INSTALL_FAILS:-0}" != 1 ]
            }
            hand_over_to_new_daemon() {
                printf "handover-daemon %s\n" "$2"
                [ "${FAKE_HANDOVER_FAILS:-0}" = 1 ] && return 1
                HANDOVER_STARTED=now
            }
            refresh_installed_cli() { :; }
            run_app_stage() { :; }
            run_wake_stage() { WAKE_CANDIDATES=0; WAKE_WOKEN=0; WAKE_FAILED=0; }
            set -uo pipefail
            main "$@"
        ' _ "$SCRIPT" "$@" 2>&1
}

# A release case: the fixture remote with a second commit on main, stubs for
# the release tools, and a daemon reporting the first commit.
mkcase_release() {
    local name="$1" d first
    d="$(mkcase "$name")"
    mkstub_release_tools "$d/bin"
    first="$(git -C "$d/remote" rev-parse HEAD)"
    echo "// second" >> "$d/remote/Sources/Seed.swift"
    git -C "$d/remote" commit -q -am "second"
    cat > "$d/state/status.json" << EOF
{
  "executablePath": "$d/worktree/.build/release/TBDDaemon",
  "buildIdentity": {"commit": "$first", "sourceWorktree": "$d/worktree"}
}
EOF
    printf '%s\n' "$d"
}

sidecar_field() {
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2"
}

test_update_source_resolution() {
    (
        UPDATE_SOURCE_FILE="$TEST_TMP/no-such-source"
        OPT_FROM_RELEASE=false
        unset TBD_UPDATE_SOURCE
        assert_eq "the shipped default is a local build" "build" "$(resolve_update_source)"
        assert_eq "the shipped default constant is build" "build" "$UPDATE_SOURCE_DEFAULT"
        printf 'release\n' > "$TEST_TMP/source-file"
        UPDATE_SOURCE_FILE="$TEST_TMP/source-file"
        assert_eq "the update-source file opts in" "release" "$(resolve_update_source)"
        TBD_UPDATE_SOURCE=build
        assert_eq "the environment beats the file" "build" "$(resolve_update_source)"
        OPT_FROM_RELEASE=true
        assert_eq "--from-release beats everything" "release" "$(resolve_update_source)"
        OPT_FROM_RELEASE=false
        TBD_UPDATE_SOURCE=nonsense
        assert_eq "an unknown source builds locally" "build" "$(resolve_update_source 2>/dev/null)"
    ) || FAIL=1
    (
        parse_args --from-release
        assert_eq "--from-release is recorded" "true" "$OPT_FROM_RELEASE"
    ) || FAIL=1
    assert_contains "--help documents --from-release" "--from-release" "$(bash "$SCRIPT" --help 2>&1)"
}

test_check_ref_follows_the_standing_source() {
    (
        UPDATE_HOME="$TEST_TMP/check-ref-home"
        CHECK_REF_FILE="$UPDATE_HOME/check-ref"
        UPDATE_SOURCE_FILE="$UPDATE_HOME/update-source"
        OPT_FROM_RELEASE=false
        unset TBD_UPDATE_SOURCE
        mkdir -p "$UPDATE_HOME"
        printf 'release\n' > "$UPDATE_SOURCE_FILE"
        sync_check_ref
        assert_eq "a standing release source points the check at the release tag" \
            "refs/tags/main-builds" "$(cat "$CHECK_REF_FILE" 2>/dev/null)"
        rm -f "$UPDATE_SOURCE_FILE"
        OPT_FROM_RELEASE=true
        sync_check_ref
        if [ -e "$CHECK_REF_FILE" ]; then
            fail "a one-off --from-release leaves the check on main"
        else
            pass "a one-off --from-release leaves the check on main"
        fi
    ) || FAIL=1
}

test_release_products_partition_the_runtime_products() {
    assert_eq "published plus locally built products are exactly the runtime products" \
        "$(printf '%s\n' "${RUNTIME_PRODUCTS[@]}" | sort | tr '\n' ' ')" \
        "$(printf '%s\n' "${RELEASE_PRODUCTS[@]}" "${RELEASE_LOCAL_PRODUCTS[@]}" | sort | tr '\n' ' ')"
}

test_release_dry_run_leaves_the_running_link() {
    local case_dir out head previous
    case_dir="$(mkcase_release release-dry-run)"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkrelease "$case_dir" "$head"
    previous="$case_dir/home/tbd/updates/prebuilt/1111111111111111111111111111111111111111"
    # A first run creates the clone; plant the running build's link, then dry-run.
    FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 run_update_release "$case_dir" --from-release --dry-run >/dev/null
    mkdir -p "$previous"
    ln -sfn "$previous" "$case_dir/home/tbd/updates/src/.build/release"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 run_update_release "$case_dir" --from-release --dry-run)"
    assert_eq "a release dry run exits zero" "0" "$?"
    assert_contains "it says it installs nothing" "installing nothing" "$out"
    assert_eq "a release dry run leaves .build/release on the running build" "$previous" \
        "$(link_target "$case_dir/home/tbd/updates/src/.build/release")"
    assert_not_contains "a release dry run hands nothing over" "handover-daemon" "$out"
}

test_release_repo_slug_parses_github_remotes() {
    (
        unset TBD_RELEASE_REPO
        assert_eq "an https remote" "acme/tbd" "$(release_repo_slug https://github.com/acme/tbd.git)"
        assert_eq "an ssh remote" "acme/tbd" "$(release_repo_slug git@github.com:acme/tbd.git)"
        assert_fail "a non-GitHub remote has no releases" release_repo_slug /tmp/some/repo
    ) || FAIL=1
}

test_release_install_verified() {
    local case_dir out head tree sidecar
    case_dir="$(mkcase_release release-verified)"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkrelease "$case_dir" "$head"
    # An older prebuilt tree that the prune must remove.
    mkdir -p "$case_dir/home/tbd/updates/prebuilt/0000000000000000000000000000000000000000"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 run_update_release "$case_dir" --from-release)"
    assert_eq "a verified release install exits zero" "0" "$?"
    tree="$case_dir/home/tbd/updates/prebuilt/$head"
    assert_contains "the provenance is verified" "build provenance verified" "$out"
    assert_contains "every file is checked against the manifest" "every file matches the manifest" "$out"
    assert_not_contains "a verified download compiles no daemon" "building TBDDaemon" "$out"
    assert_eq "a verified download builds only the app" "built TBDApp release" \
        "$(cat "$case_dir/build.log" 2>/dev/null)"
    if [ -x "$tree/TBDApp" ] && [ -f "$tree/TBD_TBDApp.bundle/markdown-default.css" ]; then
        pass "the locally built app and its resources join the downloaded tree"
    else
        fail "the locally built app and its resources join the downloaded tree"
    fi
    assert_eq "the sidecar names what was built here" "['TBDApp']" \
        "$(sidecar_field "$tree/TBDBuildIdentity.json" locallyBuiltProducts)"
    assert_eq "the clone's .build/release points at the prebuilt tree" "$tree" \
        "$(link_target "$case_dir/home/tbd/updates/src/.build/release")"
    assert_contains "the handover starts the daemon through the link" \
        "handover-daemon $case_dir/home/tbd/updates/src/.build/release/TBDDaemon" "$out"
    assert_eq "the clone is left at the installed commit" "$head" \
        "$(git -C "$case_dir/home/tbd/updates/src" rev-parse HEAD)"
    sidecar="$tree/TBDBuildIdentity.json"
    assert_eq "the sidecar names the installed commit" "$head" "$(sidecar_field "$sidecar" commit)"
    assert_eq "the sidecar names the update clone" "$case_dir/home/tbd/updates/src" \
        "$(sidecar_field "$sidecar" sourceWorktree)"
    assert_eq "the sidecar records the release provenance" "release" \
        "$(sidecar_field "$sidecar" provenance)"
    assert_eq "the sidecar carries CI's build time" "2026-09-23T00:00:00Z" \
        "$(sidecar_field "$sidecar" builtAt)"
    if [ -d "$case_dir/home/tbd/updates/prebuilt/0000000000000000000000000000000000000000" ]; then
        fail "a completed install prunes older prebuilt trees"
    else
        pass "a completed install prunes older prebuilt trees"
    fi
    assert_eq "no partial download is left behind" "" \
        "$(find "$case_dir/home/tbd/updates/prebuilt" -maxdepth 1 -name '*.partial')"
}

test_release_walks_back_to_the_newest_published_commit() {
    local case_dir out head parent
    case_dir="$(mkcase_release release-walkback)"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    parent="$(git -C "$case_dir/remote" rev-parse HEAD~1)"
    # Only the first commit is published, and it is the one running.
    mkrelease "$case_dir" "$parent"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 run_update_release "$case_dir" --from-release)"
    assert_eq "a run already at the newest published build exits zero" "0" "$?"
    assert_contains "it finds the older published commit" "newest published build is $parent" "$out"
    assert_contains "it installs nothing when that is what is running" "nothing to install" "$out"
    assert_not_contains "and builds nothing" "building TBDDaemon" "$out"
}

test_release_attestation_missing_in_auto_mode_refuses() {
    local case_dir out head
    case_dir="$(mkcase_release release-auto-no-gh)"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkrelease "$case_dir" "$head"
    out="$(FAKE_GH_AUTH=1 run_update_release "$case_dir" --auto --from-release;
        printf 'rc=%s\n' "$?")"
    out="$out$(cat "$case_dir/home/tbd/updates/update.log" 2>/dev/null)"
    assert_contains "an unattended install without provenance fails" "rc=1" "$out"
    assert_contains "it says why" "requires a verified build provenance" "$out"
    assert_not_contains "it does not build in its place" "building TBDDaemon" "$out"
    if [ -e "$case_dir/home/tbd/updates/src/.build/release" ]; then
        fail "an unverified download is never linked into place"
    else
        pass "an unverified download is never linked into place"
    fi

    # gh signed in, but no attestation for this archive: refused the same way.
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=1 run_update_release "$case_dir" --auto --from-release;
        printf 'rc=%s\n' "$?")"
    out="$out$(cat "$case_dir/home/tbd/updates/update.log" 2>/dev/null)"
    assert_contains "an attestation that does not verify fails the run" "rc=1" "$out"
    assert_contains "and names the provenance" "build provenance did not verify" "$out"
}

test_release_attestation_missing_in_manual_mode() {
    local case_dir out head
    case_dir="$(mkcase_release release-manual-no-gh)"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkrelease "$case_dir" "$head"
    out="$(FAKE_GH_AUTH=1 run_update_release "$case_dir" --from-release)"
    assert_eq "a manual install without gh proceeds on the checksum" "0" "$?"
    assert_contains "and warns that provenance went unchecked" \
        "build provenance was not checked" "$out"
    assert_eq "the download is linked into place" \
        "$case_dir/home/tbd/updates/prebuilt/$head" \
        "$(link_target "$case_dir/home/tbd/updates/src/.build/release")"

    case_dir="$(mkcase_release release-manual-bad-attest)"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkrelease "$case_dir" "$head"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=1 run_update_release "$case_dir" --from-release;
        printf 'rc=%s\n' "$?")"
    assert_contains "a manual install whose attestation fails is refused" "rc=1" "$out"
    assert_not_contains "and does not fall back to a build" "building TBDDaemon" "$out"
}

test_release_checksum_mismatch_aborts() {
    local case_dir out head name
    case_dir="$(mkcase_release release-bad-checksum)"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkrelease "$case_dir" "$head"
    name="tbd-$head-macos-arm64.tar.gz"
    printf '%064d  %s\n' 0 "$name" > "$case_dir/release/$name.sha256"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 run_update_release "$case_dir" --from-release;
        printf 'rc=%s\n' "$?")"
    assert_contains "a checksum mismatch fails the run" "rc=1" "$out"
    assert_contains "and says so" "checksum mismatch" "$out"
    assert_not_contains "a manual run does not build in its place" "building TBDDaemon" "$out"
    if [ -d "$case_dir/home/tbd/updates/prebuilt/$head" ]; then
        fail "a mismatched download is not unpacked into place"
    else
        pass "a mismatched download is not unpacked into place"
    fi
}

test_release_manifest_mismatch_aborts() {
    local case_dir out head
    case_dir="$(mkcase_release release-bad-manifest)"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    # A well-formed archive whose manifest names another commit.
    mkrelease "$case_dir" "$head"
    rm -rf "$case_dir/release-stage"
    mkdir -p "$case_dir/release-other"
    (
        d="$case_dir/release-other"
        mkrelease "$d" "$(git -C "$case_dir/remote" rev-parse HEAD~1)"
        mkdir -p "$d/x" && tar -xzf "$d/release/"*.tar.gz -C "$d/x"
        mv "$d/x/"* "$d/x/tbd-$head-macos-arm64"
        tar -czf "$case_dir/release/tbd-$head-macos-arm64.tar.gz" -C "$d/x" "tbd-$head-macos-arm64"
        printf '%s  x\n' "$(shasum -a 256 "$case_dir/release/tbd-$head-macos-arm64.tar.gz" | awk '{print $1}')" \
            > "$case_dir/release/tbd-$head-macos-arm64.tar.gz.sha256"
    )
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 run_update_release "$case_dir" --from-release;
        printf 'rc=%s\n' "$?")"
    assert_contains "a manifest naming another commit fails the run" "rc=1" "$out"
    assert_contains "and says what did not match" "does not match its manifest" "$out"
}

test_release_no_asset_auto_skips() {
    local case_dir out
    case_dir="$(mkcase_release release-none-auto)"
    mkdir -p "$case_dir/release"
    out="$(run_update_release "$case_dir" --auto --from-release; printf 'rc=%s\n' "$?")"
    out="$out$(cat "$case_dir/home/tbd/updates/update.log" 2>/dev/null)"
    assert_contains "an unattended run with nothing published exits zero" "rc=0" "$out"
    assert_contains "and says it skipped" "skipping this unattended update" "$out"
    if [ -f "$case_dir/build.log" ]; then
        fail "an unattended run with nothing published builds nothing"
    else
        pass "an unattended run with nothing published builds nothing"
    fi
}

test_release_no_asset_manual_builds_locally() {
    local case_dir out
    case_dir="$(mkcase_release release-none-manual)"
    mkdir -p "$case_dir/release"
    out="$(run_update_release "$case_dir" --from-release --dry-run)"
    assert_eq "a manual run with nothing published still succeeds" "0" "$?"
    assert_contains "it says it falls back" "building locally instead" "$out"
    assert_contains "and builds" "building TBDDaemon" "$out"
    assert_eq "every product is built" "5" "$(grep -c 'release' "$case_dir/build.log" 2>/dev/null)"
}

test_release_non_arm64_builds_locally() {
    local case_dir out head
    case_dir="$(mkcase_release release-intel)"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkrelease "$case_dir" "$head"
    out="$(FAKE_ARCH=x86_64 run_update_release "$case_dir" --auto --from-release --dry-run;
        printf 'rc=%s\n' "$?")"
    out="$out$(cat "$case_dir/home/tbd/updates/update.log" 2>/dev/null)"
    assert_contains "an Intel machine is told why" "this machine is x86_64" "$out"
    assert_contains "and builds locally, even unattended" "building TBDDaemon" "$out"
    assert_contains "and succeeds" "rc=0" "$out"
    if [ -f "$case_dir/curl.log" ]; then
        fail "an Intel machine downloads nothing"
    else
        pass "an Intel machine downloads nothing"
    fi
}

test_release_failed_handover_restores_the_link() {
    local case_dir out previous
    case_dir="$(mkcase_release_live release-handover-fails)"
    previous="$case_dir/home/tbd/updates/prebuilt/1111111111111111111111111111111111111111"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 FAKE_HANDOVER_FAILS=1 \
        run_update_release "$case_dir" --from-release; printf 'rc=%s\n' "$?")"
    assert_contains "the run reaches the handover" "handover-daemon" "$out"
    assert_contains "a failed handover fails the run" "rc=1" "$out"
    assert_eq "a failed handover points the link back at the running build" "$previous" \
        "$(link_target "$case_dir/home/tbd/updates/src/.build/release")"
    if [ -d "$previous" ]; then
        pass "a failed handover keeps the live tree"
    else
        fail "a failed handover keeps the live tree"
    fi
    assert_eq "a failed handover leaves no new tree" "1111111111111111111111111111111111111111" \
        "$(prebuilt_entries "$case_dir")"
}

# A failed install puts the link back as a failed handover does, so that a
# reboot respawns the build that is still running, and never reaches the
# handover. (FAKE_INSTALL_FAILS=1 fails the stubbed install_new_bundle.)
test_release_failed_install_restores_the_link() {
    local case_dir out previous
    case_dir="$(mkcase_release_live release-install-fails)"
    previous="$case_dir/home/tbd/updates/prebuilt/1111111111111111111111111111111111111111"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 FAKE_INSTALL_FAILS=1 \
        run_update_release "$case_dir" --from-release; printf 'rc=%s\n' "$?")"
    assert_contains "the run reaches the install" "install-bundle" "$out"
    assert_not_contains "a failed install never reaches the handover" "handover-daemon" "$out"
    assert_contains "a failed install fails the run" "rc=1" "$out"
    assert_eq "a failed install points the link back at the running build" "$previous" \
        "$(link_target "$case_dir/home/tbd/updates/src/.build/release")"
    assert_eq "a failed install leaves no new tree" "1111111111111111111111111111111111111111" \
        "$(prebuilt_entries "$case_dir")"
}

# A release case (mkcase_release_live) whose installed bundle and live tree
# both name the running build, the case's first commit, as an installation
# that a completed update left. Echoes the case directory.
mkcase_release_installed() {
    local case_dir running
    case_dir="$(mkcase_release_live "$1")"
    running="$(git -C "$case_dir/remote" rev-parse HEAD~1)"
    printf '{"commit": "%s"}\n' "$running" \
        > "$case_dir/home/tbd/updates/prebuilt/1111111111111111111111111111111111111111/TBDBuildIdentity.json"
    mkdir -p "$case_dir/Applications"
    mkbundle "$case_dir/Applications/TBD.app" "before-the-update" "$running" >/dev/null
    printf '%s\n' "$case_dir"
}

# THE REGRESSION: main points .build/release at the download before the
# install begins, and a run interrupted while the install was still staging
# left it there, while the report said nothing needed recovering. The app
# that kept running starts its next daemon from that link, so that daemon
# was the new build behind the old app. The exit trap now puts the link back
# as a failed install does, and the report reads where everything stands:
# the installed bundle, the daemon and the link all on the running build is
# the one state that needs no recovering. When the put-back fails, the link
# names the new build, and the same report gives the recovery steps.
test_release_interrupted_staging_puts_the_link_back() {
    local case_dir out previous link installed running head
    case_dir="$(mkcase_release_installed release-install-interrupted)"
    previous="$case_dir/home/tbd/updates/prebuilt/1111111111111111111111111111111111111111"
    link="$case_dir/home/tbd/updates/src/.build/release"
    installed="$case_dir/Applications/TBD.app"
    running="$(git -C "$case_dir/remote" rev-parse HEAD~1)"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 FAKE_INSTALL_INTERRUPTED=1 \
        run_update_release "$case_dir" --from-release; printf 'rc=%s\n' "$?")"
    assert_contains "the run reaches the install" "install-bundle" "$out"
    assert_not_contains "an interrupted run fails" "rc=0" "$out"
    assert_not_contains "it never reaches the handover" "handover-daemon" "$out"
    assert_eq "the exit points the link back at the running build" "$previous" "$(link_target "$link")"
    assert_contains_literal "and says so" "pointed $link back at $previous" "$out"
    assert_contains "it is reported as an interruption" \
        "ERROR: the run was interrupted while installing" "$out"
    assert_contains_literal "the report names the installed build" \
        "installed bundle at $installed: build $running" "$out"
    assert_contains_literal "the daemon's" "daemon: build $running" "$out"
    assert_contains_literal "and the link's" \
        "build directory $link, a link to $previous: build $running" "$out"
    assert_contains_literal "all three match, so nothing needs recovering" \
        "the installed app and the daemon are the same build, so nothing needs recovering" "$out"
    assert_not_contains "and there are no recovery steps" "to recover:" "$out"
    assert_eq "the exit leaves no new tree" "1111111111111111111111111111111111111111" \
        "$(prebuilt_entries "$case_dir")"

    case_dir="$(mkcase_release_installed release-install-interrupted-link-stuck)"
    previous="$case_dir/home/tbd/updates/prebuilt/1111111111111111111111111111111111111111"
    link="$case_dir/home/tbd/updates/src/.build/release"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 FAKE_INSTALL_INTERRUPTED=1 FAKE_LINK_PUT_BACK_FAILS=1 \
        run_update_release "$case_dir" --from-release; printf 'rc=%s\n' "$?")"
    assert_not_contains "an interrupted run fails (link stuck)" "rc=0" "$out"
    if [ "$(link_target "$link")" != "$previous" ]; then
        pass "a put-back that fails leaves the link on the new build"
    else
        fail "a put-back that fails leaves the link on the new build"
    fi
    assert_contains "the failed put-back is logged" "ERROR: could not point .* back at" "$out"
    assert_contains_literal "the report names the build the link holds (link stuck)" \
        "build directory $link, a link to $case_dir/home/tbd/updates/prebuilt/$head: build $head" "$out"
    assert_not_contains "it does not say nothing needs recovering (link stuck)" \
        "nothing needs recovering" "$out"
    assert_contains "it gives the recovery steps (link stuck)" "to recover:" "$out"
}

# A run whose installed bundle already is the build it installs — what a run
# cut short after its swap leaves — keeps no bundle (keep_installed_bundle),
# and the tree live at the start (1111…) is not the build of any bundle at
# ~/tbd/updates/previous/TBD.app, so the rollback record stays as it was
# (here 2222…). Recording the tree live at the start, as a completed install
# otherwise does, fails, and the reconcile then deletes 2222….
test_release_over_its_own_build_keeps_the_rollback_record() {
    local case_dir home head installed out
    case_dir="$(mkcase_release_live release-over-own-build)"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    home="$case_dir/home/tbd/updates/prebuilt"
    installed="$case_dir/Applications/TBD.app"
    mkdir -p "$home/2222222222222222222222222222222222222222" "$case_dir/Applications"
    printf '%s\n' "$home/2222222222222222222222222222222222222222" > "$home/.previous"
    mkbundle "$installed" "left-by-the-cut-short-run" >/dev/null
    stamp_clone_identity "$installed" "$case_dir" "$head"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 run_update_release "$case_dir" --from-release; printf 'rc=%s\n' "$?")"
    assert_contains "the run succeeds" "rc=0" "$out"
    assert_contains_literal "it reaches the install" "install-bundle $installed" "$out"
    assert_contains "and the handover" "handover-daemon" "$out"
    assert_eq "the rollback record still names the earlier tree" \
        "$home/2222222222222222222222222222222222222222" "$(cat "$home/.previous" 2>/dev/null)"
    if [ -d "$home/2222222222222222222222222222222222222222" ]; then
        pass "and the earlier tree is kept"
    else
        fail "and the earlier tree is kept"
    fi
}

# The same run, where a prebuilt tree of the kept bundle's build is still
# here: the tree live at the start (1111…), as a failed handover whose bundle
# could not be put back leaves it, with the link put back and the kept
# bundle that tree's build. The record names that tree, and the reconcile
# keeps it. Leaving the record on 2222…, which pairs with nothing kept,
# fails.
test_release_over_its_own_build_records_the_kept_bundles_tree() {
    local case_dir home head live kept out
    case_dir="$(mkcase_release_live release-over-own-build-kept-tree)"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    home="$case_dir/home/tbd/updates/prebuilt"
    live="$home/1111111111111111111111111111111111111111"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    mkdir -p "$home/2222222222222222222222222222222222222222" "$case_dir/Applications"
    printf '%s\n' "$home/2222222222222222222222222222222222222222" > "$home/.previous"
    mkbundle "$case_dir/Applications/TBD.app" "left-by-the-cut-short-run" >/dev/null
    stamp_clone_identity "$case_dir/Applications/TBD.app" "$case_dir" "$head"
    mkbundle "$kept" "the-live-trees-build" >/dev/null
    stamp_clone_identity "$kept" "$case_dir" 1111111111111111111111111111111111111111
    cp "$kept/Contents/TBDBuildIdentity.json" "$live/TBDBuildIdentity.json"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 run_update_release "$case_dir" --from-release; printf 'rc=%s\n' "$?")"
    assert_contains "the run succeeds" "rc=0" "$out"
    assert_contains_literal "it reaches the install" "install-bundle $case_dir/Applications/TBD.app" "$out"
    assert_contains "and the handover" "handover-daemon" "$out"
    assert_eq "the rollback record names the tree of the kept bundle's build" \
        "$live" "$(cat "$home/.previous" 2>/dev/null)"
    if [ -d "$live" ]; then
        pass "and that tree is kept"
    else
        fail "and that tree is kept"
    fi
}

# An install interrupted between its two renames left the bundle that was
# installed, this run's own build, at the outgoing name with nothing
# installed. The run's install puts it back first, and the keep then finds
# this run's build installed and keeps nothing, so the bundle at
# ~/tbd/updates/previous/TBD.app (2222…) is an earlier update's and the
# record stays on its tree. Deciding the record from what was installed
# before the install began, as the run did, finds nothing installed and
# records the tree live at the start (1111…), which pairs with no kept
# bundle, and the reconcile then deletes 2222….
test_an_install_that_puts_back_its_own_build_keeps_the_rollback_record() {
    local case_dir home link live recorded installed kept new_commit out rc
    case_dir="$(mkcase put-back-own-build-record)"
    home="$case_dir/home/tbd/updates/prebuilt"
    link="$case_dir/home/tbd/updates/src/.build/release"
    live="$home/1111111111111111111111111111111111111111"
    recorded="$home/2222222222222222222222222222222222222222"
    installed="$case_dir/Applications/TBD.app"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    new_commit="$(git -C "$case_dir/remote" rev-parse HEAD)"
    # A first run makes the clone; a dry run installs nothing.
    run_update "$case_dir" --dry-run >/dev/null
    mkdir -p "$live" "$recorded" "$case_dir/Applications"
    rm -f "$link"
    ln -s "$live" "$link"
    printf '%s\n' "$recorded" > "$home/.previous"
    mkbundle "$kept" "earlier-update" >/dev/null
    stamp_clone_identity "$kept" "$case_dir" 2222222222222222222222222222222222222222
    cp "$kept/Contents/TBDBuildIdentity.json" "$recorded/TBDBuildIdentity.json"
    mkbundle "$case_dir/Applications/.TBD-install-outgoing" "left-by-the-interrupted-swap" >/dev/null
    stamp_clone_identity "$case_dir/Applications/.TBD-install-outgoing" "$case_dir" "$new_commit"
    out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "the update succeeds" "0" "$rc"
    assert_contains_literal "the install puts the outgoing bundle back first" \
        "put back $installed from $case_dir/Applications/.TBD-install-outgoing" "$out"
    assert_contains "and the keep then keeps nothing" "keeping no copy of it" "$out"
    assert_eq "the earlier update's kept bundle stays" "earlier-update" \
        "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "the rollback record stays on that bundle's tree" "$recorded" \
        "$(cat "$home/.previous" 2>/dev/null)"
    assert_eq "and the reconcile keeps that tree" "present" "$(path_state "$recorded")"
}

# The trees under <case>/home/tbd/updates/prebuilt, by name, space-separated
# and sorted. Dotfiles (the rollback record) are not trees.
prebuilt_entries() {
    local dir="$1/home/tbd/updates/prebuilt"
    [ -d "$dir" ] || return 0
    find "$dir" -mindepth 1 -maxdepth 1 ! -name '.*' -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//'
}

# A release case whose clone exists and whose .build/release points at a
# planted live tree 1111…. Echoes the case directory.
mkcase_release_live() {
    local case_dir head live
    case_dir="$(mkcase_release "$1")"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkrelease "$case_dir" "$head"
    # A first run creates the clone; a dry run installs nothing.
    FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 run_update_release "$case_dir" --from-release --dry-run >/dev/null
    live="$case_dir/home/tbd/updates/prebuilt/1111111111111111111111111111111111111111"
    mkdir -p "$live"
    ln -sfn "$live" "$case_dir/home/tbd/updates/src/.build/release"
    printf '%s\n' "$case_dir"
}

test_release_dry_run_keeps_nothing_it_downloaded() {
    local case_dir out
    case_dir="$(mkcase_release release-dry-run-prune)"
    mkrelease "$case_dir" "$(git -C "$case_dir/remote" rev-parse HEAD)"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 run_update_release "$case_dir" --from-release --dry-run)"
    assert_contains "a first release dry run downloads" "installing nothing" "$out"
    assert_eq "a release dry run with nothing live leaves no tree" "" "$(prebuilt_entries "$case_dir")"

    case_dir="$(mkcase_release_live release-dry-run-prune-live)"
    FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 run_update_release "$case_dir" --from-release --dry-run >/dev/null
    assert_eq "a release dry run leaves no new tree beside the live one" \
        "1111111111111111111111111111111111111111" "$(prebuilt_entries "$case_dir")"
}

test_release_failed_app_build_leaves_no_new_tree() {
    local case_dir out
    case_dir="$(mkcase_release_live release-app-build-fails)"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 FAKE_BUILD_FAILS_PRODUCT=TBDApp \
        run_update_release "$case_dir" --from-release; printf 'rc=%s\n' "$?")"
    assert_contains "a failed app build fails the run" "rc=1" "$out"
    assert_eq "a failed app build leaves no new tree" \
        "1111111111111111111111111111111111111111" "$(prebuilt_entries "$case_dir")"
    assert_eq "a failed app build leaves the link on the live tree" \
        "$case_dir/home/tbd/updates/prebuilt/1111111111111111111111111111111111111111" \
        "$(link_target "$case_dir/home/tbd/updates/src/.build/release")"
}

test_release_failed_link_restores_the_running_link() {
    local case_dir out live real_python
    case_dir="$(mkcase_release_live release-link-fails)"
    live="$case_dir/home/tbd/updates/prebuilt/1111111111111111111111111111111111111111"
    # point_release_link swaps the link with a python3 os.replace. A python3
    # that refuses that swap for any target but the live tree makes pointing
    # the link at the download fail, and pointing it back succeed.
    real_python="$(command -v python3)"
    cat > "$case_dir/bin/python3" << EOF
#!/bin/sh
case "\$2" in
    *os.replace*)
        [ "\$(readlink "\$3")" = "$live" ] || exit 1
        ;;
esac
exec "$real_python" "\$@"
EOF
    chmod +x "$case_dir/bin/python3"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 \
        run_update_release "$case_dir" --from-release; printf 'rc=%s\n' "$?")"
    rm -f "$case_dir/bin/python3"
    assert_contains "a failed link fails the run" "rc=1" "$out"
    assert_not_contains "a failed link hands nothing over" "handover-daemon" "$out"
    assert_eq "a failed link points .build/release back at the running build" "$live" \
        "$(link_target "$case_dir/home/tbd/updates/src/.build/release")"
    assert_eq "a failed link leaves no new tree" \
        "1111111111111111111111111111111111111111" "$(prebuilt_entries "$case_dir")"
}

test_release_failed_runs_never_grow_the_prebuilt_home() {
    local case_dir home i ok=true
    case_dir="$(mkcase_release_live release-failed-runs)"
    home="$case_dir/home/tbd/updates/prebuilt"
    # A rollback tree on record, and a stray older tree nothing names.
    mkdir -p "$home/2222222222222222222222222222222222222222" \
        "$home/0000000000000000000000000000000000000000" "$home/download.partial"
    printf '%s\n' "$home/2222222222222222222222222222222222222222" > "$home/.previous"
    for i in 1 2 3 4; do
        case "$i" in
            1|3) FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 FAKE_HANDOVER_FAILS=1 \
                    run_update_release "$case_dir" --from-release >/dev/null ;;
            2) FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 FAKE_BUILD_FAILS_PRODUCT=TBDApp \
                    run_update_release "$case_dir" --from-release >/dev/null ;;
            4) FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 \
                    run_update_release "$case_dir" --from-release --dry-run >/dev/null ;;
        esac
        if [ "$(prebuilt_entries "$case_dir")" != \
            "1111111111111111111111111111111111111111 2222222222222222222222222222222222222222" ]; then
            ok=false
        fi
    done
    if [ "$ok" = true ]; then
        pass "successive failed runs keep exactly the live tree and one rollback"
    else
        fail "successive failed runs keep exactly the live tree and one rollback (got: $(prebuilt_entries "$case_dir"))"
    fi
}

# A completed install that kept the bundle it replaced records the tree
# that was live when it started as the rollback, paired with that bundle.
test_release_completed_install_keeps_the_replaced_tree_as_rollback() {
    local case_dir head home out
    case_dir="$(mkcase_release_live release-rollback)"
    head="$(git -C "$case_dir/remote" rev-parse HEAD)"
    home="$case_dir/home/tbd/updates/prebuilt"
    mkdir -p "$home/2222222222222222222222222222222222222222" "$case_dir/Applications"
    printf '%s\n' "$home/2222222222222222222222222222222222222222" > "$home/.previous"
    mkbundle "$case_dir/Applications/TBD.app" "before-the-update" \
        1111111111111111111111111111111111111111 >/dev/null
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 run_update_release "$case_dir" --from-release; printf 'rc=%s\n' "$?")"
    assert_contains "the run succeeds" "rc=0" "$out"
    assert_contains_literal "it reaches the install" "install-bundle $case_dir/Applications/TBD.app" "$out"
    assert_contains "and the handover" "handover-daemon" "$out"
    assert_eq "a completed install keeps the new tree and the one it replaced" \
        "$(printf '%s\n' 1111111111111111111111111111111111111111 "$head" | sort | tr '\n' ' ' | sed 's/ $//')" \
        "$(prebuilt_entries "$case_dir")"
    assert_eq "the replaced tree is recorded as the rollback" \
        "$home/1111111111111111111111111111111111111111" "$(cat "$home/.previous" 2>/dev/null)"
}

# A local build hands .build/release to SwiftPM; every way the run can end
# short of a completed install must put it back on the downloaded tree that
# is running, or a reboot respawns a partial or missing TBDDaemon.
test_local_build_short_of_an_install_restores_the_downloaded_link() {
    local case_dir out live how
    for how in compile handover dry-run sign; do
        case_dir="$(mkcase_release_live "local-restore-$how")"
        live="$case_dir/home/tbd/updates/prebuilt/1111111111111111111111111111111111111111"
        case "$how" in
            compile) out="$(FAKE_BUILD_FAILS_PRODUCT=TBDDaemon \
                    run_update_release "$case_dir"; printf 'rc=%s\n' "$?")" ;;
            handover) out="$(FAKE_HANDOVER_FAILS=1 \
                    run_update_release "$case_dir"; printf 'rc=%s\n' "$?")" ;;
            dry-run) out="$(run_update_release "$case_dir" --dry-run; printf 'rc=%s\n' "$?")" ;;
            sign)
                printf '#!/bin/sh\nexit 1\n' > "$case_dir/bin/codesign"
                out="$(run_update_release "$case_dir"; printf 'rc=%s\n' "$?")"
                ;;
        esac
        assert_contains "a local build is what ran ($how)" "building TBDDaemon" "$out"
        if [ "$how" = dry-run ]; then
            assert_contains "a local dry run succeeds" "rc=0" "$out"
        else
            assert_contains "a local build that fails at $how fails the run" "rc=1" "$out"
        fi
        assert_eq "a local build that stops at $how points the link back at the running download" \
            "$live" "$(link_target "$case_dir/home/tbd/updates/src/.build/release")"
    done
}

test_release_failed_signing_restores_the_link() {
    local case_dir out live
    case_dir="$(mkcase_release_live release-sign-fails)"
    live="$case_dir/home/tbd/updates/prebuilt/1111111111111111111111111111111111111111"
    printf '#!/bin/sh\nexit 1\n' > "$case_dir/bin/codesign"
    out="$(FAKE_GH_AUTH=0 FAKE_GH_ATTEST=0 \
        run_update_release "$case_dir" --from-release; printf 'rc=%s\n' "$?")"
    assert_contains "a failed signing fails the run" "rc=1" "$out"
    assert_not_contains "a failed signing hands nothing over" "handover-daemon" "$out"
    assert_eq "a failed signing points the link back at the running build" "$live" \
        "$(link_target "$case_dir/home/tbd/updates/src/.build/release")"
}

test_local_build_takes_the_link_back_from_a_download() {
    local link home
    home="$TEST_TMP/yield/prebuilt"
    link="$TEST_TMP/yield/src/.build/release"
    mkdir -p "$home/abc" "$(dirname "$link")"
    ln -s "$home/abc" "$link"
    release_link_yield_to_swiftpm "$link" "$home"
    if [ -e "$link" ] || [ -L "$link" ]; then
        fail "a link into the prebuilt home is removed before a local build"
    else
        pass "a link into the prebuilt home is removed before a local build"
    fi
    mkdir -p "$TEST_TMP/yield/src/.build/arm64-apple-macosx/release"
    ln -s "arm64-apple-macosx/release" "$link"
    release_link_yield_to_swiftpm "$link" "$home"
    assert_eq "SwiftPM's own link is left alone" "arm64-apple-macosx/release" "$(link_target "$link")"
    rm -f "$link"
    mkdir -p "$link"
    assert_fail "a real build directory is never replaced by a link" \
        point_release_link "$link" "$home/abc"
}

# MARK: - The app around the handover

# Run update.sh's main, building locally from the fixture remote, through the
# app stages. The install and the handover are stubbed as in
# run_update_release, and record themselves ("install", "handover") into the
# same events file the open, pkill and pgrep stubs write, so the order of the
# install, the stop, the handover and the launch reads off one file.
# INSTALLED_BUNDLE moves to a scratch path too, so the anchored pattern could
# not name a real app even past the stubs.
#
#   run_update_around_handover <case_dir> [args...]
#
# Every run starts with the app running (<case>/app exists, per
# FAKE_APP_STATE in mkstub_tbd) and an empty events file;
# FAKE_APP_NOT_RUNNING=1 starts it with no app running instead, as an
# earlier run that stopped the app and was killed leaves it.
# FAKE_HANDOVER_FAILS=1 fails the handover, with the rollback of the bundle
# taken as done. FAKE_RESTORE_FAILS=1 beside it runs that rollback for real
# (roll_back_bundle) with no bundle kept by this run, as on a first update, so
# it fails and records that as hand_over_to_new_daemon's failure path does.
# FAKE_REAL_INSTALL=1 instead runs the real install_new_bundle and
# hand_over_to_new_daemon — keeping the installed bundle, installing the new
# one, rolling back — with only the handover itself faked: it records
# "bundle-at-handover" and the installed bundle's SourceWorktreePath.txt, then
# "handover", and fails under FAKE_HANDOVER_FAILS=1. FAKE_KEPT_BUNDLE_VANISHES=1
# deletes the kept bundle from inside the handover, so the rollback after it
# finds nothing to put back. Every bundle copy goes
# through the bundle-cp stub (mkstub_tbd), which records what the installed
# path holds while it copies, and FAKE_COPY_FAILS=1 fails the copy of a new
# bundle into place. (Through the library's TBD_BUNDLE_CP seam, set as
# install_new_bundle begins: main sources restart-bundle-lib.sh as it starts,
# which sets the seam back to /bin/cp and would replace a stub of a library
# function.) FAKE_EXITS_AFTER_KEEP=1 exits the whole run once the installed
# bundle has been kept, before anything has moved. FAKE_EXITS_AFTER_INSTALL=1
# exits the whole run with status 6 once the install has completed, before
# the app is stopped or anything is handed over. FAKE_LINK_PUT_BACK_FAILS=1
# fails main's put-back of the .build/release link after a failed install or
# handover (restore_release_link, replaced as the install begins, since main
# sources its library as it starts). The case must create <case>/Applications
# for the install to land in.
# FAKE_HANDOVER_EXITS=1 exits the whole run from inside the handover, the way
# a step that calls `exit` or a signal does, so that only the exit trap is
# left to decide about the app; with the stubbed install as well as the real
# one.
# FAKE_STAMP_STOP=1 records "app-stop-returned at <epoch seconds>" once the
# stop before the handover has returned.
# FAKE_EXITS_DURING_STOP=1 exits the whole run with status 7 once the stop
# before the handover has signalled the app and returned, before it records
# that it stopped one: what an exit during the stop's grace wait leaves.
# FAKE_EXITS_BEFORE_APP_STAGE=1 exits the run the same way after the handover
# has completed, from the CLI refresh that runs just before the app stage.
# FAKE_APP_STARTS_DURING_HANDOVER=1 brings an app up while the handover runs,
# the way an operator opening it by hand would.
# FAKE_REAL_HANDOVER=1 fakes nothing of the install or the handover: the
# successor is the fixture build's TBDDaemon, which stays up as a copy of
# sleep named TBDDaemon at <case>/successor/TBDDaemon (its pid beside it, in
# TBDDaemon.pid) and is killed once the run ends; the predecessor is whatever
# <case>/home/tbd/tbdd.pid names (start_predecessor); and the handover is done
# when the status in <case>/state says so. Its budget is FAKE_HANDOVER_TIMEOUT
# seconds. FAKE_SUCCESSOR_EXITS=1 makes the successor exit at once instead,
# like a daemon that fails to start. The case must create <case>/Applications.
#
# Whatever the mode, the successor's log is <case>/tbdd.log rather than the
# real /tmp/tbdd.log, and the wake stage records "wake" in the events file
# instead of waking anything.
run_update_around_handover() {
    local case_dir="$1"; shift
    local successor_bin="" status=0
    if [ "${FAKE_APP_NOT_RUNNING:-0}" = 1 ]; then
        rm -f "$case_dir/app"
    else
        : > "$case_dir/app"
    fi
    : > "$case_dir/events.log"
    if [ "${FAKE_REAL_HANDOVER:-0}" = 1 ] && [ "${FAKE_SUCCESSOR_EXITS:-0}" != 1 ]; then
        successor_bin="$case_dir/successor/TBDDaemon"
        mkdir -p "$case_dir/successor"
        cp "$(command -v sleep)" "$successor_bin"
        rm -f "$successor_bin.pid"
    fi
    env \
        HOME="$case_dir/home" \
        TBD_HOME="$case_dir/home/tbd" \
        FAKE_TBD_STATE="$case_dir/state" \
        FAKE_BUILD_LOG="$case_dir/build.log" \
        FAKE_APP_STATE="$case_dir/app" \
        FAKE_OPEN_LOG="$case_dir/events.log" \
        FAKE_KILL_LOG="$case_dir/events.log" \
        FAKE_EVENTS_LOG="$case_dir/events.log" \
        FAKE_INSTALLED_BUNDLE="$case_dir/Applications/TBD.app" \
        FAKE_DAEMON_LOG="$case_dir/tbdd.log" \
        FAKE_SUCCESSOR_BIN="$successor_bin" \
        FAKE_BUNDLE_CP="$case_dir/bin/bundle-cp" \
        PATH="$case_dir/bin:$PATH" \
        bash -c '
            script="$1"; shift
            # shellcheck source=/dev/null
            source "$script"
            INSTALLED_BUNDLE="$FAKE_INSTALLED_BUNDLE"
            DAEMON_LOG="$FAKE_DAEMON_LOG"
            # The library sets TBD_BUNDLE_CP to /bin/cp whenever it is
            # sourced, and main sources it again as it starts, so the stub
            # goes in as the install begins, the first step that copies a
            # bundle, and stays for the rest of the run.
            eval "stubless_$(declare -f install_new_bundle)"
            install_new_bundle() {
                TBD_BUNDLE_CP="$FAKE_BUNDLE_CP"
                if [ "${FAKE_LINK_PUT_BACK_FAILS:-0}" = 1 ]; then
                    restore_release_link() { return 1; }
                fi
                stubless_install_new_bundle "$@"
            }
            if [ "${FAKE_STAMP_STOP:-0}" = 1 ]; then
                eval "real_$(declare -f stop_app_before_handover)"
                stop_app_before_handover() {
                    real_stop_app_before_handover
                    printf "app-stop-returned at %s\n" "$(date +%s)" >> "$FAKE_EVENTS_LOG"
                }
            fi
            if [ "${FAKE_EXITS_DURING_STOP:-0}" = 1 ]; then
                log_app_stop() { exit 7; }
            fi
            if [ "${FAKE_REAL_HANDOVER:-0}" = 1 ]; then
                HANDOVER_TIMEOUT="${FAKE_HANDOVER_TIMEOUT:-$HANDOVER_TIMEOUT}"
                HANDOVER_STOP_GRACE=1
            elif [ "${FAKE_REAL_INSTALL:-0}" = 1 ]; then
                if [ "${FAKE_EXITS_AFTER_KEEP:-0}" = 1 ]; then
                    eval "real_$(declare -f keep_installed_bundle)"
                    keep_installed_bundle() { real_keep_installed_bundle "$@"; exit 5; }
                fi
                if [ "${FAKE_EXITS_AFTER_INSTALL:-0}" = 1 ]; then
                    eval "real_$(declare -f install_new_bundle)"
                    install_new_bundle() { real_install_new_bundle "$@" && exit 6; }
                fi
                handover() {
                    printf "bundle-at-handover %s\n" \
                        "$(cat "$INSTALLED_BUNDLE/Contents/SourceWorktreePath.txt" 2>/dev/null)" \
                        >> "$FAKE_EVENTS_LOG"
                    printf "handover %s\n" "$1" >> "$FAKE_EVENTS_LOG"
                    [ "${FAKE_HANDOVER_EXITS:-0}" = 1 ] && exit 3
                    if [ "${FAKE_KEPT_BUNDLE_VANISHES:-0}" = 1 ]; then
                        rm -rf "$PREVIOUS_BUNDLE"
                    fi
                    [ "${FAKE_HANDOVER_FAILS:-0}" != 1 ]
                }
            else
                install_new_bundle() {
                    printf "install %s\n" "$2" >> "$FAKE_EVENTS_LOG"
                }
                hand_over_to_new_daemon() {
                    printf "handover %s\n" "$2" >> "$FAKE_EVENTS_LOG"
                    [ "${FAKE_APP_STARTS_DURING_HANDOVER:-0}" = 1 ] && : > "$FAKE_APP_STATE"
                    [ "${FAKE_HANDOVER_EXITS:-0}" = 1 ] && exit 3
                    if [ "${FAKE_HANDOVER_FAILS:-0}" = 1 ]; then
                        [ "${FAKE_RESTORE_FAILS:-0}" = 1 ] && roll_back_bundle "$INSTALLED_BUNDLE"
                        return 1
                    fi
                    HANDOVER_STARTED=now
                }
            fi
            refresh_installed_cli() {
                if [ "${FAKE_EXITS_BEFORE_APP_STAGE:-0}" = 1 ]; then
                    exit 4
                fi
            }
            run_wake_stage() {
                printf "wake\n" >> "$FAKE_EVENTS_LOG"
                WAKE_CANDIDATES=0; WAKE_WOKEN=0; WAKE_FAILED=0
            }
            set -uo pipefail
            main "$@"
        ' _ "$SCRIPT" "$@" 2>&1 || status=$?
    [ -z "$successor_bin" ] || stop_stand_in "$successor_bin.pid"
    return "$status"
}

# Kill the stand-in daemon whose pid <pid_file> holds, if it is still running.
# Only while that pid is still a running daemon: once the stand-in has gone,
# the pid is free for the system to hand to anything.
stop_stand_in() {
    local pid
    pid="$(head -1 "$1" 2>/dev/null | tr -dc '0-9')"
    if daemon_process_is_running "$pid"; then
        kill -KILL "$pid" 2>/dev/null
    fi
}

# Stand in for the daemon a handover replaces: a copy of sleep named
# TBDDaemon, so daemon_process_is_running takes it for one, with its pid in the
# case's pid file, where handover() reads its predecessor from. Its shutdown
# begins when the handover starts the successor (the successor's log appears)
# and takes <seconds>: the time a real predecessor goes on answering on its
# socket after it has let go of every session. Then it exits, and "predecessor
# exited" lands in the events file. With `never` it keeps running until the
# case calls stop_predecessor. Counting from the handover rather than from the
# start means a build that runs long on a slow runner cannot use the lifetime
# up before the handover begins.
#
#   start_predecessor <case_dir> <seconds|never>
start_predecessor() {
    local case_dir="$1" lifetime="$2"
    local bin="$case_dir/old/TBDDaemon"
    local pid_file="$case_dir/home/tbd/tbdd.pid"
    mkdir -p "$case_dir/old" "$case_dir/home/tbd"
    cp "$(command -v sleep)" "$bin"
    rm -f "$pid_file" "$case_dir/tbdd.log"
    (
        "$bin" 300 &
        pid=$!
        printf '%s\n' "$pid" > "$pid_file"
        # The pid stays this subshell's until the wait below reaps it, so the
        # kill can only ever reach the stand-in.
        if [ "$lifetime" != never ]; then
            ticks=0
            while [ ! -e "$case_dir/tbdd.log" ] && [ "$ticks" -lt 600 ] &&
                daemon_process_is_running "$pid"; do
                sleep 0.1
                ticks=$((ticks + 1))
            done
            sleep "$lifetime"
            kill "$pid" 2>/dev/null
        fi
        wait "$pid"
        printf 'predecessor exited\n' >> "$case_dir/events.log"
    ) > /dev/null 2>&1 &
    # Until the fork has become the exec, the pid is still a shell and names no
    # daemon.
    wait_until_daemon "$pid_file"
}

# Wait, up to five seconds, until the pid in <pid_file> is a running daemon
# (daemon_process_is_running).
wait_until_daemon() {
    local ticks=0
    while ! daemon_process_is_running "$(head -1 "$1" 2>/dev/null | tr -dc '0-9')" &&
        [ "$ticks" -lt 50 ]; do
        sleep 0.1
        ticks=$((ticks + 1))
    done
}

# The pid start_predecessor started for <case_dir>.
predecessor_pid() {
    head -1 "$1/home/tbd/tbdd.pid" 2>/dev/null | tr -dc '0-9'
}

# Kill the stand-in start_predecessor started for <case_dir>, if it is still
# running.
stop_predecessor() {
    stop_stand_in "$1/home/tbd/tbdd.pid"
}

# Make the case's daemon status name the executable the update installs: the
# update clone's release TBDDaemon. A local build runs the predecessor from
# that same file, so this is what the predecessor answers as well as the
# successor, from before the handover to after it.
report_installed_executable() {
    local case_dir="$1"
    cat > "$case_dir/state/status.json" << EOF
{
  "executablePath": "$case_dir/home/tbd/updates/src/.build/release/TBDDaemon",
  "buildIdentity": {
    "commit": "1111111111111111111111111111111111111111",
    "shortCommit": "1111111",
    "sourceWorktree": "$case_dir/worktree"
  }
}
EOF
}

# The number of the first line of <file> that starts with <prefix>, or nothing
# when no line does.
first_line_starting() {
    grep -n -- "^$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

# Pass when line <a> exists and comes before line <b>, which also exists.
assert_before() {
    if [ -n "$2" ] && [ -n "$3" ] && [ "$2" -lt "$3" ]; then
        pass "$1"
    else
        fail "$1: expected line [$2] before line [$3]"
    fi
}

# THE REGRESSION: the app used to be restarted only after the handover. The
# old app, still running while the daemon changed hands, reconnected to the
# successor and re-attached the session on screen half a second before the
# restart killed it, and the successor kept that dead app's claim on the
# terminal, refusing the new app's attach. The stop has to finish before the
# handover starts and the launch has to follow it, for a run from the user's
# shell and for the daemon's unattended --auto run alike.
test_the_app_is_stopped_before_the_handover() {
    local mode case_dir rc events log install stop poll handover launch
    for mode in manual auto; do
        case_dir="$(mkcase "app-order-$mode")"
        events="$case_dir/events.log"
        if [ "$mode" = auto ]; then
            run_update_around_handover "$case_dir" --auto >/dev/null; rc=$?
        else
            run_update_around_handover "$case_dir" >/dev/null; rc=$?
        fi
        assert_eq "an update that hands over succeeds ($mode)" "0" "$rc"
        install="$(first_line_starting "$events" "install ")"
        stop="$(first_line_starting "$events" "pkill -f ")"
        poll="$(first_line_starting "$events" "pgrep -f ")"
        handover="$(first_line_starting "$events" "handover ")"
        launch="$(first_line_starting "$events" "open ")"
        # Why the install comes first: test_the_app_quits_in_front_of_the_whole_new_bundle.
        assert_before "the new bundle is installed before the app is signalled ($mode)" "$install" "$stop"
        assert_before "the app is signalled before the handover starts ($mode)" "$stop" "$handover"
        assert_before "the stop waits for the app to exit before the handover ($mode)" "$poll" "$handover"
        assert_before "the app is launched after the handover ($mode)" "$handover" "$launch"
        assert_eq "the app is launched once ($mode)" "1" "$(grep -c '^open ' "$events")"
        if [ -f "$case_dir/app" ]; then
            pass "the app is running when the update ends ($mode)"
        else
            fail "the app is running when the update ends ($mode)"
        fi
        log="$(cat "$case_dir/home/tbd/updates/update.log" 2>/dev/null)"
        assert_contains "the stop before the handover is logged ($mode)" \
            "stopping the app before the handover" "$log"
        assert_contains "how the stop ended is logged ($mode)" "the app exited" "$log"
        # The app stage stops the installed app again in case one came up
        # since. Finding none is the expected answer there, and logging it
        # read as if the stop before the handover had found nothing.
        assert_not_contains "the app stage's empty second stop is not logged ($mode)" \
            "no app running from" "$log"
        assert_eq "the app's exit is logged once, by the stop before the handover ($mode)" \
            "1" "$(grep -c 'the app exited' "$case_dir/home/tbd/updates/update.log")"
    done
}

# THE REGRESSION: the app was stopped before the new bundle went in, so it
# quit while /Applications/TBD.app was moved aside or half-copied. On macOS 27
# a quitting app's bundle is read from its installed path to decide whether
# the app may stay in the background; a read that fails counts as "no", and
# LaunchServices then force-quits everything in the app's coalition — the
# daemon, every holder and every agent session under them. The real install
# runs here over a bundle installed before the update, and the pkill stub
# records what the installed path holds at the instant the app is signalled
# (FAKE_BUNDLE_AT_STOP): it must already be the new build, whole, and must
# still be that build when the handover starts. Stopping first records the
# bundle from before the update instead, and fails.
test_the_app_quits_in_front_of_the_whole_new_bundle() {
    local case_dir out rc events installed new_build
    case_dir="$(mkcase app-quits-in-front-of-new-bundle)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    # What the assembled bundle's SourceWorktreePath.txt names: the update clone.
    new_build="$case_dir/home/tbd/updates/src"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_BUNDLE_AT_STOP="$installed" \
        run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "the update succeeds" "0" "$rc"
    assert_eq "the app is signalled once while it runs" "1" \
        "$(grep -c '^bundle-at-stop ' "$events")"
    # Not absent, not incomplete, not the bundle from before the update.
    assert_eq "the installed path holds the whole new build when the app quits" \
        "bundle-at-stop $new_build" "$(grep '^bundle-at-stop ' "$events" | head -1)"
    assert_eq "and still holds it when the handover starts" \
        "bundle-at-handover $new_build" "$(grep '^bundle-at-handover ' "$events" | head -1)"
    assert_eq "the bundle it replaced is kept" "before-the-update" \
        "$(cat "$case_dir/home/tbd/updates/previous/TBD.app/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_contains "the stop is logged" "stopping the app before the handover" "$out"
    if [ -f "$case_dir/app" ]; then
        pass "the app is running when the update ends"
    else
        fail "the app is running when the update ends"
    fi
}

# THE REGRESSION: the install emptied the installed path and only then copied
# the new bundle in — moved aside, or deleted — so for as long as the copy ran
# the app was running in front of a missing or half-copied bundle, and an app
# that quit then (a Cmd-Q, a crash) took every session with it. The new bundle
# is now copied in beside the installed one and swapped in once whole. The
# bundle-cp stub records what the installed path holds as each copy starts and
# once it has finished: every record must be the whole bundle from before the
# update, and one of the copies must be the new bundle's, into the staging
# sibling. An install that empties the path first records `absent`, and one
# that copies past the seam records no copy at all.
test_the_installed_bundle_stays_whole_while_the_update_copies() {
    local case_dir rc events installed incoming
    case_dir="$(mkcase installed-whole-while-copying)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    incoming="$case_dir/Applications/.TBD-install-incoming"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" >/dev/null
    FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir" >/dev/null; rc=$?
    assert_eq "the update succeeds" "0" "$rc"
    assert_eq "the new bundle is copied to the staging sibling once" "1" \
        "$(grep -c -F -- "-> $incoming at " "$events")"
    assert_eq "every copy starts and ends with the whole bundle from before the update installed" \
        "before-the-update" \
        "$(sed -n -e 's/^copy .* installed //p' -e 's/^copied .* installed //p' "$events" | sort -u)"
    assert_eq "the new build is installed" "$case_dir/home/tbd/updates/src" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "no staging sibling is left" "gone" "$(path_state "$incoming")"
    assert_eq "no outgoing sibling is left" "gone" \
        "$(path_state "$case_dir/Applications/.TBD-install-outgoing")"
}

# With the install ahead of the stop, a failed install happens with the app
# still running. The real install runs, keeps a copy of the installed bundle,
# and then the copy of the new bundle into the staging sibling fails, leaving
# its tree behind: the run removes it and fails with the installed bundle as
# it was, whole throughout, and because the app was never stopped it is never
# signalled, nothing launches it again, and nothing reports an interruption or
# a rollback left undone.
test_a_failed_install_leaves_the_app_running() {
    local case_dir out rc events installed incoming
    case_dir="$(mkcase app-failed-install)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    incoming="$case_dir/Applications/.TBD-install-incoming"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_COPY_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed install fails the run" "1" "$rc"
    assert_contains_literal "the failed copy is logged" "ERROR: could not install to $installed" "$out"
    assert_contains "and says the installed bundle is untouched" \
        "what was installed there is untouched" "$out"
    assert_eq "the copy into the staging sibling was made" "1" \
        "$(grep -c -F -- "-> $incoming at " "$events")"
    assert_eq "the installed path holds the bundle from before the update throughout" \
        "before-the-update" \
        "$(sed -n -e 's/^copy .* installed //p' -e 's/^copied .* installed //p' "$events" | sort -u)"
    assert_eq "the installed bundle is the one from before the update" "before-the-update" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    if [ -x "$installed/Contents/MacOS/TBDApp" ]; then
        pass "the installed bundle is whole"
    else
        fail "the installed bundle is whole"
    fi
    assert_eq "the failed copy is removed" "gone" "$(path_state "$incoming")"
    assert_eq "nothing was moved out" "gone" \
        "$(path_state "$case_dir/Applications/.TBD-install-outgoing")"
    assert_not_contains "nothing is put back, since nothing moved" \
        "restored previous app bundle" "$out"
    assert_not_contains "the app is never signalled" "^pkill" "$(cat "$events")"
    assert_not_contains "nothing is handed over" "^handover" "$(cat "$events")"
    assert_not_contains "no app is launched, by main or by the exit trap" "^open" "$(cat "$events")"
    if [ -f "$case_dir/app" ]; then
        pass "the app is still running when a failed install ends"
    else
        fail "the app is still running when a failed install ends"
    fi
    assert_not_contains "no relaunch is logged" \
        "relaunching the app this run stopped before the handover" "$out"
    assert_not_contains "a failed install is not reported as an interruption" \
        "interrupted while installing" "$out"
    assert_not_contains "nor as a rollback that did not complete" "did not complete" "$out"
}

# A swap that can put neither the new bundle in place nor the old one back
# leaves nothing installed, with the app still running in front of the empty
# path (install_app_bundle's status 2). Nothing later in the run puts the old
# bundle back, so the install tries the rename back once more. When that fails
# too, it says nothing is installed and where the bundle that was installed
# is, warns not to quit TBD until a bundle is back with the command that puts
# it back, and records that the installed path no longer holds what the run
# found (BUNDLE_RESTORE_FAILED), so main reports a rollback that did not
# complete and logs the recovery steps rather than a failed install that left
# everything as it was. The mv stub refuses the staged bundle's rename into
# place and every rename back.
test_an_install_that_leaves_nothing_installed_says_where_the_bundle_is() {
    local case_dir out rc events apps installed incoming outgoing kept
    case_dir="$(mkcase install-leaves-nothing)"
    events="$case_dir/events.log"
    apps="$case_dir/Applications"
    installed="$apps/TBD.app"
    incoming="$apps/.TBD-install-incoming"
    outgoing="$apps/.TBD-install-outgoing"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    mkdir -p "$apps"
    mkbundle "$installed" "before-the-update" >/dev/null
    mkrefusingmv "$case_dir/bin"
    refuse_mv "$case_dir/bin" "$incoming" "$installed"
    refuse_mv "$case_dir/bin" "$outgoing" "$installed"
    out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "an install that leaves nothing installed fails the run" "1" "$rc"
    assert_eq "the staged bundle's rename into place is refused" "1" \
        "$(mv_refusals "$case_dir/bin" "$incoming" "$installed")"
    assert_eq "the rename back is refused, and refused again when it is retried" "2" \
        "$(mv_refusals "$case_dir/bin" "$outgoing" "$installed")"
    assert_contains_literal "the error says nothing is installed, and where the bundle that was is" \
        "ERROR: could not install to $installed, and nothing is installed there now; the bundle that was is at $outgoing" \
        "$out"
    assert_contains_literal "the report says nothing is installed" \
        "installed bundle at $installed: build none" "$out"
    assert_contains_literal "and where the kept copy is" "kept bundle at $kept: build" "$out"
    assert_contains_literal "a warning says not to quit TBD until a bundle is back" \
        "WARNING: nothing is installed at $installed. Do not quit TBD until a whole bundle is back there" \
        "$out"
    assert_contains_literal "and names the command that puts it back, its paths quoted" \
        "Put back the bundle that was installed with: mv \"$outgoing\" \"$installed\"" "$out"
    assert_contains "the run reports a rollback that did not complete" \
        "ERROR: the rollback of the failed install did not complete" "$out"
    assert_contains "with the recovery steps" "run 'tbd version'" "$out"
    assert_not_contains "it is not reported as a failed install that changed nothing" \
        "what was installed there is untouched" "$out"
    assert_not_contains "nor as an interruption" "interrupted while installing" "$out"
    assert_eq "nothing is installed" "gone" "$(path_state "$installed")"
    assert_eq "the bundle that was installed is at the outgoing sibling" "before-the-update" \
        "$(cat "$outgoing/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "and a copy of it is kept" "before-the-update" \
        "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_not_contains "the app is never signalled" "^pkill" "$(cat "$events")"
    assert_not_contains "nothing is handed over" "^handover" "$(cat "$events")"
    assert_not_contains "no app is launched, by main or by the exit trap" "^open" "$(cat "$events")"
    if [ -f "$case_dir/app" ]; then
        pass "the app the run never stopped is still running"
    else
        fail "the app the run never stopped is still running"
    fi
}

# The warning offers the rename back only for a tree that is a bundle, by
# the test the put-back itself makes. A tree at the outgoing name that is not
# whole (here the installed bundle had no executable Contents/MacOS/TBDApp
# to begin with) is no bundle to put in front of a quitting app. The bundle
# the swap staged at the incoming name is, so the warning gives the rename
# that puts it in place. Offering `mv` for the broken tree fails, and so does
# sending the operator to the kept bundle, a copy of that broken tree, by the
# documented way back, whose `rm` would delete the staged bundle.
test_an_install_that_leaves_nothing_installed_points_past_a_broken_bundle() {
    local case_dir out rc apps installed incoming outgoing new_commit
    case_dir="$(mkcase install-leaves-nothing-broken)"
    apps="$case_dir/Applications"
    installed="$apps/TBD.app"
    incoming="$apps/.TBD-install-incoming"
    outgoing="$apps/.TBD-install-outgoing"
    mkdir -p "$apps"
    mkbundle "$installed" "before-the-update" >/dev/null
    rm -f "$installed/Contents/MacOS/TBDApp"
    mkrefusingmv "$case_dir/bin"
    refuse_mv "$case_dir/bin" "$incoming" "$installed"
    # The swap's own rename back; the retry after it (the put-back) turns the
    # tree down before it renames anything.
    refuse_mv "$case_dir/bin" "$outgoing" "$installed"
    out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "an install that leaves nothing installed fails the run" "1" "$rc"
    assert_eq "nothing is installed" "gone" "$(path_state "$installed")"
    assert_eq "the tree that was installed is at the outgoing sibling" "before-the-update" \
        "$(cat "$outgoing/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_contains_literal "the put-back refuses it" \
        "not putting back $installed from $outgoing: it lacks" "$out"
    assert_contains_literal "a warning says not to quit TBD until a bundle is back" \
        "WARNING: nothing is installed at $installed. Do not quit TBD until a whole bundle is back there" \
        "$out"
    assert_not_contains "it offers no rename of the broken tree into place" \
        "Put back the bundle that was installed with" "$out"
    new_commit="$(git -C "$case_dir/home/tbd/updates/src" rev-parse HEAD 2>/dev/null)"
    assert_contains_literal "it gives the rename of the staged bundle into place, naming it the new build, which the daemon does not run, its paths quoted" \
        "The bundle that was installed, at $outgoing, is not whole, but the one this run staged is (the new build, $new_commit from $case_dir/home/tbd/updates/src, not build $CASE_DAEMON_COMMIT from $case_dir/worktree, which the daemon runs): put it in place with: mv \"$incoming\" \"$installed\"" \
        "$out"
    assert_not_contains "and does not send the operator to the kept bundle instead" \
        "is whole, so put back the bundle kept at" "$out"
    assert_eq "the staged bundle is still there to rename" "present" \
        "$(path_state "$incoming/Contents/MacOS/TBDApp")"
}

# The way back that docs/updating.md gives, run as written but pointed at a
# scratch /Applications and home. With nothing installed, a whole bundle at
# the incoming name is the one the warning above tells the operator to
# rename into place, so the command leaves it alone; once that name holds no
# whole bundle, the command puts the kept bundle in. A command whose `rm`
# clears the incoming name regardless, as it did, deletes the staged bundle.
#
# A copy cut short must never sit at the incoming name, which that test
# trusts: here a stand-in for /bin/cp copies Info.plist and TBDApp, enough to
# look whole, and fails. The incoming name stays empty, and a re-run with the
# real cp puts the kept bundle in. A command that copies straight to the
# incoming name, as it did, leaves the partial copy looking whole there, and
# the re-run then does nothing.
#
# The command names /Applications once, in its `cd`, and /bin/cp once; both
# are rewritten to scratch stand-ins, and a command that names either
# anywhere else is not run at all.
test_the_documented_way_back_keeps_a_staged_bundle() {
    local state root apps cmd run cut_short
    cmd="$(awk '/^  ```bash$/{f=1;next} /^  ```$/{if(f)exit} f' "$REPO_ROOT/docs/updating.md")"
    if [ "$(printf '%s\n' "$cmd" | grep -o /Applications | wc -l | tr -d ' ')" != 1 ] ||
        ! printf '%s\n' "$cmd" | grep -q '( cd /Applications &&' ||
        [ "$(printf '%s\n' "$cmd" | grep -o /bin/cp | wc -l | tr -d ' ')" != 1 ]; then
        fail "the documented way back names /Applications only in its cd, and /bin/cp once"
        return
    fi
    assert_contains_literal "it is the command that copies the kept bundle" \
        "/bin/cp -cR ~/tbd/updates/previous/TBD.app" "$cmd"
    cut_short="$TEST_TMP/documented-way-back-cp"
    cat > "$cut_short" << 'EOF'
#!/bin/sh
# A copy cut short: what makes a bundle look whole, and nothing else.
mkdir -p "$3/Contents/MacOS"
/bin/cp "$2/Contents/Info.plist" "$3/Contents/"
/bin/cp "$2/Contents/MacOS/TBDApp" "$3/Contents/MacOS/"
exit 1
EOF
    chmod +x "$cut_short"
    for state in whole-incoming broken-incoming copy-cut-short; do
        root="$TEST_TMP/documented-way-back-$state"
        apps="$root/Applications"
        mkdir -p "$apps"
        case "$state" in
            whole-incoming) mkbundle "$apps/.TBD-install-incoming" "staged" >/dev/null ;;
            broken-incoming) mkdir -p "$apps/.TBD-install-incoming/Contents" ;;
        esac
        mkbundle "$root/home/tbd/updates/previous/TBD.app" "kept" >/dev/null
        # The scratch paths go in as arguments, "$1" for the cd and "$2" for
        # the copy, not spliced into the command's source.
        # shellcheck disable=SC2016 # "$1" is for the command's own shell
        run="$(printf '%s\n' "$cmd" | sed 's|cd /Applications|cd "$1"|')"
        case "$run" in
            *"cd /Applications"*)
                fail "the documented way back is pointed at a scratch /Applications ($state)"
                continue
                ;;
        esac
        if [ "$state" = copy-cut-short ]; then
            # shellcheck disable=SC2016 # "$2" is for the command's own shell
            HOME="$root/home" bash -c "$(printf '%s\n' "$run" | sed 's|/bin/cp|"$2"|')" \
                _ "$apps" "$cut_short" >/dev/null 2>&1
            assert_eq "a copy cut short leaves nothing at the incoming name" "gone" \
                "$(path_state "$apps/.TBD-install-incoming")"
            assert_eq "and nothing installed" "gone" "$(path_state "$apps/TBD.app")"
        fi
        HOME="$root/home" bash -c "$run" _ "$apps" >/dev/null 2>&1
        if [ "$state" = whole-incoming ]; then
            assert_eq "with a whole staged bundle and nothing installed, it changes nothing" "gone" \
                "$(path_state "$apps/TBD.app")"
            assert_eq "and the staged bundle is still there" "staged" \
                "$(cat "$apps/.TBD-install-incoming/Contents/SourceWorktreePath.txt" 2>/dev/null)"
        else
            assert_eq "with no whole bundle staged, it puts the kept bundle in ($state)" "kept" \
                "$(cat "$apps/TBD.app/Contents/SourceWorktreePath.txt" 2>/dev/null)"
            assert_eq "and leaves nothing beside it ($state)" "gone gone gone" \
                "$(path_state "$apps/.TBD-install-incoming") $(path_state "$apps/.TBD-install-outgoing") $(path_state "$apps/.TBD-install-discard")"
        fi
    done
}

# The staged bundle the warning offers is named by its build and by whether
# the daemon runs it, so the operator knows what the rename puts in front of
# the daemon: in a rollback, a copy of the kept bundle of the daemon's build;
# in an install, the new build (the test above); with the daemon's build
# unknown, its build alone. Offering it unnamed, as the warning did, hides
# that an install's staged bundle is not the daemon's build.
test_a_swap_that_leaves_a_whole_staged_bundle_names_its_build() {
    local daemon root out installed outgoing incoming
    for daemon in known unknown; do
        root="$TEST_TMP/whole-staged-bundle-$daemon"
        installed="$root/Applications/TBD.app"
        outgoing="$root/Applications/.TBD-install-outgoing"
        incoming="$root/Applications/.TBD-install-incoming"
        mkdir -p "$outgoing/Contents" "$root/updates"
        mkbundle "$incoming" "staged" "$CASE_DAEMON_COMMIT" >/dev/null
        out="$(
            OPT_AUTO=false
            UPDATE_HOME="$root/updates"
            UPDATE_LOG="$root/updates/update.log"
            PREVIOUS_BUNDLE="$root/updates/previous/TBD.app"
            INSTALLING_BUILD="2222222222222222222222222222222222222222||"
            RUNNING_BUILD=""
            [ "$daemon" = unknown ] || RUNNING_BUILD="$CASE_DAEMON_COMMIT||"
            put_back_after_failed_swap "$installed" 2>&1
        )"
        if [ "$daemon" = known ]; then
            assert_contains_literal "it names the staged bundle's build as the daemon's" \
                "but the one this run staged is (build $CASE_DAEMON_COMMIT, which the daemon runs): put it in place with: mv \"$incoming\" \"$installed\"" \
                "$out"
        else
            assert_contains_literal "with the daemon's build unknown, it names the staged bundle's build alone" \
                "but the one this run staged is (build $CASE_DAEMON_COMMIT): put it in place with: mv \"$incoming\" \"$installed\"" \
                "$out"
        fi
    done
}

# When neither the bundle that was installed nor the one the swap staged is
# whole, the warning sends the operator to the kept bundle, naming its build
# and whether this run kept it or an earlier update did. Sending the operator
# there without saying which, as the warning did, can put back an older
# update's bundle unawares. With no bundle kept, or a kept tree that is not
# whole, it points at a build of a TBD checkout rather than at a bundle that
# cannot go back.
test_a_swap_that_leaves_no_whole_bundle_names_the_kept_one() {
    local who root out installed outgoing incoming kept
    for who in this-run earlier none broken; do
        root="$TEST_TMP/no-whole-bundle-$who"
        installed="$root/Applications/TBD.app"
        outgoing="$root/Applications/.TBD-install-outgoing"
        incoming="$root/Applications/.TBD-install-incoming"
        kept="$root/updates/previous/TBD.app"
        mkdir -p "$outgoing/Contents" "$incoming/Contents" "$root/updates"
        [ "$who" = none ] || mkbundle "$kept" "kept" "$CASE_DAEMON_COMMIT" >/dev/null
        [ "$who" != broken ] || rm -f "$kept/Contents/MacOS/TBDApp"
        out="$(
            OPT_AUTO=false
            UPDATE_HOME="$root/updates"
            UPDATE_LOG="$root/updates/update.log"
            PREVIOUS_BUNDLE="$kept"
            BUNDLE_STASHED=false
            [ "$who" = earlier ] || BUNDLE_STASHED=true
            put_back_after_failed_swap "$installed" 2>&1
        )"
        assert_contains_literal "a warning says not to quit TBD until a bundle is back ($who)" \
            "WARNING: nothing is installed at $installed. Do not quit TBD until a whole bundle is back there" "$out"
        assert_not_contains "it offers no rename of either tree into place ($who)" "with: mv" "$out"
        if [ "$who" = none ] || [ "$who" = broken ]; then
            assert_contains_literal "with no whole bundle kept, it points at a build of a TBD checkout ($who)" \
                "no whole bundle is kept at $kept: install one from a TBD checkout with scripts/restart.sh" "$out"
            assert_not_contains "and not at the kept tree ($who)" "put back the bundle kept at" "$out"
        elif [ "$who" = earlier ]; then
            assert_contains_literal "it names the kept bundle, its build, and that an earlier update kept it" \
                "put back the bundle kept at $kept (build $CASE_DAEMON_COMMIT, kept by an earlier update, not this run) instead" "$out"
        else
            assert_contains_literal "it names the kept bundle, its build, and that this run kept it" \
                "put back the bundle kept at $kept (build $CASE_DAEMON_COMMIT, kept by this run) instead" "$out"
        fi
    done
}

# The second try at the rename back is what keeps a passing failure from
# leaving the installed path empty: here the stub refuses the rename back only
# once, the retry puts the bundle that was installed back in place, and the
# run ends as a failed install that changed nothing, with no warning and no
# rollback to report. Without the retry the path stays empty, and this fails.
test_an_install_that_leaves_nothing_installed_retries_the_put_back() {
    local case_dir out rc events apps installed incoming outgoing
    case_dir="$(mkcase install-put-back-retried)"
    events="$case_dir/events.log"
    apps="$case_dir/Applications"
    installed="$apps/TBD.app"
    incoming="$apps/.TBD-install-incoming"
    outgoing="$apps/.TBD-install-outgoing"
    mkdir -p "$apps"
    mkbundle "$installed" "before-the-update" >/dev/null
    mkrefusingmv "$case_dir/bin"
    refuse_mv "$case_dir/bin" "$incoming" "$installed"
    refuse_mv "$case_dir/bin" "$outgoing" "$installed" once
    out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "the failed install fails the run" "1" "$rc"
    assert_eq "the swap's own rename back is refused" "1" \
        "$(mv_refusals "$case_dir/bin" "$outgoing" "$installed")"
    assert_eq "the retry puts the bundle that was installed back" "before-the-update" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    if [ -x "$installed/Contents/MacOS/TBDApp" ]; then
        pass "the installed bundle is whole"
    else
        fail "the installed bundle is whole"
    fi
    assert_contains_literal "the log says it is back" \
        "the bundle that was installed there is back in place" "$out"
    assert_eq "nothing is left at the outgoing sibling" "gone" "$(path_state "$outgoing")"
    assert_eq "the staged bundle is removed" "gone" "$(path_state "$incoming")"
    assert_not_contains "no warning is logged" "WARNING: nothing is installed" "$out"
    assert_not_contains "nor a rollback that did not complete" "did not complete" "$out"
    assert_not_contains "the app is never signalled" "^pkill" "$(cat "$events")"
    assert_not_contains "no app is launched" "^open" "$(cat "$events")"
    if [ -f "$case_dir/app" ]; then
        pass "the app the run never stopped is still running"
    else
        fail "the app the run never stopped is still running"
    fi
}

# The app stage's second stop still does its job: an app that came up while
# the daemon changed hands is stopped, and its exit logged, before the launch,
# so `open` starts the new bundle instead of activating the old process.
test_an_app_started_during_the_handover_is_stopped_before_the_launch() {
    local case_dir rc events log handover second_stop launch
    case_dir="$(mkcase app-started-during-handover)"
    events="$case_dir/events.log"
    FAKE_APP_STARTS_DURING_HANDOVER=1 run_update_around_handover "$case_dir" >/dev/null; rc=$?
    assert_eq "the update succeeds" "0" "$rc"
    handover="$(first_line_starting "$events" "handover ")"
    second_stop="$(grep -n '^pkill -f ' "$events" | sed -n 2p | cut -d: -f1)"
    launch="$(first_line_starting "$events" "open ")"
    assert_before "the app stage signals the app that came up during the handover" \
        "$handover" "$second_stop"
    assert_before "that app is stopped before the launch" "$second_stop" "$launch"
    log="$case_dir/home/tbd/updates/update.log"
    assert_eq "each stop that found an app logs its exit" "2" "$(grep -c 'the app exited' "$log")"
    if [ -f "$case_dir/app" ]; then
        pass "the app is running when the update ends"
    else
        fail "the app is running when the update ends"
    fi
}

# The real sign_app_bundle runs here (run_update_around_handover stubs only
# the handover), and with CI unset it tries to create the signing identity.
# Neither way may that run the real openssl or leave anything outside the
# case: HOME is the case's, so the keychain and its lock land under it, and
# so does TMPDIR, where the key's scratch directory is made. A GitHub runner
# sets CI=true, so the case runs both ways on purpose.
test_signing_stays_inside_the_case_with_and_without_ci() {
    local ci case_dir rc log
    for ci in unset true; do
        case_dir="$(mkcase "signing-ci-$ci")"
        mkdir -p "$case_dir/tmp"
        if [ "$ci" = unset ]; then
            (
                unset CI
                FAKE_OPENSSL_LOG="$case_dir/openssl.log" TMPDIR="$case_dir/tmp" \
                    run_update_around_handover "$case_dir" >/dev/null
            )
            rc=$?
        else
            CI=true FAKE_OPENSSL_LOG="$case_dir/openssl.log" TMPDIR="$case_dir/tmp" \
                run_update_around_handover "$case_dir" >/dev/null
            rc=$?
        fi
        log="$(cat "$case_dir/openssl.log" 2>/dev/null)"
        assert_eq "an update that cannot create the signing identity still succeeds (CI $ci)" "0" "$rc"
        if [ "$ci" = unset ]; then
            assert_contains_literal "without CI, the identity is tried with the stub openssl" \
                "openssl req -x509" "$log"
            assert_contains_literal "and its key directory is under the case's TMPDIR" \
                "-keyout $case_dir/tmp/tbd-signing." "$log"
        else
            assert_eq "under CI, no openssl runs" "" "$log"
        fi
        assert_eq "no key directory is left (CI $ci)" "" \
            "$(find "$case_dir/tmp" -name 'tbd-signing.*' 2>/dev/null)"
        assert_eq "no keychain or lock is left (CI $ci)" "" \
            "$(find "$case_dir/home" -name 'tbd-signing*' 2>/dev/null)"
    done
}

# Before the stop moved ahead of the handover, a handover that failed left the
# old app running, and it reconnected to whichever daemon came back. Now the
# run has stopped it, so the rollback has to bring it back, from the bundle the
# rollback left installed.
test_a_failed_handover_relaunches_the_stopped_app() {
    local case_dir out rc events stop handover launch
    case_dir="$(mkcase app-failed-handover)"
    events="$case_dir/events.log"
    out="$(FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed handover fails the run" "1" "$rc"
    stop="$(first_line_starting "$events" "pkill -f ")"
    handover="$(first_line_starting "$events" "handover ")"
    launch="$(first_line_starting "$events" "open ")"
    assert_before "the app is stopped before the failed handover" "$stop" "$handover"
    assert_before "the app is relaunched after the failed handover" "$handover" "$launch"
    assert_contains "the relaunch is logged" \
        "relaunching the app this run stopped before the handover" "$out"
    assert_contains_literal "the relaunch opens the installed bundle" \
        "$case_dir/Applications/TBD.app" "$(grep '^open ' "$events")"
    assert_eq "the app is launched once, not again by the exit trap" "1" \
        "$(grep -c '^open ' "$events")"
    if [ -f "$case_dir/app" ]; then
        pass "the app is running when a failed update ends"
    else
        fail "the app is running when a failed update ends"
    fi
}

# The relaunch after a failed handover is right only when the rollback put the
# previous bundle back. When it cannot — a first update keeps no bundle to
# restore — the new build is still installed, and launching it would put the
# new app in front of the old daemon, or start the new daemon if none is left:
# the state the rollback exists to prevent. Main and the exit trap both leave
# the app stopped, and the log says so and how to recover.
test_a_failed_handover_whose_restore_fails_leaves_the_app_stopped() {
    local case_dir out rc events
    case_dir="$(mkcase app-failed-restore)"
    events="$case_dir/events.log"
    out="$(FAKE_HANDOVER_FAILS=1 FAKE_RESTORE_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed handover fails the run" "1" "$rc"
    assert_contains "the app was stopped before the handover" "^pkill -f " "$(cat "$events")"
    assert_contains "the failed restore is logged" "no previous app bundle to restore" "$out"
    assert_not_contains "no app is launched, by main or by the exit trap" "^open" "$(cat "$events")"
    if [ -f "$case_dir/app" ]; then
        fail "the app stays stopped when the rollback could not restore the bundle"
    else
        pass "the app stays stopped when the rollback could not restore the bundle"
    fi
    assert_not_contains "no relaunch is logged" \
        "relaunching the app this run stopped before the handover" "$out"
    assert_contains "the incomplete rollback is logged as an error" \
        "ERROR: the rollback of the failed install did not complete" "$out"
    assert_not_contains "a failed rollback is not reported as an interruption" \
        "interrupted while installing" "$out"
    assert_contains "the log says the app was stopped and is not running" \
        "the app was stopped for the handover and is not running" "$out"
    assert_contains "the recovery starts from tbd version" "run 'tbd version'" "$out"
    assert_contains "the recovery offers another tbd update" "run 'tbd update' again" "$out"
    assert_contains_literal "the report says no bundle is kept" "kept bundle: none" "$out"
    assert_not_contains "nor sends the operator to one" "or put back the bundle kept at" "$out"
    assert_contains "the error reaches update.log too" \
        "ERROR: the rollback of the failed install did not complete" \
        "$(cat "$case_dir/home/tbd/updates/update.log" 2>/dev/null)"
}

# A rollback that puts the kept bundle back spends it, so when only the
# put-back of the .build/release link then fails, nothing is kept at
# ~/tbd/updates/previous/TBD.app any more, and the recovery steps must not
# send the operator there: the report says nothing is kept, and that the
# daemon's build is installed. Saying it is kept at that path, as the steps
# did, fails.
test_a_rollback_whose_link_put_back_fails_does_not_name_a_spent_kept_bundle() {
    local case_dir out rc events installed kept
    case_dir="$(mkcase rollback-link-fails)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" "$CASE_DAEMON_COMMIT" >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 FAKE_LINK_PUT_BACK_FAILS=1 \
        run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed handover fails the run" "1" "$rc"
    assert_contains "the rollback puts the kept bundle back" "restored previous app bundle" "$out"
    assert_contains "the link put-back fails" "ERROR: could not point .* back at" "$out"
    assert_contains "so the rollback did not complete" \
        "ERROR: the rollback of the failed install did not complete" "$out"
    assert_eq "the bundle from before the update is installed" "before-the-update" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "the kept copy is spent" "gone" "$(path_state "$kept")"
    assert_contains_literal "the report says nothing is kept" "kept bundle: none" "$out"
    assert_not_contains "nor sends the operator to the spent copy" \
        "or put back the bundle kept at" "$out"
    assert_contains_literal "it names the daemon's build as installed" \
        "installed bundle at $installed: build $CASE_DAEMON_COMMIT" "$out"
    assert_not_contains "no app is launched" "^open" "$(cat "$events")"
}

# The report says what is installed, not what the rollback did. A kept copy
# this run made that is gone before the rollback leaves nothing to restore,
# just as a restore that spent it leaves the copy gone. Inferring a restore
# from that, as the steps did, tells the operator a bundle is installed
# again that never was. Here the kept copy is deleted during the handover.
test_a_rollback_that_finds_the_kept_bundle_gone_does_not_claim_a_restore() {
    local case_dir out rc events installed kept new_commit
    case_dir="$(mkcase rollback-kept-gone)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    new_commit="$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" "$CASE_DAEMON_COMMIT" >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 FAKE_KEPT_BUNDLE_VANISHES=1 \
        run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed handover fails the run" "1" "$rc"
    assert_contains_literal "the run kept a copy" "kept the previous app bundle at $kept" "$out"
    assert_contains "the rollback finds nothing to restore" \
        "ERROR: no previous app bundle to restore" "$out"
    assert_not_contains "nothing is restored" "restored previous app bundle" "$out"
    assert_contains "so the rollback did not complete" \
        "ERROR: the rollback of the failed install did not complete" "$out"
    assert_contains_literal "the report names the new build as installed" \
        "installed bundle at $installed: build $new_commit" "$out"
    assert_contains_literal "and says nothing is kept" "kept bundle: none" "$out"
    assert_not_contains "no app is launched" "^open" "$(cat "$events")"
}

# THE REGRESSION: the rollback put back whatever sat at
# ~/tbd/updates/previous/TBD.app, and a run that finds nothing installed keeps
# nothing there, so a bundle an earlier update kept was still in place. A
# failed handover then moved that older build into the installed path, called
# the rollback done, and relaunched the app from it: the mismatch the rollback
# exists to prevent. The real install and rollback run here, against a kept
# bundle from an earlier update that is another build than the daemon's
# (0000…, the daemon 1111…) and nothing installed, and only a bundle of the
# daemon's build may go back, so nothing does: the new build stays
# installed, the earlier bundle stays where it was, and the app stays
# stopped with the recovery steps.
test_a_failed_handover_never_restores_an_earlier_updates_bundle() {
    local case_dir out rc events kept installed
    case_dir="$(mkcase app-failed-handover-earlier-bundle)"
    events="$case_dir/events.log"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    installed="$case_dir/Applications/TBD.app"
    mkdir -p "$case_dir/Applications"
    mkbundle "$kept" "earlier-update" 0000000000000000000000000000000000000000 >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed handover fails the run" "1" "$rc"
    assert_contains "the run found nothing installed to keep" \
        "keeping no previous bundle" "$out"
    assert_contains "the run installed and reached the handover" "^handover " "$(cat "$events")"
    assert_eq "the earlier update's bundle stays where it was" "earlier-update" \
        "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_contains_literal "the installed bundle is still the new build" \
        "updates/src" "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_not_contains "nothing is reported restored" "restored previous app bundle" "$out"
    assert_contains "the rollback says it had nothing to restore" \
        "ERROR: no previous app bundle to restore" "$out"
    assert_contains_literal "and why the earlier bundle was not used" \
        "neither $installed nor $kept is build $CASE_DAEMON_COMMIT from $case_dir/worktree, which the daemon runs" "$out"
    assert_contains "the app was stopped before the handover" "^pkill -f " "$(cat "$events")"
    assert_not_contains "no app is launched, by main or by the exit trap" "^open" "$(cat "$events")"
    if [ -f "$case_dir/app" ]; then
        fail "the app stays stopped when the run kept no bundle to restore"
    else
        pass "the app stays stopped when the run kept no bundle to restore"
    fi
    assert_not_contains "no relaunch is logged" \
        "relaunching the app this run stopped before the handover" "$out"
    assert_contains "the incomplete rollback is logged as an error" \
        "ERROR: the rollback of the failed install did not complete" "$out"
    assert_contains "the log says the app was stopped and is not running" \
        "the app was stopped for the handover and is not running" "$out"
    assert_contains "the recovery starts from tbd version" "run 'tbd version'" "$out"
    assert_contains "the recovery offers another tbd update" "run 'tbd update' again" "$out"
}

# Give <bundle> the build identity this harness's run stamps on its own build
# of <commit>, from the update clone of <case>: the fields bundle_build_key
# compares, and the release configuration the run builds, which same_build
# compares too. A non-empty <source> or <dirty> stands in for that field,
# and a non-empty <built_at> adds a builtAt, which a dirty build is compared
# by.
#
#   stamp_clone_identity <bundle> <case> <commit> [<source>] [<dirty>] [<built_at>]
stamp_clone_identity() {
    local bundle="$1" case_dir="$2" commit="$3"
    local source="${4:-$case_dir/home/tbd/updates/src}" dirty="${5:-false}" built_at=""
    [ -z "${6-}" ] || built_at=", \"builtAt\": \"$6\""
    printf '{"commit": "%s", "sourceWorktree": "%s", "dirty": %s%s, "configuration": "release"}\n' \
        "$commit" "$source" "$dirty" "$built_at" > "$bundle/Contents/TBDBuildIdentity.json"
}

# Make the daemon of a case made by mkcase report <commit> as its build.
daemon_reports_commit() {
    local case_dir="$1" commit="$2"
    cat > "$case_dir/state/status.json" << EOF
{
  "executablePath": "$case_dir/worktree/.build/debug/TBDDaemon",
  "buildIdentity": {
    "commit": "$commit",
    "sourceWorktree": "$case_dir/worktree"
  }
}
EOF
}

# THE REGRESSION: a run cut short after its swap leaves the new build
# installed in front of a daemon still on the previous build, with the bundle
# it replaced kept. The next `tbd update` kept a copy of what it found
# installed, the new build, in place of that kept bundle, so the route back to
# the previous build was gone. A run that finds the build it installs
# already installed (same commit, source worktree and dirty flag) now keeps
# no copy of it and leaves the earlier kept bundle where it is, whether the
# handover completes or fails, and whether or not the daemon's build is
# known: here the daemon names no build, as one that does not answer leaves
# it. A failed handover in front of a daemon (1111…) that neither bundle
# matches (the kept one is 0000…) restores nothing, leaves the app stopped,
# and the report gives the facts and the recovery steps.
test_an_update_over_its_own_build_leaves_the_kept_bundle_alone() {
    local how case_dir out rc events installed kept new_commit
    for how in completes fails daemon-unknown; do
        case_dir="$(mkcase "over-own-build-$how")"
        events="$case_dir/events.log"
        installed="$case_dir/Applications/TBD.app"
        kept="$case_dir/home/tbd/updates/previous/TBD.app"
        # The commit the run installs: the fixture remote's main, which the
        # update clone checks out.
        new_commit="$(git -C "$case_dir/remote" rev-parse HEAD)"
        mkdir -p "$case_dir/Applications"
        mkbundle "$installed" "left-by-the-cut-short-run" >/dev/null
        stamp_clone_identity "$installed" "$case_dir" "$new_commit"
        mkbundle "$kept" "before-the-cut-short-run" 0000000000000000000000000000000000000000 >/dev/null
        case "$how" in
            fails)
                out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
                assert_eq "a failed handover fails the run" "1" "$rc"
                ;;
            daemon-unknown)
                printf '{"buildIdentity": {"sourceWorktree": "%s"}}\n' "$case_dir/worktree" \
                    > "$case_dir/state/status.json"
                out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
                assert_eq "a completed handover succeeds (daemon's build unknown)" "0" "$rc"
                ;;
            *)
                out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
                assert_eq "a completed handover succeeds" "0" "$rc"
                ;;
        esac
        assert_contains_literal "the run says the build it installs is already installed ($how)" \
            "$installed is already the build this run installs — keeping no copy of it" "$out"
        assert_eq "the earlier kept bundle stays ($how)" "before-the-cut-short-run" \
            "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
        assert_eq "the run's own build is installed ($how)" "$case_dir/home/tbd/updates/src" \
            "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
        [ "$how" = fails ] || continue
        assert_not_contains "a failed handover restores nothing" "restored previous app bundle" "$out"
        assert_contains_literal "no bundle of the daemon's build is at hand" \
            "ERROR: no previous app bundle to restore — neither $installed nor $kept is build $CASE_DAEMON_COMMIT from $case_dir/worktree, which the daemon runs" "$out"
        assert_contains "the incomplete rollback is logged as an error" \
            "ERROR: the rollback of the failed install did not complete" "$out"
        assert_contains_literal "the report names the installed build" \
            "installed bundle at $installed: build $new_commit" "$out"
        assert_contains_literal "says the daemon's build is unknown once the handover began" \
            "daemon: build unknown — the handover had begun" "$out"
        assert_contains_literal "names the kept bundle and its build" \
            "kept bundle at $kept: build 0000000000000000000000000000000000000000" "$out"
        assert_contains_literal "and sends the operator to it" \
            "or put back the bundle kept at $kept" "$out"
        assert_not_contains "no app is launched, by main or by the exit trap" "^open" "$(cat "$events")"
        if [ -f "$case_dir/app" ]; then
            fail "the app stays stopped when no bundle matches the daemon"
        else
            pass "the app stays stopped when no bundle matches the daemon"
        fi
    done
}

# A run cut short after its swap, whose earlier kept bundle is the daemon's
# build (1111…): the keep keeps nothing, and a failed handover puts that
# kept bundle back in front of the daemon and relaunches the app. Restoring
# only a bundle this run kept, as the rollback did, leaves the new app
# installed and the app stopped, and fails.
test_a_failed_handover_restores_the_kept_bundle_that_matches_the_daemon() {
    local case_dir out rc events installed kept
    case_dir="$(mkcase rollback-to-the-daemons-build)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "left-by-the-cut-short-run" >/dev/null
    stamp_clone_identity "$installed" "$case_dir" "$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkbundle "$kept" "the-daemons-build" "$CASE_DAEMON_COMMIT" >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed handover fails the run" "1" "$rc"
    assert_contains "the keep was skipped" "keeping no copy of it" "$out"
    assert_contains "the rollback restores the kept bundle" "restored previous app bundle" "$out"
    assert_eq "the daemon's build is installed" "the-daemons-build" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_not_contains "the rollback completes" "did not complete" "$out"
    assert_contains "and the app is relaunched" \
        "relaunching the app this run stopped before the handover" "$out"
    assert_eq "once" "1" "$(grep -c '^open ' "$events")"
}

# THE REGRESSION: a run kept the daemon's build (1111…), swapped in its new
# build (2222…) and was cut short before the handover; a newer commit then
# landed, and the retry installs that. The installed bundle is neither the
# daemon's build nor the retry's, so the keep copied it over the kept
# bundle, and the only bundle of the daemon's build was gone: a failed
# handover put the cut-short build back in front of the daemon, with a line
# saying it matched nothing, and a completed one left a successor reading
# that build at the kept path. The keep now keeps nothing there, so a failed
# handover puts the daemon's build back and a completed one leaves it kept.
test_a_newer_retry_after_a_cut_short_swap_keeps_the_daemons_build() {
    local how case_dir out rc events installed kept
    for how in fails completes; do
        case_dir="$(mkcase "newer-retry-$how")"
        events="$case_dir/events.log"
        installed="$case_dir/Applications/TBD.app"
        kept="$case_dir/home/tbd/updates/previous/TBD.app"
        mkdir -p "$case_dir/Applications"
        mkbundle "$installed" "left-by-the-cut-short-run" >/dev/null
        stamp_clone_identity "$installed" "$case_dir" 2222222222222222222222222222222222222222
        mkbundle "$kept" "the-daemons-build" "$CASE_DAEMON_COMMIT" >/dev/null
        if [ "$how" = fails ]; then
            out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
            assert_eq "a failed handover fails the run" "1" "$rc"
        else
            out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
            assert_eq "a completed handover succeeds" "0" "$rc"
        fi
        assert_contains_literal "the keep names both builds and keeps nothing ($how)" \
            "$installed is build 2222222222222222222222222222222222222222 from $case_dir/home/tbd/updates/src, not build $CASE_DAEMON_COMMIT from $case_dir/worktree, which the daemon runs and $kept holds — keeping no copy of it" \
            "$out"
        assert_not_contains "the cut-short build is not kept ($how)" "kept the previous app bundle" "$out"
        if [ "$how" = completes ]; then
            assert_eq "the daemon's build is still the kept bundle" "the-daemons-build" \
                "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
            assert_eq "and the retry's build is installed" "$case_dir/home/tbd/updates/src" \
                "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
            continue
        fi
        assert_not_contains "the rollback needs no excuse for what it restores" \
            "putting back the bundle this run replaced" "$out"
        assert_contains "the kept bundle goes back" "restored previous app bundle" "$out"
        assert_eq "the daemon's build is installed" "the-daemons-build" \
            "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
        assert_not_contains "the rollback completes" "did not complete" "$out"
        assert_contains "and the app is relaunched" \
            "relaunching the app this run stopped before the handover" "$out"
        assert_eq "once" "1" "$(grep -c '^open ' "$events")"
    done
}

# A daemon with no stamp reports the HEAD of its worktree, marked
# `origin: worktreeHead`, and that HEAD can have moved since the daemon
# started, so it says nothing sure of the daemon's build. The rollback then
# treats the build as unknown: with this run's own build installed (the keep
# kept nothing) and an earlier update's bundle kept at the reported commit,
# it puts nothing back, leaves the app stopped and reports the daemon's
# build as unknown. A stamped daemon reporting the same commit gets the kept
# bundle put back, as above. Taking the HEAD for the daemon's build, as the
# run did, puts that bundle in front of a daemon that may be another build.
test_a_daemon_identity_read_from_its_worktree_head_is_an_unknown_build() {
    local origin case_dir out rc events installed kept
    for origin in worktreeHead stamp; do
        case_dir="$(mkcase "daemon-origin-$origin")"
        events="$case_dir/events.log"
        installed="$case_dir/Applications/TBD.app"
        kept="$case_dir/home/tbd/updates/previous/TBD.app"
        cat > "$case_dir/state/status.json" << EOF
{
  "executablePath": "$case_dir/worktree/.build/debug/TBDDaemon",
  "buildIdentity": {
    "commit": "$CASE_DAEMON_COMMIT",
    "sourceWorktree": "$case_dir/worktree",
    "origin": "$origin"
  }
}
EOF
        mkdir -p "$case_dir/Applications"
        mkbundle "$installed" "left-by-the-cut-short-run" >/dev/null
        stamp_clone_identity "$installed" "$case_dir" "$(git -C "$case_dir/remote" rev-parse HEAD)"
        mkbundle "$kept" "the-reported-commit" "$CASE_DAEMON_COMMIT" >/dev/null
        out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
        assert_eq "a failed handover fails the run ($origin)" "1" "$rc"
        assert_contains "the keep was skipped ($origin)" "keeping no copy of it" "$out"
        if [ "$origin" = worktreeHead ]; then
            assert_contains_literal "the rollback takes the daemon's build for unknown" \
                "no previous app bundle to restore — the daemon's build is unknown, and this run kept none" \
                "$out"
            assert_not_contains "and puts nothing back" "restored previous app bundle" "$out"
            assert_eq "this run's build stays installed" "$case_dir/home/tbd/updates/src" \
                "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
            assert_contains "so the rollback is not complete" \
                "ERROR: the rollback of the failed install did not complete" "$out"
            assert_contains "the report says the daemon's build is unknown" "daemon: build unknown" "$out"
            assert_not_contains "and names no build for it" "daemon: build $CASE_DAEMON_COMMIT" "$out"
            assert_not_contains "no app is launched" "^open" "$(cat "$events")"
            if [ -f "$case_dir/app" ]; then
                fail "the app stays stopped when the daemon's build is unknown"
            else
                pass "the app stays stopped when the daemon's build is unknown"
            fi
        else
            assert_contains "a stamped daemon's kept bundle goes back" "restored previous app bundle" "$out"
            assert_eq "the reported commit's bundle is installed" "the-reported-commit" \
                "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
            assert_contains "and the app is relaunched" \
                "relaunching the app this run stopped before the handover" "$out"
        fi
    done
}

# An earlier run interrupted after its swap left the new build (B) installed
# and .build/release linked to B's downloaded tree, with the daemon and the
# kept bundle still on A (1111…). A re-run of B whose handover fails puts the
# kept bundle A back and the link back on B's tree: each half puts back what
# the run found, and an app launched from A would start its next daemon
# from B. So the app is left stopped, with an error naming both builds and
# the report. When the link names a tree of A's build instead, the pair
# agrees and the app is relaunched. Relaunching on the two halves alone, as
# the run did, launches A in front of B's tree.
test_a_rollback_whose_bundle_and_link_disagree_leaves_the_app_stopped() {
    local tree_build case_dir out rc events installed kept link tree new_commit
    for tree_build in new daemons; do
        case_dir="$(mkcase "rollback-link-$tree_build")"
        events="$case_dir/events.log"
        installed="$case_dir/Applications/TBD.app"
        kept="$case_dir/home/tbd/updates/previous/TBD.app"
        link="$case_dir/home/tbd/updates/src/.build/release"
        new_commit="$(git -C "$case_dir/remote" rev-parse HEAD)"
        # A first run makes the clone; a dry run installs nothing.
        run_update "$case_dir" --dry-run >/dev/null
        if [ "$tree_build" = new ]; then
            tree="$case_dir/home/tbd/updates/prebuilt/$new_commit"
        else
            tree="$case_dir/home/tbd/updates/prebuilt/$CASE_DAEMON_COMMIT"
        fi
        mkdir -p "$tree" "$case_dir/Applications"
        rm -f "$link"
        ln -s "$tree" "$link"
        mkbundle "$installed" "left-by-the-interrupted-run" >/dev/null
        stamp_clone_identity "$installed" "$case_dir" "$new_commit"
        mkbundle "$kept" "the-daemons-build" >/dev/null
        stamp_clone_identity "$kept" "$case_dir" "$CASE_DAEMON_COMMIT"
        if [ "$tree_build" = new ]; then
            cp "$installed/Contents/TBDBuildIdentity.json" "$tree/TBDBuildIdentity.json"
        else
            cp "$kept/Contents/TBDBuildIdentity.json" "$tree/TBDBuildIdentity.json"
        fi
        out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
        assert_eq "a failed handover fails the run ($tree_build)" "1" "$rc"
        assert_contains "the keep was skipped ($tree_build)" "keeping no copy of it" "$out"
        assert_contains "the kept bundle goes back ($tree_build)" "restored previous app bundle" "$out"
        assert_eq "the daemon's build is installed ($tree_build)" "the-daemons-build" \
            "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
        assert_eq "the link goes back to the tree it named ($tree_build)" "$tree" "$(link_target "$link")"
        if [ "$tree_build" = new ]; then
            assert_contains_literal "the run says the bundle and the link name different builds" \
                "ERROR: $installed holds build $CASE_DAEMON_COMMIT from $case_dir/home/tbd/updates/src, but $link, from which an app launched from it starts a daemon, names $tree, build $new_commit from $case_dir/home/tbd/updates/src" \
                "$out"
            assert_contains "so the rollback is not complete" \
                "ERROR: the rollback of the failed install did not complete" "$out"
            assert_contains_literal "the report names the link's build" \
                "build directory $link, a link to $tree: build $new_commit" "$out"
            assert_contains "and gives the recovery steps" "to recover:" "$out"
            assert_not_contains "no app is launched" "^open" "$(cat "$events")"
            if [ -f "$case_dir/app" ]; then
                fail "the app stays stopped when the bundle and the link disagree"
            else
                pass "the app stays stopped when the bundle and the link disagree"
            fi
        else
            assert_not_contains "a bundle and link that agree raise nothing" \
                "from which an app launched from it starts a daemon" "$out"
            assert_not_contains "and the rollback completes" "did not complete" "$out"
            assert_contains "so the app is relaunched" \
                "relaunching the app this run stopped before the handover" "$out"
            assert_eq "once" "1" "$(grep -c '^open ' "$events")"
        fi
    done
}

# A re-run over the build the daemon runs finds that build installed. The
# keep keeps nothing, and a failed handover has nothing to put back: the
# installed bundle already matches the daemon, so the rollback counts as
# done and the app is relaunched. Keeping a copy and restoring it, as the
# run did, or leaving the app stopped for want of a kept bundle, fails.
test_a_failed_handover_over_the_daemons_build_restores_nothing() {
    local case_dir out rc events installed kept new_commit
    case_dir="$(mkcase rollback-over-the-daemons-build)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    new_commit="$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "installed-before-the-run" >/dev/null
    stamp_clone_identity "$installed" "$case_dir" "$new_commit"
    daemon_reports_commit "$case_dir" "$new_commit"
    mkbundle "$kept" "earlier-update" >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed handover fails the run" "1" "$rc"
    assert_contains "the keep was skipped" "keeping no copy of it" "$out"
    assert_contains_literal "the rollback finds the installed bundle matches the daemon" \
        "$installed is already build $new_commit from $case_dir/worktree, which the daemon runs — nothing to put back" "$out"
    assert_not_contains "nothing is restored" "restored previous app bundle" "$out"
    assert_eq "the earlier kept bundle stays" "earlier-update" \
        "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_not_contains "the rollback completes" "did not complete" "$out"
    assert_contains "and the app is relaunched" \
        "relaunching the app this run stopped before the handover" "$out"
    assert_eq "once" "1" "$(grep -c '^open ' "$events")"
}

# The rollback and the report compare whole builds — commit, source worktree
# and dirty flag, and a dirty build's build time — when the daemon reports
# them. Here the daemon and the installed bundle are one dirty build, from
# another worktree, of the commit the update installs, and the update
# installs the clone's clean build of it. A failed handover puts the kept
# bundle back in front of that daemon as its build,
# and an exit after the install gives the recovery steps. Comparing commits
# alone, as both did, takes the clone's build for the daemon's: the rollback
# puts nothing back and relaunches the new app, and the report says nothing
# needs recovering.
test_the_rollback_and_the_report_compare_whole_builds() {
    local how case_dir out rc events installed kept new_commit
    for how in fails interrupted; do
        case_dir="$(mkcase "whole-build-$how")"
        events="$case_dir/events.log"
        installed="$case_dir/Applications/TBD.app"
        kept="$case_dir/home/tbd/updates/previous/TBD.app"
        new_commit="$(git -C "$case_dir/remote" rev-parse HEAD)"
        mkdir -p "$case_dir/Applications"
        mkbundle "$installed" "the-daemons-build" >/dev/null
        stamp_clone_identity "$installed" "$case_dir" "$new_commit" "$case_dir/worktree" true \
            2026-01-02T03:04:05Z
        printf '{"buildIdentity": {"commit": "%s", "sourceWorktree": "%s", "dirty": true, "builtAt": "2026-01-02T03:04:05Z"}}\n' \
            "$new_commit" "$case_dir/worktree" > "$case_dir/state/status.json"
        if [ "$how" = fails ]; then
            out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
            assert_eq "a failed handover fails the run" "1" "$rc"
            assert_contains_literal "the installed bundle is kept, as another build" \
                "kept the previous app bundle at $kept" "$out"
            assert_not_contains "the clone's build is not taken for the daemon's" \
                "nothing to put back" "$out"
            assert_not_contains "the kept bundle is the daemon's build, so it needs no excuse" \
                "putting back the bundle this run replaced" "$out"
            assert_contains "the kept bundle goes back" "restored previous app bundle" "$out"
            assert_eq "the daemon's build is installed again" "the-daemons-build" \
                "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
            assert_contains "and the app is relaunched" \
                "relaunching the app this run stopped before the handover" "$out"
            assert_eq "once" "1" "$(grep -c '^open ' "$events")"
        else
            out="$(FAKE_REAL_INSTALL=1 FAKE_EXITS_AFTER_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
            assert_eq "the run exits with the status it left by" "6" "$rc"
            assert_contains_literal "the report gives the daemon's whole build" \
                "daemon: build $new_commit from $case_dir/worktree, dirty, built 2026-01-02T03:04:05Z" "$out"
            assert_contains_literal "and the installed bundle's" \
                "installed bundle at $installed: build $new_commit from $case_dir/home/tbd/updates/src" "$out"
            assert_not_contains "they differ, so it does not say nothing needs recovering" \
                "nothing needs recovering" "$out"
            assert_contains "it gives the recovery steps" "to recover:" "$out"
        fi
    done
}

# A bundle this run kept goes back after a failed handover even when no
# bundle is the daemon's build: the run copied it from the installed path, so
# it is the bundle that was installed when the run began. Requiring a kept
# bundle of the daemon's build, as the rollback did, leaves the new app
# installed and the app stopped. Two ways to miss: the kept bundle's identity
# names no commit (here), and a daemon whose build disagrees with it on a
# field (the next test).
test_a_failed_handover_restores_a_kept_bundle_with_no_build_identity() {
    local case_dir out rc events installed
    case_dir="$(mkcase rollback-kept-unidentified)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed handover fails the run" "1" "$rc"
    assert_contains_literal "the run kept the installed bundle" \
        "kept the previous app bundle at $case_dir/home/tbd/updates/previous/TBD.app" "$out"
    assert_contains "the rollback puts it back" "restored previous app bundle" "$out"
    assert_eq "the bundle from before the update is installed" "before-the-update" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_not_contains "the rollback completes" "did not complete" "$out"
    assert_contains "and the app is relaunched" \
        "relaunching the app this run stopped before the handover" "$out"
    assert_eq "once" "1" "$(grep -c '^open ' "$events")"
}

# A daemon whose build was read from its worktree rather than its stamp can
# disagree with every bundle on a field. Here it reports the installed
# bundle's commit and worktree, but clean where the bundle's identity says
# dirty. The bundle this run kept goes back all the same, with a line naming
# both builds, and the app is relaunched.
test_a_failed_handover_restores_the_kept_bundle_when_none_matches_the_daemon() {
    local case_dir out rc events installed kept new_commit
    case_dir="$(mkcase rollback-no-match)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    new_commit="$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "installed-before-the-run" >/dev/null
    stamp_clone_identity "$installed" "$case_dir" "$new_commit" "$case_dir/worktree" true
    printf '{"buildIdentity": {"commit": "%s", "sourceWorktree": "%s", "dirty": false}}\n' \
        "$new_commit" "$case_dir/worktree" > "$case_dir/state/status.json"
    out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed handover fails the run" "1" "$rc"
    assert_contains_literal "the run kept the installed bundle" "kept the previous app bundle at $kept" "$out"
    assert_contains_literal "the rollback says neither bundle is the daemon's build, and names both" \
        "neither $installed nor $kept is build $new_commit from $case_dir/worktree, which the daemon runs; putting back the bundle this run replaced, build $new_commit from $case_dir/worktree, dirty" \
        "$out"
    assert_contains "the kept bundle goes back" "restored previous app bundle" "$out"
    assert_eq "the bundle from before the update is installed" "installed-before-the-run" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_not_contains "the rollback completes" "did not complete" "$out"
    assert_contains "and the app is relaunched" \
        "relaunching the app this run stopped before the handover" "$out"
    assert_eq "once" "1" "$(grep -c '^open ' "$events")"
}

# The keep is skipped only for the build being installed. A bundle of the
# same commit that is another build, from another worktree (a restart.sh
# build), a dirty tree, or the other build configuration (here a --debug run
# over the clone's release build), is kept as any other, and so is one whose
# identity records no configuration. Skipping on the commit alone, as the
# keep did, kept nothing; skipping on commit, worktree and dirty flag, as it
# did next, loses the release bundle to a --debug run.
test_an_update_over_the_same_commit_keeps_another_build() {
    local variant case_dir out rc installed kept new_commit
    for variant in other-worktree dirty debug-run unconfigured; do
        case_dir="$(mkcase "same-commit-$variant")"
        installed="$case_dir/Applications/TBD.app"
        kept="$case_dir/home/tbd/updates/previous/TBD.app"
        new_commit="$(git -C "$case_dir/remote" rev-parse HEAD)"
        mkdir -p "$case_dir/Applications"
        mkbundle "$installed" "installed-before-the-run" >/dev/null
        mkbundle "$kept" "earlier-update" >/dev/null
        case "$variant" in
            other-worktree)
                stamp_clone_identity "$installed" "$case_dir" "$new_commit" "$case_dir/worktree" ;;
            dirty) stamp_clone_identity "$installed" "$case_dir" "$new_commit" "" true ;;
            debug-run) stamp_clone_identity "$installed" "$case_dir" "$new_commit" ;;
            unconfigured)
                printf '{"commit": "%s", "sourceWorktree": "%s", "dirty": false}\n' \
                    "$new_commit" "$case_dir/home/tbd/updates/src" \
                    > "$installed/Contents/TBDBuildIdentity.json"
                ;;
        esac
        if [ "$variant" = debug-run ]; then
            out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir" --debug)"; rc=$?
        else
            out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
        fi
        assert_eq "the update succeeds ($variant)" "0" "$rc"
        assert_not_contains "the keep is not skipped ($variant)" "keeping no copy of it" "$out"
        assert_contains_literal "the installed bundle is kept ($variant)" \
            "kept the previous app bundle at $kept" "$out"
        assert_eq "the kept bundle is the one installed before the run ($variant)" \
            "installed-before-the-run" "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    done
}

# A dirty tree's changes are not in its build identity, so two dirty builds
# of one commit and worktree are the same build only when their build times
# match too; a dirty build that names no build time matches none. Clean
# builds still match on commit, worktree and dirty flag alone, whatever their
# build times. Here the keep reads each pair: it keeps the installed bundle
# unless it is the build being installed. Matching dirty builds on the three
# fields alone, as the keep did, skips it for another build of the tree.
test_the_keep_tells_dirty_builds_apart_by_build_time() {
    local pair root out installed new kept wt
    for pair in dirty-other-time dirty-no-time dirty-same-time clean-other-time; do
        root="$TEST_TMP/keep-dirty-$pair"
        installed="$root/Applications/TBD.app"
        new="$root/new/TBD.app"
        kept="$root/updates/previous/TBD.app"
        wt="$root/worktree"
        mkdir -p "$root/Applications" "$root/updates"
        mkbundle "$installed" "installed-before-the-run" >/dev/null
        mkbundle "$new" "this-runs-build" >/dev/null
        case "$pair" in
            dirty-other-time)
                stamp_clone_identity "$installed" "$root" "$CASE_DAEMON_COMMIT" "$wt" true 2026-01-02T03:04:05Z
                stamp_clone_identity "$new" "$root" "$CASE_DAEMON_COMMIT" "$wt" true 2026-01-02T03:09:00Z
                ;;
            dirty-no-time)
                stamp_clone_identity "$installed" "$root" "$CASE_DAEMON_COMMIT" "$wt" true
                stamp_clone_identity "$new" "$root" "$CASE_DAEMON_COMMIT" "$wt" true
                ;;
            dirty-same-time)
                stamp_clone_identity "$installed" "$root" "$CASE_DAEMON_COMMIT" "$wt" true 2026-01-02T03:04:05Z
                stamp_clone_identity "$new" "$root" "$CASE_DAEMON_COMMIT" "$wt" true 2026-01-02T03:04:05Z
                ;;
            *)
                stamp_clone_identity "$installed" "$root" "$CASE_DAEMON_COMMIT" "$wt" false 2026-01-02T03:04:05Z
                stamp_clone_identity "$new" "$root" "$CASE_DAEMON_COMMIT" "$wt" false 2026-01-02T03:09:00Z
                ;;
        esac
        out="$(
            OPT_AUTO=false
            UPDATE_HOME="$root/updates"
            UPDATE_LOG="$root/updates/update.log"
            PREVIOUS_BUNDLE="$kept"
            keep_installed_bundle "$installed" "$new"
            printf 'rc=%s stashed=%s\n' "$?" "$BUNDLE_STASHED"
        )"
        case "$pair" in
            dirty-other-time | dirty-no-time)
                assert_contains "another dirty build of the tree is kept ($pair)" "rc=0 stashed=true" "$out"
                assert_not_contains "the keep is not skipped ($pair)" "keeping no copy of it" "$out"
                assert_eq "the kept bundle is the one installed before the run ($pair)" \
                    "installed-before-the-run" "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
                ;;
            *)
                assert_contains "the build being installed is not kept ($pair)" "rc=0 stashed=false" "$out"
                assert_contains_literal "the keep says why ($pair)" \
                    "$installed is already the build this run installs — keeping no copy of it" "$out"
                assert_eq "nothing is kept ($pair)" "gone" "$(path_state "$kept")"
                ;;
        esac
    done
}

# The rollback takes a dirty bundle for the daemon's build only at the
# daemon's build time. A daemon whose dirty build names no build time, as
# one whose identity was read from its worktree's HEAD does, matches no
# bundle. Taking either for a match, as the rollback did, says the installed
# bundle is already the daemon's build and puts nothing back.
test_the_rollback_tells_dirty_builds_apart_by_build_time() {
    local daemon root out installed kept wt built_at
    for daemon in other-time no-time same-time; do
        root="$TEST_TMP/rollback-dirty-$daemon"
        installed="$root/Applications/TBD.app"
        kept="$root/updates/previous/TBD.app"
        wt="$root/worktree"
        mkdir -p "$root/Applications" "$root/updates"
        mkbundle "$installed" "installed" >/dev/null
        stamp_clone_identity "$installed" "$root" "$CASE_DAEMON_COMMIT" "$wt" true 2026-01-02T03:04:05Z
        # Chosen here, not inside the command substitution below: bash 3.2
        # cannot parse a case pattern's unbalanced `)` inside `$( )`.
        case "$daemon" in
            other-time) built_at=', "builtAt": "2026-01-02T03:09:00Z"' ;;
            same-time) built_at=', "builtAt": "2026-01-02T03:04:05Z"' ;;
            *) built_at="" ;;
        esac
        out="$(
            OPT_AUTO=false
            UPDATE_HOME="$root/updates"
            UPDATE_LOG="$root/updates/update.log"
            PREVIOUS_BUNDLE="$kept"
            BUNDLE_STASHED=false
            BUNDLE_RESTORE_FAILED=false
            RUNNING_BUILD="$(build_key_of "{\"buildIdentity\": {\"commit\": \"$CASE_DAEMON_COMMIT\", \"sourceWorktree\": \"$wt\", \"dirty\": true$built_at}}" buildIdentity)"
            roll_back_bundle "$installed" 2>&1
            printf 'restore_failed=%s\n' "$BUNDLE_RESTORE_FAILED"
        )"
        case "$daemon" in
            other-time)
                assert_not_contains "a dirty build of another time is not the daemon's" \
                    "nothing to put back" "$out"
                assert_contains_literal "the rollback names the daemon's build with its time" \
                    "neither $installed nor $kept is build $CASE_DAEMON_COMMIT from $wt, dirty, built 2026-01-02T03:09:00Z, which the daemon runs, and this run kept none" \
                    "$out"
                assert_contains "and records that nothing went back" "restore_failed=true" "$out"
                ;;
            no-time)
                assert_not_contains "a dirty daemon build with no time matches no bundle" \
                    "nothing to put back" "$out"
                assert_contains_literal "the rollback names the daemon's build" \
                    "neither $installed nor $kept is build $CASE_DAEMON_COMMIT from $wt, dirty, which the daemon runs, and this run kept none" \
                    "$out"
                assert_contains "and records that nothing went back" "restore_failed=true" "$out"
                ;;
            *)
                assert_contains_literal "the same dirty build is the daemon's" \
                    "$installed is already build $CASE_DAEMON_COMMIT from $wt, dirty, built 2026-01-02T03:04:05Z, which the daemon runs — nothing to put back" \
                    "$out"
                assert_contains "and nothing is recorded as failed" "restore_failed=false" "$out"
                ;;
        esac
    done
}

# A run whose keep found its own build already installed, in front of a
# daemon on another commit, starts with app and daemon on different builds.
# Interrupted while it stages, it has installed nothing new, but the new app
# is still in front of the old daemon, and the report says so from what it
# reads: the installed build and the daemon's differ, so it gives the
# recovery steps. Reporting it as one that installed nothing and needs no
# recovery, as the report did from its step flags, fails.
test_an_interrupted_update_over_its_own_build_gives_the_recovery_steps() {
    local case_dir out rc events installed new_commit
    case_dir="$(mkcase interrupted-over-own-build)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    new_commit="$(git -C "$case_dir/remote" rev-parse HEAD)"
    mkdir -p "$case_dir/Applications" "$case_dir/tmp"
    mkbundle "$installed" "left-by-the-cut-short-run" >/dev/null
    stamp_clone_identity "$installed" "$case_dir" "$new_commit"
    mkbundle "$case_dir/home/tbd/updates/previous/TBD.app" "before-the-cut-short-run" >/dev/null
    out="$(TMPDIR="$case_dir/tmp" FAKE_REAL_INSTALL=1 FAKE_STAGE_COPY_INTERRUPTED=1 \
        run_update_around_handover "$case_dir")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "an interrupted run fails"
    else
        fail "an interrupted run fails"
    fi
    assert_contains "the keep was skipped" "keeping no copy of it" "$out"
    assert_contains_literal "the run was interrupted during the staging copy" \
        "-> $case_dir/Applications/.TBD-install-incoming at " "$(cat "$events")"
    assert_contains "it is reported as an interruption" \
        "ERROR: the run was interrupted while installing" "$out"
    assert_contains_literal "the report names the new build as installed" \
        "installed bundle at $installed: build $new_commit" "$out"
    assert_contains_literal "and the daemon's build" "daemon: build $CASE_DAEMON_COMMIT" "$out"
    assert_not_contains "so it does not say nothing needs recovering" "nothing needs recovering" "$out"
    assert_contains "it gives the recovery steps" "to recover:" "$out"
    assert_eq "the installed bundle is still the one the cut-short run left" \
        "left-by-the-cut-short-run" "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
}

# A run that leaves by `exit` (or a signal) while the installation is moving
# never reaches main's own rollback, and the exit trap cannot tell which
# bundle is installed or which daemon is serving. Launching the app there
# could pair a new app with an old daemon, the state the rollback exists to
# prevent, so the trap leaves the app stopped and says how to recover.
test_an_exit_mid_handover_leaves_the_app_stopped() {
    local case_dir out rc events
    case_dir="$(mkcase app-exit-mid-handover)"
    events="$case_dir/events.log"
    out="$(FAKE_HANDOVER_EXITS=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "the run exits with the status it left by" "3" "$rc"
    assert_contains "the app was stopped before the handover" "^pkill -f " "$(cat "$events")"
    assert_not_contains "the exit trap launches no app" "^open" "$(cat "$events")"
    if [ -f "$case_dir/app" ]; then
        fail "the app stays stopped when an update is interrupted mid-handover"
    else
        pass "the app stays stopped when an update is interrupted mid-handover"
    fi
    assert_not_contains "no relaunch is logged" \
        "relaunching the app this run stopped before the handover" "$out"
    assert_contains "the interruption is logged as an error" \
        "ERROR: the run was interrupted while installing" "$out"
    assert_contains "the log says the app was stopped and is not running" \
        "the app was stopped for the handover and is not running" "$out"
    assert_contains "the recovery starts from tbd version" "run 'tbd version'" "$out"
    assert_contains "the recovery offers another tbd update" "run 'tbd update' again" "$out"
    assert_contains_literal "the report says no bundle is kept" "kept bundle: none" "$out"
    assert_contains "the error reaches update.log too" \
        "ERROR: the run was interrupted while installing" \
        "$(cat "$case_dir/home/tbd/updates/update.log" 2>/dev/null)"
}

# Outside that window the exit trap still owes the app a relaunch. Once the
# handover has completed, bundle and daemon are the same new build, so a run
# that leaves by `exit` (or a signal) before its app stage brings the app back
# from the trap.
test_an_exit_after_the_handover_still_relaunches_the_app() {
    local case_dir out rc events handover launch
    case_dir="$(mkcase app-exit-after-handover)"
    events="$case_dir/events.log"
    out="$(FAKE_EXITS_BEFORE_APP_STAGE=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "the run exits with the status it left by" "4" "$rc"
    handover="$(first_line_starting "$events" "handover ")"
    launch="$(first_line_starting "$events" "open ")"
    assert_before "the exit trap relaunches the app after the completed handover" \
        "$handover" "$launch"
    assert_contains "the trap's relaunch is logged" \
        "relaunching the app this run stopped before the handover" "$out"
    assert_not_contains "a completed handover is not reported as interrupted" \
        "interrupted while installing" "$out"
    assert_eq "the trap launches it once" "1" "$(grep -c '^open ' "$events")"
    if [ -f "$case_dir/app" ]; then
        pass "the app is running when an update exits after its handover"
    else
        fail "the app is running when an update exits after its handover"
    fi
}

# The rollback after a failed handover is the one step that moves the
# installed bundle after the app stop, and a handover can fail within
# milliseconds of it, while macOS may still be reading the bundle for the
# app's exit. So the rollback waits for the exit to settle before it starts on
# the bundle. Here the settle is three seconds and the handover fails at once:
# the rollback's copy of the kept bundle must start at least two whole clock
# seconds after the stop returned (`date +%s` counts whole seconds, so three
# seconds can read as two), where without the wait it starts in the same
# second or the next. Under --no-app this run stopped no app, so no exit is
# being checked, and the same staged rollback runs without a wait.
test_a_rollback_waits_for_the_app_exit_to_settle() {
    local case_dir out rc events installed incoming kept stopped_at copied_at
    case_dir="$(mkcase rollback-settles)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    incoming="$case_dir/Applications/.TBD-install-incoming"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" "$CASE_DAEMON_COMMIT" >/dev/null
    out="$(TBD_UPDATE_APP_EXIT_SETTLE_SECONDS=3 FAKE_STAMP_STOP=1 FAKE_REAL_INSTALL=1 \
        FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed handover fails the run" "1" "$rc"
    assert_contains "the wait is logged" \
        "waiting [0-9]*s before putting the previous app bundle back at $installed: the app exited [0-9]*s ago" "$out"
    stopped_at="$(sed -n 's/^app-stop-returned at //p' "$events" | head -1)"
    copied_at="$(grep -F -- "copy $kept -> $incoming at " "$events" |
        sed -n 's/.* at \([0-9][0-9]*\) installed .*/\1/p' | head -1)"
    if [ -n "$stopped_at" ] && [ -n "$copied_at" ] && [ $((copied_at - stopped_at)) -ge 2 ]; then
        pass "the rollback starts on the bundle only once the settle has passed"
    else
        fail "the rollback starts on the bundle only once the settle has passed: stop returned at [$stopped_at], rollback copy at [$copied_at]"
    fi
    assert_before "the stop returns before the rollback copies the kept bundle" \
        "$(first_line_starting "$events" "app-stop-returned")" \
        "$(first_line_containing "$events" "copy $kept -> $incoming at ")"
    assert_eq "the rollback puts the bundle from before the update back" "before-the-update" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "the rollback leaves no sibling behind" "gone gone" \
        "$(path_state "$incoming") $(path_state "$case_dir/Applications/.TBD-install-outgoing")"
    assert_eq "the app this run stopped is relaunched once" "1" "$(grep -c '^open ' "$events")"

    case_dir="$(mkcase rollback-no-app)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    incoming="$case_dir/Applications/.TBD-install-incoming"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" "$CASE_DAEMON_COMMIT" >/dev/null
    out="$(TBD_UPDATE_APP_EXIT_SETTLE_SECONDS=3 FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 \
        run_update_around_handover "$case_dir" --no-app)"; rc=$?
    assert_eq "a failed handover fails the run (--no-app)" "1" "$rc"
    assert_not_contains "with no app stopped, the rollback does not wait (--no-app)" \
        "before putting the previous app bundle back" "$out"
    assert_eq "the rollback still stages the kept bundle beside the installed one (--no-app)" "1" \
        "$(grep -c -F -- "copy $kept -> $incoming at " "$events")"
    assert_contains "and puts it back (--no-app)" "restored previous app bundle" "$out"
    assert_eq "the bundle from before the update is installed (--no-app)" "before-the-update" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
}

# The wait that keeps a rename at the installed path clear of macOS's two
# checks of an app exit, as a function of the clock and of the interval the
# exit lies in. With the settle at 3 s and the second check at 31 s, an exit
# seen at 0 holds a rename until 4 s for the first check, then lets it
# through until 29 s, holds it from there until 34 s for the second, and lets
# it through for good after that. An exit not seen, known to lie in [0, 9],
# holds a rename until 13 s, then from 29 s until 43 s. A settle of 0 waits
# for nothing at the first check. Unset, the settle is 3 s and the second
# check 31 s, and a second check that is not a whole number reads as 31 s.
# The interval: [t, t] for an exit seen at t, [t, now] for a stop begun at t
# that did not see the exit, however long ago that was, and never past the
# clock. So a stop not seen to end, read long after it began, holds a rename
# for the whole second check from now: an app slow to quit can exit at any
# time after the stop began.
#
# The assertions run in this shell, not a subshell: `fail` records a failure
# in FAIL, and a subshell's FAIL never reaches the harness's exit status. The
# overrides and the record are local instead, so later cases still read the
# harness's.
test_the_app_exit_check_wait_keeps_renames_clear_of_both_checks() {
    local TBD_UPDATE_APP_EXIT_SETTLE_SECONDS=3 TBD_UPDATE_APP_EXIT_RECHECK_SECONDS=31
    local APP_EXIT_KIND APP_EXIT_AT pair now expected interval
    for pair in 0:4 2:2 4:0 28:0 29:5 31:3 33:1 34:0 121:0; do
        now="${pair%%:*}"
        expected="${pair#*:}"
        assert_eq "an exit seen at 0: a rename at ${now}s waits ${expected}s" "$expected" \
            "$(app_exit_check_wait "$now" 0 0)"
    done
    assert_eq "an exit not seen, in [0, 9]: a rename at 5s waits until 13s" "8" "$(app_exit_check_wait 5 0 9)"
    assert_eq "and one at 30s until 43s" "13" "$(app_exit_check_wait 30 0 9)"
    TBD_UPDATE_APP_EXIT_SETTLE_SECONDS=0
    assert_eq "a settle of 0 waits for nothing at the first check" "0" "$(app_exit_check_wait 0 0 0)"
    assert_eq "but still for the second" "5" "$(app_exit_check_wait 29 0 0)"
    TBD_UPDATE_APP_EXIT_SETTLE_SECONDS=3
    TBD_UPDATE_APP_EXIT_RECHECK_SECONDS=soon
    assert_eq "a second check that is not a whole number reads as 31 s" "3" "$(app_exit_check_wait 31 0 0)"
    assert_fail "a clock reading that is not a whole number is refused" app_exit_check_wait x 0 0
    # shellcheck disable=SC2016 # expanded by the inner bash
    assert_eq "unset, the settle is 3 s and the second check 31 s" "3 31 4 5" \
        "$(env -u TBD_UPDATE_APP_EXIT_SETTLE_SECONDS -u TBD_UPDATE_APP_EXIT_RECHECK_SECONDS \
            bash -c 'source "$1"; source "$2"; OPT_AUTO=true
                printf "%s %s %s %s\n" "$APP_EXIT_SETTLE_SECONDS" "$APP_EXIT_RECHECK_SECONDS" \
                    "$(app_exit_check_wait 0 0 0)" "$(app_exit_check_wait 29 0 0)"' \
            _ "$SCRIPT" "$HERE/restart-bundle-lib.sh")"

    TBD_UPDATE_APP_EXIT_RECHECK_SECONDS=31
    APP_EXIT_KIND=exited
    APP_EXIT_AT=100
    assert_eq "an exit seen at t lies at t" "100 100" "$(app_exit_interval 150)"
    APP_EXIT_KIND=stopping
    assert_eq "a stop not seen to end, read 3 s in: the exit is in [t, now]" "100 103" "$(app_exit_interval 103)"
    interval="$(app_exit_interval 200)"
    assert_eq "read 100 s in: still [t, now], with no bound for an app slow to quit" "100 200" "$interval"
    assert_eq "so a rename then waits the whole second check from now, 34 s" "34" \
        "$(app_exit_check_wait 200 "${interval% *}" "${interval#* }")"
    APP_EXIT_AT=200
    assert_eq "a stop recorded ahead of the clock reads as an exit now" "150 150" "$(app_exit_interval 150)"
    APP_EXIT_KIND=exited
    assert_eq "a record ahead of the clock reads as an exit now" "150 150" "$(app_exit_interval 150)"
}

# A rollback runs with the stopped app still down, so macOS's second check of
# its exit, about 31 s after it, can still come, and a handover can fail
# anywhere in its two-minute budget. A rollback that would land on that check
# waits it out before it renames anything. Here the settle is 1 s and the
# second check is moved to 3 s after the exit, so the rollback, which comes
# at once, waits out the settle to 2 s, finds itself in the window around the
# second check (1 s to 6 s), and waits until 6 s: its copy of the kept bundle
# starts at least 5 whole clock seconds after the stop returned. The settle
# alone, as the rollback waited, starts it 2 s after.
test_a_rollback_waits_out_the_second_check_of_the_app_exit() {
    local case_dir out rc events installed incoming kept stopped_at copied_at
    case_dir="$(mkcase rollback-second-check)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    incoming="$case_dir/Applications/.TBD-install-incoming"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" "$CASE_DAEMON_COMMIT" >/dev/null
    out="$(TBD_UPDATE_APP_EXIT_SETTLE_SECONDS=1 TBD_UPDATE_APP_EXIT_RECHECK_SECONDS=3 \
        FAKE_STAMP_STOP=1 FAKE_REAL_INSTALL=1 FAKE_HANDOVER_FAILS=1 \
        run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "a failed handover fails the run" "1" "$rc"
    assert_contains "the wait is logged with both checks" \
        "waiting [0-9]*s before putting the previous app bundle back at $installed: the app exited [0-9]*s ago, and macOS checks a quit app's bundle just after it quits and again about 3s later" \
        "$out"
    stopped_at="$(sed -n 's/^app-stop-returned at //p' "$events" | head -1)"
    copied_at="$(grep -F -- "copy $kept -> $incoming at " "$events" |
        sed -n 's/.* at \([0-9][0-9]*\) installed .*/\1/p' | head -1)"
    if [ -n "$stopped_at" ] && [ -n "$copied_at" ] && [ $((copied_at - stopped_at)) -ge 5 ]; then
        pass "the rollback starts on the bundle only once the second check is over"
    else
        fail "the rollback starts on the bundle only once the second check is over: stop returned at [$stopped_at], rollback copy at [$copied_at]"
    fi
    assert_contains "the kept bundle still goes back" "restored previous app bundle" "$out"
    assert_eq "the bundle from before the update is installed" "before-the-update" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "and the app is relaunched once" "1" "$(grep -c '^open ' "$events")"
}

# THE REGRESSION: a run that stops the app and is then killed leaves the app
# down with macOS's second check of its exit still to come, about 31 s after
# the exit, and nothing launches the app to call it off. A retry within that
# time swapped the installed bundle before its own stop, which found no app
# and waited for nothing. The stop now records the exit in
# ~/tbd/updates/app-exit, and an install that finds the app down waits out
# both checks of it. Here an exit is recorded as the run starts and the
# second check is moved to 2 s after it, so the install, which comes a
# second or two in, lands in the window around it (0 s to 5 s) and waits
# until 5 s: its staging copy starts at least 4 whole clock seconds after
# the exit. With the app running, it was launched since, so the record is
# forgotten and the install does not wait. Either way the record is gone
# once the run has launched the app.
test_a_retry_waits_out_the_checks_of_an_earlier_runs_exit() {
    local how case_dir out rc events installed incoming record exited_at copied_at
    for how in app-down app-running; do
        case_dir="$(mkcase "retry-after-a-killed-run-$how")"
        events="$case_dir/events.log"
        installed="$case_dir/Applications/TBD.app"
        incoming="$case_dir/Applications/.TBD-install-incoming"
        record="$case_dir/home/tbd/updates/app-exit"
        mkdir -p "$case_dir/Applications" "$(dirname "$record")"
        mkbundle "$installed" "before-the-update" "$CASE_DAEMON_COMMIT" >/dev/null
        exited_at="$(date +%s)"
        printf 'exited %s\n' "$exited_at" > "$record"
        if [ "$how" = app-down ]; then
            out="$(FAKE_APP_NOT_RUNNING=1 TBD_UPDATE_APP_EXIT_RECHECK_SECONDS=2 FAKE_REAL_INSTALL=1 \
                run_update_around_handover "$case_dir")"; rc=$?
        else
            out="$(TBD_UPDATE_APP_EXIT_RECHECK_SECONDS=2 FAKE_REAL_INSTALL=1 \
                run_update_around_handover "$case_dir")"; rc=$?
        fi
        assert_eq "the retry succeeds ($how)" "0" "$rc"
        assert_eq "the new build is installed ($how)" "$case_dir/home/tbd/updates/src" \
            "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
        assert_eq "the record is gone once the run has launched the app ($how)" "gone" \
            "$(path_state "$record")"
        if [ "$how" = app-running ]; then
            assert_not_contains "an app that is running has no exit pending, so nothing waits" \
                "before installing the new app bundle" "$out"
            continue
        fi
        assert_contains "the wait says why" \
            "waiting [0-9]*s before installing the new app bundle at $installed: the app exited [0-9]*s ago, and macOS checks a quit app's bundle just after it quits and again about 2s later" \
            "$out"
        copied_at="$(grep -F -- "-> $incoming at " "$events" |
            sed -n 's/.* at \([0-9][0-9]*\) installed .*/\1/p' | head -1)"
        if [ -n "$copied_at" ] && [ $((copied_at - exited_at)) -ge 4 ]; then
            pass "the install stages its bundle only once the earlier exit's second check is over"
        else
            fail "the install stages its bundle only once the earlier exit's second check is over: exit at [$exited_at], staging copy at [$copied_at]"
        fi
    done
}

# The exit record follows the app. A run that completes and launches the app
# leaves none. A run that stops the app and then exits inside the handover
# leaves the exit it saw. A run whose stop finds no app, and that then exits
# the same way, leaves an earlier run's record exactly as it found it; here
# that exit was 5 s ago, so the install, well short of its second check,
# does not wait. A record of a stop that did not see the exit begun 1 s ago
# makes the install wait by the interval: the exit lies anywhere up to the
# moment of the install, so with the second check moved to 2 s the install
# waits the whole 5 s from then. A record that does not parse is noted and
# removed.
test_the_exit_record_follows_the_app() {
    local how case_dir out rc record started ended line at seeded
    for how in completes exits-mid-handover none-found-then-exits stopping garbage; do
        case_dir="$(mkcase "exit-record-$how")"
        record="$case_dir/home/tbd/updates/app-exit"
        mkdir -p "$case_dir/Applications" "$(dirname "$record")"
        mkbundle "$case_dir/Applications/TBD.app" "before-the-update" "$CASE_DAEMON_COMMIT" >/dev/null
        started="$(date +%s)"
        case "$how" in
            completes)
                out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
                assert_eq "the run completes" "0" "$rc"
                assert_eq "a run that launches the app leaves no record" "gone" "$(path_state "$record")"
                ;;
            exits-mid-handover)
                out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_EXITS=1 run_update_around_handover "$case_dir")"
                ended="$(date +%s)"
                line="$(cat "$record" 2>/dev/null)"
                at="${line#exited }"
                if [ "$line" != "$at" ] && [ -n "$at" ] && [ "$at" -ge "$started" ] && [ "$at" -le "$ended" ]; then
                    pass "a run killed after its stop leaves the exit it saw"
                else
                    fail "a run killed after its stop leaves the exit it saw: record [$line], run from $started to $ended"
                fi
                ;;
            none-found-then-exits)
                seeded="exited $((started - 5))"
                printf '%s\n' "$seeded" > "$record"
                out="$(FAKE_APP_NOT_RUNNING=1 FAKE_REAL_INSTALL=1 FAKE_HANDOVER_EXITS=1 \
                    run_update_around_handover "$case_dir")"
                assert_contains "the stop finds no app" "no app running from" "$out"
                assert_not_contains "the install comes well short of the second check" \
                    "before installing the new app bundle" "$out"
                assert_eq "an earlier run's record survives a stop that finds no app" "$seeded" \
                    "$(cat "$record" 2>/dev/null)"
                ;;
            stopping)
                printf 'stopping %s\n' "$((started - 1))" > "$record"
                out="$(FAKE_APP_NOT_RUNNING=1 TBD_UPDATE_APP_EXIT_RECHECK_SECONDS=2 FAKE_REAL_INSTALL=1 \
                    run_update_around_handover "$case_dir")"; rc=$?
                assert_eq "the run completes (stopping)" "0" "$rc"
                assert_contains "an exit not seen waits by its interval, and says so" \
                    "waiting 5s before installing the new app bundle at $case_dir/Applications/TBD.app: the app was being stopped [0-9]*s ago and was not seen to exit, so it exited no earlier than that" \
                    "$out"
                assert_eq "the record is gone once the run has launched the app (stopping)" "gone" \
                    "$(path_state "$record")"
                ;;
            *)
                printf 'quit sometime\n' > "$record"
                out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
                assert_eq "the run completes (garbage)" "0" "$rc"
                assert_contains_literal "a record that does not parse is noted" \
                    "note: $record does not hold an app exit this run can read: [quit sometime]; removing it" "$out"
                assert_eq "and removed" "gone" "$(path_state "$record")"
                ;;
        esac
    done
}

# An exit with no usable time, as a clock that could not be read leaves it,
# must not read as an exit long past, or as one at the epoch's start, either
# of which waits for nothing. Recording it writes nothing: the file keeps the
# line it held, the WARNING says so, and the record in memory keeps the empty
# time. The wait point then waits out a whole second check from now, 34 s
# with the second check at 31 s, says why, and keeps the record, since
# nothing says that check is over. The second check stays at 31 s and the
# settle at 0, as in the rest of the harness, so the only thing that makes
# this wait is the missing time: read as an exit now, the record would wait
# 3 s with a second check of 0 s and nothing with one of 31 s. The wait is a
# stubbed `sleep` that prints its argument, and the app is not running, so
# nothing here waits or looks for a process.
test_an_exit_with_no_usable_time_waits_out_a_whole_second_check() {
    local root record out
    root="$TEST_TMP/exit-with-no-usable-time"
    record="$root/updates/app-exit"
    mkdir -p "$root/updates"
    printf 'exited 100\n' > "$record"
    out="$(
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        APP_EXIT_FILE="$record"
        INSTALLED_BUNDLE="$root/Applications/TBD.app"
        OPT_AUTO=false
        export TBD_UPDATE_APP_EXIT_SETTLE_SECONDS=0 TBD_UPDATE_APP_EXIT_RECHECK_SECONDS=31
        app_process_pid() { return 1; }
        sleep() { printf 'slept %s\n' "$1"; }
        record_app_exit exited ""
        printf 'recorded [%s] [%s]\n' "$APP_EXIT_KIND" "$APP_EXIT_AT"
        wait_out_app_exit_checks "installing the new app bundle"
        printf 'after the wait [%s] [%s]\n' "$APP_EXIT_KIND" "$APP_EXIT_AT"
    )"
    assert_contains_literal "an exit with no usable time is not written, and the WARNING says so" \
        "WARNING: the app's exit has no usable time [], so $record is left as it was" "$out"
    assert_eq "the file keeps the line it held" "exited 100" "$(cat "$record" 2>/dev/null)"
    assert_contains_literal "the record in memory keeps the empty time" "recorded [exited] []" "$out"
    assert_contains_literal "the wait point says why it waits in full" \
        "WARNING: the recorded exit has no usable time []; waiting 34s before installing the new app bundle" "$out"
    assert_contains_literal "and waits a whole second check from now, rather than for nothing" "slept 34" "$out"
    assert_contains_literal "and keeps the record" "after the wait [exited] []" "$out"
}

# An install that stops part-way leaves its siblings behind: a partial copy at
# .TBD-install-incoming, and, when it stopped between its two renames, the
# bundle it was replacing at .TBD-install-outgoing with nothing installed. The
# next install clears both before it does anything else, which is their only
# reclaimer, and puts an outgoing bundle back first when nothing is installed,
# since that is the last whole bundle there is. Two runs. Leftovers beside an
# installed bundle are removed, and the installed bundle is the one kept. An
# outgoing bundle with nothing installed is put back, so it is the one kept,
# rather than deleted with the rest.
test_an_update_clears_what_an_interrupted_install_left() {
    local case_dir out rc apps kept new_build
    case_dir="$(mkcase leftovers-beside-installed)"
    apps="$case_dir/Applications"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    new_build="$case_dir/home/tbd/updates/src"
    mkdir -p "$apps/.TBD-install-incoming/Contents"
    printf 'half' > "$apps/.TBD-install-incoming/Contents/half-copied"
    mkbundle "$apps/TBD.app" "before-the-update" >/dev/null
    mkbundle "$apps/.TBD-install-outgoing" "left-outgoing" >/dev/null
    FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir" >/dev/null; rc=$?
    assert_eq "an update beside leftovers succeeds" "0" "$rc"
    assert_eq "the new build is installed" "$new_build" \
        "$(cat "$apps/TBD.app/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "the bundle that was installed is the one kept, not the leftover" "before-the-update" \
        "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "both leftovers are gone" "gone gone" \
        "$(path_state "$apps/.TBD-install-incoming") $(path_state "$apps/.TBD-install-outgoing")"

    case_dir="$(mkcase leftovers-mid-swap)"
    apps="$case_dir/Applications"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    new_build="$case_dir/home/tbd/updates/src"
    mkdir -p "$apps/.TBD-install-incoming/Contents"
    printf 'half' > "$apps/.TBD-install-incoming/Contents/half-copied"
    mkbundle "$apps/.TBD-install-outgoing" "stopped-mid-swap" >/dev/null
    out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "an update after a run stopped mid-swap succeeds" "0" "$rc"
    assert_contains_literal "the outgoing bundle is put back, and the log says so" \
        "put back $apps/TBD.app from $apps/.TBD-install-outgoing" "$out"
    assert_eq "the bundle put back is the one kept" "stopped-mid-swap" \
        "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "the new build is installed (mid-swap)" "$new_build" \
        "$(cat "$apps/TBD.app/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "both leftovers are gone (mid-swap)" "gone gone" \
        "$(path_state "$apps/.TBD-install-incoming") $(path_state "$apps/.TBD-install-outgoing")"
}

# An exit while the installation moves is reported rather than rolled back,
# and the report says what it reads: the build the installed path holds,
# from its build identity, and the daemon's, which is the one it ran when
# the run started until the handover begins and unknown after. An exit
# before the swap leaves the build the run started with installed, and an
# app the run never stopped still running; one after the install leaves the
# new build, in front of the daemon the run started with. Neither installed
# build matches that daemon (1111…), so each report gives the recovery
# steps.
test_an_interrupted_install_reports_which_build_is_installed() {
    local case_dir out rc events installed old_commit new_commit
    old_commit=0000000000000000000000000000000000000000
    case_dir="$(mkcase interrupted-before-swap)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" "$old_commit" >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_EXITS_AFTER_KEEP=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "the run exits with the status it left by (before the swap)" "5" "$rc"
    assert_contains_literal "the report names the build from before the run" \
        "installed bundle at $installed: build $old_commit" "$out"
    assert_contains_literal "and the daemon's (before the swap)" \
        "daemon: build $CASE_DAEMON_COMMIT" "$out"
    assert_contains_literal "and the kept copy (before the swap)" \
        "kept bundle at $case_dir/home/tbd/updates/previous/TBD.app: build $old_commit" "$out"
    assert_contains "they differ, so it gives the recovery steps (before the swap)" "to recover:" "$out"
    assert_eq "that build is still installed" "before-the-update" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_not_contains "the app is never signalled (before the swap)" "^pkill" "$(cat "$events")"
    assert_not_contains "no app is launched (before the swap)" "^open" "$(cat "$events")"
    assert_not_contains "nothing claims the app was stopped (before the swap)" \
        "the app was stopped for the handover" "$out"
    if [ -f "$case_dir/app" ]; then
        pass "the app the run never stopped is still running"
    else
        fail "the app the run never stopped is still running"
    fi

    case_dir="$(mkcase interrupted-after-install)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" "$old_commit" >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_EXITS_AFTER_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
    new_commit="$(git -C "$case_dir/home/tbd/updates/src" rev-parse HEAD 2>/dev/null)"
    assert_eq "the run exits with the status it left by (after the install)" "6" "$rc"
    assert_contains_literal "the report names the new build as the one to install" \
        "new build: $new_commit" "$out"
    assert_contains_literal "and as installed (after the install)" \
        "installed bundle at $installed: build $new_commit" "$out"
    assert_contains_literal "in front of the daemon the run started with" \
        "daemon: build $CASE_DAEMON_COMMIT" "$out"
    assert_contains "and gives the recovery steps (after the install)" "run 'tbd update' again" "$out"
    assert_not_contains "the app is never signalled (after the install)" "^pkill" "$(cat "$events")"
    assert_not_contains "nothing is handed over (after the install)" "^handover" "$(cat "$events")"
    assert_not_contains "no app is launched (after the install)" "^open" "$(cat "$events")"
    if [ -f "$case_dir/app" ]; then
        pass "the app the run never stopped is still running (after the install)"
    else
        fail "the app the run never stopped is still running (after the install)"
    fi

    case_dir="$(mkcase interrupted-after-swap)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" "$old_commit" >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_EXITS=1 run_update_around_handover "$case_dir")"; rc=$?
    new_commit="$(git -C "$case_dir/home/tbd/updates/src" rev-parse HEAD 2>/dev/null)"
    assert_eq "the run exits with the status it left by (after the swap)" "3" "$rc"
    assert_contains_literal "the report names the new build as installed (after the swap)" \
        "installed bundle at $installed: build $new_commit" "$out"
    assert_contains_literal "and the daemon's build as unknown once the handover began" \
        "daemon: build unknown — the handover had begun" "$out"
    assert_contains "the app it stopped is left stopped" \
        "the app was stopped for the handover and is not running" "$out"
    assert_not_contains "no app is launched (after the swap)" "^open" "$(cat "$events")"

    # --no-app stops no app, and the begun handover alone makes the daemon's
    # build unknown.
    case_dir="$(mkcase interrupted-mid-handover-no-app)"
    installed="$case_dir/Applications/TBD.app"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" "$old_commit" >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_HANDOVER_EXITS=1 run_update_around_handover "$case_dir" --no-app)"; rc=$?
    assert_eq "the run exits with the status it left by (--no-app, mid-handover)" "3" "$rc"
    assert_contains_literal "the daemon's build is unknown (--no-app, mid-handover)" \
        "daemon: build unknown — the handover had begun" "$out"
    assert_not_contains "nothing claims the app was stopped (--no-app)" \
        "the app was stopped for the handover" "$out"
}

# The staging copy is the longest step before the swap, and it runs inside
# the library's install_app_bundle. A run interrupted there has moved nothing
# that runs: the installed bundle is the one from before the update and the
# app was never stopped. This is a local build, so the clone's .build/release
# already holds the new build, which an app that finds no daemon would start,
# and the report reads that too: it gives the recovery steps rather than
# saying nothing needs recovering (the release path, where the link goes
# back, is test_release_interrupted_staging_puts_the_link_back). Here the
# installed bundle is the daemon's build, so the link is the one fact that
# differs. Here the copy into the incoming sibling writes part of a tree and
# the run is sent SIGTERM.
test_an_interruption_while_staging_reports_that_nothing_was_installed() {
    local case_dir out rc events installed incoming new_commit
    case_dir="$(mkcase interrupted-while-staging)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    incoming="$case_dir/Applications/.TBD-install-incoming"
    mkdir -p "$case_dir/Applications" "$case_dir/tmp"
    mkbundle "$installed" "before-the-update" "$CASE_DAEMON_COMMIT" >/dev/null
    out="$(TMPDIR="$case_dir/tmp" FAKE_REAL_INSTALL=1 FAKE_STAGE_COPY_INTERRUPTED=1 \
        run_update_around_handover "$case_dir")"; rc=$?
    new_commit="$(git -C "$case_dir/home/tbd/updates/src" rev-parse HEAD 2>/dev/null)"
    if [ "$rc" -ne 0 ]; then
        pass "an interrupted run fails"
    else
        fail "an interrupted run fails"
    fi
    assert_contains_literal "the run was interrupted during the staging copy" \
        "-> $incoming at " "$(cat "$events")"
    assert_contains "it is reported as an interruption" \
        "ERROR: the run was interrupted while installing" "$out"
    assert_contains_literal "the installed bundle is the daemon's build" \
        "installed bundle at $installed: build $CASE_DAEMON_COMMIT" "$out"
    assert_contains_literal "the daemon is the one the run started with" \
        "daemon: build $CASE_DAEMON_COMMIT" "$out"
    assert_contains "the link holds the new build" \
        "build directory .*/\.build/release.*: build $new_commit" "$out"
    assert_not_contains "so it does not say nothing needs recovering" \
        "nothing needs recovering" "$out"
    assert_contains "it gives the recovery steps" "to recover:" "$out"
    assert_eq "the installed bundle is the one from before the update" "before-the-update" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_not_contains "the app is never signalled" "^pkill" "$(cat "$events")"
    assert_not_contains "no app is launched" "^open" "$(cat "$events")"
    assert_not_contains "nothing claims the app was stopped" \
        "the app was stopped for the handover" "$out"
    if [ -f "$case_dir/app" ]; then
        pass "the app the run never stopped is still running"
    else
        fail "the app the run never stopped is still running"
    fi
}

# An exit between the swap's two renames leaves the bundle that was installed
# at the outgoing name and nothing installed. The report renames it back,
# then reads what is installed: not the new build, so the .build/release link
# goes back to what it named when the run started. With the new build
# installed the link stays on it. Deciding by the step the install had
# reached, as the report did, left the link on the new build beside the old
# bundle.
test_an_interrupted_swap_puts_the_link_back_with_the_bundle() {
    local how root out installed link old_tree new_tree
    for how in mid-swap after-swap; do
        root="$TEST_TMP/interrupted-swap-link-$how"
        installed="$root/Applications/TBD.app"
        link="$root/src/.build/release"
        old_tree="$root/prebuilt/1111111111111111111111111111111111111111"
        new_tree="$root/prebuilt/2222222222222222222222222222222222222222"
        mkdir -p "$root/Applications" "$root/updates" "$old_tree" "$root/src/.build"
        mkbundle "$new_tree/TBD.app" "new-build" 2222222222222222222222222222222222222222 >/dev/null
        ln -s "$new_tree" "$link"
        if [ "$how" = mid-swap ]; then
            mkbundle "$root/Applications/.TBD-install-outgoing" "before-the-update" \
                1111111111111111111111111111111111111111 >/dev/null
        else
            cp -R "$new_tree/TBD.app" "$installed"
        fi
        out="$(
            OPT_AUTO=false
            UPDATE_HOME="$root/updates"
            UPDATE_LOG="$root/updates/update.log"
            PREVIOUS_BUNDLE="$root/updates/previous/TBD.app"
            INSTALLED_BUNDLE="$installed"
            RELEASE_LINK="$link"
            RELEASE_LINK_MOVED=true
            PREVIOUS_RELEASE_TARGET="$old_tree"
            INSTALLING_BUILD="$(bundle_build_key "$new_tree/TBD.app")"
            HANDOVER_STARTED=""
            report_interrupted_install 2>&1
        )"
        if [ "$how" = mid-swap ]; then
            assert_eq "the bundle that was installed is back" "before-the-update" \
                "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
            assert_eq "and the link goes back with it" "$old_tree" "$(link_target "$link")"
            assert_contains_literal "and says so" "pointed $link back at $old_tree" "$out"
        else
            assert_eq "the link stays on the new build beside it" "$new_tree" "$(link_target "$link")"
            assert_not_contains "and is not put back" "pointed .* back at" "$out"
        fi
    done
}

# Under --debug the run's own build is in .build/debug, where an app of that
# build starts a daemon from, so the report reads that directory. Here the
# installed bundle and .build/release hold the daemon's build, and
# .build/debug the new one: under --debug the report names .build/debug and
# gives the recovery steps, and for a release run the same state needs no
# recovering. Reading .build/release under --debug, as the report did, said
# nothing needed recovering.
test_the_report_reads_the_build_directory_of_the_runs_configuration() {
    local config root out src
    for config in debug release; do
        root="$TEST_TMP/report-build-dir-$config"
        src="$root/src"
        mkdir -p "$root/updates" "$root/Applications" "$src/.build/release" "$src/.build/debug"
        mkbundle "$root/Applications/TBD.app" "the-daemons-build" "$CASE_DAEMON_COMMIT" >/dev/null
        printf '{"commit": "%s"}\n' "$CASE_DAEMON_COMMIT" > "$src/.build/release/TBDBuildIdentity.json"
        printf '{"commit": "%s"}\n' 2222222222222222222222222222222222222222 \
            > "$src/.build/debug/TBDBuildIdentity.json"
        out="$(
            OPT_AUTO=false
            UPDATE_HOME="$root/updates"
            UPDATE_LOG="$root/updates/update.log"
            PREVIOUS_BUNDLE="$root/updates/previous/TBD.app"
            INSTALLED_BUNDLE="$root/Applications/TBD.app"
            RELEASE_LINK="$src/.build/release"
            BUILD_CONFIG="$config"
            HANDOVER_STARTED=""
            RUNNING_BUILD="$CASE_DAEMON_COMMIT||"
            INSTALLING_BUILD="2222222222222222222222222222222222222222||"
            report_installation_facts 2>&1
        )"
        if [ "$config" = debug ]; then
            assert_contains_literal "under --debug the report reads .build/debug" \
                "build directory $src/.build/debug: build 2222222222222222222222222222222222222222" "$out"
            assert_not_contains "and not .build/release" "build directory .*/\.build/release" "$out"
            assert_not_contains "so it does not say nothing needs recovering" \
                "nothing needs recovering" "$out"
            assert_contains "it gives the recovery steps" "to recover:" "$out"
        else
            assert_contains_literal "a release run reads .build/release" \
                "build directory $src/.build/release: build $CASE_DAEMON_COMMIT" "$out"
            assert_contains "where the daemon's build is, so nothing needs recovering" \
                "nothing needs recovering" "$out"
        fi
    done
}

# The stop before the handover records that it stopped an app only once it
# returns, which can take seconds of grace wait, and an exit in between used
# to read as "the app was not stopped": the report said TBD was still running
# the previous build and said nothing about the app, which had been signalled
# and may have gone. Here the run exits as the stop returns, before it
# records the app it stopped, with the new build installed.
test_an_exit_during_the_app_stop_says_the_app_may_be_stopped() {
    local case_dir out rc events installed new_commit
    case_dir="$(mkcase interrupted-during-stop)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" 0000000000000000000000000000000000000000 >/dev/null
    out="$(FAKE_REAL_INSTALL=1 FAKE_EXITS_DURING_STOP=1 run_update_around_handover "$case_dir")"; rc=$?
    assert_eq "the run exits with the status it left by (during the stop)" "7" "$rc"
    assert_contains "the app was signalled" "^pkill -f " "$(cat "$events")"
    if [ -f "$case_dir/app" ]; then
        fail "the app the stop signalled has exited"
    else
        pass "the app the stop signalled has exited"
    fi
    new_commit="$(git -C "$case_dir/home/tbd/updates/src" rev-parse HEAD 2>/dev/null)"
    assert_contains "the interruption is reported (during the stop)" \
        "ERROR: the run was interrupted while installing" "$out"
    assert_contains_literal "the report names the new build (during the stop)" \
        "installed bundle at $installed: build $new_commit" "$out"
    assert_not_contains "the report does not say the app was not stopped" \
        "the app was not stopped" "$out"
    assert_contains "it says the app may have been stopped and may not be running" \
        "the app may have been stopped and may not be running" "$out"
    assert_not_contains "no app is launched (during the stop)" "^open" "$(cat "$events")"
}

# THE REGRESSION: the keep deleted the bundle an earlier update had kept and
# copied straight into its place, so a run interrupted during that copy left a
# half-copied ~/tbd/updates/previous/TBD.app, the bundle the recovery steps
# and docs/updating.md send the operator to. A half-copied previous is worse
# than none. The copy now goes to a sibling and is renamed into place only
# once whole. Here the copy writes part of a tree and the run is sent SIGTERM
# before it copies anything else: what is kept is still the earlier update's
# bundle, whole, and nothing in /Applications has moved.
test_an_interrupted_keep_leaves_no_partial_previous_bundle() {
    local case_dir out rc events installed kept
    case_dir="$(mkcase keep-interrupted)"
    events="$case_dir/events.log"
    installed="$case_dir/Applications/TBD.app"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    mkdir -p "$case_dir/Applications" "$case_dir/tmp"
    mkbundle "$installed" "before-the-update" >/dev/null
    mkbundle "$kept" "earlier-update" >/dev/null
    out="$(TMPDIR="$case_dir/tmp" FAKE_REAL_INSTALL=1 FAKE_KEEP_COPY_INTERRUPTED=1 \
        run_update_around_handover "$case_dir")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "an interrupted run fails"
    else
        fail "an interrupted run fails"
    fi
    assert_contains_literal "the run was interrupted during the keep" \
        "copy $installed -> $case_dir/home/tbd/updates/previous/" "$(cat "$events")"
    assert_contains "the interruption is reported" \
        "ERROR: the run was interrupted while installing" "$out"
    assert_contains_literal "the report names the earlier update's bundle as kept" \
        "kept bundle at $kept: build" "$out"
    assert_eq "the kept bundle is still the earlier update's" "earlier-update" \
        "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    if [ -x "$kept/Contents/MacOS/TBDApp" ] && [ ! -e "$kept/Contents/half-copied" ]; then
        pass "the kept bundle is whole, not the half-copied tree"
    else
        fail "the kept bundle is whole, not the half-copied tree"
    fi
    assert_eq "the installed bundle has not moved" "before-the-update" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_not_contains "the app is never signalled (interrupted keep)" "^pkill" "$(cat "$events")"
}

# --no-app leaves the running app alone on both sides of the handover, and
# whether or not the handover completes: an app that stays alive owns its
# claims on the new daemon legitimately, and nothing that was never stopped
# needs relaunching.
test_no_app_never_stops_the_app() {
    local case_dir out how events
    case_dir="$(mkcase app-no-app)"
    events="$case_dir/events.log"
    for how in completes fails; do
        if [ "$how" = fails ]; then
            out="$(FAKE_HANDOVER_FAILS=1 run_update_around_handover "$case_dir" --no-app)"
        else
            out="$(run_update_around_handover "$case_dir" --no-app)"
        fi
        assert_contains "--no-app still hands over (handover $how)" "^handover " "$(cat "$events")"
        assert_not_contains "--no-app signals no app (handover $how)" "^pkill" "$(cat "$events")"
        assert_not_contains "--no-app launches no app (handover $how)" "^open" "$(cat "$events")"
        if [ -f "$case_dir/app" ]; then
            pass "--no-app leaves the app running (handover $how)"
        else
            fail "--no-app leaves the app running (handover $how)"
        fi
        assert_contains "--no-app says the app stays up (handover $how)" \
            "the running app stays up through the handover" "$out"
    done
}

# The number of the first line of <file> that contains <text>, or nothing.
first_line_containing() {
    grep -n -F -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

# THE REGRESSION: the handover counted as done as soon as `tbd daemon status`
# named the new binary. A local build runs the old daemon and the new one from
# the same file, so the old daemon's own answer passed on the first poll, while
# it was still inside its shutdown with every session already let go. The app
# relaunched then attached to the old daemon and was refused, and the wake
# stage read the fleet off it. Here the status names the installed executable
# from start to finish and the predecessor goes on running for three seconds
# after the handover starts: neither the launch nor the wake may come before it
# has exited.
test_the_app_and_the_wake_wait_for_the_predecessor_to_exit() {
    local case_dir out rc events log pid exited launch wake
    case_dir="$(mkcase handover-waits-for-predecessor)"
    events="$case_dir/events.log"
    log="$case_dir/home/tbd/updates/update.log"
    mkdir -p "$case_dir/Applications"
    report_installed_executable "$case_dir"
    start_predecessor "$case_dir" 3
    pid="$(predecessor_pid "$case_dir")"
    out="$(FAKE_REAL_HANDOVER=1 FAKE_HANDOVER_TIMEOUT=30 run_update_around_handover "$case_dir")"; rc=$?
    stop_predecessor "$case_dir"

    assert_eq "the update succeeds once the predecessor has gone" "0" "$rc"
    assert_contains "the run hands over from the predecessor" "handing over from daemon pid $pid" "$out"
    exited="$(first_line_starting "$events" "predecessor exited")"
    launch="$(first_line_starting "$events" "open ")"
    wake="$(first_line_starting "$events" "wake")"
    assert_before "the app is launched only after the predecessor has exited" "$exited" "$launch"
    assert_before "the wake stage runs only after the predecessor has exited" "$exited" "$wake"
    assert_before "the run logs the predecessor's exit before it calls the handover done" \
        "$(first_line_containing "$log" "the previous daemon (pid $pid) has exited")" \
        "$(first_line_containing "$log" "daemon is serving from")"
    if [ -f "$case_dir/app" ]; then
        pass "the app is running when the update ends"
    else
        fail "the app is running when the update ends"
    fi
}

# A predecessor that never exits never hands over, however the status reads.
# The status names the installed executable throughout, and the handover still
# fails once its budget is spent, down the same path as a successor that never
# reports itself: the successor is stopped, the bundle this run kept goes back,
# the app this run stopped is relaunched from it, and nothing is woken.
test_a_predecessor_that_never_exits_fails_the_handover() {
    local case_dir out rc events pid
    case_dir="$(mkcase handover-predecessor-never-exits)"
    events="$case_dir/events.log"
    mkdir -p "$case_dir/Applications"
    mkbundle "$case_dir/Applications/TBD.app" "before-the-update" >/dev/null
    report_installed_executable "$case_dir"
    start_predecessor "$case_dir" never
    pid="$(predecessor_pid "$case_dir")"
    out="$(FAKE_REAL_HANDOVER=1 FAKE_HANDOVER_TIMEOUT=2 run_update_around_handover "$case_dir")"; rc=$?
    stop_predecessor "$case_dir"

    assert_eq "a predecessor that never exits fails the run" "1" "$rc"
    assert_contains "the error names the predecessor that did not exit" \
        "ERROR: the previous daemon (pid $pid) is still running after 2s" "$out"
    assert_contains "and points at the new daemon's output" "the new daemon's output is in" "$out"
    assert_not_contains "the new daemon is never called the one serving" "daemon is serving from" "$out"
    assert_contains "the failure path stops the successor" \
        "so the rollback leaves no daemon from the new build: stopped" "$out"
    assert_contains "the bundle this run kept goes back" "restored previous app bundle" "$out"
    assert_eq "the installed bundle is the one from before the update" "before-the-update" \
        "$(cat "$case_dir/Applications/TBD.app/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_contains "the app this run stopped is relaunched" \
        "relaunching the app this run stopped before the handover" "$out"
    assert_eq "the app is launched once" "1" "$(grep -c '^open ' "$events")"
    assert_not_contains "nothing is woken after a failed handover" "^wake" "$(cat "$events")"
}

# A successor that dies at launch — a dyld error, a migration that throws —
# never retires its predecessor, so waiting for the predecessor to exit would
# sit out the whole budget with the app stopped. Its death ends the handover
# at once, down the failure path, long before a budget it is nowhere near.
test_a_successor_that_dies_fails_the_handover_at_once() {
    local case_dir out rc events pid started elapsed
    case_dir="$(mkcase handover-successor-dies)"
    events="$case_dir/events.log"
    mkdir -p "$case_dir/Applications"
    mkbundle "$case_dir/Applications/TBD.app" "before-the-update" >/dev/null
    report_installed_executable "$case_dir"
    start_predecessor "$case_dir" never
    pid="$(predecessor_pid "$case_dir")"
    started=$SECONDS
    out="$(FAKE_REAL_HANDOVER=1 FAKE_SUCCESSOR_EXITS=1 FAKE_HANDOVER_TIMEOUT=90 \
        run_update_around_handover "$case_dir")"; rc=$?
    elapsed=$((SECONDS - started))
    stop_predecessor "$case_dir"

    assert_eq "a successor that dies fails the run" "1" "$rc"
    assert_contains "the log says the successor died first" \
        "exited while the previous daemon (pid $pid) was still running" "$out"
    assert_not_contains "the run does not sit out the budget" "still running after 90s" "$out"
    if [ "$elapsed" -lt 60 ]; then
        pass "the run ends well inside the 90-second budget"
    else
        fail "the run ends well inside the 90-second budget: it took ${elapsed}s"
    fi
    assert_contains "the bundle this run kept goes back" "restored previous app bundle" "$out"
    assert_contains "the app this run stopped is relaunched" \
        "relaunching the app this run stopped before the handover" "$out"
    assert_not_contains "nothing is woken after a failed handover" "^wake" "$(cat "$events")"
}

# With no daemon running there is no predecessor to wait for. The pid file is
# absent, the successor starts cold, and the handover is done once the status
# names the installed executable.
test_a_cold_start_hands_over_without_a_predecessor() {
    local case_dir out rc events launch wake
    case_dir="$(mkcase handover-cold-start)"
    events="$case_dir/events.log"
    mkdir -p "$case_dir/Applications"
    report_installed_executable "$case_dir"
    rm -f "$case_dir/home/tbd/tbdd.pid"
    out="$(FAKE_REAL_HANDOVER=1 FAKE_HANDOVER_TIMEOUT=5 run_update_around_handover "$case_dir")"; rc=$?

    assert_eq "a cold start succeeds" "0" "$rc"
    assert_contains "it says it starts the new daemon cold" "starting the new one cold" "$out"
    assert_not_contains "it waits for no predecessor" "the previous daemon" "$out"
    assert_contains "the new daemon is serving" "daemon is serving from" "$out"
    launch="$(first_line_starting "$events" "open ")"
    wake="$(first_line_starting "$events" "wake")"
    assert_before "the app is launched, then the wake runs" "$launch" "$wake"
}

# MARK: - Installing and handing over

# A directory that looks enough like an assembled bundle for install and
# restore to move it around, with a build identity naming <commit> when one is
# given. It has an Info.plist and an executable TBDApp, which is what put-back
# checks for. Echoes its path.
#
#   mkbundle <dir> <marker> [commit]
mkbundle() {
    local dir="$1" marker="$2" commit="${3-}"
    mkdir -p "$dir/Contents/MacOS"
    printf '%s' "$marker" > "$dir/Contents/SourceWorktreePath.txt"
    printf '<plist version="1.0"><dict/></plist>\n' > "$dir/Contents/Info.plist"
    printf '#!/bin/sh\nexit 0\n' > "$dir/Contents/MacOS/TBDApp"
    chmod +x "$dir/Contents/MacOS/TBDApp"
    if [ -n "$commit" ]; then
        printf '{"commit": "%s"}\n' "$commit" > "$dir/Contents/TBDBuildIdentity.json"
    fi
    printf '%s\n' "$dir"
}

# `present` when anything is at <path>, `gone` otherwise.
path_state() {
    if [ -e "$1" ]; then echo present; else echo gone; fi
}

# A stand-in for `mv` at <bin>/mv, for a run with <bin> first on its PATH. It
# refuses the renames refuse_mv names, records each refusal in <bin>/mv.log
# as `refused mv <source>|<destination>`, and makes every other move with
# /bin/mv. In place of a rename interrupt_mv names, it sends the process that
# ran it SIGTERM, as an interruption at that point would, and records
# `interrupted mv <source>|<destination>`.
#
#   mkrefusingmv <bin>
mkrefusingmv() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/mv" << EOF
#!/bin/sh
pair="\$1|\$2"
if grep -qxF -- "\$pair" "$bin/mv-interrupts" 2>/dev/null; then
    printf 'interrupted mv %s\n' "\$pair" >> "$bin/mv.log"
    kill -TERM "\$PPID"
    exit 1
fi
if grep -qxF -- "\$pair" "$bin/mv-refuses" 2>/dev/null; then
    printf 'refused mv %s\n' "\$pair" >> "$bin/mv.log"
    exit 1
fi
if grep -qxF -- "\$pair" "$bin/mv-refuses-once" 2>/dev/null &&
    ! grep -qxF -- "\$pair" "$bin/mv-refused-once" 2>/dev/null; then
    printf '%s\n' "\$pair" >> "$bin/mv-refused-once"
    printf 'refused mv %s\n' "\$pair" >> "$bin/mv.log"
    exit 1
fi
exec /bin/mv "\$@"
EOF
    chmod +x "$bin/mv"
}

# Make the mv stub at <bin> (mkrefusingmv) refuse to rename <source> to
# <destination>: every time, or with `once`, the first time only.
#
#   refuse_mv <bin> <source> <destination> [once]
refuse_mv() {
    local bin="$1" source="$2" destination="$3" when="${4-}"
    if [ "$when" = once ]; then
        printf '%s|%s\n' "$source" "$destination" >> "$bin/mv-refuses-once"
    else
        printf '%s|%s\n' "$source" "$destination" >> "$bin/mv-refuses"
    fi
}

# Make the mv stub at <bin> (mkrefusingmv) interrupt the run in place of
# renaming <source> to <destination>.
#
#   interrupt_mv <bin> <source> <destination>
interrupt_mv() {
    printf '%s|%s\n' "$2" "$3" >> "$1/mv-interrupts"
}

# How many times the mv stub at <bin> refused to rename <source> to
# <destination>.
#
#   mv_refusals <bin> <source> <destination>
mv_refusals() {
    local count
    count="$(grep -cxF -- "refused mv $2|$3" "$1/mv.log" 2>/dev/null)"
    printf '%s\n' "${count:-0}"
}

# Write a stand-in successor daemon at <path>: a script that records its pid
# in <path>.pid and then becomes a copy of sleep named TBDDaemon, so that it
# stays up the way a daemon that started does, and daemon_process_is_running
# (and so stop_daemon_process) takes it for one.
mksuccessor() {
    local path="$1"
    local bin
    bin="$(dirname "$path")/successor-bin/TBDDaemon"
    mkdir -p "$(dirname "$bin")"
    cp "$(command -v sleep)" "$bin"
    cat > "$path" << EOF
#!/bin/sh
printf '%s\n' "\$\$" > "$path.pid"
exec "$bin" 60
EOF
    chmod +x "$path"
}

# Drive install_new_bundle and then hand_over_to_new_daemon, as main does with
# the app stop between them (there is no app here), against scratch paths,
# with a stub `tbd` whose reported executable decides whether the handover
# completes. The successor is <case_root>/newdaemon (mksuccessor), killed
# afterwards if it is still up.
run_install_and_handover() {
    local case_root="$1" reports="$2" timeout="$3"
    local state="$case_root/state"
    mkdir -p "$state"
    printf '{"executablePath":"%s"}\n' "$reports" > "$state/status.json"

    (
        export FAKE_TBD_STATE="$state" PATH="$case_root/bin:$PATH" \
            FAKE_LSREGISTER_LOG="$case_root/lsregister.log"
        OPT_AUTO=false
        UPDATE_HOME="$case_root/updates"
        UPDATE_LOG="$case_root/updates/update.log"
        PREVIOUS_BUNDLE="$case_root/updates/previous/TBD.app"
        TBD_HOME_DIR="$case_root"
        DAEMON_PID_FILE="$case_root/tbdd.pid"
        DAEMON_LOG="$case_root/tbdd.log"
        HANDOVER_TIMEOUT="$timeout"
        install_new_bundle "$case_root/new/TBD.app" "$case_root/Applications/TBD.app" &&
            hand_over_to_new_daemon "$case_root/Applications/TBD.app" "$case_root/newdaemon"
        printf 'rc=%s\n' "$?"
        printf 'bundle_restore_failed=%s\n' "$BUNDLE_RESTORE_FAILED"
    )
    stop_stand_in "$case_root/newdaemon.pid"
}

# The Medium finding this guards: the bundle used to be installed before the
# handover with nothing to undo it, so a handover that never completed left a
# new app driving the old daemon.
test_a_failed_handover_restores_the_previous_bundle() {
    local root out
    root="$TEST_TMP/handover-restore"
    mkdir -p "$root/bin" "$root/Applications"
    mkstub_tbd "$root/bin"
    mkbundle "$root/Applications/TBD.app" "old-worktree" >/dev/null
    mkbundle "$root/new/TBD.app" "new-clone" >/dev/null
    mksuccessor "$root/newdaemon"

    # The daemon that answers reports another binary, so the handover fails.
    out="$(run_install_and_handover "$root" "/somewhere/else/TBDDaemon" 1)"

    assert_contains "a handover that never completes fails the step" "rc=1" "$out"
    assert_contains "the failure says the previous bundle went back" \
        "restored previous app bundle" "$out"
    assert_contains "a restore that worked records no failure for main" \
        "bundle_restore_failed=false" "$out"
    assert_eq "the installed bundle is the one that was there before" \
        "old-worktree" \
        "$(cat "$root/Applications/TBD.app/Contents/SourceWorktreePath.txt")"
    if [ -d "$root/updates/previous/TBD.app" ]; then
        fail "restoring consumes the kept bundle"
    else
        pass "restoring consumes the kept bundle"
    fi
    assert_contains "the restored bundle is re-registered with LaunchServices" \
        "lsregister -f $root/Applications/TBD.app" \
        "$(cat "$root/lsregister.log" 2>/dev/null)"
    assert_not_contains "a registration that worked is not reported as failed" \
        "could not register" "$out"
}

# Registering the restored bundle with LaunchServices changes nothing about
# what is installed, so a registration that fails fails nothing: the rollback
# still puts the previous bundle back and counts as done. But the line that
# reports the restore says the bundle is not registered, where it used to
# report a plain restore. Here every lsregister call fails.
test_a_rollback_says_when_the_restored_bundle_is_not_registered() {
    local root out
    root="$TEST_TMP/handover-restore-unregistered"
    mkdir -p "$root/bin" "$root/Applications"
    mkstub_tbd "$root/bin"
    cat > "$root/failing-lsregister" << 'EOF'
#!/bin/sh
printf 'lsregister %s\n' "$*" >> "${FAKE_LSREGISTER_LOG:-/dev/null}"
exit 1
EOF
    chmod +x "$root/failing-lsregister"
    mkbundle "$root/Applications/TBD.app" "old-worktree" >/dev/null
    mkbundle "$root/new/TBD.app" "new-clone" >/dev/null
    mksuccessor "$root/newdaemon"

    # The daemon that answers reports another binary, so the handover fails.
    out="$(TBD_LSREGISTER="$root/failing-lsregister" \
        run_install_and_handover "$root" "/somewhere/else/TBDDaemon" 1 2>/dev/null)"

    assert_contains "a handover that never completes fails the step" "rc=1" "$out"
    assert_contains_literal "the restore says LaunchServices could not register the bundle" \
        "restored previous app bundle, but LaunchServices could not register it" "$out"
    assert_contains "a registration that fails is no failed restore" \
        "bundle_restore_failed=false" "$out"
    assert_eq "the previous bundle is installed" "old-worktree" \
        "$(cat "$root/Applications/TBD.app/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_contains_literal "the restored bundle was offered to LaunchServices" \
        "lsregister -f $root/Applications/TBD.app" "$(cat "$root/lsregister.log" 2>/dev/null)"
}

# THE REGRESSION: once the rollback had put the kept bundle back, it deleted
# the kept copy where it sat, so a delete cut short left part of a tree at
# ~/tbd/updates/previous/TBD.app, the bundle the recovery steps and
# docs/updating.md send the operator to. The copy is now renamed to the
# discard sibling first and deleted there. Here an `rm` that removes nothing
# under ~/tbd/updates/previous/ stands in for that delete cut short: the
# rollback still puts the bundle back, nothing is left at the kept name, the
# tree waits at the discard name, and no rm is ever aimed at the kept name.
# Deleting in place leaves the tree at the kept name, and fails.
test_a_rollback_never_deletes_the_kept_bundle_in_place() {
    local root out kept discard
    root="$TEST_TMP/handover-restore-delete-fails"
    kept="$root/updates/previous/TBD.app"
    discard="$root/updates/previous/.TBD.app.discard"
    mkdir -p "$root/bin" "$root/Applications"
    mkstub_tbd "$root/bin"
    cat > "$root/bin/rm" << EOF
#!/bin/sh
case "\$*" in
    *"$root/updates/previous/"*)
        printf 'rm %s\n' "\$*" >> "$root/rm.log"
        exit 1
        ;;
esac
exec /bin/rm "\$@"
EOF
    chmod +x "$root/bin/rm"
    mkbundle "$root/Applications/TBD.app" "old-worktree" >/dev/null
    mkbundle "$root/new/TBD.app" "new-clone" >/dev/null
    mksuccessor "$root/newdaemon"

    # The daemon that answers reports another binary, so the handover fails.
    out="$(run_install_and_handover "$root" "/somewhere/else/TBDDaemon" 1)"

    assert_contains "the failed handover puts the previous bundle back" \
        "restored previous app bundle" "$out"
    assert_contains "a delete that fails is no failed restore" \
        "bundle_restore_failed=false" "$out"
    assert_eq "the installed bundle is the one that was there before" "old-worktree" \
        "$(cat "$root/Applications/TBD.app/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "nothing is left at the kept name, though nothing was deleted" "gone" \
        "$(path_state "$kept")"
    assert_eq "the spent copy waits at the discard name" "old-worktree" \
        "$(cat "$discard/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_not_contains "no rm is aimed at the kept name" \
        "^rm -rf $kept\$" "$(cat "$root/rm.log" 2>/dev/null)"
    assert_contains_literal "the rm is aimed at the discard name" \
        "rm -rf $discard" "$(cat "$root/rm.log" 2>/dev/null)"
}

# A rollback whose swap leaves nothing installed (install_app_bundle's status
# 2) gets the second try at the rename back, and the warning, that an
# install's does. Here the kept bundle is the daemon's build, so the
# rollback stages it, and the mv stub refuses its rename into place and the
# rename back: every time, then only the first time. Reporting only that the
# restore failed, as the rollback did, leaves the installed path empty with
# no second try and no warning.
test_a_rollback_whose_swap_leaves_nothing_installed_retries_and_warns() {
    local how root out installed incoming outgoing kept
    for how in always once; do
        root="$TEST_TMP/rollback-leaves-nothing-$how"
        installed="$root/Applications/TBD.app"
        incoming="$root/Applications/.TBD-install-incoming"
        outgoing="$root/Applications/.TBD-install-outgoing"
        kept="$root/updates/previous/TBD.app"
        mkdir -p "$root/Applications"
        mkbundle "$installed" "new-build" >/dev/null
        mkbundle "$kept" "the-daemons-build" "$CASE_DAEMON_COMMIT" >/dev/null
        mkrefusingmv "$root/bin"
        refuse_mv "$root/bin" "$incoming" "$installed"
        if [ "$how" = once ]; then
            refuse_mv "$root/bin" "$outgoing" "$installed" once
        else
            refuse_mv "$root/bin" "$outgoing" "$installed"
        fi
        out="$(
            export PATH="$root/bin:$PATH"
            OPT_AUTO=false
            UPDATE_HOME="$root/updates"
            UPDATE_LOG="$root/updates/update.log"
            PREVIOUS_BUNDLE="$kept"
            RUNNING_BUILD="$CASE_DAEMON_COMMIT||"
            roll_back_bundle "$installed" 2>&1
            printf 'restore_failed=%s\n' "$BUNDLE_RESTORE_FAILED"
        )"
        assert_eq "the swap's rename into place is refused ($how)" "1" \
            "$(mv_refusals "$root/bin" "$incoming" "$installed")"
        assert_contains_literal "the restore fails ($how)" \
            "could not put the previous app bundle back from $kept" "$out"
        assert_contains "and is recorded for main ($how)" "restore_failed=true" "$out"
        assert_eq "the kept bundle is not spent ($how)" "the-daemons-build" \
            "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
        if [ "$how" = once ]; then
            assert_eq "the swap's own rename back is the one refused (once)" "1" \
                "$(mv_refusals "$root/bin" "$outgoing" "$installed")"
            assert_eq "the second try puts the bundle that was installed back" "new-build" \
                "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
            assert_contains_literal "and says so" \
                "the bundle that was installed there is back in place, renamed back from $outgoing on a second try" "$out"
            assert_not_contains "with no warning" "WARNING: nothing is installed" "$out"
        else
            assert_eq "the rename back is refused, and refused again when it is retried" "2" \
                "$(mv_refusals "$root/bin" "$outgoing" "$installed")"
            assert_eq "nothing is installed" "gone" "$(path_state "$installed")"
            assert_contains_literal "a warning says not to quit TBD until a bundle is back" \
                "WARNING: nothing is installed at $installed. Do not quit TBD until a whole bundle is back there" "$out"
            assert_contains_literal "and names the rename back, its paths quoted" \
                "Put back the bundle that was installed with: mv \"$outgoing\" \"$installed\"" "$out"
        fi
    done
}

# A keep renames the bundle an earlier update kept to the discard name, then
# renames its own copy into place. When that last rename fails, the earlier
# bundle goes back to its own name: the run installs nothing, so it is still
# the route back, and left at the discard name the next keep would delete it.
# The mv stub refuses only that last rename here. Returning without moving
# the earlier bundle back leaves it at the discard name, and fails.
test_a_failed_keep_puts_the_earlier_kept_bundle_back() {
    local root out installed kept partial discard
    root="$TEST_TMP/keep-rename-fails"
    installed="$root/Applications/TBD.app"
    kept="$root/updates/previous/TBD.app"
    partial="$root/updates/previous/.TBD.app.partial"
    discard="$root/updates/previous/.TBD.app.discard"
    mkdir -p "$root/Applications"
    mkbundle "$installed" "installed-now" >/dev/null
    mkbundle "$kept" "earlier-update" >/dev/null
    mkrefusingmv "$root/bin"
    refuse_mv "$root/bin" "$partial" "$kept"

    out="$(
        export PATH="$root/bin:$PATH"
        OPT_AUTO=false
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        PREVIOUS_BUNDLE="$kept"
        keep_installed_bundle "$installed"
        printf 'rc=%s stashed=%s\n' "$?" "$BUNDLE_STASHED"
    )"

    assert_eq "the keep's last rename is the one refused" "1" \
        "$(mv_refusals "$root/bin" "$partial" "$kept")"
    assert_contains "a keep whose last rename fails fails, and keeps nothing" \
        "rc=1 stashed=false" "$out"
    assert_contains "and says it installs nothing" "installing nothing" "$out"
    assert_eq "the earlier kept bundle is back under its own name" "earlier-update" \
        "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "nothing waits at the discard name for the next keep to delete" "gone" \
        "$(path_state "$discard")"
    assert_eq "the copy is removed" "gone" "$(path_state "$partial")"
    assert_eq "the installed bundle is untouched" "installed-now" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
}

# A keep cut short between its two renames leaves nothing at the kept path,
# the earlier kept bundle at the discard name and its own whole copy at the
# partial name. The next keep renames the earlier bundle back before it
# clears either sibling, whatever it does after: here it finds nothing
# installed and keeps nothing of its own, so the earlier bundle is the only
# route back. Clearing the siblings first, as the keep did, deletes it. A
# discard tree with no partial beside it is one a delete was working
# through, and is never put back.
test_the_next_keep_puts_back_a_kept_bundle_left_at_the_discard_name() {
    local root out kept partial discard
    root="$TEST_TMP/keep-after-interrupted-renames"
    kept="$root/updates/previous/TBD.app"
    partial="$root/updates/previous/.TBD.app.partial"
    discard="$root/updates/previous/.TBD.app.discard"
    mkbundle "$discard" "earlier-update" >/dev/null
    mkbundle "$partial" "copy-of-the-installed-bundle" >/dev/null
    out="$(
        OPT_AUTO=false
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        PREVIOUS_BUNDLE="$kept"
        keep_installed_bundle "$root/Applications/TBD.app"
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "the keep succeeds" "rc=0" "$out"
    assert_eq "the earlier kept bundle is back under its own name" "earlier-update" \
        "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "nothing is left at the discard name" "gone" "$(path_state "$discard")"
    assert_contains_literal "the keep says it put it back" \
        "put back $kept from $discard, where an interrupted keep had left it" "$out"

    root="$TEST_TMP/keep-after-interrupted-delete"
    kept="$root/updates/previous/TBD.app"
    discard="$root/updates/previous/.TBD.app.discard"
    mkbundle "$discard" "spent-copy" >/dev/null
    out="$(
        OPT_AUTO=false
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        PREVIOUS_BUNDLE="$kept"
        keep_installed_bundle "$root/Applications/TBD.app"
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "the keep succeeds (delete in progress)" "rc=0" "$out"
    assert_eq "a discard tree with no partial beside it is not put back" "gone" "$(path_state "$kept")"
    assert_not_contains "nor said to be" "put back $kept" "$out"
}

# When the earlier kept bundle cannot be renamed back from the discard name,
# that name holds its only copy, and the keep's clearing of the siblings
# would delete the very path the warning just named. So the keep fails and
# the run installs nothing, and the bundle stays where it is. Ignoring the
# failure and clearing, as the keep did, deletes it, and fails here. The mv
# stub refuses the rename back.
test_a_keep_that_cannot_put_back_the_discarded_bundle_deletes_nothing() {
    local root out installed kept partial discard
    root="$TEST_TMP/keep-cannot-put-back"
    installed="$root/Applications/TBD.app"
    kept="$root/updates/previous/TBD.app"
    partial="$root/updates/previous/.TBD.app.partial"
    discard="$root/updates/previous/.TBD.app.discard"
    mkdir -p "$root/Applications"
    mkbundle "$installed" "installed-now" >/dev/null
    mkbundle "$discard" "earlier-update" >/dev/null
    mkbundle "$partial" "copy-of-the-installed-bundle" >/dev/null
    mkrefusingmv "$root/bin"
    refuse_mv "$root/bin" "$discard" "$kept"
    out="$(
        export PATH="$root/bin:$PATH"
        OPT_AUTO=false
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        PREVIOUS_BUNDLE="$kept"
        keep_installed_bundle "$installed"
        printf 'rc=%s stashed=%s\n' "$?" "$BUNDLE_STASHED"
    )"
    assert_eq "the rename back is the one refused" "1" "$(mv_refusals "$root/bin" "$discard" "$kept")"
    assert_contains "the keep fails, and keeps nothing" "rc=1 stashed=false" "$out"
    assert_contains_literal "a warning names where the bundle is" \
        "WARNING: the bundle an earlier update kept is at $discard" "$out"
    assert_contains "and the run installs nothing" "installing nothing" "$out"
    assert_eq "the earlier kept bundle is still at the discard name" "earlier-update" \
        "$(cat "$discard/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "the installed bundle is untouched" "installed-now" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
}

# When the keep's last rename fails, the earlier kept bundle goes back to its
# own name before the copy at the partial name goes. Until then the partial
# marks the state put_back_discarded_kept_bundle recognises, so a keep cut
# short in between, or a rename back that fails, leaves the earlier bundle
# for the next keep, or the report of the interruption, to put back.
# Removing the partial first, as the keep did, leaves the earlier bundle at
# the discard name with nothing marking it, and the next keep deletes it.
# The mv stub refuses the last rename, then in place of the rename back cuts
# the keep short, or refuses it; a put-back with no stub follows.
test_a_failed_keep_leaves_the_earlier_bundle_recoverable_until_it_is_back() {
    local how root out installed kept partial discard
    for how in interrupted refused; do
        root="$TEST_TMP/keep-put-back-$how"
        installed="$root/Applications/TBD.app"
        kept="$root/updates/previous/TBD.app"
        partial="$root/updates/previous/.TBD.app.partial"
        discard="$root/updates/previous/.TBD.app.discard"
        mkdir -p "$root/Applications"
        mkbundle "$installed" "installed-now" >/dev/null
        mkbundle "$kept" "earlier-update" >/dev/null
        mkrefusingmv "$root/bin"
        refuse_mv "$root/bin" "$partial" "$kept"
        if [ "$how" = interrupted ]; then
            interrupt_mv "$root/bin" "$discard" "$kept"
        else
            refuse_mv "$root/bin" "$discard" "$kept"
        fi
        out="$(
            export PATH="$root/bin:$PATH"
            OPT_AUTO=false
            UPDATE_HOME="$root/updates"
            UPDATE_LOG="$root/updates/update.log"
            PREVIOUS_BUNDLE="$kept"
            keep_installed_bundle "$installed"
        )"
        assert_contains_literal "the rename back is the step cut short or refused ($how)" \
            "$how mv $discard|$kept" "$(cat "$root/bin/mv.log" 2>/dev/null)"
        assert_eq "the earlier bundle is at the discard name ($how)" "earlier-update" \
            "$(cat "$discard/Contents/SourceWorktreePath.txt" 2>/dev/null)"
        assert_eq "with the copy still at the partial name beside it ($how)" "present" \
            "$(path_state "$partial")"
        if [ "$how" = refused ]; then
            assert_contains_literal "the keep warns where the earlier bundle is" \
                "WARNING: the bundle an earlier update kept is at $discard" "$out"
        fi
        (
            OPT_AUTO=false
            UPDATE_HOME="$root/updates"
            UPDATE_LOG="$root/updates/update.log"
            PREVIOUS_BUNDLE="$kept"
            put_back_discarded_kept_bundle
        ) >/dev/null
        assert_eq "the put-back that follows restores it ($how)" "earlier-update" \
            "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    done
}

# THE REGRESSION: a run cut short between the keep's two renames left the
# bundle an earlier update kept at the discard name, with nothing at
# ~/tbd/updates/previous/TBD.app where the docs send the operator, and the
# report said nothing needed recovering. The report now renames it back
# first. Here the stand-in mv sends the run SIGTERM in place of the keep's
# second rename.
test_an_interruption_between_the_keeps_renames_puts_the_kept_bundle_back() {
    local case_dir out rc installed kept partial discard
    case_dir="$(mkcase interrupted-between-keep-renames)"
    installed="$case_dir/Applications/TBD.app"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    partial="$case_dir/home/tbd/updates/previous/.TBD.app.partial"
    discard="$case_dir/home/tbd/updates/previous/.TBD.app.discard"
    mkdir -p "$case_dir/Applications"
    mkbundle "$installed" "before-the-update" >/dev/null
    mkbundle "$kept" "earlier-update" >/dev/null
    mkrefusingmv "$case_dir/bin"
    interrupt_mv "$case_dir/bin" "$partial" "$kept"
    out="$(FAKE_REAL_INSTALL=1 run_update_around_handover "$case_dir")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "an interrupted run fails"
    else
        fail "an interrupted run fails"
    fi
    assert_contains_literal "the run was interrupted between the keep's renames" \
        "interrupted mv $partial|$kept" "$(cat "$case_dir/bin/mv.log" 2>/dev/null)"
    assert_eq "the earlier kept bundle is back under its own name" "earlier-update" \
        "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "nothing is left at the discard name" "gone" "$(path_state "$discard")"
    assert_contains_literal "the report says it put it back" \
        "put back $kept from $discard, where an interrupted keep had left it" "$out"
    assert_contains_literal "and names it as the kept bundle" "kept bundle at $kept: build" "$out"
    assert_eq "the installed bundle is the one from before the update" "before-the-update" \
        "$(cat "$installed/Contents/SourceWorktreePath.txt" 2>/dev/null)"
}

# The report renames the earlier kept bundle back whatever else fails. Here
# the .build/release link cannot be put back either, and the recovery steps
# send the operator to the kept bundle, so it has to be at
# ~/tbd/updates/previous/TBD.app, where they name it. Renaming it back only
# when the link went back too, as the report did, leaves it at the discard
# name here, and fails.
test_an_interruption_between_the_keeps_renames_with_the_link_stuck_puts_the_kept_bundle_back() {
    local case_dir out rc kept partial discard
    case_dir="$(mkcase interrupted-between-keep-renames-link-stuck)"
    kept="$case_dir/home/tbd/updates/previous/TBD.app"
    partial="$case_dir/home/tbd/updates/previous/.TBD.app.partial"
    discard="$case_dir/home/tbd/updates/previous/.TBD.app.discard"
    mkdir -p "$case_dir/Applications"
    mkbundle "$case_dir/Applications/TBD.app" "before-the-update" >/dev/null
    mkbundle "$kept" "earlier-update" >/dev/null
    mkrefusingmv "$case_dir/bin"
    interrupt_mv "$case_dir/bin" "$partial" "$kept"
    out="$(FAKE_REAL_INSTALL=1 FAKE_LINK_PUT_BACK_FAILS=1 run_update_around_handover "$case_dir")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "an interrupted run fails"
    else
        fail "an interrupted run fails"
    fi
    assert_contains "the link put-back fails" "ERROR: could not point .* back at" "$out"
    assert_contains "the interruption is reported" \
        "ERROR: the run was interrupted while installing" "$out"
    assert_contains_literal "whose recovery steps name the kept bundle" \
        "or put back the bundle kept at $kept" "$out"
    assert_eq "which is back under its own name" "earlier-update" \
        "$(cat "$kept/Contents/SourceWorktreePath.txt" 2>/dev/null)"
    assert_eq "nothing is left at the discard name" "gone" "$(path_state "$discard")"
    assert_contains_literal "and the report says it put it back" \
        "put back $kept from $discard, where an interrupted keep had left it" "$out"
}

test_a_completed_handover_keeps_the_previous_bundle() {
    local root out
    root="$TEST_TMP/handover-keep"
    mkdir -p "$root/bin" "$root/Applications"
    mkstub_tbd "$root/bin"
    mkbundle "$root/Applications/TBD.app" "old-worktree" >/dev/null
    mkbundle "$root/new/TBD.app" "new-clone" >/dev/null
    mksuccessor "$root/newdaemon"

    out="$(run_install_and_handover "$root" "$root/newdaemon" 5)"

    assert_contains "a completed handover succeeds" "rc=0" "$out"
    assert_eq "the new bundle is what is installed" "new-clone" \
        "$(cat "$root/Applications/TBD.app/Contents/SourceWorktreePath.txt")"
    assert_eq "the previous bundle is kept for a manual rollback" "old-worktree" \
        "$(cat "$root/updates/previous/TBD.app/Contents/SourceWorktreePath.txt")"
    assert_not_contains "a completed handover restores nothing" \
        "restored previous app bundle" "$out"
}

test_a_first_install_has_no_previous_bundle() {
    local root out
    root="$TEST_TMP/handover-first"
    mkdir -p "$root/bin" "$root/Applications"
    mkstub_tbd "$root/bin"
    mkbundle "$root/new/TBD.app" "new-clone" >/dev/null
    mksuccessor "$root/newdaemon"

    out="$(run_install_and_handover "$root" "$root/newdaemon" 5)"
    assert_contains "installing where nothing was installed still succeeds" "rc=0" "$out"
    assert_contains "and says there was nothing to keep" "keeping no previous bundle" "$out"
    assert_eq "the new bundle is what is installed" "new-clone" \
        "$(cat "$root/Applications/TBD.app/Contents/SourceWorktreePath.txt")"
}

# A first install whose handover fails has no kept bundle to put back, so the
# new build stays installed. hand_over_to_new_daemon records that for main,
# which then leaves the app stopped instead of launching the new build against
# whichever daemon is left.
test_a_failed_first_install_records_that_nothing_was_restored() {
    local root out
    root="$TEST_TMP/handover-first-fails"
    mkdir -p "$root/bin" "$root/Applications"
    mkstub_tbd "$root/bin"
    mkbundle "$root/new/TBD.app" "new-clone" >/dev/null
    mksuccessor "$root/newdaemon"

    # The daemon that answers reports another binary, so the handover fails.
    out="$(run_install_and_handover "$root" "/somewhere/else/TBDDaemon" 1)"

    assert_contains "a handover that never completes fails the step" "rc=1" "$out"
    assert_contains "the failed restore is logged" "no previous app bundle to restore" "$out"
    assert_contains "the failed restore is recorded for main" \
        "bundle_restore_failed=true" "$out"
    assert_eq "the new bundle is still what is installed" "new-clone" \
        "$(cat "$root/Applications/TBD.app/Contents/SourceWorktreePath.txt")"
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

# The daemon that answers once the predecessor is gone is the successor, and
# the path in that answer must be the binary just installed. One that names
# another binary fails the handover, with an error naming both.
test_a_daemon_that_reports_another_binary_fails_the_handover() {
    local root out
    root="$TEST_TMP/handover-other-binary"
    mkdir -p "$root/bin" "$root/state" "$root/updates"
    mkstub_tbd "$root/bin"
    printf '{"executablePath":"/old/.build/release/TBDDaemon"}\n' > "$root/state/status.json"

    out="$(
        export FAKE_TBD_STATE="$root/state" PATH="$root/bin:$PATH"
        OPT_AUTO=false
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        HANDOVER_STATUS_FILE="$root/updates/handover-status.json"
        wait_for_handover 0 "$$" "/new/.build/release/TBDDaemon" 5
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "a daemon naming another binary fails the handover" "rc=1" "$out"
    assert_contains_literal "with an error naming both" \
        "ERROR: the new daemon reports [/old/.build/release/TBDDaemon] as its executable, not /new/.build/release/TBDDaemon" \
        "$out"
    if [ -e "$root/updates/handover-status.json" ]; then
        fail "the answer it read is not left behind"
    else
        pass "the answer it read is not left behind"
    fi
}

# The answer that ends the wait decides. A `tbd` that answers once, with the
# new binary, and fails every call after is a successor serving through one
# transient failure: a second status call would see only the failure and roll
# a good update back.
test_the_answer_that_ends_the_wait_decides() {
    local root out
    root="$TEST_TMP/handover-one-answer"
    mkdir -p "$root/bin" "$root/updates"
    cat > "$root/bin/tbd" << EOF
#!/bin/sh
calls="\$(cat "$root/calls" 2>/dev/null || printf 0)"
calls=\$((calls + 1))
printf '%s\n' "\$calls" > "$root/calls"
[ "\$calls" -eq 1 ] || exit 1
printf '{"executablePath":"/new/.build/release/TBDDaemon"}\n'
EOF
    chmod +x "$root/bin/tbd"

    out="$(
        export PATH="$root/bin:$PATH"
        OPT_AUTO=false
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        HANDOVER_STATUS_FILE="$root/updates/handover-status.json"
        wait_for_handover 0 "$$" "/new/.build/release/TBDDaemon" 5
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "one answer naming the new binary completes the handover" "rc=0" "$out"
    assert_eq "and the status is asked once" "1" "$(cat "$root/calls" 2>/dev/null)"
}

# `tbd daemon status` has no timeout of its own, so a daemon that accepts the
# connection and never replies would hang it, and the run with it. Every
# status call is cut off after STATUS_PROBE_TIMEOUT seconds instead, and the
# hung `tbd` is stopped rather than left behind.
test_a_status_call_that_hangs_is_cut_off() {
    local root out started elapsed pid
    root="$TEST_TMP/handover-status-hangs"
    mkdir -p "$root/bin"
    cat > "$root/bin/tbd" << EOF
#!/bin/sh
printf '%s\n' "\$\$" > "$root/tbd.pid"
exec sleep 30
EOF
    chmod +x "$root/bin/tbd"

    started=$SECONDS
    out="$(
        export PATH="$root/bin:$PATH"
        STATUS_PROBE_TIMEOUT=1
        daemon_status_json
        printf 'rc=%s\n' "$?"
    )"
    elapsed=$((SECONDS - started))

    assert_eq "a status call that never answers is cut off, with no answer" "rc=124" "$out"
    if [ "$elapsed" -lt 10 ]; then
        pass "the hung status call is cut off near its one-second limit"
    else
        fail "the hung status call is cut off near its one-second limit: it took ${elapsed}s"
    fi
    pid="$(head -1 "$root/tbd.pid" 2>/dev/null | tr -dc '0-9')"
    if [ -n "$pid" ] && ! process_is_running "$pid"; then
        pass "the hung tbd is stopped"
    else
        fail "the hung tbd is stopped: pid [$pid]"
        [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null
    fi
}

# A pid no process runs as, by `ps`, which sees every user's processes. `kill
# -0` would not do: it also fails on a live process another user owns.
unused_pid() {
    local pid=$(( ($$ + 100000) % 60000 + 2 ))
    while ps -p "$pid" > /dev/null 2>&1; do
        pid=$((pid + 1))
    done
    printf '%s\n' "$pid"
}

# A pid file can outlive its daemon: after a crash, or a reboot that handed the
# pid to something else. The successor starts as on a cold start then, and
# waiting for that unrelated process to exit would time a good handover out
# and roll it back. Only a running daemon is waited for, and the log does not
# claim a handover from a pid that is not one. The successor in the
# function-level cases after this one is this harness's own process, which is
# running.
test_a_stale_pid_file_is_not_waited_on() {
    local root out other
    root="$TEST_TMP/handover-stale-pid"
    mkdir -p "$root/bin" "$root/state" "$root/updates"
    mkstub_tbd "$root/bin"
    mksuccessor "$root/newdaemon"
    printf '{"executablePath":"%s"}\n' "$root/newdaemon" > "$root/state/status.json"
    sleep 30 > /dev/null 2>&1 &
    other=$!
    printf '%s\n' "$other" > "$root/tbdd.pid"

    out="$(
        export FAKE_TBD_STATE="$root/state" PATH="$root/bin:$PATH"
        OPT_AUTO=false
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        HANDOVER_STATUS_FILE="$root/updates/handover-status.json"
        TBD_HOME_DIR="$root"
        DAEMON_PID_FILE="$root/tbdd.pid"
        DAEMON_LOG="$root/tbdd.log"
        HANDOVER_TIMEOUT=10
        handover "$root/newdaemon"
        printf 'rc=%s\n' "$?"
    )"
    kill "$other" 2>/dev/null
    wait "$other" 2>/dev/null
    stop_stand_in "$root/newdaemon.pid"

    assert_contains "a live pid that is not a daemon is not waited on" "rc=0" "$out"
    assert_contains "and the log says what the pid file named" \
        "names pid $other, which is not a running daemon" "$out"
    assert_not_contains "and claims no handover from it" "handing over from daemon pid" "$out"
    assert_not_contains "nothing waits for it to exit" "is still running" "$out"
}

# One budget covers both phases: wait_for_handover computes its deadline once
# and hands that same deadline to each. The phases are stubbed here to record
# the deadline they are given, and the first takes over a second, so a
# deadline computed afresh for the second would be a later one. Nothing here
# depends on how fast the runner is: the phases' own handling of a deadline
# is tested in scripts/restart-bundle-lib.test.sh.
test_the_handover_has_one_budget_for_both_waits() {
    local root out first second
    root="$TEST_TMP/handover-one-budget"
    mkdir -p "$root/updates"

    out="$(
        OPT_AUTO=false
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        wait_for_predecessor_exit() {
            printf 'first %s\n' "$3" >> "$root/deadlines"
            sleep 1.2
            printf 'exited\n'
        }
        wait_until_daemon_ready() {
            printf 'second %s\n' "$2" >> "$root/deadlines"
            printf 'timeout\n'
            return 1
        }
        wait_for_handover 4242 "$$" "/new/.build/release/TBDDaemon" 30
        printf 'rc=%s\n' "$?"
    )"
    first="$(sed -n 's/^first //p' "$root/deadlines" 2>/dev/null)"
    second="$(sed -n 's/^second //p' "$root/deadlines" 2>/dev/null)"

    assert_contains "a second phase that times out fails the handover" "rc=1" "$out"
    if [ -n "$first" ]; then
        pass "the first phase is given a deadline"
    else
        fail "the first phase is given a deadline"
    fi
    assert_eq "the second phase is given the same deadline, not a fresh one" "$first" "$second"
}

# A successor that dies after its predecessor has gone, before it has answered,
# ends the wait at once too, rather than leaving the status polled to the end
# of the budget.
test_a_successor_that_dies_before_it_answers_ends_the_wait() {
    local root out dead started elapsed
    root="$TEST_TMP/handover-successor-dies-late"
    # No status.json: the stub `tbd` answers nothing, as no daemon would.
    mkdir -p "$root/bin" "$root/state" "$root/updates"
    mkstub_tbd "$root/bin"
    dead="$(unused_pid)"

    started=$SECONDS
    out="$(
        export FAKE_TBD_STATE="$root/state" PATH="$root/bin:$PATH"
        OPT_AUTO=false
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        wait_for_handover 0 "$dead" "/new/.build/release/TBDDaemon" 30
        printf 'rc=%s\n' "$?"
    )"
    elapsed=$((SECONDS - started))

    assert_contains "a successor that is gone fails the handover" "rc=1" "$out"
    assert_contains "and the log says it exited" "the new daemon (pid $dead) exited before it answered" "$out"
    assert_not_contains "it is not reported as a timeout" "did not answer" "$out"
    if [ "$elapsed" -lt 10 ]; then
        pass "the wait ends well inside its 30-second budget"
    else
        fail "the wait ends well inside its 30-second budget: it took ${elapsed}s"
    fi
}

# The Medium finding this guards: the successor was backgrounded without its
# pid being captured, so a handover that timed out because the successor was
# merely slow — rather than dead — rolled the bundle back while that successor
# went on to bind and serve from the new build. Installed bundle and running
# daemon would disagree about which build is live.
#
# The stub daemon here outlives the timeout by a wide margin and never answers:
# there is no status.json, so the stub `tbd` reports nothing. It `exec`s a copy
# of sleep named TBDDaemon (mksuccessor), so the pid handover captured is the
# process that has to be signalled, and it is one stop_daemon_process
# recognises as a daemon. The budget is two seconds because SECONDS ticks on
# the wall clock's second boundaries: a budget of 1 could end within
# milliseconds, before the stub has become that TBDDaemon.
test_a_timed_out_handover_stops_the_successor() {
    local root out pid
    root="$TEST_TMP/handover-stop"
    mkdir -p "$root/bin" "$root/state" "$root/updates"
    mkstub_tbd "$root/bin"
    mksuccessor "$root/newdaemon"

    out="$(
        export FAKE_TBD_STATE="$root/state" PATH="$root/bin:$PATH"
        OPT_AUTO=false
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        HANDOVER_STATUS_FILE="$root/updates/handover-status.json"
        TBD_HOME_DIR="$root"
        DAEMON_PID_FILE="$root/tbdd.pid"
        DAEMON_LOG="$root/tbdd.log"
        HANDOVER_TIMEOUT=2
        HANDOVER_STOP_GRACE=3
        handover "$root/newdaemon"
        printf 'rc=%s\n' "$?"
    )"

    assert_contains "a successor that never answers fails the handover" "rc=1" "$out"
    assert_contains "and the log says it did not answer" "did not answer" "$out"
    pid="$(head -1 "$root/newdaemon.pid" 2>/dev/null | tr -dc '0-9')"
    if [ -z "$pid" ]; then
        fail "the stub successor recorded its pid"
        return
    fi
    pass "the stub successor recorded its pid"
    assert_contains "the failure names the pid it stopped, and how" \
        "stopped the new daemon (pid $pid) so the rollback leaves no daemon from the new build: stopped" "$out"
    if daemon_process_is_running "$pid"; then
        kill -KILL "$pid" 2>/dev/null
        fail "no daemon from the new build survives a failed handover"
    else
        pass "no daemon from the new build survives a failed handover"
    fi
}

# The stop is only ever reached on the failure path, and it has to cope with a
# successor that has already exited on its own — a crash rather than a stall.
test_stopping_a_successor_that_is_already_gone_is_not_an_error() {
    local root out dead
    root="$TEST_TMP/handover-stop-gone"
    mkdir -p "$root/updates"
    dead="$(unused_pid)"

    out="$(
        OPT_AUTO=false
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        stop_handover_successor "$dead"
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "a successor that already exited needs no stopping" "rc=0" "$out"
    assert_contains "and says so" "pid $dead) is not running" "$out"

    out="$(
        OPT_AUTO=false
        UPDATE_HOME="$root/updates"
        UPDATE_LOG="$root/updates/update.log"
        stop_handover_successor ""
        printf 'rc=%s\n' "$?"
    )"
    assert_contains "an empty pid is a no-op" "rc=0" "$out"
}

test_the_matchers_survive_output_longer_than_a_pipe
test_help_lists_every_flag
test_unknown_flag_is_rejected
test_parse_args_sets_options
test_lock_refuses_a_live_run
test_acquire_lock_recognises_its_own_lock
test_update_refuses_while_another_run_holds_the_lock
test_a_stale_lock_is_taken_over
test_simultaneous_acquire_lock_admits_exactly_one
test_stale_lock_takeover_leaves_no_debris
test_stale_lock_takeover_refuses_a_lock_that_turned_live
test_an_abandoned_takeover_mutex_is_reclaimed
test_an_old_takeover_mutex_with_a_live_owner_is_kept
test_an_old_ownerless_takeover_mutex_is_reclaimed
test_a_fresh_takeover_mutex_refuses_the_run
test_remote_resolution_order
test_source_worktree_resolution
test_json_field_reads_nested_paths
test_reexec_predicate
test_reexec_happens_once_and_passes_arguments
test_reexec_when_only_a_sourced_library_differs
test_reexec_when_the_script_runs_from_the_update_clone
test_check_reports_without_changing_anything
test_check_fallback_decides_ancestry_like_the_daemon
test_dry_run_builds_but_installs_nothing
test_a_failed_identity_stamp_installs_nothing
test_debug_flag_selects_the_debug_configuration
test_a_failed_build_stops_before_installing
test_a_failed_build_leaves_the_previous_stamp_alone
test_a_failed_build_reports_its_first_errors
test_a_slot_timeout_is_not_reported_as_a_compile_failure
test_build_failure_excerpt_with_auto_flag_goes_only_to_log
test_the_build_ignores_an_inherited_dev_shell_sdk
test_an_xcode_sdk_selection_is_kept
test_keep_build_env_switch_turns_the_scrub_off
test_auto_logs_without_printing
test_no_wake_skips_the_stage
test_no_app_skips_the_relaunch
test_app_stage_seeds_the_tmux_fallback
test_wake_candidate_filter
test_wake_candidates_exclude_tmux_rows
test_wake_batches_and_paces
test_wake_counts_failures
test_wake_ignores_other_background_children
test_wake_stagger_separates_batches
test_no_wake_and_wake_only
test_terminals_are_collected_across_worktrees
test_terminals_survive_brackets_and_pretty_printing
test_a_terminal_list_that_is_not_json_is_skipped_not_fatal
test_summary_reports_the_move
test_summary_survives_an_unknown_commit
test_cli_refresh_only_touches_an_existing_install
test_the_app_is_stopped_before_the_handover
test_the_app_quits_in_front_of_the_whole_new_bundle
test_the_installed_bundle_stays_whole_while_the_update_copies
test_a_failed_install_leaves_the_app_running
test_an_install_that_leaves_nothing_installed_says_where_the_bundle_is
test_an_install_that_leaves_nothing_installed_points_past_a_broken_bundle
test_the_documented_way_back_keeps_a_staged_bundle
test_a_swap_that_leaves_a_whole_staged_bundle_names_its_build
test_a_swap_that_leaves_no_whole_bundle_names_the_kept_one
test_an_install_that_leaves_nothing_installed_retries_the_put_back
test_an_app_started_during_the_handover_is_stopped_before_the_launch
test_signing_stays_inside_the_case_with_and_without_ci
test_a_failed_handover_relaunches_the_stopped_app
test_a_failed_handover_whose_restore_fails_leaves_the_app_stopped
test_a_rollback_whose_link_put_back_fails_does_not_name_a_spent_kept_bundle
test_a_rollback_that_finds_the_kept_bundle_gone_does_not_claim_a_restore
test_a_failed_handover_never_restores_an_earlier_updates_bundle
test_an_update_over_its_own_build_leaves_the_kept_bundle_alone
test_a_failed_handover_restores_the_kept_bundle_that_matches_the_daemon
test_a_newer_retry_after_a_cut_short_swap_keeps_the_daemons_build
test_a_daemon_identity_read_from_its_worktree_head_is_an_unknown_build
test_a_rollback_whose_bundle_and_link_disagree_leaves_the_app_stopped
test_a_failed_handover_over_the_daemons_build_restores_nothing
test_the_rollback_and_the_report_compare_whole_builds
test_a_failed_handover_restores_a_kept_bundle_with_no_build_identity
test_a_failed_handover_restores_the_kept_bundle_when_none_matches_the_daemon
test_an_update_over_the_same_commit_keeps_another_build
test_the_keep_tells_dirty_builds_apart_by_build_time
test_the_rollback_tells_dirty_builds_apart_by_build_time
test_an_interrupted_update_over_its_own_build_gives_the_recovery_steps
test_an_exit_mid_handover_leaves_the_app_stopped
test_an_exit_after_the_handover_still_relaunches_the_app
test_a_rollback_waits_for_the_app_exit_to_settle
test_the_app_exit_check_wait_keeps_renames_clear_of_both_checks
test_a_rollback_waits_out_the_second_check_of_the_app_exit
test_a_retry_waits_out_the_checks_of_an_earlier_runs_exit
test_the_exit_record_follows_the_app
test_an_exit_with_no_usable_time_waits_out_a_whole_second_check
test_an_update_clears_what_an_interrupted_install_left
test_an_interrupted_install_reports_which_build_is_installed
test_an_interruption_while_staging_reports_that_nothing_was_installed
test_an_interrupted_swap_puts_the_link_back_with_the_bundle
test_the_report_reads_the_build_directory_of_the_runs_configuration
test_an_exit_during_the_app_stop_says_the_app_may_be_stopped
test_an_interrupted_keep_leaves_no_partial_previous_bundle
test_no_app_never_stops_the_app
test_the_app_and_the_wake_wait_for_the_predecessor_to_exit
test_a_predecessor_that_never_exits_fails_the_handover
test_a_successor_that_dies_fails_the_handover_at_once
test_a_cold_start_hands_over_without_a_predecessor
test_a_failed_handover_restores_the_previous_bundle
test_a_rollback_says_when_the_restored_bundle_is_not_registered
test_a_rollback_never_deletes_the_kept_bundle_in_place
test_a_rollback_whose_swap_leaves_nothing_installed_retries_and_warns
test_a_failed_keep_puts_the_earlier_kept_bundle_back
test_a_failed_keep_leaves_the_earlier_bundle_recoverable_until_it_is_back
test_the_next_keep_puts_back_a_kept_bundle_left_at_the_discard_name
test_a_keep_that_cannot_put_back_the_discarded_bundle_deletes_nothing
test_an_interruption_between_the_keeps_renames_puts_the_kept_bundle_back
test_an_interruption_between_the_keeps_renames_with_the_link_stuck_puts_the_kept_bundle_back
test_a_completed_handover_keeps_the_previous_bundle
test_a_first_install_has_no_previous_bundle
test_a_failed_first_install_records_that_nothing_was_restored
test_paths_match_resolves_symlinks
test_a_daemon_that_reports_another_binary_fails_the_handover
test_the_answer_that_ends_the_wait_decides
test_a_status_call_that_hangs_is_cut_off
test_a_stale_pid_file_is_not_waited_on
test_the_handover_has_one_budget_for_both_waits
test_a_successor_that_dies_before_it_answers_ends_the_wait
test_a_timed_out_handover_stops_the_successor
test_stopping_a_successor_that_is_already_gone_is_not_an_error
test_update_source_resolution
test_check_ref_follows_the_standing_source
test_release_products_partition_the_runtime_products
test_release_dry_run_leaves_the_running_link
test_release_repo_slug_parses_github_remotes
test_release_install_verified
test_release_walks_back_to_the_newest_published_commit
test_release_attestation_missing_in_auto_mode_refuses
test_release_attestation_missing_in_manual_mode
test_release_checksum_mismatch_aborts
test_release_manifest_mismatch_aborts
test_release_no_asset_auto_skips
test_release_no_asset_manual_builds_locally
test_release_non_arm64_builds_locally
test_release_failed_handover_restores_the_link
test_release_failed_install_restores_the_link
test_release_interrupted_staging_puts_the_link_back
test_release_over_its_own_build_keeps_the_rollback_record
test_release_over_its_own_build_records_the_kept_bundles_tree
test_an_install_that_puts_back_its_own_build_keeps_the_rollback_record
test_release_dry_run_keeps_nothing_it_downloaded
test_release_failed_app_build_leaves_no_new_tree
test_release_failed_link_restores_the_running_link
test_release_failed_runs_never_grow_the_prebuilt_home
test_release_completed_install_keeps_the_replaced_tree_as_rollback
test_local_build_takes_the_link_back_from_a_download
test_local_build_short_of_an_install_restores_the_downloaded_link
test_release_failed_signing_restores_the_link

# A TRAP BELONGS TO THE SHELL THAT INSTALLED IT. A child that bash forks for a
# background job keeps a copy of this harness's EXIT trap until it execs, so a
# signal that lands first runs the trap in the CHILD, which would delete the
# directory under the running suite. No case can win that race on demand, so
# this one runs the trap's own text in a subshell, which is a forked child just
# as `cmd &` is until its exec, aimed at a decoy so the real directory is safe.
# It runs on every bash. On bash 3.2 a check built on `${BASHPID:-$$}` would
# fail the forked-child assertion below, which keeps that form from coming back.
dir_state() { if [ -d "$1" ]; then echo present; else echo gone; fi; }

# Run trap text $1 in this shell with TEST_TMP aimed at directory $2.
run_trap_aimed_at() {
    local TEST_TMP="$2"
    eval "$1"
}

test_only_the_harness_shell_deletes_the_scratch_dir() {
    local spec body unguarded decoy
    spec="$(trap -p EXIT)"
    eval "set -- $spec"
    body="${3:-}"
    # shellcheck disable=SC2016 # the trap's text, not its expansion
    case "$body" in *'rm -rf "$TEST_TMP"'*) pass "the EXIT trap removes the scratch dir" ;; *) fail "the EXIT trap removes the scratch dir: [$body]" ;; esac

    # A check that never deletes anything would pass the child case, so the
    # owner has to get through first.
    decoy="$(mktemp -d "$TEST_TMP/trap-owner.XXXXXX")"
    run_trap_aimed_at "$body" "$decoy"
    assert_eq "the harness shell itself deletes it" "gone" "$(dir_state "$decoy")"

    decoy="$(mktemp -d "$TEST_TMP/trap-owner.XXXXXX")"
    ( run_trap_aimed_at "$body" "$decoy" )
    assert_eq "a forked child running the trap leaves the directory alone" "present" "$(dir_state "$decoy")"

    # MUTATION: the trap as it was before the check, run by the same child.
    unguarded="${body#*&& }"
    # shellcheck disable=SC2016 # the trap's text, not its expansion
    assert_eq "the mutant really is the bare rm" 'rm -rf "$TEST_TMP"' "$unguarded"
    ( run_trap_aimed_at "$unguarded" "$decoy" )
    assert_eq "mutation: without the check, a forked child deletes the directory" "gone" "$(dir_state "$decoy")"
    rm -rf "$decoy"
}

test_only_the_harness_shell_deletes_the_scratch_dir

if [ "$FAIL" -ne 0 ]; then
    echo "SOME UPDATE TESTS FAILED"
    exit 1
fi

echo "ALL UPDATE TESTS PASSED"
