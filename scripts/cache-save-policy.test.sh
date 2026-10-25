#!/usr/bin/env bash
# Tests the SwiftPM cache-save policy in .github/workflows/test.yml —
# run: bash scripts/cache-save-policy.test.sh
#
# WHY THIS EXISTS. The `test` job saves its ~1.5 GB SwiftPM cache entry only
# when the run is a push to main, or a pull request that touched a first-party
# library or the package manifest. Half of that decision is a shell step
# (`Decide whether this run may save the SwiftPM cache`) and half is the save
# step's `if:` expression. Get either wrong in the "never save" direction and
# nothing goes red — every later run simply restores nothing and pays a ~12
# minute cold build, for as long as it takes someone to notice. Get it wrong in
# the "always save" direction and the 10 GB store churns main's entry out again.
# Neither failure has a symptom this repo's suites can see, so the branches are
# exercised here instead. The same holds for WHEN it saves — right after the
# build and the marker recording, before any test pass, so that a run cancelled
# during its tests has still saved — and the step order is pinned here too. So
# is WHAT the key names: the `test` job's build flags, without which an entry
# compiled with other flags would be restored and, on an exact hit, never
# replaced.
#
# NOTHING HERE TOUCHES A REAL REPO, REMOTE OR CACHE, with one deliberate
# exception noted below. Each case builds a throwaway git repo in a temp dir,
# plants `refs/remotes/origin/<base>` in it by hand, and runs the workflow's own
# shell against it with `$GITHUB_OUTPUT` pointed at a scratch file. The step is
# EXTRACTED from the workflow rather than copied here, so a divergence between
# what CI runs and what this proves cannot arise.
#
# THE FIXTURE REPOSITORIES MIRROR THIS PACKAGE'S REAL LAYOUT, and that is
# load-bearing rather than decorative. `Sources/TBDDaemonLib` does not exist:
# the TBDDaemonLib library target is declared with `path: "Sources/TBDDaemon"`,
# the `TBDDaemon` executable target beside it being `main.swift` alone. A
# fixture that invented the directory let the step's path list name it and pass
# every case here while matching nothing in the real repository — a `git diff`
# over a path absent from both sides exits 0, so every library-touching PR was
# scored as not library-touching and never saved the cache the decision exists
# to grant it. Two cases guard that now, and they are the exception to the
# paragraph above: `test_the_gated_paths_exist_in_this_repository` resolves each
# gated path against the checkout the harness is running in, and
# `test_the_gated_paths_match_the_wipe_scripts_list` pins the list to
# `WIPE_PATHS` in `scripts/ci/first-party-wipe-needed.sh`, which asks the same
# question about the same paths. Both read git trees and nothing else.
#
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
# shellcheck disable=SC2016 # the workflow's own text is matched literally, not expanded
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW="$HERE/../.github/workflows/test.yml"
STEP_NAME='Decide whether this run may save the SwiftPM cache'

FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1; fi; }

# Identity and signing are pinned per-command: a developer's global
# `commit.gpgsign` would otherwise make the fixture commits fail here, and only
# here, with no obvious cause.
GIT_FIXTURE=(git -c user.email=cache-policy-test@example.invalid -c user.name="Cache Policy Test" -c commit.gpgsign=false)

# --- extract the step's shell from the workflow ------------------------------

# Everything indented under this step's `run: |`, dedented. Blank lines inside
# the block are preserved; the first non-blank line that is not part of the
# block ends it.
extract_step_script() {
  awk -v name="      - name: $STEP_NAME" '
    $0 == name { found = 1; next }
    found && $0 == "        run: |" { inrun = 1; next }
    inrun {
      if ($0 == "") { print ""; next }
      if ($0 !~ /^          /) { exit }
      print substr($0, 11)
    }
  ' "$WORKFLOW"
}

SAVE_STEP_NAME='Save SwiftPM build artifacts and dependencies'

# The `if:` expression the save step carries, as one line, read from WORKFLOW
# or from the workflow file given as $1 (a mutated copy, in the cases below).
extract_save_if() {
  awk -v name="      - name: $SAVE_STEP_NAME" '
    $0 == name { found = 1; next }
    found && /^      - / { exit }
    found && $0 ~ /^        if:/ { print; exit }
  ' "${1:-$WORKFLOW}"
}

# The `test` job's step names, in order, one per line.
test_job_step_names() {
  awk '
    /^  test:[ \t]*$/ { injob = 1; next }
    injob && /^  [^ #]/ { exit }
    injob && /^      - name: / { sub(/^      - name: /, ""); print }
  ' "${1:-$WORKFLOW}"
}

# Where the save sits among the steps around it: `ordered` when it comes after
# the build and the marker recording and before the first test pass, otherwise
# `misordered`, or `missing <step>` when one of the four cannot be found.
save_position_verdict() {
  local wf="${1:-$WORKFLOW}" names build record save pass
  names="$(test_job_step_names "$wf")"
  build="$(awk 'index($0, "Build (") == 1 { print NR; exit }' <<<"$names")"
  record="$(awk 'index($0, "Record the sources these build artifacts came from") == 1 { print NR; exit }' <<<"$names")"
  save="$(awk -v want="$SAVE_STEP_NAME" '$0 == want { print NR; exit }' <<<"$names")"
  pass="$(awk 'index($0, "Test (") == 1 { print NR; exit }' <<<"$names")"
  if [[ -z "$build" ]]; then echo "missing build"; return; fi
  if [[ -z "$record" ]]; then echo "missing record"; return; fi
  if [[ -z "$save" ]]; then echo "missing save"; return; fi
  if [[ -z "$pass" ]]; then echo "missing test pass"; return; fi
  if (( build < record && record < save && save < pass )); then
    echo "ordered"
  else
    echo "misordered"
  fi
}

SCRIPT="$(mktemp "${TMPDIR:-/tmp}/cache-save-policy.XXXXXX.sh")"
extract_step_script > "$SCRIPT"

# Everything this harness mints is reclaimed from one EXIT trap rather than from
# the line after each case, so an interrupted run leaves nothing behind either.
# On a runner the VM is discarded anyway; on a developer box a harness that
# leaks a fixture repo per case per run is how a temp directory fills up.
FIXTURE_ROOTS=()
cleanup() {
  rm -f "$SCRIPT"
  local root
  for root in ${FIXTURE_ROOTS+"${FIXTURE_ROOTS[@]}"}; do rm -rf "$root"; done
}
trap cleanup EXIT

# --- fixture -----------------------------------------------------------------

# mkrepo ROOT -> a repo with one commit on `main`, that commit also planted at
# refs/remotes/origin/main, and a `topic` branch checked out on top of it. That
# is the shape `actions/checkout` with `fetch-depth: 0` leaves behind, which is
# what the step reads.
mkrepo() {
  local root="$1"
  git init -q -b main "$root"
  mkdir -p "$root/Sources/TBDShared" "$root/Sources/TBDDaemon/Server" \
           "$root/Sources/TBDTerminalSerialization" "$root/Sources/TBDApp" "$root/docs"
  echo base > "$root/Sources/TBDShared/Base.swift"
  # TBDDaemonLib's sources, under the directory Package.swift gives that target.
  echo base > "$root/Sources/TBDDaemon/Server/Router.swift"
  echo base > "$root/Sources/TBDDaemon/main.swift"
  echo base > "$root/Sources/TBDTerminalSerialization/Frame.swift"
  echo base > "$root/Sources/TBDApp/Base.swift"
  echo base > "$root/docs/notes.md"
  echo base > "$root/Package.swift"
  echo base > "$root/Package.resolved"
  "${GIT_FIXTURE[@]}" -C "$root" add -A
  "${GIT_FIXTURE[@]}" -C "$root" commit -q -m base
  git -C "$root" update-ref refs/remotes/origin/main HEAD
  git -C "$root" checkout -q -b topic
}

# change_file ROOT PATH -> one commit on `topic` changing that path.
change_file() {
  local root="$1" path="$2"
  echo changed > "$root/$path"
  "${GIT_FIXTURE[@]}" -C "$root" add -A
  "${GIT_FIXTURE[@]}" -C "$root" commit -q -m "change $path"
}

# run_step ROOT EVENT BASE -> the step's stdout, with the resolved
# `library_touched=` output appended as `output:<value>` so one capture carries
# both what CI would read and what a human would see in the log.
run_step() {
  local root="$1" event="$2" base="$3"
  local out; out="$(mktemp "${TMPDIR:-/tmp}/cache-save-policy-output.XXXXXX")"
  local log
  log="$(cd "$root" && EVENT_NAME="$event" BASE_REF="$base" GITHUB_OUTPUT="$out" bash "$SCRIPT" 2>&1)"
  printf '%s\noutput:%s\n' "$log" "$(sed -n 's/^library_touched=//p' "$out")"
  rm -f "$out"
}

# decision ROOT EVENT BASE -> just the written output value.
decision() {
  sed -n 's/^output://p' <<<"$(run_step "$@")"
}

# plant_unrelated_base ROOT NAME -> refs/remotes/origin/<NAME> pointing at a
# commit that shares no history with HEAD. `git rev-parse` resolves it, so the
# step gets past its base-ref guard, and the three-dot `git diff` then exits 128
# with "no merge base" — which is the only realistic way to reach the step's
# error branch.
plant_unrelated_base() {
  local root="$1" name="$2" empty_tree sha
  empty_tree="$(git -C "$root" hash-object -t tree /dev/null)"
  sha="$("${GIT_FIXTURE[@]}" -C "$root" commit-tree "$empty_tree" -m unrelated)"
  git -C "$root" update-ref "refs/remotes/origin/$name" "$sha"
}

with_repo() {
  local fn="$1"
  local root; root="$(mktemp -d "${TMPDIR:-/tmp}/cache-save-policy-repo.XXXXXX")"
  FIXTURE_ROOTS+=("$root")
  mkrepo "$root"
  "$fn" "$root"
}

# --- cases -------------------------------------------------------------------

# The extraction is the one thing that can make every case below pass while
# proving nothing: an awk program that matched no step would hand each case an
# empty script, which writes no output and reads as `false`. Check the extracted
# text before trusting a single verdict.
test_the_extraction_found_the_real_step() {
  local script; script="$(cat "$SCRIPT")"
  assert_contains "extracted the step's shell" "$script" 'library_touched'
  assert_contains "and the paths it gates on" "$script" 'Sources/TBDShared Sources/TBDDaemon Sources/TBDTerminalSerialization Package.swift Package.resolved'
  assert_contains "and the three-dot diff" "$script" 'origin/$BASE_REF...HEAD'
}

# The gated paths, one per line, read out of the extracted shell rather than
# retyped — a list this harness typed for itself would agree with itself while
# CI gated on something else.
gated_paths() {
  awk '
    /^git diff --quiet/ { grab = 1; next }
    grab {
      sub(/\|\| status=\$\?/, "")
      for (i = 1; i <= NF; i++) print $i
      exit
    }
  ' "$SCRIPT"
}

# `WIPE_PATHS` from the sibling script, same treatment.
wipe_script_paths() {
  awk '
    /^WIPE_PATHS=\(/ { grab = 1; next }
    grab && /^\)/ { exit }
    grab { gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "") print }
  ' "$HERE/ci/first-party-wipe-needed.sh"
}

# The case the original list failed: `Sources/TBDDaemonLib/` is not a directory
# in this package, so a `git diff` naming it matched nothing on either side,
# exited 0, and scored every library-touching PR as not library-touching. A
# pathspec that cannot be resolved against this checkout is not a gate.
test_the_gated_paths_exist_in_this_repository() {
  local path count=0
  while read -r path; do
    [[ -n "$path" ]] || continue
    count=$((count + 1))
    if git -C "$HERE/.." rev-parse --verify --quiet "HEAD:$path" >/dev/null; then
      echo "ok   - the step gates on $path, which exists here"
    else
      echo "FAIL - the step gates on $path, which does not exist in this repository"
      FAIL=1
    fi
  done <<<"$(gated_paths)"
  # Without this the loop above passes vacuously when the extraction breaks.
  if [[ "$count" -gt 0 ]]; then
    echo "ok   - the gated path list was read out of the step ($count paths)"
  else
    echo "FAIL - no gated paths were read out of the step"
    FAIL=1
  fi
}

# Both lists answer "did a first-party library move?" — this one to decide
# whether the PR has earned a cache entry, the wipe script's to decide whether
# the cached artifacts can be trusted. Two answers to one question that disagree
# means one of them is wrong, so they are pinned to each other.
test_the_gated_paths_match_the_wipe_scripts_list() {
  assert_eq "the gated paths are the wipe script's WIPE_PATHS" \
    "$(wipe_script_paths)" "$(gated_paths)"
}

# A push run never consults the diff — the save step decides it on the event
# alone — so the step must answer without needing a base ref at all.
test_a_push_run_does_not_consult_the_diff() { with_repo case_push; }
case_push() {
  local out; out="$(run_step "$1" push "")"
  assert_contains "a push run answers false and says why" "$out" 'the save step decides on the event alone'
  assert_eq "a push run writes library_touched=false" "false" "$(sed -n 's/^output://p' <<<"$out")"
}

# The dispatch case is what the whole policy exists for: a preflight run must
# never be told it may save.
test_a_dispatch_run_answers_false() { with_repo case_dispatch; }
case_dispatch() {
  assert_eq "a workflow_dispatch run writes library_touched=false" "false" "$(decision "$1" workflow_dispatch "")"
}

test_a_pr_touching_tbdshared_answers_true() { with_repo case_shared; }
case_shared() {
  change_file "$1" Sources/TBDShared/Base.swift
  assert_eq "TBDShared -> true" "true" "$(decision "$1" pull_request main)"
}

# TBDDaemonLib's sources live under `Sources/TBDDaemon`, so that is the path a
# real library change appears at.
test_a_pr_touching_tbddaemonlib_answers_true() { with_repo case_daemonlib; }
case_daemonlib() {
  change_file "$1" Sources/TBDDaemon/Server/Router.swift
  assert_eq "TBDDaemonLib -> true" "true" "$(decision "$1" pull_request main)"
}

# TBDDaemonLib imports TBDTerminalSerialization, so a change confined to that
# target recompiles the library just the same and earns the entry too.
test_a_pr_touching_tbdterminalserialization_answers_true() { with_repo case_serialization; }
case_serialization() {
  change_file "$1" Sources/TBDTerminalSerialization/Frame.swift
  assert_eq "TBDTerminalSerialization -> true" "true" "$(decision "$1" pull_request main)"
}

test_a_pr_touching_the_manifest_answers_true() { with_repo case_manifest; }
case_manifest() {
  change_file "$1" Package.resolved
  assert_eq "Package.resolved -> true" "true" "$(decision "$1" pull_request main)"
}

# Both manifest files are gated, for different reasons — Package.resolved moves
# the restore-keys scope, Package.swift re-plans the build graph — so both get
# their own case rather than one standing in for the other.
test_a_pr_touching_the_package_manifest_answers_true() { with_repo case_package_swift; }
case_package_swift() {
  change_file "$1" Package.swift
  assert_eq "Package.swift -> true" "true" "$(decision "$1" pull_request main)"
}

# The discriminating half. A first-party source change that is NOT one of the
# gated directories must still answer false, or the gate is just "any change".
test_a_pr_touching_another_first_party_target_answers_false() { with_repo case_app; }
case_app() {
  change_file "$1" Sources/TBDApp/Base.swift
  assert_eq "TBDApp alone -> false" "false" "$(decision "$1" pull_request main)"
}

test_a_docs_only_pr_answers_false() { with_repo case_docs; }
case_docs() {
  change_file "$1" docs/notes.md
  assert_eq "docs only -> false" "false" "$(decision "$1" pull_request main)"
}

# An unresolvable base ref is indistinguishable from "this PR changed nothing",
# so it must answer false AND say so where a human will see it — silence there
# would read as a deliberate verdict.
test_a_missing_base_ref_answers_false_and_warns() { with_repo case_missing_base; }
case_missing_base() {
  change_file "$1" Sources/TBDShared/Base.swift
  local out; out="$(run_step "$1" pull_request nonexistent-base)"
  assert_eq "missing base ref -> false" "false" "$(sed -n 's/^output://p' <<<"$out")"
  assert_contains "and warns" "$out" '::warning::origin/nonexistent-base is absent'
}

# The third arm of the step's `case`: a base ref that RESOLVES but that the
# three-dot diff cannot reach, which git reports as "no merge base" with exit
# 128. It must land on false with a warning rather than being read as either
# verdict — a 128 silently taken for "nothing changed" is the same answer as a
# real "nothing changed", and only the warning tells them apart.
test_a_diff_that_errors_answers_false_and_warns() { with_repo case_diff_error; }
case_diff_error() {
  change_file "$1" Sources/TBDShared/Base.swift
  plant_unrelated_base "$1" unrelated
  local out; out="$(run_step "$1" pull_request unrelated)"
  assert_eq "an erroring diff -> false" "false" "$(sed -n 's/^output://p' <<<"$out")"
  assert_contains "and warns with the status" "$out" '::warning::git diff against origin/unrelated failed (128)'
}

# The status functions in an `if:` expression that would let a step run after
# an earlier step failed, space-separated, or nothing.
widening_status_functions_in() {
  grep -oE '(always|cancelled|failure)\(\)' <<<"$1" | sort -u | paste -sd' ' -
}

# WORKFLOW with the step named $2 cut out and appended at the end of the file,
# which is the end of the `test` job, the last job in it. The comment above the
# step stays where it was; only the step moves.
move_step_to_end() {
  awk -v name="      - name: $2" '
    $0 == name { moving = 1 }
    moving && $0 == "" { moving = 0; next }
    moving { held = held $0 "\n"; next }
    { print }
    END { printf "\n%s", held }
  ' "$1"
}

# The step is only half the decision; the save step's `if:` is the other half,
# and no fixture can execute a GitHub expression. Assert its clauses are all
# present, so dropping one — which would silently stop every save, or start
# saving from preflight refs again — cannot pass unnoticed.
#
# The save runs right after the build, and its `if:` carries no status function,
# so GitHub's implicit `success()` keeps it from running after any earlier step
# failed, the marker recording included. An `always()` or `!cancelled()` there
# would store an entry whose recording broke — no marker in it, so every run that
# restored it would wipe the libraries for nothing.
test_the_save_step_gates_on_the_build_and_the_policy() {
  local expr d; expr="$(extract_save_if)"
  assert_contains "the save step has an if: expression" "$expr" 'if:'
  assert_contains "gated on the build having succeeded" "$expr" "steps.build.outcome == 'success'"
  assert_contains "gated on the restore having missed" "$expr" "steps.spm-cache.outputs.cache-hit != 'true'"
  assert_contains "saves on a push" "$expr" "github.event_name == 'push'"
  assert_contains "and on a library-touching pull request" "$expr" "github.event_name == 'pull_request' && steps.cache_policy.outputs.library_touched == 'true'"
  assert_eq "no status function widens it past the implicit success()" "" "$(widening_status_functions_in "$expr")"
  # MUTATION: an `always()` in the save's `if:` is seen by the check above.
  d="$(mktemp -d "${TMPDIR:-/tmp}/cache-save-policy.XXXXXX")"
  FIXTURE_ROOTS+=("$d")
  sed "s/if: \${{ steps\.build\.outcome == 'success' && steps\.spm-cache/if: \${{ always() \&\& steps.build.outcome == 'success' \&\& steps.spm-cache/" \
    "$WORKFLOW" > "$d/always.yml"
  assert_eq "mutation: an always() in the save's if: is caught" "always()" \
    "$(widening_status_functions_in "$(extract_save_if "$d/always.yml")")"
}

# WHEN the save happens is the other half of the design. It comes right after
# the build, so a run that `concurrency` cancels during its tests — most of a
# run's life — has already saved; and after the marker recording, so the entry
# carries the marker the next run's wipe decision reads. A save moved behind the
# tests goes back to saving nothing for every cancelled run, and nothing here
# would go red for it.
test_the_save_follows_the_build_and_the_marker_and_precedes_the_tests() {
  local d
  assert_eq "the save comes after the build and the marker recording, before the first test pass" \
    "ordered" "$(save_position_verdict)"
  d="$(mktemp -d "${TMPDIR:-/tmp}/cache-save-policy.XXXXXX")"
  FIXTURE_ROOTS+=("$d")
  # MUTATION: the save moved to the end of the job, behind every test pass.
  move_step_to_end "$WORKFLOW" "$SAVE_STEP_NAME" > "$d/save-last.yml"
  assert_eq "mutation: a save behind the tests is caught" "misordered" \
    "$(save_position_verdict "$d/save-last.yml")"
  # MUTATION: the marker recorded after the save, so the entry lacks it.
  move_step_to_end "$WORKFLOW" "Record the sources these build artifacts came from" > "$d/record-last.yml"
  assert_eq "mutation: a marker recorded after the save is caught" "misordered" \
    "$(save_position_verdict "$d/record-last.yml")"
}

RESTORE_STEP_NAME='Restore SwiftPM build artifacts and dependencies'
# What the restore step's key and fallback prefix both carry: the `test` job's
# build flags.
FLAGS_SEGMENT='-flags-${{ env.CI_SWIFTPM_FLAGS }}-'

# `key <value>` and `prefix <value>` for the restore step's primary key and its
# restore-keys lines, read from WORKFLOW or from the workflow file given as $1.
restore_keys() {
  awk -v name="      - name: $RESTORE_STEP_NAME" '
    $0 == name { found = 1; next }
    found && /^      - / { exit }
    found && /^          key: / { sub(/^          key: /, ""); print "key " $0; next }
    found && $0 == "          restore-keys: |" { inkeys = 1; next }
    found && inkeys && /^            [^ ]/ { sub(/^            /, ""); print "prefix " $0; next }
    found { inkeys = 0 }
  ' "${1:-$WORKFLOW}"
}

# `keyed` when the key and its one fallback prefix both carry the build flags,
# the prefix ending with them and being the key's own prefix; otherwise what is
# wrong.
key_verdict() {
  local keys key prefix
  keys="$(restore_keys "${1:-$WORKFLOW}")"
  key="$(sed -n 's/^key //p' <<<"$keys")"
  prefix="$(sed -n 's/^prefix //p' <<<"$keys")"
  if [[ -z "$key" || -z "$prefix" ]]; then echo "missing"; return; fi
  if [[ "$prefix" == *$'\n'* ]]; then echo "more than one prefix"; return; fi
  if [[ "$key" != *"$FLAGS_SEGMENT"* ]]; then echo "key lacks the flags"; return; fi
  if [[ "$prefix" != *"$FLAGS_SEGMENT" ]]; then echo "prefix lacks the flags"; return; fi
  if [[ "$key" != "$prefix"* ]]; then echo "prefix is not the key's"; return; fi
  echo "keyed"
}

# WHAT the key names. Every compile command carries the `test` job's
# CI_SWIFTPM_FLAGS, so an entry built with other flags is compiled again in
# full, and an exact-key hit on one would also skip the save (`cache-hit`):
# every later run with the same sources would restore it and compile everything
# again. Nothing goes red for that either, so the key and its fallback prefix
# must both carry the flags.
test_the_cache_key_carries_the_build_flags() {
  local d
  assert_eq "the key and its fallback prefix both carry the build flags" "keyed" "$(key_verdict)"
  d="$(mktemp -d "${TMPDIR:-/tmp}/cache-save-policy.XXXXXX")"
  FIXTURE_ROOTS+=("$d")
  # MUTATION: the fallback prefix without them, which restores an entry
  # compiled with other flags.
  sed 's/flags-\${{ env\.CI_SWIFTPM_FLAGS }}-$//' "$WORKFLOW" > "$d/prefix.yml"
  assert_eq "mutation: a fallback prefix without the flags is caught" "prefix lacks the flags" \
    "$(key_verdict "$d/prefix.yml")"
  # MUTATION: the primary key without them, whose exact hit would skip the save.
  sed 's/-flags-\${{ env\.CI_SWIFTPM_FLAGS }}-src-/-src-/' "$WORKFLOW" > "$d/key.yml"
  assert_eq "mutation: a key without the flags is caught" "key lacks the flags" \
    "$(key_verdict "$d/key.yml")"
}

# --- run ---------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  echo "--- $t"
  "$t"
done

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All cache-save-policy cases passed."
