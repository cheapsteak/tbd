#!/usr/bin/env bash
# Tests for scripts/test.sh — run: bash scripts/test.test.sh
#
# ZERO BUILDS, ZERO CPU LOAD, AND IT NEVER TOUCHES THE REAL ~/tbd, ~/.claude OR
# ~/.codex. Every case here drives the wrapper against a synthetic home under a
# throwaway fixture directory, with a stub standing in for `swift`, so the whole
# file runs in seconds on a shared box while other agents are working.
#
# THREE SEAMS MAKE THAT POSSIBLE, AND ALL THREE ALREADY EXISTED IN PRODUCTION:
#
#   HOME              scripts/test.sh reads the caller's real `$HOME` to derive
#                     the shared lock path, and `scripts/tbd-home-fingerprint.sh`
#                     reads it to decide what to fingerprint. Point it at a
#                     fixture and both observe the fixture instead.
#   TMPDIR            the fake home is `$TMPDIR/tbd-test-fakehome.<uid>`, so a
#                     fixture TMPDIR gives each case its own fake home and its
#                     own decoys.
#   TBD_SWIFT_BIN     `scripts/swift-safe` execs this instead of `swift`. The
#                     stub records the environment and argv it was handed, and
#                     can be told to misbehave — chmod a decoy back, or write
#                     into the fixture's real home as a leak would.
#
# Using TBD_SWIFT_BIN rather than stubbing out `swift-safe` itself is
# deliberate: the admission-lock cases below then exercise the REAL lock
# acquisition, so "the fenced run takes the shared lock" is proven by the shared
# lock file containing this run's details rather than by reading an assignment.
#
# EVERY GUARD IS MUTATION-CHECKED. `mutant_of` builds a copy of the script with
# one guard deliberately weakened, the case re-runs against it, and the verdict
# has to flip. A guard whose test passes for reasons unrelated to the guard is the
# failure mode this file exists to prevent: the PR that added these guards
# proved them once, by hand, and nothing would have noticed them rotting.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
# shellcheck disable=SC2016 # the sed mutation expressions must NOT expand here
# shellcheck disable=SC2088 # `~/tbd` in expectations is the fingerprint's literal output, not a path
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/test.sh"
FINGERPRINT="$HERE/tbd-home-fingerprint.sh"
# shellcheck source=/dev/null
source "$SCRIPT"   # source-guard prevents the run; brings in the guard helpers
set +e             # the sourced script's strict mode is scoped to execution

FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1; fi; }
assert_missing()  { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] unexpectedly has [$3]"; FAIL=1; fi; }
assert_ok()       { if [[ "$2" == "0" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected exit 0, got $2"; FAIL=1; fi; }
assert_nonzero()  { if [[ "$2" != "0" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected a non-zero exit, got 0"; FAIL=1; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/testsh-test.XXXXXX"; }
mode_of()         { stat -f '%Lp' "$1" 2>/dev/null; }
# The fake home's decoys are mode 000, which defeats a plain `rm -rf` — chmod
# them back first or every run leaves a fixture behind.
rmfix()           { chmod -R u+rwx "$1" 2>/dev/null; rm -rf "$1"; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# A throwaway world: a synthetic "real" home with the three stores the detector
# watches, an empty TMPDIR for the fake home to be minted in, and the stub
# swift. Echoes the fixture root.
mkfix() {
  local d; d="$(mktmpd)"
  mkdir -p "$d/home/tbd/worktrees/slot" \
           "$d/home/.claude/projects/-acme-repo" \
           "$d/home/.codex/plugins/cache" \
           "$d/tmp" "$d/bin"
  : > "$d/home/tbd/state.db"
  mkdir -p "$d/home/tbd/worktrees/slot/existing-worktree"
  cat > "$d/bin/fake-swift" <<'STUB'
#!/usr/bin/env bash
# Stands in for `swift`, exec'd by scripts/swift-safe from inside the fence.
{
  echo "argv: $*"
  echo "HOME=${HOME:-<unset>}"
  echo "CFFIXED_USER_HOME=${CFFIXED_USER_HOME:-<unset>}"
  echo "TBD_HOME=${TBD_HOME:-<unset>}"
  echo "TBD_SOCKET_PATH=${TBD_SOCKET_PATH:-<unset>}"
  echo "TBD_CLAUDE_HOST_HOME=${TBD_CLAUDE_HOST_HOME:-<unset>}"
  echo "TBD_TEST_CODEX_HOME=${TBD_TEST_CODEX_HOME:-<unset>}"
  echo "TBD_SWIFT_LOCK_PATH=${TBD_SWIFT_LOCK_PATH:-<unset>}"
  for decoy in tbd .claude .codex; do
    echo "decoy-mode $decoy=$(stat -f '%Lp' "$HOME/$decoy" 2>/dev/null)"
  done
} > "$FAKE_SWIFT_DUMP"
# Disarm a decoy mid-run, as code owning the directory could.
if [ -n "${FAKE_SWIFT_DISARM:-}" ]; then chmod 755 "$HOME/$FAKE_SWIFT_DISARM"; fi
# Write into the fixture's real home, as a leak that escaped the fence would.
if [ -n "${FAKE_SWIFT_LEAK:-}" ]; then mkdir -p "$FAKE_SWIFT_LEAK"; fi
exit "${FAKE_SWIFT_RC:-0}"
STUB
  chmod +x "$d/bin/fake-swift"
  echo "$d"
}

# Run the wrapper (or a mutant of it) against a fixture. Sets RUN_OUT and
# RUN_RC. Extra environment goes in RUN_ENV before the call.
#
# The `-u` list matters: this harness may itself be running under a fenced
# session, and an inherited TBD_HOME or TBD_SWIFT_LOCK_PATH would silently
# change which branch of the lock resolution is under test.
run_script() {
  local script="$1" fix="$2"; shift 2
  RUN_OUT="$(env -u CI -u TBD_HOME -u TBD_SOCKET_PATH -u TBD_CLAUDE_HOST_HOME \
                 -u TBD_TEST_CODEX_HOME -u TBD_SWIFT_LOCK_PATH -u CFFIXED_USER_HOME \
                 -u FAKE_SWIFT_DISARM -u FAKE_SWIFT_LEAK -u FAKE_SWIFT_RC \
                 ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
                 HOME="$fix/home" \
                 TMPDIR="$fix/tmp" \
                 TBD_SWIFT_BIN="$fix/bin/fake-swift" \
                 FAKE_SWIFT_DUMP="$fix/swift-invocation" \
                 bash "$script" "$@" 2>&1)"
  RUN_RC=$?
}

run_wrapper() { run_script "$SCRIPT" "$@"; }

# A copy of a script with one guard weakened by `sed`. Echoes its path; the
# caller runs it exactly as it runs the real one, so a green mutant means the
# assertion above it was not actually testing that guard.
#
# All mutants share one directory, removed on exit — the cases themselves clean
# up their fixtures, but a case that fails early would otherwise leave a mutant
# behind on every run.
MUTANT_DIR="$(mktmpd)"
MUTANT_SEQ=0
trap 'rm -rf "$MUTANT_DIR"' EXIT
mutant_of() {
  local source_script="$1" sed_expr="$2" out
  MUTANT_SEQ=$((MUTANT_SEQ + 1))
  out="$MUTANT_DIR/mutant.$MUTANT_SEQ.sh"
  sed -E "$sed_expr" "$source_script" > "$out"
  echo "$out"
}

dump_of()      { cat "$1/swift-invocation" 2>/dev/null; }
fake_home_of() { echo "$1/tmp/tbd-test-fakehome.$(id -u)"; }

# ---------------------------------------------------------------------------
# 1. The symlink refusal — the guard that could chmod 000 a real ~/tbd
# ---------------------------------------------------------------------------

# A victim directory standing in for the developer's home, plus a symlink at
# the fake-home path pointing at it. Echoes the victim path.
plant_symlink_fake_home() {
  local fix="$1" victim="$1/victim"
  mkdir -p "$victim/tbd" "$victim/.claude" "$victim/.codex"
  chmod 755 "$victim" "$victim/tbd" "$victim/.claude" "$victim/.codex"
  ln -s "$victim" "$(fake_home_of "$fix")"
  echo "$victim"
}

test_symlinked_fake_home_is_refused_without_chmod() {
  local fix victim; fix="$(mkfix)"; victim="$(plant_symlink_fake_home "$fix")"
  run_wrapper "$fix"
  assert_nonzero "symlinked fake home refuses to run" "$RUN_RC"
  assert_contains "refusal names the symlink" "$RUN_OUT" "the fake home is a SYMLINK"
  assert_contains "refusal explains the chmod danger" "$RUN_OUT" "THE TEST FENCE'S OWN SCRATCH HOME IS NOT SAFE"
  assert_eq "the symlink target's tbd is untouched" "755" "$(mode_of "$victim/tbd")"
  assert_eq "the symlink target's .claude is untouched" "755" "$(mode_of "$victim/.claude")"
  assert_eq "the symlink target itself is untouched" "755" "$(mode_of "$victim")"
  assert_eq "swift was never reached" "" "$(dump_of "$fix")"
  rmfix "$fix"
}

# MUTATION. Strip the `-L` tests and the same fixture chmods the victim's
# stores to 000 — which is the reproduced incident this guard was written for.
test_symlink_refusal_is_load_bearing() {
  local fix victim mutant; fix="$(mkfix)"; victim="$(plant_symlink_fake_home "$fix")"
  mutant="$(mutant_of "$SCRIPT" '/\[ -L "\$path" \] && fence_bail/d')"
  run_script "$mutant" "$fix"
  assert_eq "without the -L test the victim's tbd is chmod 000" "0" "$(mode_of "$victim/tbd")"
  assert_eq "without the -L test the victim's .claude is chmod 000" "0" "$(mode_of "$victim/.claude")"
  rmfix "$fix"
}

test_fake_home_that_is_a_regular_file_is_refused() {
  local fix; fix="$(mkfix)"
  : > "$(fake_home_of "$fix")"
  run_wrapper "$fix"
  assert_nonzero "regular file at the fake-home path refuses to run" "$RUN_RC"
  assert_contains "refusal names the non-directory" "$RUN_OUT" "exists but is not a directory"
  rmfix "$fix"
}

# The uid arm cannot be reached by running the script — creating a directory
# owned by somebody else needs root. It is reached through the sourced helper
# instead, with `id` shadowed so the check compares against a uid that is not
# the directory's owner. Same call, same directory, only the uid differs: the
# verdict flipping is what proves the comparison is load-bearing.
test_foreign_uid_dir_is_refused() {
  local fix out rc; fix="$(mkfix)"
  out="$( id() { echo 424242; }; require_owned_dir_after_mkdir "$fix/home" "the fake home" 2>&1 )"
  rc=$?
  assert_nonzero "a directory owned by another uid refuses to run" "$rc"
  assert_contains "refusal names both uids" "$out" "is owned by uid $(id -u), not 424242"
  rmfix "$fix"
}

test_own_uid_dir_is_accepted() {
  local fix out rc; fix="$(mkfix)"
  out="$( require_owned_dir_after_mkdir "$fix/home" "the fake home" 2>&1 )"
  rc=$?
  assert_ok "a directory owned by this uid is accepted" "$rc"
  assert_eq "acceptance is silent" "" "$out"
  rmfix "$fix"
}

# ---------------------------------------------------------------------------
# 2. The post-run mode-000 recheck
# ---------------------------------------------------------------------------

test_decoys_are_mode_000_during_the_run() {
  local fix; fix="$(mkfix)"
  run_wrapper "$fix"
  assert_ok "a clean run exits 0" "$RUN_RC"
  local dump; dump="$(dump_of "$fix")"
  assert_contains "tbd decoy is 000 while the suite runs" "$dump" "decoy-mode tbd=0"
  assert_contains ".claude decoy is 000 while the suite runs" "$dump" "decoy-mode .claude=0"
  assert_contains ".codex decoy is 000 while the suite runs" "$dump" "decoy-mode .codex=0"
  rmfix "$fix"
}

test_decoy_chmodded_back_during_the_run_fails_the_run() {
  local decoy fix
  for decoy in tbd .claude .codex; do
    fix="$(mkfix)"
    RUN_ENV=(FAKE_SWIFT_DISARM="$decoy")
    run_wrapper "$fix"
    RUN_ENV=()
    assert_nonzero "a disarmed $decoy decoy fails the run" "$RUN_RC"
    assert_contains "the $decoy recheck names the mode it came back as" "$RUN_OUT" "the $decoy decoy came back mode 0755"
    assert_contains "the $decoy recheck says the tripwire was disarmed" "$RUN_OUT" "the run disarmed the tripwire"
    chmod -R 755 "$fix/tmp" 2>/dev/null
    rmfix "$fix"
  done
}

# MUTATION. Neuter the mode comparison and a disarmed tripwire sails through.
test_mode_recheck_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"
  mutant="$(mutant_of "$SCRIPT" 's/\[ "\$mode" = "0" \]/[ "$mode" = "$mode" ]/')"
  RUN_ENV=(FAKE_SWIFT_DISARM="tbd")
  run_script "$mutant" "$fix"
  RUN_ENV=()
  assert_ok "without the mode comparison a disarmed decoy passes" "$RUN_RC"
  assert_missing "and nothing is reported" "$RUN_OUT" "disarmed the tripwire"
  chmod -R 755 "$fix/tmp" 2>/dev/null
  rmfix "$fix"
}

# The recheck must not be satisfiable by deleting the decoy either.
test_decoy_replaced_by_a_symlink_during_the_run_fails_the_run() {
  local fix; fix="$(mkfix)"
  run_wrapper "$fix"   # first run mints the fake home and its decoys
  local fake; fake="$(fake_home_of "$fix")"
  assert_ok "priming run is green" "$RUN_RC"
  # Stand in for a run that swapped a decoy for a symlink: the wrapper's
  # pre-run `require_owned_dir` sees it on the NEXT run and refuses.
  chmod 755 "$fake/tbd"; rmdir "$fake/tbd"; ln -s "$fix/home/tbd" "$fake/tbd"
  run_wrapper "$fix"
  assert_nonzero "a symlinked decoy refuses to run" "$RUN_RC"
  assert_contains "refusal names the tbd decoy" "$RUN_OUT" "the tbd decoy is a SYMLINK"
  assert_eq "the symlink target is untouched" "755" "$(mode_of "$fix/home/tbd")"
  rm -f "$fake/tbd"; rmfix "$fix"
}

# ---------------------------------------------------------------------------
# 3. Fingerprint diffing, through the wrapper
# ---------------------------------------------------------------------------

# Each arm leaks one entry into the fixture's real home — the shape a leak that
# got past the fence would take — and must be named in the diff.
_assert_leak_is_detected() {
  local label="$1" leak="$2" expected="$3" fix; fix="$(mkfix)"
  RUN_ENV=(FAKE_SWIFT_LEAK="$fix/home/$leak")
  run_wrapper "$fix" --fingerprint
  RUN_ENV=()
  assert_nonzero "$label fails the run" "$RUN_RC"
  assert_contains "$label is reported" "$RUN_OUT" "THE TEST RUN WROTE INTO ~/tbd, ~/.claude OR ~/.codex"
  # `+  ` — the two spaces are the rendering: `sed 's/^>/  + /'` over a diff
  # line that already carries `> `. Pinned as-is so a reformat is visible.
  assert_contains "$label names the entry" "$RUN_OUT" "+  $expected"
  chmod -R 755 "$fix/tmp" 2>/dev/null
  rmfix "$fix"
}

test_fingerprint_detects_a_new_tbd_entry() {
  _assert_leak_is_detected "a new ~/tbd entry" "tbd/profiles" "~/tbd/profiles"
}

test_fingerprint_detects_a_new_worktree_at_depth_3() {
  _assert_leak_is_detected "a new worktree" \
    "tbd/worktrees/slot/leaked-worktree" "~/tbd/worktrees/slot/leaked-worktree"
}

test_fingerprint_detects_a_new_claude_entry() {
  _assert_leak_is_detected "a new ~/.claude entry" ".claude/leaked-slot" "~/.claude/leaked-slot"
}

test_fingerprint_detects_a_new_claude_projects_entry() {
  _assert_leak_is_detected "a new ~/.claude/projects entry" \
    ".claude/projects/-acme-leaked" "~/.claude/projects/-acme-leaked"
}

test_fingerprint_detects_a_new_codex_entry() {
  _assert_leak_is_detected "a new ~/.codex entry" ".codex/leaked" "~/.codex/leaked"
}

test_fingerprint_passes_on_an_unchanged_tree() {
  local fix; fix="$(mkfix)"
  run_wrapper "$fix" --fingerprint
  assert_ok "an unchanged tree passes with detection on" "$RUN_RC"
  assert_missing "and reports nothing" "$RUN_OUT" "THE TEST RUN WROTE INTO"
  rmfix "$fix"
}

# The lock file lands in ~/tbd/runtime, which the detector prunes as volatile —
# but the wrapper creating it mid-flight would still add the `runtime` entry
# itself between the snapshots. It is created before the first snapshot for
# exactly that reason, so a home with no `runtime` directory must still pass.
test_fingerprint_passes_when_the_lock_dir_did_not_exist() {
  local fix; fix="$(mkfix)"
  assert_eq "fixture starts with no runtime dir" "false" \
    "$([ -d "$fix/home/tbd/runtime" ] && echo true || echo false)"
  run_wrapper "$fix" --fingerprint
  assert_ok "minting the lock dir does not redden detection" "$RUN_RC"
  rmfix "$fix"
}

# MUTATION. Neuter the comparison and a real leak passes silently.
test_fingerprint_comparison_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"
  mutant="$(mutant_of "$SCRIPT" 's/!= "\$fingerprint_after"/= "$fingerprint_after"/')"
  RUN_ENV=(FAKE_SWIFT_LEAK="$fix/home/tbd/profiles")
  run_script "$mutant" "$fix" --fingerprint
  RUN_ENV=()
  assert_ok "without the comparison a leak passes" "$RUN_RC"
  assert_missing "and nothing is reported" "$RUN_OUT" "THE TEST RUN WROTE INTO"
  rmfix "$fix"
}

# ---------------------------------------------------------------------------
# 3b. The fingerprint script's own arms
#
# The wrapper cases above prove each arm end to end. These prove WHICH arm did
# the catching, by deleting one arm at a time — coverage the end-to-end cases
# cannot give, since a single over-broad arm would satisfy all of them.
# ---------------------------------------------------------------------------

fingerprint_with_home() { HOME="$1" bash "$2"; }

test_fingerprint_script_covers_all_four_roots() {
  local d; d="$(mktmpd)"
  local out; out="$(fingerprint_with_home "$d" "$FINGERPRINT")"
  assert_contains "absent ~/tbd is a marker, not silence" "$out" "~/tbd <absent>"
  assert_contains "absent ~/.claude is a marker" "$out" "~/.claude <absent>"
  assert_contains "absent ~/.claude/projects is a marker" "$out" "~/.claude/projects <absent>"
  assert_contains "absent ~/.codex is a marker" "$out" "~/.codex <absent>"
  rmfix "$d"
}

# depth 3 is what sees `worktrees/<slot>/<name>` — invisible at depth 2 because
# the slot directory already exists.
test_fingerprint_script_sees_a_depth_3_worktree() {
  local fix; fix="$(mkfix)"
  local shallow; shallow="$(mutant_of "$FINGERPRINT" 's/-maxdepth 3/-maxdepth 2/')"
  local before shallow_before
  before="$(fingerprint_with_home "$fix/home" "$FINGERPRINT")"
  shallow_before="$(fingerprint_with_home "$fix/home" "$shallow")"
  mkdir -p "$fix/home/tbd/worktrees/slot/leaked"
  local after; after="$(fingerprint_with_home "$fix/home" "$FINGERPRINT")"
  assert_missing "depth-3 entry absent before" "$before" "~/tbd/worktrees/slot/leaked"
  assert_contains "depth-3 entry present after" "$after" "~/tbd/worktrees/slot/leaked"
  # MUTATION: at depth 2 the same leak is invisible, because the slot directory
  # already existed — so the two snapshots the wrapper diffs become identical.
  assert_eq "at depth 2 the worktree leak vanishes" "$shallow_before" \
    "$(fingerprint_with_home "$fix/home" "$shallow")"
  rmfix "$fix"
}

test_fingerprint_script_sees_a_claude_projects_entry() {
  local fix; fix="$(mkfix)"
  # MUTATION: drop the second ~/.claude arm, leaving only the depth-1 one.
  local one_arm; one_arm="$(mutant_of "$FINGERPRINT" 's|-d "\$real_claude/projects"|-d "/no/such/path"|')"
  local before mutant_before; before="$(fingerprint_with_home "$fix/home" "$FINGERPRINT")"
  mutant_before="$(fingerprint_with_home "$fix/home" "$one_arm")"
  mkdir -p "$fix/home/.claude/projects/-acme-leaked"
  local after mutant_after; after="$(fingerprint_with_home "$fix/home" "$FINGERPRINT")"
  mutant_after="$(fingerprint_with_home "$fix/home" "$one_arm")"
  assert_missing "projects entry absent before" "$before" "~/.claude/projects/-acme-leaked"
  assert_contains "projects entry present after" "$after" "~/.claude/projects/-acme-leaked"
  assert_contains "the depth-1 arm lists projects either way" "$mutant_after" "~/.claude/projects"
  assert_eq "without the projects arm the snapshots are identical" "$mutant_before" "$mutant_after"
  rmfix "$fix"
}

test_fingerprint_script_prunes_volatile_runtime_contents() {
  local fix; fix="$(mkfix)"
  mkdir -p "$fix/home/tbd/runtime"; : > "$fix/home/tbd/runtime/swift-build.lock"
  local before; before="$(fingerprint_with_home "$fix/home" "$FINGERPRINT")"
  : > "$fix/home/tbd/runtime/some-session-file"
  local after; after="$(fingerprint_with_home "$fix/home" "$FINGERPRINT")"
  assert_eq "runtime contents are pruned" "$before" "$after"
  assert_contains "but the runtime entry itself is fingerprinted" "$before" "~/tbd/runtime"
  rmfix "$fix"
}

# ---------------------------------------------------------------------------
# 4. --no-fingerprint disables detection, containment stays on
# ---------------------------------------------------------------------------

test_no_fingerprint_disables_detection() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(FAKE_SWIFT_LEAK="$fix/home/tbd/profiles" CI=1)
  run_wrapper "$fix" --no-fingerprint
  RUN_ENV=()
  assert_ok "--no-fingerprint passes a leaking run even under CI" "$RUN_RC"
  assert_missing "and reports no diff" "$RUN_OUT" "THE TEST RUN WROTE INTO"
  rmfix "$fix"
}

# The half that must NOT be disabled: every fence variable still points into
# the scratch dirs, and the decoys are still armed.
test_no_fingerprint_leaves_containment_intact() {
  local fix; fix="$(mkfix)"
  run_wrapper "$fix" --no-fingerprint
  assert_ok "--no-fingerprint run is green" "$RUN_RC"
  local dump; dump="$(dump_of "$fix")"
  local fake; fake="$(fake_home_of "$fix")"
  assert_contains "HOME is the fake home" "$dump" "HOME=$fake"
  assert_contains "CFFIXED_USER_HOME is the fake home" "$dump" "CFFIXED_USER_HOME=$fake"
  assert_contains "TBD_HOME is a scratch dir" "$dump" "TBD_HOME=/tmp/tbd-test-home."
  assert_contains "TBD_SOCKET_PATH is under the scratch dir" "$dump" "/sanctioned/tbd/sock"
  assert_contains "TBD_CLAUDE_HOST_HOME is under the scratch dir" "$dump" "/sanctioned/tbd/claude-host"
  assert_contains "TBD_TEST_CODEX_HOME is under the scratch dir" "$dump" "/sanctioned/tbd/codex-host"
  assert_contains "decoys are still armed" "$dump" "decoy-mode tbd=0"
  rmfix "$fix"
}

# The fence variables are OVERWRITTEN, not defaulted — an inherited value is
# discarded. TBD_SWIFT_LOCK_PATH is the documented exception and is covered in
# section 5.
test_inherited_fence_vars_are_overwritten() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(TBD_HOME="$fix/callers-home" TBD_CLAUDE_HOST_HOME="$fix/callers-claude")
  run_wrapper "$fix"
  RUN_ENV=()
  local dump; dump="$(dump_of "$fix")"
  assert_missing "an inherited TBD_HOME is discarded" "$dump" "TBD_HOME=$fix/callers-home"
  assert_missing "an inherited TBD_CLAUDE_HOST_HOME is discarded" "$dump" "TBD_CLAUDE_HOST_HOME=$fix/callers-claude"
  assert_contains "TBD_HOME is still the scratch dir" "$dump" "TBD_HOME=/tmp/tbd-test-home."
  rmfix "$fix"
}

test_ci_turns_detection_on_by_default() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(FAKE_SWIFT_LEAK="$fix/home/tbd/profiles" CI=1)
  run_wrapper "$fix"
  RUN_ENV=()
  assert_nonzero "CI=1 detects a leak with no flag" "$RUN_RC"
  rmfix "$fix"
}

test_detection_is_off_by_default_off_ci() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(FAKE_SWIFT_LEAK="$fix/home/tbd/profiles")
  run_wrapper "$fix"
  RUN_ENV=()
  assert_ok "off CI the same leak passes with no flag" "$RUN_RC"
  rmfix "$fix"
}

# Position-independent, last one wins, and neither flag reaches `swift test`.
test_fingerprint_flags_are_consumed_and_last_wins() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(FAKE_SWIFT_LEAK="$fix/home/tbd/profiles")
  run_wrapper "$fix" --parallel --fingerprint -j 2 --no-fingerprint
  assert_ok "a trailing --no-fingerprint wins" "$RUN_RC"
  assert_missing "flags are not forwarded to swift" "$(dump_of "$fix")" "fingerprint"
  assert_contains "other arguments are forwarded" "$(dump_of "$fix")" "argv: test --parallel -j 2"
  RUN_ENV=()
  rmfix "$fix"

  # A FRESH fixture: the run above already created the leak, so re-running
  # against the same home would find before == after and prove nothing.
  fix="$(mkfix)"
  RUN_ENV=(FAKE_SWIFT_LEAK="$fix/home/tbd/profiles")
  run_wrapper "$fix" --no-fingerprint --fingerprint
  RUN_ENV=()
  assert_nonzero "a trailing --fingerprint wins" "$RUN_RC"
  rmfix "$fix"
}

test_exit_status_of_the_suite_is_propagated() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(FAKE_SWIFT_RC=3)
  run_wrapper "$fix"
  RUN_ENV=()
  assert_eq "a red suite propagates its exit status" "3" "$RUN_RC"
  rmfix "$fix"
}

# ---------------------------------------------------------------------------
# 5. Admission-lock stacking — the regression this PR shipped and review caught
#
# `swift-safe` derives its lock from `$TBD_HOME/runtime/…` when
# TBD_SWIFT_LOCK_PATH is unset, and the fence points TBD_HOME at a `mktemp -d`
# unique per invocation. Leave the pinning out and every fenced run takes a
# PRIVATE lock: two concurrent runs never serialize, which is precisely the
# compiler swarm swift-safe exists to prevent.
# ---------------------------------------------------------------------------

lock_path_with() { env -u TBD_SWIFT_LOCK_PATH -u TBD_HOME "$@" bash -c \
  "source '$SCRIPT'; resolve_swift_lock_path"; }

test_lock_path_prefers_an_explicit_override() {
  assert_eq "explicit TBD_SWIFT_LOCK_PATH wins" "/x/y/shared.lock" \
    "$(lock_path_with TBD_SWIFT_LOCK_PATH=/x/y/shared.lock TBD_HOME=/t HOME=/h)"
}

test_lock_path_falls_back_to_tbd_home() {
  assert_eq "TBD_HOME is the second branch" "/t/runtime/swift-build.lock" \
    "$(lock_path_with TBD_HOME=/t HOME=/h)"
}

test_lock_path_falls_back_to_home() {
  assert_eq "HOME is the last branch" "/h/tbd/runtime/swift-build.lock" \
    "$(lock_path_with HOME=/h)"
}

# End to end, through the real swift-safe: the shared lock file must carry this
# run's details, which only happens if swift-safe actually took THAT file.
test_fenced_run_takes_the_shared_lock() {
  local fix; fix="$(mkfix)"
  run_wrapper "$fix"
  assert_ok "run is green" "$RUN_RC"
  local shared="$fix/home/tbd/runtime/swift-build.lock"
  assert_contains "the shared lock records the fenced run" "$(cat "$shared" 2>/dev/null)" "command=swift test"
  assert_contains "and the run was told to use it" "$(dump_of "$fix")" "TBD_SWIFT_LOCK_PATH=$shared"
  assert_missing "not a lock derived from the scratch TBD_HOME" "$(dump_of "$fix")" \
    "TBD_SWIFT_LOCK_PATH=/tmp/tbd-test-home."
  rmfix "$fix"
}

# MUTATION. Drop the pin from the env prefix and swift-safe derives the lock
# from the scratch TBD_HOME instead: the shared file is created but never
# taken, so it stays empty.
test_shared_lock_pin_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"
  mutant="$(mutant_of "$SCRIPT" '/^  TBD_SWIFT_LOCK_PATH="\$swift_lock_path" \\$/d')"
  run_script "$mutant" "$fix"
  assert_ok "mutant run is green (the lock is not a correctness gate)" "$RUN_RC"
  local shared="$fix/home/tbd/runtime/swift-build.lock"
  assert_eq "without the pin the shared lock is never taken" "" "$(cat "$shared" 2>/dev/null)"
  assert_contains "and the run sees no lock path at all" "$(dump_of "$fix")" "TBD_SWIFT_LOCK_PATH=<unset>"
  rmfix "$fix"
}

# The documented exception to "fence vars are overwritten": an inherited lock
# path names a lock the caller wants this run to contend on, and honouring it
# can only make the run wait for more things.
test_inherited_lock_path_is_honoured() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(TBD_SWIFT_LOCK_PATH="$fix/callers.lock")
  run_wrapper "$fix"
  RUN_ENV=()
  assert_contains "an inherited lock path is used" "$(cat "$fix/callers.lock" 2>/dev/null)" "command=swift test"
  assert_eq "and the default shared lock is not" "false" \
    "$([ -s "$fix/home/tbd/runtime/swift-build.lock" ] && echo true || echo false)"
  rmfix "$fix"
}

RUN_ENV=()
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
if [ "$FAIL" -ne 0 ]; then echo "SOME TESTS FAILED"; exit 1; fi
echo "ALL TEST-FENCE TESTS PASSED"
