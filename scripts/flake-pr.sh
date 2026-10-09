#!/usr/bin/env bash
# scripts/flake-pr.sh — the flake PR driver: its open step and its promote step
# (docs/specs/2026-10-07-flake-autofix-design.md §4.4, §7, §8).
#
# `open` runs in the `publish` job, on ubuntu, after `fix` has ended on its own
# runner. `promote` (below `open`) runs in the `promote` job when the PR's own
# `test.yml` run completes or the bot sets its `flakefix/stress` status.
# Neither runs a model. Every write it makes — the push, the PR, the commit
# status, labels, issue comments, the attempt record — uses the
# tbd-flake-fixer App token in APP_TOKEN, because a PR opened, pushed or given
# a status with the default GITHUB_TOKEN starts no workflows (§7). The status
# `open` sets with the App token is what starts the status-triggered promote.
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
#   aborted       no candidate artifact, or one whose verification never
#                 finished; marked session_failed when a fixer session failed
#                 and left no commit (the artifact's abort_kind); marked
#                 publish_raced when `main` moved during the run and the
#                 candidate could not be replayed onto it (below)
#   no-diff       the session made no commits; its notes go on the issue
#   push-refused  GitHub rejected the push; a rejection of a candidate that
#                 changes .github/workflows/ (the App has no `workflows`
#                 permission) is told apart from any other in the issue
#                 comment
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
# REPLAY AT PUBLISH (§7, §8). GitHub refuses the App's push of any branch whose
# .github/workflows/ files differ from `main`'s, even when the branch's own
# commits never touch them: a candidate built on a `main` that has since
# changed a workflow reads to GitHub as a workflow edit. So before pushing, a
# candidate whose tree leaves the base's workflow files as they were (judged
# on the tree, as GitHub judges the push) is checked against `main` as it is
# now; if `main`'s workflow files moved since the run's base, its
# commits are replayed onto the new `main` (cherry-pick -x, author and
# committer kept) and that is what is pushed, given the stress status, and
# promoted. A replay that conflicts pushes nothing and records `aborted`,
# marked publish_raced. A workflow refusal of a candidate that touches no
# workflow file means `main` moved again after the check: the replay and push
# are retried once, and a second refusal records `aborted`, publish_raced,
# and goes red.
#
# Exit: 0 when the attempt is recorded (whatever its outcome), 1 when a push
# was refused for any reason but the candidate's own workflow change, or as a
# workflow change twice for a candidate that makes none (recorded, but the run
# goes red), 2 on a malformed artifact, a missing token, or a failed GitHub
# call.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_CMD="${FLAKE_GH_CMD:-gh}"

BRANCH_PREFIX="flakefix/issue-"
WORKFLOWS_DIR=".github/workflows/"
PUSH_ERROR_LINES=15
# GitHub's refusal of a push that creates or updates a workflow file without
# the permission: "refusing to allow a GitHub App to create or update workflow
# `<path>` without `workflows` permission" (an OAuth App's or a personal token's
# ends "without `workflow` scope"). Matched on the shared opening, so any token
# type's wording counts. Only this text classifies a refusal as a workflow
# change; if GitHub rewords it, the refusal turns the run red with the generic
# explanation, which fails loud.
WORKFLOW_REFUSAL='refusing to allow .* to create or update workflow|to create or update workflow .* without .?workflows?.? (permission|scope)'

# Once the target is known, a failure must still leave an attempt entry:
# without one the picker sees no attempt and re-picks the test on the same
# evidence, and a PR closed later has no attempt to tie its close to. So die
# records `pr-opened` when a PR exists and `aborted` otherwise, once (a failed
# record does not record again), then exits 2 so the run goes red. A failure
# in the replay's own steps (RACED_DIE) says nothing about the test, so its
# abort is marked publish_raced.
ISSUE="" PR="" POST_PUSH="" RECORDING="" REUSED="" RACED_DIE="" NEW_BASE=""
die() {
  echo "flake-pr: $*" >&2
  if [[ -n "$ISSUE" && -z "$RECORDING" ]]; then
    RECORDING=1
    if [[ -n "$PR" ]]; then
      record_opened
    elif [[ -n "$POST_PUSH" ]]; then
      record aborted --reason "The candidate was pushed to $BRANCH_PREFIX$ISSUE, then publishing failed: $*"
    elif [[ -n "$RACED_DIE" ]]; then
      record aborted --publish-raced --reason "Publishing failed before any push, while checking main or replaying onto it: $*"
    else
      record aborted --reason "Publishing failed before any push: $*"
    fi
  fi
  exit 2
}

# record_opened: the pr-opened entry, noting a replay when there was one.
record_opened() {
  if [[ -n "$NEW_BASE" ]]; then
    record pr-opened --pr "$PR" --reason "Stress-checked on ${base:0:12}; replayed onto main ${NEW_BASE:0:12} as ${PUSHED:0:12} because main's workflow files changed during the run."
  else
    record pr-opened --pr "$PR"
  fi
}
py() { python3 "$SCRIPT_DIR/flake-pr.py" "$@"; }

# Every gh call in `open` carries the App token, read or write. `promote`
# reads with the job token and writes through this.
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

# fetch_main: the remote's `main` as it is now, into MAIN_NOW.
fetch_main() {
  RACED_DIE=1
  git_auth fetch -q "$remote" refs/heads/main || die "cannot fetch main"
  MAIN_NOW="$(git rev-parse FETCH_HEAD)" || die "cannot read the fetched main"
  RACED_DIE=""
}

# workflows_moved: whether `main` now holds other .github/workflows/ files than
# the run's base did.
workflows_moved() {
  local rc=0
  git diff --quiet "$base" "$MAIN_NOW" -- "$WORKFLOWS_DIR" || rc=$?
  [[ "$rc" -le 1 ]] || { RACED_DIE=1; die "cannot compare main's workflow files with $base"; }
  [[ "$rc" -eq 1 ]]
}

# sync_to_main: fetch `main`; when its workflow files moved from the base,
# replay the candidate onto it, and otherwise push the candidate itself. Sets
# PUSHED and NEW_BASE; returns 1, with REPLAY_ERROR, when the replay does not
# apply.
sync_to_main() {
  fetch_main
  if workflows_moved; then
    replay_onto "$MAIN_NOW" || return 1
    echo "flake-pr: main's workflow files changed during the run; replayed the candidate onto ${MAIN_NOW:0:12} as $PUSHED"
  else
    PUSHED="$head" NEW_BASE=""
  fi
}

# replay_onto ONTO: the candidate's commits, base..head, cherry-picked in order
# onto ONTO in a throwaway worktree, each keeping its author and committer and
# gaining git's "(cherry picked from commit …)" line. Sets PUSHED to the new
# tip and NEW_BASE to ONTO; returns 1, with git's reason in REPLAY_ERROR, when
# a commit does not apply.
replay_onto() {
  local onto="$1" wt c rc=0 out list cn ce cd
  RACED_DIE=1
  list="$(git rev-list --reverse "$base..$head")" || die "cannot list the candidate's commits"
  [[ -n "$list" && "$(wc -l <<< "$list" | tr -d ' ')" == "$commits_n" ]] \
    || die "the candidate's commit list does not match its count ($commits_n)"
  wt="$(mktemp -d "${TMPDIR:-/tmp}/flake-pr-replay.XXXXXX")" || die "cannot create a replay directory"
  git worktree add -q --detach "$wt" "$onto" 2>/dev/null || die "cannot check out $onto to replay onto"
  out="$(mktemp "${TMPDIR:-/tmp}/flake-pr-replay-out.XXXXXX")" || die "cannot create a replay log"
  RACED_DIE=""
  REPLAY_ERROR=""
  for c in $list; do
    IFS=$'\t' read -r cn ce cd < <(git log -1 --format='%cn%x09%ce%x09%cI' "$c")
    if ! GIT_COMMITTER_NAME="$cn" GIT_COMMITTER_EMAIL="$ce" GIT_COMMITTER_DATE="$cd" \
        git -C "$wt" cherry-pick -x --allow-empty --keep-redundant-commits "$c" > "$out" 2>&1; then
      REPLAY_ERROR="$(git log -1 --format='%h %s' "$c"): $(head -"$PUSH_ERROR_LINES" "$out")"
      rc=1
      git -C "$wt" cherry-pick --abort > /dev/null 2>&1
      break
    fi
  done
  [[ "$rc" -eq 0 ]] && PUSHED="$(git -C "$wt" rev-parse HEAD)" && NEW_BASE="$onto"
  git worktree remove --force "$wt" > /dev/null 2>&1 || rm -rf "$wt"
  git worktree prune > /dev/null 2>&1
  rm -f "$out"
  return "$rc"
}

# is_replay_of_head SHA: whether SHA, an open PR's head, is exactly this
# candidate as an earlier run of this publish replayed it. The tip naming head
# as its origin finds the base it was replayed onto; the replay is then redone
# there, and only the identical commit counts (a replay keeps each commit's
# author, committer and dates, so it is reproducible), so a head anyone
# amended is someone else's. Sets PUSHED and NEW_BASE when it is.
is_replay_of_head() {
  local sha="$1" tip onto
  # A branch not at SHA is not this PR's head as listed; one that is must be
  # fetchable, so a failure from here on is a publishing failure.
  tip="$(git_auth ls-remote "$remote" "refs/heads/$branch" | awk '{print $1}')" \
    || { RACED_DIE=1; die "cannot read $branch on the remote"; }
  [[ "$tip" == "$sha" ]] || return 1
  git_auth fetch -q "$remote" "refs/heads/$branch" || { RACED_DIE=1; die "cannot fetch $branch"; }
  [[ "$(git rev-parse FETCH_HEAD)" == "$sha" ]] || return 1
  git log -1 --format=%B "$sha" | grep -qxF "(cherry picked from commit $head)" || return 1
  onto="$(git rev-parse -q --verify "$sha~$commits_n^{commit}")" || return 1
  if replay_onto "$onto" && [[ "$PUSHED" == "$sha" ]]; then
    return 0
  fi
  PUSHED="$head" NEW_BASE=""
  return 1
}

# raced REASON: the candidate was lost to `main` moving; record it so the
# picker may try the test again at once (§5).
raced() {
  record aborted --publish-raced --reason "$1"
}

# push_branch: push PUSHED to the branch under the lease; GitHub's answer in err.
push_branch() {
  git_auth push -q --force-with-lease="$lease" "$remote" "$PUSHED:refs/heads/$branch" 2> "$err"
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
      # A session that failed without a commit tried nothing; the picker
      # does not wait for a new failure after it (§5).
      local kind=()
      [[ "$(cat "$ATTEMPT/abort_kind" 2>/dev/null)" == session ]] && kind=(--session-failed)
      record aborted --reason "The fix job aborted: $(head -c 2000 "$ATTEMPT/abort_reason" 2>/dev/null)" ${kind[@]+"${kind[@]}"}
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

  # What is pushed, given the status, and promoted: the candidate itself, or
  # its replay onto a newer `main` (PUSHED, on NEW_BASE).
  PUSHED="$head" NEW_BASE="" MAIN_NOW="" REPLAY_ERROR=""
  # Whether the candidate's tree differs from its base under .github/workflows/:
  # what GitHub judges is the tree pushed, not how the commits got there.
  local touches_workflows="" commits_n wrc=0
  git diff --quiet "$base" "$head" -- "$WORKFLOWS_DIR" || wrc=$?
  [[ "$wrc" -le 1 ]] || die "cannot compare the candidate's workflow files with $base"
  [[ "$wrc" -eq 1 ]] && touches_workflows=1
  commits_n="$(git rev-list --count "$base..$head")" || die "cannot count the candidate's commits"

  # An open PR on the branch: a re-run of this publish, or not ours to touch.
  local open open_head
  open="$(ghw pr list --repo "$REPO" --head "$branch" --state open --json number,headRefOid)" || die "cannot list PRs on $branch"
  if [[ "$(jq length <<< "$open")" -gt 0 ]]; then
    open_head="$(jq -r '.[0].headRefOid' <<< "$open")"
    if [[ "$open_head" != "$head" ]] && ! is_replay_of_head "$open_head"; then
      record aborted --reason "An open PR (#$(jq -r '.[0].number' <<< "$open")) already uses $branch at another commit; nothing was pushed over it."
      return 0
    fi
    PR="$(jq -r '.[0].number' <<< "$open")"; POST_PUSH=1; REUSED=1
    echo "flake-pr: PR #$PR already carries $open_head (a re-run); reusing it"
  fi

  local replayed=()
  if [[ -z "$PR" ]]; then
    local seen lease err rc=0
    seen="$(git_auth ls-remote "$remote" "refs/heads/$branch" | awk '{print $1}')" || die "cannot read $branch on the remote"
    if [[ -n "$seen" ]]; then
      echo "flake-pr: replacing the stale branch $branch (at $seen), left by a PR closed unmerged or a publish that died before opening one"
    fi
    lease="refs/heads/$branch:$seen"
    err="$(mktemp "${TMPDIR:-/tmp}/flake-pr-push.XXXXXX")"
    # A candidate built on a `main` whose workflow files have since changed
    # is replayed onto `main` as it is now, or GitHub refuses it as a
    # workflow edit. One that touches workflow files itself is pushed as it
    # is: no replay makes that push acceptable.
    local lost="main's workflow files changed during the run, so the candidate had to be replayed onto main, and the replay did not apply; nothing was pushed."
    if [[ -z "$touches_workflows" ]] && ! sync_to_main; then
      raced "$lost (${base:0:12} to ${MAIN_NOW:0:12}) $REPLAY_ERROR"
      return 0
    fi
    push_branch || rc=$?
    # A workflow refusal of a candidate that touches no workflow file: `main`
    # moved again between the fetch and the push. Replay onto it, when its
    # workflow files moved, and push once more; a second refusal is recorded
    # `aborted` and goes red.
    if [[ "$rc" -ne 0 && -z "$touches_workflows" ]] && grep -qiE "$WORKFLOW_REFUSAL" "$err"; then
      echo "flake-pr: GitHub refused the push as a workflow change though the candidate touches no workflow file; checking main again"
      if ! sync_to_main; then
        raced "GitHub refused the push as a workflow change though the candidate changes no workflow file; $lost (${base:0:12} to ${MAIN_NOW:0:12}) $REPLAY_ERROR"
        return 0
      fi
      rc=0
      push_branch || rc=$?
      if [[ "$rc" -ne 0 ]] && grep -qiE "$WORKFLOW_REFUSAL" "$err"; then
        local why; why="$(head -"$PUSH_ERROR_LINES" "$err")"
        echo "flake-pr: GitHub refused the replayed push as a workflow change too: $why" >&2
        raced "GitHub refused the push as a workflow change twice, though the candidate touches no workflow file and main (${MAIN_NOW:0:12}) was checked again before the second push; nothing was pushed. GitHub said: $why"
        return 1
      fi
    fi
    if [[ "$rc" -ne 0 ]]; then
      local detail; detail="$(mktemp "${TMPDIR:-/tmp}/flake-pr-detail.XXXXXX")"
      # Classified on GitHub's refusal text alone: a candidate that touches
      # .github/workflows/ can still be refused for another reason (a lease
      # that went stale, a protection rule), and that must turn the run red.
      # A candidate that touches none never gets here with that text: its
      # refusal was retried above.
      if grep -qiE "$WORKFLOW_REFUSAL" "$err"; then
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
  fi
  # NEW_BASE is final here, on either path.
  [[ -n "$NEW_BASE" ]] && replayed=(--replayed "$base" "$NEW_BASE")
  if [[ -z "$PR" ]]; then
    local commits bodyf url test
    commits="$(git log --format='%h %s' "${NEW_BASE:-$base}..$PUSHED")"
    bodyf="$(mktemp "${TMPDIR:-/tmp}/flake-pr-body.XXXXXX")"
    py body --pick-dir "$PICK" --attempt-dir "$ATTEMPT" --repo "$REPO" --commits <(printf '%s\n' "$commits") \
      ${replayed[@]+"${replayed[@]}"} --out "$bodyf" || die "cannot render the PR body"
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

  # §6.4, §7: a candidate that renamed or retired its target stays a draft for
  # a human; the label is what promote refuses on. Before the status, so no
  # status can reach promote ahead of it.
  local change
  change="$(jq -r '.target_change.kind // "none"' "$ATTEMPT/verify/verdict.json")" || die "cannot read the verdict"
  if [[ "$change" == renamed || "$change" == retired ]]; then
    py label --repo "$REPO" --pr "$PR" --which needs-human || die "cannot label PR #$PR"
  fi

  # The verdict was measured on the candidate; the status goes on what was
  # pushed, which promote then requires to be the PR's head (§7).
  local line state description run_url
  line="$(py status --attempt-dir "$ATTEMPT" ${replayed[@]+"${replayed[@]}"})" || die "cannot compute the status"
  state="${line%%$'\t'*}"; description="${line#*$'\t'}"
  run_url="$(cat "$ATTEMPT/run_url" 2>/dev/null)"
  ghw api -X POST "repos/$REPO/statuses/$PUSHED" -f state="$state" -f context=flakefix/stress \
    -f description="$description" -f target_url="$run_url" > /dev/null || die "cannot set the status on $PUSHED"
  echo "flake-pr: flakefix/stress = $state on $PUSHED ($description)"

  # A re-run that found its PR already open posted this comment the first time.
  if [[ "$(jq -r .verdict "$ATTEMPT/verify/verdict.json")" != pass && -z "$REUSED" ]]; then
    local lines; lines="$(mktemp "${TMPDIR:-/tmp}/flake-pr-lines.XXXXXX")"
    { [[ -s "$ATTEMPT/verify/protected.txt" ]] && { echo "Protected files touched:"; cat "$ATTEMPT/verify/protected.txt"; echo; }
      head -60 "$ATTEMPT/verify/failing-lines.txt" 2>/dev/null; } > "$lines"
    comment failed --pr "$PR" --detail "$lines"
  fi
  if [[ "$(jq -r .weak "$ATTEMPT/verify/verdict.json")" == true ]]; then
    py label --repo "$REPO" --pr "$PR" --which weak || die "cannot label PR #$PR"
  fi
  RECORDING=1
  record_opened
}

# promote: mark the draft ready once its own CI passed on the head the verifier
# passed (spec §7). Two events start it, so whichever lands last promotes:
#   --branch B --conclusion C --event E --run-id ID --run-created-at T
#                                         Test run ID on B completed (C, E)
#   --from-status                         the bot set flakefix/stress on --sha;
#                                         the PR is found from the commit
# Both are judged on the same facts. Reads with the job token in GH_TOKEN; the
# writes, the ready (and the weak label, if publish never added it), use the
# App token, because a ready_for_review raised by GITHUB_TOKEN starts no
# claude-review. It writes no ledger or attempt state (§4.4). Exit 0 promoted
# or skipped, 2 on a failed read or malformed input, which leaves the PR a
# draft.
cmd_promote() {
  local repo="" branch="" sha="" conclusion="" event="" run_id="" created="" from_status=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --branch) branch="${2:-}"; shift 2 ;;
      --sha) sha="${2:-}"; shift 2 ;;
      --conclusion) conclusion="${2:-}"; shift 2 ;;
      --event) event="${2:-}"; shift 2 ;;
      --run-id) run_id="${2:-}"; shift 2 ;;
      --run-created-at) created="${2:-}"; shift 2 ;;
      --from-status) from_status=1; shift ;;
      *) die "promote: unknown argument $1" ;;
    esac
  done
  local trigger=(--trigger test-run --conclusion "$conclusion" --event "$event" --run-id "$run_id" --run-created-at "$created")
  if [[ -n "$from_status" ]]; then
    [[ -n "$repo" && -n "$sha" && -z "$branch$conclusion$event$run_id$created" ]] \
      || die "promote --from-status: --repo and --sha are required, and no Test run's facts are taken"
    trigger=(--trigger status)
  else
    [[ -n "$repo" && -n "$branch" && -n "$sha" && -n "$conclusion" && -n "$event" && -n "$created" ]] \
      || die "promote: --repo, --branch, --sha, --conclusion, --event, --run-id and --run-created-at are required"
    [[ "$run_id" =~ ^[0-9]+$ ]] || die "promote: --run-id is not a run id"
  fi
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "promote: --sha is not a commit id"
  if [[ -n "$from_status" ]]; then
    branch="$(py promote-resolve --repo "$repo" --sha "$sha")" || die "cannot find the PR whose head is $sha"
    if [[ -z "$branch" ]]; then
      echo "flake-pr: SKIP no one open flakefix/issue-<N> PR from $repo has $sha at its head"
      return 0
    fi
  fi
  # The branch reaches a URL; nothing but the bot's own names goes further.
  if [[ ! "$branch" =~ ^flakefix/issue-[0-9]+$ ]]; then
    echo "flake-pr: SKIP $branch is not a flakefix/issue-<N> branch"
    return 0
  fi
  [[ -n "${APP_TOKEN:-}" ]] || die "refusing to promote without APP_TOKEN (the tbd-flake-fixer App token)"

  local facts files protected decision number now rc=0
  PROMOTE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/flake-pr-promote.XXXXXX")" || die "cannot create a temporary directory"
  trap 'rm -rf "$PROMOTE_WORK"' EXIT
  facts="$PROMOTE_WORK/facts.json"; files="$PROMOTE_WORK/files"; protected="$PROMOTE_WORK/protected"
  py promote-facts --repo "$repo" --branch "$branch" --sha "$sha" "${trigger[@]}" \
    --out "$facts" || die "cannot read the promotion facts"
  # Through files, not pipes: a failed listing must not read as an empty one.
  jq -j '.files[] | (.filename, (.previous_filename // empty)) | . + "\u0000"' "$facts" > "$files" \
    || die "cannot list the PR's files"
  # The verifier's own matcher, from main's checkout: 0 none, 1 some, else it failed.
  bash "$SCRIPT_DIR/flake-verify.sh" protected-in < "$files" > "$protected" || rc=$?
  [[ "$rc" -le 1 ]] || die "cannot check the PR's files against the protected list"
  jq --rawfile p "$protected" '. + {protected_touched: ($p | split("\n") | map(select(length > 0)))}' \
    "$facts" > "$facts.new" || die "cannot record the protected files"
  mv "$facts.new" "$facts" || die "cannot record the protected files"
  decision="$(py promote-decide --facts "$facts")" || die "cannot decide"
  number="$(jq -r '.prs[0].number // empty' "$facts")"
  case "$decision" in
    PROMOTE|"PROMOTE label") ;;
    SKIP*) echo "flake-pr: $decision"; return 0 ;;
    *) die "promote-decide printed [$decision]" ;;
  esac
  [[ "$number" =~ ^[0-9]+$ ]] || die "no PR number to promote"
  if [[ "$decision" == "PROMOTE label" ]]; then
    # §6.5: weak evidence cannot be missed. publish labels the PR; one that
    # died before it did gets the label here, before anyone is asked to review.
    FLAKE_WRITE_TOKEN="$APP_TOKEN" py label --repo "$repo" --pr "$number" --which weak || die "cannot label PR #$number"
  fi
  ghw pr ready "$number" --repo "$repo" || die "cannot mark PR #$number ready"
  # GitHub's ready takes no expected head, so a push that landed after the
  # facts were read would be promoted. Read the head again; if it moved, put
  # the PR back to draft and go red.
  now="$("$GH_CMD" api "repos/$repo/pulls/$number" --jq .head.sha)" || now=""
  if [[ "$now" != "$sha" ]]; then
    ghw pr ready "$number" --repo "$repo" --undo || die "PR #$number was marked ready, but its head is now ${now:-unreadable}, not $sha, and it could not be returned to draft"
    die "PR #$number's head is now ${now:-unreadable}, not the verified $sha; returned it to draft"
  fi
  echo "flake-pr: marked PR #$number ready for review"
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    open) cmd_open "$@" ;;
    promote) cmd_promote "$@" ;;
    promote-decide)
      [[ "${1:-}" == --facts && -n "${2:-}" ]] || die "usage: $0 promote-decide --facts F"
      py promote-decide --facts "$2" ;;
    *) die "usage: $0 {open --pick-dir P --attempt-dir A --repo R | promote --repo R --sha S (--branch B --conclusion C --event E --run-id ID --run-created-at T | --from-status) | promote-decide --facts F}" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
