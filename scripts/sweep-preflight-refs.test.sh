#!/usr/bin/env bash
# Tests for scripts/sweep-preflight-refs.sh — run: bash scripts/sweep-preflight-refs.test.sh
#
# NOTHING HERE TOUCHES A REAL REMOTE. Each case builds a throwaway bare repo in
# a temp dir and points a throwaway clone's `origin` at it, so the sweep runs
# its real `git ls-remote` / `git push --delete` against a fixture. `gh` is a
# stub on PATH; the real one is never reached, authenticated or not.
#
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F`/"$t" below
# shellcheck disable=SC2016 # the sed mutation expressions must NOT expand here
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$HERE/sweep-preflight-refs.sh"
# shellcheck source=/dev/null
source "$SWEEP"   # source-guard prevents main() from running

FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1; fi; }
assert_missing()  { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] unexpectedly contains [$3]"; FAIL=1; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/preflight-sweep-test.XXXXXX"; }

# --- fixture -----------------------------------------------------------------

# mkfixture ROOT BRANCH... -> a bare "origin" carrying one commit on each named
# branch, plus a clone whose `origin` points at it. Identity and signing are
# pinned per-command: a developer's global `commit.gpgsign` would otherwise make
# the fixture commit fail here (and only here) with no obvious cause.
GIT_FIXTURE=(git -c user.email=sweep-test@example.invalid -c user.name="Sweep Test" -c commit.gpgsign=false)

# THE SEED COMMIT IS BACKDATED, AND EVERY DELETION CASE DEPENDS ON IT. The sweep
# spares refs whose commit is younger than an hour, so a fixture committed
# "now" would be kept by the AGE guard in every case that means to be exercising
# the PR guard — each of them would pass while proving nothing. Backdating puts
# the age question out of the way, and `push_fresh_ref` is how a case opts back
# into it. `date +%s`-relative rather than a fixed year so the arithmetic reads
# the same however far in the future this runs.
FIXTURE_SEED_AGE_SECONDS=$(( 30 * 24 * 3600 ))

mkfixture() {
  local root="$1"; shift
  git init -q --bare "$root/origin.git"
  git init -q "$root/work"
  : > "$root/work/seed"
  "${GIT_FIXTURE[@]}" -C "$root/work" add seed
  GIT_AUTHOR_DATE="@$(( $(date +%s) - FIXTURE_SEED_AGE_SECONDS ))" \
  GIT_COMMITTER_DATE="@$(( $(date +%s) - FIXTURE_SEED_AGE_SECONDS ))" \
    "${GIT_FIXTURE[@]}" -C "$root/work" commit -q -m "seed"
  git -C "$root/work" remote add origin "$root/origin.git"
  local branch
  for branch in "$@"; do
    git -C "$root/work" push -q origin "HEAD:refs/heads/$branch"
  done
}

# "backdated" / the age itself — whether a dated commit is the fixture's seed,
# allowing the one-second slack three separate `date +%s` reads can introduce.
# A verdict rather than a comparison so a failure prints the age that missed.
seed_age_verdict() {
  local age="$1"
  if [ "$age" -ge "$FIXTURE_SEED_AGE_SECONDS" ] \
     && [ "$age" -le $(( FIXTURE_SEED_AGE_SECONDS + 2 )) ]; then
    echo "backdated"
  else
    echo "$age"
  fi
}

# push_fresh_ref ROOT REF -> a ref pointing at a commit made just now, which is
# what a lane that has this second pushed a preflight ref looks like.
push_fresh_ref() {
  local root="$1" ref="$2"
  "${GIT_FIXTURE[@]}" -C "$root/work" commit -q --allow-empty -m "fresh"
  git -C "$root/work" push -q origin "HEAD:refs/heads/$ref"
}

# push_aged_ref ROOT REF -> the same, backdated, and on a commit that is NOT
# reachable from `main`. The unreachability is what lets a `--single-branch`
# clone of `main` be genuinely missing the object; see `clone_without_namespace`.
push_aged_ref() {
  local root="$1" ref="$2" when
  when="@$(( $(date +%s) - FIXTURE_SEED_AGE_SECONDS ))"
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
    "${GIT_FIXTURE[@]}" -C "$root/work" commit -q --allow-empty -m "aged $ref"
  git -C "$root/work" push -q origin "HEAD:refs/heads/$ref"
}

# clone_without_namespace ROOT -> a second clone at `$ROOT/clone` holding only
# `main`'s history, so the sweep run from it has to FETCH before it can date
# anything. That is the production situation — a sweep run from any worktree has
# never seen most of the namespace — and the fixture's own `work` repo cannot
# stand in for it, because it authored those commits and has the objects already.
# `file://` rather than a plain path: a local-path clone hardlinks the whole
# object store and the clone would arrive holding everything.
clone_without_namespace() {
  local root="$1"
  git clone -q --single-branch --branch main "file://$root/origin.git" "$root/clone"
}

# stub_gh ROOT [OPEN_PR_BRANCHES] — a `gh` on PATH that reports an open PR for
# each space-separated branch named, and none for anything else. Two knobs stand
# in for the two ways a real `gh` misbehaves:
#
#   STUB_GH_FAIL=1  it fails outright — a rate limit, or a token that lost its
#                   scope.
#   STUB_GH_WARN=…  it succeeds, prints nothing on stdout, and writes the given
#                   text to STDERR. That is the shape of every benign `gh`
#                   message: a deprecation notice, an upgrade nag, a hint about
#                   a missing default remote.
stub_gh() {
  local root="$1" open="${2:-}"
  mkdir -p "$root/bin"
  cat > "$root/bin/gh" <<STUB
#!/usr/bin/env bash
if [[ -n "\${STUB_GH_FAIL:-}" ]]; then echo "API rate limit exceeded" >&2; exit 1; fi
if [[ -n "\${STUB_GH_WARN:-}" ]]; then echo "\$STUB_GH_WARN" >&2; exit 0; fi
head=""
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "--head" ]]; then head="\$2"; shift; fi
  shift
done
for open_branch in $open; do
  if [[ "\$head" == "\$open_branch" ]]; then echo 7; exit 0; fi
done
exit 0
STUB
  chmod +x "$root/bin/gh"
}

# refs_on_origin ROOT -> the fixture remote's branch names, sorted, space-joined.
refs_on_origin() {
  git -C "$1/work" ls-remote --heads origin | awk '{sub(/^refs\/heads\//, "", $2); print $2}' | sort | tr '\n' ' '
}

# run_sweep ROOT ARGS... -> runs the sweep in ROOT's clone with the stub `gh`
# first on PATH, leaving its combined output in OUT and its status in RC.
# Deliberately NOT `out=$(run_sweep …)`: command substitution would run this in
# a subshell and the status would never come back.
#
# SWEEP_UNDER_TEST names a mutant to run in place of the real script; empty means
# the real one.
# SWEEP_CWD names which repo under ROOT the sweep runs in; empty means `work`.
OUT=""
RC=0
SWEEP_UNDER_TEST=""
SWEEP_CWD=""
run_sweep() {
  local root="$1"; shift
  OUT="$(cd "$root/${SWEEP_CWD:-work}" && PATH="$root/bin:$PATH" \
         bash "${SWEEP_UNDER_TEST:-$SWEEP}" "$@" 2>&1)"
  RC=$?
}

# --- mutants ------------------------------------------------------------------
#
# EVERY GUARD IS MUTATION-CHECKED. `mutant_of` writes a copy of the sweep with
# one guard deliberately weakened; the case re-runs against it and the verdict
# has to flip. A guard whose test passes for reasons unrelated to the guard is
# the failure mode this exists to prevent — and on a script that deletes refs on
# a shared remote, the guard rotting silently is the expensive outcome.
MUTANT_DIR="$(mktmpd)"
MUTANT_SEQ=0
trap 'rm -rf "$MUTANT_DIR"' EXIT
mutant_of() {
  local sed_expr="$1" out
  MUTANT_SEQ=$((MUTANT_SEQ + 1))
  out="$MUTANT_DIR/mutant.$MUTANT_SEQ.sh"
  sed -E "$sed_expr" "$SWEEP" > "$out"
  echo "$out"
}

# Run a case against a mutant and restore the real script afterwards.
run_mutant_sweep() {
  local root="$1" sed_expr="$2"; shift 2
  SWEEP_UNDER_TEST="$(mutant_of "$sed_expr")"
  run_sweep "$root" "$@"
  SWEEP_UNDER_TEST=""
}

# --- the namespace guard, at the unit level ----------------------------------

test_preflight_branch_of_only_matches_the_namespace() {
  assert_eq "a preflight ref yields its branch" "feature-a" "$(preflight_branch_of refs/heads/preflight/feature-a)"
  assert_eq "a nested branch keeps its slashes" "tbd/x/y" "$(preflight_branch_of refs/heads/preflight/tbd/x/y)"
  assert_eq "main yields nothing" "" "$(preflight_branch_of refs/heads/main)"
  assert_eq "a lookalike prefix yields nothing" "" "$(preflight_branch_of refs/heads/preflighty/x)"
  assert_eq "a bare namespace with no branch yields nothing" "" "$(preflight_branch_of refs/heads/preflight/)"
  assert_eq "a tag in the namespace yields nothing" "" "$(preflight_branch_of refs/tags/preflight/x)"
}

# --- the sweep ---------------------------------------------------------------

test_dry_run_is_the_default() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/orphan
  stub_gh "$root"
  run_sweep "$root"
  assert_contains "orphan planned for deletion" "$OUT" "PLAN delete preflight/orphan"
  assert_contains "the plan says it did nothing" "$OUT" "dry run: nothing deleted"
  assert_eq "the ref survives a default run" "main preflight/orphan " "$(refs_on_origin "$root")"
  assert_eq "dry run exits clean" "0" "$RC"
  rm -rf "$root"
}

test_apply_deletes_an_orphaned_preflight_ref() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/orphan
  stub_gh "$root"
  run_sweep "$root" --apply
  assert_contains "orphan planned for deletion" "$OUT" "PLAN delete preflight/orphan"
  assert_eq "only main is left" "main " "$(refs_on_origin "$root")"
  assert_eq "apply exits clean" "0" "$RC"
  rm -rf "$root"
}

# THE OPEN-PR GUARD. The lane can dispatch against this ref again at any moment.
test_a_ref_whose_branch_has_an_open_pr_survives_apply() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main feature-a preflight/feature-a
  stub_gh "$root" "feature-a"
  run_sweep "$root" --apply
  assert_contains "kept for its open PR" "$OUT" "KEEP open-pr preflight/feature-a"
  assert_missing "and never planned for deletion" "$OUT" "PLAN delete preflight/feature-a"
  assert_eq "the ref survives" "feature-a main preflight/feature-a " "$(refs_on_origin "$root")"
  rm -rf "$root"
}

# THE NAMESPACE GUARD. Everything outside `preflight/` is untouchable, including
# refs whose names merely start with the word.
test_refs_outside_the_namespace_are_never_touched() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main feature-c preflighty/decoy preflight/orphan
  stub_gh "$root"
  run_sweep "$root" --apply
  assert_contains "main skipped by name" "$OUT" "SKIP outside-namespace refs/heads/main"
  assert_contains "a lookalike prefix skipped" "$OUT" "SKIP outside-namespace refs/heads/preflighty/decoy"
  assert_missing "main never planned" "$OUT" "PLAN delete main"
  assert_eq "only the preflight ref went" "feature-c main preflighty/decoy " "$(refs_on_origin "$root")"
  rm -rf "$root"
}

# A failed query is not evidence of a missing PR. Treating it as one would empty
# the whole namespace the first time the API rate limits.
test_a_failed_pr_query_keeps_the_ref_and_reports() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/orphan
  stub_gh "$root"
  export STUB_GH_FAIL=1
  run_sweep "$root" --apply
  unset STUB_GH_FAIL
  assert_contains "kept, state unknown" "$OUT" "KEEP unknown-pr-state preflight/orphan"
  assert_contains "the failure is reported" "$OUT" "gh pr list failed for orphan"
  assert_eq "the ref survives" "main preflight/orphan " "$(refs_on_origin "$root")"
  assert_eq "and the sweep exits non-zero" "1" "$RC"
  rm -rf "$root"
}

test_a_missing_gh_refuses_to_sweep() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/orphan
  # An empty PATH, so a `gh` installed on this machine cannot be found. `bash`
  # is named absolutely for the same reason — PATH is where it would come from.
  mkdir -p "$root/bin"
  local out
  out="$(cd "$root/work" && PATH="$root/bin" /bin/bash "$SWEEP" --apply 2>&1)"
  local rc=$?
  assert_contains "names the missing tool" "$out" "gh is not installed"
  assert_eq "refuses with 2" "2" "$rc"
  assert_eq "the ref survives" "main preflight/orphan " "$(refs_on_origin "$root")"
  rm -rf "$root"
}

# THE IN-NAMESPACE REAL BRANCH. `preflight/` is a convention, not a reservation:
# a human can name a branch `preflight/flaky-repro` and open a PR for it. The
# stripped name (`flaky-repro`) has no PR, so asking only about that deletes the
# branch the PR is built on — breaking the PR rather than reclaiming an orphan.
# The lookalike-prefix case above does NOT cover this: `preflighty/decoy` never
# enters the namespace at all, while this ref does and is then misidentified.
test_an_in_namespace_branch_with_its_own_pr_survives() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/flaky-repro
  stub_gh "$root" "preflight/flaky-repro"
  run_sweep "$root" --apply
  assert_contains "kept for its own open PR" "$OUT" "KEEP open-pr preflight/flaky-repro"
  assert_missing "and never planned for deletion" "$OUT" "PLAN delete preflight/flaky-repro"
  assert_eq "the branch the PR is built on survives" "main preflight/flaky-repro " \
    "$(refs_on_origin "$root")"
  assert_eq "the sweep exits clean" "0" "$RC"
  rm -rf "$root"
}

# MUTATION. Ask about the stripped name alone — the shape this sweep shipped with
# — and the same fixture deletes a branch with an open PR.
test_querying_the_refs_own_name_is_load_bearing() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/flaky-repro
  stub_gh "$root" "preflight/flaky-repro"
  run_mutant_sweep "$root" \
    's/has_open_pr_for_any "\$branch" "\$NAMESPACE\$branch"/has_open_pr "$branch"/' --apply
  assert_contains "asking only the stripped name plans the deletion" "$OUT" \
    "PLAN delete preflight/flaky-repro"
  assert_eq "and the branch with the open PR is gone" "main " "$(refs_on_origin "$root")"
  rm -rf "$root"
}

# A BENIGN `gh` NOTICE IS NOT A PR. `gh` writes deprecation notices, upgrade nags
# and remote hints to stderr while exiting 0 with an empty stdout. Folding the
# two streams together makes any of them read as "a PR exists" — KEEP, so it
# fails safe, but the first `gh` release that starts printing a notice would
# quietly stop this sweep reclaiming anything.
test_a_gh_stderr_notice_is_not_read_as_an_open_pr() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/orphan
  stub_gh "$root"
  export STUB_GH_WARN="gh: A new release of gh is available"
  run_sweep "$root" --apply
  unset STUB_GH_WARN
  assert_contains "the orphan is still planned for deletion" "$OUT" "PLAN delete preflight/orphan"
  assert_missing "and is not mistaken for an open PR" "$OUT" "KEEP open-pr"
  assert_eq "only main is left" "main " "$(refs_on_origin "$root")"
  assert_eq "the sweep exits clean" "0" "$RC"
  rm -rf "$root"
}

# MUTATION. Fold stderr back into the captured value and the notice becomes a PR.
test_reading_stdout_only_is_load_bearing() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/orphan
  stub_gh "$root"
  export STUB_GH_WARN="gh: A new release of gh is available"
  run_mutant_sweep "$root" \
    "s/--jq '\.\[\]\.number'\)\"/--jq '.[].number' 2>\&1)\"/" --apply
  unset STUB_GH_WARN
  assert_contains "with the streams merged a notice reads as an open PR" "$OUT" \
    "KEEP open-pr preflight/orphan"
  assert_eq "and the orphan is never reclaimed" "main preflight/orphan " \
    "$(refs_on_origin "$root")"
  rm -rf "$root"
}

# THE AGE GUARD. The driver pushes `preflight/<branch>` for every lane, including
# one whose branch has no PR, so a brand-new ref is eligible for deletion the
# instant it exists — and a sweep landing between the push and the dispatch that
# consumes it would take the ref out from under a lane that is mid-flight.
test_a_fresh_ref_is_spared_even_with_no_open_pr() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main
  push_fresh_ref "$root" preflight/just-pushed
  stub_gh "$root"
  run_sweep "$root" --apply
  assert_contains "kept for its age" "$OUT" "KEEP too-young preflight/just-pushed"
  assert_missing "and never planned for deletion" "$OUT" "PLAN delete preflight/just-pushed"
  assert_eq "the ref survives" "main preflight/just-pushed " "$(refs_on_origin "$root")"
  assert_eq "a spared young ref is not a problem" "0" "$RC"
  rm -rf "$root"
}

# MUTATION. Drop the grace period to zero and the same ref is reclaimed while
# its lane is still waiting on the verdict.
test_the_age_guard_is_load_bearing() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main
  push_fresh_ref "$root" preflight/just-pushed
  stub_gh "$root"
  run_mutant_sweep "$root" 's/^MIN_AGE_SECONDS=3600$/MIN_AGE_SECONDS=0/' --apply
  assert_contains "without the grace period a fresh ref is planned" "$OUT" \
    "PLAN delete preflight/just-pushed"
  assert_eq "and deleted under the lane that pushed it" "main " "$(refs_on_origin "$root")"
  rm -rf "$root"
}

# The guard must not become a blanket KEEP: a ref old enough to be inert still
# goes. Without this, a mutant that spared everything would pass the case above.
test_an_aged_ref_with_no_pr_is_still_reclaimed() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/stale
  push_fresh_ref "$root" preflight/just-pushed
  stub_gh "$root"
  run_sweep "$root" --apply
  assert_contains "the aged ref goes" "$OUT" "PLAN delete preflight/stale"
  assert_contains "the fresh one stays" "$OUT" "KEEP too-young preflight/just-pushed"
  assert_eq "only the aged ref was reclaimed" "main preflight/just-pushed " \
    "$(refs_on_origin "$root")"
  rm -rf "$root"
}

# AN AGE THAT CANNOT BE READ IS NOT AN OLD AGE, at the unit level.
test_commit_time_of_distinguishes_unreadable_from_old() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main
  local sha; sha="$(git -C "$root/work" rev-parse HEAD)"
  local dated; dated="$(cd "$root/work" && commit_time_of "$sha")"
  assert_eq "a real commit dates to digits only" "" "${dated//[0-9]/}"
  # A WINDOW, NOT AN EQUALITY, and the slack is not laziness. `mkfixture` reads
  # `date +%s` once for the author date and again for the committer date, and this
  # line reads it a third time — a second ticking over between any two of them
  # shifts the age by one, which is a red suite for nothing. What the case pins is
  # that the seed is backdated by the fixture's constant, not the instant three
  # clock reads happened to agree.
  assert_eq "and it is the backdated seed" "backdated" \
    "$(seed_age_verdict "$(( $(date +%s) - dated ))")"
  assert_eq "an object this clone cannot see dates to nothing" "" \
    "$(cd "$root/work" && commit_time_of 0000000000000000000000000000000000000001)"
  rm -rf "$root"
}

# `plant_dangling_ref ROOT NAME` — a ref on origin pointing at an object that
# does not exist there. `git ls-remote` lists it happily; any fetch of it dies
# with `upload-pack: not our ref`. Written with `printf` because git itself
# refuses to create one, which is the same reason it can exist in the wild only
# by way of something that bypassed git.
plant_dangling_ref() {
  local root="$1" name="$2"
  mkdir -p "$root/origin.git/refs/heads/$(dirname "$name")"
  printf '%s\n' "0000000000000000000000000000000000000001" \
    > "$root/origin.git/refs/heads/$name"
}

# END TO END. An unreadable age keeps the ref and reports, and — the part that
# matters more — it does not take the rest of the namespace with it. git aborts a
# whole fetch on the first ref it cannot serve, so without the per-ref retry a
# single dangling ref leaves every age unknown, and since unknown means KEEP, the
# dangling ref survives to do it again on every run from then on.
test_a_dangling_ref_is_kept_without_blocking_the_rest() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main
  push_aged_ref "$root" preflight/stale
  plant_dangling_ref "$root" preflight/ghost
  clone_without_namespace "$root"
  stub_gh "$root"
  SWEEP_CWD="clone"
  run_sweep "$root" --apply
  SWEEP_CWD=""
  assert_contains "the dangling ref is kept" "$OUT" "KEEP unknown-age preflight/ghost"
  assert_contains "and the failure is named" "$OUT" "its age will be unknown"
  assert_contains "the aged orphan is still reclaimed" "$OUT" "PLAN delete preflight/stale"
  assert_eq "so only the unreadable one is left behind" "main preflight/ghost " \
    "$(refs_on_origin "$root")"
  assert_eq "and the sweep exits non-zero" "1" "$RC"
  rm -rf "$root"
}

# MUTATION. Drop the per-ref retry and the dangling ref takes the whole namespace
# hostage: nothing can be dated, so nothing is ever reclaimed.
test_the_per_ref_fetch_retry_is_load_bearing() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main
  push_aged_ref "$root" preflight/stale
  plant_dangling_ref "$root" preflight/ghost
  clone_without_namespace "$root"
  stub_gh "$root"
  SWEEP_CWD="clone"
  run_mutant_sweep "$root" \
    's/if ! git fetch --quiet "\$REMOTE" "\$ref" 2>\/dev\/null; then/if false; then/' --apply
  SWEEP_CWD=""
  assert_contains "without the retry the healthy ref is undatable too" "$OUT" \
    "KEEP unknown-age preflight/stale"
  assert_missing "so nothing is planned" "$OUT" "PLAN delete"
  assert_eq "and the namespace is never reclaimed" "main preflight/ghost preflight/stale " \
    "$(refs_on_origin "$root")"
  rm -rf "$root"
}

# --- the close path: one ref, through the same two guards ---------------------
#
# A PR closing reclaims its own `preflight/<branch>`, and it does so by narrowing
# THIS sweep to that ref rather than deleting it itself. The age guard is the
# reason: a lane that pushed a preflight ref seconds ago and dispatched a run
# against it is racing whoever merges the PR next, and in a forty-worktree fleet
# that race is ordinary rather than exotic. A close path with its own
# `git push --delete` honours neither guard.

test_a_named_branch_is_still_subject_to_the_age_guard() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main
  push_fresh_ref "$root" preflight/just-pushed
  stub_gh "$root"
  run_sweep "$root" --apply --branch just-pushed
  assert_contains "the close path keeps a ref a live run may still check out" "$OUT" \
    "KEEP too-young preflight/just-pushed"
  assert_missing "and never plans it" "$OUT" "PLAN delete preflight/just-pushed"
  assert_eq "so the ref survives the merge that closed the PR" "main preflight/just-pushed " \
    "$(refs_on_origin "$root")"
  assert_eq "and sparing it is not a problem" "0" "$RC"
  rm -rf "$root"
}

# MUTATION. Drop the grace period and the close path deletes the ref a lane
# pushed seconds ago — the run it dispatched then fails at `actions/checkout`.
test_the_age_guard_is_load_bearing_for_a_named_branch() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main
  push_fresh_ref "$root" preflight/just-pushed
  stub_gh "$root"
  run_mutant_sweep "$root" 's/^MIN_AGE_SECONDS=3600$/MIN_AGE_SECONDS=0/' \
    --apply --branch just-pushed
  assert_contains "without the grace period the close path plans it" "$OUT" \
    "PLAN delete preflight/just-pushed"
  assert_eq "and takes it out from under the lane" "main " "$(refs_on_origin "$root")"
  rm -rf "$root"
}

# The filter must not become a blanket KEEP either: the ordinary close, where the
# ref has outlived any run, still reclaims.
test_a_named_branch_that_is_inert_is_reclaimed() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/closed-pr preflight/other
  stub_gh "$root"
  run_sweep "$root" --apply --branch closed-pr
  assert_contains "the named ref goes" "$OUT" "PLAN delete preflight/closed-pr"
  assert_contains "and every other ref is left to the weekly pass" "$OUT" \
    "SKIP other-branch refs/heads/preflight/other"
  assert_missing "with no verdict reached on it" "$OUT" "preflight/other ("
  assert_eq "only the named ref was reclaimed" "main preflight/other " \
    "$(refs_on_origin "$root")"
  assert_eq "the close path exits clean" "0" "$RC"
  rm -rf "$root"
}

# THE OTHER GUARD IS REUSED TOO. A branch can carry a second open PR — the one
# that closed is not necessarily the only one — and the ref stays while any of
# them could dispatch against it again.
test_a_named_branch_with_another_open_pr_survives() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main feature-a preflight/feature-a
  stub_gh "$root" "feature-a"
  run_sweep "$root" --apply --branch feature-a
  assert_contains "kept for the open PR" "$OUT" "KEEP open-pr preflight/feature-a"
  assert_eq "the ref survives" "feature-a main preflight/feature-a " "$(refs_on_origin "$root")"
  rm -rf "$root"
}

# A CLOSE WITH NOTHING TO RECLAIM IS THE COMMON CASE — most PRs never had a
# preflight ref pushed for them at all.
test_a_named_branch_with_no_ref_says_so_and_exits_clean() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/somebody-else
  stub_gh "$root"
  run_sweep "$root" --apply --branch never-verified
  assert_contains "it says there was nothing to do" "$OUT" \
    "no preflight ref for never-verified; nothing to reclaim"
  assert_eq "nothing else is touched" "main preflight/somebody-else " "$(refs_on_origin "$root")"
  assert_eq "and it exits clean" "0" "$RC"
  rm -rf "$root"
}

# THE FILTER CANNOT WIDEN WHAT IS ELIGIBLE. Naming the default branch — which is
# what a close event on a PR merged into `main` would hand a naive filter — reaches
# the namespace guard exactly as it always did.
test_a_named_branch_cannot_reach_outside_the_namespace() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main
  stub_gh "$root"
  run_sweep "$root" --apply --branch main
  assert_contains "main is skipped by the namespace guard" "$OUT" \
    "SKIP outside-namespace refs/heads/main"
  assert_contains "and the named branch has no preflight ref" "$OUT" \
    "no preflight ref for main; nothing to reclaim"
  assert_eq "main survives" "main " "$(refs_on_origin "$root")"
  assert_eq "and the sweep exits clean" "0" "$RC"
  rm -rf "$root"
}

# AN EMPTY NAME IS NOT "EVERY REF". The close path spells one ref as
# `--branch "$HEAD_REF"`, so a variable that came out empty must refuse rather
# than quietly widening into a whole-namespace apply.
test_a_branch_filter_requires_a_name() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/orphan
  stub_gh "$root"
  run_sweep "$root" --apply --branch ""
  assert_contains "an empty name is refused" "$OUT" "--branch requires a branch name"
  assert_eq "refuses with 2" "2" "$RC"
  assert_eq "and nothing is swept" "main preflight/orphan " "$(refs_on_origin "$root")"
  run_sweep "$root" --apply --branch
  assert_contains "a missing name is refused too" "$OUT" "--branch requires a branch name"
  assert_eq "also with 2" "2" "$RC"
  assert_eq "and still nothing is swept" "main preflight/orphan " "$(refs_on_origin "$root")"
  rm -rf "$root"
}

# MUTATION. Accept the empty name and `--branch "$HEAD_REF"` with an unset
# variable sweeps the whole namespace under a close event.
test_the_empty_branch_name_refusal_is_load_bearing() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/orphan
  stub_gh "$root"
  run_mutant_sweep "$root" 's/if \[\[ \$# -eq 0 \|\| -z "\$1" \]\]; then/if false; then/' \
    --apply --branch ""
  assert_contains "an accepted empty name reaches every ref" "$OUT" "PLAN delete preflight/orphan"
  assert_eq "and empties the namespace" "main " "$(refs_on_origin "$root")"
  rm -rf "$root"
}

# --- the close path's wiring --------------------------------------------------
#
# The guards above are only reached if the workflow actually delegates. Pinned
# here because the failure is invisible in this file otherwise: a close path that
# went back to deleting the ref itself would leave every case above passing.
test_the_workflow_close_path_delegates_to_this_sweep() {
  local body; body="$(cat "$HERE/../.github/workflows/preflight-cleanup.yml" 2>/dev/null)"
  assert_contains "the close leg narrows this sweep to the PR's ref" "$body" \
    'bash scripts/sweep-preflight-refs.sh --apply --branch "$HEAD_REF"'
  assert_missing "and deletes nothing itself" "$body" "git push origin --delete"
  # The branch name arrives through `env:`, never interpolated into a `run:`
  # body, and both legs need a token for `gh pr list`.
  assert_contains "the branch name comes from the environment" "$body" \
    'HEAD_REF: ${{ github.event.pull_request.head.ref }}'
  assert_missing "never interpolated into the script" "$body" 'preflight/${{'
  assert_eq "both legs carry a token" "2" "$(grep -c 'GH_TOKEN:' \
    "$HERE/../.github/workflows/preflight-cleanup.yml")"
  # Forks have no preflight ref here and a read-only token, so the leg is skipped.
  assert_contains "the fork gate is intact" "$body" \
    "github.event.pull_request.head.repo.full_name == github.repository"
}

test_an_unknown_argument_refuses() {
  local root; root="$(mktmpd)"
  mkfixture "$root" main preflight/orphan
  stub_gh "$root"
  run_sweep "$root" --force
  assert_contains "names the argument" "$OUT" "unknown argument: --force"
  assert_eq "refuses with 2" "2" "$RC"
  assert_eq "the ref survives" "main preflight/orphan " "$(refs_on_origin "$root")"
  rm -rf "$root"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
exit $FAIL
