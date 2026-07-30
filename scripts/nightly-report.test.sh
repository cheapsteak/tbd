#!/usr/bin/env bash
# Tests for scripts/nightly-report.sh — run: bash scripts/nightly-report.test.sh
#
# The thing worth proving about a reporting wire is that it does NOT fire when it
# should not: a dry run must reach `gh` zero times. The `--post` path is proven
# against a stub here and for real, once, against issue #519 (the wire-verification
# fixture) — see nightly.yml.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/nightly-report.sh"

FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output lacks [$3]"; FAIL=1; fi; }
assert_lacks()    { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: unexpectedly contains [$3]"; FAIL=1; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/report-test.XXXXXX"; }

# A stand-in for `gh` that records that it was called, and with what.
mk_gh_stub() {
  local dir="$1"
  cat > "$dir/gh" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$dir/gh-calls"
cat >> "$dir/gh-stdin"
STUB
  chmod +x "$dir/gh"
  : > "$dir/gh-calls"    # pre-create so "never called" reads as 0, not as an error
  : > "$dir/gh-stdin"
}

test_dry_run_never_touches_gh() {
  local d; d="$(mktmpd)"; mk_gh_stub "$d"
  echo "some findings" > "$d/body.md"
  local out
  out="$(REPORT_GH_CMD="$d/gh" REPORT_TODAY=2026-07-27 REPORT_RUN_URL="https://example/run/1" \
        bash "$SCRIPT" --issue 519 --title "Quarantine audit" --body-file "$d/body.md" 2>&1)"
  assert_eq "dry run calls gh zero times" "0" "$(wc -l < "$d/gh-calls" 2>/dev/null | tr -d ' ' || echo 0)"
  assert_contains "dry run announces itself" "$out" "DRY RUN"
  assert_contains "dry run shows the body" "$out" "some findings"
  rm -rf "$d"
}

test_post_sends_the_composed_comment() {
  local d; d="$(mktmpd)"; mk_gh_stub "$d"
  echo "F1 — quarantine references a CLOSED issue" > "$d/body.md"
  REPORT_GH_CMD="$d/gh" REPORT_TODAY=2026-07-27 REPORT_RUN_URL="https://example/run/1" \
    bash "$SCRIPT" --issue 519 --title "Quarantine audit" --body-file "$d/body.md" --post >/dev/null 2>&1
  local call body
  call="$(cat "$d/gh-calls")"
  body="$(cat "$d/gh-stdin")"
  assert_contains "gh is called as issue comment on the right issue" "$call" "issue comment 519"
  assert_contains "and against the right repo" "$call" "--repo cheapsteak/tbd"
  assert_contains "the body carries the title" "$body" "Quarantine audit"
  assert_contains "the body carries the findings" "$body" "F1 —"
  assert_contains "the body links back to the run" "$body" "https://example/run/1"
  rm -rf "$d"
}

test_fixture_is_unmistakably_labelled() {
  local d; d="$(mktmpd)"; mk_gh_stub "$d"
  REPORT_GH_CMD="$d/gh" REPORT_TODAY=2026-07-27 REPORT_RUN_URL="https://example/run/1" \
    bash "$SCRIPT" --issue 519 --fixture --post >/dev/null 2>&1
  local body heading; body="$(cat "$d/gh-stdin")"
  heading="$(printf '%s' "$body" | grep -m1 '^###')"
  assert_contains "fixture says what it is, in the heading" "$heading" "WIRE VERIFICATION FIXTURE — not a real report"
  assert_contains "fixture says why it is kept" "$body" "kept rather than deleted on purpose"
  # WHITELIST THE HEADING, don't blacklist the glyph across the whole body: the
  # fixture's own text explains that real reports carry 🌙, so `assert_lacks 🌙`
  # on the full body fails from the wrong side — the prohibition contains the
  # thing prohibited. Assert on the unit that actually distinguishes them.
  assert_lacks "the fixture's heading is not a real-report heading" "$heading" "🌙"
  assert_contains "and a real report's heading is" \
    "$(REPORT_GH_CMD=true REPORT_TODAY=2026-07-27 bash "$SCRIPT" --issue 519 --title T | grep -m1 '^###')" "🌙"
  rm -rf "$d"
}

test_missing_body_file_is_an_error_not_an_empty_comment() {
  local d; d="$(mktmpd)"; mk_gh_stub "$d"
  local rc
  REPORT_GH_CMD="$d/gh" bash "$SCRIPT" --issue 519 --title "T" --body-file "$d/nope.md" --post >/dev/null 2>&1
  rc=$?
  assert_eq "a missing body file fails loudly" "2" "$rc"
  assert_eq "and posts nothing" "0" "$(wc -l < "$d/gh-calls" 2>/dev/null | tr -d ' ' || echo 0)"
  rm -rf "$d"
}

test_every_workflow_step_that_tees_a_report_body_captures_stderr() {
  # A comment is only worth posting if it carries the reason. Every nightly step
  # that tees its output into a file which later becomes an issue-comment body
  # must redirect stderr into that file first — the scripts report harness
  # failures via stderr + a non-zero exit, which is exactly the case that gets
  # commented about, and a clean run posts nothing at all.
  #
  # This exists because one of the three steps was missing `2>&1` on the first
  # version of this PR: the audit's die() path produced ZERO bytes of stdout, so
  # #519 would have received a comment with no reason in it. Two correct siblings
  # in the same file did not stop the third from being wrong, so the check is
  # mechanical rather than a habit.
  local wf="$HERE/../.github/workflows/nightly.yml"
  local total bad
  total="$(grep -c 'tee "\$' "$wf")"
  bad="$(grep 'tee "\$' "$wf" | grep -cv '2>&1 | tee')"
  assert_eq "nightly.yml still has the three tee'd report steps" "3" "$total"
  assert_eq "every tee'd step redirects stderr into the body it will post" "0" "$bad"
}

test_a_failed_gh_call_is_not_reported_as_success() {
  local d; d="$(mktmpd)"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$d/gh"; chmod +x "$d/gh"
  echo "body" > "$d/body.md"
  local rc
  REPORT_GH_CMD="$d/gh" bash "$SCRIPT" --issue 519 --title "T" --body-file "$d/body.md" --post >/dev/null 2>&1
  rc=$?
  assert_eq "gh failing makes the reporter fail" "2" "$rc"
  rm -rf "$d"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  echo "== $t"
  "$t"
done
if [[ $FAIL -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $FAIL
