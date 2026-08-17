#!/usr/bin/env bash
# Tests for scripts/sweep-preflight-refs.sh — run: bash scripts/sweep-preflight-refs.test.sh
#
# NOTHING HERE TOUCHES A REAL REMOTE. Each case builds a throwaway bare repo in
# a temp dir and points a throwaway clone's `origin` at it, so the sweep runs
# its real `git ls-remote` / `git push --delete` against a fixture. `gh` is a
# stub on PATH; the real one is never reached, authenticated or not.
#
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F`/"$t" below
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

mkfixture() {
  local root="$1"; shift
  git init -q --bare "$root/origin.git"
  git init -q "$root/work"
  : > "$root/work/seed"
  "${GIT_FIXTURE[@]}" -C "$root/work" add seed
  "${GIT_FIXTURE[@]}" -C "$root/work" commit -q -m "seed"
  git -C "$root/work" remote add origin "$root/origin.git"
  local branch
  for branch in "$@"; do
    git -C "$root/work" push -q origin "HEAD:refs/heads/$branch"
  done
}

# stub_gh ROOT [OPEN_PR_BRANCHES] — a `gh` on PATH that reports an open PR for
# each space-separated branch named, and none for anything else. With
# STUB_GH_FAIL=1 in the environment it fails instead, standing in for a rate
# limit or a token that lost its scope.
stub_gh() {
  local root="$1" open="${2:-}"
  mkdir -p "$root/bin"
  cat > "$root/bin/gh" <<STUB
#!/usr/bin/env bash
if [[ -n "\${STUB_GH_FAIL:-}" ]]; then echo "API rate limit exceeded" >&2; exit 1; fi
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
OUT=""
RC=0
run_sweep() {
  local root="$1"; shift
  OUT="$(cd "$root/work" && PATH="$root/bin:$PATH" bash "$SWEEP" "$@" 2>&1)"
  RC=$?
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
