#!/usr/bin/env bash
# scripts/flake-verify.sh — the flake fixer's verifier
# (docs/specs/2026-10-07-flake-autofix-design.md §6.3–§6.5).
#
# It decides whether a candidate fix may become a ready PR. The session's own
# account of its results is recorded but never consulted.
#
# WHERE IT RUNS. Every subcommand that runs tests runs with its cwd in the
# VERIFICATION TREE, a separate checkout the session is never pointed at. This
# script runs from a copy of `main`'s scripts/ taken before the session starts,
# so SCRIPT_DIR below is that copy: `nightly-flake-stress.sh`, `test.sh`,
# `swift-safe` and `nightly-quarantine-audit.sh` all resolve from it, never from
# the candidate. `test.sh` itself calls `scripts/swift-safe`,
# `scripts/remote-verify.sh` and `scripts/tbd-home-fingerprint.sh` relative to
# the tree it runs in, so `apply-candidate` puts main's copies of those over the
# candidate's in the verification tree's working copy (RUNNER_CHAIN below).
#
# Usage (cwd: the verification tree unless noted):
#   flake-verify.sh quarantined --test ID
#       yes | no, or `ambiguous` and exit 2.
#   flake-verify.sh baseline --test ID --quarantined yes|no --out-dir D
#       BASELINE_ITERATIONS test-alone iterations on `main`, then choose-scope.
#       Exit 2: harness or build failure. Exit 4: too many exclusions (abort).
#   flake-verify.sh choose-scope --test ID --dir D --quarantined yes|no      (pure)
#   flake-verify.sh plan-iterations --scope test|pass --baseline-dir D --out F (pure)
#   flake-verify.sh apply-candidate --bundle B --base SHA
#       the verification tree becomes exactly SHA plus the bundle's commits.
#       Exit 3, the tree untouched, when the candidate commits a file under a
#       build directory; the paths go to stdout.
#   flake-verify.sh stress --scope test|pass --test ID --iterations N --out-dir D
#       exit 0 whenever the loop ran (the judge decides), 2 on a harness error.
#   flake-verify.sh protected-touched --base SHA
#       prints protected paths the candidate changed; exit 1 if any, 2 on error.
#   flake-verify.sh judge --scope S --test ID --dir D --iterations N
#                         --quarantined yes|no [--protected-touched F] [--plan F]
#                         [--baseline-md F]                               (pure)
#       exit 0 pass, 1 fail, 3 ineligible, 2 malformed input.
#   flake-verify.sh snapshot-processes --out F          (cwd: anywhere)
#   flake-verify.sh end-session-processes --before F    (cwd: anywhere)
#       TERM, then KILL, every process of this user that is new since the
#       snapshot; exit 5 if any of them survives (the attempt aborts).
#
# KILL DISCIPLINE (Tests/CLAUDE.md "The kill hazards"): processes are ended by
# captured PID only — the PIDs absent from a snapshot taken before the
# session — never by name, pattern, or process group.
# shellcheck disable=SC2329 # main dispatches subcommands by name

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- tunable numbers (spec §6.3, §9, §12) --------------------------------------

BASELINE_ITERATIONS=20
# More exclusions than this and the baseline is not measuring the test.
MAX_EXCLUDED=2
# N is never below the baseline's own count.
MIN_N=20
# The per-try allotment R and the timing behind each scope's cap,
# cap = floor((R - B - W) / t), all in seconds (spec §9). Measured on a
# macos-26 CI runner (3 cores, 2 compile jobs) in run 37686691741: a
# test-alone iteration took 17 to 25 seconds, and a warm fast pass 2 iteration
# 171 seconds, its first iteration 169 seconds more, a warm-up that persists
# after an incremental rebuild. B is a ceiling on the incremental rebuild,
# which measured 26 seconds. At these values the test-scope cap is 45 and the
# pass-scope cap 5. Fast passes 1a and 1b and the quiet pass were not
# measured; they use pass 2's figures until they are.
ALLOTMENT_S=1440
REBUILD_S=300
TEST_T_S=25
TEST_W_S=0
PASS_T_S=171
PASS_W_S=169
# Seconds between TERM and KILL, and after KILL before the survivor check.
TERM_GRACE_S=5
# Listing-and-killing passes, for processes forked while an earlier pass ran.
KILL_ROUNDS=3
KILL_GRACE_S=2

# The build directories. Both are gitignored, so a candidate that tracks a
# file under them meant to: `git add -f` would put it into the verification
# tree's warm build, which `git clean -e .build` keeps. `apply-candidate`
# refuses such a candidate before touching the tree; they are protected too
# (below), so nothing that reaches the judge can carry one.
BUILD_DIR_PATTERNS=('.build' '.build/*' '.swiftpm' '.swiftpm/*')

# Spec §6.4: every file on the verdict's path. A candidate touching any of them
# is never promoted. These are `case` globs, in which `*` also matches `/`.
PROTECTED_PATTERNS=(
  'scripts/nightly-flake-stress.sh'
  'scripts/nightly-quarantine-audit.sh'
  'scripts/flake-*'
  'scripts/flake_lib.py'
  'scripts/test.sh'
  'scripts/swift-safe'
  'scripts/remote-verify.sh'
  'scripts/tbd-home-fingerprint.sh'
  'scripts/ci/*'
  'scripts/repair-spm-workspace.sh'
  'Tests/TestSupport/FlakyTestSupport.swift'
  'Package.swift'
  'Package.resolved'
  "${BUILD_DIR_PATTERNS[@]}"
)

# The scripts `test.sh` runs by tree-relative path. `apply-candidate` puts
# main's copies over the candidate's, so the verdict comes from main's runner.
RUNNER_CHAIN=(swift-safe remote-verify.sh tbd-home-fingerprint.sh test.sh)

die() { echo "flake-verify: $*" >&2; exit 2; }

# -I: no PYTHON* variable, user site or current directory reaches the
# verdict; -S: no site-packages .pth or sitecustomize; -B: no .pyc written
# into the fingerprinted verifier copy.
py() { python3 -I -S -B "$SCRIPT_DIR/flake-verify.py" "$@"; }

toplevel() { git rev-parse --show-toplevel 2>/dev/null || die "not in a git tree: $(pwd)"; }

# --- quarantined ------------------------------------------------------------

cmd_quarantined() {
  local test="" root inv
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --test) test="${2:-}"; shift 2 ;;
      *) die "quarantined: unknown argument $1" ;;
    esac
  done
  [[ -n "$test" ]] || die "quarantined: --test is required"
  root="$(toplevel)"
  inv="$(mktemp "${TMPDIR:-/tmp}/flake-verify-inventory.XXXXXX")"
  bash "$SCRIPT_DIR/nightly-quarantine-audit.sh" inventory --out "$inv" --root "$root" || { rm -f "$inv"; die "the quarantine inventory failed"; }
  local rc=0
  py quarantined --test "$test" --inventory "$inv" --root "$root" || rc=$?
  rm -f "$inv"
  return "$rc"
}

# --- the stress loop ----------------------------------------------------------

# run_stress MODE ID N D: the stress loop with every structured output in D.
# Its console goes to D/stress.log. Returns the loop's exit code.
run_stress() {
  local mode="$1" id="$2" n="$3" d="$4" rc=0
  mkdir -p "$d" || die "cannot create $d"
  bash "$SCRIPT_DIR/nightly-flake-stress.sh" "$mode" "$id" --iterations "$n" \
    --xunit-dir "$d/xunit" --metrics-dir "$d/metrics" --log-dir "$d/logs" \
    --results-tsv "$d/results.tsv" --report-dir "$d/report" > "$d/stress.log" 2>&1 || rc=$?
  return "$rc"
}

cmd_baseline() {
  local test="" quarantined="" out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --test) test="${2:-}"; shift 2 ;;
      --quarantined) quarantined="${2:-}"; shift 2 ;;
      --out-dir) out="${2:-}"; shift 2 ;;
      *) die "baseline: unknown argument $1" ;;
    esac
  done
  [[ -n "$test" && -n "$quarantined" && -n "$out" ]] || die "baseline: --test, --quarantined and --out-dir are required"
  local rc=0
  run_stress --test "$test" "$BASELINE_ITERATIONS" "$out" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    tail -40 "$out/stress.log" >&2
    die "the baseline's stress loop failed (build or harness error)"
  fi
  cmd_choose_scope --test "$test" --dir "$out" --quarantined "$quarantined"
}

cmd_choose_scope() {
  local test="" dir="" quarantined=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --test) test="${2:-}"; shift 2 ;;
      --dir) dir="${2:-}"; shift 2 ;;
      --quarantined) quarantined="${2:-}"; shift 2 ;;
      *) die "choose-scope: unknown argument $1" ;;
    esac
  done
  py choose-scope --test "$test" --dir "$dir" --quarantined "$quarantined" \
    --iterations "$BASELINE_ITERATIONS" --max-excluded "$MAX_EXCLUDED"
}

cmd_plan_iterations() {
  local scope="" bdir="" out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope) scope="${2:-}"; shift 2 ;;
      --baseline-dir) bdir="${2:-}"; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      *) die "plan-iterations: unknown argument $1" ;;
    esac
  done
  py plan --scope "$scope" --baseline-dir "$bdir" --out "$out" --min-n "$MIN_N" \
    --allotment "$ALLOTMENT_S" --rebuild "$REBUILD_S" \
    --test-t "$TEST_T_S" --test-w "$TEST_W_S" --pass-t "$PASS_T_S" --pass-w "$PASS_W_S"
}

cmd_stress() {
  local scope="" test="" n="" out="" mode
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope) scope="${2:-}"; shift 2 ;;
      --test) test="${2:-}"; shift 2 ;;
      --iterations) n="${2:-}"; shift 2 ;;
      --out-dir) out="${2:-}"; shift 2 ;;
      *) die "stress: unknown argument $1" ;;
    esac
  done
  case "$scope" in
    test) mode=--test ;;
    pass) mode=--pass-of ;;
    *) die "stress: --scope must be test or pass" ;;
  esac
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || die "stress: --iterations must be a positive integer"
  local rc=0
  run_stress "$mode" "$test" "$n" "$out" || rc=$?
  [[ "$rc" -ne 2 ]] && return 0
  # A candidate that does not build fails like any failing stress run (spec
  # §8), and its build log goes to the second try. Any other exit 2 is the
  # harness's own failure and says nothing about the candidate.
  if grep -q 'BUILD FAILED' "$out/stress.log"; then
    cp "$out/stress.log" "$out/build-failed"
    return 0
  fi
  cp "$out/stress.log" "$out/harness-error"
  tail -40 "$out/stress.log" >&2
  return 2
}

cmd_judge() { py judge "$@"; }

# --- the candidate --------------------------------------------------------------

cmd_apply_candidate() {
  local bundle="" base=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bundle) bundle="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      *) die "apply-candidate: unknown argument $1" ;;
    esac
  done
  [[ -f "$bundle" && -n "$base" ]] || die "apply-candidate: --bundle FILE and --base SHA are required"
  cd "$(toplevel)" || die "cannot enter the verification tree"
  git bundle verify -q "$bundle" >/dev/null 2>&1 || die "the bundle does not verify against this tree"
  git reset -q --hard "$base" || die "cannot reset to $base"
  git clean -q -ffdx -e .build || die "cannot clean the tree"
  git fetch -q "$bundle" HEAD || die "cannot fetch the bundle"
  local tip; tip="$(git rev-parse FETCH_HEAD)" || die "no FETCH_HEAD"
  git merge-base --is-ancestor "$base" "$tip" || die "the candidate $tip does not descend from $base"
  # Before the tree is touched: a tracked file under a build directory would
  # overwrite the warm build the verdict runs.
  local listing path planted=()
  listing="$(mktemp "${TMPDIR:-/tmp}/flake-verify-changed.XXXXXX")" || die "cannot create a temporary file"
  changed_paths "$base" "$tip" > "$listing" || { rm -f "$listing"; die "git diff $base $tip failed"; }
  while IFS= read -r -d '' path; do
    # Not failing closed: every pattern starts `.build` or `.swiftpm`, pure
    # ASCII, which no normalization makes from other characters, so a
    # non-ASCII name elsewhere is not refused here (protected-touched flags it).
    if globs_match "$path" "${BUILD_DIR_PATTERNS[@]}"; then planted+=("$(shown "$path")"); fi
  done < "$listing"
  rm -f "$listing"
  if [[ ${#planted[@]} -gt 0 ]]; then
    # Exit 3: the candidate's own failure, not the harness's. The paths go to
    # stdout, one per line, for the verdict's protected list.
    printf '%s\n' "${planted[@]}"
    echo "flake-verify: the candidate commits files under a build directory, which the verifier never applies: ${planted[*]}" >&2
    exit 3
  fi
  git reset -q --hard "$tip" || die "cannot reset to the candidate"
  local f
  for f in "${RUNNER_CHAIN[@]}"; do
    [[ -f "$SCRIPT_DIR/$f" ]] || die "main's $f is missing from $SCRIPT_DIR"
    if ! { cp "$SCRIPT_DIR/$f" "scripts/$f" && chmod +x "scripts/$f"; }; then
      die "cannot put main's $f in place"
    fi
  done
  echo "$tip"
}

# changed_paths REV...: the paths `git diff REV...` names, NUL-separated and
# verbatim, so a name holding a newline, a quote or a non-ASCII byte arrives
# whole rather than C-quoted. --no-renames: a renamed protected file must list
# its old path too, or a rename (with edits) would slip past every pattern.
changed_paths() { git diff --no-renames --name-only -z "$@"; }

# 0 when PATH is non-empty printable ASCII, the only kind a glob can be
# trusted to match the way the filesystem will. The verification tree's
# filesystem folds case (handled by nocasematch in globs_match) and may
# normalize Unicode, so a name `case` sees as different could be the same
# file to it. Pure bash under the C locale, byte by byte: no fork per path.
matchable() {
  local LC_ALL=C
  [[ -n "$1" && "$1" != *[!\ -~]* ]]
}

# PATH as one printable line, for a listing a human reads.
shown() { if matchable "$1"; then printf '%s' "$1"; else printf '%q' "$1"; fi; }

# globs_match PATH PATTERN...: 0 when PATH matches a pattern, ignoring case.
globs_match() {
  local path="$1" pattern rc=1 restore
  shift
  restore="$(shopt -p nocasematch)"
  shopt -s nocasematch
  for pattern in "$@"; do
    # shellcheck disable=SC2254 # the pattern is a glob on purpose
    case "$path" in $pattern) rc=0; break ;; esac
  done
  eval "$restore"
  return "$rc"
}

# matches_any PATH PATTERN...: globs_match, failing closed – 0 also when PATH
# cannot be matched safely.
matches_any() {
  matchable "$1" || return 0
  globs_match "$@"
}

# 0 when PATH matches a protected pattern, or cannot be matched safely.
is_protected() { matches_any "$1" "${PROTECTED_PATTERNS[@]}"; }

cmd_protected_touched() {
  local base="" listing path found=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) base="${2:-}"; shift 2 ;;
      *) die "protected-touched: unknown argument $1" ;;
    esac
  done
  [[ -n "$base" ]] || die "protected-touched: --base is required"
  # Through a file, not a pipe: a failed diff must not read as an empty one.
  listing="$(mktemp "${TMPDIR:-/tmp}/flake-verify-changed.XXXXXX")" || die "cannot create a temporary file"
  changed_paths "$base...HEAD" > "$listing" || { rm -f "$listing"; die "git diff $base...HEAD failed"; }
  while IFS= read -r -d '' path; do
    if is_protected "$path"; then shown "$path"; echo; found=0; fi
  done < "$listing"
  rm -f "$listing"
  [[ "$found" -eq 0 ]] && return 1
  return 0
}

# --- the session's processes -------------------------------------------------------

# `pid<TAB>ppid<TAB>stat<TAB>start` for every process of this user. Start time
# with PID is the identity, so a recycled PID reads as a new process.
# FLAKE_VERIFY_PS lets the harness narrow the listing to processes it owns.
list_processes() {
  if [[ -n "${FLAKE_VERIFY_PS:-}" ]]; then
    "$FLAKE_VERIFY_PS"
    return
  fi
  ps -o pid=,ppid=,stat=,lstart= -U "$(id -u)" | awk '{pid=$1; ppid=$2; st=$3; $1=$2=$3=""; sub(/^ +/, ""); print pid "\t" ppid "\t" st "\t" $0}'
}

cmd_snapshot_processes() {
  local out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="${2:-}"; shift 2 ;;
      *) die "snapshot-processes: unknown argument $1" ;;
    esac
  done
  [[ -n "$out" ]] || die "snapshot-processes: --out is required"
  list_processes | awk -F'\t' '{print $1 "\t" $4}' > "$out" || die "cannot list processes"
  [[ -s "$out" ]] || die "the process snapshot is empty"
}

# This shell and its ancestors, one PID per line: never signalled.
ancestry() {
  local pid=$$
  while [[ -n "$pid" && "$pid" -gt 1 ]]; do
    echo "$pid"
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
}

# New processes: `pid<TAB>start` absent from the snapshot, excluding this
# shell's ancestry and anything descending from this shell (the listing itself).
new_processes() {
  local before="$1" listing anc
  listing="$(list_processes)" || return 1
  anc="$(ancestry | tr '\n' ' ')"
  awk -F'\t' -v self="$$" -v anc=" $anc" '
    NR == FNR { seen[$1 "\t" $2] = 1; next }
    { parent[$1] = $2; start[$1] = $4; stat[$1] = $3; order[++n] = $1 }
    END {
      for (k = 1; k <= n; k++) {
        p = order[k]
        if (seen[p "\t" start[p]]) continue
        if (index(anc, " " p " ")) continue
        if (stat[p] ~ /^Z/) continue
        q = p; mine = 0
        for (hops = 0; hops < 64 && q != "" && q > 1; hops++) {
          if (q == self) { mine = 1; break }
          q = parent[q]
        }
        if (mine) continue
        print p "\t" start[p]
      }
    }' "$before" - <<< "$listing"
}

# Whether `pid<TAB>start` is still alive and not a zombie.
still_alive() {
  local pid="${1%%$'\t'*}" start="${1#*$'\t'}"
  list_processes | awk -F'\t' -v p="$pid" -v s="$start" '$1 == p && $4 == s && $3 !~ /^Z/ {found = 1} END {exit !found}'
}

cmd_end_session_processes() {
  local before=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --before) before="${2:-}"; shift 2 ;;
      *) die "end-session-processes: unknown argument $1" ;;
    esac
  done
  [[ -s "$before" ]] || die "end-session-processes: --before must name a non-empty snapshot"
  local targets entry round all="" survivors=()
  # Rounds, because a process that traps TERM can fork a child after the
  # listing; each round lists again and ends whatever is new.
  for ((round = 1; round <= KILL_ROUNDS; round++)); do
    targets="$(new_processes "$before")" || die "cannot list processes"
    [[ -n "$targets" ]] || break
    all+="$targets"$'\n'
    echo "flake-verify: round $round: ending $(wc -l <<< "$targets" | tr -d ' ') process(es) new since the snapshot:"
    while IFS= read -r entry; do echo "  pid ${entry%%$'\t'*} (started ${entry#*$'\t'})"; kill -TERM "${entry%%$'\t'*}" 2>/dev/null; done <<< "$targets"
    sleep "$TERM_GRACE_S"
    while IFS= read -r entry; do
      still_alive "$entry" && kill -KILL "${entry%%$'\t'*}" 2>/dev/null
    done <<< "$targets"
    sleep "$KILL_GRACE_S"
  done
  if [[ -z "$all" ]]; then
    echo "flake-verify: no process is new since the snapshot"
    return 0
  fi
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    still_alive "$entry" && survivors+=("${entry%%$'\t'*}")
  done <<< "$all"
  if [[ "${#survivors[@]}" -gt 0 ]]; then
    echo "flake-verify: ${#survivors[@]} session process(es) survived SIGKILL: ${survivors[*]}; nothing is verified with one alive" >&2
    return 5
  fi
  return 0
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    quarantined)           cmd_quarantined "$@" ;;
    baseline)              cmd_baseline "$@" ;;
    choose-scope)          cmd_choose_scope "$@" ;;
    plan-iterations)       cmd_plan_iterations "$@" ;;
    apply-candidate)       cmd_apply_candidate "$@" ;;
    stress)                cmd_stress "$@" ;;
    protected-touched)     cmd_protected_touched "$@" ;;
    judge)                 cmd_judge "$@" ;;
    snapshot-processes)    cmd_snapshot_processes "$@" ;;
    end-session-processes) cmd_end_session_processes "$@" ;;
    *) die "usage: $0 {quarantined|baseline|choose-scope|plan-iterations|apply-candidate|stress|protected-touched|judge|snapshot-processes|end-session-processes} ..." ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
