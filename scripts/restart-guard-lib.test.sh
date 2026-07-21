#!/usr/bin/env bash
# Tests for scripts/restart-guard-lib.sh — run: bash scripts/restart-guard-lib.test.sh
# shellcheck disable=SC2329 # test_* helpers are dispatched dynamically via `declare -F`/"$t" below
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/restart-guard-lib.sh"   # pure function defs, no side effects

FAIL=0
assert_ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok   - $d"; else echo "FAIL - $d: expected success"; FAIL=1; fi; }
assert_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL - $d: expected failure"; FAIL=1; else echo "ok   - $d"; fi; }
assert_eq()   { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }

# Build a throwaway git repo with a `main` branch and one commit. Echoes its path.
mkrepo() {
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/guard-test.XXXXXX")"
    git -C "$d" init -q -b main
    git -C "$d" config user.email t@t.t
    git -C "$d" config user.name t
    echo "seed" > "$d/README.md"
    git -C "$d" add -A && git -C "$d" commit -q -m "seed"
    echo "$d"
}

test_clean_on_main_is_blessed() {
    local REPO_ROOT; REPO_ROOT="$(mkrepo)"
    assert_ok "is_working_tree_clean on clean repo" is_working_tree_clean
    assert_eq "resolve_main_ref falls back to main" "main" "$(resolve_main_ref)"
    assert_ok "is_build_blessed: clean + HEAD == main" is_build_blessed
    rm -rf "$REPO_ROOT"
}

test_dirty_tracked_file_not_blessed() {
    local REPO_ROOT; REPO_ROOT="$(mkrepo)"
    echo "change" >> "$REPO_ROOT/README.md"   # modify a tracked file
    assert_fail "is_working_tree_clean with modified tracked file" is_working_tree_clean
    assert_fail "is_build_blessed with dirty tracked file" is_build_blessed
    rm -rf "$REPO_ROOT"
}

# The High finding this PR fixes: a brand-new untracked .swift file is compiled
# by SwiftPM but was invisible to the old --untracked-files=no check.
test_untracked_new_file_not_blessed() {
    local REPO_ROOT; REPO_ROOT="$(mkrepo)"
    echo "// wip" > "$REPO_ROOT/NewFeature.swift"   # untracked, never `git add`ed
    assert_fail "is_working_tree_clean with untracked new file" is_working_tree_clean
    assert_fail "is_build_blessed with untracked new file" is_build_blessed
    rm -rf "$REPO_ROOT"
}

# Ignored paths (like .build/) must NOT trip the clean check.
test_gitignored_path_stays_blessed() {
    local REPO_ROOT; REPO_ROOT="$(mkrepo)"
    printf '.build/\n' > "$REPO_ROOT/.gitignore"
    git -C "$REPO_ROOT" add .gitignore && git -C "$REPO_ROOT" commit -q -m "ignore build"
    mkdir -p "$REPO_ROOT/.build/debug"; echo x > "$REPO_ROOT/.build/debug/artifact"
    assert_ok "is_working_tree_clean ignores .build artifacts" is_working_tree_clean
    assert_ok "is_build_blessed with only ignored artifacts" is_build_blessed
    rm -rf "$REPO_ROOT"
}

test_head_ahead_of_main_not_blessed() {
    local REPO_ROOT; REPO_ROOT="$(mkrepo)"
    git -C "$REPO_ROOT" checkout -q -b feature
    echo "feat" > "$REPO_ROOT/f.txt"
    git -C "$REPO_ROOT" add -A && git -C "$REPO_ROOT" commit -q -m "feature commit"
    assert_fail "is_head_ancestor_of main when HEAD is ahead" is_head_ancestor_of "main"
    assert_fail "is_build_blessed when HEAD ahead of main" is_build_blessed
    rm -rf "$REPO_ROOT"
}

test_no_main_ref_not_blessed() {
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/guard-test.XXXXXX")"
    git -C "$d" init -q -b trunk   # no branch/ref named main
    git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
    echo x > "$d/a"; git -C "$d" add -A; git -C "$d" commit -q -m x
    local REPO_ROOT="$d"
    assert_eq "resolve_main_ref empty when no main" "" "$(resolve_main_ref)"
    assert_fail "is_build_blessed when no main ref resolvable" is_build_blessed
    rm -rf "$d"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
if [ "$FAIL" -ne 0 ]; then echo "SOME TESTS FAILED"; exit 1; fi
echo "ALL GUARD-LIB TESTS PASSED"
