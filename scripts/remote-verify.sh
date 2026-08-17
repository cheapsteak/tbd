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
# USAGE: scripts/remote-verify.sh [--narrowed]
#
# `--narrowed` says the caller selected a subset of the suite with `--filter` or
# `--skip`, so it will re-run locally rather than adopt a failing whole-suite
# verdict. It changes nothing about routing; it suppresses the `Test run with N
# tests` line on a failure, because six consumers grep that line and take the
# first match — a whole-suite count printed ahead of the local re-run's own would
# clear the very floor that exists to catch a filter matching nothing.
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
REMOTE="origin"
INERT_NAMESPACE="preflight/"
# Used only when the remote's own HEAD cannot be read; see `default_branch`.
FALLBACK_DEFAULT_BRANCH="main"
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

# dispatch_ref_for BRANCH -> the ref to push and dispatch. Always inert, never
# the branch, and deliberately answerable without asking GitHub anything.
#
# THE BRANCH ITSELF IS NEVER PUSHED, for three independent reasons:
#
#   - A PUSH IS WHAT THE PRE-PUSH HOOK IS GATING. `scripts/git-hooks/pre-push`
#     runs the suite before the commits are published; a verification path that
#     publishes them to the branch to get its verdict has bypassed the gate it
#     was running inside.
#   - THE DEFAULT BRANCH NEVER HAS AN OPEN PR. A ref choice keyed on "is there a
#     PR?" therefore fast-forwards `origin/main`, and nothing refuses it: the
#     protection on `main` was read at the time of writing and enforces against
#     neither admins nor pushers. The result is main's CI and the Pages deploy
#     firing on unreviewed commits.
#   - AN INERT REF HAS A NAMED RECONCILER AND A BRANCH DOES NOT.
#     `scripts/sweep-preflight-refs.sh` matches `refs/heads/preflight/` and
#     nothing else, so a branch pushed from here would be a durable resource
#     nobody reclaims.
#
# A push to a branch with an open PR would also fire `pull_request_target:
# synchronize` and run the claude-review fan-out on every iteration; GitHub
# minutes are free but Claude quota is not, and it is the only metered resource
# left in this loop. One namespace covers every one of those cases, so this
# needs no `gh pr list` and cannot be wrong about the answer.
dispatch_ref_for() {
  printf '%s%s\n' "$INERT_NAMESPACE" "$1"
}

# default_branch -> the branch this repository treats as its trunk.
#
# Read from the remote's own HEAD, which is what `git remote set-head` records,
# and falling back to a name rather than to "no protected branch": a repository
# whose `origin/HEAD` was never fetched is the common case on a fresh clone, and
# the fallback must fail towards refusing rather than towards verifying trunk.
default_branch() {
  local head=""
  head="$(git symbolic-ref --quiet --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null)" || head=""
  if [ -n "$head" ]; then
    printf '%s\n' "${head#"$REMOTE/"}"
    return 0
  fi
  printf '%s\n' "$FALLBACK_DEFAULT_BRANCH"
}

main() {
  local repo_dir branch sha ref status=0
  # AN UNRECOGNISED ARGUMENT REFUSES RATHER THAN BEING IGNORED. The caller passes
  # `--narrowed` to change how its verdict may be read, so a flag this front-end
  # silently dropped — a rename, a typo — would hand back a verdict the caller
  # then reads under the wrong rule. 78 is free; a misread verdict is not.
  local -a narrowing=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --narrowed) narrowing=(--narrowed) ;;
      *)
        log "remote-verify: unknown argument '$1'; refusing rather than guessing"
        return $EXIT_REFUSED
        ;;
    esac
    shift
  done

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

  # DEFENCE IN DEPTH, and the only guard here that is deliberately redundant.
  # `dispatch_ref_for` already answers `preflight/<branch>` for every branch, so
  # trunk is safe by construction — but the cost of that construction ever
  # regressing is a push to `origin/main` that fires main's CI and the Pages
  # deploy, which is worth a second, independent stop.
  local trunk; trunk="$(default_branch)"
  if [ "$branch" = "$trunk" ]; then
    log "remote-verify: refusing to verify $branch, the default branch; commit to a lane branch instead"
    return $EXIT_REFUSED
  fi

  check_preconditions || return $?

  status=0
  ref="$(dispatch_ref_for "$branch")" || status=$?
  if [ $status -ne 0 ] || [ -z "$ref" ]; then
    return $EXIT_REFUSED
  fi

  sha="$(git rev-parse HEAD)"

  # `exec`: the driver holds the dispatch ticket for the whole remote run, and
  # its exit status is this script's contract verbatim.
  exec python3 "$HERE/remote_verify.py" drive \
    --repo-dir "$repo_dir" --ref "$ref" --sha "$sha" \
    ${narrowing[@]+"${narrowing[@]}"}
}

# --- entrypoint (strict mode only when executed, not when sourced) -----------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
