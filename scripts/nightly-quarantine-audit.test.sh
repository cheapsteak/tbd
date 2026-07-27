#!/usr/bin/env bash
# Tests for scripts/nightly-quarantine-audit.sh
# Run: bash scripts/nightly-quarantine-audit.test.sh
#
# WHY THIS FILE EXISTS, in one sentence: a quarantine audit that silently never
# fires is indistinguishable from a clean codebase. Three of the test-hardening
# program's broken instruments were in the verification layer rather than the
# measurement layer — a poller that matched its own posts, a tally that grepped
# for a glyph the toolchain never prints, a spinner-survival check that cleared
# its PID array before checking. So every finding below is proven to FIRE on a
# known-positive input, and then MUTATION-CHECKED: the guard is broken on a copy
# of the script and the same input must stop reporting. A check that cannot fail
# is not a check.
#
# No network. `analyze` is a pure function of its input files, which is the whole
# reason fetch/states/inventory are separate subcommands.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/nightly-quarantine-audit.sh"

FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output lacks [$3]"; FAIL=1; fi; }
assert_lacks()    { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output unexpectedly contains [$3]"; FAIL=1; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/audit-test.XXXXXX"; }

# Build a work dir: $1 = ledger JSONL on stdin, plus default runs/states files.
mk_work() {
  local d; d="$(mktmpd)"
  mkdir -p "$d/ledger"
  cat > "$d/ledger/run1.jsonl"
  printf '1\t2026-07-20T00:00:00Z\tyes\n' > "$d/runs.tsv"
  : > "$d/issue-states.tsv"
  printf '%s' "$d"
}

# Run `analyze` against a work dir. Sets ANALYZE_OUT and ANALYZE_RC as globals
# rather than echoing the report: `out="$(analyze_in ...)"` would run the whole
# function in a command-substitution SUBSHELL, so the exit code it recorded would
# be discarded and every rc assertion would read a stale value. That is the same
# family of defect as a check that cannot fail.
ANALYZE_OUT=""
ANALYZE_RC=0
analyze_in() {
  local d="$1"; shift
  ANALYZE_OUT="$(AUDIT_TODAY=2026-07-27 bash "$SCRIPT" analyze \
          --ledger-dir "$d/ledger" --runs-file "$d/runs.tsv" \
          --issue-states "$d/issue-states.tsv" "$@" 2>&1)"
  ANALYZE_RC=$?
}

# Run a MUTATED copy of the script — `sed -E "$1"` applied to the source.
analyze_mutated() {
  local sed_expr="$1" d="$2"; shift 2
  local mutant; mutant="$(mktmpd)/mutant.sh"
  sed -E "$sed_expr" "$SCRIPT" > "$mutant"
  AUDIT_TODAY=2026-07-27 bash "$mutant" analyze \
    --ledger-dir "$d/ledger" --runs-file "$d/runs.tsv" \
    --issue-states "$d/issue-states.tsv" "$@" >/dev/null 2>&1
  echo $?
}

# ---------------------------------------------------------------------------
# TRUE NEGATIVE — the real artifact, byte for byte
# ---------------------------------------------------------------------------

# This is the actual content of the `retry-metrics` artifact from CI run
# 30145614672 (slice E's end-to-end verification, PR #500). Kept verbatim rather
# than fetched, so this test is offline and stable: it is the shape a HEALTHY
# repo produces today, and the audit must report nothing on it.
readonly REAL_ARTIFACT='{"attempts":2,"file":"Tests/TBDDaemonTests/FlakyQuarantineSelfTests.swift","issue":499,"line":29,"outcome":"passedOnRetry","schema":1,"testID":"TBDDaemonTests.FlakyQuarantineSelfTests/retriesUntilPass()"}'

test_real_artifact_is_clean() {
  local d; d="$(printf '%s\n' "$REAL_ARTIFACT" | mk_work)"
  printf '499\tOPEN\n' > "$d/issue-states.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "real artifact from run 30145614672 -> exit 0" "0" "$ANALYZE_RC"
  assert_contains "real artifact -> no findings" "$out" "### No findings"
  assert_contains "real artifact -> fixture listed as excluded" "$out" "Excluded by contract (1)"
  assert_contains "real artifact -> record counted" "$out" "total records: **1**"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# F1 — quarantine referencing a CLOSED issue
# ---------------------------------------------------------------------------

test_f1_fires_on_closed_issue() {
  local d; d="$(mk_work <<'JSON'
{"attempts":1,"file":"Tests/TBDDaemonTests/AcmeTests.swift","issue":458,"line":10,"outcome":"passedFirstTry","schema":1,"testID":"TBDDaemonTests.AcmeTests/racesOnAttach()"}
JSON
)"
  # #458 is a genuinely closed issue in this repo.
  printf '458\tCLOSED\n' > "$d/issue-states.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "closed-issue quarantine -> exit 1" "1" "$ANALYZE_RC"
  assert_contains "F1 named" "$out" "F1 — quarantine references a CLOSED issue"
  assert_contains "F1 names the test" "$out" "AcmeTests/racesOnAttach()"
  assert_contains "F1 names the issue" "$out" "#458 is CLOSED"
  # MUTATION: break the F1 guard; the same input must stop reporting.
  # shellcheck disable=SC2016 # the sed expression must reach sed unexpanded
  assert_eq "F1 mutation: guard removed -> no longer fires" "0" \
    "$(analyze_mutated 's/if \[\[ "\$state" == "CLOSED" \]\]/if [[ "$state" == "NEVER_MATCHES" ]]/' "$d")"
  rm -rf "$d"
}

test_f1_unknown_state_is_informational_not_a_finding() {
  local d; d="$(mk_work <<'JSON'
{"attempts":1,"file":"Tests/TBDDaemonTests/AcmeTests.swift","issue":777,"line":10,"outcome":"passedFirstTry","schema":1,"testID":"TBDDaemonTests.AcmeTests/racesOnAttach()"}
JSON
)"
  : > "$d/issue-states.tsv"   # lookup failed for #777
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "unresolvable issue state -> exit 0 (not a finding)" "0" "$ANALYZE_RC"
  assert_contains "unresolvable issue state -> informational" "$out" "Could not resolve the state of #777"
  assert_lacks "unresolvable issue state is not reported as CLOSED" "$out" "F1 —"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# F2 — passed first-try all week
# ---------------------------------------------------------------------------

_six_first_try_records() {
  local i
  for i in 1 2 3 4 5 6; do
    printf '{"attempts":1,"file":"Tests/TBDDaemonTests/AcmeTests.swift","issue":494,"line":%d,"outcome":"passedFirstTry","schema":1,"testID":"TBDDaemonTests.AcmeTests/quietlyFixed()"}\n' "$i"
  done
}

test_f2_fires_when_all_first_try_over_threshold() {
  local d; d="$(_six_first_try_records | mk_work)"
  printf '494\tOPEN\n' > "$d/issue-states.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "6/6 passedFirstTry -> exit 1" "1" "$ANALYZE_RC"
  assert_contains "F2 named" "$out" "F2 — passed first-try every run"
  assert_contains "F2 shows the ratio" "$out" "6/6"
  assert_eq "F2 mutation: threshold made unreachable -> no longer fires" "0" \
    "$(analyze_mutated 's/readonly DEFAULT_MIN_RUNS=5/readonly DEFAULT_MIN_RUNS=9999/' "$d")"
  rm -rf "$d"
}

test_f2_does_not_fire_below_threshold() {
  local d; d="$(mk_work <<'JSON'
{"attempts":1,"file":"Tests/TBDDaemonTests/AcmeTests.swift","issue":494,"line":1,"outcome":"passedFirstTry","schema":1,"testID":"TBDDaemonTests.AcmeTests/quietlyFixed()"}
{"attempts":1,"file":"Tests/TBDDaemonTests/AcmeTests.swift","issue":494,"line":1,"outcome":"passedFirstTry","schema":1,"testID":"TBDDaemonTests.AcmeTests/quietlyFixed()"}
JSON
)"
  printf '494\tOPEN\n' > "$d/issue-states.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "2 clean runs is not evidence of a fix -> exit 0" "0" "$ANALYZE_RC"
  assert_lacks "no F2 below threshold" "$out" "F2 —"
  rm -rf "$d"
}

test_f2_does_not_fire_when_a_retry_happened() {
  local d; d="$({ _six_first_try_records; printf '{"attempts":2,"file":"Tests/TBDDaemonTests/AcmeTests.swift","issue":494,"line":1,"outcome":"passedOnRetry","schema":1,"testID":"TBDDaemonTests.AcmeTests/quietlyFixed()"}\n'; } | mk_work)"
  printf '494\tOPEN\n' > "$d/issue-states.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "one retry in the window -> still quarantined, exit 0" "0" "$ANALYZE_RC"
  assert_lacks "no F2 when a retry occurred" "$out" "F2 —"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# F3 — the CI gate leaked. REPORTED, never filtered.
# ---------------------------------------------------------------------------

test_f3_fires_on_alwaysfails_records() {
  local d; d="$(mk_work <<'JSON'
{"attempts":3,"file":"Tests/TBDDaemonTests/FlakyQuarantineSelfTests.swift","issue":499,"line":54,"outcome":"failed","schema":1,"testID":"TBDDaemonTests.FlakyQuarantineSelfTests/alwaysFails()"}
JSON
)"
  printf '499\tOPEN\n' > "$d/issue-states.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "alwaysFails record -> exit 1" "1" "$ANALYZE_RC"
  assert_contains "F3 named" "$out" "F3 — THE CI GATE LEAKED"
  assert_contains "F3 explains why it is not excluded" "$out" "turns the gate into silence"
  # THE MUTATION THAT MATTERS: slice E's reviewer proposed exactly this — adding
  # alwaysFails() to the exclusion list. Here it does NOT silence F3, and that is
  # a deliberate ordering property, not luck: the gate-leak check runs BEFORE the
  # exclusion check, so no future edit to the exclusion list can hide a leaked
  # gate. (I wrote this assertion the other way round first, expecting the
  # exclusion to win; the run said otherwise and the implementation was the
  # stronger of the two. Kept as a regression guard on the ordering.)
  assert_eq "F3 ordering: even excluding alwaysFails cannot silence the gate leak" "1" \
    "$(analyze_mutated 's|readonly EXCLUDED_TEST_ID=.*|readonly EXCLUDED_TEST_ID="TBDDaemonTests.FlakyQuarantineSelfTests/alwaysFails()"|' "$d")"
  # And the real kill, so this test is provably coupled to the F3 code path:
  # break the suffix it matches on and the same input must stop reporting.
  assert_eq "F3 mutation: suffix match broken -> no longer fires" "0" \
    "$(analyze_mutated 's|readonly GATE_LEAK_SUFFIX=.*|readonly GATE_LEAK_SUFFIX="/neverMatches()"|' "$d")"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# F4 — ledger schema drift
# ---------------------------------------------------------------------------

test_f4_fires_on_schema_bump() {
  local d; d="$(mk_work <<'JSON'
{"attempts":1,"file":"Tests/TBDDaemonTests/AcmeTests.swift","issue":494,"line":1,"outcome":"passedFirstTry","schema":2,"testID":"TBDDaemonTests.AcmeTests/racesOnAttach()"}
JSON
)"
  printf '494\tOPEN\n' > "$d/issue-states.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "schema 2 -> exit 1" "1" "$ANALYZE_RC"
  assert_contains "F4 named" "$out" "F4 — ledger schema drift"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# F5 — a run that produced no ledger artifact at all
# ---------------------------------------------------------------------------

test_f5_fires_on_missing_artifact_after_the_ledger_worked() {
  local d; d="$(printf '%s\n' "$REAL_ARTIFACT" | mk_work)"
  printf '499\tOPEN\n' > "$d/issue-states.tsv"
  {
    printf '1\t2026-07-20T00:00:00Z\tyes\n'
    printf '2\t2026-07-21T00:00:00Z\tno\n'
    printf '3\t2026-07-22T00:00:00Z\tno\n'
  } > "$d/runs.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "artifact stopped appearing after it had worked -> exit 1" "1" "$ANALYZE_RC"
  assert_contains "F5 named" "$out" "F5 — run(s) after the ledger was already working"
  assert_contains "F5 lists the run IDs" "$out" "2 3"
  # shellcheck disable=SC2016 # the sed expression must reach sed unexpanded
  assert_eq "F5 mutation: late-missing detection broken -> no longer fires" "0" \
    "$(analyze_mutated 's/\$3 == "no" && \$2 > since/$3 == "never" \&\& $2 > since/' "$d")"
  rm -rf "$d"
}

test_f5_ignores_runs_that_predate_the_first_ledger() {
  # These runs are older than the ledger feature itself. Reporting them says
  # "the wiring is broken" about commits where the wiring did not yet exist.
  local d; d="$(printf '%s\n' "$REAL_ARTIFACT" | mk_work)"
  printf '499\tOPEN\n' > "$d/issue-states.tsv"
  {
    printf '1\t2026-07-20T00:00:00Z\tno\n'
    printf '2\t2026-07-21T00:00:00Z\tno\n'
    printf '3\t2026-07-22T00:00:00Z\tyes\n'
  } > "$d/runs.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "pre-feature runs are not a wiring break -> exit 0" "0" "$ANALYZE_RC"
  assert_lacks "no F5 for runs older than the first ledger" "$out" "F5 —"
  rm -rf "$d"
}

test_f5_does_not_count_cancelled_runs() {
  # MEASURED, not theorised: the first live run of this audit reported 30 missing
  # artifacts, and the three that post-dated the feature were all
  # `cancel-in-progress` cancellations — runs that never reach the upload step.
  # Counting those reports a concurrency cancellation as a broken ledger.
  local d; d="$(printf '%s\n' "$REAL_ARTIFACT" | mk_work)"
  printf '499\tOPEN\n' > "$d/issue-states.tsv"
  {
    printf '1\t2026-07-20T00:00:00Z\tyes\n'
    printf '2\t2026-07-21T00:00:00Z\tskipped:cancelled\n'
    printf '3\t2026-07-22T00:00:00Z\tskipped:cancelled\n'
  } > "$d/runs.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "cancelled runs are not a wiring break -> exit 0" "0" "$ANALYZE_RC"
  assert_lacks "no F5 for cancelled runs" "$out" "F5 —"
  assert_contains "cancelled runs are still visible in the counts" "$out" "2 ineligible"
  rm -rf "$d"
}

test_f5_reports_a_total_absence_of_ledgers_as_its_own_finding() {
  # The scoping above must not swallow the case that matters most: if NOTHING in
  # the window produced a ledger, an empty ledger reads exactly like a healthy one.
  local d; d="$(printf '' | mk_work)"
  {
    printf '1\t2026-07-20T00:00:00Z\tno\n'
    printf '2\t2026-07-21T00:00:00Z\tno\n'
  } > "$d/runs.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "no ledger anywhere in the window -> exit 1" "1" "$ANALYZE_RC"
  assert_contains "total absence named" "$out" "NO run in the window produced a"
  assert_contains "and says why it matters" "$out" "reads exactly like a healthy one"
  rm -rf "$d"
}

test_f5_unreadable_artifact_is_informational_not_a_finding() {
  local d; d="$(printf '%s\n' "$REAL_ARTIFACT" | mk_work)"
  printf '499\tOPEN\n' > "$d/issue-states.tsv"
  printf '9\t2026-07-22T00:00:00Z\tunreadable\n' >> "$d/runs.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "unreadable artifact is a download failure, not a wiring break" "0" "$ANALYZE_RC"
  assert_contains "unreadable artifact -> informational" "$out" "could not download or unzip"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# F6 — informational only (a finding here would contradict F3)
# ---------------------------------------------------------------------------

test_f6_absent_quarantine_is_informational_only() {
  local d; d="$(printf '%s\n' "$REAL_ARTIFACT" | mk_work)"
  printf '499\tOPEN\n' > "$d/issue-states.tsv"
  printf 'Tests/TBDDaemonTests/FlakyQuarantineSelfTests.swift\talwaysFails\t499\n' > "$d/inv.tsv"
  analyze_in "$d" --inventory "$d/inv.tsv"; local out="$ANALYZE_OUT"
  assert_eq "a quarantine with no records does not fail the audit" "0" "$ANALYZE_RC"
  assert_contains "F6 reported as informational" "$out" "has NO records in the window"
  assert_contains "F6 names alwaysFails as expected there" "$out" "is expected here"
  rm -rf "$d"
}

test_f6_matches_a_present_quarantine_and_stays_quiet() {
  local d; d="$(printf '%s\n' "$REAL_ARTIFACT" | mk_work)"
  printf '499\tOPEN\n' > "$d/issue-states.tsv"
  printf 'Tests/TBDDaemonTests/FlakyQuarantineSelfTests.swift\tretriesUntilPass\t499\n' > "$d/inv.tsv"
  analyze_in "$d" --inventory "$d/inv.tsv"; local out="$ANALYZE_OUT"
  assert_eq "a quarantine WITH records -> exit 0" "0" "$ANALYZE_RC"
  assert_lacks "no spurious F6 for a test that did run" "$out" "has NO records in the window"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# The exclusion list: exactly one entry
# ---------------------------------------------------------------------------

test_excluded_fixture_never_produces_f1_or_f2() {
  # Six first-try passes AND a closed issue — both F1 and F2 would fire on any
  # other test. The fixture is exempt from both, and only the fixture is.
  local d; d="$(for i in 1 2 3 4 5 6; do
      printf '{"attempts":1,"file":"Tests/TBDDaemonTests/FlakyQuarantineSelfTests.swift","issue":499,"line":29,"outcome":"passedFirstTry","schema":1,"testID":"TBDDaemonTests.FlakyQuarantineSelfTests/retriesUntilPass()"}\n'
    done | mk_work)"
  printf '499\tCLOSED\n' > "$d/issue-states.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "the one excluded fixture is exempt from F1 and F2" "0" "$ANALYZE_RC"
  assert_contains "and is still reported as excluded" "$out" "Excluded by contract (1)"
  # MUTATION: shrink the exclusion to nothing — the fixture must then trip both.
  assert_eq "exclusion mutation: emptied -> the fixture now trips findings" "1" \
    "$(analyze_mutated 's|readonly EXCLUDED_TEST_ID=.*|readonly EXCLUDED_TEST_ID="none"|' "$d")"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# Degenerate inputs must not read as "healthy"
# ---------------------------------------------------------------------------

test_empty_ledger_reports_zero_rather_than_pretending() {
  local d; d="$(printf '' | mk_work)"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_eq "empty ledger -> exit 0" "0" "$ANALYZE_RC"
  assert_contains "empty ledger states the count plainly" "$out" "Quarantined tests seen: **0**"
  rm -rf "$d"
}

test_malformed_record_does_not_crash_the_audit() {
  local d; d="$(mk_work <<'JSON'
not json at all
{"attempts":1,"file":"f.swift","issue":494,"line":1,"outcome":"passedFirstTry","schema":1,"testID":"TBDDaemonTests.AcmeTests/x()"}
JSON
)"
  printf '494\tOPEN\n' > "$d/issue-states.tsv"
  analyze_in "$d"; local out="$ANALYZE_OUT"
  assert_contains "a malformed line does not take the report down" "$out" "Quarantine audit"
  rm -rf "$d"
}

# ---------------------------------------------------------------------------
# inventory: parses the real source tree
# ---------------------------------------------------------------------------

test_inventory_finds_the_real_selftests() {
  local out; out="$(mktmpd)/inv.tsv"
  bash "$SCRIPT" inventory --out "$out" --root "$HERE/.." >/dev/null 2>&1
  local content; content="$(cat "$out")"
  assert_contains "inventory finds retriesUntilPass" "$content" "retriesUntilPass"
  assert_contains "inventory finds alwaysFails" "$content" "alwaysFails"
  assert_contains "inventory records the issue number" "$content" "499"
  assert_lacks "inventory skips the trait's own definition file" "$content" "FlakyTestSupport.swift"
}

# ---------------------------------------------------------------------------

test_workflow_grants_actions_read_because_this_script_reads_the_actions_api() {
  # Declaring a `permissions:` block sets every scope NOT listed to `none`, so
  # omitting `actions: read` does not fall back to a default — it revokes it.
  # `fetch()` reads the Actions API three ways; without the scope every one of
  # them 403s and the audit dies without ever auditing anything.
  #
  # DERIVED rather than hardcoded: the requirement is asserted only if this
  # script actually still calls the Actions API, so the check tracks the code
  # instead of restating a fact about it. It also fires the other way — add an
  # Actions-API call to a workflow that lacks the scope and this goes red.
  #
  # This is here because my own end-to-end verification could not have caught it:
  # I ran `fetch` under my personal `gh` auth, which has scopes the constrained
  # workflow token does not.
  local wf="$HERE/../.github/workflows/nightly.yml"
  local uses_actions_api=0
  grep -qE "gh run list|actions/runs/|actions/artifacts/|run list --repo" "$SCRIPT" && uses_actions_api=1
  assert_eq "the audit still reads the Actions API (premise of this check)" "1" "$uses_actions_api"
  if [[ "$uses_actions_api" -eq 1 ]]; then
    assert_eq "so nightly.yml must grant actions: read" "1" \
      "$(grep -cE '^[[:space:]]*actions:[[:space:]]*read' "$wf")"
  fi
}

for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  echo "== $t"
  "$t"
done
if [[ $FAIL -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $FAIL
