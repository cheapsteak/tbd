#!/usr/bin/env bash
# Tests for scripts/dsym-prune-lib.sh — run: bash scripts/dsym-prune-lib.test.sh
#
# Fixture `.build` trees in a temp dir; no build, no real worktree touched.
# Portable find/du/rm only, so it runs on Linux and under macOS's bash 3.2.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
# shellcheck disable=SC2016 # the static check greps restart.sh for literal, unexpanded text
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/dsym-prune-lib.sh"

FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/dsym-prune-test.XXXXXX"; }

# The shapes a local debug build leaves, plus the things the prune must not
# touch: the binaries and objects themselves, a release build's bundle, a
# plugin cache's bundle, and the `.build/debug` convenience symlink.
mk_build() {
  local root="$1" debug="$1/.build/arm64-apple-macosx/debug"
  mkdir -p "$debug/TBDApp.dSYM/Contents/Resources/DWARF" \
           "$debug/TBDPackageTests.xctest/Contents/MacOS/TBDPackageTests.dSYM/Contents" \
           "$debug/TBDApp.build" \
           "$root/.build/arm64-apple-macosx/release/TBDApp.dSYM" \
           "$root/.build/plugins/cache/Plugin.dSYM"
  head -c 4096 /dev/zero > "$debug/TBDApp.dSYM/Contents/Resources/DWARF/TBDApp"
  : > "$debug/TBDApp"
  : > "$debug/TBDApp.build/main.swift.o"
  : > "$debug/TBDPackageTests.xctest/Contents/MacOS/TBDPackageTests"
  ln -s arm64-apple-macosx/debug "$root/.build/debug"
}

survivors() {
  find "$1/.build" -name '*.dSYM' -prune -print | sed "s|^$1/.build/||" | sort | tr '\n' ' '
}

KEPT_ONLY="arm64-apple-macosx/release/TBDApp.dSYM plugins/cache/Plugin.dSYM "
ALL="arm64-apple-macosx/debug/TBDApp.dSYM arm64-apple-macosx/debug/TBDPackageTests.xctest/Contents/MacOS/TBDPackageTests.dSYM $KEPT_ONLY"

test_lists_both_debug_bundles_and_nothing_else() {
  local d; d="$(mktmpd)"; mk_build "$d"
  local out; out="$(list_debug_dsyms "$d" | sed "s|^$d/.build/||" | sort | tr '\n' ' ')"
  assert_eq "lists the product and the nested test bundle" \
    "arm64-apple-macosx/debug/TBDApp.dSYM arm64-apple-macosx/debug/TBDPackageTests.xctest/Contents/MacOS/TBDPackageTests.dSYM " "$out"
  rm -rf "$d"
}

test_prunes_debug_bundles_only() {
  local d; d="$(mktmpd)"; mk_build "$d"
  local out; out="$(CI='' TBD_KEEP_DSYM='' prune_debug_dsyms "$d")"
  assert_eq "only release and plugin bundles survive" "$KEPT_ONLY" "$(survivors "$d")"
  assert_eq "the binary is kept" "yes" "$([ -f "$d/.build/arm64-apple-macosx/debug/TBDApp" ] && echo yes || echo no)"
  assert_eq "the objects are kept" "yes" "$([ -f "$d/.build/arm64-apple-macosx/debug/TBDApp.build/main.swift.o" ] && echo yes || echo no)"
  assert_eq "the test binary is kept" "yes" "$([ -f "$d/.build/arm64-apple-macosx/debug/TBDPackageTests.xctest/Contents/MacOS/TBDPackageTests" ] && echo yes || echo no)"
  assert_contains "it reports what it removed" "$out" "Removed 2 debug-symbol bundle(s)"
  rm -rf "$d"
}

test_keep_dsym_keeps_everything() {
  local d; d="$(mktmpd)"; mk_build "$d"
  local out; out="$(CI='' TBD_KEEP_DSYM=1 prune_debug_dsyms "$d")"
  assert_eq "TBD_KEEP_DSYM=1 keeps every bundle" "$ALL" "$(survivors "$d")"
  assert_eq "and says nothing" "" "$out"
  rm -rf "$d"
}

test_ci_keeps_everything() {
  local d; d="$(mktmpd)"; mk_build "$d"
  CI=true TBD_KEEP_DSYM='' prune_debug_dsyms "$d" >/dev/null
  assert_eq "CI keeps every bundle" "$ALL" "$(survivors "$d")"
  rm -rf "$d"
}

test_nothing_to_do_is_silent_and_green() {
  local d; d="$(mktmpd)"
  local out rc
  out="$(CI='' TBD_KEEP_DSYM='' prune_debug_dsyms "$d")"; rc=$?
  assert_eq "no .build -> exit 0" "0" "$rc"
  assert_eq "no .build -> silent" "" "$out"
  CI='' TBD_KEEP_DSYM='' prune_debug_dsyms ""; rc=$?
  assert_eq "empty root -> exit 0, nothing touched" "0" "$rc"
  rm -rf "$d"
}

# Another build in the same worktree may be mid-link, writing the bundle the
# prune would delete; one in a different worktree must not hold this one off.
test_holds_off_while_a_build_in_this_worktree_runs() {
  local d; d="$(mktmpd)"; mk_build "$d"
  local ps_line="4242 /usr/bin/dsymutil $d/.build/arm64-apple-macosx/debug/TBDApp -o $d/.build/arm64-apple-macosx/debug/TBDApp.dSYM"
  local out rc
  out="$(CI='' TBD_KEEP_DSYM='' DSYM_PRUNE_PS_CMD="printf '%s\n' '$ps_line'" prune_debug_dsyms "$d")"; rc=$?
  assert_eq "a running dsymutil here keeps every bundle" "$ALL" "$(survivors "$d")"
  assert_eq "and still exits 0" "0" "$rc"
  assert_contains "and says why" "$out" "a build in this worktree is still running"
  out="$(CI='' TBD_KEEP_DSYM='' DSYM_PRUNE_PS_CMD="printf '%s\n' '4242 /usr/bin/swift-frontend -c /elsewhere/Sources/a.swift' '4243 /bin/zsh $d'" prune_debug_dsyms "$d")"
  assert_eq "a build elsewhere, or a non-build process here, does not hold it off" "$KEPT_ONLY" "$(survivors "$d")"
  rm -rf "$d"
}

# Under pipefail a `grep -q` that exits on the first match SIGPIPEs the writer
# and reports a miss; the matcher must see a match with lots of ps text after it.
test_matcher_survives_pipefail_with_long_input() {
  local d rc; d="$(mktmpd)"
  { echo "1 swiftc -o /w/.build/x"
    awk 'BEGIN { for (i = 0; i < 200000; i++) print "2 /usr/bin/swift-frontend /other/path" }'
  } > "$d/ps"
  ( set -o pipefail; build_procs_name /w/.build < "$d/ps" ); rc=$?
  assert_eq "match ahead of 200k lines is still a match" "0" "$rc"
  rm -rf "$d"
}

# Static check: restart.sh cannot be run here (it builds and launches the real
# app). The prune must sit after the build-status gate, so a failed build exits
# first, and before the bundle assembly.
test_restart_prunes_after_a_successful_build() {
  local restart="$HERE/restart.sh" gate prune assemble order="wrong"
  gate="$(grep -nF '[ "$build_status" -eq 0 ] || exit "$build_status"' "$restart" | head -1 | cut -d: -f1)"
  prune="$(grep -nF 'prune_debug_dsyms "$REPO_ROOT"' "$restart" | head -1 | cut -d: -f1)"
  assemble="$(grep -nF 'assemble_app_bundle "$REPO_ROOT"' "$restart" | head -1 | cut -d: -f1)"
  if [[ -n "$gate" && -n "$prune" && -n "$assemble" ]] && (( gate < prune && prune < assemble )); then
    order="right"
  fi
  assert_eq "prune (line ${prune:-?}) is after the build gate (${gate:-?}) and before assembly (${assemble:-?})" "right" "$order"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
if [ "$FAIL" -ne 0 ]; then echo "SOME TESTS FAILED"; exit 1; fi
echo "ALL DSYM-PRUNE TESTS PASSED"
