#!/usr/bin/env bash
# scripts/nightly-quarantine-audit.sh — audit the `.flaky(issue:)` quarantine list
# against the retry-metrics ledger. Step 3 of the nightly workflow
# (docs/specs/2026-07-24-test-hardening-design.md §7 and §9).
#
# Quarantine is a deadline, not a resting place. Two things make it rot silently:
# a `.flaky` whose issue was closed months ago, and a `.flaky` whose test has
# passed first-try every run since someone quietly fixed it. Neither is visible
# from a green CI badge. This reads the ledger and says so.
#
# THE INPUT IS THE LEDGER, NEVER A LOG. Every `.flaky` execution — including
# clean first-try passes, which are what prove a flake is fixed — appends one
# JSONL record to `$TBD_RETRY_METRICS_PATH`, uploaded as the `retry-metrics`
# artifact by the `test` job. Keys: schema/testID/issue/attempts/outcome/file/line.
# That schema is a consumed API; this script is the consumer. Parsing `swift test`
# output instead would re-introduce exactly the fragility the ledger removed.
#
# Usage:
#   scripts/nightly-quarantine-audit.sh run                      # CI: fetch + analyze
#   scripts/nightly-quarantine-audit.sh fetch     --out-dir DIR [--days N]
#   scripts/nightly-quarantine-audit.sh states    --ledger-dir DIR --out FILE
#   scripts/nightly-quarantine-audit.sh inventory --out FILE
#   scripts/nightly-quarantine-audit.sh analyze   --ledger-dir DIR --runs-file F \
#                                                 --issue-states F [--inventory F]
#
# The split exists so `analyze` is a PURE FUNCTION of its input files and can be
# proven against known-positive fixtures with no network — see
# scripts/nightly-quarantine-audit.test.sh. An audit that has only ever been run
# against a healthy codebase is indistinguishable from one that never fires.
#
# Exit: 0 = no findings, 1 = findings (report on stdout either way), 2 = usage/input error.
#
# Test seams (env):
#   AUDIT_GH_CMD    command standing in for `gh`   (default: gh)
#   AUDIT_REPO      owner/repo for gh queries      (default: cheapsteak/tbd)
#   AUDIT_TODAY     ISO date used in the header    (default: today, UTC)

set -uo pipefail

# --- Contract constants -------------------------------------------------------

# THE EXCLUSION LIST IS EXACTLY ONE ENTRY, and growing it is a contract change.
# `retriesUntilPass()` fails once and passes on retry BY DESIGN on every run, so
# that a quarantine mechanism which silently stopped retrying cannot look
# identical to a working one. Its issue (#499) is a permanently-open fixture
# anchor, so F1/F2 would nag about a test that is doing its job.
readonly EXCLUDED_TEST_ID="TBDDaemonTests.FlakyQuarantineSelfTests/retriesUntilPass()"

# `alwaysFails()` shares issue #499 and is DELIBERATELY NOT EXCLUDED. It is gated
# off by TBD_FLAKY_SELFTEST_FAILURE, which nothing in CI sets, so it must
# contribute zero records. If records appear, the gate leaked into CI and F3
# reports it. An exclusion list grown to cover a broken gate turns the gate into
# silence — slice E was asked to add this entry in review and refused. Honoured.
readonly GATE_LEAK_SUFFIX="/alwaysFails()"

readonly EXPECTED_SCHEMA=1
readonly DEFAULT_WINDOW_DAYS=7
# F2 needs enough observations that "all green" means something. One clean run is
# not evidence a flake is gone; five is a week of nightlies-plus-merges.
readonly DEFAULT_MIN_RUNS=5

GH_CMD="${AUDIT_GH_CMD:-gh}"
REPO="${AUDIT_REPO:-cheapsteak/tbd}"

die() { echo "nightly-quarantine-audit: $*" >&2; exit 2; }

# --- fetch: CI runs -> ledger dir + runs.tsv ----------------------------------

# Downloads every `retry-metrics` artifact from `main` runs of the Test workflow
# inside the window. Writes:
#   $out/ledger/<runId>.jsonl   one file per run that produced an artifact
#   $out/runs.tsv               runId \t createdAt \t yes|no|unreadable|skipped:<conclusion>
# The runs.tsv "no" rows are the whole point of F5: `test.yml` uploads with
# `if-no-files-found: warn`, which is invisible unless something looks for it.
#
# ONLY success/failure runs are eligible. A CANCELLED run never reaches the
# upload step, so counting it as "no artifact" reports a concurrency cancellation
# as a broken ledger — measured, not theorised: the first live run of this audit
# reported 30 missing artifacts, of which the three post-feature ones were all
# `cancel-in-progress` cancellations. Ineligible runs are recorded as
# `skipped:<conclusion>` so they stay visible without being counted.
fetch() {
  local out_dir="" days="$DEFAULT_WINDOW_DAYS"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out-dir) out_dir="${2:-}"; shift 2 ;;
      --days)    days="${2:-}"; shift 2 ;;
      *) die "fetch: unknown argument $1" ;;
    esac
  done
  [[ -n "$out_dir" ]] || die "fetch: --out-dir is required"
  mkdir -p "$out_dir/ledger" || die "fetch: cannot create $out_dir/ledger"
  : > "$out_dir/runs.tsv"

  local since
  since="$(iso_days_ago "$days")"

  local runs
  runs="$("$GH_CMD" run list --repo "$REPO" --workflow test.yml --branch main \
            --status completed --limit 100 \
            --json databaseId,createdAt,conclusion --jq \
            ".[] | select(.createdAt >= \"$since\") | [.databaseId, .createdAt, .conclusion] | @tsv")" \
    || die "fetch: gh run list failed"

  if [[ -z "$runs" ]]; then
    echo "fetch: no completed main runs of test.yml since $since" >&2
    return 0
  fi

  local run_id created conclusion artifact_id
  while IFS=$'\t' read -r run_id created conclusion; do
    [[ -n "$run_id" ]] || continue
    case "$conclusion" in
      success|failure) ;;
      *) printf '%s\t%s\tskipped:%s\n' "$run_id" "$created" "${conclusion:-unknown}" >> "$out_dir/runs.tsv"
         continue ;;
    esac
    artifact_id="$("$GH_CMD" api "repos/$REPO/actions/runs/$run_id/artifacts" \
                     --jq '.artifacts[] | select(.name == "retry-metrics" and .expired == false) | .id' \
                     2>/dev/null | head -1)"
    if [[ -z "$artifact_id" ]]; then
      printf '%s\t%s\tno\n' "$run_id" "$created" >> "$out_dir/runs.tsv"
      continue
    fi
    local tmp_zip="$out_dir/ledger/$run_id.zip"
    if "$GH_CMD" api "repos/$REPO/actions/artifacts/$artifact_id/zip" > "$tmp_zip" 2>/dev/null \
       && unzip -p "$tmp_zip" > "$out_dir/ledger/$run_id.jsonl" 2>/dev/null; then
      printf '%s\t%s\tyes\n' "$run_id" "$created" >> "$out_dir/runs.tsv"
    else
      # The artifact exists but could not be read. That is not "no artifact" —
      # reporting it as such would blame the test job for a download failure.
      printf '%s\t%s\tunreadable\n' "$run_id" "$created" >> "$out_dir/runs.tsv"
    fi
    rm -f "$tmp_zip"
  done <<< "$runs"
}

iso_days_ago() {
  local days="$1"
  # BSD date (macOS) and GNU date (ubuntu) disagree on relative-date syntax, and
  # this script runs on both: locally for its tests, on ubuntu in CI.
  date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ
}

# --- states: distinct issues in the ledger -> issue \t OPEN|CLOSED ------------

states() {
  local ledger_dir="" out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ledger-dir) ledger_dir="${2:-}"; shift 2 ;;
      --out)        out="${2:-}"; shift 2 ;;
      *) die "states: unknown argument $1" ;;
    esac
  done
  [[ -n "$ledger_dir" && -n "$out" ]] || die "states: --ledger-dir and --out are required"
  : > "$out"

  local issue state
  for issue in $(distinct_issues "$ledger_dir"); do
    state="$("$GH_CMD" issue view "$issue" --repo "$REPO" --json state --jq .state 2>/dev/null)"
    # An unreadable issue is recorded as UNKNOWN rather than assumed OPEN: a
    # lookup failure must not silently read as "quarantine is still justified".
    printf '%s\t%s\n' "$issue" "${state:-UNKNOWN}" >> "$out"
  done
}

distinct_issues() {
  ledger_cat "$1" | jq -r 'select(.issue != null) | .issue' 2>/dev/null | sort -un
}

# `cat` over the ledger dir that tolerates an empty/absent dir (jq -s [] is the
# correct answer for "no records", and must not be an error).
ledger_cat() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -name '*.jsonl' -type f -exec cat {} + 2>/dev/null
}

# --- inventory: source-tree `.flaky(issue:)` sites ----------------------------

# Emits: file \t funcName \t issue — one row per quarantined test in the tree.
# Feeds F6 (informational): a quarantine the ledger has never seen.
inventory() {
  local out="" root="."
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)  out="${2:-}"; shift 2 ;;
      --root) root="${2:-}"; shift 2 ;;
      *) die "inventory: unknown argument $1" ;;
    esac
  done
  [[ -n "$out" ]] || die "inventory: --out is required"
  : > "$out"

  local file line_no issue func rest
  # `.flaky(issue: N)` on a trait line, then the next `func NAME(` below it.
  grep -rn '\.flaky(issue: *[0-9]\+)' "$root/Tests" --include='*.swift' 2>/dev/null \
    | grep -v 'FlakyTestSupport.swift' \
    | while IFS=: read -r file line_no rest; do
        issue="$(printf '%s' "$rest" | sed -n 's/.*\.flaky(issue: *\([0-9]*\)).*/\1/p')"
        [[ -n "$issue" ]] || continue
        func="$(tail -n "+$line_no" "$file" 2>/dev/null \
                  | sed -n 's/^[[:space:]]*func \([A-Za-z0-9_]*\)(.*/\1/p' | head -1)"
        [[ -n "$func" ]] || continue
        printf '%s\t%s\t%s\n' "${file#"$root"/}" "$func" "$issue" >> "$out"
      done
}

# --- analyze: pure function of its input files --------------------------------

# One aggregate object per testID, in exactly slice E's verified shape:
#   jq -s 'group_by(.testID)[] | {testID, issue, records, outcomes}'
aggregate() {
  ledger_cat "$1" | jq -s -c '
    map(select(.testID != null))
    | group_by(.testID)[]
    | {
        testID:   .[0].testID,
        issue:    .[0].issue,
        file:     .[0].file,
        line:     .[0].line,
        records:  length,
        outcomes: (group_by(.outcome) | map({key: (.[0].outcome // "null"), value: length}) | from_entries),
        schemas:  (map(.schema) | unique)
      }
  ' 2>/dev/null
}

# `grep -c` prints 0 AND exits 1 when nothing matches, so the obvious
# `x=$(grep -c ... || echo 0)` yields the string "0\n0" and every later arithmetic
# test on it is a syntax error. Measured on the first live run.
count_matching() {
  local n; n="$(grep -c -- "$(printf '%b' "$1")" "$2" 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf '0'
}

issue_state() {
  local issue="$1" states_file="$2" row
  row="$(grep -E "^${issue}	" "$states_file" 2>/dev/null | head -1)"
  [[ -n "$row" ]] && printf '%s' "${row#*	}" || printf 'UNKNOWN'
}

analyze() {
  local ledger_dir="" runs_file="" issue_states="" inventory_file=""
  local window_days="$DEFAULT_WINDOW_DAYS" min_runs="$DEFAULT_MIN_RUNS"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ledger-dir)   ledger_dir="${2:-}"; shift 2 ;;
      --runs-file)    runs_file="${2:-}"; shift 2 ;;
      --issue-states) issue_states="${2:-}"; shift 2 ;;
      --inventory)    inventory_file="${2:-}"; shift 2 ;;
      --window-days)  window_days="${2:-}"; shift 2 ;;
      --min-runs)     min_runs="${2:-}"; shift 2 ;;
      *) die "analyze: unknown argument $1" ;;
    esac
  done
  [[ -n "$ledger_dir" ]]   || die "analyze: --ledger-dir is required"
  [[ -n "$issue_states" ]] || die "analyze: --issue-states is required"

  local findings=() informational=() excluded_note=""
  local agg total_records=0 test_count=0
  agg="$(aggregate "$ledger_dir")"

  local line test_id issue records outcomes schemas first_try file
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    test_id="$(printf '%s' "$line"  | jq -r '.testID')"
    issue="$(printf '%s' "$line"    | jq -r '.issue // "null"')"
    records="$(printf '%s' "$line"  | jq -r '.records')"
    outcomes="$(printf '%s' "$line" | jq -r '.outcomes | to_entries | map("\(.key)=\(.value)") | join(", ")')"
    schemas="$(printf '%s' "$line"  | jq -r '.schemas | join(",")')"
    first_try="$(printf '%s' "$line" | jq -r '.outcomes | keys == ["passedFirstTry"]')"
    file="$(printf '%s' "$line"     | jq -r '.file // "?"')"
    test_count=$((test_count + 1))
    total_records=$((total_records + records))

    # F4 — schema drift. Deliberately NOT subject to the exclusion list: this is a
    # property of the artifact format, not of any test's quarantine status, and
    # the fixture's records are as good a witness to a bumped schema as any.
    if [[ "$schemas" != "$EXPECTED_SCHEMA" ]]; then
      findings+=("**F4 — ledger schema drift.** \`$test_id\` has records with schema \`$schemas\`, expected \`$EXPECTED_SCHEMA\`. The retry-metrics schema is a consumed API (Tests/CLAUDE.md); this audit's parsing may be reading the wrong shape. Re-check the consumer before trusting anything else in this report.")
    fi

    # F3 — the CI gate leaked. Reported, never filtered.
    case "$test_id" in
      *"$GATE_LEAK_SUFFIX")
        findings+=("**F3 — THE CI GATE LEAKED.** \`$test_id\` produced $records record(s) ($outcomes). This fixture is gated off by \`TBD_FLAKY_SELFTEST_FAILURE\` and nothing in CI sets it, so it must contribute ZERO records. Something is setting that variable in CI. This is reported rather than excluded on purpose — an exclusion list grown to cover a broken gate turns the gate into silence.")
        continue
        ;;
    esac

    if [[ "$test_id" == "$EXCLUDED_TEST_ID" ]]; then
      excluded_note="\`$test_id\` — permanent fixture for the quarantine mechanism itself (#499, kept open by design). $records record(s): $outcomes. Excluded from F1/F2 by contract; this is the only excluded entry."
      continue
    fi

    # F1 — quarantine outliving its issue.
    local state
    state="$(issue_state "$issue" "$issue_states")"
    if [[ "$state" == "CLOSED" ]]; then
      findings+=("**F1 — quarantine references a CLOSED issue.** \`$test_id\` is \`.flaky(issue: $issue)\` but #$issue is CLOSED. Either the flake is fixed and the trait should be removed, or the issue was closed prematurely. ($records record(s) in window: $outcomes; $file)")
    elif [[ "$state" == "UNKNOWN" ]]; then
      informational+=("Could not resolve the state of #$issue for \`$test_id\` — the \`gh issue view\` lookup failed. Not treated as OPEN: a failed lookup is not evidence that quarantine is still justified.")
    fi

    # F2 — quietly fixed. Needs enough observations to mean anything.
    if [[ "$first_try" == "true" && "$records" -ge "$min_runs" ]]; then
      findings+=("**F2 — passed first-try every run in the window.** \`$test_id\` (#$issue): $records/$records \`passedFirstTry\` over the last $window_days days. Candidate for removing \`.flaky(issue: $issue)\` — quarantine is a deadline, not a resting place. ($file)")
    fi
  done <<< "$agg"

  # F5 — a run that produced no ledger at all. test.yml uploads with
  # `if-no-files-found: warn`, so a broken wiring is otherwise invisible.
  #
  # Scoped to runs NEWER than the oldest run in the window that DID produce a
  # ledger. A run older than that predates the feature (or predates a fix) and
  # reporting it says "the wiring is broken" about a commit where it did not yet
  # exist. Using the observed first-ledger run rather than a hardcoded date keeps
  # this self-maintaining: nothing to update when the window rolls forward.
  # The all-missing case is NOT swallowed by that scoping — it is its own finding.
  local runs_total=0 runs_with=0 runs_without=0 runs_unreadable=0 runs_skipped=0
  if [[ -n "$runs_file" && -f "$runs_file" ]]; then
    runs_total=$(count_matching '.' "$runs_file")
    runs_with=$(count_matching '\tyes$' "$runs_file")
    runs_unreadable=$(count_matching '\tunreadable$' "$runs_file")
    runs_skipped=$(count_matching '\tskipped:' "$runs_file")
    runs_without=$(count_matching '\tno$' "$runs_file")

    local first_ledger_at="" late_missing=""
    if [[ "$runs_with" -gt 0 ]]; then
      first_ledger_at="$(grep '\tyes$' "$runs_file" | cut -f2 | sort | head -1)"
      late_missing="$(awk -F'\t' -v since="$first_ledger_at" \
        '$3 == "no" && $2 > since { print $1 }' "$runs_file" | tr '\n' ' ')"
    fi

    local eligible=$((runs_with + runs_without + runs_unreadable))
    if [[ "$runs_with" -eq 0 && "$eligible" -gt 0 ]]; then
      findings+=("**F5 — NO run in the window produced a \`retry-metrics\` artifact at all** ($eligible eligible run(s)). Either the ledger wiring is entirely broken or the artifacts have expired. Nothing in this report about quarantine health can be trusted until that is resolved — an empty ledger reads exactly like a healthy one.")
    elif [[ -n "$late_missing" ]]; then
      findings+=("**F5 — run(s) after the ledger was already working produced NO \`retry-metrics\` artifact.** \`if-no-files-found: warn\` does not fail the job, so this is invisible unless something looks for it. Run IDs: $late_missing(first ledger in window: $first_ledger_at)")
    fi
    if [[ "$runs_unreadable" -gt 0 ]]; then
      informational+=("$runs_unreadable run(s) had a \`retry-metrics\` artifact this audit could not download or unzip. Not counted as F5 — a download failure is not the test job's fault.")
    fi
  fi

  # F6 — informational only. `alwaysFails()` is legitimately absent from the
  # ledger (it is gated off), so a FINDING here would directly contradict F3.
  if [[ -n "$inventory_file" && -f "$inventory_file" ]]; then
    local inv_file inv_func inv_issue
    while IFS=$'\t' read -r inv_file inv_func inv_issue; do
      [[ -n "$inv_func" ]] || continue
      if ! printf '%s' "$agg" | jq -e --arg f "/$inv_func()" 'select(.testID | endswith($f))' >/dev/null 2>&1; then
        informational+=("\`$inv_func()\` in \`$inv_file\` is \`.flaky(issue: $inv_issue)\` but has NO records in the window — it never ran, or it is gated off. (\`alwaysFails()\` is expected here.)")
      fi
    done < "$inventory_file"
  fi

  # --- report ---
  local today="${AUDIT_TODAY:-$(date -u +%Y-%m-%d)}"
  echo "## Quarantine audit — $today"
  echo
  echo "Window: last $window_days days of \`main\` runs of \`test.yml\`. Source: the \`retry-metrics\` JSONL ledger (no log parsing)."
  echo
  echo "- Runs examined: **$runs_total** — $runs_with with a ledger artifact, $runs_without without, $runs_unreadable unreadable, $runs_skipped ineligible (cancelled/skipped: never reach the upload step)"
  echo "- Quarantined tests seen: **$test_count**, total records: **$total_records**"
  echo

  if [[ ${#findings[@]} -eq 0 ]]; then
    echo "### No findings"
    echo
    # Say what was actually checked, not "everything is fine". $runs_without is
    # deliberately reported here even in the clean case: those runs predate the
    # first ledger in the window, and a reader deserves the number rather than a
    # blanket reassurance the data does not support.
    echo "No quarantine references a closed issue, none passed first-try across the whole window (threshold: $min_runs runs), and the self-test gate has not leaked."
    echo
    echo "Ledger coverage: $runs_with of $((runs_with + runs_without + runs_unreadable)) eligible run(s) carried a \`retry-metrics\` artifact. The $runs_without without one all predate the oldest ledger in this window, so they are treated as pre-feature rather than as a wiring break — see F5."
  else
    echo "### Findings (${#findings[@]})"
    echo
    local f
    for f in "${findings[@]}"; do echo "- $f"; echo; done
  fi
  echo

  if [[ -n "$excluded_note" ]]; then
    echo "### Excluded by contract (1)"
    echo
    echo "- $excluded_note"
    echo
  fi

  if [[ ${#informational[@]} -gt 0 ]]; then
    echo "### Informational (${#informational[@]}) — not findings"
    echo
    local i
    for i in "${informational[@]}"; do echo "- $i"; echo; done
  fi

  [[ ${#findings[@]} -eq 0 ]]
}

# --- run: the CI entry point --------------------------------------------------

run() {
  local work_dir="" days="$DEFAULT_WINDOW_DAYS"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --work-dir) work_dir="${2:-}"; shift 2 ;;
      --days)     days="${2:-}"; shift 2 ;;
      *) die "run: unknown argument $1" ;;
    esac
  done
  [[ -n "$work_dir" ]] || work_dir="$(mktemp -d "${TMPDIR:-/tmp}/quarantine-audit.XXXXXX")"
  mkdir -p "$work_dir"
  # Inventory reads the source tree, so anchor it to the repo rather than to
  # whatever cwd the caller happens to have.
  local repo_root; repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  fetch --out-dir "$work_dir" --days "$days" || return 2
  states --ledger-dir "$work_dir/ledger" --out "$work_dir/issue-states.tsv" || return 2
  inventory --out "$work_dir/inventory.tsv" --root "$repo_root" || return 2
  analyze --ledger-dir "$work_dir/ledger" \
          --runs-file "$work_dir/runs.tsv" \
          --issue-states "$work_dir/issue-states.tsv" \
          --inventory "$work_dir/inventory.tsv" \
          --window-days "$days"
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    run)       run "$@" ;;
    fetch)     fetch "$@" ;;
    states)    states "$@" ;;
    inventory) inventory "$@" ;;
    analyze)   analyze "$@" ;;
    *) die "usage: $0 {run|fetch|states|inventory|analyze} [...]" ;;
  esac
}

# Source-guard: the test file sources this for its functions without running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
