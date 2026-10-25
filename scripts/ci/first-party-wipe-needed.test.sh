#!/usr/bin/env bash
# Tests for scripts/ci/first-party-wipe-needed.sh — run:
#   /bin/bash scripts/ci/first-party-wipe-needed.test.sh
#
# VERIFIED WITH `/bin/bash`, WHICH ON MACOS IS 3.2. A developer with Homebrew's
# bash first on `PATH` is running 5.x, where constructs 3.2 cannot parse work
# fine and then fail at RUN time from inside a command substitution, where
# `bash -n` on 5.x never sees them. Nothing here is macOS-only, though: the
# script under test drives nothing but `git`, `grep` and shell builtins, so this
# harness joins the Linux collection in the `plans-guard` job.
#
# THE FIXTURE REPOSITORIES MIRROR THIS PACKAGE'S REAL LAYOUT, and that is
# load-bearing rather than decorative. `Sources/TBDDaemonLib` does not exist:
# the TBDDaemonLib library target is declared with `path: "Sources/TBDDaemon"`.
# A fixture that invented the directory would let a path list naming it pass
# every case here while matching nothing in the real repository — a `git diff`
# or `git rev-parse` over a path that is absent from both sides of a comparison
# reports no difference, so the wipe would silently never fire for the library
# it exists to protect. `test_compared_paths_resolve_in_this_repository` pins
# the list to the checkout the harness is running in for the same reason.
#
# ZERO BUILDS, AND THE ONLY REAL THINGS READ ARE THIS CHECKOUT'S GIT TREE AND
# THE TEXT OF THREE OF ITS FILES. `test_compared_paths_resolve_in_this_repository`
# reads the tree, and `test_the_wipe_step_removes_exactly_the_compared_libraries`
# reads `Package.swift`, `.github/workflows/test.yml` and the `WIPE_PATHS` list
# in the script under test, writing its mutated copies of the first two to a
# temp directory. Every other case mints
# a throwaway repository under `mktemp -d`, shaped like this one only in the
# paths the decision reads. No case reads the network, `~/tbd`, or a real
# `.build/`, and nothing is ever written outside a temp directory.
#
# THE FIXTURE REPOS ARE FENCED OFF FROM THE DEVELOPER'S GIT CONFIG. Each one
# sets its own identity and turns signing off in LOCAL config: a global
# `commit.gpgsign = true` would otherwise make every fixture commit prompt or
# fail, which has bitten this repo's suites before.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/first-party-wipe-needed.sh"
WORKFLOW="$HERE/../../.github/workflows/test.yml"
PACKAGE="$HERE/../../Package.swift"

FAIL=0
assert_eq()       { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { case "$2" in *"$3"*) echo "ok   - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]" ; FAIL=1 ;; esac; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/first-party-wipe-test.XXXXXX"; }

# The fixture register is a FILE, not a variable: every fixture is minted inside
# a command substitution, so a subshell's assignment would be lost and the trap
# would reclaim nothing.
FIXTURE_LIST="$(mktmpd)/fixtures"
: > "$FIXTURE_LIST"
cleanup() {
  local dir
  while read -r dir; do
    [ -n "$dir" ] && rm -rf "$dir"
  done < "$FIXTURE_LIST"
  rm -rf "$(dirname "$FIXTURE_LIST")"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# A throwaway repository with one commit, holding a file in each path the
# decision looks at plus two it must ignore. Echoes the directory — so every
# diagnostic in here goes to stderr, or it would be captured as part of the
# path and vanish from the log.
mkrepo() {
  local d; d="$(mktmpd)"
  echo "$d" >> "$FIXTURE_LIST"
  mkdir -p "$d/Sources/TBDShared" "$d/Sources/TBDDaemon/Server" \
           "$d/Sources/TBDTerminalSerialization" "$d/Sources/TBDApp" \
           "$d/Tests/TBDDaemonTests"
  echo "public struct Shared {}"      > "$d/Sources/TBDShared/Shared.swift"
  echo "struct Router {}"             > "$d/Sources/TBDDaemon/Server/Router.swift"
  echo "struct Frame {}"              > "$d/Sources/TBDTerminalSerialization/Frame.swift"
  echo "// entry point"               > "$d/Sources/TBDDaemon/main.swift"
  echo "struct App {}"                > "$d/Sources/TBDApp/App.swift"
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
  ) || echo "fixture repo $d could not be created" >&2
  echo "$d"
}

# Commit a one-line change to a path inside the repo.
commit_change() {
  local repo="$1" path="$2"
  echo "// touched $RANDOM" >> "$repo/$path"
  (
    cd "$repo" || exit 1
    git add -A
    git commit -q -m "touch $path"
  )
}

# Record the marker the way the `test` job does after its build.
record_marker() {
  ( cd "$1" && /bin/bash "$SCRIPT" --record "$1/marker" ) >/dev/null 2>&1
}

# Run the decision from inside the fixture repo. Sets RUN_OUT (stdout), RUN_ERR
# (the reason line) and RUN_RC.
run_decider() {
  local repo="$1"
  RUN_OUT="$(cd "$repo" && /bin/bash "$SCRIPT" "$repo/marker" 2>"$repo/stderr.txt")"
  RUN_RC=$?
  RUN_ERR="$(cat "$repo/stderr.txt" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# 1. No usable provenance — the shape of every run before this mechanism existed
# ---------------------------------------------------------------------------

test_absent_marker_wipes() {
  local repo; repo="$(mkrepo)"
  run_decider "$repo"
  assert_eq "an absent marker exits 0" "0" "$RUN_RC"
  assert_eq "an absent marker wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the missing marker" "$RUN_ERR" "no marker at"
}

test_empty_marker_wipes() {
  local repo; repo="$(mkrepo)"
  : > "$repo/marker"
  run_decider "$repo"
  assert_eq "an empty marker wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason says the marker is empty" "$RUN_ERR" "empty or unreadable"
}

# The other half of "empty or unreadable": a marker that is there but cannot be
# opened. Root can read a mode-000 file, so where the harness runs as root the
# case says so rather than asserting something it did not arrange.
test_unreadable_marker_wipes() {
  local repo; repo="$(mkrepo)"
  record_marker "$repo"
  chmod 000 "$repo/marker"
  if [ -r "$repo/marker" ]; then
    echo "ok   - (skipped: this user can read a mode-000 file, so unreadability cannot be staged)"
    chmod 644 "$repo/marker"
    return
  fi
  run_decider "$repo"
  chmod 644 "$repo/marker"
  assert_eq "a marker that cannot be read wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason says the marker is unreadable" "$RUN_ERR" "empty or unreadable"
}

# A marker holding only its human-readable header decides nothing.
test_header_only_marker_wipes() {
  local repo; repo="$(mkrepo)"
  echo "# recorded at deadbeef" > "$repo/marker"
  run_decider "$repo"
  assert_eq "a marker with no fingerprint lines wipes" "wipe" "$RUN_OUT"
}

# One corrupted id inside an otherwise intact fingerprint — every other line
# still matching, so only the single differing id can decide it.
test_one_corrupted_id_wipes() {
  local repo; repo="$(mkrepo)"
  record_marker "$repo"
  sed 's|^Sources/TBDShared .*|Sources/TBDShared 0000000000000000000000000000000000000000|' \
    "$repo/marker" > "$repo/marker.tmp"
  mv "$repo/marker.tmp" "$repo/marker"
  run_decider "$repo"
  assert_eq "a single differing id wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the one path that differs" "$RUN_ERR" "Sources/TBDShared"
}

# A marker recorded under a different compared set — what an upgrade across a
# change to the list looks like from the next run's side.
test_marker_from_a_different_path_set_wipes() {
  local repo; repo="$(mkrepo)"
  record_marker "$repo"
  grep -v "^Package.resolved" "$repo/marker" > "$repo/marker.tmp"
  mv "$repo/marker.tmp" "$repo/marker"
  run_decider "$repo"
  assert_eq "a marker recorded under a different path set wipes" "wipe" "$RUN_OUT"
}

# ---------------------------------------------------------------------------
# 2. A library changed since the cache was built — the bug's precondition
# ---------------------------------------------------------------------------

test_tbdshared_change_wipes() {
  local repo; repo="$(mkrepo)"
  record_marker "$repo"
  commit_change "$repo" "Sources/TBDShared/Shared.swift"
  run_decider "$repo"
  assert_eq "a TBDShared change wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the changed path" "$RUN_ERR" "Sources/TBDShared"
}

# TBDDaemonLib's sources, which live under `Sources/TBDDaemon` — the case that
# goes red if the compared path list ever names a directory the package has not
# got.
test_tbddaemonlib_change_wipes() {
  local repo; repo="$(mkrepo)"
  record_marker "$repo"
  commit_change "$repo" "Sources/TBDDaemon/Server/Router.swift"
  run_decider "$repo"
  assert_eq "a TBDDaemonLib source change wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the changed path" "$RUN_ERR" "Sources/TBDDaemon"
}

# TBDTerminalSerialization is a library the wipe removes in its own right, and
# TBDDaemonLib imports it, so a commit touching only that target re-emits its
# module and recompiles TBDDaemonLib: both archives can go stale.
test_tbdterminalserialization_change_wipes() {
  local repo; repo="$(mkrepo)"
  record_marker "$repo"
  commit_change "$repo" "Sources/TBDTerminalSerialization/Frame.swift"
  run_decider "$repo"
  assert_eq "a TBDTerminalSerialization change wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the changed path" "$RUN_ERR" "Sources/TBDTerminalSerialization"
}

# A manifest change can move a library's module boundary without touching a
# single file under `Sources/`, so the manifest and the resolved file are part
# of the comparison.
test_package_swift_change_wipes() {
  local repo; repo="$(mkrepo)"
  record_marker "$repo"
  commit_change "$repo" "Package.swift"
  run_decider "$repo"
  assert_eq "a Package.swift change wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the manifest" "$RUN_ERR" "Package.swift"
}

test_package_resolved_change_wipes() {
  local repo; repo="$(mkrepo)"
  record_marker "$repo"
  commit_change "$repo" "Package.resolved"
  run_decider "$repo"
  assert_eq "a Package.resolved change wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the resolved file" "$RUN_ERR" "Package.resolved"
}

# A compared path that no longer resolves is the shape a silent pathspec would
# swallow: the answer must be `wipe`, said out loud.
test_removed_compared_path_wipes() {
  local repo; repo="$(mkrepo)"
  record_marker "$repo"
  (
    cd "$repo" || exit 1
    git rm -q -r Sources/TBDShared
    git commit -q -m "remove the library"
  )
  run_decider "$repo"
  assert_eq "a compared path that vanished wipes" "wipe" "$RUN_OUT"
  assert_contains "the reason names the path that no longer resolves" "$RUN_ERR" \
    "Sources/TBDShared does not resolve at HEAD"
}

# ---------------------------------------------------------------------------
# 3. The common case this exists for: commits that touch neither library
# ---------------------------------------------------------------------------

test_app_and_tests_only_skips() {
  local repo; repo="$(mkrepo)"
  record_marker "$repo"
  commit_change "$repo" "Sources/TBDApp/App.swift"
  commit_change "$repo" "Tests/TBDDaemonTests/DaemonTests.swift"
  run_decider "$repo"
  assert_eq "a run that touched neither library exits 0" "0" "$RUN_RC"
  assert_eq "a run that touched neither library skips" "skip" "$RUN_OUT"
  assert_contains "the reason says what was unchanged" "$RUN_ERR" "byte-identical"
}

test_identical_tree_skips() {
  local repo; repo="$(mkrepo)"
  record_marker "$repo"
  run_decider "$repo"
  assert_eq "an untouched tree skips" "skip" "$RUN_OUT"
}

# A library restored to its recorded contents is byte-identical to it, even
# though intervening commits changed it — the decision is on content, not on
# whether a commit ever named the path.
test_reverted_library_change_skips() {
  local repo base; repo="$(mkrepo)"
  base="$(git -C "$repo" rev-parse HEAD)"
  record_marker "$repo"
  commit_change "$repo" "Sources/TBDShared/Shared.swift"
  (
    cd "$repo" || exit 1
    git checkout -q "$base" -- Sources/TBDShared/Shared.swift
    git commit -q -m "revert"
  )
  run_decider "$repo"
  assert_eq "a reverted library change skips" "skip" "$RUN_OUT"
}

# The decision must survive the commit that recorded the marker being thrown
# away, because on a `pull_request` run that is the normal course of events:
# `actions/checkout` builds an ephemeral merge commit which GitHub discards when
# the next push recomputes the merge ref. Content ids do not care.
test_skip_survives_the_recording_commit_being_discarded() {
  local repo; repo="$(mkrepo)"
  record_marker "$repo"
  commit_change "$repo" "Sources/TBDApp/App.swift"
  (
    cd "$repo" || exit 1
    # Rewrite history so the commit the marker was recorded at is unreachable,
    # exactly as a recomputed merge ref makes the previous one unreachable.
    git checkout -q --orphan rebuilt
    git add -A
    git commit -q -m "rebuilt history"
  )
  run_decider "$repo"
  assert_eq "a skip survives its recording commit being unreachable" "skip" "$RUN_OUT"
}

# ---------------------------------------------------------------------------
# 4. Recording refuses rather than lying
# ---------------------------------------------------------------------------

test_record_writes_every_compared_path() {
  local repo lines; repo="$(mkrepo)"
  record_marker "$repo"
  lines="$(grep -c -v '^#' "$repo/marker" | tr -d ' ')"
  assert_eq "the marker carries one line per compared path" "5" "$lines"
  assert_contains "the marker names TBDDaemonLib's source directory" \
    "$(cat "$repo/marker")" "Sources/TBDDaemon "
}

test_record_writes_nothing_when_a_path_does_not_resolve() {
  local repo; repo="$(mkrepo)"
  (
    cd "$repo" || exit 1
    git rm -q -r Sources/TBDShared
    git commit -q -m "remove the library"
  )
  record_marker "$repo"
  if [ -f "$repo/marker" ]; then
    echo "FAIL - a tree that cannot be described was recorded anyway"
    FAIL=1
  else
    echo "ok   - a tree that cannot be described records nothing, so the next run wipes"
  fi
}

# A marker the decision step never consumed belongs to the artifacts the cache
# restored, not to this run — overwriting it would claim a consistency this run
# never established. The workflow never reaches its recording step in that
# shape, since that step carries no condition and so runs only after every step
# before it succeeded; the guard is what makes the script safe to call from
# anywhere, including by hand on a machine whose `.build/` it did not build.
test_record_leaves_an_unread_marker_alone() {
  local repo before after; repo="$(mkrepo)"
  record_marker "$repo"
  before="$(cat "$repo/marker")"
  commit_change "$repo" "Sources/TBDShared/Shared.swift"
  record_marker "$repo"
  after="$(cat "$repo/marker")"
  assert_eq "an unconsumed marker is left exactly as it was" "$before" "$after"
  # And it still decides for the artifacts it describes, which have now diverged.
  run_decider "$repo"
  assert_eq "the untouched marker still reports the divergence" "wipe" "$RUN_OUT"
}

# The list is only meaningful if it names paths this package actually has: a
# path absent from both sides of a comparison reports no difference forever.
test_compared_paths_resolve_in_this_repository() {
  local out rc
  out="$(/bin/bash "$SCRIPT" --record "$(dirname "$FIXTURE_LIST")/repo-marker" 2>&1)"
  rc=$?
  assert_eq "recording against this checkout exits 0" "0" "$rc"
  assert_contains "every compared path resolves in this repository" "$out" \
    "Recorded the first-party source fingerprint"
  assert_contains "TBDShared resolves here" "$out" "Sources/TBDShared "
  assert_contains "TBDDaemonLib's source directory resolves here" "$out" "Sources/TBDDaemon "
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

test_unknown_option_is_refused() {
  local repo; repo="$(mkrepo)"
  RUN_OUT="$(cd "$repo" && /bin/bash "$SCRIPT" --wat "$repo/marker" 2>"$repo/stderr.txt")"
  RUN_RC=$?
  assert_eq "an unknown option exits 64" "64" "$RUN_RC"
  assert_eq "an unknown option decides nothing" "" "$RUN_OUT"
}

# ---------------------------------------------------------------------------
# 6. The wipe step removes every library this decision compares, and no other
# ---------------------------------------------------------------------------
#
# The decision and the wipe live in two files — `WIPE_PATHS` in the script, the
# module loop in the workflow's wipe step — and they only work as a pair. A
# library whose sources are compared but whose artifacts the loop never removes
# gets a `wipe` answer on exactly the run that changes it and keeps its stale
# objects anyway, which is the #7715 condition left in place. A module the loop
# removes whose sources are not compared has its wipe hinge on unrelated files,
# and a name in the loop that is no library target at all removes nothing,
# silently. So both lists are read out of the files CI runs and checked against
# the targets `Package.swift` declares.
#
# The manifest is read by a line parser, not by SwiftPM, so a declaration it
# does not recognise must turn this red rather than drop out of the comparison:
# every source directory in `WIPE_PATHS` has to belong to exactly one library
# target the parser found. What is checked is each module against its OWN
# sources. That `WIPE_PATHS` also covers each module's first-party dependencies
# is not read here, and is for review to hold.

WIPE_STEP_NAME='Force-rebuild first-party libraries (workaround SPM #7715)'

# The modules the wipe step removes, one per line, read from its module loop in
# WORKFLOW, or in the workflow file given as $1 (a mutated copy, in the case
# below).
wiped_modules() {
  awk -v name="      - name: $WIPE_STEP_NAME" '
    $0 == name { found = 1; next }
    found && /^      - / { exit }
    found && /^[ \t]*for module in / {
      sub(/^[ \t]*for module in /, "")
      sub(/;[ \t]*do[ \t]*$/, "")
      n = split($0, m, " ")
      for (i = 1; i <= n; i++) print m[i]
      exit
    }
  ' "${1:-$WORKFLOW}"
}

# `WIPE_PATHS` from the script under test, one per line.
wipe_paths() {
  awk '
    /^WIPE_PATHS=\(/ { grab = 1; next }
    grab && /^\)/ { exit }
    grab { gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "") print }
  ' "$SCRIPT"
}

# Every library target PACKAGE (or the manifest given as $1) declares — a
# `.target(`, not an executable, test or system-library target — as
# `<name> <path>`, the path being its `path:` argument or SwiftPM's default
# `Sources/<name>`. It reads a declaration that opens on a line of its own and
# closes with a `)` at the opener's indentation, which is how this manifest
# writes every one, and takes `name:` and `path:` only from lines those labels
# start: a dependency's `.product(name: ...)` starts with `.product`. Lines
# outside a declaration it recognised are ignored, so a missed declaration
# cannot lend its `path:` to the one before it. A declaration written any other
# way is missed, which the `unclaimed` check below turns red.
library_targets() {
  awk '
    function flush(  p) {
      if (kind == ".target(" && name != "") {
        p = path
        if (p == "") p = "Sources/" name
        print name, p
      }
      kind = ""; name = ""; path = ""
    }
    /^[ \t]*\.[A-Za-z]+\([ \t]*$/ {
      flush(); kind = $1
      match($0, /^[ \t]*/)
      closer = "^" substr($0, 1, RLENGTH) "\\),?[ \t]*$"
      next
    }
    kind != "" && $0 ~ closer { flush(); next }
    kind != "" && name == "" && /^[ \t]*name: "/ {
      name = $0; sub(/^[ \t]*name: "/, "", name); sub(/".*/, "", name); next
    }
    kind != "" && /^[ \t]*path: "/ {
      path = $0; sub(/^[ \t]*path: "/, "", path); sub(/".*/, "", path); next
    }
    END { flush() }
  ' "${1:-$PACKAGE}"
}

# Whether $1 is one of the newline-separated lines of $2.
is_listed() {
  case "
$2
" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

# Where the wipe step's module loop, `WIPE_PATHS` and the manifest disagree, one
# line per disagreement, or nothing. Reads WORKFLOW and PACKAGE, or the workflow
# file given as $1 and the manifest given as $2.
#   `unwiped <target>` – a library target whose sources `WIPE_PATHS` compares
#     and whose artifacts the loop never removes;
#   `uncompared <module>` – a module the loop removes that is not a library
#     target whose sources `WIPE_PATHS` compares;
#   `unclaimed <path>` – a source directory in `WIPE_PATHS` that no library
#     target the parser found claims, or that more than one does.
wipe_loop_drift() {
  local paths modules targets name path claims
  paths="$(wipe_paths)"
  modules="$(wiped_modules "${1:-$WORKFLOW}")"
  targets="$(library_targets "${2:-$PACKAGE}")"
  while read -r name path; do
    [ -n "$name" ] || continue
    if is_listed "$path" "$paths" && ! is_listed "$name" "$modules"; then
      echo "unwiped $name"
    fi
  done <<EOF
$targets
EOF
  while read -r name; do
    [ -n "$name" ] || continue
    path="$(printf '%s\n' "$targets" | awk -v n="$name" '$1 == n { print $2; exit }')"
    if ! is_listed "$path" "$paths"; then
      echo "uncompared $name"
    fi
  done <<EOF
$modules
EOF
  while read -r path; do
    case "$path" in
      ''|Package.swift|Package.resolved) continue ;;
    esac
    claims="$(printf '%s\n' "$targets" | awk -v p="$path" '$2 == p { n++ } END { print n + 0 }')"
    if [ "$claims" -ne 1 ]; then
      echo "unclaimed $path"
    fi
  done <<EOF
$paths
EOF
}

test_the_wipe_step_removes_exactly_the_compared_libraries() {
  local d
  # Each reader has to have found what it looks for, or the comparison below
  # could pass on two empty lists agreeing with each other.
  assert_contains "Package.swift reads as TBDDaemonLib at its real directory" \
    "$(library_targets)" "TBDDaemonLib Sources/TBDDaemon"
  assert_contains "the wipe step's module loop was read" "$(wiped_modules)" "TBDShared"
  assert_eq "the wipe step removes every library WIPE_PATHS compares, and no other" \
    "" "$(wipe_loop_drift)"
  d="$(mktmpd)"
  echo "$d" >> "$FIXTURE_LIST"
  # MUTATION: TBDTerminalSerialization dropped from the loop, its sources still
  # compared.
  sed '/for module in /s/ TBDTerminalSerialization;/;/' "$WORKFLOW" > "$d/unwiped.yml"
  assert_eq "mutation: a compared library the loop does not remove is caught" \
    "unwiped TBDTerminalSerialization" "$(wipe_loop_drift "$d/unwiped.yml")"
  # MUTATION: a library added to the loop whose sources are not compared.
  sed '/for module in /s/TBDDaemonLib/TBDDaemonLib TBDAppIcon/' "$WORKFLOW" > "$d/uncompared.yml"
  assert_eq "mutation: a loop entry whose sources are not compared is caught" \
    "uncompared TBDAppIcon" "$(wipe_loop_drift "$d/uncompared.yml")"
  # MUTATION: the case the first two cannot see. TBDTerminalSerialization is
  # dropped from the loop AND declared in a way the parser misses — its opener
  # carries a trailing comment — so it is in neither list being compared, and
  # only its unclaimed directory in `WIPE_PATHS` is left to say so.
  awk '
    NR > 1 {
      if ($0 ~ /^[ \t]*name: "TBDTerminalSerialization"/) sub(/\($/, "( // a comment the parser does not expect", held)
      print held
    }
    { held = $0 }
    END { print held }
  ' "$PACKAGE" > "$d/Package.swift"
  assert_eq "mutation: a compared library the manifest parser misses is caught" \
    "unclaimed Sources/TBDTerminalSerialization" "$(wipe_loop_drift "$d/unwiped.yml" "$d/Package.swift")"
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
