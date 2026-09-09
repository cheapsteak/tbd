#!/usr/bin/env bash
#
# Run one test pass under a stall watchdog, and turn its outcome into a verdict.
#
#   scripts/ci/watched-test-pass.sh --name <name> --budget-seconds <N> \
#     --floor <N> --floor-message '<text>' [--out-dir <dir>] \
#     -- <arguments forwarded to scripts/test.sh>
#
# `--name` names every file the pass writes, under `--out-dir` (default /tmp):
# `<name>.log`, `<name>.rc`, `<name>-stall-ps.txt` and, per sampled process,
# `<name>-stall-sample-<pid>.txt`. It also names the pass in every `::error::`
# line and in the closing "executed N tests" line, so a reader of the job log
# knows which pass spoke without matching step boundaries.
#
# Every test step in `.github/workflows/test.yml` goes through here. The design
# is `docs/specs/2026-09-04-quiet-pass-stall-watchdog-design.md`; the rationale
# below is the part a reader of THIS file needs, and the spec carries the
# evidence and the rejected alternatives.
#
# ---------------------------------------------------------------------------
# WHAT IT IS FOR
#
# GitHub's step timeout leaves no evidence. A stall is a thread blocked
# somewhere no Swift Testing time limit can reach — a wedged cooperative pool,
# or a blocking wait off it — so the step timeout is the only bound, and being
# killed by it records nothing about which test or which frame. The watchdog
# bounds the run itself: on expiry it captures every thread's stack of the
# processes executing the tests, plus a picture of the machine around them,
# then fails the step while the platform timeout still has margin left.
#
# ---------------------------------------------------------------------------
# WHY A PTY
#
# On the serial (`--no-parallel`) path SwiftPM relays the test binary's output
# through `print($0, terminator: "")` on its own stdout
# (`SwiftTestCommand.runTestProducts`). `scripts/test.sh` runs
# `scripts/swift-safe` with no pipe of its own and `swift-safe` `os.execv`s the
# toolchain driver, so whatever this script hands the wrapper becomes SwiftPM's
# stdout. Piping into `tee` makes that stdout a pipe, and C stdio then fully
# buffers it in 16 KB blocks (a pipe's `st_blksize` on macOS). The quiet pass
# emits roughly 16 KB per minute, so its log lagged the run by about a minute
# and was cut at an arbitrary byte boundary: runs 33797806278 (stalled) and
# 33787142345 (green) both stopped at exactly byte 16384, mid-way through the
# same `keepsTheReaderForAJobThatIsStillRunning()` line. The last line a wedged
# step showed was the buffer boundary, not the hung test. The fast passes only
# look real-time because they emit 16 KB a second.
#
# `TERM=dumb script -q /dev/null … < /dev/null` makes SwiftPM's stdout a
# terminal, so C stdio line-buffers it and every line lands as it is produced.
# Each part earns its place: `script` propagates the child's exit status, so the
# verdict still reaches the caller; `< /dev/null` guarantees nothing ever waits
# on the pty for input; `TERM=dumb` keeps SwiftPM's build progress line-oriented
# instead of cursor-rewriting animations. The pty translates `\n` to `\r\n`,
# which is harmless both to the runner log and to the `grep -oE 'Test run with
# [0-9]+ tests?'` floor check below.
#
# ---------------------------------------------------------------------------
# WHY LINEAGE, NEVER NAMES
#
# On expiry the whole machine's process listing is written first and
# unconditionally. The runner is single-tenant, so that listing is both the
# record of the fixture's holder, tmux and job processes and the way we learn
# what anything is really called.
#
# The processes to sample are then found structurally, by descending the
# pipeline subshell's own tree with `pgrep -P`, and never by name: a CI probe of
# this watchdog matched `pgrep -x TBDPackageTests` against a live pass and found
# nothing, because the swift-testing binary does not run under its bundle name.
# A name match fails silently — it samples nothing and reports success at having
# collected nothing — whereas a tree walk finds whatever the pipeline actually
# spawned.
#
# WHY THE ARGV MATCH. The test binary is picked out of those descendants by
# matching `swiftpm-testing`, `xctest` or `TBDPackageTests` anywhere in the full
# argv from `ps -o command=`, not against a name: SwiftPM's
# `TestRunner.args(forTestAt:)` runs a swift-testing bundle as
# `<toolchain>/swiftpm-testing-helper --test-bundle-path <bundle> …
# --testing-library swift-testing` and an XCTest bundle as `<toolchain>/xctest
# <bundle>`, so the process executing the tests is the helper and never carries
# the bundle's own name — and the kernel truncates `p_comm` to 15 characters,
# which would render the helper as `swiftpm-testing` anyway. Matching unanchored
# against argv — read with `-ww` so ps never clips the long toolchain path —
# sidesteps both the truncation and the path prefix.
#
# WHY A FALLBACK. When no descendant matches, every descendant that is not known
# plumbing (`script`, the shells, `tee`, `sleep`, python, `swift-safe`) is worth
# a stack, and the list is short enough that sampling all of them costs nothing.
# SwiftPM's own driver is included deliberately: when nothing looks like a test
# runner, the driver's stack is evidence about what it was waiting on, which is
# exactly the question such a stall poses.
#
# WHY A CAP OF FOUR. Both selection paths take at most `sample_target_cap`
# processes, in walk order (parents before children, so SwiftPM's driver comes
# ahead of the compiler processes it spawns — in a stall during compilation the
# driver's own stack is the more informative one). A match count is not a
# process count: while the package is compiling, the bundle path
# `.build/<triple>/debug/TBDPackageTests.build/…` appears in the argv of every
# concurrent compiler process, so the argv match can select a dozen at once, and
# at ~5 s of serial sampling each that would eat the margin and leave the step
# to be killed by `timeout-minutes` after all. Whatever a cap drops is recorded
# in the ps file, and the whole-machine listing still names every matching
# process, so nothing disappears from the artifact — only from the sampling.
#
# Measured on a probe of the fallback path with the argv match disabled (run
# 33902144920): three of the four slots used — SwiftPM's `swift-test` driver at
# 87 KB, `swiftpm-testing-helper` at 796 KB symbolicated, and a fixture
# `TBDHolder` that exited mid-sample and was reported as failed — and the whole
# expiry path, from the whole-machine ps through the tree walk, the three serial
# samples and the SIGTERM sweep to the step exiting, took 42 s.
#
# WHY FIVE SECONDS OF `sample`. `/usr/bin/sample` — part of macOS, present on
# the runner image — captures every thread's stack of each target. Five seconds
# at sample's 1 ms interval is what it takes to show a blocked thread's stack
# unambiguously: a parked thread looks identical in every sample so a longer
# capture buys nothing, while a shorter one risks reading a scheduler blip as
# the stall — and symbolicating the ~200 MB debug helper still finishes well
# inside the margin the budget leaves.
#
# ---------------------------------------------------------------------------
# WHY THE KILL ORDER IS BUILT AND NOT REVERSED, AND WHY `tee` DIES LAST
#
# Each sampled target is SIGKILLed the moment its stacks are captured: it is
# wedged, and it has already given up everything it has to give. They are then
# filtered out of every order built from here on — signalling a dead pid is
# inert at best and reaches whatever reused the number at worst.
#
# The remaining processes get a graceful pass, because `scripts/test.sh` has an
# EXIT trap that sweeps tmux servers and checks its filesystem fence, and that
# cleanup is worth running. `tee` is a direct child of the subshell and owns the
# far end of the log pipe, so anything still writing when `tee` dies writes to a
# closed pipe — and the EXIT trap's cleanup output is exactly what the log
# wants. The walk is preorder (`script`, then all of script's subtree, then the
# sibling `tee`), so a plain reversal would signal `tee` FIRST, precisely
# backwards. The order is therefore built explicitly: everything below the
# direct children first (that subset reversed, so deepest-first), then the
# direct children other than `tee`, then `tee`.
#
# Both sweeps rebuild the order from a fresh walk rather than reusing an earlier
# snapshot: sampling several targets takes 20 s or more and the grace window is
# another 30 s, and the EXIT trap's own cleanup spawns processes during exactly
# that window.
#
# WHY 30 SECONDS OF GRACE. That is what `scripts/test.sh`'s EXIT trap gets to
# run its tmux `kill-server` sweep and fence checks — generous against the few
# seconds those take, and still inside the margin the budget leaves. SIGTERM
# goes first for the same reason; SIGKILL follows only if the subshell is still
# alive after the grace, to a rebuilt order and then to the subshell itself.
# Taking the pipeline down within a bounded window is the point: leaving `wait`
# to block until `timeout-minutes` fires is the very outcome this budget exists
# to avoid.
#
# ---------------------------------------------------------------------------
# WHY THE STATUS IS VALIDATED, AND WHY IT COMES BEFORE THE FLOOR
#
# The pipeline's status is written to the rc file by the background subshell.
# An unreadable status fails closed, the same way the floor guards its own empty
# `count`: the `|| echo 1` covers only a missing file, and a writer that died
# mid-write leaves an empty or non-numeric one, on which `[ "$rc" -ne 0 ]`
# errors — and an erroring `if` condition reads as false, letting a failed run
# walk on to the floor check as though it had succeeded.
#
# THE STATUS IS THEN RETURNED UNTOUCHED, and that matters beyond tidiness:
# `scripts/swift-safe` exits 75 for an abandoned queue wait and 76 for "yielded
# the queue, verify remotely", and the remote verification valve
# (docs/specs/2026-08-16-remote-verification-valve-design.md) routes on 76 and
# only on 76. Flattening either to 1, or conflating the two, is a silent wrong
# answer. The status also comes FIRST, before the floor: a build error, an early
# crash, or a 75/76 all log fewer tests than any floor, and reporting them
# through the floor's message would both misdiagnose them and flatten them. The
# floor only means anything for a run that claims to have succeeded.
#
# ---------------------------------------------------------------------------
# STRICTNESS
#
# `set -uo pipefail`, deliberately WITHOUT errexit. This script's whole output is
# a verdict, and under errexit any incidental non-zero — a `ps` on a process
# that just exited, a `grep` that found no summary line — would abort it and
# report the failing command's status in place of the pass's own. Every step
# that can fail is therefore guarded explicitly, and the `|| true` guards below
# are kept so the code stays correct if errexit is ever added around it.
#
# The pipeline subshell nevertheless says `set +e` out loud: its only job is to
# run the pipeline and record `PIPESTATUS[0]`, and errexit there would abort it
# before the `echo` on exactly the runs whose status matters most.
#
# Bash 3.2 compatible, because macOS ships 3.2 as /bin/bash and the harness
# `scripts/ci/watched-test-pass.test.sh` is verified against it.

set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: watched-test-pass.sh --name <name> --budget-seconds <N> --floor <N>
                            --floor-message <text> [--out-dir <dir>]
                            -- <arguments forwarded to scripts/test.sh>

  --name           names the log, rc and stall files, and the pass in messages.
                   Letters, digits, dot, dash and underscore only.
  --budget-seconds how long the pass may run before it is sampled and killed.
  --floor          the smallest test count a run claiming success may report.
  --floor-message  the explanation appended to the floor's ::error:: line.
  --out-dir        where the files are written (default: /tmp).
  --               everything after this is forwarded to scripts/test.sh.
USAGE
}

die_usage() {
  echo "watched-test-pass.sh: $1" >&2
  usage
  exit 64
}

name=""
budget_seconds=""
floor=""
floor_message=""
out_dir="/tmp"
forwarded=()
saw_separator=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) [ "$#" -ge 2 ] || die_usage "--name needs a value"; name="$2"; shift 2 ;;
    --budget-seconds) [ "$#" -ge 2 ] || die_usage "--budget-seconds needs a value"; budget_seconds="$2"; shift 2 ;;
    --floor) [ "$#" -ge 2 ] || die_usage "--floor needs a value"; floor="$2"; shift 2 ;;
    --floor-message) [ "$#" -ge 2 ] || die_usage "--floor-message needs a value"; floor_message="$2"; shift 2 ;;
    --out-dir) [ "$#" -ge 2 ] || die_usage "--out-dir needs a value"; out_dir="$2"; shift 2 ;;
    --) saw_separator=1; shift; forwarded=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unrecognised argument '$1'" ;;
  esac
done

[ -n "$name" ] || die_usage "--name is required"
case "$name" in
  *[!A-Za-z0-9._-]*) die_usage "--name '$name' must be letters, digits, dot, dash or underscore" ;;
esac
case "$budget_seconds" in
  ''|*[!0-9]*) die_usage "--budget-seconds must be a whole number of seconds (got '$budget_seconds')" ;;
esac
[ "$budget_seconds" -gt 0 ] || die_usage "--budget-seconds must be greater than zero"
case "$floor" in
  ''|*[!0-9]*) die_usage "--floor must be a whole number (got '$floor')" ;;
esac
[ -n "$floor_message" ] || die_usage "--floor-message is required"
[ -d "$out_dir" ] || die_usage "--out-dir '$out_dir' is not a directory"
[ "$saw_separator" -eq 1 ] || die_usage "the -- separator is required, even with nothing after it"

# Resolved to an absolute path, so the pass does not depend on the caller's
# working directory. `scripts/test.sh` cds to the repository root itself.
here="$(cd "$(dirname "$0")" && pwd)"
test_script="$(cd "$here/.." && pwd)/test.sh"
if [ ! -x "$test_script" ]; then
  echo "::error::$name cannot run: $test_script is missing or not executable."
  exit 1
fi

log_file="$out_dir/$name.log"
rc_file="$out_dir/$name.rc"
stall_ps_file="$out_dir/$name-stall-ps.txt"

rm -f "$rc_file"
(
  # This subshell's only job is to run the pipeline and record its status, so
  # errexit is wrong here: on a red run it would abort the subshell before the
  # `echo` below and discard the very status we came to capture (a real
  # failure, or swift-safe's 75/76).
  set +e
  TERM=dumb script -q /dev/null "$test_script" ${forwarded[@]+"${forwarded[@]}"} \
    < /dev/null 2>&1 | tee "$log_file"
  echo "${PIPESTATUS[0]}" > "$rc_file"
) &
pipeline=$!
waited=0
while kill -0 "$pipeline" 2>/dev/null && [ "$waited" -lt "$budget_seconds" ]; do
  sleep 5
  waited=$((waited + 5))
done

# Collect a process tree by parent pid, so targets are found by lineage from the
# pipeline rather than by executable name.
descendants() {
  local parent="$1" child
  for child in $(pgrep -P "$parent" || true); do
    echo "$child"
    descendants "$child"
  done
}

if kill -0 "$pipeline" 2>/dev/null; then
  echo "::error::$name has been running for ${budget_seconds}s and is being sampled before it is killed."
  {
    echo "=== whole-machine process listing at stall (pass $name, budget ${budget_seconds}s) ==="
    ps -ww -axo pid,ppid,pgid,stat,%cpu,etime,comm,command || true
  } > "$stall_ps_file"
  kids=$(descendants "$pipeline" || true)
  {
    echo
    echo "=== descendants of the pipeline subshell (pid $pipeline) ==="
  } >> "$stall_ps_file"
  if [ -n "$kids" ]; then
    kid_list=$(printf '%s\n' "$kids" | paste -sd, -)
    ps -ww -o pid,ppid,pgid,stat,%cpu,etime,comm,command -p "$kid_list" >> "$stall_ps_file" || true
  else
    echo "(none)" >> "$stall_ps_file"
  fi
  sample_target_cap=4
  targets=""
  primary_taken=0
  primary_skipped=0
  for pid in $kids; do
    argv=$(ps -ww -o command= -p "$pid" 2>/dev/null || true)
    case "$argv" in
      *swiftpm-testing*|*xctest*|*TBDPackageTests*) ;;
      *) continue ;;
    esac
    if [ "$primary_taken" -lt "$sample_target_cap" ]; then
      targets="$targets $pid"
      primary_taken=$((primary_taken + 1))
    else
      primary_skipped=$((primary_skipped + 1))
    fi
  done
  if [ "$primary_skipped" -gt 0 ]; then
    echo "(primary sampling capped at $sample_target_cap targets; $primary_skipped further candidates skipped)" >> "$stall_ps_file"
  fi
  if [ -z "$targets" ]; then
    fallback_taken=0
    fallback_skipped=0
    for pid in $kids; do
      comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
      case "${comm##*/}" in
        ""|script|bash|sh|tee|sleep|Python|python3|swift-safe) continue ;;
      esac
      if [ "$fallback_taken" -lt "$sample_target_cap" ]; then
        targets="$targets $pid"
        fallback_taken=$((fallback_taken + 1))
      else
        fallback_skipped=$((fallback_skipped + 1))
      fi
    done
    if [ "$fallback_skipped" -gt 0 ]; then
      echo "(fallback sampling capped at $sample_target_cap targets; $fallback_skipped further candidates skipped)" >> "$stall_ps_file"
    fi
  fi
  if [ -z "$targets" ]; then
    echo "The pipeline has no sampleable descendants — $stall_ps_file carries the whole-machine listing instead."
  else
    {
      echo
      echo "=== sampled processes ==="
    } >> "$stall_ps_file"
    for pid in $targets; do
      ps -ww -o pid,comm,command -p "$pid" >> "$stall_ps_file" || true
      sample "$pid" 5 -mayDie -file "$out_dir/$name-stall-sample-$pid.txt" || echo "sample $pid failed"
    done
    for pid in $targets; do
      kill -KILL "$pid" 2>/dev/null || true
    done
  fi
  is_target() {
    local needle="$1" candidate
    for candidate in $targets; do
      if [ "$candidate" = "$needle" ]; then
        return 0
      fi
    done
    return 1
  }
  is_direct_child() {
    local needle="$1" child
    for child in $direct_children; do
      if [ "$child" = "$needle" ]; then
        return 0
      fi
    done
    return 1
  }
  build_kill_order() {
    local pid comm remaining="" deeper_first="" direct_others="" tee_pids=""
    kids=$(descendants "$pipeline" || true)
    for pid in $kids; do
      if is_target "$pid"; then
        continue
      fi
      remaining="$remaining $pid"
    done
    kids="$remaining"
    direct_children=$(pgrep -P "$pipeline" || true)
    for pid in $kids; do
      if is_direct_child "$pid"; then
        continue
      fi
      deeper_first="$pid $deeper_first"
    done
    for pid in $direct_children; do
      # The same `is_target` skip the deep walk above applies, so a sampled
      # target is filtered out of EVERY order rather than only most of them.
      # By construction the direct children are `script` and `tee`, and neither
      # can be a target — the fallback excludes both by name, and no forwarded
      # argument carries `swiftpm-testing`, `xctest` or `TBDPackageTests` — so
      # this closes a documented invariant rather than a reachable path, which
      # is why the harness has no fixture for it.
      if is_target "$pid"; then
        continue
      fi
      comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
      case "${comm##*/}" in
        tee) tee_pids="$tee_pids $pid" ;;
        *) direct_others="$direct_others $pid" ;;
      esac
    done
    kill_order="$deeper_first $direct_others $tee_pids"
  }
  build_kill_order
  for pid in $kill_order; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  teardown_waited=0
  while kill -0 "$pipeline" 2>/dev/null && [ "$teardown_waited" -lt 30 ]; do
    sleep 1
    teardown_waited=$((teardown_waited + 1))
  done
  if kill -0 "$pipeline" 2>/dev/null; then
    build_kill_order
    for pid in $kill_order; do
      kill -KILL "$pid" 2>/dev/null || true
    done
    kill -KILL "$pipeline" 2>/dev/null || true
  fi
  wait "$pipeline" || true
  exit 1
fi

wait "$pipeline" || true
rc=$(cat "$rc_file" 2>/dev/null || echo 1)
case "$rc" in
  ''|*[!0-9]*)
    echo "::error::$name left no readable exit status (got '$rc'); treating the run as failed."
    exit 1 ;;
esac
if [ "$rc" -ne 0 ]; then
  echo "::error::$name exited $rc"
  exit "$rc"
fi
# `|| true`: a log with no summary line makes the first `grep` exit 1, and under
# a surrounding errexit a failing command substitution in an assignment kills
# the shell — so the truncated-run case this floor exists for would die before
# ever reaching the `::error::` below.
count=$(grep -oE 'Test run with [0-9]+ tests?' "$log_file" | grep -oE '[0-9]+' | head -1 || true)
# A `--filter`/`--skip` regex exits GREEN on zero matches, so a bad regex or a
# renamed target would otherwise silently run nothing and pass.
if [ -z "$count" ] || [ "$count" -lt "$floor" ]; then
  echo "::error::$name ran ${count:-no} tests (floor $floor) — $floor_message"
  exit 1
fi
echo "$name executed $count tests."
