#!/usr/bin/env bash
# Tests for scripts/test.sh — run: bash scripts/test.test.sh
#
# ZERO BUILDS, ZERO CPU LOAD, AND IT NEVER TOUCHES THE REAL ~/tbd, ~/.claude,
# ~/.codex OR THE REAL TMUX SOCKET DIRECTORY. Every case here drives the wrapper
# against a synthetic home under a throwaway fixture directory, with a stub
# standing in for `swift`, so the whole file runs in seconds on a shared box
# while other agents are working.
#
# FOUR SEAMS MAKE THAT POSSIBLE, AND EVERY ONE IS A PRODUCTION MECHANISM RATHER
# THAN A TEST-ONLY HOOK — nothing here asks the scripts under test to behave
# differently because they are under test:
#
#   HOME              scripts/test.sh reads the caller's real `$HOME` to derive
#                     the shared lock path, and `scripts/tbd-home-fingerprint.sh`
#                     reads it to decide what to fingerprint. Point it at a
#                     fixture and both observe the fixture instead.
#   TMPDIR            the fake home is `$TMPDIR/tbd-test-fakehome.<uid>`, so a
#                     fixture TMPDIR gives each case its own fake home and its
#                     own decoys.
#   TMUX_TMPDIR       the wrapper OVERWRITES it for the run but the fingerprint
#                     reads the caller's value, so a fixture value stands in for
#                     "the developer's real /tmp/tmux-<uid>" on both sides. Every
#                     run through `run_script` gets one, so no case can observe —
#                     or litter — the real socket directory.
#   TBD_SWIFT_BIN     `scripts/swift-safe` execs this instead of `swift`. The
#                     stub records the environment and argv it was handed, and
#                     can be told to misbehave — chmod a decoy back, write into
#                     the fixture's real home as a leak would, or leave tmux
#                     sockets behind in the fenced directory as a real run does.
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
# THE FIXTURES' MODES ARE ASSERTED, SO THE UMASK CANNOT BE AMBIENT. Several
# cases pin an exact mode on a directory this file created with `mkdir -p`,
# which yields 0777 masked by the umask — 755 at the common 022, but 700 at a
# hardened 077, where those assertions would red with nothing actually wrong.
# Pinning it here makes every fixture mode a property of this harness rather
# than of whoever ran it. It does NOT weaken any guard: every mode the wrapper
# itself sets, it sets with an explicit `chmod`.
umask 022
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

# The unix-socket path cap. `sun_path` is 104 bytes on darwin INCLUDING the
# terminating NUL, so 103 is the longest path a socket may have. tmux reports
# an overflow only as `error connecting to <path> (File name too long)`, which
# is why the budget is asserted here rather than left to be rediscovered.
SUN_PATH_BUDGET=103
# The longest tmux socket name this suite may mint. Today's longest is 31 bytes
# (`tbd-test-send-mismatch-` plus 8 hex characters); 50 is budgeted headroom, so
# a new suite naming its server generously does not have to re-derive this.
LONGEST_SOCKET_NAME_BYTES=50
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
  echo "TMUX_TMPDIR=${TMUX_TMPDIR:-<unset>}"
  echo "tmux-tmpdir-mode=$(stat -f '%Lp' "${TMUX_TMPDIR:-/nonexistent}" 2>/dev/null)"
  echo "TBD_SWIFT_LOCK_PATH=${TBD_SWIFT_LOCK_PATH:-<unset>}"
  for decoy in tbd .claude .codex; do
    echo "decoy-mode $decoy=$(stat -f '%Lp' "$HOME/$decoy" 2>/dev/null)"
  done
} > "$FAKE_SWIFT_DUMP"
# Disarm a decoy mid-run, as code owning the directory could.
if [ -n "${FAKE_SWIFT_DISARM:-}" ]; then chmod 755 "$HOME/$FAKE_SWIFT_DISARM"; fi
# Write into the fixture's real home, as a leak that escaped the fence would.
if [ -n "${FAKE_SWIFT_LEAK:-}" ]; then mkdir -p "$FAKE_SWIFT_LEAK"; fi
# Leave sockets where the run's tmux servers would leave them. tmux creates
# `$TMUX_TMPDIR/tmux-<uid>` itself and never unlinks a socket on server exit,
# so this is what the directory looks like when the suite finishes — dead
# files, possibly with live servers still behind some of them.
if [ -n "${FAKE_SWIFT_TMUX_SOCKETS:-}" ]; then
  socket_dir="${TMUX_TMPDIR:-/nonexistent}/tmux-$(id -u)"
  mkdir -p "$socket_dir"
  for socket_name in $FAKE_SWIFT_TMUX_SOCKETS; do : > "$socket_dir/$socket_name"; done
fi
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
# change which branch of the lock resolution is under test. Every OTHER knob
# `scripts/swift-safe` reads is cleared for the same reason — the cases below
# run the REAL wrapper, so a developer's exported TBD_SWIFT_JOBS decides
# whether a forwarded `-j 2` is admitted at all, and an exported timeout,
# heartbeat or orphan hatch decides how the admission-lock cases wait.
# TBD_SWIFT_BIN is the deliberate exception: this harness sets it itself, below.
#
# `TMUX_TMPDIR` is pinned rather than unset, and it stands in for the
# DEVELOPER'S REAL socket directory: the wrapper overwrites it for the run, so
# what the fixture value actually controls is which directory the fingerprint
# observes on both sides. Leaving it unset would point that at the real
# `/tmp/tmux-<uid>`, where a live daemon on a developer box creates and removes
# sockets throughout — the fingerprint cases would flake, and they would be
# reporting the machine rather than the wrapper. It doubles as the bogus
# inherited value the overwrite case asserts against.
run_script() {
  local script="$1" fix="$2"; shift 2
  RUN_OUT="$(env -u CI -u TBD_HOME -u TBD_SOCKET_PATH -u TBD_CLAUDE_HOST_HOME \
                 -u TBD_TEST_CODEX_HOME -u TBD_SWIFT_LOCK_PATH -u CFFIXED_USER_HOME \
                 -u TBD_SWIFT_JOBS -u TBD_SWIFT_LOCK_TIMEOUT_SECONDS \
                 -u TBD_SWIFT_HEARTBEAT_SECONDS -u TBD_SWIFT_ALLOW_ORPHAN \
                 -u FAKE_SWIFT_DISARM -u FAKE_SWIFT_LEAK -u FAKE_SWIFT_RC \
                 -u FAKE_SWIFT_TMUX_SOCKETS \
                 ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
                 HOME="$fix/home" \
                 TMPDIR="$fix/tmp" \
                 TMUX_TMPDIR="$(caller_tmux_tmpdir "$fix")" \
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

# The fixture's stand-in for the developer's real `/tmp/tmux-<uid>` parent —
# what the CALLER has in `TMUX_TMPDIR`, and therefore what the fingerprint
# watches. Deliberately not created: an absent directory is a valid starting
# state and the arm has an `<absent>` marker for it.
caller_tmux_tmpdir()      { echo "$1/real-tmux"; }
caller_tmux_socket_dir()  { echo "$(caller_tmux_tmpdir "$1")/tmux-$(id -u)"; }
# What the wrapper handed the run, read back out of the stub's dump.
fenced_tmux_tmpdir()      { dump_of "$1" | sed -n 's/^TMUX_TMPDIR=//p'; }
tmux_log_of()             { cat "$1/tmux-invocations" 2>/dev/null; }

# A stub `tmux` on PATH, recording every argv it is handed. The wrapper's
# cleanup sweep resolves tmux with `command -v`, so a PATH prefix is all it
# takes to observe the sweep without a real tmux server anywhere.
mk_stub_tmux() {
  local fix="$1"
  mkdir -p "$fix/tmuxbin"
  cat > "$fix/tmuxbin/tmux" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_TMUX_LOG:-/dev/null}"
exit 0
STUB
  chmod +x "$fix/tmuxbin/tmux"
}

# The longest socket path the fence can produce: its directory, the `tmux-<uid>`
# subdirectory tmux appends, and a socket name at the budgeted maximum.
worst_case_socket_path() {
  local dir="$1" name=""
  while [ "${#name}" -lt "$LONGEST_SOCKET_NAME_BYTES" ]; do name="${name}x"; done
  echo "$dir/tmux-$(id -u)/$name"
}

# "within" / "over (N > cap)" — a verdict rather than a boolean, so a failing
# assertion prints the length that blew the budget.
sun_path_verdict() {
  local path="$1"
  if [ "${#path}" -le "$SUN_PATH_BUDGET" ]; then
    echo "within"
  else
    echo "over (${#path} > $SUN_PATH_BUDGET)"
  fi
}

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
  assert_contains "$label is reported" "$RUN_OUT" "THE TEST RUN WROTE INTO ~/tbd, ~/.claude, ~/.codex OR /tmp/tmux-<uid>"
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

# `TMUX_TMPDIR` is derived from the fixture home for the same reason the
# wrapper cases pin it: unset would point the tmux arm at the developer's real
# `/tmp/tmux-<uid>`, which exists and churns on any box with a live daemon.
fingerprint_with_home() { HOME="$1" TMUX_TMPDIR="$1/tmux-tmpdir" bash "$2"; }

# ARMS, NOT ROOTS — the two counts differ and the smaller one is the tempting
# mistake. There are four roots (`~/tbd`, `~/.claude`, `~/.codex`, the tmux
# socket dir) but SIX arms, because `~/.claude` and `~/.codex` are each read
# twice: a `-maxdepth 1` pass over the store itself, then a second pass at a
# nested directory the depth limit puts out of the first one's reach. An arm
# with no assertion here can be deleted wholesale and this file stays green —
# that is how the `~/.codex/plugins/cache` arm went untested — so the
# enumeration IS the coverage. Count in arms, and add a line when you add one.
test_fingerprint_script_covers_every_arm() {
  local d; d="$(mktmpd)"
  local out; out="$(fingerprint_with_home "$d" "$FINGERPRINT")"
  assert_contains "absent ~/tbd is a marker, not silence" "$out" "~/tbd <absent>"
  assert_contains "absent ~/.claude is a marker" "$out" "~/.claude <absent>"
  assert_contains "absent ~/.claude/projects is a marker" "$out" "~/.claude/projects <absent>"
  assert_contains "absent ~/.codex is a marker" "$out" "~/.codex <absent>"
  assert_contains "absent ~/.codex/plugins/cache is a marker" "$out" "~/.codex/plugins/cache <absent>"
  assert_contains "absent socket dir is a marker" "$out" "<tmux-sockets> <absent>"
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
  # TBD_SWIFT_JOBS is pinned because the forwarded `-j 2` must clear
  # swift-safe's bound: left unset it rides on that wrapper's DEFAULT_JOBS, and
  # lowering that constant would red this case as if forwarding had broken.
  RUN_ENV=(FAKE_SWIFT_LEAK="$fix/home/tbd/profiles" TBD_SWIFT_JOBS=2)
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

# ---------------------------------------------------------------------------
# 6. The tmux socket fence
#
# tmux resolves every `-L <name>` under `$TMUX_TMPDIR/tmux-<uid>/`, and it NEVER
# unlinks a socket file when its server exits — it unlinks a stale one lazily at
# bind time, when a new server claims that exact path. Every test mints a fresh
# UUID-suffixed name, so nothing ever reclaims one and the files accumulate
# forever: ~7,100 dead sockets in nine days on one box. No teardown can fix
# that; only a fenced directory that gets deleted wholesale can.
# ---------------------------------------------------------------------------

test_tmux_tmpdir_is_fenced_under_the_scratch_root() {
  local fix; fix="$(mkfix)"
  run_wrapper "$fix"
  assert_ok "a clean run exits 0" "$RUN_RC"
  local dump; dump="$(dump_of "$fix")"
  assert_contains "TMUX_TMPDIR is a scratch dir" "$dump" "TMUX_TMPDIR=/tmp/tbd-test-home."
  assert_contains "and it is the run's own tmux dir" "$dump" "/tmux"
  assert_missing "the caller's socket dir is discarded" "$dump" \
    "TMUX_TMPDIR=$(caller_tmux_tmpdir "$fix")"
  rmfix "$fix"
}

# MUTATION. Drop the pin from the env prefix and the run inherits the caller's
# socket directory — every server it starts lands in the real one, forever.
test_tmux_tmpdir_pin_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"
  mutant="$(mutant_of "$SCRIPT" '/^  TMUX_TMPDIR="\$tmux_tmpdir" \\$/d')"
  run_script "$mutant" "$fix"
  local dump; dump="$(dump_of "$fix")"
  assert_contains "without the pin the caller's value survives" "$dump" \
    "TMUX_TMPDIR=$(caller_tmux_tmpdir "$fix")"
  assert_missing "and nothing points at the scratch dir" "$dump" \
    "TMUX_TMPDIR=/tmp/tbd-test-home."
  rmfix "$fix"
}

test_fenced_tmux_dir_exists_and_is_mode_700_during_the_run() {
  local fix; fix="$(mkfix)"
  run_wrapper "$fix"
  assert_contains "the fenced tmux dir is 700 while the suite runs" \
    "$(dump_of "$fix")" "tmux-tmpdir-mode=700"
  rmfix "$fix"
}

# MUTATION. Without the chmod the directory takes the umask — group- and
# world-readable on a default box, which is a socket anyone can connect to.
#
# THE UMASK IS PINNED, and that is what makes this case an assertion rather
# than a reading of the developer's shell. `mkdir -p` creates 0777 masked by
# the umask, so the mutant's mode is a function of ambient state: at 022 it is
# 755 (the case is meaningful), but at 077 it is *already* 700 and the case
# would red on a hardened box while nothing was wrong. Pinning 022 also lets
# this assert the exact composed mode instead of "not 700", which is the
# whitelist shape the rest of this file uses.
test_fenced_tmux_dir_chmod_is_load_bearing() {
  local fix mutant prior_umask; fix="$(mkfix)"
  mutant="$(mutant_of "$SCRIPT" '/^chmod 700 "\$tmux_tmpdir"$/d')"
  prior_umask="$(umask)"
  umask 022
  run_script "$mutant" "$fix"
  umask "$prior_umask"
  local dump; dump="$(dump_of "$fix")"
  assert_contains "without the chmod the dir takes the umask, not 700" \
    "$dump" "tmux-tmpdir-mode=755"
  rmfix "$fix"
}

# THE BUDGET CASE. This is what stops a future refactor from nesting the fenced
# directory deeper and reintroducing `error connecting to <path> (File name too
# long)` across every live tmux test at once.
test_fenced_tmux_socket_path_fits_sun_path() {
  local fix; fix="$(mkfix)"
  run_wrapper "$fix"
  local path; path="$(worst_case_socket_path "$(fenced_tmux_tmpdir "$fix")")"
  assert_eq "the worst-case socket path fits sun_path" "within" "$(sun_path_verdict "$path")"

  # MUTATION: the same budget against a fence dir nested a few components
  # deeper — the exact refactor this case exists to refuse.
  local mutant deep
  mutant="$(mutant_of "$SCRIPT" \
    's|^tmux_tmpdir="\$scratch_home/tmux"$|tmux_tmpdir="$scratch_home/sanctioned/tbd/runtime/tmux-sockets"|')"
  run_script "$mutant" "$fix"
  deep="$(worst_case_socket_path "$(fenced_tmux_tmpdir "$fix")")"
  assert_contains "the mutant really nested it deeper" "$deep" "/sanctioned/tbd/runtime/tmux-sockets/"
  assert_contains "a deeper fence dir blows the budget" "$(sun_path_verdict "$deep")" "over ("
  rmfix "$fix"
}

# The sweep is about PROCESSES, not files: `rm -rf` would unlink the socket and
# leave a live server running forever with nothing able to reach it.
test_cleanup_sweeps_the_runs_tmux_servers() {
  local fix; fix="$(mkfix)"; mk_stub_tmux "$fix"
  RUN_ENV=(PATH="$fix/tmuxbin:$PATH" FAKE_TMUX_LOG="$fix/tmux-invocations"
           FAKE_SWIFT_TMUX_SOCKETS="tbd-sweep-a tbd-sweep-b")
  run_wrapper "$fix"
  RUN_ENV=()
  assert_ok "a run that left sockets behind still exits 0" "$RUN_RC"
  local log; log="$(tmux_log_of "$fix")"
  assert_contains "the first server is killed" "$log" "/tmux-$(id -u)/tbd-sweep-a kill-server"
  assert_contains "the second server is killed" "$log" "/tmux-$(id -u)/tbd-sweep-b kill-server"
  assert_contains "by socket path, not by name" "$log" "-S /tmp/tbd-test-home."
  rmfix "$fix"
}

# MUTATION. Drop the sweep and the scratch dir still disappears — which is
# exactly the silent failure: the files are gone and the servers are not.
test_cleanup_sweep_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"; mk_stub_tmux "$fix"
  mutant="$(mutant_of "$SCRIPT" 's/sweep_tmux_servers; rm -rf/rm -rf/')"
  RUN_ENV=(PATH="$fix/tmuxbin:$PATH" FAKE_TMUX_LOG="$fix/tmux-invocations"
           FAKE_SWIFT_TMUX_SOCKETS="tbd-sweep-a tbd-sweep-b")
  run_script "$mutant" "$fix"
  RUN_ENV=()
  assert_ok "the mutant run is green (a sweep is not a correctness gate)" "$RUN_RC"
  assert_eq "without the sweep no server is killed" "" "$(tmux_log_of "$fix")"
  rmfix "$fix"
}

# The detector's fourth ROOT — its sixth arm, since `~/.claude` and `~/.codex`
# are each read twice — directly: a socket appearing in the CALLER's socket
# directory between two snapshots must change the fingerprint.
test_fingerprint_script_sees_a_new_tmux_socket() {
  local fix; fix="$(mkfix)"
  # MUTATION: point the arm's existence test at a path that never exists, so it
  # always takes the `<absent>` branch and reports nothing.
  local no_arm; no_arm="$(mutant_of "$FINGERPRINT" 's|-d "\$real_tmux"|-d "/no/such/path"|')"
  mkdir -p "$fix/home/tmux-tmpdir/tmux-$(id -u)"
  local before mutant_before
  before="$(fingerprint_with_home "$fix/home" "$FINGERPRINT")"
  mutant_before="$(fingerprint_with_home "$fix/home" "$no_arm")"
  : > "$fix/home/tmux-tmpdir/tmux-$(id -u)/tbd-leaked-socket"
  local after mutant_after
  after="$(fingerprint_with_home "$fix/home" "$FINGERPRINT")"
  mutant_after="$(fingerprint_with_home "$fix/home" "$no_arm")"
  assert_missing "socket absent before" "$before" "<tmux-sockets>/tbd-leaked-socket"
  assert_contains "socket present after" "$after" "<tmux-sockets>/tbd-leaked-socket"
  assert_eq "without the arm the snapshots are identical" "$mutant_before" "$mutant_after"
  rmfix "$fix"
}

# End to end through the wrapper, which is also what proves the arm reads the
# CALLER's TMUX_TMPDIR: the run itself was fenced elsewhere, yet a write to the
# caller's socket directory still reddens the diff.
test_fingerprint_detects_a_leaked_tmux_socket() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(FAKE_SWIFT_LEAK="$(caller_tmux_socket_dir "$fix")/tbd-leaked-socket")
  run_wrapper "$fix" --fingerprint
  RUN_ENV=()
  assert_nonzero "a leaked tmux socket fails the run" "$RUN_RC"
  assert_contains "it is reported" "$RUN_OUT" \
    "THE TEST RUN WROTE INTO ~/tbd, ~/.claude, ~/.codex OR /tmp/tmux-<uid>"
  assert_contains "the entry is named" "$RUN_OUT" "+  <tmux-sockets>/tbd-leaked-socket"
  assert_contains "and the fix is named" "$RUN_OUT" "the fix is TMUX_TMPDIR"
  rmfix "$fix"
}

RUN_ENV=()
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
if [ "$FAIL" -ne 0 ]; then echo "SOME TESTS FAILED"; exit 1; fi
echo "ALL TEST-FENCE TESTS PASSED"
