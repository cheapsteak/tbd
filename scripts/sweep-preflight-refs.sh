#!/usr/bin/env bash
# scripts/sweep-preflight-refs.sh — reclaim inert `preflight/*` refs on origin.
#
# THE NAMED RECONCILER FOR INERT REFS. The remote verification valve
# (docs/specs/2026-08-16-remote-verification-valve-design.md) pushes
# `preflight/<branch>` when a lane needs a CI verdict on a branch that already
# has an open PR: pushing the PR branch itself would fire
# `pull_request_target: synchronize` and spend Claude quota on a review nobody
# asked for. That inert ref is a durable external resource created outside any
# transaction, so per CLAUDE.md it needs a sweep that compares ground truth
# against intent rather than a best-effort cleanup on the happy path. The close
# path in `.github/workflows/preflight-cleanup.yml` deletes a PR's ref when the
# PR closes; this sweep reclaims every ref that path missed.
#
# A `preflight/<branch>` ref is KEPT when it is still plausibly in use, which is
# three conditions rather than one:
#
#   - **An open PR names it.** Either `<branch>` or the ref's own full name has
#     one; see `has_open_pr_for_any` for why both are asked about. The lane may
#     dispatch against it again at any moment.
#   - **A workflow run is using it.** A run against `preflight/<branch>` that has
#     not reached `completed` may not have checked out the code yet, so deleting
#     the ref under it fails the run. This is asked directly rather than inferred;
#     see `has_live_run`.
#   - **It is younger than `MIN_AGE_SECONDS`.** The driver pushes
#     `preflight/<branch>` for every lane, including one whose branch has no PR
#     at all, so a brand-new ref is otherwise eligible for deletion the instant
#     it exists.
#
# Everything else in the namespace is inert and gets deleted.
#
# THE TWO GUARDS COVER DISJOINT HALVES OF ONE WINDOW, WHICH IS WHY BOTH ARE HERE.
# The exposure runs push → dispatch → checkout:
#
#   - Between the PUSH and the DISPATCH there is no run to ask about yet, so the
#     live-run query answers "none" for a ref that is about to be used. Only the
#     age guard spares it.
#   - After the DISPATCH the run exists, and the age guard is the weaker half:
#     the age it can observe is the COMMIT's committer date, since a remote ref
#     carries no push timestamp. A commit younger than the grace period does
#     imply a ref younger than it, but the converse fails, and it fails in the
#     COMMON case rather than an exotic one — an agent commits, and the run
#     needing verification happens minutes or hours later, so a ref pushed
#     seconds ago reports an age well past the grace period. The live-run query
#     is what spares that ref.
#
# HOW WIDE THAT WINDOW REALLY IS. Not seconds. Runner pickup measured at 3s at
# p90 on an idle account, but the valve fires precisely when the local machine is
# at capacity, and past roughly two concurrent runs everything queues on GitHub's
# side — five concurrent macOS jobs per account, two per `test.yml` run. The
# realistic dispatch → checkout window is minutes, which is why "the age guard
# plus a short grace period" was not a sufficient bound on its own.
#
# WHAT A DELETED-TOO-EARLY REF ACTUALLY COSTS. The run fails at
# `actions/checkout`, produces no results artifact, and the driver treats a
# missing artifact as a refusal — so the lane falls back to a local run rather
# than reporting a wrong verdict. The verdict is safe; what is wasted is a scarce
# macOS slot and a lane's whole round trip, and that is worth a query to avoid.
#
# DRY RUN IS THE DEFAULT. This deletes refs on a shared remote, so it prints its
# plan and does nothing until `--apply` says otherwise.
#
# `--branch <name>` NARROWS THE PASS TO ONE REF, AND IS WHY THE CLOSE PATH IS
# NOT ITS OWN DELETE. A PR closing reclaims its own `preflight/<branch>` through
# this script rather than with a `git push --delete` of its own, so all three
# guards above apply on both legs and live in exactly one place. They matter most
# there: in a fleet of forty worktrees "another agent merges this PR while a lane
# verifies against it" is ordinary, and an unguarded close path deletes the ref
# between the dispatch and `actions/checkout`, wasting a run that was about to
# pass. A ref this leg spares is inert soon after and the weekly pass takes it.
#
# The name only ever FILTERS. Every branch acted on is read back out of
# `git ls-remote`, so an argument that names nothing deletes nothing — which
# matters because the close path's value is a PR head branch, attacker-adjacent
# text.
#
# Usage:
#   scripts/sweep-preflight-refs.sh            # print the plan; delete nothing
#   scripts/sweep-preflight-refs.sh --apply    # delete the refs planned above
#   scripts/sweep-preflight-refs.sh --apply --branch tbd/foo   # that ref only
#
# Exit status: 0 clean, 1 something was kept or failed that should not have
# been (a `gh` query failed, an age could not be read, a delete failed), 2 the
# sweep could not run at all.

REMOTE="origin"
NAMESPACE="preflight/"

# THE GRACE PERIOD — THE SECOND LINE, AND THE ONLY ONE THAT COVERS PUSH →
# DISPATCH. `has_live_run` answers the in-use question directly once a run exists;
# before one does, this is what spares a ref. Sized against a run rather than
# against tidiness: the valve's worst observed end-to-end remote run is 1910s and
# its ceiling is ~2700s, so an hour clears a whole one with room to spare. Nothing
# is lost by being generous — a ref that outlives its usefulness by an hour costs
# one line in a namespace, and this sweep runs again.
MIN_AGE_SECONDS=3600

log() { printf '%s\n' "$*" >&2; }

usage() {
  log "usage: sweep-preflight-refs.sh [--apply | --dry-run] [--branch <name>]"
}

# preflight_branch_of REF -> the branch this preflight ref shadows, or nothing.
#
# THE NAMESPACE GUARD, and deliberately the only one. A ref becomes eligible for
# deletion here and nowhere else, so there is a single place to read when asking
# "can this sweep reach `main`?" — it cannot, because a ref that does not start
# with `refs/heads/preflight/` yields an empty branch and is skipped. Defence in
# depth would be worse here: a second redundant check makes each copy untestable
# in isolation, since weakening either one leaves the other still refusing.
preflight_branch_of() {
  case "$1" in
    refs/heads/"$NAMESPACE"?*) printf '%s\n' "${1#refs/heads/"$NAMESPACE"}" ;;
    *) return 0 ;;
  esac
}

# has_open_pr BRANCH -> 0 open PR exists, 1 none, 2 the query itself failed.
#
# The failure case is distinct on purpose. Treating a failed `gh` call as "no
# open PR" would delete every ref in the namespace the first time the API rate
# limits or the token loses its scope — a silent failure whose blast radius is
# the whole sweep.
#
# STDOUT ONLY DECIDES THE ANSWER. Folding stderr in with `2>&1` would let any
# benign `gh` message — a deprecation notice, an upgrade nag, a hint about a
# missing default remote — land in the value whose emptiness means "a PR exists".
# The verdict would still be KEEP, so nothing would break loudly; the check would
# simply be reading the wrong stream, and the first `gh` release that started
# printing a notice would quietly stop this sweep deleting anything. `gh`'s
# stderr is left to flow to ours, where an operator reads it verbatim.
has_open_pr() {
  local numbers status=0
  numbers="$(gh pr list --head "$1" --state open --json number --jq '.[].number')" || status=$?
  if [[ $status -ne 0 ]]; then
    log "gh pr list failed for $1 (exit $status); gh's own message is above"
    return 2
  fi
  [[ -n "${numbers//[[:space:]]/}" ]]
}

# has_open_pr_for_any HEAD... -> 0 any has an open PR, 1 none does, 2 a query
# failed (and no other query answered yes).
#
# BOTH THE STRIPPED NAME AND THE REF'S OWN NAME GET ASKED ABOUT, because the
# namespace is a convention rather than a reservation. Nothing stops a human from
# working on a branch actually named `preflight/flaky-repro` and opening a PR for
# it: `preflight_branch_of` hands back `flaky-repro`, `gh` finds no PR for a
# branch by that name, and the sweep deletes the branch the PR is built on —
# breaking the PR rather than reclaiming an orphan. Either name answering yes is
# enough to keep the ref, which is the safe direction: the cost of a false KEEP
# is one surviving ref, and the cost of a false delete is somebody's work.
#
# A failed query never becomes a "no" — same reasoning as `has_open_pr` — but it
# does not override a yes either, so an open PR found on the first name is
# reported even if the second query cannot be answered.
has_open_pr_for_any() {
  local head status failed=0
  for head in "$@"; do
    status=0
    has_open_pr "$head" || status=$?
    case "$status" in
      0) return 0 ;;
      2) failed=1 ;;
    esac
  done
  if [[ $failed -eq 1 ]]; then
    return 2
  fi
  return 1
}

# has_live_run REF_BRANCH -> 0 a workflow run is using this ref, 1 none is, 2 the
# query itself failed.
#
# THE QUESTION THE AGE GUARD CANNOT ANSWER, ASKED DIRECTLY. `gh run list --branch`
# reports the runs GitHub has for a ref, so "is anything using it?" needs no
# inference from a commit date at all. A ref with a live run is KEPT regardless of
# how old its commit is, which is the case the age guard gets wrong every time an
# agent verifies a commit it made an hour ago.
#
# THE FILTER IS `!= "completed"`, NOT A LIST OF THE LIVE STATUSES. The API's `status`
# is one of `queued`, `in_progress`, `waiting`, `requested`, `pending` or
# `completed`, and new spellings have been added before. Naming the live ones would
# make a status nobody here has heard of read as "not in use" — a DELETE. Negating
# the one terminal value makes every unknown read as "in use", which is a KEEP, and
# the cost of a false keep is one surviving ref for a week.
#
# STDOUT ONLY DECIDES, and a failed query is its own outcome — the same two rules
# `has_open_pr` is built on, and for the same reasons: a benign `gh` notice on
# stderr must not read as a live run, and a rate limit must not read as an idle
# ref. This one also needs `actions: read` in any workflow that calls it; without
# it every query 403s, which lands here as "unknown" and keeps every ref.
has_live_run() {
  local live status=0
  live="$(gh run list --branch "$1" --limit 50 --json status \
            --jq '.[] | select(.status != "completed") | .status')" || status=$?
  if [[ $status -ne 0 ]]; then
    log "gh run list failed for $1 (exit $status); gh's own message is above"
    return 2
  fi
  [[ -n "${live//[[:space:]]/}" ]]
}

# commit_time_of SHA -> the commit's committer time as a unix timestamp, or
# nothing at all when this clone cannot see the object. Empty is a distinct
# outcome from "old", and the caller keeps the ref rather than guessing.
# `|| true` IS LOAD-BEARING UNDER `set -e`. Without it a `git log` that cannot
# find the object exits 128, and `var="$(commit_time_of …)"` takes that as the
# assignment's own status — killing the whole sweep at the first undatable ref
# instead of keeping it and moving on.
commit_time_of() {
  git log -1 --format=%ct "$1" 2>/dev/null || true
}

# fetch_namespace_objects REF... -> best effort; the objects are what the age
# check needs, and `git log` cannot date a commit this clone has never seen.
#
# ONE FETCH, THEN ONE PER REF IF THAT FAILED, AND THE RETRY IS NOT BELT AND
# BRACES. git aborts an entire fetch on the first ref it cannot serve — one
# deleted between the listing and now, or a dangling ref written by something
# that bypassed git — so a single bad ref would leave EVERY age unknown. That is
# the safe direction for one run, but it is not safe standing: unknown age means
# KEEP, so the bad ref survives to poison the next run too, and the sweep would
# never reclaim anything again. Retrying one at a time confines the damage to the
# ref that caused it.
#
# Explicit refspecs with no destination — no wildcard, which git rejects without
# one — land in `FETCH_HEAD`, which the next fetch overwrites. No local ref is
# created, so there is nothing here for anything to reclaim.
fetch_namespace_objects() {
  local ref
  if git fetch --quiet "$REMOTE" "$@"; then
    return 0
  fi
  log "batch fetch of $NAMESPACE objects failed; retrying one ref at a time"
  for ref in "$@"; do
    if ! git fetch --quiet "$REMOTE" "$ref" 2>/dev/null; then
      log "could not fetch $ref; its age will be unknown"
    fi
  done
}

main() {
  local apply=false only_branch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply)   apply=true ;;
      --dry-run) apply=false ;;
      # A `--branch` with nothing after it must not become a whole-namespace
      # pass: the close path spells "this one ref" that way, and a caller whose
      # variable came out empty would silently ask for every ref instead.
      --branch)
        shift
        if [[ $# -eq 0 || -z "$1" ]]; then
          log "--branch requires a branch name"
          usage
          return 2
        fi
        only_branch="$1"
        ;;
      -h|--help) usage; return 0 ;;
      *) log "unknown argument: $1"; usage; return 2 ;;
    esac
    shift
  done

  if ! command -v gh >/dev/null 2>&1; then
    log "gh is not installed; refusing to sweep (every ref would look PR-less)"
    return 2
  fi

  local heads
  if ! heads="$(git ls-remote --heads "$REMOTE")"; then
    log "could not list refs on $REMOTE"
    return 2
  fi

  # PASS ONE — partition the remote's heads. The namespace guard runs here and
  # nowhere else, so `main` is reported skipped and never reaches the rest.
  local line ref branch problems=0
  local refs=() shas=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ref="${line#*$'\t'}"                       # "<sha>\trefs/heads/<name>"
    branch="$(preflight_branch_of "$ref")"
    if [[ -z "$branch" ]]; then
      echo "SKIP outside-namespace $ref"
      continue
    fi
    # The `--branch` filter, and the only thing that argument does. It cannot
    # widen what is eligible — a name matching no ref on the remote leaves this
    # loop with nothing to decide.
    if [[ -n "$only_branch" && "$branch" != "$only_branch" ]]; then
      echo "SKIP other-branch $ref"
      continue
    fi
    refs+=("$ref")
    shas+=("${line%%$'\t'*}")
  done <<< "$heads"

  # The objects the age check needs. A ref whose object never arrives has an
  # unknown age and is kept, not guessed at; see `fetch_namespace_objects`.
  if [[ ${#refs[@]} -eq 0 ]]; then
    # Said only for a named branch, where "there is nothing here" is the answer
    # to a question somebody asked. An empty namespace is not news.
    if [[ -n "$only_branch" ]]; then
      echo "no preflight ref for $only_branch; nothing to reclaim"
    fi
  else
    fetch_namespace_objects "${refs[@]}"
  fi

  # PASS TWO — decide each ref. The questions are asked in order of how directly
  # they answer "is this in use?", so a ref that is kept is reported with the
  # strongest reason that applies rather than with whichever guard fired first: an
  # open PR, then a live run, then merely being young.
  local i sha pr run committed now age
  now="$(date +%s)"
  for (( i = 0; i < ${#refs[@]}; i++ )); do
    ref="${refs[$i]}"
    sha="${shas[$i]}"
    branch="$(preflight_branch_of "$ref")"
    pr=0
    has_open_pr_for_any "$branch" "$NAMESPACE$branch" || pr=$?
    if [[ $pr -eq 0 ]]; then
      echo "KEEP open-pr $NAMESPACE$branch"
      continue
    fi
    if [[ $pr -eq 2 ]]; then
      echo "KEEP unknown-pr-state $NAMESPACE$branch"
      problems=1
      continue
    fi
    # THE REF'S OWN NAME IS THE ONE A RUN IS ATTACHED TO. The valve dispatches
    # against `preflight/<branch>`, never against `<branch>`, so this asks about
    # the full ref name rather than the stripped one `has_open_pr_for_any` also
    # tries.
    run=0
    has_live_run "$NAMESPACE$branch" || run=$?
    if [[ $run -eq 0 ]]; then
      echo "KEEP live-run $NAMESPACE$branch"
      continue
    fi
    if [[ $run -eq 2 ]]; then
      echo "KEEP unknown-run-state $NAMESPACE$branch"
      problems=1
      continue
    fi
    committed="$(commit_time_of "$sha")"
    if [[ -z "$committed" ]]; then
      echo "KEEP unknown-age $NAMESPACE$branch"
      problems=1
      continue
    fi
    age=$(( now - committed ))
    if [[ $age -lt $MIN_AGE_SECONDS ]]; then
      echo "KEEP too-young $NAMESPACE$branch (${age}s < ${MIN_AGE_SECONDS}s)"
      continue
    fi
    echo "PLAN delete $NAMESPACE$branch"
    if [[ "$apply" == "true" ]]; then
      if git push "$REMOTE" --delete "$ref" >/dev/null 2>&1; then
        log "deleted $NAMESPACE$branch"
      else
        log "delete failed: $NAMESPACE$branch"
        problems=1
      fi
    fi
  done

  if [[ "$apply" != "true" ]]; then
    log "dry run: nothing deleted. Pass --apply to delete the refs planned above."
  fi
  return $problems
}

# --- entrypoint (strict mode only when executed, not when sourced) -----------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
