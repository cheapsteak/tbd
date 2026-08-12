#!/usr/bin/env bash
# Tests for scripts/restart-environment-lib.sh.
# Run: bash scripts/restart-environment-lib.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
HELPER="$HERE/restart-environment-lib.sh"
SOURCE_PLIST="$REPO_ROOT/Resources/TBDApp.Info.plist"

if [ ! -f "$HELPER" ]; then
    echo "FAIL - restart environment helper is missing: $HELPER"
    exit 1
fi

# shellcheck source=/dev/null
source "$HELPER"

FAIL=0
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/restart-environment-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

pass() {
    echo "ok   - $1"
}

fail() {
    echo "FAIL - $1"
    FAIL=1
}

assert_ok() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$description"
    else
        fail "$description: expected success"
    fi
}

assert_fail() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$description: expected failure"
    else
        pass "$description"
    fi
}

assert_plist_path() {
    local description="$1"
    local plist="$2"
    local expected_path="$3"
    local expected_file="$TEST_TMP/expected-$RANDOM"
    local actual_file="$TEST_TMP/actual-$RANDOM"

    printf '%s' "$expected_path" > "$expected_file"
    if ! plutil -extract LSEnvironment.PATH raw -o "$actual_file" "$plist" >/dev/null 2>&1; then
        fail "$description: could not extract LSEnvironment.PATH"
        return
    fi
    if cmp -s "$expected_file" "$actual_file"; then
        pass "$description"
    else
        fail "$description: PATH bytes differ"
    fi
}

test_exact_path_round_trip() {
    local generated="$TEST_TMP/exact.plist"
    local launch_path='/opt/tools with spaces/bin:/usr/bin:/opt/tools with spaces/bin:/bin'

    if write_restart_environment_plist "$SOURCE_PLIST" "$generated" "$launch_path" >/dev/null 2>&1; then
        pass "helper writes a generated plist"
    else
        fail "helper writes a generated plist: expected success"
        return
    fi
    assert_plist_path "PATH round-trips exactly with spaces and repeated entries" "$generated" "$launch_path"
    assert_ok "generated plist passes plutil lint" plutil -lint "$generated"
}

test_stale_environment_is_replaced() {
    local generated="$TEST_TMP/stale-generated.plist"
    local launch_path='/new/tools:/usr/bin'

    cp "$SOURCE_PLIST" "$generated"
    plutil -insert LSEnvironment -xml '<dict><key>PATH</key><string>/stale/path</string><key>STALE</key><string>value</string></dict>' "$generated"

    if ! write_restart_environment_plist "$SOURCE_PLIST" "$generated" "$launch_path" >/dev/null 2>&1; then
        fail "helper replaces a stale LSEnvironment: expected success"
        return
    fi
    assert_plist_path "stale LSEnvironment.PATH is replaced" "$generated" "$launch_path"
    assert_fail "other stale LSEnvironment values are removed" \
        plutil -extract LSEnvironment.STALE raw -o - "$generated"
}

test_empty_path_is_rejected() {
    local generated="$TEST_TMP/empty.plist"

    assert_fail "empty PATH is rejected" \
        write_restart_environment_plist "$SOURCE_PLIST" "$generated" ""
    if [ -e "$generated" ]; then
        fail "empty PATH does not leave a generated plist"
    else
        pass "empty PATH does not leave a generated plist"
    fi
}

test_malformed_plist_is_rejected() {
    local malformed="$TEST_TMP/malformed.plist"
    local generated="$TEST_TMP/malformed-generated.plist"

    printf '%s\n' 'not a plist' > "$malformed"
    assert_fail "malformed source plist is rejected" \
        write_restart_environment_plist "$malformed" "$generated" '/usr/bin:/bin'
}

test_source_plist_is_unchanged() {
    local source_copy="$TEST_TMP/source-copy.plist"
    local source_before="$TEST_TMP/source-before.plist"
    local generated="$TEST_TMP/source-generated.plist"

    cp "$SOURCE_PLIST" "$source_copy"
    cp "$source_copy" "$source_before"
    if ! write_restart_environment_plist "$source_copy" "$generated" '/custom/bin:/usr/bin' >/dev/null 2>&1; then
        fail "source plist remains unchanged: helper failed"
        return
    fi
    if cmp -s "$source_before" "$source_copy"; then
        pass "source plist remains unchanged"
    else
        fail "source plist remains unchanged: source bytes differ"
    fi
}

test_exact_path_round_trip
test_stale_environment_is_replaced
test_empty_path_is_rejected
test_malformed_plist_is_rejected
test_source_plist_is_unchanged

if [ "$FAIL" -ne 0 ]; then
    echo "SOME RESTART ENVIRONMENT TESTS FAILED"
    exit 1
fi

echo "ALL RESTART ENVIRONMENT TESTS PASSED"
