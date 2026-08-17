#!/usr/bin/env bash
# Tests for scripts/remote-verify.sh — run: bash scripts/remote-verify.test.sh
#
# NOTHING HERE REACHES THE NETWORK, DISPATCHES A RUN, OR TOUCHES ~/tbd. Each
# case builds a throwaway bare repo in a temp dir and points a throwaway
# clone's `origin` at it, so every `git push` the valve makes is real and
# lands in a fixture. `gh` is a stub first on PATH; the real one is never
# reached, authenticated or not. `TBD_HOME` points at the same temp dir, so
# the dispatch tickets are taken in the fixture rather than in the runtime
# directory the live daemon and forty agent lanes share.
#
# The whole path runs: the real front-end, the real python driver, real flocks,
# real pushes. Only GitHub is fake — which is the only part that must be.
#
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F`/"$t" below
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/remote-verify.sh"
# shellcheck source=/dev/null
source "$SCRIPT"   # source-guard prevents main() from running

FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1; fi; }
assert_missing()  { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] unexpectedly contains [$3]"; FAIL=1; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/remote-verify-test.XXXXXX"; }

# Identity and signing are pinned per-command: a developer's global
# `commit.gpgsign` would otherwise make the fixture commits fail here (and only
# here) with no obvious cause.
GIT_FIXTURE=(git -c user.email=valve-test@example.invalid -c user.name="Valve Test" -c commit.gpgsign=false)

BRANCH="tbd/lane"

# --- fixture -----------------------------------------------------------------

# mkfixture ROOT -> a bare "origin" and a clone on $BRANCH whose HEAD commit is
# NOT yet on the remote, so a case can see exactly which ref the valve moved.
mkfixture() {
  local root="$1"
  git init -q --bare "$root/origin.git"
  git init -q -b main "$root/work"
  git -C "$root/work" remote add origin "$root/origin.git"
  : > "$root/work/seed"
  "${GIT_FIXTURE[@]}" -C "$root/work" add seed
  "${GIT_FIXTURE[@]}" -C "$root/work" commit -q -m "seed"
  git -C "$root/work" checkout -q -b "$BRANCH"
  git -C "$root/work" push -q origin "HEAD:refs/heads/$BRANCH"   # remote is at the seed
  echo "later" > "$root/work/seed"
  "${GIT_FIXTURE[@]}" -C "$root/work" add seed
  "${GIT_FIXTURE[@]}" -C "$root/work" commit -q -m "the commit under test"
  mkdir -p "$root/home/runtime" "$root/bin" "$root/xml"
}

# Three result files, as `test.yml` uploads them: the two fast passes and the
# quiet pass. The element shapes are the two writers SwiftPM actually uses —
# its own XCTest generator (flat) and Swift Testing's (indented, `<skipped />`).
write_xml() {
  local dir="$1"
  cat > "$dir/xunit-daemon.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
<testsuite name="TestResults" errors="0" tests="3" failures="1" time="12.5">
<testcase classname="TBDDaemonTests.OrphanGCTests" name="reclaimsStaleWorktrees" time="0.031"/>
<testcase classname="TBDDaemonTests.OrphanGCTests" name="quarantinesProfileDirs" time="0.044"><failure message="expected 1 got 2"></failure></testcase>
</testsuite>
</testsuites>
XML
  cat > "$dir/xunit-app.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="TestResults" errors="0" tests="3" failures="1" time="8.25">
    <testcase classname="TBDAppTests" name="testExample()" time="0.100"><failure message="Expectation failed: the valve stayed local" /></testcase>
    <testcase classname="TBDAppTests" name="skippedForNow()" time="0.000"><skipped /></testcase>
  </testsuite>
</testsuites>
XML
  cat > "$dir/xunit-quiet.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="TestResults" errors="0" tests="1" failures="0" time="1.5">
    <testcase classname="TBDDaemonLiveTests" name="attachesToTmux()" time="1.400" />
  </testsuite>
</testsuites>
XML
}

# A `gh` that answers from the environment and records every call it was given,
# so a case can assert that a dispatch did NOT happen as easily as that it did.
#
# RUNS EXIST ONLY ONCE THEY HAVE BEEN DISPATCHED, recorded in `$STUB_GH_RUNS`
# with a fresh id each time. A stub that answered `run list` with a constant run
# could not tell the run a lane just asked for from one that was already there,
# which is exactly the confusion the driver's baseline exists to prevent — and a
# case can seed that file to put a stale run in front of a lane.
stub_gh() {
  local root="$1"
  cat > "$root/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_GH_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_GH_LOG"
conclusion="${STUB_GH_CONCLUSION:-success}"
runs="${STUB_GH_RUNS:-}"
case "$1 ${2:-}" in
  "auth status")
    exit "${STUB_GH_AUTH_STATUS:-0}" ;;
  "pr list")
    if [ -n "${STUB_GH_PR_FAIL:-}" ]; then echo "API rate limit exceeded" >&2; exit 1; fi
    if [ -n "${STUB_GH_PR_OPEN:-}" ]; then echo 7; fi
    exit 0 ;;
  "workflow run")
    status="${STUB_GH_DISPATCH_STATUS:-0}"
    if [ "$status" -ne 0 ]; then exit "$status"; fi
    next=4242
    if [ -f "$runs" ]; then next=$(( $(wc -l < "$runs") + 4242 )); fi
    printf '%s %s\n' "$next" "$(git rev-parse HEAD)" >> "$runs"
    exit 0 ;;
  "run list")
    ids=(); shas=()
    if [ -f "$runs" ]; then
      while read -r id sha; do ids+=("$id"); shas+=("$sha"); done < "$runs"
    fi
    out=""; i=$(( ${#ids[@]} - 1 ))
    while [ $i -ge 0 ]; do
      entry="$(printf '{"databaseId":%s,"headSha":"%s","status":"completed","conclusion":"%s","event":"workflow_dispatch","url":"https://example.invalid/runs/%s"}' \
        "${ids[$i]}" "${shas[$i]}" "$conclusion" "${ids[$i]}")"
      if [ -n "$out" ]; then out="$out,$entry"; else out="$entry"; fi
      i=$((i - 1))
    done
    printf '[%s]\n' "$out"
    exit 0 ;;
  "run view")
    printf '{"status":"completed","conclusion":"%s","url":"https://example.invalid/runs/%s","jobs":[{"name":"Test","conclusion":"%s"}]}\n' \
      "$conclusion" "${3:-0}" "$conclusion"
    exit 0 ;;
  "run download")
    if [ -n "${STUB_GH_NO_ARTIFACT:-}" ]; then echo "no artifact matches xunit-results" >&2; exit 1; fi
    dir=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--dir" ]; then dir="$2"; fi
      shift
    done
    mkdir -p "$dir"
    cp "$STUB_GH_XML_DIR"/*.xml "$dir"/
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$root/bin/gh"
}

# run_verify ROOT [ENV=VAL ...] — runs the real front-end in the fixture clone
# with the stub `gh` first on PATH, leaving its combined output in OUT and its
# status in RC. Deliberately NOT `out=$(run_verify …)`: command substitution
# would run this in a subshell and the status would never come back.
OUT=""
RC=0
run_verify() {
  local root="$1"; shift
  OUT="$(cd "$root/work" && env \
    PATH="$root/bin:$PATH" \
    TBD_HOME="$root/home" \
    STUB_GH_LOG="$root/gh.log" \
    STUB_GH_RUNS="$root/runs" \
    STUB_GH_XML_DIR="$root/xml" \
    TBD_REMOTE_VERIFY_POLL_SECONDS=0.01 \
    TBD_REMOTE_VERIFY_CORRELATE_SECONDS=2 \
    TBD_REMOTE_VERIFY_RUN_SECONDS=2 \
    "$@" bash "$SCRIPT" 2>&1)"
  RC=$?
}

# What the fixture remote holds for a ref, or nothing.
remote_sha() { git -C "$1/work" ls-remote origin "refs/heads/$2" | awk '{print $1}'; }
gh_calls()   { cat "$1/gh.log" 2>/dev/null; }

setup() {
  local root; root="$(mktmpd)"
  mkfixture "$root"
  stub_gh "$root"
  write_xml "$root/xml"
  printf '%s\n' "$root"
}

# --- ref choice, at the unit level -------------------------------------------

test_dispatch_ref_for_always_answers_an_inert_ref() {
  # THE BRANCH IS NEVER THE ANSWER, whether or not a PR is open. Pushing it
  # would publish the commits a pre-push hook is gating, and it would leave a
  # ref that `scripts/sweep-preflight-refs.sh` does not match.
  local root; root="$(setup)"
  local ref; ref="$(cd "$root/work" && PATH="$root/bin:$PATH" dispatch_ref_for "$BRANCH")"
  assert_eq "a branch with no PR still dispatches a preflight ref" "preflight/$BRANCH" "$ref"
  ref="$(cd "$root/work" && PATH="$root/bin:$PATH" STUB_GH_PR_OPEN=1 dispatch_ref_for "$BRANCH")"
  assert_eq "and so does one with a PR open" "preflight/$BRANCH" "$ref"
  rm -rf "$root"
}

test_dispatch_ref_for_asks_github_nothing() {
  # The answer is the same in every case, so it needs no query — and a call
  # that cannot happen cannot be answered wrongly, rate-limited, or read as
  # "no PR" when it merely failed.
  local root; root="$(setup)"
  (cd "$root/work" && PATH="$root/bin:$PATH" STUB_GH_LOG="$root/gh.log" dispatch_ref_for "$BRANCH") >/dev/null
  assert_eq "the ref choice consults no gh call" "" "$(gh_calls "$root")"
  rm -rf "$root"
}

test_the_default_branch_is_read_from_the_remote_head() {
  local root; root="$(setup)"
  local trunk; trunk="$(cd "$root/work" && default_branch)"
  assert_eq "an unfetched origin/HEAD falls back to main" "main" "$trunk"
  git -C "$root/work" fetch -q origin
  git -C "$root/work" symbolic-ref "refs/remotes/origin/HEAD" "refs/remotes/origin/$BRANCH"
  trunk="$(cd "$root/work" && default_branch)"
  assert_eq "and a recorded one is believed" "$BRANCH" "$trunk"
  rm -rf "$root"
}

# --- preconditions: every refusal names itself and exits 78 ------------------

test_a_dirty_tree_refuses_and_stays_local() {
  local root; root="$(setup)"
  echo "uncommitted work" >> "$root/work/seed"
  run_verify "$root"
  assert_eq "dirty tree exits 78" "78" "$RC"
  assert_contains "and names the condition" "$OUT" "uncommitted"
  assert_missing "and dispatches nothing" "$(gh_calls "$root")" "workflow run"
  rm -rf "$root"
}

test_an_untracked_file_refuses_too() {
  local root; root="$(setup)"
  : > "$root/work/NewTests.swift"
  run_verify "$root"
  assert_eq "untracked file exits 78" "78" "$RC"
  assert_contains "and names the condition" "$OUT" "uncommitted"
  rm -rf "$root"
}

test_a_missing_gh_refuses_rather_than_falling_back_silently() {
  local root; root="$(setup)"
  OUT="$(cd "$root/work" && env PATH="/usr/bin:/bin" TBD_HOME="$root/home" bash "$SCRIPT" 2>&1)"
  RC=$?
  assert_eq "no gh exits 78" "78" "$RC"
  assert_contains "and says so" "$OUT" "gh is not installed"
  rm -rf "$root"
}

test_an_unauthenticated_gh_refuses() {
  local root; root="$(setup)"
  run_verify "$root" STUB_GH_AUTH_STATUS=1
  assert_eq "unauthenticated gh exits 78" "78" "$RC"
  assert_contains "and says so" "$OUT" "not authenticated"
  rm -rf "$root"
}

test_a_detached_head_refuses() {
  local root; root="$(setup)"
  git -C "$root/work" checkout -q --detach
  run_verify "$root"
  assert_eq "detached HEAD exits 78" "78" "$RC"
  assert_contains "and says so" "$OUT" "detached"
  rm -rf "$root"
}

test_the_default_branch_refuses_before_anything_is_pushed() {
  # DEFENCE IN DEPTH. `dispatch_ref_for` already answers `preflight/main`, so
  # this stop is redundant by construction — and worth having anyway, because
  # what a regression there would cost is a fast-forward of `origin/main`
  # firing main's CI and the Pages deploy on unreviewed commits.
  local root; root="$(setup)"
  git -C "$root/work" checkout -q main
  local before; before="$(remote_sha "$root" main)"
  run_verify "$root"
  assert_eq "verifying the default branch exits 78" "78" "$RC"
  assert_contains "and names it" "$OUT" "default branch"
  assert_eq "main on the remote is untouched" "$before" "$(remote_sha "$root" main)"
  assert_eq "and no preflight ref was created either" "" "$(remote_sha "$root" "preflight/main")"
  assert_missing "and nothing was dispatched" "$(gh_calls "$root")" "workflow run"
  rm -rf "$root"
}

# --- which ref gets pushed ---------------------------------------------------

test_the_inert_ref_is_pushed_and_the_branch_is_left_alone() {
  local root; root="$(setup)"
  local head before
  head="$(git -C "$root/work" rev-parse HEAD)"
  before="$(remote_sha "$root" "$BRANCH")"
  run_verify "$root"
  assert_eq "a passing remote run exits 0" "0" "$RC"
  assert_eq "the inert ref carries the commit" "$head" "$(remote_sha "$root" "preflight/$BRANCH")"
  assert_eq "the branch itself never moved" "$before" "$(remote_sha "$root" "$BRANCH")"
  assert_contains "and the dispatch named the inert ref" "$(gh_calls "$root")" "--ref preflight/$BRANCH"
  rm -rf "$root"
}

test_an_open_pr_changes_nothing_about_the_ref() {
  local root; root="$(setup)"
  local head before
  head="$(git -C "$root/work" rev-parse HEAD)"
  before="$(remote_sha "$root" "$BRANCH")"
  run_verify "$root" STUB_GH_PR_OPEN=1
  assert_eq "a passing remote run exits 0" "0" "$RC"
  assert_eq "the inert ref carries the commit" "$head" "$(remote_sha "$root" "preflight/$BRANCH")"
  assert_eq "the PR branch never moved" "$before" "$(remote_sha "$root" "$BRANCH")"
  rm -rf "$root"
}

test_an_inert_ref_survives_a_rewritten_commit() {
  # Amending or rebasing between two verifications leaves the throwaway ref on
  # a commit the new HEAD does not descend from. The ref is inert and belongs
  # to nobody, so it is forced; without that this lane could never verify
  # again after a rebase — and the branch it shadows still never moves.
  local root; root="$(setup)"
  run_verify "$root"
  local before; before="$(remote_sha "$root" "$BRANCH")"
  git -C "$root/work" reset -q --hard HEAD~1
  echo "a rewritten commit" > "$root/work/seed"
  "${GIT_FIXTURE[@]}" -C "$root/work" commit -q -am "rewritten"
  local head; head="$(git -C "$root/work" rev-parse HEAD)"
  run_verify "$root"
  assert_eq "the second run exits 0" "0" "$RC"
  assert_eq "and the inert ref moved to the rewritten commit" "$head" "$(remote_sha "$root" "preflight/$BRANCH")"
  assert_eq "the branch itself still never moved" "$before" "$(remote_sha "$root" "$BRANCH")"
  rm -rf "$root"
}

test_a_stale_run_for_this_commit_is_not_adopted() {
  # A run already registered for this sha — an earlier lane on the same commit,
  # or this lane's own previous attempt — answers `gh run list` instantly while
  # the run just dispatched takes seconds to register. Adopting it would report
  # its verdict while the run this lane paid for burns a macOS slot unwatched.
  local root; root="$(setup)"
  printf '4000 %s\n' "$(git -C "$root/work" rev-parse HEAD)" > "$root/runs"
  run_verify "$root"
  assert_eq "the run exits 0" "0" "$RC"
  assert_contains "the dispatched run is the one watched" "$(gh_calls "$root")" "run view 4243"
  assert_missing "and the stale run is not" "$(gh_calls "$root")" "run view 4000"
  rm -rf "$root"
}

# --- the verdict -------------------------------------------------------------

test_a_passing_remote_run_states_the_population_it_executed() {
  # SIX CALL SITES GREP FOR THIS EXACT LINE — `scripts/git-hooks/pre-push`,
  # `scripts/nightly-flake-stress.sh` and three steps of `.github/workflows/
  # test.yml` — and read its absence as a truncated or collapsed suite. A GREEN
  # remote verdict without it blocks the push naming the wrong cause.
  local root; root="$(setup)"
  run_verify "$root"
  assert_eq "a passing remote run exits 0" "0" "$RC"
  # 3 + 3 + 1, summed across the three passes exactly as the files declare them.
  assert_contains "and states the population it ran" "$OUT" "Test run with 7 tests passed"
  assert_contains "in the wording the callers grep for" \
    "$(printf '%s' "$OUT" | grep -oE 'Test run with [0-9]+ tests?' | head -1)" "Test run with 7 tests"
  rm -rf "$root"
}

test_a_passing_run_whose_results_are_missing_refuses_rather_than_inventing() {
  # A count no result file supports is worse than no verdict: every floor check
  # downstream would read it as the run's real population.
  local root; root="$(setup)"
  run_verify "$root" STUB_GH_NO_ARTIFACT=1
  assert_eq "an uncountable pass exits 78" "78" "$RC"
  assert_missing "and states no population" "$OUT" "Test run with"
  rm -rf "$root"
}

test_a_failing_remote_run_renders_the_failing_tests() {
  local root; root="$(setup)"
  run_verify "$root" STUB_GH_CONCLUSION=failure
  assert_eq "a failing remote run exits 1" "1" "$RC"
  assert_contains "names the failing job" "$OUT" "failing jobs: Test"
  assert_contains "names a test from the first pass" "$OUT" "TBDDaemonTests.OrphanGCTests.quarantinesProfileDirs"
  assert_contains "and its message" "$OUT" "expected 1 got 2"
  assert_contains "names a test from the second pass" "$OUT" "TBDAppTests.testExample()"
  assert_contains "and its message" "$OUT" "the valve stayed local"
  assert_contains "counts both" "$OUT" "2 failing tests"
  rm -rf "$root"
}

test_a_run_that_published_fewer_files_still_renders_what_it_has() {
  local root; root="$(setup)"
  rm "$root/xml/xunit-app.xml" "$root/xml/xunit-quiet.xml"
  run_verify "$root" STUB_GH_CONCLUSION=failure
  assert_eq "still exits 1" "1" "$RC"
  assert_contains "renders the one file it got" "$OUT" "quarantinesProfileDirs"
  assert_contains "and says how many files it read" "$OUT" "1 result file(s)"
  rm -rf "$root"
}

test_a_truncated_result_file_is_named_rather_than_read_as_green() {
  local root; root="$(setup)"
  rm "$root/xml/xunit-app.xml"
  printf '<?xml version="1.0"?>\n<testsuites>\n  <testsuite name="TestResults"><testcase classname="A" name="di' \
    > "$root/xml/xunit-daemon.xml"
  run_verify "$root" STUB_GH_CONCLUSION=failure
  assert_eq "still exits 1" "1" "$RC"
  assert_contains "the half-written file is named" "$OUT" "xunit-daemon.xml — unreadable"
  rm -rf "$root"
}

test_a_failing_run_with_no_results_artifact_still_fails_loudly() {
  local root; root="$(setup)"
  run_verify "$root" STUB_GH_CONCLUSION=failure STUB_GH_NO_ARTIFACT=1
  assert_eq "a failing run with no artifact still exits 1" "1" "$RC"
  assert_contains "says the results could not be had" "$OUT" "could not download"
  assert_contains "and points at the run" "$OUT" "https://example.invalid/runs/4242"
  rm -rf "$root"
}

test_a_run_with_no_verdict_returns_the_lane_to_the_local_queue() {
  local root; root="$(setup)"
  run_verify "$root" STUB_GH_CONCLUSION=cancelled
  assert_eq "a cancelled run exits 78, not 1" "78" "$RC"
  assert_contains "and says why" "$OUT" "no verdict"
  rm -rf "$root"
}

test_a_dispatch_that_fails_refuses() {
  local root; root="$(setup)"
  run_verify "$root" STUB_GH_DISPATCH_STATUS=1
  assert_eq "a failed dispatch exits 78" "78" "$RC"
  assert_contains "and names it" "$OUT" "could not dispatch"
  rm -rf "$root"
}

# --- the ticket pool, from the front-end -------------------------------------

test_no_ticket_refuses_without_pushing_or_dispatching() {
  # The ordering guarantee, end to end: a lane that never got a ticket leaves
  # no ref behind on the remote and spends no dispatch.
  local root; root="$(setup)"
  local before; before="$(remote_sha "$root" "$BRANCH")"
  run_verify "$root" TBD_REMOTE_VERIFY_SLOTS=0
  assert_eq "no ticket exits 78" "78" "$RC"
  assert_contains "and says the slots are in flight" "$OUT" "dispatch slots are in flight"
  assert_eq "the branch was not pushed" "$before" "$(remote_sha "$root" "$BRANCH")"
  assert_missing "and nothing was dispatched" "$(gh_calls "$root")" "workflow run"
  rm -rf "$root"
}

test_the_ticket_is_released_when_the_run_is_over() {
  local root; root="$(setup)"
  run_verify "$root"
  assert_eq "the first run passed" "0" "$RC"
  run_verify "$root" TBD_REMOTE_VERIFY_SLOTS=1
  assert_eq "a later lane still gets the only ticket" "0" "$RC"
  rm -rf "$root"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
exit $FAIL
