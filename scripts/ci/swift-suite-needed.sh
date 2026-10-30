#!/usr/bin/env bash
#
# Decide whether the Swift suite — the `test` job in `.github/workflows/test.yml`
# — can say anything about this run's changes.
#
#   scripts/ci/swift-suite-needed.sh
#       Reads EVENT_NAME and BASE_REF from the environment and appends
#       `run=true` or `run=false` to $GITHUB_OUTPUT (stdout when it is unset),
#       plus a per-file account to $GITHUB_STEP_SUMMARY (stderr when unset).
#       Exits 0 with an answer, or non-zero with none.
#
#   scripts/ci/swift-suite-needed.sh --classify
#       Judges the paths on stdin — NUL-separated if the input holds a NUL,
#       newline-separated otherwise — and answers the same way, without git.
#       This is the seam the harness drives, and how the rule is replayed
#       against merged PRs' file lists.
#
#   scripts/ci/swift-suite-needed.sh --list-suite-scripts
#       Prints the suite's own scripts, one path or `case` pattern per line:
#       the list the drift check in `swift-suite-needed.test.sh` holds the
#       suite's real references against.
#
# Design: docs/specs/2026-10-25-skip-swift-suite-for-non-code-prs-design.md.
#
# ---------------------------------------------------------------------------
# WHAT IT IS FOR
#
# The `test` job spends 10 to 13 minutes of a `macos-26` runner on every pull
# request, and GitHub allows five concurrent macOS jobs account-wide, so a PR
# that changes only a spec or a skill also delays every other PR waiting for a
# slot. The workflow's `changes` job runs this script on Linux, and `test` is
# skipped when it answers `run=false`. A job skipped by its own `if:` reports
# success to branch protection, so the required `test` check still passes.
#
# ---------------------------------------------------------------------------
# FAIL CLOSED
#
# Only an explicit `false` skips the suite, and `run=` is written exactly once,
# as the last thing the script does. A run that dies anywhere before that line
# leaves the output empty, which the workflow reads as "run the suite". Every
# question this script cannot answer honestly is answered `run=true` out loud:
#
#   - any event but `pull_request` — a push to main always gets a full run, and
#     a `workflow_dispatch`, the remote verification valve's among them, always
#     asks for the whole suite; no diff is read;
#   - a base ref that does not resolve;
#   - a `git diff` that fails;
#   - an empty diff, which cannot be told apart from one the script failed to
#     read;
#   - a step summary that cannot be written, so a skip never happens without
#     the record of why.
#
# ---------------------------------------------------------------------------
# THE RULE
#
# The changed files are `git diff --name-only --no-renames origin/<base>...HEAD`.
# Three-dot, so the list is what the PR changed since it forked rather than
# everything that has landed on the base since. `--no-renames`, so a rename
# lists its old path as well as its new one and each is judged on its own:
# with rename detection on, `--name-only` prints only the new path, and a file
# moved OUT of `Sources/` into `docs/` would read as a docs-only change.
#
# The suite is skipped only when that list is non-empty and every path on it
# matches a skip rule in `judge` below. The rules name what is safe to skip,
# never what is risky, so a path nobody thought about runs the suite.
set -uo pipefail

# The suite's own scripts: everything under `scripts/` that the `test` job runs,
# loads, or reads, directly or through `scripts/test.sh` and `scripts/swift-safe`.
# A change to any of these runs the suite; any other script under `scripts/`
# can skip it.
#
#   - `scripts/test.sh`, `scripts/swift-safe` and everything under `scripts/ci/`
#     run the suite;
#   - `dsym-prune-lib.sh`, `tbd-home-fingerprint.sh` and `remote-verify.sh` are
#     what `test.sh` loads or runs;
#   - `repair-spm-workspace.sh` is run by the `test` job itself;
#   - `restart.sh` is read by `DaemonBuildSkewTests`, the libraries are what it
#     loads, and `swift-safe` names `restart-build-lib.sh`.
#
# Entries are `case` patterns, in which `*` also matches `/`. The drift check in
# `scripts/ci/swift-suite-needed.test.sh`, run by the Lint job, gathers every
# script the suite can reach and fails when one of them is missing here — so a
# PR that makes the suite depend on a new script cannot land without adding it.
SUITE_SCRIPTS=(
  'scripts/test.sh'
  'scripts/swift-safe'
  'scripts/ci/*'
  'scripts/dsym-prune-lib.sh'
  'scripts/tbd-home-fingerprint.sh'
  'scripts/remote-verify.sh'
  'scripts/repair-spm-workspace.sh'
  'scripts/restart.sh'
  'scripts/restart-*-lib.sh'
)

usage() {
  echo "usage: $(basename "$0") [--classify | --list-suite-scripts]" >&2
  exit 64
}

WORK=""
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() {
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

# Sets SUITE_PATTERN to the entry that names PATH and succeeds, or fails.
is_suite_script() {
  local pattern
  for pattern in "${SUITE_SCRIPTS[@]}"; do
    # Unquoted on purpose: each entry is a `case` pattern, not a literal.
    # shellcheck disable=SC2254
    case "$1" in
      $pattern) SUITE_PATTERN="$pattern"; return 0 ;;
    esac
  done
  return 1
}

# Judges one changed path. Sets VERDICT to `skip` or `run` and REASON to the
# rule that decided it. A path skips when ANY rule matches it, each rule with
# its own exceptions; a path no rule matches runs the suite.
judge() {
  local p="$1"
  VERDICT=skip
  case "$p" in
    docs/*) REASON='docs/**'; return ;;
  esac
  case "$p" in
    # Markdown inside a target tree can be a bundled resource:
    # `Sources/TBDApp/Resources/markdown-stylesheets.md` ships in the app.
    Sources/*|Tests/*) ;;
    *.md) REASON='*.md outside Sources/ and Tests/'; return ;;
  esac
  case "$p" in
    .claude/*)
      REASON='.claude/**'; return ;;
    .github/workflows/test.yml)
      VERDICT=run; REASON='the workflow that runs the suite'; return ;;
    .github/*)
      REASON='.github/** except .github/workflows/test.yml'; return ;;
    # The daemon ships the copy embedded in
    # `Sources/TBDShared/SessionModContent.swift`, and the `Session mod` job
    # checks that copy is current. Changing the copy changes `Sources/`.
    SessionMod/*)
      REASON='SessionMod/**'; return ;;
    recipe/*)
      REASON='recipe/**'; return ;;
    tools/*)
      REASON='tools/**'; return ;;
    scripts/*)
      if is_suite_script "$p"; then
        VERDICT=run; REASON="one of the suite's own scripts ($SUITE_PATTERN)"
      else
        REASON="scripts/** except the suite's own scripts"
      fi
      return ;;
    Sources/*|Tests/*)
      VERDICT=run; REASON='Swift sources, tests or their resources'; return ;;
  esac
  VERDICT=run
  REASON='no skip rule names it'
}

# Writes the answer and exits: the step summary first, then `run=`, once and
# last. Arguments: the answer, a one-line reason, and the per-file account.
answer() {
  local run="$1" reason="$2" files="${3:-}" summary
  if [ "$run" = false ]; then
    summary="### Swift suite gate: the suite is skipped"
  else
    summary="### Swift suite gate: the suite runs"
  fi
  summary="$summary

$reason"
  if [ -n "$files" ]; then
    summary="$summary

$files"
  fi

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if ! printf '%s\n' "$summary" >> "$GITHUB_STEP_SUMMARY"; then
      echo "::warning::Could not write the step summary, so the suite runs rather than skipping with no record of why." >&2
      run=true
      reason="$reason (overridden: the step summary could not be written)"
    fi
  else
    printf '%s\n' "$summary" >&2
  fi

  echo "run=$run: $reason" >&2
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'run=%s\n' "$run" >> "$GITHUB_OUTPUT" || exit 1
  else
    printf 'run=%s\n' "$run"
  fi
  exit 0
}

# Judges every path in FILE and answers. FILE is NUL-separated if it holds a
# NUL, newline-separated otherwise.
classify_file() {
  local file="$1" nuls delim path total=0 runs=0 files=""
  nuls="$(tr -cd '\000' < "$file" | wc -c)" || answer true "The list of changed files could not be read."
  nuls="$(printf '%s' "$nuls" | tr -d ' ')"
  case "$nuls" in
    ''|*[!0-9]*) answer true "The list of changed files could not be read." ;;
  esac
  if [ "$nuls" -gt 0 ]; then
    delim=''
  else
    delim=$'\n'
  fi

  # `|| [ -n "$path" ]` keeps a last entry that has no terminator. Dropping it
  # could drop the one path that runs the suite.
  while IFS= read -r -d "$delim" path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    total=$((total + 1))
    judge "$path"
    if [ "$VERDICT" = skip ]; then
      files="$files- skip – \`$path\` – $REASON
"
    else
      runs=$((runs + 1))
      files="$files- runs the suite – \`$path\` – $REASON
"
    fi
  done < "$file"

  if [ "$total" -eq 0 ]; then
    answer true "The diff is empty, which cannot be told apart from a diff that failed to read, so the suite runs."
  fi
  if [ "$runs" -gt 0 ]; then
    answer true "$runs of $total changed files can affect the suite." "$files"
  fi
  answer false "None of the $total changed files can affect the suite, so the \`test\` job is skipped." "$files"
}

new_work_dir() {
  WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/swift-suite-needed.XXXXXX")" || WORK=""
  [ -n "$WORK" ] && [ -d "$WORK" ]
}

case "${1:-}" in
  --list-suite-scripts)
    [ "$#" -eq 1 ] || usage
    printf '%s\n' "${SUITE_SCRIPTS[@]}"
    exit 0 ;;
  --classify)
    [ "$#" -eq 1 ] || usage
    new_work_dir || answer true "Could not make a scratch directory to read the paths into."
    cat > "$WORK/paths" || answer true "Could not read the paths on stdin."
    classify_file "$WORK/paths" ;;
  '')
    [ "$#" -eq 0 ] || usage ;;
  *)
    usage ;;
esac

event="${EVENT_NAME:-}"
if [ "$event" != pull_request ]; then
  answer true "A \`${event:-unnamed}\` run always runs the whole suite; no diff was read."
fi

base="${BASE_REF:-}"
if [ -z "$base" ] || ! git rev-parse --verify --quiet "origin/$base" >/dev/null 2>&1; then
  echo "::warning::origin/${base:-<empty BASE_REF>} does not resolve, so this run cannot tell what it changed; the suite runs." >&2
  answer true "\`origin/${base:-<empty BASE_REF>}\` does not resolve, so the suite runs."
fi

new_work_dir || answer true "Could not make a scratch directory for the diff."
if ! git diff -z --name-only --no-renames "origin/$base...HEAD" > "$WORK/paths"; then
  echo "::warning::git diff against origin/$base failed; the suite runs." >&2
  answer true "\`git diff\` against \`origin/$base\` failed, so the suite runs."
fi
classify_file "$WORK/paths"
