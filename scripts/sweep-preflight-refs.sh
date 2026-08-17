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
# two conditions rather than one:
#
#   - **An open PR names it.** Either `<branch>` or the ref's own full name has
#     one; see `has_open_pr_for_any` for why both are asked about. The lane may
#     dispatch against it again at any moment.
#   - **It is younger than `MIN_AGE_SECONDS`.** The driver pushes
#     `preflight/<branch>` for every lane, including one whose branch has no PR
#     at all, so a brand-new ref is otherwise eligible for deletion the instant
#     it exists — and this sweep could land between the push and the dispatch
#     that consumes it.
#
# Everything else in the namespace is inert and gets deleted.
#
# WHAT THE AGE GUARD MEASURES, AND WHAT IT THEREFORE CANNOT SEE. There is no
# push timestamp on a remote ref, so the age used here is the COMMIT's committer
# date. That is a sound one-way implication: a ref cannot have been pushed before
# its commit existed, so a commit younger than the grace period guarantees a ref
# younger than it. The converse does not hold — a lane re-verifying a branch it
# has not touched today pushes an old commit, and that ref is not spared. The
# residual is small and its cost is bounded: the window is push → dispatch →
# checkout (runner pickup is 3s at p90, and a ref deleted after checkout cannot
# disturb a run that already has the code), and a lane whose dispatch fails
# falls back to the local queue rather than reporting a wrong verdict.
#
# DRY RUN IS THE DEFAULT. This deletes refs on a shared remote, so it prints its
# plan and does nothing until `--apply` says otherwise.
#
# Usage:
#   scripts/sweep-preflight-refs.sh            # print the plan; delete nothing
#   scripts/sweep-preflight-refs.sh --apply    # delete the refs planned above
#
# Exit status: 0 clean, 1 something was kept or failed that should not have
# been (a `gh` query failed, an age could not be read, a delete failed), 2 the
# sweep could not run at all.

REMOTE="origin"
NAMESPACE="preflight/"

# THE GRACE PERIOD, SIZED AGAINST A RUN RATHER THAN AGAINST TIDINESS. The
# valve's worst observed end-to-end remote run is 1910s and its ceiling is
# ~2700s, so an hour clears a whole run with room to spare. Nothing is lost by
# being generous: a ref that outlives its usefulness by an hour costs one line
# in a namespace, and this sweep runs again.
MIN_AGE_SECONDS=3600

log() { printf '%s\n' "$*" >&2; }

usage() {
  log "usage: sweep-preflight-refs.sh [--apply | --dry-run]"
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
  local apply=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply)   apply=true ;;
      --dry-run) apply=false ;;
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
    refs+=("$ref")
    shas+=("${line%%$'\t'*}")
  done <<< "$heads"

  # The objects the age check needs. A ref whose object never arrives has an
  # unknown age and is kept, not guessed at; see `fetch_namespace_objects`.
  if [[ ${#refs[@]} -gt 0 ]]; then
    fetch_namespace_objects "${refs[@]}"
  fi

  # PASS TWO — decide each ref. The PR question is asked before the age one so
  # that an in-use ref is reported as such rather than as merely young.
  local i sha pr committed now age
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
