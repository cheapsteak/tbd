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
# A `preflight/<branch>` ref is KEPT when `<branch>` still has an open PR — the
# lane may dispatch against it again at any moment. Everything else in the
# namespace is inert and gets deleted.
#
# DRY RUN IS THE DEFAULT. This deletes refs on a shared remote, so it prints its
# plan and does nothing until `--apply` says otherwise.
#
# Usage:
#   scripts/sweep-preflight-refs.sh            # print the plan; delete nothing
#   scripts/sweep-preflight-refs.sh --apply    # delete the refs planned above
#
# Exit status: 0 clean, 1 something was kept or failed that should not have
# been (a `gh` query failed, a delete failed), 2 the sweep could not run at all.

REMOTE="origin"
NAMESPACE="preflight/"

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
has_open_pr() {
  local out status=0
  out="$(gh pr list --head "$1" --state open --json number --jq '.[].number' 2>&1)" || status=$?
  if [[ $status -ne 0 ]]; then
    log "gh pr list failed for $1 (exit $status): $out"
    return 2
  fi
  [[ -n "${out//[[:space:]]/}" ]]
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

  local line ref branch pr problems=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ref="${line#*$'\t'}"                       # "<sha>\trefs/heads/<name>"
    branch="$(preflight_branch_of "$ref")"
    if [[ -z "$branch" ]]; then
      echo "SKIP outside-namespace $ref"
      continue
    fi
    pr=0
    has_open_pr "$branch" || pr=$?
    if [[ $pr -eq 0 ]]; then
      echo "KEEP open-pr $NAMESPACE$branch"
      continue
    fi
    if [[ $pr -eq 2 ]]; then
      echo "KEEP unknown-pr-state $NAMESPACE$branch"
      problems=1
      continue
    fi
    echo "PLAN delete $NAMESPACE$branch"
    if [[ "$apply" == "true" ]]; then
      if git push "$REMOTE" --delete "refs/heads/$NAMESPACE$branch" >/dev/null 2>&1; then
        log "deleted $NAMESPACE$branch"
      else
        log "delete failed: $NAMESPACE$branch"
        problems=1
      fi
    fi
  done <<< "$heads"

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
