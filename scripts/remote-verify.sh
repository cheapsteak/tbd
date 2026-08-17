#!/usr/bin/env bash
# scripts/remote-verify.sh — get this commit's test verdict from CI instead of
# waiting any longer for the machine-global build slot.
#
# THE OVERFLOW PATH OF THE REMOTE VERIFICATION VALVE
# (docs/specs/2026-08-16-remote-verification-valve-design.md). A lane that has
# queued for `scripts/swift-safe`'s single build slot past a threshold has
# compiled nothing, so nothing is wasted by leaving that queue and asking
# GitHub for the same verdict. `scripts/test.sh` calls this; nothing else does.
#
# THE EXIT CONTRACT, which the caller depends on:
#   0   the remote run passed
#   1   the remote run failed, and its failing tests are already printed
#   78   refused — the caller must return to the local queue
#
# 78 is what keeps this an optimisation rather than a gate. Every refusal names
# its condition on stderr: NO SILENT FALLBACK. A quiet fall-back to a local run
# reintroduces the long stall at exactly the moment it is least visible.
#
# THE SPLIT WITH `remote_verify.py`. This front-end answers "should we, and
# against which ref"; the python driver does the run, because the dispatch
# ticket is an flock that must be held by the process that waits out the whole
# remote round trip, and macOS ships no `flock(1)` for a bash 3.2 shell to use.
# It is `exec`ed for the same reason — a subshell would return early and drop
# the ticket while its run was still burning GitHub's two-run allowance.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The remote itself is named once, in the driver: this front-end never pushes.
INERT_NAMESPACE="preflight/"
EXIT_REFUSED=78

log() { printf '%s\n' "$*" >&2; }

# THE DIRTY-TREE STOP IS SEMANTIC, NOT COSMETIC. `scripts/test.sh` runs against
# the working tree, uncommitted edits and untracked files included; GitHub can
# only test what was pushed. A green remote result on a dirty tree is a false
# statement about the code in hand — and an untracked file is the worst case,
# because a brand-new test that never left this disk would be reported as
# passing. Squash merge absorbs the cost of committing more often.
check_preconditions() {
  if ! command -v gh >/dev/null 2>&1; then
    log "remote-verify: gh is not installed, so no run can be dispatched"
    return $EXIT_REFUSED
  fi
  if ! gh auth status >/dev/null 2>&1; then
    log "remote-verify: gh is not authenticated, so no run can be dispatched"
    return $EXIT_REFUSED
  fi
  if [ -n "$(git status --porcelain)" ]; then
    log "remote-verify: the tree has uncommitted changes; a remote run would test a different commit"
    return $EXIT_REFUSED
  fi
  return 0
}

# dispatch_ref_for BRANCH -> the ref to push and dispatch.
# Status 2 means the question could not be answered and the lane must refuse.
#
# `test.yml` fires on `pull_request`, and on `push` only to main — so a branch
# with no PR is already inert and needs no separate ref. Once a PR is open a
# push to that branch fires `pull_request_target: synchronize`, which runs the
# claude-review fan-out on every iteration; GitHub minutes are free but Claude
# quota is not, and it is the only metered resource left in this loop. So that
# case gets a throwaway `preflight/<branch>` ref instead, reclaimed by
# `scripts/sweep-preflight-refs.sh`.
#
# A FAILED QUERY IS NOT "NO PR". Treating it as one would push the PR branch
# and spend the quota this branch exists to protect, which is the expensive
# direction to be wrong in.
dispatch_ref_for() {
  local branch="$1" open status=0
  open="$(gh pr list --head "$branch" --state open --json number --jq '.[].number' 2>&1)" || status=$?
  if [ $status -ne 0 ]; then
    log "remote-verify: gh pr list failed for $branch (exit $status): $open"
    return 2
  fi
  if [ -z "${open//[[:space:]]/}" ]; then
    printf '%s\n' "$branch"
  else
    printf '%s%s\n' "$INERT_NAMESPACE" "$branch"
  fi
}

main() {
  local repo_dir branch sha ref status=0

  repo_dir="$(git rev-parse --show-toplevel 2>/dev/null)" || status=$?
  if [ $status -ne 0 ] || [ -z "$repo_dir" ]; then
    log "remote-verify: not inside a git repository"
    return $EXIT_REFUSED
  fi

  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch=""
  if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    log "remote-verify: HEAD is detached, so there is no branch to push"
    return $EXIT_REFUSED
  fi

  check_preconditions || return $?

  status=0
  ref="$(dispatch_ref_for "$branch")" || status=$?
  if [ $status -ne 0 ] || [ -z "$ref" ]; then
    return $EXIT_REFUSED
  fi

  sha="$(git rev-parse HEAD)"

  local inert=()
  if [ "$ref" != "$branch" ]; then
    inert=(--inert)
  fi

  # `exec`: the driver holds the dispatch ticket for the whole remote run, and
  # its exit status is this script's contract verbatim.
  exec python3 "$HERE/remote_verify.py" drive \
    --repo-dir "$repo_dir" --ref "$ref" --sha "$sha" ${inert[@]+"${inert[@]}"}
}

# --- entrypoint (strict mode only when executed, not when sourced) -----------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
