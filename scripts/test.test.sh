#!/usr/bin/env bash
# Tests for scripts/test.sh — run: bash scripts/test.test.sh
#
# MACOS ONLY, AND LOUDLY SO. `mode_of` reads the file mode with BSD `stat -f`,
# which GNU `stat` spells differently, so on Linux the mode comes back empty and
# the decoy cases fail rather than passing vacuously. That is why this file runs
# in the macOS `lint` job while the other script harnesses run on `ubuntu-latest`
# (.github/workflows/test.yml).
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
#
# IT COUNTS ITS INVOCATIONS AND CAN VERDICT EACH ONE DIFFERENTLY. The remote
# verification valve's fallback runs the fenced invocation a SECOND time, so a
# stub with one fixed exit code cannot express "yielded the queue, then passed
# locally". FAKE_SWIFT_RC is a space-separated list indexed by invocation, with
# the last value repeating for any run beyond its length — so an unset or
# single value behaves exactly as it always has.
#
# The dump is still OVERWRITTEN each time, so it describes the LAST invocation.
# That is what the fallback cases assert against: the re-run must be fenced
# identically and must NOT carry the yield bound.
printf 'invocation\n' >> "$FAKE_SWIFT_DUMP.count"
fake_swift_invocation="$(wc -l < "$FAKE_SWIFT_DUMP.count" | tr -d ' ')"
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
  echo "TBD_SWIFT_QUEUE_YIELD_SECONDS=${TBD_SWIFT_QUEUE_YIELD_SECONDS:-<unset>}"
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
# Unquoted on purpose: FAKE_SWIFT_RC is a space-separated list.
fake_swift_codes=(${FAKE_SWIFT_RC:-0})
fake_swift_index=$((fake_swift_invocation - 1))
if [ "$fake_swift_index" -ge "${#fake_swift_codes[@]}" ]; then
  fake_swift_index=$(( ${#fake_swift_codes[@]} - 1 ))
fi
fake_swift_rc="${fake_swift_codes[$fake_swift_index]}"
# THE POPULATION LINE SIX FLOOR CONSUMERS GREP FOR, in the wording they grep
# for. FAKE_SWIFT_TEST_COUNT unset prints nothing, which is what every case
# outside the count ones wants. A 76 prints nothing either, whatever the count
# says: 76 stands in for a queue yielded before anything compiled, and a summary
# from a run that never ran would put a count in the log the fence never
# produced.
if [ -n "${FAKE_SWIFT_TEST_COUNT:-}" ] && [ "$fake_swift_rc" != "76" ]; then
  echo "Test run with ${FAKE_SWIFT_TEST_COUNT} tests passed after 0.1 seconds."
fi
exit "$fake_swift_rc"
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
#
# `RUN_CWD` names the directory to run from, and it is a seam of the same kind:
# `scripts/test.sh` resolves `scripts/swift-safe`, `scripts/remote-verify.sh`
# and the fingerprint script relative to `git rev-parse --show-toplevel`, so a
# case that wants a stub in place of one of them puts the wrapper in a fixture
# repository rather than asking the wrapper for an override it would never need
# in production. Empty means "wherever the harness was invoked" — the real repo
# — which is what every case outside section 7 wants.
#
# `RUN_TEE` names a file the run's output is STREAMED to while it happens.
# `RUN_OUT` is a command substitution, so it exists only once the run is over —
# which is no use to a case that must observe a run mid-flight and act on what
# it sees (the lock-contention cases in section 7). `pipefail` is on for this
# file, and `tee` never fails, so `RUN_RC` is still the wrapper's own status.
# Empty means `/dev/null`, which is every other case.
RUN_CWD=""
RUN_TEE=""
run_script() {
  local script="$1" fix="$2"; shift 2
  RUN_OUT="$(cd "${RUN_CWD:-.}" && env -u CI -u TBD_HOME -u TBD_SOCKET_PATH -u TBD_CLAUDE_HOST_HOME \
                 -u TBD_TEST_CODEX_HOME -u TBD_SWIFT_LOCK_PATH -u CFFIXED_USER_HOME \
                 -u TBD_SWIFT_JOBS -u TBD_SWIFT_LOCK_TIMEOUT_SECONDS \
                 -u TBD_SWIFT_HEARTBEAT_SECONDS -u TBD_SWIFT_ALLOW_ORPHAN \
                 -u FAKE_SWIFT_DISARM -u FAKE_SWIFT_LEAK -u FAKE_SWIFT_RC \
                 -u FAKE_SWIFT_TMUX_SOCKETS -u FAKE_SWIFT_TEST_COUNT \
                 -u TBD_REMOTE_VERIFY -u TBD_REMOTE_VERIFY_YIELD_SECONDS \
                 -u TBD_SWIFT_QUEUE_YIELD_SECONDS \
                 -u FAKE_REMOTE_VERIFY_RC -u FAKE_REMOTE_VERIFY_LOG \
                 -u FAKE_REMOTE_VERIFY_COUNT -u FAKE_REMOTE_VERIFY_ARGV \
                 ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
                 HOME="$fix/home" \
                 TMPDIR="$fix/tmp" \
                 TMUX_TMPDIR="$(caller_tmux_tmpdir "$fix")" \
                 TBD_SWIFT_BIN="$fix/bin/fake-swift" \
                 FAKE_SWIFT_DUMP="$fix/swift-invocation" \
                 bash "$script" "$@" 2>&1 | tee "${RUN_TEE:-/dev/null}")"
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

# How many times the fenced invocation actually ran. The valve's fallback is
# the only thing that makes this exceed 1, and asserting the COUNT is what
# distinguishes "fell back and re-ran locally" from "reported the remote
# verdict" — both of which can end in the same exit status.
swift_invocations() {
  local counted="$1/swift-invocation.count"
  if [ -f "$counted" ]; then wc -l < "$counted" | tr -d ' '; else echo 0; fi
}

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
  mutant="$(mutant_of "$SCRIPT" '/^ +TBD_SWIFT_LOCK_PATH="\$swift_lock_path" \\$/d')"
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
  mutant="$(mutant_of "$SCRIPT" '/^ +TMUX_TMPDIR="\$tmux_tmpdir" \\$/d')"
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

# ---------------------------------------------------------------------------
# 7. The remote verification valve
#
# `scripts/test.sh` is the only caller that opts in. When `TBD_REMOTE_VERIFY=1`
# it bounds its queueing with `TBD_SWIFT_QUEUE_YIELD_SECONDS`, and `swift-safe`
# answers 76 — "I gave up my place in the queue, having compiled nothing" — at
# which point the verdict is fetched from CI instead.
#
# TWO EXIT CODES CARRY THE WHOLE DESIGN AND BOTH ARE EASY TO GET WRONG:
#
#   76 vs 75.  `swift-safe` exits 75 for a wait that TIMED OUT or was ABANDONED
#              and 76 only for a yield it was ASKED for. Routing a 75 to CI
#              would dispatch a run nobody is waiting for; treating a 76 as a
#              test failure would report a red suite that never compiled.
#   78 vs 1.   `remote-verify.sh` exits 78 for a REFUSED precondition, which
#              must fall back to a local run — the valve is an optimisation,
#              never a gate — and 1 for a remote run that genuinely FAILED,
#              which is the verdict.
#
# AND ONE MISCONFIGURATION LOOKS EXACTLY LIKE A RED SUITE. `swift-safe` rejects
# a non-positive, nan, inf or non-numeric yield bound with `SystemExit`, which
# exits 1 — the same code a failing suite returns. `TBD_REMOTE_VERIFY_YIELD_SECONDS=0`
# is the plausible way to spell "always go remote", so the bound is validated
# here, before the run starts, and refused with its own code and its own name.
# ---------------------------------------------------------------------------

# The spec's threshold, sized against remote capacity rather than impatience:
# two hours of sampled contention put T=60 at ~28 trips an hour against a
# remote that sustains ~12 runs an hour, while T=300 trips four or five times
# and fires only on the tail the valve exists for.
DEFAULT_YIELD_SECONDS=300

# A fixture repository, so the wrapper's own relative `scripts/remote-verify.sh`
# resolves to a stub. `scripts/test.sh` cd's to `git rev-parse --show-toplevel`
# before doing anything, so running it from here is all it takes — the real
# `swift-safe` and fingerprint scripts are symlinked in so every other layer of
# the wrapper behaves exactly as it does in the real tree. Echoes the repo path.
mk_repo_fixture() {
  local fix="$1" repo="$1/repo"
  mkdir -p "$repo/scripts"
  git init -q "$repo" >/dev/null 2>&1
  ln -sf "$HERE/swift-safe" "$repo/scripts/swift-safe"
  ln -sf "$FINGERPRINT" "$repo/scripts/tbd-home-fingerprint.sh"
  cat > "$repo/scripts/remote-verify.sh" <<'STUB'
#!/usr/bin/env bash
# Stands in for the remote path. It records that it was reached — the valve
# must consult it exactly once, and only when the queue was yielded — records
# the argv it was handed, and returns whichever verdict the case is exercising.
#
# IT MODELS THE ONE PART OF THE DRIVER'S OUTPUT ANYTHING DOWNSTREAM READS: the
# `Test run with N tests` line, which six floor consumers grep out of a log and
# take the FIRST of. `FAKE_REMOTE_VERIFY_COUNT` is the whole-suite population it
# claims; unset prints nothing, which is what every case outside the count ones
# wants.
#
# `--narrowed` is the caller declaring it asked for less than the whole suite,
# and the driver's contract on that flag is to omit the count from a FAILING
# report only. That caller is about to re-run locally and print a count of its
# own, and the first count in the log has to be the run whose verdict is
# reported. A PASSING report always states its population — there the remote
# verdict is the one adopted, and a whole-suite count clears a narrowed floor
# legitimately, being a minimum measured against a superset.
echo "dispatched" >> "${FAKE_REMOTE_VERIFY_LOG:-/dev/null}"
printf '%s\n' "$*" >> "${FAKE_REMOTE_VERIFY_ARGV:-/dev/null}"
fake_remote_narrowed=0
for fake_remote_arg in "$@"; do
  case "$fake_remote_arg" in --narrowed) fake_remote_narrowed=1 ;; esac
done
fake_remote_rc="${FAKE_REMOTE_VERIFY_RC:-0}"
if [ -n "${FAKE_REMOTE_VERIFY_COUNT:-}" ]; then
  if [ "$fake_remote_rc" = "0" ]; then
    echo "remote-verify: Test run with $FAKE_REMOTE_VERIFY_COUNT tests passed remotely." >&2
  elif [ "$fake_remote_rc" = "1" ] && [ "$fake_remote_narrowed" -eq 0 ]; then
    echo "remote-verify: Test run with $FAKE_REMOTE_VERIFY_COUNT tests failed remotely." >&2
  fi
fi
echo "remote-verify: stub reached" >&2
exit "$fake_remote_rc"
STUB
  chmod +x "$repo/scripts/remote-verify.sh"
  echo "$repo"
}

remote_verify_dispatches() {
  local log="$1/remote-verify-log"
  if [ -f "$log" ]; then wc -l < "$log" | tr -d ' '; else echo 0; fi
}

# The argv the wrapper handed the remote path, one dispatch per line.
remote_verify_argv() { cat "$1/remote-verify-argv" 2>/dev/null; }

# WHAT A FLOOR CONSUMER WOULD READ OUT OF THIS RUN'S LOG — the first
# `Test run with N tests`, extracted exactly as `scripts/git-hooks/pre-push`,
# `scripts/nightly-flake-stress.sh` and the three `test.yml` steps extract it,
# `head -1` included. Asserting through the consumer's own reading is the point:
# a count that is merely PRESENT somewhere in the log proves nothing, since the
# floor only ever sees the first one.
first_reported_test_count() {
  printf '%s\n' "$1" | grep -oE 'Test run with [0-9]+ tests?' | grep -oE '[0-9]+' | head -1
}

# Run the wrapper from a fixture repo, with the remote path stubbed.
#
#   run_with_valve FIX [SCRIPT [ARG...]]
#
# SCRIPT is spelled out rather than defaulted-around when arguments follow it,
# because the narrowing cases need both at once: a mutant AND a `--filter`.
run_with_valve() {
  local fix="$1" script="$SCRIPT"
  shift
  if [ $# -gt 0 ]; then script="$1"; shift; fi
  RUN_CWD="$fix/repo"
  run_script "$script" "$fix" "$@"
  RUN_CWD=""
}

test_the_valve_is_off_by_default() {
  local fix; fix="$(mkfix)"
  run_wrapper "$fix"
  assert_ok "a run with the flag unset is green" "$RUN_RC"
  assert_contains "no yield bound reaches swift-safe" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=<unset>"
  rmfix "$fix"
}

# MUTATION. Force the flag on and the default-off case above is a lie: the same
# unset environment starts bounding its queueing.
test_the_valve_flag_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"
  mutant="$(mutant_of "$SCRIPT" 's/\[ "\$\{TBD_REMOTE_VERIFY:-\}" = "1" \]/[ "1" = "1" ]/')"
  run_script "$mutant" "$fix"
  assert_contains "without the flag check an unset environment yields anyway" \
    "$(dump_of "$fix")" "TBD_SWIFT_QUEUE_YIELD_SECONDS=$DEFAULT_YIELD_SECONDS"
  rmfix "$fix"
}

# THE BOUND THE CONTENTION CASES EXPORT, AND THE MARGIN THEY WAIT PAST IT.
# `swift-safe` measures the bound from the moment it starts waiting — which is
# the moment it prints the line the cases below poll for — so the margin is
# relative to the bound and to nothing else. No case here waits on a wall-clock
# guess about how long the wrapper's preamble takes, because on a loaded box
# that guess is wrong and the case that made it passes vacuously.
INHERITED_YIELD_SECONDS=0.4
PAST_THE_BOUND_SECONDS=1.5
# How long a case will wait for something it is certain must happen — the
# holder taking the lock, the queued run announcing itself, the run giving up.
# Generous, because it only bounds a WEDGE: reaching it is a failure with a
# named cause, never a verdict. Expressed in 0.05s polls, which is also what
# the holder is handed.
WEDGE_DEADLINE_SECONDS=60
WEDGE_DEADLINE_POLLS=1200

# Poll until a file exists, or the deadline passes. Answers "waited" / "wedged"
# so a failing assertion says which.
await_file() {
  local path="$1" waited=0
  while [ ! -e "$path" ] && [ "$waited" -lt "$WEDGE_DEADLINE_POLLS" ]; do
    sleep 0.05; waited=$((waited + 1))
  done
  if [ -e "$path" ]; then echo "waited"; else echo "wedged"; fi
}

# The same, for a string appearing in a file a live run is still writing to.
await_text() {
  local path="$1" needle="$2" waited=0
  while ! grep -q -- "$needle" "$path" 2>/dev/null && [ "$waited" -lt "$WEDGE_DEADLINE_POLLS" ]; do
    sleep 0.05; waited=$((waited + 1))
  done
  if grep -q -- "$needle" "$path" 2>/dev/null; then echo "waited"; else echo "wedged"; fi
}

# A REAL SECOND HOLDER ON THE REAL LOCK — the contention a yield needs, and
# nothing else in this file simulates it. `swift-safe` takes an exclusive
# `flock`, so the only way to make a run queue is to hold that lock from another
# process; a stub could only assert that the bound was forwarded, which is the
# half of the defect that was already visible.
#
# IT HOLDS UNTIL RELEASED, NOT FOR A FIXED TIME. A timed hold has to outlast the
# wrapper's preamble — a scratch home, three decoys, a fingerprint, a python
# interpreter — and on a loaded box that took longer than any hold worth
# writing, at which point the run acquires an uncontended lock and the case
# proves nothing. The holder's own deadline is a wedge guard, not a schedule.
LOCK_HOLDER_PID=""
hold_the_shared_lock() {
  local lock="$1" ready="$2" release="$3"
  mkdir -p "$(dirname "$lock")"
  rm -f "$ready" "$release"
  python3 - "$lock" "$ready" "$release" "$WEDGE_DEADLINE_SECONDS" <<'HOLDER' &
import fcntl, os, sys, time
lock_path, ready_path, release_path, deadline_seconds = sys.argv[1:5]
with open(lock_path, "a+", encoding="utf-8") as handle:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    open(ready_path, "w", encoding="utf-8").close()
    deadline = time.monotonic() + float(deadline_seconds)
    while not os.path.exists(release_path) and time.monotonic() < deadline:
        time.sleep(0.05)
HOLDER
  LOCK_HOLDER_PID=$!
  assert_eq "the holder took the shared lock" "waited" "$(await_file "$ready")"
}

release_the_shared_lock() {
  local release="$1"
  : > "$release"
  wait "$LOCK_HOLDER_PID" 2>/dev/null
  LOCK_HOLDER_PID=""
}

# The wrapper, running while the case watches it. `run_script` captures its
# output with a command substitution, so it hands back nothing until the run is
# over — and a run queued behind a held lock is not over. The subshell writes
# the status to a file, whose EXISTENCE is what "has it exited yet?" is asked
# through: no `kill -0`, no process-table matching, nothing that could touch a
# process this harness does not own.
BACKGROUND_RUN_PID=""
start_run_in_background() {
  local script="$1" fix="$2"
  RUN_TEE="$fix/run-output"
  : > "$RUN_TEE"
  rm -f "$fix/run-status"
  ( run_script "$script" "$fix"; printf '%s' "$RUN_RC" > "$fix/run-status" ) &
  BACKGROUND_RUN_PID=$!
}

# Sets RUN_OUT and RUN_RC from the files, so the assertions below read exactly
# as they do in every synchronous case.
finish_background_run() {
  local fix="$1"
  wait "$BACKGROUND_RUN_PID" 2>/dev/null
  BACKGROUND_RUN_PID=""
  RUN_OUT="$(cat "$fix/run-output" 2>/dev/null)"
  RUN_RC="$(cat "$fix/run-status" 2>/dev/null)"
  RUN_TEE=""
}

# `swift-safe` announcing that it is queued. Waiting for THIS rather than for a
# duration is what makes the two cases below independent of how slow the box is:
# the bound is measured from here.
QUEUED_ANNOUNCEMENT="waiting for the shared build slot"

# THE DEFAULT-OFF GUARANTEE, TESTED THROUGH THE ONLY THING THAT CAN BREAK IT.
# Every other off-path case here runs against an environment `run_script` has
# already scrubbed, so none of them can see the one input that makes the off
# path behave differently: an INHERITED `TBD_SWIFT_QUEUE_YIELD_SECONDS`. It is a
# knob `scripts/swift-safe` documents, it is honoured on any `test` regardless
# of `TBD_REMOTE_VERIFY`, and `env` ADDS assignments rather than clearing
# inherited ones — so omitting the assignment is not the same as clearing it.
# Left uncleared, a developer who exported that bound gets 76 out of a wrapper
# that ran no tests at all, and `scripts/git-hooks/pre-push` runs this script
# with no scrubbing and turns that into a blocked push.
#
# The run must REACH THE COMPILER, not merely exit non-76: the whole complaint
# is a run that tested nothing.
test_an_inherited_yield_bound_does_not_bound_a_valve_off_run() {
  local fix; fix="$(mkfix)"
  hold_the_shared_lock "$fix/home/tbd/runtime/swift-build.lock" \
    "$fix/lock-held" "$fix/lock-release"
  RUN_ENV=(TBD_SWIFT_QUEUE_YIELD_SECONDS="$INHERITED_YIELD_SECONDS")
  start_run_in_background "$SCRIPT" "$fix"
  RUN_ENV=()
  assert_eq "the run really was queued behind the holder" "waited" \
    "$(await_text "$fix/run-output" "$QUEUED_ANNOUNCEMENT")"
  sleep "$PAST_THE_BOUND_SECONDS"
  assert_eq "and it is still queued well past the inherited bound" "false" \
    "$([ -e "$fix/run-status" ] && echo true || echo false)"
  release_the_shared_lock "$fix/lock-release"
  finish_background_run "$fix"
  assert_ok "a valve-off run under contention is green" "$RUN_RC"
  assert_eq "and it reached the compiler" "1" "$(swift_invocations "$fix")"
  assert_missing "having never yielded its place" "$RUN_OUT" \
    "yielding the local build slot"
  assert_contains "with the inherited bound cleared" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=<unset>"
  rmfix "$fix"
}

# MUTATION. Put the bare `fenced_env=()` back — anchored at column 0, so this
# weakens the valve-off initialisation and not the identically spelled clearing
# inside `fall_back_to_the_local_queue` — and the caller's bound rides into a
# run that never asked to be verified anywhere: 76, no tests, blocked push.
# Nothing here is timed: the lock is held until the run gives up on its own.
test_the_valve_off_bound_clearing_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"
  mutant="$(mutant_of "$SCRIPT" \
    's/^fenced_env=\(TBD_SWIFT_QUEUE_YIELD_SECONDS=\)$/fenced_env=()/')"
  hold_the_shared_lock "$fix/home/tbd/runtime/swift-build.lock" \
    "$fix/lock-held" "$fix/lock-release"
  RUN_ENV=(TBD_SWIFT_QUEUE_YIELD_SECONDS="$INHERITED_YIELD_SECONDS")
  start_run_in_background "$mutant" "$fix"
  RUN_ENV=()
  assert_eq "the mutant queued behind the holder too" "waited" \
    "$(await_text "$fix/run-output" "$QUEUED_ANNOUNCEMENT")"
  assert_eq "and gave up on its own, without the lock ever being released" \
    "waited" "$(await_file "$fix/run-status")"
  release_the_shared_lock "$fix/lock-release"
  finish_background_run "$fix"
  assert_eq "without the clearing a valve-off run exits 76" "76" "$RUN_RC"
  assert_eq "having compiled and tested nothing" "0" "$(swift_invocations "$fix")"
  assert_contains "on a yield nobody asked for" "$RUN_OUT" \
    "yielding the local build slot"
  rmfix "$fix"
}

test_the_valve_forwards_its_default_bound_when_enabled() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(TBD_REMOTE_VERIFY=1)
  run_wrapper "$fix"
  RUN_ENV=()
  assert_ok "an enabled run is green" "$RUN_RC"
  assert_contains "the spec's threshold is forwarded" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=$DEFAULT_YIELD_SECONDS"
  rmfix "$fix"
}

test_the_valve_forwards_an_explicit_bound() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 TBD_REMOTE_VERIFY_YIELD_SECONDS=45.5)
  run_wrapper "$fix"
  RUN_ENV=()
  assert_ok "an explicitly bounded run is green" "$RUN_RC"
  assert_contains "the explicit bound is forwarded verbatim" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=45.5"
  rmfix "$fix"
}

# A bound the flag never uses must not fail a run that never consults it.
test_a_bad_bound_is_ignored_while_the_valve_is_off() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(TBD_REMOTE_VERIFY_YIELD_SECONDS=0)
  run_wrapper "$fix"
  RUN_ENV=()
  assert_ok "a bad bound with the valve off changes nothing" "$RUN_RC"
  assert_contains "and no bound is forwarded" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=<unset>"
  rmfix "$fix"
}

# THE MEASURED HAZARD. `swift-safe` rejects each of these with SystemExit, which
# exits 1 — indistinguishable from a red suite. The wrapper must refuse first,
# with its own code and its own name, and must not start a run at all.
test_a_bad_bound_fails_loudly_rather_than_as_a_red_suite() {
  local fix bound
  # The EMPTY value is deliberately not in this list; see
  # `test_an_empty_bound_means_unset_rather_than_a_refusal`.
  for bound in 0 0.0 .0 00 -5 nan inf later; do
    fix="$(mkfix)"
    RUN_ENV=(TBD_REMOTE_VERIFY=1 TBD_REMOTE_VERIFY_YIELD_SECONDS="$bound")
    run_wrapper "$fix"
    RUN_ENV=()
    assert_eq "a bound of [$bound] exits 64, not 1" "64" "$RUN_RC"
    assert_contains "and names the variable" "$RUN_OUT" "TBD_REMOTE_VERIFY_YIELD_SECONDS"
    assert_contains "and says what it must be" "$RUN_OUT" "must be a positive number"
    assert_eq "and no suite is started" "0" "$(swift_invocations "$fix")"
    rmfix "$fix"
  done
}

# EMPTY IS THE ABSENCE OF A VALUE, NOT A TYPO, and it is the one spelling that
# must NOT join the list above. `TBD_REMOTE_VERIFY_YIELD_SECONDS=` is how a shell
# clears an inherited value, how `env VAR=` arrives, and what an unquoted
# `"$maybe_unset"` expands to — and it is not how the valve gets turned off, which
# is `TBD_REMOTE_VERIFY` unset and never reaches the bound at all. So a refusal
# here could only be answering a caller who meant "use the default", and the price
# would be paid somewhere else entirely: `scripts/git-hooks/pre-push` runs this
# wrapper to decide whether a push may proceed, and an exit of 64 there BLOCKS THE
# PUSH.
test_an_empty_bound_means_unset_rather_than_a_refusal() {
  local fix; fix="$(mkfix)"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 TBD_REMOTE_VERIFY_YIELD_SECONDS=)
  run_wrapper "$fix"
  RUN_ENV=()
  assert_ok "an empty bound runs rather than exiting 64" "$RUN_RC"
  assert_missing "and nothing is said about the variable" "$RUN_OUT" \
    "TBD_REMOTE_VERIFY_YIELD_SECONDS must"
  assert_contains "the default is used" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=$DEFAULT_YIELD_SECONDS"
  rmfix "$fix"
}

# MUTATION, IN THE DIRECTION THIS DECISION WAS MADE AGAINST. Spell the expansion
# `-` instead of `:-` — substituting only for an UNSET variable — and the empty
# string reaches the validator, which refuses it with the code that blocks a push.
test_the_empty_bound_defaulting_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"
  mutant="$(mutant_of "$SCRIPT" \
    's/\$\{TBD_REMOTE_VERIFY_YIELD_SECONDS:-\$DEFAULT_REMOTE_VERIFY_YIELD_SECONDS\}/${TBD_REMOTE_VERIFY_YIELD_SECONDS-$DEFAULT_REMOTE_VERIFY_YIELD_SECONDS}/')"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 TBD_REMOTE_VERIFY_YIELD_SECONDS=)
  run_script "$mutant" "$fix"
  RUN_ENV=()
  assert_eq "with a bare dash an empty bound exits 64" "64" "$RUN_RC"
  assert_contains "and a pre-push would be blocked over it" "$RUN_OUT" \
    "TBD_REMOTE_VERIFY_YIELD_SECONDS must"
  assert_eq "with no suite started at all" "0" "$(swift_invocations "$fix")"
  rmfix "$fix"
}

# MUTATION. Without the check the same value reaches `swift-safe`, which exits
# 1 with no mention of the variable the caller actually set — a typo wearing a
# failing test suite's clothes.
test_the_bound_validation_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"
  mutant="$(mutant_of "$SCRIPT" 's/if ! valid_yield_bound "\$yield_seconds"; then/if false; then/')"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 TBD_REMOTE_VERIFY_YIELD_SECONDS=0)
  run_script "$mutant" "$fix"
  RUN_ENV=()
  assert_eq "without the check a zero bound exits 1, like a red suite" "1" "$RUN_RC"
  assert_missing "and nothing names the variable the caller set" "$RUN_OUT" \
    "TBD_REMOTE_VERIFY_YIELD_SECONDS must"
  rmfix "$fix"
}

# The helper on its own, sourced — the table the case above cannot show without
# running the whole wrapper nine times over.
test_valid_yield_bound_accepts_only_positive_numbers() {
  local value
  for value in 300 60 0.5 .5 1.25 007; do
    valid_yield_bound "$value"
    assert_ok "[$value] is a usable bound" "$?"
  done
  for value in "" 0 0.0 .0 00 000.000 -1 +1 1e3 nan inf later 1.2.3 . " " "1 2"; do
    valid_yield_bound "$value"
    assert_nonzero "[$value] is refused" "$?"
  done
}

test_a_yielded_queue_is_verified_remotely() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC=76 FAKE_REMOTE_VERIFY_RC=0
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix"
  RUN_ENV=()
  assert_ok "a passing remote run is a passing run" "$RUN_RC"
  assert_eq "the remote path was consulted once" "1" "$(remote_verify_dispatches "$fix")"
  assert_eq "and the local suite was not re-run" "1" "$(swift_invocations "$fix")"
  rmfix "$fix"
}

# 1 is a verdict, not a refusal: the failing tests are already printed by the
# remote path, so the run reports them rather than starting over locally.
test_a_failing_remote_run_is_the_runs_verdict() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC=76 FAKE_REMOTE_VERIFY_RC=1
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix"
  RUN_ENV=()
  assert_eq "a red remote run fails the run" "1" "$RUN_RC"
  assert_eq "and nothing is re-run locally" "1" "$(swift_invocations "$fix")"
  rmfix "$fix"
}

# 78 IS THE ONE THAT MUST NOT FAIL THE RUN. A precondition the remote path
# cannot meet — a dirty tree, no `gh` — returns this lane to the local queue.
test_a_refused_precondition_falls_back_to_a_local_run() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 0" FAKE_REMOTE_VERIFY_RC=78
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix"
  RUN_ENV=()
  assert_ok "a refusal falls back rather than failing" "$RUN_RC"
  assert_eq "the remote path was consulted once" "1" "$(remote_verify_dispatches "$fix")"
  assert_eq "and the suite ran locally afterwards" "2" "$(swift_invocations "$fix")"
  local dump; dump="$(dump_of "$fix")"
  assert_contains "the fallback carries no yield bound" "$dump" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=<unset>"
  # THE FENCE MUST NOT DRIFT BETWEEN THE TWO CALLS. That is why the invocation
  # is a function rather than two copies of the same `env` prefix.
  assert_contains "the fallback is still fenced (TBD_HOME)" "$dump" "TBD_HOME=/tmp/tbd-test-home."
  assert_contains "the fallback is still fenced (host claude)" "$dump" "/sanctioned/tbd/claude-host"
  assert_contains "the fallback is still fenced (codex)" "$dump" "/sanctioned/tbd/codex-host"
  assert_contains "the fallback is still fenced (tmux)" "$dump" "TMUX_TMPDIR=/tmp/tbd-test-home."
  assert_contains "and still pinned to the shared lock" "$dump" \
    "TBD_SWIFT_LOCK_PATH=$fix/home/tbd/runtime/swift-build.lock"
  rmfix "$fix"
}

# A BROKEN CHECKOUT IS A REFUSAL TOO. Without the executability check the shell
# answers 127, which would be adopted as the run's exit status — a missing file
# reported as a failing test suite.
test_a_missing_remote_path_falls_back_to_a_local_run() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  rm -f "$fix/repo/scripts/remote-verify.sh"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 0")
  run_with_valve "$fix"
  RUN_ENV=()
  assert_ok "a missing remote path falls back rather than failing" "$RUN_RC"
  assert_contains "and says why" "$RUN_OUT" "remote-verify.sh is missing or not executable"
  assert_eq "and the suite ran locally afterwards" "2" "$(swift_invocations "$fix")"
  rmfix "$fix"
}

# MUTATION. The two guards are LAYERED, and this is where that shows. Without
# the executability check the shell answers 127 — but 127 is outside the
# `{0, 1, 78}` contract, so the whitelist below catches it and the run still
# falls back rather than reporting a broken checkout as a failing suite. What
# the check buys on top is the DIAGNOSIS: it names the missing file instead of
# leaving the reader an exit status to interpret, and it does so without
# spending a dispatch attempt on a script that is not there.
test_the_missing_remote_path_check_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  rm -f "$fix/repo/scripts/remote-verify.sh"
  mutant="$(mutant_of "$SCRIPT" 's/if \[ ! -x scripts\/remote-verify\.sh \]; then/if false; then/')"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 0")
  run_with_valve "$fix" "$mutant"
  RUN_ENV=()
  assert_missing "without the check nothing names the missing file" "$RUN_OUT" \
    "remote-verify.sh is missing or not executable"
  assert_contains "the reader is left with a bare 127 instead" "$RUN_OUT" \
    "exited 127, which is"
  rmfix "$fix"
}

# MUTATION. Have the refusal branch adopt the status instead of falling back and
# a lane that could not go remote reports a failure instead of testing anything.
# Keyed to the branch's own comment so the mutation is unambiguous about WHICH of
# the three fallbacks it weakens — they all call the same function.
test_the_refusal_fallback_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  mutant="$(mutant_of "$SCRIPT" \
    '/A REFUSAL IS NOT A FAILURE/,/;;/ s/fall_back_to_the_local_queue/test_status=$remote_status/')"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 0" FAKE_REMOTE_VERIFY_RC=78
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$mutant"
  RUN_ENV=()
  assert_eq "without the fallback a refusal fails the run" "78" "$RUN_RC"
  assert_eq "and the suite never ran locally" "1" "$(swift_invocations "$fix")"
  rmfix "$fix"
}

# THE CONTRACT IS A WHITELIST, AND EVERYTHING OUTSIDE IT IS A NON-ANSWER. The
# set of statuses a script can produce is open-ended — 127 for an interpreter
# that is not there, 126 for a lost executable bit, 130 for a Ctrl-C, 2 for a
# syntax error — and not one of them says anything about the tests. Adopting one
# reports a suite that never ran as a suite that failed.
test_an_out_of_contract_status_is_a_refusal_not_a_verdict() {
  local fix status
  for status in 2 126 127 130; do
    fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
    RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 0" FAKE_REMOTE_VERIFY_RC="$status"
             FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
    run_with_valve "$fix"
    RUN_ENV=()
    assert_ok "an exit of $status falls back rather than failing the run" "$RUN_RC"
    assert_contains "and names the status it saw" "$RUN_OUT" "exited $status, which is"
    assert_contains "and says it is outside the contract" "$RUN_OUT" \
      "outside its {0, 1, 78} contract"
    assert_eq "the suite ran locally afterwards" "2" "$(swift_invocations "$fix")"
    rmfix "$fix"
  done
}

# MUTATION. The same weakening one branch over: have the catch-all adopt the
# status and a 127 from a mangled interpreter line becomes the test suite's exit
# code with nothing ever run.
test_the_contract_whitelist_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  mutant="$(mutant_of "$SCRIPT" \
    '/OUTSIDE THE CONTRACT ENTIRELY/,/;;/ s/fall_back_to_the_local_queue/test_status=$remote_status/')"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 0" FAKE_REMOTE_VERIFY_RC=127
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$mutant"
  RUN_ENV=()
  assert_eq "without the whitelist a 127 becomes the run's verdict" "127" "$RUN_RC"
  assert_eq "and the suite never ran locally" "1" "$(swift_invocations "$fix")"
  rmfix "$fix"
}

# THE INHERITED-BOUND TRAP, AND THE ONE CASE HERE THAT DELIBERATELY DOES NOT
# UNSET `TBD_SWIFT_QUEUE_YIELD_SECONDS`. `scripts/swift-safe` documents it as a
# supported knob, so a caller exporting it next to `TBD_REMOTE_VERIFY=1` is
# expected. `fenced_env=()` on the fallback path omits the assignment but does
# not unset the variable, and `env` passes the caller's value straight through —
# so the re-run would yield 76 a second time, and since the valve block has
# already been passed, the wrapper would exit 76 with nothing tested and nothing
# said. `run_script`'s `-u` list would have hidden this exactly as it hid it
# from review; the assignment below reaches the run because `env` applies
# assignments after its options.
test_an_inherited_yield_bound_does_not_survive_the_fallback() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 TBD_SWIFT_QUEUE_YIELD_SECONDS=10
           FAKE_SWIFT_RC="76 0" FAKE_REMOTE_VERIFY_RC=78
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix"
  RUN_ENV=()
  assert_ok "the fallback run is green" "$RUN_RC"
  assert_eq "and it really did re-run locally" "2" "$(swift_invocations "$fix")"
  # The dump describes the LAST invocation — the fallback. An inherited 10 here
  # is the yield that would strand the run at 76.
  assert_contains "the fallback carries no yield bound at all" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=<unset>"
  rmfix "$fix"
}

# MUTATION. Put the bare `fenced_env=()` back and the caller's 10 rides straight
# into the re-run. Anchored to the indented occurrence, so it weakens the
# clearing inside `fall_back_to_the_local_queue` and leaves the identically
# spelled valve-off initialisation at column 0 intact — the two are separate
# guards and a mutation that tripped both would prove neither.
test_the_fallback_bound_clearing_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  mutant="$(mutant_of "$SCRIPT" \
    's/^  fenced_env=\(TBD_SWIFT_QUEUE_YIELD_SECONDS=\)$/  fenced_env=()/')"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 TBD_SWIFT_QUEUE_YIELD_SECONDS=10
           FAKE_SWIFT_RC="76 0" FAKE_REMOTE_VERIFY_RC=78
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$mutant"
  RUN_ENV=()
  assert_contains "without the clearing the caller's bound survives the fallback" \
    "$(dump_of "$fix")" "TBD_SWIFT_QUEUE_YIELD_SECONDS=10"
  rmfix "$fix"
}

# ---------------------------------------------------------------------------
# 7b. A narrowed run routes, and its verdict is read by the asymmetry
#
# Nothing on the dispatch carries a filter, so a routed run is always the WHOLE
# suite — and the two outcomes do not transfer equally to a caller who asked for
# less:
#
#   GREEN transfers. Every test passed, so every subset of them passed. Adopted,
#      with one line so the whole-suite test count is not read as the subset's.
#   RED does not. The failures may lie entirely outside what the caller selected,
#      so the narrowed suite is re-run locally and the LOCAL verdict reported.
#
# WHY THE CASES BELOW ASSERT ROUTING RATHER THAN REFUSAL. Refusing a narrowed run
# outright needs no interpretation, but it turns the valve off for every real
# caller: `scripts/git-hooks/pre-push` narrows BOTH of its passes (`--skip
# '^TBDDaemonLiveTests\.'` and `--filter '^TBDDaemonLiveTests\.'`), the nightly
# stress harness forwards a filter, and four of five live queued test lanes were
# `--filter` runs.
# ---------------------------------------------------------------------------

test_narrows_the_suite_recognises_both_spellings() {
  local arg
  for arg in --filter --skip --specifier -s --disable-xctest --disable-swift-testing \
             --test-product --list-tests list; do
    narrows_the_suite "$arg"
    assert_ok "[$arg] narrows" "$?"
    narrows_the_suite "$arg=Foo"
    assert_ok "[$arg=Foo] narrows" "$?"
    narrows_the_suite --parallel -j 2 "$arg" Foo
    assert_ok "[$arg] narrows wherever it appears" "$?"
  done
  for arg in --parallel --no-parallel -j --enable-code-coverage --verbose \
             --enable-xctest --enable-swift-testing --num-workers --xunit-output; do
    narrows_the_suite "$arg"
    assert_nonzero "[$arg] does not narrow" "$?"
  done
  narrows_the_suite
  assert_nonzero "no arguments at all does not narrow" "$?"
  # A value that merely looks like one of the names is not one of them.
  narrows_the_suite --parallel '^--filterTests\.'
  assert_nonzero "a regex mentioning a flag name does not narrow" "$?"
}

# THE LIST IS CHECKED AGAINST THE TOOLCHAIN, NOT AGAINST MEMORY. Every name here
# is one this `swift-test` binary actually accepts — read out of its own strings,
# since invoking SwiftPM to ask would take the machine-global build slot. A name
# that does not exist costs nothing; a name that exists and is MISSING is the
# expensive direction, because the run it fails to recognise adopts a whole-suite
# failure as its own and reports tests the caller excluded.
#
# `--test-product` was the omission this case was written for: it restricts the
# run to one test product, which on a multi-product package is the largest
# reduction on offer, and SwiftPM names the flag itself in its "found multiple
# test products" diagnostic.
test_the_narrowing_list_names_only_real_swift_test_options() {
  local swift_test missing=""
  swift_test="$(xcrun -f swift-test 2>/dev/null || command -v swift-test || true)"
  if [ -z "$swift_test" ] || [ ! -e "$swift_test" ]; then
    echo "ok   - (skipped: no swift-test binary to read)"
    return 0
  fi
  # ArgumentParser derives a long name from a property name or a `customLong`, so
  # the string in the binary is sometimes the camelCase property (`testProduct`)
  # and sometimes the flag's own stem (`specifier`, `xctest`). Each entry is
  # looked for in whichever shape that toolchain stores it.
  #
  # STRINGS GOES TO A FILE FIRST, and that is not tidiness. This harness runs
  # under `pipefail`, and `strings … | grep -q` closes the pipe on the first match
  # — `strings` then dies of SIGPIPE and the PIPELINE reports 141 even though grep
  # matched, so every needle would look missing. That failure looked exactly like
  # a toolchain with none of these options.
  local dump; dump="$(mktmpd)/swift-test.strings"
  strings -a "$swift_test" > "$dump"
  local -a needles=(testProduct specifier --list-tests filter skip xctest swift-testing)
  local needle
  for needle in "${needles[@]}"; do
    grep -xF -- "$needle" "$dump" >/dev/null || missing="$missing $needle"
  done
  assert_eq "every narrowing name has a counterpart in the toolchain" "" "$missing"
  # And the list in the script really carries them, so the check above is not
  # asserting against a list that has drifted away from the one in use.
  local body; body="$(cat "$SCRIPT")"
  assert_contains "the script's list carries --test-product" "$body" "--test-product"
  assert_contains "and --list-tests" "$body" "--list-tests"
  assert_contains "and the deprecated --specifier with its short form" "$body" \
    "--specifier -s"
}

# END TO END, THROUGH THE VERDICT INTERPRETATION. `--test-product` has to reach
# the same reading `--filter` gets: a red whole-suite verdict is unattributable, so
# the narrowed suite is re-run locally and THAT verdict is the run's.
test_a_test_product_narrowed_run_reads_a_red_verdict_as_unattributable() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 3" FAKE_REMOTE_VERIFY_RC=1
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --test-product TBDPackageTests
  RUN_ENV=()
  assert_eq "the LOCAL verdict is reported, not the remote 1" "3" "$RUN_RC"
  assert_eq "the narrowed suite was re-run locally" "2" "$(swift_invocations "$fix")"
  assert_contains "and the reason names the mismatch" "$RUN_OUT" \
    "remote WHOLE-SUITE run failed"
  rmfix "$fix"
}

# MUTATION. Drop `--test-product` back out of the list — the state this case was
# written against — and the same run adopts a whole-suite failure as one test
# product's result, naming tests the caller never asked to run.
test_including_test_product_in_the_narrowing_list_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  mutant="$(mutant_of "$SCRIPT" 's/^  --test-product$//')"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 3" FAKE_REMOTE_VERIFY_RC=1
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$mutant" --test-product TBDPackageTests
  RUN_ENV=()
  assert_eq "without the entry the remote 1 is adopted" "1" "$RUN_RC"
  assert_eq "and the one product is never re-run" "1" "$(swift_invocations "$fix")"
  assert_missing "with nothing said about attribution" "$RUN_OUT" \
    "WHOLE-SUITE run failed"
  rmfix "$fix"
}

# NARROWED + GREEN — the sound direction, adopted. The whole suite passing
# implies the caller's subset passed, so there is nothing to re-run; only the
# test COUNT fails to transfer, which is what the note exists for.
test_a_narrowed_run_adopts_a_green_whole_suite_verdict() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC=76 FAKE_REMOTE_VERIFY_RC=0
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --filter '^FooTests\.'
  RUN_ENV=()
  assert_ok "a green whole-suite run passes the narrowed run" "$RUN_RC"
  assert_eq "it really was dispatched" "1" "$(remote_verify_dispatches "$fix")"
  assert_eq "and nothing was re-run locally" "1" "$(swift_invocations "$fix")"
  assert_contains "the bound is forwarded like any other run" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=$DEFAULT_YIELD_SECONDS"
  assert_contains "the filter still reaches swift test" "$(dump_of "$fix")" \
    "argv: test --filter"
  assert_contains "and the count is flagged as whole-suite" "$RUN_OUT" \
    "the remote run was the WHOLE suite"
  rmfix "$fix"
}

# NARROWED + RED — unattributable, so it is not adopted. The local re-run's
# verdict is the one reported, and this fixture makes the two differ: remote says
# 1, the local re-run says 3, and 3 is what comes out.
test_a_narrowed_run_reports_the_local_verdict_after_a_red_whole_suite_run() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 3" FAKE_REMOTE_VERIFY_RC=1
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --filter '^FooTests\.'
  RUN_ENV=()
  assert_eq "the LOCAL verdict is reported, not the remote 1" "3" "$RUN_RC"
  assert_eq "the narrowed suite was re-run locally" "2" "$(swift_invocations "$fix")"
  assert_contains "and the re-run is still narrowed" "$(dump_of "$fix")" \
    "argv: test --filter"
  assert_contains "the reason is stated" "$RUN_OUT" "cannot"
  assert_contains "and names what happened" "$RUN_OUT" "remote WHOLE-SUITE run failed"
  assert_contains "the re-run carries no yield bound" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=<unset>"
  rmfix "$fix"
}

# The same shape when the local re-run PASSES: a red whole-suite verdict whose
# failures were all outside the caller's subset must not fail the caller's run.
test_a_narrowed_run_goes_green_when_the_local_rerun_passes() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 0" FAKE_REMOTE_VERIFY_RC=1
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --skip '^TBDDaemonLiveTests\.'
  RUN_ENV=()
  assert_ok "failures outside the subset do not fail the narrowed run" "$RUN_RC"
  assert_eq "the narrowed suite was re-run locally" "2" "$(swift_invocations "$fix")"
  rmfix "$fix"
}

# UNNARROWED + RED — still the verdict, still adopted, still no re-run. This is
# the branch the narrowed cases above must be distinguished FROM.
test_an_unnarrowed_run_still_adopts_a_red_verdict() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 0" FAKE_REMOTE_VERIFY_RC=1
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --parallel -j 2
  RUN_ENV=()
  assert_eq "a red remote run fails an unnarrowed run" "1" "$RUN_RC"
  assert_eq "and nothing is re-run locally" "1" "$(swift_invocations "$fix")"
  assert_missing "nothing is said about attribution" "$RUN_OUT" "WHOLE-SUITE run failed"
  assert_missing "nor about a whole-suite count" "$RUN_OUT" "was the WHOLE suite"
  rmfix "$fix"
}

# MUTATION, AND THE ONE THAT MATTERS MOST HERE. With `narrows_the_suite` never
# recognising anything, a `--filter`ed lane adopts a whole-suite failure as its
# own verdict — naming tests it deliberately excluded, which is the exact wrong
# answer this interpretation exists to prevent.
test_the_narrowed_verdict_discrimination_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  mutant="$(mutant_of "$SCRIPT" 's/if narrows_the_suite .*; then/if false; then/')"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 3" FAKE_REMOTE_VERIFY_RC=1
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$mutant" --filter '^FooTests\.'
  RUN_ENV=()
  assert_eq "without the discrimination the remote 1 is adopted" "1" "$RUN_RC"
  assert_eq "and the narrowed suite is never re-run" "1" "$(swift_invocations "$fix")"
  assert_missing "with nothing said about attribution" "$RUN_OUT" "WHOLE-SUITE run failed"
  rmfix "$fix"
}

# The other half of the same mutation: a narrowed GREEN result must be labelled.
# Without it the caller reads a whole-suite test count as their subset's — which
# is precisely how a `pre-push` floor stops catching a filter that matched
# nothing.
test_the_whole_suite_label_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  mutant="$(mutant_of "$SCRIPT" 's/if narrows_the_suite .*; then/if false; then/')"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC=76 FAKE_REMOTE_VERIFY_RC=0
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$mutant" --filter '^FooTests\.'
  RUN_ENV=()
  assert_ok "the mutant still passes (the label is not a correctness gate)" "$RUN_RC"
  assert_missing "but the whole-suite count goes unlabelled" "$RUN_OUT" \
    "the remote run was the WHOLE suite"
  rmfix "$fix"
}

# A NARROWED RUN'S 78 IS STILL JUST A REFUSAL. The interpretation only touches 0
# and 1; a precondition that refused falls back exactly as it does unnarrowed,
# and must not pick up the attribution message.
test_a_narrowed_run_falls_back_on_a_refusal_like_any_other() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 0" FAKE_REMOTE_VERIFY_RC=78
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --filter '^FooTests\.'
  RUN_ENV=()
  assert_ok "a refusal still falls back" "$RUN_RC"
  assert_eq "with one local re-run" "2" "$(swift_invocations "$fix")"
  assert_missing "and no attribution message" "$RUN_OUT" "WHOLE-SUITE run failed"
  rmfix "$fix"
}

# ---------------------------------------------------------------------------
# 7d. A listing invocation never arms the valve at all
#
# `--list-tests`, and the bare `list` subcommand that spells the same thing, ask
# for OUTPUT rather than a verdict: they run nothing and print method names, and
# those names are the whole answer. The remote path produces a verdict, and a
# verdict answers that question in NEITHER direction — green would exit 0 having
# printed no name the caller asked for, red would report failures for a run that
# was never going to run a test.
#
# SO THE GATE IS AT THE ARMING, NOT AT THE VERDICT. Routing a listing run and
# salvaging it on the way back would spend a whole CI dispatch on a question CI
# cannot answer and then run locally anyway. Not arming has to leave the run in
# the PRE-VALVE state exactly — no routing AND the yield bound cleared — which is
# what the inherited-bound case below is for: `env` passes an inherited
# `TBD_SWIFT_QUEUE_YIELD_SECONDS` straight through, so merely declining to set it
# would strand a listing run at 76 with nothing printed and nothing routed.
#
# The bound is still VALIDATED for a listing run, because a malformed one is a
# property of the caller's environment rather than of these arguments.
# ---------------------------------------------------------------------------

# The line the wrapper prints when it declines to arm. On stderr, because stdout
# is where the listing itself goes.
LISTING_NOTICE="asks for a test LISTING"

test_a_list_tests_run_never_arms_the_valve() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_REMOTE_VERIFY_RC=0
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --list-tests
  RUN_ENV=()
  assert_ok "a listing run is green" "$RUN_RC"
  assert_eq "and nothing is dispatched, whatever the remote would have said" \
    "0" "$(remote_verify_dispatches "$fix")"
  assert_eq "the listing really ran locally" "1" "$(swift_invocations "$fix")"
  assert_contains "with the request intact" "$(dump_of "$fix")" "argv: test --list-tests"
  assert_contains "and no yield bound to give the queue up with" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=<unset>"
  assert_contains "the reason is stated" "$RUN_OUT" "$LISTING_NOTICE"
  rmfix "$fix"
}

# THE SUBCOMMAND SPELLING IS THE SAME REQUEST, and it is a bare word rather than
# a flag, so nothing about the matching can be flag-shaped.
test_the_bare_list_subcommand_never_arms_the_valve() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_REMOTE_VERIFY_RC=0
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" list
  RUN_ENV=()
  assert_ok "a bare-subcommand listing run is green" "$RUN_RC"
  assert_eq "and nothing is dispatched" "0" "$(remote_verify_dispatches "$fix")"
  assert_eq "the listing really ran locally" "1" "$(swift_invocations "$fix")"
  assert_contains "with the subcommand intact" "$(dump_of "$fix")" "argv: test list"
  assert_contains "and no yield bound" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=<unset>"
  assert_contains "the reason is stated" "$RUN_OUT" "$LISTING_NOTICE"
  rmfix "$fix"
}

# CLEARED, NOT MERELY UNSET — the distinction the whole gate turns on. `env` ADDS
# assignments rather than clearing inherited ones, so a gate that only declined
# to SET the bound would let a caller's exported `TBD_SWIFT_QUEUE_YIELD_SECONDS`
# ride into a listing run: `swift-safe` gates the yield on the subcommand alone,
# would yield 76 with no routing armed, and the wrapper would exit 76 having
# printed no test names at all. The assignment below reaches the run because
# `env` applies assignments after its options, past `run_script`'s `-u` list.
test_an_inherited_yield_bound_does_not_bound_a_listing_run() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 TBD_SWIFT_QUEUE_YIELD_SECONDS=10
           FAKE_REMOTE_VERIFY_RC=0 FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --list-tests
  RUN_ENV=()
  assert_ok "the listing run is green" "$RUN_RC"
  assert_contains "the inherited bound is cleared, not passed through" \
    "$(dump_of "$fix")" "TBD_SWIFT_QUEUE_YIELD_SECONDS=<unset>"
  assert_eq "and nothing is dispatched" "0" "$(remote_verify_dispatches "$fix")"
  assert_eq "the listing ran" "1" "$(swift_invocations "$fix")"
  rmfix "$fix"
}

# A MALFORMED BOUND IS STILL REFUSED, LISTING OR NOT. It is a misconfiguration in
# the environment rather than a property of these arguments — it will strand the
# next run just as badly — and `swift-safe` would answer it with a bare 1, which
# reads as a failing suite. The gate skips the ARMING, never the validation.
test_a_bad_bound_still_fails_a_listing_run_loudly() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 TBD_REMOTE_VERIFY_YIELD_SECONDS=0
           FAKE_REMOTE_VERIFY_RC=0 FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --list-tests
  RUN_ENV=()
  assert_eq "a listing run with a bad bound exits 64, not 1" "64" "$RUN_RC"
  assert_contains "and names the variable" "$RUN_OUT" "TBD_REMOTE_VERIFY_YIELD_SECONDS"
  assert_contains "and says what it must be" "$RUN_OUT" "must be a positive number"
  assert_eq "with no listing started" "0" "$(swift_invocations "$fix")"
  assert_eq "and nothing dispatched" "0" "$(remote_verify_dispatches "$fix")"
  rmfix "$fix"
}

# The classifier on its own, sourced. It matches exactly as `narrows_the_suite`
# does — both spellings, wherever the argument appears — and, crucially, it must
# not fire on a run that merely selects a subset: those still route.
test_asks_for_a_listing_recognises_both_spellings() {
  local arg
  for arg in --list-tests list; do
    asks_for_a_listing "$arg"
    assert_ok "[$arg] asks for a listing" "$?"
    asks_for_a_listing "$arg=Foo"
    assert_ok "[$arg=Foo] asks for a listing" "$?"
    asks_for_a_listing --parallel -j 2 "$arg"
    assert_ok "[$arg] is recognised wherever it appears" "$?"
  done
  for arg in --filter --skip --specifier -s --test-product --disable-xctest \
             --disable-swift-testing --parallel --no-parallel -j --verbose; do
    asks_for_a_listing "$arg"
    assert_nonzero "[$arg] does not ask for a listing" "$?"
  done
  asks_for_a_listing
  assert_nonzero "no arguments at all does not ask for a listing" "$?"
  # A regex that merely mentions the flag's name is a VALUE, not the flag.
  asks_for_a_listing --filter '^--list-testsTests\.'
  assert_nonzero "a regex mentioning the flag name does not ask for a listing" "$?"
  # And every listing name is on the narrowing list too, as defence in depth: if
  # this gate were ever bypassed, a red whole-suite verdict still must not be
  # adopted as a listing run's result.
  for arg in --list-tests list; do
    narrows_the_suite "$arg"
    assert_ok "[$arg] is on the narrowing list as well" "$?"
  done
}

# MUTATION, AND THE ONE THIS SECTION EXISTS FOR. Disable the gate and the bug
# comes straight back: a `--list-tests` run bounds its queueing, yields 76,
# dispatches a whole-suite CI run, and adopts its GREEN verdict — exiting 0
# having never listed a single test name. The caller asked for output and got a
# verdict instead.
test_the_listing_gate_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  mutant="$(mutant_of "$SCRIPT" 's/if asks_for_a_listing .*; then/if false; then/')"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC=76 FAKE_REMOTE_VERIFY_RC=0
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$mutant" --list-tests
  RUN_ENV=()
  assert_eq "without the gate a listing run dispatches" "1" \
    "$(remote_verify_dispatches "$fix")"
  assert_ok "and adopts the green whole-suite verdict" "$RUN_RC"
  assert_eq "having yielded before listing anything" "1" "$(swift_invocations "$fix")"
  assert_contains "because the bound was armed after all" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=$DEFAULT_YIELD_SECONDS"
  assert_missing "and nothing was said about listings" "$RUN_OUT" "$LISTING_NOTICE"
  rmfix "$fix"
}

# THE OTHER DIRECTION: the gate must not be over-broad. A run that merely selects
# a subset still routes, still forwards the bound, and still adopts a green
# whole-suite verdict — see section 7b, whose reading depends on it.
test_the_listing_gate_does_not_catch_a_filtered_run() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC=76 FAKE_REMOTE_VERIFY_RC=0
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --filter '^FooTests\.'
  RUN_ENV=()
  assert_ok "a filtered run still adopts a green remote verdict" "$RUN_RC"
  assert_eq "and it really was dispatched" "1" "$(remote_verify_dispatches "$fix")"
  assert_contains "with the bound armed" "$(dump_of "$fix")" \
    "TBD_SWIFT_QUEUE_YIELD_SECONDS=$DEFAULT_YIELD_SECONDS"
  assert_missing "and no listing notice" "$RUN_OUT" "$LISTING_NOTICE"
  rmfix "$fix"
}

# ---------------------------------------------------------------------------
# 7c. The count in the log has to describe the run being reported
#
# Six consumers decide whether a run is trustworthy by grepping its log for
# `Test run with N tests` and taking the FIRST match — `scripts/git-hooks/
# pre-push` (which pipes both streams into its log), `scripts/nightly-flake-
# stress.sh`, and three floors in `.github/workflows/test.yml`.
#
# On the narrowed-red path two runs speak into one log, and only the second's
# verdict is reported: the remote whole-suite report prints first, then the local
# re-run. A remote count left in there is read as the reported run's population.
# THE CONCRETE FAILURE that closes is pre-push's tier-3 pass — `--filter
# '^TBDDaemonLiveTests\.'`, floor 35, a floor that exists precisely to catch a
# filter that matched nothing. Rename the type, and the local re-run selects
# zero tests, exits 0, and says `Test run with 0 tests`; with a whole-suite
# count ahead of it in the log the floor sees four thousand, is satisfied, and
# the push is allowed.
#
# The wrapper therefore declares its narrowing with `--narrowed`, and the driver
# omits the count from a FAILING report only. Green keeps its count: there the
# remote verdict is the one adopted, and a floor is a minimum measured against a
# superset.
# ---------------------------------------------------------------------------

# The whole-suite population the stubbed remote path claims — the real number
# from a recent full run, so the arithmetic below is the arithmetic in the wild.
REMOTE_WHOLE_SUITE_COUNT=4593
# What a vacuous filter's local re-run reports: it selected nothing and exited 0.
VACUOUS_FILTER_COUNT=0

# The tier-3 pass's floor, read out of the hook so this section cannot drift
# from the number actually enforced.
pre_push_tier3_floor() {
  sed -n 's/^run_pass "quiet pass[^"]*" \([0-9][0-9]*\).*/\1/p' "$HERE/git-hooks/pre-push"
}

# "caught" / "undetected" — what the floor makes of the count a consumer read
# out of a log, in `pre-push`'s own condition. A verdict rather than a number, so
# the assertion reads as the consequence rather than as arithmetic.
floor_verdict() {
  local count="$1" floor="$2"
  if [ -z "$count" ] || [ "$count" -lt "$floor" ]; then echo "caught"; else echo "undetected"; fi
}

test_the_tier3_floor_is_readable_from_the_hook() {
  local floor; floor="$(pre_push_tier3_floor)"
  assert_eq "the floor is digits only" "" "${floor//[0-9]/}"
  assert_eq "a vacuous filter's count is below it" "caught" \
    "$(floor_verdict "$VACUOUS_FILTER_COUNT" "$floor")"
  assert_eq "and a whole-suite count is not" "undetected" \
    "$(floor_verdict "$REMOTE_WHOLE_SUITE_COUNT" "$floor")"
}

# THE CASE THE FINDING IS ABOUT. A narrowed lane goes remote, the whole suite
# comes back red on something outside the subset, the narrowed suite is re-run
# locally and selects NOTHING — and the count a floor reads must be that re-run's
# zero, not the remote suite's four thousand.
test_a_narrowed_red_run_leaves_only_the_local_count_in_the_log() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 0"
           FAKE_SWIFT_TEST_COUNT="$VACUOUS_FILTER_COUNT"
           FAKE_REMOTE_VERIFY_RC=1
           FAKE_REMOTE_VERIFY_COUNT="$REMOTE_WHOLE_SUITE_COUNT"
           FAKE_REMOTE_VERIFY_ARGV="$fix/remote-verify-argv"
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --no-parallel --filter '^TBDDaemonLiveTests\.'
  RUN_ENV=()
  assert_ok "the local re-run's verdict is the run's" "$RUN_RC"
  assert_eq "and it really did re-run locally" "2" "$(swift_invocations "$fix")"
  assert_contains "the narrowing is declared to the remote path" \
    "$(remote_verify_argv "$fix")" "--narrowed"
  assert_eq "the count a floor reads is the local re-run's" "$VACUOUS_FILTER_COUNT" \
    "$(first_reported_test_count "$RUN_OUT")"
  assert_missing "the remote suite's count is nowhere in the log" "$RUN_OUT" \
    "$REMOTE_WHOLE_SUITE_COUNT tests"
  assert_eq "so the vacuous filter is caught" "caught" \
    "$(floor_verdict "$(first_reported_test_count "$RUN_OUT")" "$(pre_push_tier3_floor)")"
  rmfix "$fix"
}

# MUTATION. Stop declaring the narrowing and the remote report keeps its count.
# It is printed BEFORE the local re-run's, so `head -1` finds four thousand
# tests, a floor of 35 is satisfied by a run that executed nothing, and the push
# the floor exists to stop goes through.
test_declaring_the_narrowing_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  mutant="$(mutant_of "$SCRIPT" 's/remote_verify_args=\(--narrowed\)/remote_verify_args=()/')"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC="76 0"
           FAKE_SWIFT_TEST_COUNT="$VACUOUS_FILTER_COUNT"
           FAKE_REMOTE_VERIFY_RC=1
           FAKE_REMOTE_VERIFY_COUNT="$REMOTE_WHOLE_SUITE_COUNT"
           FAKE_REMOTE_VERIFY_ARGV="$fix/remote-verify-argv"
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$mutant" --no-parallel --filter '^TBDDaemonLiveTests\.'
  RUN_ENV=()
  assert_missing "nothing declares the narrowing" "$(remote_verify_argv "$fix")" "--narrowed"
  assert_eq "so the remote whole-suite count is the one a floor reads" \
    "$REMOTE_WHOLE_SUITE_COUNT" "$(first_reported_test_count "$RUN_OUT")"
  assert_eq "and the vacuous filter goes undetected" "undetected" \
    "$(floor_verdict "$(first_reported_test_count "$RUN_OUT")" "$(pre_push_tier3_floor)")"
  rmfix "$fix"
}

# THE OTHER TWO STATES, so "suppress the count whenever the valve fires" cannot
# pass as this fix. A narrowed GREEN verdict is the one being reported, so its
# count belongs in the log — a floor is a minimum and the whole suite is a
# superset of the subset asked for.
test_a_narrowed_green_run_keeps_the_remote_count() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC=76 FAKE_REMOTE_VERIFY_RC=0
           FAKE_REMOTE_VERIFY_COUNT="$REMOTE_WHOLE_SUITE_COUNT"
           FAKE_REMOTE_VERIFY_ARGV="$fix/remote-verify-argv"
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --filter '^FooTests\.'
  RUN_ENV=()
  assert_ok "a green whole-suite verdict is adopted" "$RUN_RC"
  assert_contains "the narrowing is still declared" "$(remote_verify_argv "$fix")" "--narrowed"
  assert_eq "and the adopted run's count is in the log" "$REMOTE_WHOLE_SUITE_COUNT" \
    "$(first_reported_test_count "$RUN_OUT")"
  rmfix "$fix"
}

# AN UNNARROWED CALLER DECLARES NOTHING, and its red verdict — which IS the
# reported one — keeps the population it executed.
test_an_unnarrowed_run_declares_nothing_and_keeps_its_count() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC=76 FAKE_REMOTE_VERIFY_RC=1
           FAKE_REMOTE_VERIFY_COUNT="$REMOTE_WHOLE_SUITE_COUNT"
           FAKE_REMOTE_VERIFY_ARGV="$fix/remote-verify-argv"
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$SCRIPT" --parallel -j 2
  RUN_ENV=()
  assert_eq "the remote verdict is the run's" "1" "$RUN_RC"
  assert_eq "nothing is declared" "" "$(remote_verify_argv "$fix")"
  assert_eq "and the reported run's count is in the log" "$REMOTE_WHOLE_SUITE_COUNT" \
    "$(first_reported_test_count "$RUN_OUT")"
  rmfix "$fix"
}

# THE FLAG IS A CONTRACT BETWEEN TWO FILES, so it is pinned against the real one
# rather than only against the stub. `scripts/remote-verify.sh` refuses an
# argument it does not recognise — 78, which this wrapper reads as a refusal and
# answers with a local run — so a rename on either side would leave every
# narrowed lane paying the remote round trip and then running locally anyway,
# quietly, because a refusal is not a failure.
test_the_narrowed_flag_is_one_the_remote_path_accepts() {
  local remote; remote="$(cat "$HERE/remote-verify.sh" 2>/dev/null)"
  assert_contains "the remote path parses the flag this wrapper sends" "$remote" "--narrowed)"
  assert_contains "and this wrapper sends that one" "$(cat "$SCRIPT")" \
    "remote_verify_args=(--narrowed)"
}

# THE FLOORS ARE MINIMUMS, WHICH IS WHY ADOPTING A WHOLE-SUITE GREEN IS SAFE FOR
# `pre-push`. Both of its passes narrow, and the whole suite is a superset of
# each, so a whole-suite count cannot fall below a count the narrowed pass would
# have produced. Pinned here because the reasoning is what licenses the adoption:
# were the check a ceiling, or an equality, a whole-suite count would trip it.
test_pre_push_floors_are_minimums_a_superset_cannot_trip() {
  local hook="$HERE/git-hooks/pre-push"
  local body; body="$(cat "$hook" 2>/dev/null)"
  assert_contains "the count check is a less-than against the floor" "$body" \
    '[ "$count" -lt "$floor" ]'
  assert_missing "and never a greater-than" "$body" '"$count" -gt'
  assert_missing "nor an equality" "$body" '"$count" -eq "$floor"'
  # Both passes narrow, so both are subsets of the whole suite.
  assert_contains "the fast pass narrows with --skip" "$body" "--skip '^TBDDaemonLiveTests"
  assert_contains "the tier-3 pass narrows with --filter" "$body" "--filter '^TBDDaemonLiveTests"
  narrows_the_suite --no-fingerprint --parallel -j 2 --skip '^TBDDaemonLiveTests\.'
  assert_ok "the fast pass is recognised as narrowed" "$?"
  narrows_the_suite --no-fingerprint --no-parallel --filter '^TBDDaemonLiveTests\.'
  assert_ok "the tier-3 pass is recognised as narrowed" "$?"
}

# MUTATION. Stop recognising 76 and the yield is reported as the run's exit
# status — a lane that compiled nothing looks like a suite that failed.
test_the_yield_routing_is_load_bearing() {
  local fix mutant; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  mutant="$(mutant_of "$SCRIPT" 's/-eq "\$YIELDED_THE_QUEUE"/-eq 999/')"
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC=76 FAKE_REMOTE_VERIFY_RC=0
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix" "$mutant"
  RUN_ENV=()
  assert_eq "without the routing a yield leaks out as the exit status" "76" "$RUN_RC"
  assert_eq "and nothing is dispatched" "0" "$(remote_verify_dispatches "$fix")"
  rmfix "$fix"
}

# 75 IS NOT 76. A timed-out or abandoned wait means nobody is waiting for this
# verdict, or the slot simply never came free — neither is a request to verify
# elsewhere, and dispatching one would spend a remote slot on nothing.
test_a_timed_out_wait_is_not_routed_remotely() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(TBD_REMOTE_VERIFY=1 FAKE_SWIFT_RC=75 FAKE_REMOTE_VERIFY_RC=0
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix"
  RUN_ENV=()
  assert_eq "75 is propagated untouched" "75" "$RUN_RC"
  assert_eq "and nothing is dispatched" "0" "$(remote_verify_dispatches "$fix")"
  rmfix "$fix"
}

# WITH THE FLAG OFF, A 76 CAN ONLY COME FROM THE SUITE ITSELF, and it is still
# just an exit status. The yield can no longer produce one: the off path clears
# `TBD_SWIFT_QUEUE_YIELD_SECONDS` rather than merely declining to set it, so
# `swift-safe` never yields there however the caller's environment was primed
# (see `test_an_inherited_yield_bound_does_not_bound_a_valve_off_run`). What is
# left is a test process that exits 76 for reasons of its own — which the stub
# is, standing in for `swift` — and the routing must not fire on it. Hence the
# invocation count: the 76 asserted here is a suite's verdict, from a run that
# reached the compiler, not a queue given up before one.
test_a_76_with_the_valve_off_is_propagated_untouched() {
  local fix; fix="$(mkfix)"; mk_repo_fixture "$fix" >/dev/null
  RUN_ENV=(FAKE_SWIFT_RC=76 FAKE_REMOTE_VERIFY_RC=0
           FAKE_REMOTE_VERIFY_LOG="$fix/remote-verify-log")
  run_with_valve "$fix"
  RUN_ENV=()
  assert_eq "76 is just an exit status when the valve is off" "76" "$RUN_RC"
  assert_eq "and it came from a run that reached the compiler" "1" "$(swift_invocations "$fix")"
  assert_eq "and nothing is dispatched" "0" "$(remote_verify_dispatches "$fix")"
  rmfix "$fix"
}

RUN_ENV=()
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
if [ "$FAIL" -ne 0 ]; then echo "SOME TESTS FAILED"; exit 1; fi
echo "ALL TEST-FENCE TESTS PASSED"
