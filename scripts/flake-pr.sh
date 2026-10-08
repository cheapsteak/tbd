#!/usr/bin/env bash
# scripts/flake-pr.sh — the flake PR driver's open step
# (docs/specs/2026-10-07-flake-autofix-design.md §4.4, §7, §8).
#
# Runs in the `publish` job, on ubuntu, after `fix` has ended on its own
# runner. It runs no model. Every write it makes — the push, the PR, the
# commit status, labels, issue comments, the attempt record — uses the
# tbd-flake-fixer App token in APP_TOKEN, because a PR opened or pushed with the
# default GITHUB_TOKEN starts no workflows (§7).
#
# Usage, with cwd in a checkout of this repository holding the base commit:
#   APP_TOKEN=… scripts/flake-pr.sh open --pick-dir P --attempt-dir A --repo R
#
# P is the `flakefix-pick` artifact the `fix` job uploads the moment the picker
# chooses (target.json, base_sha, started_at, run_id), so a `fix` run that
# times out or is cancelled still leaves the record of what it picked. A is the
# `flakefix-candidate` artifact; when it is missing or incomplete the attempt
# is recorded `aborted` and nothing is pushed (§8).
#
# The outcomes it records, one attempt entry each (§4.4):
#   aborted       no candidate artifact, or one whose verification never finished
#   no-diff       the session made no commits; its notes go on the issue
#   push-refused  GitHub rejected the push; a rejection for touching
#                 .github/workflows/ (the App has no `workflows` permission) is
#                 told apart from any other in the issue comment
#   pr-opened     a draft PR, its `flakefix/stress` status, and the verdict
#
# THE BRANCH. `flakefix/issue-<N>` is one name per test. The picker only picks
# a test with no open bot PR, so an existing branch of that name is stale: left
# by a PR closed unmerged, or by a `publish` that died between the push and the
# PR. It is replaced deliberately, by a lease on the SHA it was seen at, and
# the log says so. An OPEN PR on the branch is never pushed over: if its head
# is already this candidate the run is a re-run and reuses it; otherwise the
# attempt is recorded `aborted`.
#
# Exit: 0 when the attempt is recorded (whatever its outcome), 1 when a push
# failed for a reason other than a rejection (recorded, but the run goes red),
# 2 on a malformed artifact, a missing token, or a failed GitHub call.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_CMD="${FLAKE_GH_CMD:-gh}"

BRANCH_PREFIX="flakefix/issue-"
PUSH_ERROR_LINES=15

# Once the target is known, a failure must still leave an attempt entry:
# without one the picker sees no attempt and re-picks the test on the same
# evidence, and a PR closed later has no attempt to tie its close to. So die
# records `pr-opened` when a PR exists and `aborted` otherwise, once (a failed
# record does not record again), then exits 2 so the run goes red.
ISSUE="" PR="" POST_PUSH="" RECORDING=""
die() {
  echo "flake-pr: $*" >&2
  if [[ -n "$ISSUE" && -z "$RECORDING" ]]; then
    RECORDING=1
    if [[ -n "$PR" ]]; then
      record pr-opened --pr "$PR"
    elif [[ -n "$POST_PUSH" ]]; then
      record aborted --reason "The candidate was pushed to $BRANCH_PREFIX$ISSUE, then publishing failed: $*"
    else
      record aborted --reason "Publishing failed before any push: $*"
    fi
  fi
  exit 2
}
py() { python3 "$SCRIPT_DIR/flake-pr.py" "$@"; }

# Every gh call carries the App token, read or write.
ghw() { GH_TOKEN="$APP_TOKEN" "$GH_CMD" "$@"; }

# git with the App token as an HTTP header for this one command. It goes in
# through the environment, so it is never in argv or in .git/config.
git_auth() {
  local header
  header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$APP_TOKEN" | base64 | tr -d '\n')"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" GIT_CONFIG_VALUE_0="$header" \
    git "$@"
}

# record OUTCOME [--pr N] [--reason TEXT]: the attempt entry, appended.
record() {
  local outcome="$1"; shift
  local entry; entry="$(mktemp "${TMPDIR:-/tmp}/flake-pr-entry.XXXXXX")"
  py entry --pick-dir "$PICK" --attempt-dir "$ATTEMPT" --outcome "$outcome" "$@" --out "$entry" || die "cannot build the $outcome entry"
  py record --repo "$REPO" --issue "$ISSUE" --entry "$entry" || die "cannot record the $outcome attempt on #$ISSUE"
  rm -f "$entry"
  echo "flake-pr: recorded $outcome on #$ISSUE"
}

comment() { # KIND [--pr N] [--detail F]
  local kind="$1"; shift
  local text; text="$(mktemp "${TMPDIR:-/tmp}/flake-pr-comment.XXXXXX")"
  py issue-comment --attempt-dir "$ATTEMPT" --kind "$kind" "$@" --out "$text" || die "cannot render the $kind comment"
  py comment --repo "$REPO" --issue "$ISSUE" --body "$text" || die "cannot comment on #$ISSUE"
  rm -f "$text"
}

cmd_open() {
  PICK="" ATTEMPT="" REPO=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pick-dir) PICK="${2:-}"; shift 2 ;;
      --attempt-dir) ATTEMPT="${2:-}"; shift 2 ;;
      --repo) REPO="${2:-}"; shift 2 ;;
      *) die "open: unknown argument $1" ;;
    esac
  done
  [[ -n "$PICK" && -n "$ATTEMPT" && -n "$REPO" ]] || die "open: --pick-dir, --attempt-dir and --repo are required"
  if [[ ! -f "$PICK/target.json" ]]; then
    echo "flake-pr: the fix run picked nothing; nothing to publish"
    return 0
  fi
  [[ -n "${APP_TOKEN:-}" ]] || die "refusing to write without APP_TOKEN (the tbd-flake-fixer App token)"
  export FLAKE_WRITE_TOKEN="$APP_TOKEN" GH_TOKEN="$APP_TOKEN"
  local issue; issue="$(jq -r .issue "$PICK/target.json")"
  [[ "$issue" =~ ^[0-9]+$ ]] || die "target.json names no issue"
  ISSUE="$issue"
  local branch="$BRANCH_PREFIX$ISSUE" remote="${FLAKE_PR_REMOTE:-https://github.com/$REPO.git}"
  # The run link every post carries is rebuilt from the pick, uploaded before
  # any session ran, never read from the session-reachable candidate.
  local run_id; run_id="$(cat "$PICK/run_id")"
  [[ "$run_id" =~ ^[0-9]+$ ]] || die "the pick names no fix run"
  mkdir -p "$ATTEMPT" || die "cannot create $ATTEMPT"
  printf 'https://github.com/%s/actions/runs/%s\n' "$REPO" "$run_id" > "$ATTEMPT/run_url"

  local outcome=""
  [[ -f "$ATTEMPT/outcome" ]] && outcome="$(cat "$ATTEMPT/outcome")"
  case "$outcome" in
    "")
      record aborted --reason "The fix job ended before it packaged a candidate (a timeout, a cancellation, or a failed step)."
      return 0 ;;
    aborted)
      record aborted --reason "The fix job aborted: $(head -c 2000 "$ATTEMPT/abort_reason" 2>/dev/null)"
      return 0 ;;
    no-diff)
      comment no-diff
      record no-diff
      return 0 ;;
    candidate) ;;
    *) die "unknown outcome '$outcome' in the artifact" ;;
  esac
  if [[ ! -f "$ATTEMPT/verify/verdict.json" || ! -f "$ATTEMPT/candidate.bundle" ]]; then
    record aborted --reason "The candidate's verification never finished, so there is no verdict to publish."
    return 0
  fi

  local base head
  base="$(cat "$PICK/base_sha")"; head="$(cat "$ATTEMPT/head_sha" 2>/dev/null)"
  [[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || die "base_sha or head_sha is not a commit id"
  git bundle verify -q "$ATTEMPT/candidate.bundle" >/dev/null 2>&1 || die "the bundle does not verify against this checkout (is $base here?)"
  git fetch -q "$ATTEMPT/candidate.bundle" HEAD || die "cannot fetch the bundle"
  [[ "$(git rev-parse FETCH_HEAD)" == "$head" ]] || die "the bundle's tip is not the recorded head $head"
  git merge-base --is-ancestor "$base" "$head" || die "the candidate does not descend from $base"

  # An open PR on the branch: a re-run of this publish, or not ours to touch.
  local open open_head
  open="$(ghw pr list --repo "$REPO" --head "$branch" --state open --json number,headRefOid)" || die "cannot list PRs on $branch"
  if [[ "$(jq length <<< "$open")" -gt 0 ]]; then
    open_head="$(jq -r '.[0].headRefOid' <<< "$open")"
    if [[ "$open_head" != "$head" ]]; then
      record aborted --reason "An open PR (#$(jq -r '.[0].number' <<< "$open")) already uses $branch at another commit; nothing was pushed over it."
      return 0
    fi
    PR="$(jq -r '.[0].number' <<< "$open")"; POST_PUSH=1
    echo "flake-pr: PR #$PR already carries $head (a re-run); reusing it"
  fi

  if [[ -z "$PR" ]]; then
    local seen lease err rc=0
    seen="$(git_auth ls-remote "$remote" "refs/heads/$branch" | awk '{print $1}')" || die "cannot read $branch on the remote"
    if [[ -n "$seen" ]]; then
      echo "flake-pr: replacing the stale branch $branch (at $seen), left by a PR closed unmerged or a publish that died before opening one"
    fi
    lease="refs/heads/$branch:$seen"
    err="$(mktemp "${TMPDIR:-/tmp}/flake-pr-push.XXXXXX")"
    git_auth push -q --force-with-lease="$lease" "$remote" "$head:refs/heads/$branch" 2> "$err" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      local detail; detail="$(mktemp "${TMPDIR:-/tmp}/flake-pr-detail.XXXXXX")"
      if grep -qiE 'workflows?` permission|without .?workflows.? permission' "$err" \
          || git diff --no-renames --name-only "$base" "$head" | grep -q '^\.github/workflows/'; then
        { echo "The fix appears to need a workflow change, which is a human's job: the bot's App has no workflows permission, so GitHub refuses any push that touches .github/workflows/."
          echo; head -"$PUSH_ERROR_LINES" "$err"; } > "$detail"
        comment push-refused --detail "$detail"
        record push-refused --reason "$(head -c 1500 "$detail")"
        return 0
      fi
      { echo "GitHub rejected the push for a reason other than a workflow change:"; echo; head -"$PUSH_ERROR_LINES" "$err"; } > "$detail"
      cat "$detail" >&2
      comment push-refused --detail "$detail"
      record push-refused --reason "$(head -c 1500 "$detail")"
      return 1
    fi
    POST_PUSH=1

    local commits bodyf url test
    commits="$(git log --format='%h %s' "$base..$head")"
    bodyf="$(mktemp "${TMPDIR:-/tmp}/flake-pr-body.XXXXXX")"
    py body --pick-dir "$PICK" --attempt-dir "$ATTEMPT" --repo "$REPO" --commits <(printf '%s\n' "$commits") --out "$bodyf" || die "cannot render the PR body"
    test="$(jq -r .test_id "$PICK/target.json")"
    url="$(ghw pr create --repo "$REPO" --draft --base main --head "$branch" --title "Fix flaky test: $test" --body-file "$bodyf")" || die "cannot open the draft PR"
    PR="$(printf '%s\n' "$url" | sed -n 's|.*/pull/\([0-9][0-9]*\).*|\1|p' | tail -1)"
    if [[ ! "$PR" =~ ^[0-9]+$ ]]; then
      # The PR may exist even though its URL did not parse; find it by branch,
      # so the attempt is tied to it rather than recorded as aborted.
      PR="$(ghw pr list --repo "$REPO" --head "$branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null)"
      [[ "$PR" =~ ^[0-9]+$ ]] || { PR=""; die "gh pr create printed no PR URL: $url"; }
    fi
    echo "flake-pr: opened draft PR #$PR"
  fi

  local line state description run_url
  line="$(py status --attempt-dir "$ATTEMPT")" || die "cannot compute the status"
  state="${line%%$'\t'*}"; description="${line#*$'\t'}"
  run_url="$(cat "$ATTEMPT/run_url" 2>/dev/null)"
  ghw api -X POST "repos/$REPO/statuses/$head" -f state="$state" -f context=flakefix/stress \
    -f description="$description" -f target_url="$run_url" > /dev/null || die "cannot set the status on $head"
  echo "flake-pr: flakefix/stress = $state ($description)"

  if [[ "$(jq -r .verdict "$ATTEMPT/verify/verdict.json")" != pass ]]; then
    local lines; lines="$(mktemp "${TMPDIR:-/tmp}/flake-pr-lines.XXXXXX")"
    { [[ -s "$ATTEMPT/verify/protected.txt" ]] && { echo "Protected files touched:"; cat "$ATTEMPT/verify/protected.txt"; echo; }
      head -60 "$ATTEMPT/verify/failing-lines.txt" 2>/dev/null; } > "$lines"
    comment failed --pr "$PR" --detail "$lines"
  fi
  if [[ "$(jq -r .weak "$ATTEMPT/verify/verdict.json")" == true ]]; then
    py weak-label --repo "$REPO" --pr "$PR" || die "cannot label PR #$PR"
  fi
  RECORDING=1
  record pr-opened --pr "$PR"
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    open) cmd_open "$@" ;;
    *) die "usage: $0 open --pick-dir P --attempt-dir A --repo R" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
