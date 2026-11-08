#!/usr/bin/env bash
#
# Decide which phone parts — the `relay`, `loader` and `phone-app` jobs in
# `.github/workflows/phone.yml` — can say anything about this run's changes,
# and judge whether the `Phone checks` job may pass.
#
#   scripts/ci/phone-parts-needed.sh
#       Reads EVENT_NAME and BASE_REF from the environment and appends three
#       lines, `relay=`, `loader=` and `phone_app=`, each `true` or `false`,
#       to $GITHUB_OUTPUT (stdout when it is unset), plus a per-file account
#       to $GITHUB_STEP_SUMMARY (stderr when unset). Exits 0 with an answer,
#       or non-zero with none.
#
#   scripts/ci/phone-parts-needed.sh --classify
#       Judges the paths on stdin — NUL-separated if the input holds a NUL,
#       newline-separated otherwise — and answers the same way, without git.
#       This is the seam the harness drives, and how the rule is replayed
#       against merged PRs' file lists.
#
#   scripts/ci/phone-parts-needed.sh --list-parts
#       Prints one line per part: its job ID in `phone.yml`, a space, and the
#       gate's output key for it.
#
#   scripts/ci/phone-parts-needed.sh --verdict
#       Reads NEEDS, the `Phone checks` job's `needs` context as JSON
#       (`toJSON(needs)`), writes one line per job to $GITHUB_STEP_SUMMARY
#       (stderr when unset), and exits 0 only when `Phone checks` may pass.
#
# Any other invocation exits 64 and writes nothing. Bash 3.2 compatible, so a
# developer can replay the rule over merged PRs on a Mac.
#
# Design: docs/specs/2026-11-07-phone-control-design.md, section 15. The model
# is the Swift suite gate, scripts/ci/swift-suite-needed.sh.
#
# ---------------------------------------------------------------------------
# WHAT IT IS FOR
#
# `phone.yml` runs on every pull request, and most pull requests touch no phone
# code. The workflow's `changes` job runs this script, and each part job is
# skipped by its own `if:` when this script answers `false` for it, so such a
# PR costs one short Linux job instead of three npm installs and test runs.
#
# Branch protection requires one context, `Phone checks`, which runs whatever
# happened before it and calls `--verdict`. A skipped job reports success to
# branch protection whatever skipped it — a cancelled run, a failed dependency
# — so the verdict accepts a skipped part only when the gate's answer for that
# part is exactly `false`.
#
# ---------------------------------------------------------------------------
# FAIL CLOSED
#
# Only an explicit `false` skips a part, and the three answers are written
# together, as the last thing the script does. A run that dies anywhere before
# that line leaves the outputs empty, which each part's `if:` reads as "run".
# Every question this script cannot answer honestly is answered `true` for all
# three parts, out loud:
#
#   - any event but `pull_request` — a push to main and a `workflow_dispatch`
#     always test every part; no diff is read;
#   - a base ref that does not resolve;
#   - a `git diff` that fails;
#   - an empty diff, which cannot be told apart from one the script failed to
#     read;
#   - a list of changed files that cannot be read;
#   - a step summary that cannot be written, so a skip never happens without
#     the record of why.
#
# ---------------------------------------------------------------------------
# THE RULE
#
# The changed files are `git diff --name-only --no-renames origin/<base>...HEAD`,
# where <base> is the pull request's base branch, which for a stacked PR is
# another PR's branch rather than `main`. Three-dot, so the list is what the PR
# changed since it forked rather than everything that has landed on the base
# since. `--no-renames`, so a rename lists its old path as well as its new one
# and each is judged on its own: with rename detection on, `--name-only` prints
# only the new path, and a test vector moved OUT of `phone/test-vectors/` into
# `docs/` would read as a docs-only change.
#
# Each changed path names the parts it can affect, by the first rule in `judge`
# that matches it. A part runs when any changed path names it. The rules that
# name no part list what is safe to skip, never what is risky, so a path nobody
# thought about runs every part.
set -uo pipefail

# Job ID : gate output key, for every part. `--list-parts` prints the same
# pairs, and `--verdict` checks exactly these jobs.
PART_JOBS="relay:relay loader:loader phone-app:phone_app"

# The gate's output keys, in output order.
ALL_PARTS=""
for pair in $PART_JOBS; do
  ALL_PARTS="${ALL_PARTS:+$ALL_PARTS }${pair#*:}"
done
unset pair

# Paths that no phone part reads, after every rule that names a part has had
# its turn. Entries are `case` patterns, in which `*` also matches `/`.
NO_PART=(
  'docs/*'
  'Sources/*'
  'Tests/*'
  'Package.swift'
  'Package.resolved'
  'rust/*'
  'Resources/*'
  'SessionMod/*'
  '.claude/*'
  'recipe/*'
  'tools/*'
  '.github/*'
  'scripts/*'
)

usage() {
  echo "usage: $(basename "$0") [--classify | --list-parts | --verdict]" >&2
  exit 64
}

WORK=""
# shellcheck disable=SC2329 # invoked by the EXIT trap below
cleanup() {
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

# Succeeds when the space-separated LIST names PART.
names_part() {
  case " $1 " in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

# Judges one changed path. Sets PARTS to the parts it can affect (a subset of
# ALL_PARTS, space-separated, possibly empty) and REASON to the rule that
# decided it. The first matching rule wins.
judge() {
  local p="$1" pattern
  PARTS="$ALL_PARTS"
  case "$p" in
    .github/workflows/phone.yml)
      REASON='the workflow that runs the parts'; return ;;
    # The classifier, its harness, the bundle check, and whatever phone script
    # comes next: each runs every part until someone narrows it here.
    scripts/*phone*)
      REASON='a script named for the phone parts'; return ;;
    # The relay is a self-contained package and reads neither.
    phone/protocol/*|phone/test-vectors/*)
      PARTS='loader phone_app'; REASON='shared with Swift, the loader and the phone app'; return ;;
    relay/*)
      PARTS=relay; REASON='relay/**'; return ;;
    phone/loader/test/*)
      PARTS=loader; REASON='the loader'"'"'s own tests'; return ;;
    phone/loader/*)
      PARTS='loader phone_app'; REASON='the loader, which the app'"'"'s end-to-end tests run'; return ;;
    phone/app/*)
      PARTS=phone_app; REASON='phone/app/**'; return ;;
    Sources/TBDDaemon/Resources/phone-app/*)
      PARTS=phone_app; REASON='the committed app bundle'; return ;;
    # `phone/package.json`, its lockfile, `.nvmrc`, `tsconfig.json`: the
    # loader and the app build and test with them. The relay has its own.
    phone/*)
      PARTS='loader phone_app'; REASON="the phone workspace's shared tooling"; return ;;
    *.md)
      PARTS=''; REASON='Markdown outside relay/ and phone/'; return ;;
  esac
  for pattern in "${NO_PART[@]}"; do
    # Unquoted on purpose: each entry is a `case` pattern, not a literal.
    # shellcheck disable=SC2254
    case "$p" in
      $pattern)
        PARTS=''
        case "$pattern" in
          *'*') REASON="${pattern}*" ;;
          *) REASON="$pattern" ;;
        esac
        return ;;
    esac
  done
  REASON='no rule names it'
}

# Writes the answer and exits: the step summary first, then the three outputs,
# together and last. Arguments: the parts that run (a subset of ALL_PARTS,
# space-separated), a one-line reason, and the per-file account.
answer() {
  local runs="$1" reason="$2" files="${3:-}" part summary out="" said=""
  summary="### Phone parts gate
"
  for part in $ALL_PARTS; do
    if names_part "$runs" "$part"; then
      summary="$summary
- $part: runs"
    else
      summary="$summary
- $part: skipped"
    fi
  done
  summary="$summary

$reason"
  if [ -n "$files" ]; then
    summary="$summary

$files"
  fi

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if ! printf '%s\n' "$summary" >> "$GITHUB_STEP_SUMMARY"; then
      echo "::warning::Could not write the step summary, so every phone part runs rather than skipping with no record of why." >&2
      runs="$ALL_PARTS"
      reason="$reason (overridden: the step summary could not be written)"
    fi
  else
    printf '%s\n' "$summary" >&2
  fi

  for part in $ALL_PARTS; do
    if names_part "$runs" "$part"; then
      out="$out$part=true
"
      said="$said $part=true"
    else
      out="$out$part=false
"
      said="$said $part=false"
    fi
  done
  echo "${said# }: $reason" >&2
  # One write for all three lines, so a failure cannot leave some answers
  # written and not others.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s' "$out" >> "$GITHUB_OUTPUT" || exit 1
  else
    printf '%s' "$out"
  fi
  exit 0
}

# Judges every path in FILE and answers. FILE is NUL-separated if it holds a
# NUL, newline-separated otherwise.
classify_file() {
  local file="$1" nuls delim path part shown total=0 named=0 runs="" files=""
  nuls="$(tr -cd '\000' < "$file" | wc -c | tr -d ' ')" || nuls=""
  case "$nuls" in
    ''|*[!0-9]*) answer "$ALL_PARTS" "The list of changed files could not be read, so every part runs." ;;
  esac
  if [ "$nuls" -gt 0 ]; then
    delim=''
  else
    delim=$'\n'
  fi

  # `|| [ -n "$path" ]` keeps a last entry that has no terminator. Dropping it
  # could drop the one path that runs a part.
  while IFS= read -r -d "$delim" path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    total=$((total + 1))
    judge "$path"
    shown=""
    for part in $PARTS; do
      shown="${shown:+$shown, }$part"
      names_part "$runs" "$part" || runs="${runs:+$runs }$part"
    done
    if [ -n "$shown" ]; then
      named=$((named + 1))
    else
      shown="no part"
    fi
    files="$files- \`$path\` – $shown – $REASON
"
  done < "$file"

  if [ "$total" -eq 0 ]; then
    answer "$ALL_PARTS" "The diff is empty, which cannot be told apart from a diff that failed to read, so every part runs."
  fi
  if [ "$named" -eq 0 ]; then
    answer "" "None of the $total changed files can affect a phone part, so every part is skipped." "$files"
  fi
  answer "$runs" "$named of $total changed files can affect a phone part; a part runs when any of them names it." "$files"
}

new_work_dir() {
  WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/phone-parts-needed.XXXXXX")" || WORK=""
  [ -n "$WORK" ] && [ -d "$WORK" ]
}

# ---------------------------------------------------------------------------
# THE VERDICT
#
# `Phone checks` runs after every other job in `phone.yml`, whatever their
# results, and passes only when:
#
#   - it needs exactly `changes`, `harness` and the part jobs — a part added to
#     the workflow but not to PART_JOBS, or the reverse, fails instead of going
#     unchecked;
#   - the harness passed;
#   - every part passed, or was skipped while the gate's answer for it is
#     exactly the string `false`. A part skipped for any other reason — a
#     cancelled run, a gate that failed before answering, an answer of `true`
#     — fails.
#
# The gate's own result is not checked: a gate that fails writes no answers,
# every part then runs, and those results are what count.

# The step summary, or stderr when it is unset or cannot be written.
report() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; then return; fi
    echo "::warning::Could not write the step summary; the account follows here." >&2
  fi
  printf '%s\n' "$1" >&2
}

fail() {
  echo "::error::$1" >&2
  report "### Phone checks: fail

$1"
  exit 1
}

needs_jq() { printf '%s' "$NEEDS" | jq "$@"; }

# The `$j`, `$f`, `$k` and `$want` in the jq programs below are jq variables
# bound by `--arg`, single-quoted so the shell leaves them alone.

# Field FIELD of job JOB in NEEDS, or empty.
# shellcheck disable=SC2016 # a jq variable, see above
job_field() { needs_jq -r --arg j "$1" --arg f "$2" '.[$j][$f] // ""' 2>/dev/null; }

# The gate's answer for output KEY, for the account: the string itself, or
# empty when there is none.
# shellcheck disable=SC2016 # a jq variable, see above
gate_answer() {
  needs_jq -r --arg k "$1" \
    '.changes.outputs[$k] | if . == null then "" elif type == "string" then . else tojson end' 2>/dev/null
}

# Succeeds only when the gate's answer for output KEY is exactly "false".
# shellcheck disable=SC2016 # a jq variable, see above
gate_said_false() {
  needs_jq -e --arg k "$1" '.changes.outputs[$k] == "false"' >/dev/null 2>&1
}

verdict() {
  local want="changes harness" have pair job key result gate shown ok=1 notes
  NEEDS="${NEEDS:-}"
  command -v jq >/dev/null 2>&1 || fail "jq is not installed, so the jobs' results cannot be read."
  needs_jq -e -s 'length == 1 and (.[0] | type) == "object"' >/dev/null 2>&1 ||
    fail "NEEDS is not one JSON object, so the jobs' results cannot be read."

  for pair in $PART_JOBS; do want="$want ${pair%%:*}"; done
  # shellcheck disable=SC2016 # a jq variable, see above
  if ! needs_jq -e --arg want "$want" 'keys == ($want | split(" ") | sort)' >/dev/null 2>&1; then
    have="$(needs_jq -r 'keys | join(" ")' 2>/dev/null)"
    fail "Phone checks must need exactly: $want. It needs: ${have:-nothing}."
  fi

  result="$(job_field changes result)"
  notes="- changes (the gate): ${result:-no result}"
  result="$(job_field harness result)"
  notes="$notes
- harness: ${result:-no result}"
  [ "$result" = success ] || ok=0

  for pair in $PART_JOBS; do
    job="${pair%%:*}"
    key="${pair#*:}"
    result="$(job_field "$job" result)"
    gate="$(gate_answer "$key")"
    if [ -n "$gate" ]; then shown="\`$gate\`"; else shown="nothing"; fi
    case "$result" in
      success)
        notes="$notes
- $job: success – the gate answered $shown" ;;
      skipped)
        if gate_said_false "$key"; then
          notes="$notes
- $job: skipped – the gate answered \`false\`, so the gate skipped it"
        else
          notes="$notes
- $job: skipped – the gate answered $shown; only the gate's \`false\` may skip a part"
          ok=0
        fi ;;
      *)
        notes="$notes
- $job: ${result:-no result} – the gate answered $shown"
        ok=0 ;;
    esac
  done

  if [ "$ok" -eq 1 ]; then
    report "### Phone checks: pass

$notes"
    echo "Phone checks pass." >&2
    exit 0
  fi
  report "### Phone checks: fail

$notes"
  echo "::error::Phone checks fail: a part or the harness did not pass, or a part was skipped without the gate's \`false\`. See the step summary." >&2
  exit 1
}

case "${1:-}" in
  --list-parts)
    [ "$#" -eq 1 ] || usage
    for pair in $PART_JOBS; do
      printf '%s %s\n' "${pair%%:*}" "${pair#*:}"
    done
    exit 0 ;;
  --verdict)
    [ "$#" -eq 1 ] || usage
    verdict ;;
  --classify)
    [ "$#" -eq 1 ] || usage
    new_work_dir || answer "$ALL_PARTS" "Could not make a scratch directory to read the paths into, so every part runs."
    cat > "$WORK/paths" || answer "$ALL_PARTS" "Could not read the paths on stdin, so every part runs."
    classify_file "$WORK/paths" ;;
  '')
    [ "$#" -eq 0 ] || usage ;;
  *)
    usage ;;
esac

event="${EVENT_NAME:-}"
if [ "$event" != pull_request ]; then
  answer "$ALL_PARTS" "A \`${event:-unnamed}\` run always runs every part; no diff was read."
fi

# BASE_REF is whatever branch the pull request targets: `main`, or another
# PR's branch in a stack. The checkout's full history holds every branch.
base="${BASE_REF:-}"
if [ -z "$base" ] || ! git rev-parse --verify --quiet "origin/$base" >/dev/null 2>&1; then
  echo "::warning::origin/${base:-<empty BASE_REF>} does not resolve, so this run cannot tell what it changed; every phone part runs." >&2
  answer "$ALL_PARTS" "\`origin/${base:-<empty BASE_REF>}\` does not resolve, so every part runs."
fi

new_work_dir || answer "$ALL_PARTS" "Could not make a scratch directory for the diff, so every part runs."
if ! git diff -z --name-only --no-renames "origin/$base...HEAD" > "$WORK/paths"; then
  echo "::warning::git diff against origin/$base failed; every phone part runs." >&2
  answer "$ALL_PARTS" "\`git diff\` against \`origin/$base\` failed, so every part runs."
fi
classify_file "$WORK/paths"
