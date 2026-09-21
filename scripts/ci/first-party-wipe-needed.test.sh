#!/usr/bin/env bash
# Tests for scripts/ci/first-party-wipe-needed.sh — run:
#   /bin/bash scripts/ci/first-party-wipe-needed.test.sh
#
# VERIFIED WITH `/bin/bash`, WHICH ON MACOS IS 3.2. A developer with Homebrew's
# bash first on `PATH` is running 5.x, where constructs 3.2 cannot parse work
# fine and then fail at RUN time from inside a command substitution, where
# `bash -n` on 5.x never sees them. Nothing here is macOS-only, though: the
# script under test drives nothing but `git`, `tr` and shell builtins, so this
# harness joins the Linux collection in the `plans-guard` job.
#
# ZERO BUILDS AND NOTHING REAL IS TOUCHED. Every case mints a throwaway git
# repository under `mktemp -d`, shaped like this one only in the paths the
# decision reads — the two library trees, `Sources/TBDDaemon`, `Tests/`, the
# manifest and the resolved file. No case reads the surrounding checkout, the
# network, `~/tbd`, or a real `.build/`.
#
# THE FIXTURE REPOS ARE FENCED OFF FROM THE DEVELOPER'S GIT CONFIG. Each one
# sets its own identity and turns signing off in LOCAL config: a global
# `commit.gpgsign = true` would otherwise make every fixture commit prompt or
# fail, which has bitten this repo's suites before.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/first-party-wipe-needed.sh"

FAIL=0
assert_eq()       { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { case "$2" in *"$3"*) echo "ok   - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]" ; FAIL=1 ;; esac; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/first-party-wipe-test.XXXXXX"; }

FIXTURES=""
cleanup() {
  local dir
  for dir in $FIXTURES; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# A throwaway repository with one commit, holding a file in each path the
# decision looks at plus two it must ignore. Echoes the directory.
mkrepo() {
  local d; d="$(mktmpd)"
  FIXTURES="$FIXTURES $d"
  mkdir -p "$d/Sources/TBDShared" "$d/Sources/TBDDaemonLib" \
           "$d/Sources/TBDDaemon" "$d/Tests/TBDDaemonTests"
  echo "public struct Shared {}"      > "$d/Sources/TBDShared/Shared.swift"
  echo "public struct DaemonLib {}"   > "$d/Sources/TBDDaemonLib/DaemonLib.swift"
  echo "struct Daemon {}"             > "$d/Sources/TBDDaemon/Daemon.swift"
  echo "import Testing"               > "$d/Tests/TBDDaemonTests/DaemonTests.swift"
  echo "// swift-tools-version:6.0"   > "$d/Package.swift"
  echo '{"pins":[]}'                  > "$d/Package.resolved"
  (
    cd "$d" || exit 1
    git -c init.defaultBranch=main init -q .
    git config user.email "harness@example.invalid"
    git config user.name "Wipe Harness"
    git config commit.gpgsign false
    git add -A
    git commit -q -m "base"
  ) || { echo "FAIL - fixture repo could not be created"; FAIL=1; }
  echo "$d"
}

# The repo's current commit.
head_of() { git -C "$1" rev-parse HEAD; }

# Commit a one-line change to a path inside the repo.
commit_change() {
  local repo="$1" path="$2"
  echo "// touched $(date +%s%N 2>/dev/null || date +%s)" >> "$repo/$path"
  (
    cd "$repo" || exit 1
    git add -A
    git commit -q -m "touch $path"
  )
}

# Write the marker file the script reads.
write_marker() { printf '%s\n' "$2" > "$1/marker"; }

# Run the script from inside the fixture repo. Sets RUN_OUT (stdout, trimmed),
# RUN_ERR (the reason line) and RUN_RC.
run_decider() {
  local repo="$1" marker="$2"
  RUN_OUT="$(cd "$repo" && /bin/bash "$SCRIPT" "$marker" 2>"$repo/stderr.txt")"
  RUN_RC=$?
  RUN_ERR="$(cat "$repo/stderr.txt" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# 1. No provenance at all — the shape of every run before this mechanism existed
# ---------------------------------------------------------------------------

test_absent_marker_wipes() {
  local repo; repo="$(mkrepo)"
  run_decider "$repo" "$repo/marker"
  assert_eq "an absent marker exits 0" "0" "$RUN_RC"
  assert_eq "an absent marker wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the missing marker" "$RUN_ERR" "no cache-source marker"
}

test_empty_marker_wipes() {
  local repo; repo="$(mkrepo)"
  : > "$repo/marker"
  run_decider "$repo" "$repo/marker"
  assert_eq "an empty marker wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason says the marker is empty" "$RUN_ERR" "empty or unreadable"
}

# ---------------------------------------------------------------------------
# 2. A marker naming a commit this checkout does not have — a force-push, or a
#    cache restored from unrelated history
# ---------------------------------------------------------------------------

test_unknown_commit_wipes() {
  local repo; repo="$(mkrepo)"
  write_marker "$repo" "0123456789abcdef0123456789abcdef01234567"
  run_decider "$repo" "$repo/marker"
  assert_eq "an unknown marker commit wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason quotes the missing commit" "$RUN_ERR" \
    "0123456789abcdef0123456789abcdef01234567 is not in this checkout"
}

# ---------------------------------------------------------------------------
# 3. A library changed since the cache was built — the bug's precondition
# ---------------------------------------------------------------------------

test_tbdshared_change_wipes() {
  local repo base; repo="$(mkrepo)"; base="$(head_of "$repo")"
  write_marker "$repo" "$base"
  commit_change "$repo" "Sources/TBDShared/Shared.swift"
  run_decider "$repo" "$repo/marker"
  assert_eq "a TBDShared change wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the changed file" "$RUN_ERR" \
    "Sources/TBDShared/Shared.swift"
}

test_tbddaemonlib_change_wipes() {
  local repo base; repo="$(mkrepo)"; base="$(head_of "$repo")"
  write_marker "$repo" "$base"
  commit_change "$repo" "Sources/TBDDaemonLib/DaemonLib.swift"
  run_decider "$repo" "$repo/marker"
  assert_eq "a TBDDaemonLib change wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the changed file" "$RUN_ERR" \
    "Sources/TBDDaemonLib/DaemonLib.swift"
}

# A manifest change can move a library's module boundary without touching a
# single file under `Sources/`, so the manifest and the resolved file are part
# of the comparison.
test_package_swift_change_wipes() {
  local repo base; repo="$(mkrepo)"; base="$(head_of "$repo")"
  write_marker "$repo" "$base"
  commit_change "$repo" "Package.swift"
  run_decider "$repo" "$repo/marker"
  assert_eq "a Package.swift change wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the manifest" "$RUN_ERR" "Package.swift"
}

test_package_resolved_change_wipes() {
  local repo base; repo="$(mkrepo)"; base="$(head_of "$repo")"
  write_marker "$repo" "$base"
  commit_change "$repo" "Package.resolved"
  run_decider "$repo" "$repo/marker"
  assert_eq "a Package.resolved change wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the resolved file" "$RUN_ERR" "Package.resolved"
}

# ---------------------------------------------------------------------------
# 4. The common case this exists for: commits that touch neither library
# ---------------------------------------------------------------------------

test_daemon_and_tests_only_skips() {
  local repo base; repo="$(mkrepo)"; base="$(head_of "$repo")"
  write_marker "$repo" "$base"
  commit_change "$repo" "Sources/TBDDaemon/Daemon.swift"
  commit_change "$repo" "Tests/TBDDaemonTests/DaemonTests.swift"
  run_decider "$repo" "$repo/marker"
  assert_eq "a run that touched neither library exits 0" "0" "$RUN_RC"
  assert_eq "a run that touched neither library skips" "skip" "$RUN_OUT"
  assert_contains "the reason names the commit compared against" "$RUN_ERR" "$base"
  assert_contains "the reason says what was unchanged" "$RUN_ERR" "are unchanged since"
}

test_identical_tree_skips() {
  local repo base; repo="$(mkrepo)"; base="$(head_of "$repo")"
  write_marker "$repo" "$base"
  run_decider "$repo" "$repo/marker"
  assert_eq "a marker equal to HEAD skips" "skip" "$RUN_OUT"
}

# A library restored to its marker-commit contents is byte-identical to it, even
# though intervening commits changed it — the decision is on trees, not on
# whether a commit ever named the path.
test_reverted_library_change_skips() {
  local repo base; repo="$(mkrepo)"; base="$(head_of "$repo")"
  write_marker "$repo" "$base"
  commit_change "$repo" "Sources/TBDShared/Shared.swift"
  (
    cd "$repo" || exit 1
    git checkout -q "$base" -- Sources/TBDShared/Shared.swift
    git commit -q -m "revert"
  )
  run_decider "$repo" "$repo/marker"
  assert_eq "a reverted library change skips" "skip" "$RUN_OUT"
}

# ---------------------------------------------------------------------------
# 5. A malformed invocation is refused by name rather than answered
# ---------------------------------------------------------------------------

test_missing_argument_is_refused() {
  local repo; repo="$(mkrepo)"
  RUN_OUT="$(cd "$repo" && /bin/bash "$SCRIPT" 2>"$repo/stderr.txt")"
  RUN_RC=$?
  RUN_ERR="$(cat "$repo/stderr.txt")"
  assert_eq "a missing marker path exits 64" "64" "$RUN_RC"
  assert_eq "a refusal decides nothing" "" "$RUN_OUT"
  assert_contains "the refusal states its usage" "$RUN_ERR" "usage:"
}

# ---------------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  echo "--- $t"
  "$t"
done

if [ "$FAIL" -eq 0 ]; then
  echo "All first-party-wipe-needed tests passed."
else
  echo "Some first-party-wipe-needed tests FAILED."
fi
exit "$FAIL"
