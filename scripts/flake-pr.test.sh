#!/usr/bin/env bash
# Tests for scripts/flake-pr.sh, scripts/flake-pr.py, the session prompt, and
# the `fix` and `publish` jobs' structure in flake-fixer.yml — run:
#   bash scripts/flake-pr.test.sh
#
# NO BUILD, NO NETWORK, NO REAL `gh`. `gh` is a stub in FLAKE_GH_CMD that
# answers from a routes file and logs every call with the GH_TOKEN it saw. The
# push goes to a local bare repository (FLAKE_PR_REMOTE), whose pre-receive
# hook can refuse a push the way GitHub refuses an App without the `workflows`
# permission.
#
# EVERY GUARD IS MUTATION-CHECKED: `mutant_of` copies the scripts into a fresh
# directory with one sed edit applied, and the case re-runs against the copy;
# the workflow cases run their check against a sed-edited copy of the file.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
# shellcheck disable=SC2016 # sed expressions and literal ${{ }} must NOT expand here
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PR_SH="$HERE/flake-pr.sh"
PR_PY="$HERE/flake-pr.py"
PROMPT="$ROOT/.github/flake-fixer/session-prompt.md"
WORKFLOW="$ROOT/.github/workflows/flake-fixer.yml"
BOT='tbd-flake-fixer[bot]'
REPO='cheapsteak/tbd'
HOLDER='TBDSharedTests.HolderLockTests/lockIsReacquirableAfterRelease()'

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GITHUB_STEP_SUMMARY FLAKE_WRITE_TOKEN GH_TOKEN

FAIL=0
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output lacks [$3]"; echo "$2" | sed 's/^/       /' | head -30; FAIL=1; fi; }
assert_lacks()    { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output contains [$3]"; echo "$2" | sed 's/^/       /' | head -30; FAIL=1; fi; }
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] != [$3]"; FAIL=1; fi; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/flake-pr-test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
# mktemp, not a counter: callers run it in a command substitution.
mktmpd() { mktemp -d "$SCRATCH/d.XXXXXX"; }
# Every repo a case makes lives under SCRATCH; a mangled path must fail there,
# never fall through to the checkout this harness lives in.
export GIT_CEILING_DIRECTORIES="$SCRATCH"
cd "$SCRATCH" || exit 2

# mutant_of SED_EXPR FILE -> a directory holding the scripts, FILE edited.
mutant_of() {
  local expr="$1" file="$2" dir name
  dir="$(mktmpd)"
  cp "$HERE/flake_lib.py" "$HERE/flake-ledger.py" "$HERE/flake-verify.sh" "$PR_SH" "$PR_PY" "$dir/"
  name="$(basename "$file")"
  sed -E "$expr" "$file" > "$dir/$name"
  if cmp -s "$file" "$dir/$name"; then
    echo "FAIL - mutation [$expr] did not change $name" >&2
    FAIL=1
  fi
  printf '%s' "$dir"
}

# ============================================================================
# the session prompt (spec §6.1)
# ============================================================================

test_the_session_prompt_names_every_protected_path() {
  local text pattern
  text="$(cat "$PROMPT")"
  while IFS= read -r pattern; do
    assert_contains "names $pattern" "$text" "\`$pattern\`"
  done < <(bash -c 'source "$1"; printf "%s\n" "${PROTECTED_PATTERNS[@]}"' _ "$HERE/flake-verify.sh")
}

test_the_session_prompt_states_each_tests_claude_rule() {
  local text needle
  text="$(cat "$PROMPT")"
  for needle in "No blanket retries" pollUntilTrue TestDeadlines "Never raise a deadline" ".flaky(issue:)" \
      "The kill hazards" "scripts/test.sh" "Assertion hygiene" "Tests/CLAUDE.md" ".github/workflows/"; do
    assert_contains "states $needle" "$text" "$needle"
  done
}

test_the_session_prompt_has_its_placeholders() {
  local text p
  text="$(cat "$PROMPT")"
  for p in BRIEF BASELINE PRIOR_TRY NOTES_PATH; do
    assert_contains "{{$p}}" "$text" "{{$p}}"
  done
  assert_eq "the brief comes after the rules" "1" "$(awk '/\{\{BRIEF\}\}/{print (seen ? 1 : 0); exit} /Assertion hygiene/{seen=1}' "$PROMPT")"
}

# ============================================================================
# the open step, against a stub gh and a local bare remote
# ============================================================================

# stub_gh DIR: DIR/gh answers from DIR/routes.json ({"match", "out"|"file",
# "exit"}) and logs `<GH_TOKEN> <args>` then `  STDIN <body>` lines to DIR/log.
stub_gh() {
  local dir="$1"
  cat > "$dir/gh" <<'PY'
#!/usr/bin/env python3
import json, os, re, sys
here = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[1:]
args = " ".join(argv)
data = sys.stdin.read() if "--input" in argv else ""
if "--body-file" in argv:
    data = open(argv[argv.index("--body-file") + 1]).read()
with open(os.path.join(here, "log"), "a") as log:
    log.write(f"{os.environ.get('GH_TOKEN', '')} {args}\n")
    for line in data.splitlines():
        log.write(f"  STDIN {line}\n")
for route in json.load(open(os.path.join(here, "routes.json"))):
    if re.search(route["match"], args):
        if "file" in route:
            sys.stdout.write(open(route["file"]).read())
        else:
            sys.stdout.write(route.get("out", ""))
        sys.exit(route.get("exit", 0))
sys.stderr.write(f"stub gh: no route for {args}\n")
sys.exit(99)
PY
  chmod +x "$dir/gh"
  : > "$dir/log"
}

# world [VERDICT_JSON] -> D with: D/origin.git (bare, main at the base), D/work
# (the publish checkout), D/session (where the candidate was committed),
# D/pick and D/attempt (the two artifacts), D/gh. The candidate edits one test
# file; set CANDIDATE_PATH to commit a different path.
world() {
  local verdict="${1:-}" d base head
  d="$(mktmpd)"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/seed" 2>/dev/null
  mkdir -p "$d/seed/Tests/TBDSharedTests"
  echo base > "$d/seed/Tests/TBDSharedTests/HolderLockTests.swift"
  git -C "$d/seed" add -A && git -C "$d/seed" commit -q -m base && git -C "$d/seed" push -q origin HEAD:main 2>/dev/null
  git clone -q -b main "$d/origin.git" "$d/work" 2>/dev/null
  git clone -q -b main "$d/origin.git" "$d/session" 2>/dev/null
  base="$(git -C "$d/session" rev-parse HEAD)"
  local path="${CANDIDATE_PATH:-Tests/TBDSharedTests/HolderLockTests.swift}"
  mkdir -p "$d/session/$(dirname "$path")"; echo fixed > "$d/session/$path"
  git -C "$d/session" add -A && git -C "$d/session" commit -q -m "Fix the lock race"
  head="$(git -C "$d/session" rev-parse HEAD)"
  mkdir -p "$d/pick" "$d/attempt/verify" "$d/attempt/baseline"
  jq -n --arg t "$HOLDER" '{issue: 10, test_id: $t, episode: 0, failures: 3, places: ["branch:a", "night:2026-10-02"]}' > "$d/pick/target.json"
  echo "$base" > "$d/pick/base_sha"; echo 2026-10-08T06:00:00Z > "$d/pick/started_at"; echo 4242 > "$d/pick/run_id"
  # A target.json in the candidate is session-reachable; publish must read the pick.
  echo '{"issue": 99, "test_id": "TAMPERED-TARGET"}' > "$d/attempt/target.json"
  echo candidate > "$d/attempt/outcome"; echo "$head" > "$d/attempt/head_sha"
  git -C "$d/session" bundle create -q "$d/attempt/candidate.bundle" "$base..HEAD" 2>/dev/null
  echo "https://github.com/$REPO/actions/runs/4242" > "$d/attempt/run_url"
  echo 1 > "$d/attempt/baseline/f"; echo 20 > "$d/attempt/baseline/v"
  printf 'Diagnosis: the lock file outlived its holder. @someone SESSION-NOTES\n' > "$d/attempt/flakefix-notes.md"
  [[ -n "$verdict" ]] || verdict='{"verdict": "pass", "scope": "test", "iterations": 59, "completed": 59, "target_failures": 0, "reasons": [], "other_failures": [], "cores": "3", "spinners": "3", "load1m": "3.1 to 5.2", "protected": [], "n": 59, "p": 0.05, "cap": 82, "bound": "reached", "false_pass": 0.0485, "weak": false, "scale": null}'
  printf '%s\n' "$verdict" > "$d/attempt/verify/verdict.json"
  printf '**Stress scope:** test.\n\n**Result:** pass. 59 of 59 iterations completed; Machine: 3 cores, 3 induced spinners, load1m 3.1 to 5.2 as observed.\n\nA clean run is one sample from a gentler regime than the one many flakes appear in, not proof of a fix.\n' > "$d/attempt/verify/verdict.md"
  printf 'iteration 4: the target failed\n    ✘ Expectation failed: lock is held\n' > "$d/attempt/verify/failing-lines.txt"
  stub_gh "$d"
  printf '%s' "$d"
}

# routes D [EXISTING_COMMENT_LINES_FILE] [OPEN_PRS_JSON]
routes() {
  local d="$1" comments="${2:-}" open="${3:-[]}"
  [[ -n "$comments" ]] || { comments="$d/comments.jsonl"; : > "$comments"; }
  jq -n --arg c "$comments" --arg open "$open" '[
    {match: "^pr list", out: $open},
    {match: "^pr create", out: "https://github.com/cheapsteak/tbd/pull/77\n"},
    {match: "issues/10/comments\\?per_page", file: $c},
    {match: "labels\\?per_page", out: ""},
    {match: "-X (POST|PATCH)", out: "{}"}
  ]' > "$d/routes.json"
}

# publish D [DIR] [extra env...] -> exit code; output in D/out
publish() {
  local d="$1" dir="${2:-$HERE}" rc=0
  (cd "$d/work" && APP_TOKEN=app-token FLAKE_GH_CMD="$d/gh" FLAKE_PR_REMOTE="$d/origin.git" \
    bash "$dir/flake-pr.sh" open --pick-dir "$d/pick" --attempt-dir "$d/attempt" --repo "$REPO") > "$d/out" 2>&1 || rc=$?
  echo "$rc"
}

remote_head() { git -C "$1/origin.git" rev-parse --verify -q "refs/heads/flakefix/issue-10" || echo none; }
logged() { cat "$1/log"; }
# recorded D [all]: the attempt entry the run recorded (with `all`, every entry
# of the attempt comment it wrote), one JSON object per line.
recorded() {
  grep '  STDIN ' "$1/log" | sed 's/^  STDIN //' | python3 -c '
import json, sys
every = len(sys.argv) > 1
for line in sys.stdin:
    try:
        body = json.loads(line)["body"]
    except Exception:
        continue
    if "flakefix-attempts-state" in body:
        block = body.split("<!-- flakefix-attempts-state\n", 1)[1].split("\nflakefix-attempts-state -->", 1)[0]
        attempts = json.loads(block)["attempts"]
        for a in (attempts if every else attempts[-1:]):
            print(json.dumps(a, sort_keys=True))
' ${2:+"$2"}
}

test_an_incomplete_attempt_publishes_nothing_and_exits_zero() {
  local d; d="$(world)"; routes "$d"
  rm -rf "$d/attempt"; mkdir "$d/attempt"
  assert_eq "exit 0" "0" "$(publish "$d")"
  assert_eq "nothing pushed" "none" "$(remote_head "$d")"
  assert_lacks "no PR" "$(logged "$d")" "pr create"
  assert_eq "recorded aborted" "aborted 4242 0" "$(recorded "$d" | jq -r '"\(.outcome) \(.run_id) \(.episode)"')"
}

test_nothing_picked_publishes_nothing() {
  local d; d="$(world)"; routes "$d"
  rm -rf "$d/pick"; mkdir "$d/pick"
  assert_eq "exit 0" "0" "$(publish "$d")"
  assert_eq "no gh call at all" "" "$(logged "$d")"
}

test_no_diff_comments_and_records_without_pushing() {
  local d; d="$(world)"; routes "$d"
  echo no-diff > "$d/attempt/outcome"; rm -f "$d/attempt/candidate.bundle"
  assert_eq "exit 0" "0" "$(publish "$d")"
  assert_eq "nothing pushed" "none" "$(remote_head "$d")"
  assert_contains "the notes go on the issue" "$(logged "$d")" "SESSION-NOTES"
  assert_contains "a mention is defused" "$(logged "$d")" '@\u200bsomeone'
  assert_eq "recorded no-diff with the notes" "no-diff true" "$(recorded "$d" | jq -r '"\(.outcome) \(.notes | contains("SESSION-NOTES"))"')"
}

test_a_session_failure_abort_is_recorded_as_one() {
  local d mutant; d="$(world)"; routes "$d"
  echo aborted > "$d/attempt/outcome"; rm -f "$d/attempt/candidate.bundle"
  echo "Fixer session 1 (step failure, Claude Code failure) did not finish and left no commit, so nothing was tried." > "$d/attempt/abort_reason"
  echo session > "$d/attempt/abort_kind"
  assert_eq "exit 0" "0" "$(publish "$d")"
  assert_eq "nothing pushed" "none" "$(remote_head "$d")"
  assert_eq "recorded aborted, marked a session failure, saying which" "aborted true true" \
    "$(recorded "$d" | jq -r '"\(.outcome) \(.session_failed) \(.notes | contains("Fixer session 1"))"')"
  mutant="$(mutant_of 's/kind=\(--session-failed\)/kind=()/' "$PR_SH")"
  d="$(world)"; routes "$d"
  echo aborted > "$d/attempt/outcome"; rm -f "$d/attempt/candidate.bundle"; echo x > "$d/attempt/abort_reason"; echo session > "$d/attempt/abort_kind"
  publish "$d" "$mutant" > /dev/null
  assert_eq "mutation: without passing the kind it is an ordinary abort" "aborted null" "$(recorded "$d" | jq -r '"\(.outcome) \(.session_failed)"')"
  d="$(world)"; routes "$d"
  echo aborted > "$d/attempt/outcome"; rm -f "$d/attempt/candidate.bundle"; echo "baseline" > "$d/attempt/abort_reason"
  publish "$d" > /dev/null
  assert_eq "any other abort is not marked" "aborted null" "$(recorded "$d" | jq -r '"\(.outcome) \(.session_failed)"')"
}

test_a_pass_opens_a_draft_and_sets_success() {
  local d log; d="$(world)"; routes "$d"
  assert_eq "exit 0" "0" "$(publish "$d")"
  assert_eq "the candidate is on the branch" "$(cat "$d/attempt/head_sha")" "$(remote_head "$d")"
  log="$(logged "$d")"
  assert_contains "a draft" "$log" "pr create --repo $REPO --draft --base main --head flakefix/issue-10"
  assert_contains "success" "$log" "-f state=success -f context=flakefix/stress"
  assert_contains "on the pushed SHA" "$log" "repos/$REPO/statuses/$(cat "$d/attempt/head_sha")"
  assert_eq "recorded pr-opened" "pr-opened 77 test 59 pass false" "$(recorded "$d" | jq -r '"\(.outcome) \(.pr) \(.scope) \(.n) \(.verdict) \(.weak)"')"
  assert_lacks "a pass posts no failure comment" "$log" "not eligible for ready"
}

FAILED='{"verdict": "fail", "scope": "test", "iterations": 59, "completed": 59, "target_failures": 1, "reasons": ["iteration 4: the target failed"], "other_failures": [], "cores": "3", "spinners": "3", "load1m": "4", "protected": [], "n": 59, "p": 0.05, "cap": 82, "bound": "reached", "false_pass": 0.0485, "weak": false, "scale": null}'
INELIGIBLE='{"verdict": "ineligible", "scope": "test", "iterations": 59, "completed": 59, "target_failures": 0, "reasons": [], "other_failures": [], "cores": "3", "spinners": "3", "load1m": "4", "protected": ["scripts/test.sh"], "n": 59, "p": 0.05, "cap": 82, "bound": "reached", "false_pass": 0.0485, "weak": false, "scale": null}'
WEAK='{"verdict": "pass", "scope": "pass", "iterations": 9, "completed": 9, "target_failures": 0, "reasons": [], "other_failures": ["TBDSharedTests.OtherTests/flaps()"], "cores": "3", "spinners": "3", "load1m": "4", "protected": [], "n": 9, "p": null, "cap": 9, "bound": "unknown", "false_pass": null, "weak": true, "scale": {"0.05": 0.63, "0.15": 0.232}}'
WEAK_CAPPED='{"verdict": "pass", "scope": "test", "iterations": 29, "completed": 29, "target_failures": 0, "reasons": [], "other_failures": [], "cores": "3", "spinners": "3", "load1m": "4", "protected": [], "n": 29, "p": 0.05, "cap": 29, "bound": "not-reached", "false_pass": 0.2259, "weak": true, "scale": null}'

test_a_fail_opens_a_draft_sets_failure_and_comments_the_log() {
  local d log; d="$(world "$FAILED")"; routes "$d"
  assert_eq "exit 0" "0" "$(publish "$d")"
  log="$(logged "$d")"
  assert_contains "still a draft" "$log" "--draft"
  assert_contains "failure" "$log" "-f state=failure -f context=flakefix/stress"
  assert_contains "the issue gets the failing lines" "$log" "Expectation failed: lock is held"
  assert_contains "and the notes" "$log" "SESSION-NOTES"
  assert_eq "recorded with verdict fail" "pr-opened fail" "$(recorded "$d" | jq -r '"\(.outcome) \(.verdict)"')"
}

test_ineligible_sets_failure_not_success() {
  local d mutant log; d="$(world "$INELIGIBLE")"; routes "$d"
  assert_eq "exit 0" "0" "$(publish "$d")"
  log="$(logged "$d")"
  assert_contains "failure, naming the file" "$log" "-f state=failure -f context=flakefix/stress -f description=not eligible for ready, a human must judge: touches scripts/test.sh"
  assert_eq "the attempt records the protected file" '["scripts/test.sh"] pass' "$(recorded "$d" | jq -c '.protected_touched' | tr -d '\n') $(recorded "$d" | jq -r .verdict)"
  mutant="$(mutant_of 's/^    if v == "pass":$/    if v in ("pass", "ineligible"):/' "$PR_PY")"
  d="$(world "$INELIGIBLE")"; routes "$d"; publish "$d" "$mutant" > /dev/null
  assert_contains "mutation: mapping ineligible to success sets success" "$(logged "$d")" "-f state=success"
}

test_the_success_description_states_n_and_never_says_fixed() {
  local d desc; d="$(world)"; routes "$d"
  publish "$d" > /dev/null
  desc="$(grep -o 'description=[^-]*' "$d/log" | head -1)"
  assert_eq "the description" "description=no failure observed in 59 runs " "$desc"
  assert_lacks "never fixed" "$(grep 'statuses' "$d/log")" "fixed"
}

test_a_weak_candidate_gets_the_status_clause_the_label_and_numbers_first() {
  local d log body
  d="$(world "$WEAK")"; routes "$d"
  publish "$d" > /dev/null
  log="$(logged "$d")"
  assert_contains "bound unknown in the status" "$log" "description=no failure observed in 9 runs; weak evidence: bound unknown"
  assert_contains "the label is created" "$log" "flakefix-weak-evidence"
  assert_contains "and added to the PR" "$log" "repos/$REPO/issues/77/labels"
  body="$(grep '^  STDIN ' "$d/log" | sed -n '1,3p')"
  assert_contains "the numbers lead the body" "$body" "**Weak evidence.** scope pass, baseline 1 of 20, p = not measured, N = 9, cap 9, false-pass probability unknown"
  d="$(world "$WEAK_CAPPED")"; routes "$d"
  publish "$d" > /dev/null
  assert_contains "a capped test scope states the no-op pass rate" "$(logged "$d")" "weak evidence: a no-op would pass 22.6% of the time"
  assert_eq "recorded weak, with its false-pass" "true 0.2259" "$(recorded "$d" | jq -r '"\(.weak) \(.false_pass)"')"
}

test_a_strong_candidate_gets_none_of_the_weak_markers() {
  local d log; d="$(world)"; routes "$d"
  publish "$d" > /dev/null
  log="$(logged "$d")"
  assert_lacks "no weak clause" "$log" "weak evidence"
  assert_lacks "no label" "$log" "flakefix-weak-evidence"
  assert_lacks "no lead block" "$log" "**Weak evidence.**"
  assert_contains "the numbers sit under the evidence" "$log" "Numbers: scope test, baseline 1 of 20, p = 0.05, N = 59, cap 82, false-pass probability 4.9%"
}

test_the_pr_body_carries_every_required_field() {
  local d body; d="$(world "$WEAK")"; routes "$d"
  printf '**Stress scope:** pass (the baseline did not reproduce the failure with the test alone).\n\n**Result:** pass. Machine: 3 cores, 3 induced spinners, load1m 4 as observed.\n\n**Other tests that failed in the same iterations**\n\n- `TBDSharedTests.OtherTests/flaps()`\n\nA clean run is one sample from a gentler regime than the one many flakes appear in, not proof of a fix.\n' > "$d/attempt/verify/verdict.md"
  publish "$d" > /dev/null
  body="$(awk '/pr create/{on=1; next} on && /^  STDIN /{sub(/^  STDIN /, ""); print; next} on{exit}' "$d/log")"
  local needle
  for needle in "$HOLDER" "Fixes #10" "## What's broken" "## Why it happens" "## What this PR does" "## Evidence & verification" \
      "session-reported" "SESSION-NOTES" "Fix the lock race" "Stress scope:** pass" "3 cores" "3 induced spinners" "load1m" \
      "TBDSharedTests.OtherTests/flaps()" "not proof of a fix" "https://github.com/$REPO/actions/runs/4242" "3 failures"; do
    assert_contains "the body has: $needle" "$body" "$needle"
  done
  assert_lacks "the target comes from the pick, not the session-reachable candidate" "$body" "TAMPERED-TARGET"
}

test_every_write_uses_the_app_token() {
  local d writes; d="$(world "$WEAK")"; routes "$d"
  publish "$d" > /dev/null
  writes="$(grep -E -- '-X (POST|PATCH)|pr create' "$d/log")"
  assert_contains "there are writes" "$writes" "pr create"
  assert_eq "each one under the App token" "" "$(grep -v '^app-token ' <<< "$writes")"
  assert_eq "and every read too" "" "$(grep -v '^  STDIN' "$d/log" | grep -v '^app-token ')"
}

test_publish_refuses_without_the_app_token() {
  local d rc=0; d="$(world)"; routes "$d"
  (cd "$d/work" && APP_TOKEN='' FLAKE_GH_CMD="$d/gh" FLAKE_PR_REMOTE="$d/origin.git" \
    bash "$PR_SH" open --pick-dir "$d/pick" --attempt-dir "$d/attempt" --repo "$REPO") > /dev/null 2>&1 || rc=$?
  assert_eq "exit 2" "2" "$rc"
  assert_eq "no call" "" "$(logged "$d")"
}

existing_attempts() { # D LOGIN TYPE -> a comments file holding one attempt comment
  local d="$1" f="$1/comments.jsonl"
  python3 - "$HERE" "$2" "$3" > "$f" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import flake_lib as fl
old = fl.Attempt(run_id=1111, started_at="2026-10-01T06:00:00Z", main_sha="a" * 40, episode=0, outcome="no-diff")
print(json.dumps({"id": 555, "body": fl.render_attempts([old], "cheapsteak/tbd"), "user": {"login": sys.argv[2], "type": sys.argv[3]}}))
PY
  printf '%s' "$f"
}

test_the_attempt_comment_is_created_once_then_edited() {
  local d; d="$(world)"; routes "$d"
  publish "$d" > /dev/null
  assert_contains "first attempt: created" "$(logged "$d")" "-X POST repos/$REPO/issues/10/comments"
  d="$(world)"; routes "$d" "$(existing_attempts "$d" "$BOT" Bot)"
  publish "$d" > /dev/null
  assert_contains "later: the bot's own comment is edited" "$(logged "$d")" "-X PATCH repos/$REPO/issues/comments/555"
  assert_contains "keeping the earlier entry" "$(grep 'STDIN' "$d/log" | grep flakefix-attempts-state)" "1111"
}

test_a_rerun_replaces_its_own_entry() {
  local d f; d="$(world)"; f="$d/comments.jsonl"
  python3 - "$HERE" > "$f" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import flake_lib as fl
old = fl.Attempt(run_id=4242, started_at="2026-10-08T06:00:00Z", main_sha="a" * 40, episode=0, outcome="aborted")
print(json.dumps({"id": 555, "body": fl.render_attempts([old], "cheapsteak/tbd"), "user": {"login": "tbd-flake-fixer[bot]", "type": "Bot"}}))
PY
  routes "$d" "$f"
  publish "$d" > /dev/null
  assert_contains "its own comment is edited" "$(logged "$d")" "-X PATCH repos/$REPO/issues/comments/555"
  assert_eq "one entry for run 4242, now pr-opened" "4242 pr-opened" "$(recorded "$d" all | jq -r '"\(.run_id) \(.outcome)"')"
}

test_an_attempt_comment_by_another_author_is_not_edited() {
  local d; d="$(world)"; routes "$d" "$(existing_attempts "$d" mallory User)"
  publish "$d" > /dev/null
  assert_lacks "the forged comment is left alone" "$(logged "$d")" "issues/comments/555"
  assert_contains "a new one is created" "$(logged "$d")" "-X POST repos/$REPO/issues/10/comments"
  d="$(world)"; routes "$d" "$(existing_attempts "$d" "tbd-flake-fixer" User)"
  publish "$d" > /dev/null
  assert_lacks "a look-alike login too" "$(logged "$d")" "issues/comments/555"
}

# reject_pushes D MESSAGE [PATH_REGEX]: a pre-receive hook refusing a push that
# changes a path matching PATH_REGEX (every push without one).
reject_pushes() {
  local d="$1" msg="$2" re="${3:-.}"
  # The message goes through a file: GitHub's text holds backticks, which the
  # unquoted heredoc below would run as commands.
  printf '%s\n' "$msg" > "$d/reject-message"
  cat > "$d/origin.git/hooks/pre-receive" <<EOF
#!/usr/bin/env bash
while read -r old new ref; do
  if git diff --name-only $(cat "$d/pick/base_sha") "\$new" | grep -qE '$re'; then
    cat "$d/reject-message" >&2
    exit 1
  fi
done
EOF
  chmod +x "$d/origin.git/hooks/pre-receive"
}

test_a_rejected_push_opens_no_pr_and_says_why() {
  local d rc log
  d="$(CANDIDATE_PATH=.github/workflows/test.yml world)"; routes "$d"
  reject_pushes "$d" 'refusing to allow a GitHub App to create or update workflow `.github/workflows/test.yml` without `workflows` permission' '^\.github/workflows/'
  rc="$(publish "$d")"
  log="$(logged "$d")"
  assert_eq "recorded, exit 0" "0" "$rc"
  assert_lacks "no PR" "$log" "pr create"
  assert_contains "the issue is told it needs a workflow change" "$log" "appears to need a workflow change, which is a human's job"
  assert_eq "recorded push-refused" "push-refused" "$(recorded "$d" | jq -r .outcome)"
  d="$(world)"; routes "$d"
  reject_pushes "$d" 'pre-receive hook declined: protected branch'
  rc="$(publish "$d")"
  assert_eq "another rejection is recorded but the run goes red" "1" "$rc"
  assert_contains "and says it was not a workflow change" "$(logged "$d")" "for a reason other than a workflow change"
  assert_lacks "with no PR" "$(logged "$d")" "pr create"
  assert_eq "recorded push-refused" "push-refused" "$(recorded "$d" | jq -r .outcome)"
}

# A candidate that touches .github/workflows/ but is refused for another
# reason (here a hook, as a lease or protection rule would) is not a workflow
# refusal: only GitHub's permission text says that.
test_a_workflow_candidate_refused_for_another_reason_goes_red() {
  local d rc mutant
  d="$(CANDIDATE_PATH=.github/workflows/test.yml world)"; routes "$d"
  reject_pushes "$d" 'pre-receive hook declined: stale info'
  rc="$(publish "$d")"
  assert_eq "the run goes red" "1" "$rc"
  assert_contains "and says it was not a workflow change" "$(logged "$d")" "for a reason other than a workflow change"
  assert_lacks "it does not blame the workflow permission" "$(logged "$d")" "appears to need a workflow change"
  assert_eq "recorded push-refused" "push-refused" "$(recorded "$d" | jq -r .outcome)"
  mutant="$(mutant_of 's#if grep -qiE "\$WORKFLOW_REFUSAL" "\$err"; then#if grep -qiE "$WORKFLOW_REFUSAL" "$err" || git diff --name-only "$base" "$head" | grep -q "^\\.github/workflows/"; then#' "$PR_SH")"
  d="$(CANDIDATE_PATH=.github/workflows/test.yml world)"; routes "$d"
  reject_pushes "$d" 'pre-receive hook declined: stale info'
  assert_eq "mutation: classifying on the diff turns it green" "0" "$(publish "$d" "$mutant")"
}

test_a_stale_branch_is_replaced_deliberately() {
  local d old; d="$(world)"; routes "$d"
  git -C "$d/session" push -q "$d/origin.git" "HEAD~1:refs/heads/flakefix/issue-10" 2>/dev/null
  old="$(remote_head "$d")"
  assert_eq "exit 0" "0" "$(publish "$d")"
  assert_eq "the branch now carries the candidate" "$(cat "$d/attempt/head_sha")" "$(remote_head "$d")"
  assert_contains "and the log says what it replaced" "$(cat "$d/out")" "replacing the stale branch flakefix/issue-10 (at $old)"
}

test_an_open_pr_on_the_branch_is_never_pushed_over() {
  local d; d="$(world)"
  routes "$d" "" '[{"number": 70, "headRefOid": "0000000000000000000000000000000000000000"}]'
  assert_eq "exit 0" "0" "$(publish "$d")"
  assert_eq "nothing pushed" "none" "$(remote_head "$d")"
  assert_eq "recorded aborted" "aborted" "$(recorded "$d" | jq -r .outcome)"
  d="$(world)"
  routes "$d" "" "[{\"number\": 77, \"headRefOid\": \"$(cat "$d/attempt/head_sha")\"}]"
  assert_eq "a re-run: exit 0" "0" "$(publish "$d")"
  assert_lacks "it opens no second PR" "$(logged "$d")" "pr create"
  assert_eq "and records the open PR" "pr-opened 77" "$(recorded "$d" | jq -r '"\(.outcome) \(.pr)"')"
}

test_a_bundle_whose_tip_does_not_match_is_refused() {
  local d rc; d="$(world)"; routes "$d"
  echo 1111111111111111111111111111111111111111 > "$d/attempt/head_sha"
  rc="$(publish "$d")"
  assert_eq "exit 2" "2" "$rc"
  assert_eq "nothing pushed" "none" "$(remote_head "$d")"
  assert_contains "says why" "$(cat "$d/out")" "is not the recorded head"
}

# fail_route D MATCH: the route whose match is MATCH now exits 1.
fail_route() { jq --arg m "$2" '[.[] | if .match == $m then .exit = 1 else . end]' "$1/routes.json" > "$1/r2" && mv "$1/r2" "$1/routes.json"; }

test_a_failure_after_the_push_still_records_the_attempt() {
  local d mutant; d="$(world)"; routes "$d"; fail_route "$d" "^pr create"
  assert_eq "a failed PR create exits 2" "2" "$(publish "$d")"
  assert_eq "after the branch was pushed" "$(cat "$d/attempt/head_sha")" "$(remote_head "$d")"
  assert_eq "and records aborted, saying so" "aborted true" "$(recorded "$d" | jq -r '"\(.outcome) \(.notes | contains("then publishing failed"))"')"
  d="$(world)"; routes "$d"
  jq '[{match: "statuses", exit: 1}] + .' "$d/routes.json" > "$d/r2" && mv "$d/r2" "$d/routes.json"
  assert_eq "a failed status after the PR exits 2" "2" "$(publish "$d")"
  assert_eq "and records the open PR, so a later close is tied to it" "pr-opened 77" "$(recorded "$d" | jq -r '"\(.outcome) \(.pr)"')"
  mutant="$(mutant_of 's/^  if \[\[ -n "\$ISSUE" \&\& -z "\$RECORDING" \]\]; then$/  if false; then/' "$PR_SH")"
  d="$(world)"; routes "$d"; fail_route "$d" "^pr create"
  publish "$d" "$mutant" > /dev/null
  assert_eq "mutation: without it nothing is recorded" "" "$(recorded "$d")"
}

test_a_failure_before_the_push_records_aborted() {
  local d; d="$(world)"; routes "$d"; fail_route "$d" "^pr list"
  assert_eq "a failed PR listing exits 2" "2" "$(publish "$d")"
  assert_eq "nothing pushed" "none" "$(remote_head "$d")"
  assert_eq "recorded aborted, saying where" "aborted true" "$(recorded "$d" | jq -r '"\(.outcome) \(.notes | contains("before any push"))"')"
}

test_an_unparsable_pr_url_is_found_by_branch() {
  local d; d="$(world)"
  routes "$d"
  jq '[{match: "^pr create", out: "created, somewhere\n"}, {match: "^pr list .*--jq", out: "88\n"}] + .' "$d/routes.json" > "$d/r2" && mv "$d/r2" "$d/routes.json"
  assert_eq "exit 0" "0" "$(publish "$d")"
  assert_eq "the attempt is tied to the PR on the branch" "pr-opened 88" "$(recorded "$d" | jq -r '"\(.outcome) \(.pr)"')"
}

test_session_text_closes_and_mentions_nothing() {
  local d body; d="$(world)"; routes "$d"
  printf 'Fixed it. fixes #519, closes https://github.com/%s/issues/412\n' "$REPO" > "$d/attempt/flakefix-notes.md"
  printf 'Result: pass. resolves #77\n' > "$d/attempt/verify/verdict.md"
  publish "$d" > /dev/null
  body="$(awk '/pr create/{on=1; next} on && /^  STDIN /{sub(/^  STDIN /, ""); print; next} on{exit}' "$d/log")"
  assert_contains "the bot's own closing reference stays" "$body" "Fixes #10"
  assert_lacks "a session's does not" "$body" "fixes #519"
  assert_lacks "nor an issue URL" "$body" "issues/412"
  assert_lacks "nor one in the verdict text" "$body" "resolves #77"
}

test_a_rerun_on_its_open_pr_posts_no_second_comment() {
  local d; d="$(world "$FAILED")"
  routes "$d" "" "[{\"number\": 77, \"headRefOid\": \"$(cat "$d/attempt/head_sha")\"}]"
  publish "$d" > /dev/null
  assert_lacks "no duplicate failure comment" "$(logged "$d")" "not eligible for ready"
  assert_eq "the attempt is still recorded" "pr-opened 77" "$(recorded "$d" | jq -r '"\(.outcome) \(.pr)"')"
}

test_the_run_link_comes_from_the_pick() {
  local d; d="$(world "$FAILED")"; routes "$d"
  echo "https://attacker.example/x" > "$d/attempt/run_url"
  publish "$d" > /dev/null
  assert_lacks "a session-written link is never posted" "$(logged "$d")" "attacker.example"
  assert_contains "the status links the fix run" "$(logged "$d")" "target_url=https://github.com/$REPO/actions/runs/4242"
}

test_the_attempt_comment_stays_under_the_body_limit() {
  local out
  out="$(python3 - "$HERE" <<'PY'
import importlib.util, sys
sys.path.insert(0, sys.argv[1])
import flake_lib as fl
spec = importlib.util.spec_from_file_location("flake_pr", sys.argv[1] + "/flake-pr.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
attempts = [fl.Attempt(run_id=i, started_at=f"2026-{1 + i // 28:02d}-{1 + i % 28:02d}T06:00:00Z", main_sha="a" * 40,
                       episode=0, outcome="no-diff", notes="x" * fl.ATTEMPT_NOTES_CHARS) for i in range(60)]
body = m.render_bounded(attempts, "cheapsteak/tbd")
kept = fl.parse_attempts(body, fl.BOT_LOGIN, "Bot")
print(len(body) <= fl.MAX_COMMENT_CHARS, len(kept), kept[0].notes == "", kept[-1].notes != "")
PY
)"
  assert_eq "under the limit, every entry kept, oldest notes blanked first" "True 60 True True" "$out"
}

test_a_candidate_with_no_verdict_is_aborted() {
  local d; d="$(world)"; routes "$d"
  rm -f "$d/attempt/verify/verdict.json"
  assert_eq "exit 0" "0" "$(publish "$d")"
  assert_eq "nothing pushed" "none" "$(remote_head "$d")"
  assert_eq "recorded aborted" "aborted" "$(recorded "$d" | jq -r .outcome)"
}

# ============================================================================
# flake-fixer.yml: the fix and publish jobs (text checks; no YAML parser)
# ============================================================================

job_block() { awk -v name="$2" '$0 ~ "^  " name ":$" {p = 1; print; next} p && /^  [a-z]/ {exit} p' "$1"; }
# step FILE JOB NAME: the step whose `- name:` contains NAME, to the next step.
step() {
  job_block "$1" "$2" | awk -v name="$3" '
    /^      - / { inside = (index($0, "- name: " name) > 0) }
    inside { print }'
}
# mutated OLD NEW [all]: a copy of the workflow with the first (or every)
# literal OLD replaced by NEW. Python rather than sed: BSD sed has no `0,/re/`
# address and no `\n` in a replacement, and this harness runs on both.
mutated() {
  local c; c="$(mktmpd)/wf.yml"
  python3 - "$WORKFLOW" "$c" "$1" "$2" "${3:-first}" <<'PY'
import sys
src, dst, old, new, how = sys.argv[1:]
text = open(src).read()
open(dst, "w").write(text.replace(old, new) if how == "all" else text.replace(old, new, 1))
PY
  cmp -s "$c" "$WORKFLOW" && { echo "FAIL - mutation [$1] did not change the workflow" >&2; FAIL=1; }
  printf '%s' "$c"
}
# check NAME FUNC OLD NEW [all]: FUNC passes on the workflow and fails on the mutant.
# FUNC runs without pipefail: its `awk … | grep -q` pipelines end when grep has
# its answer, and the SIGPIPE awk then takes would otherwise be the verdict.
check() {
  local rc=0 mutant
  ( set +o pipefail; "$2" "$WORKFLOW" ) || rc=$?
  assert_eq "$1" "0" "$rc"
  mutant="$(mutated "$3" "$4" "${5:-first}")"
  rc=0; ( set +o pipefail; "$2" "$mutant" ) || rc=$?
  assert_eq "mutation: $1 fails without it" "1" "$rc"
}

fix_permissions() {
  local perms
  perms="$(job_block "$1" fix | awk '/^    permissions:/{p=1; next} p && /^    [a-z]/{exit} p')"
  [[ -n "$perms" ]] && ! grep -qE 'write|id-token' <<< "$perms" && grep -q 'contents: read' <<< "$perms"
}
test_the_fix_job_has_no_write_permission_and_no_id_token() {
  check "fix grants read scopes only" fix_permissions $'      contents: read\n      issues: read\n      pull-requests: read\n      actions: read\n    env:' $'      contents: read\n      issues: read\n      pull-requests: read\n      actions: read\n      id-token: write\n    env:'
}

fix_no_app_secret() { ! job_block "$1" fix | grep -qE 'FLAKE_FIXER_APP|create-github-app-token'; }
test_the_fix_job_never_sees_the_app_secrets() {
  check "fix never references the App" fix_no_app_secret '      - name: Refuse to run without the ledger' $'      - uses: actions/create-github-app-token@v2\n      - name: Refuse to run without the ledger'
  assert_contains "publish mints it" "$(job_block "$WORKFLOW" publish)" "secrets.FLAKE_FIXER_APP_PRIVATE_KEY"
}

checkouts_drop_credentials() {
  local n m
  n="$(grep -c 'uses: actions/checkout' "$1")"
  m="$(grep -A6 'uses: actions/checkout' "$1" | grep -c 'persist-credentials: false')"
  [[ "$n" -gt 0 && "$n" == "$m" ]]
}
test_every_checkout_drops_credentials() { check "every checkout drops credentials" checkouts_drop_credentials 'persist-credentials: false' 'persist-credentials: true'; }

session_token() {
  local s
  for s in "Fixer session 1" "Fixer session 2"; do
    step "$1" fix "$s" | grep -q 'github_token: ${{ github.token }}' || return 1
  done
}
test_the_session_gets_the_read_only_token_explicitly() { check "both sessions get github_token explicitly" session_token 'github_token: ${{ github.token }}' 'show_full_output: false'; }

tools_clean() {
  local tools
  tools="$(job_block "$1" fix | grep -- '--allowedTools')"
  [[ "$(wc -l <<< "$tools" | tr -d ' ')" == 2 ]] || return 1
  ! grep -qE 'WebFetch|WebSearch|curl|wget|Bash\(gh|Bash,|Bash"|git push|git fetch|nc |ssh' <<< "$tools"
}
test_the_session_tool_list_has_no_network_tools() { check "no network tool is allowed" tools_clean 'Read,Write,Edit' 'Read,Write,Edit,WebFetch'; }


# Every verifier call runs from main's pre-session copy ($VS) or the private
# copy an End session step makes of it ($own), never from the session tree.
verifier_from_copy() {
  local calls
  calls="$(job_block "$1" fix | grep -E 'flake-verify\.(sh|py)|flake-pick\.py' | grep -vE '^\s*#')"
  [[ -n "$calls" ]] && ! grep -vE '"\$(VS|own/vs)/scripts/flake-(verify\.(sh|py)|pick\.py)"' <<< "$calls" | grep -q .
}
test_every_verifier_call_runs_from_the_pre_session_copy() { check "every verifier call uses \$VS" verifier_from_copy 'bash "$VS/scripts/flake-verify.sh" apply-candidate' 'bash scripts/flake-verify.sh apply-candidate'; }

verify_in_tree() {
  local s
  for s in "Build the verification tree" "Pre-fix baseline" "Stress try 1" "Stress try 2"; do
    step "$1" fix "$s" | grep -q 'working-directory: ${{ runner.temp }}/flakefix-verify$' || return 1
  done
}
test_every_test_running_verifier_step_runs_in_the_verification_tree() { check "builds, baseline and stress run in the verification tree" verify_in_tree 'working-directory: ${{ runner.temp }}/flakefix-verify' 'working-directory: ${{ env.VT }}'; }

applied_first() {
  local s block
  for s in "Stress try 1" "Stress try 2"; do
    block="$(step "$1" fix "$s")"
    awk '/flake-verify.sh" apply-candidate/{a=NR} /flake-verify.sh" stress/{s=NR} END{exit !(a && s && a < s)}' <<< "$block" || return 1
  done
}
test_the_candidate_is_applied_before_it_is_stressed() { check "apply-candidate precedes stress" applied_first 'flake-verify.sh" apply-candidate' 'flake-verify.sh" true'; }


# Each End session step: the private copy is fingerprinted, the snapshot copied
# and hash-checked, the kill run from the copy, the verification tree's digest
# checked once nothing of the session is left, then planted results removed.
end_step_ok() {
  local block
  block="$(step "$1" fix "End session $2")"
  awk -v snap="cp \"\$T/procs-before-$2\" \"\$own/procs-before\"" '
    index($0, snap) {c=NR}
    /\[ "\$\(fingerprint "\$own\/vs"\)" = "\$VS_SUM" \]/ {f=NR}
    /SNAP_SUM/ {h=NR}
    /bash "\$own\/vs\/scripts\/flake-verify.sh" end-session-processes --before "\$own\/procs-before"/ {k=NR}
    /tree-digest "\$VT"\)" = "\$VT_SUM" \]/ {t=NR}
    /rm -rf "\$T\/verify/ {r=NR}
    END {exit !(c && f && h && k && t && r && c < k && f < k && h < k && k < t && t < r)}' <<< "$block"
}
ended_before_verify() {
  local job
  job="$(job_block "$1" fix)"
  awk '/name: End session 1/{e1=NR} /name: Stress try 1/{v1=NR} /name: End session 2/{e2=NR} /name: Stress try 2/{v2=NR}
       /name: Snapshot processes before session 1/{s1=NR} /name: Fixer session 1/{f1=NR}
       /name: Snapshot processes before session 2/{s2=NR} /name: Fixer session 2/{f2=NR}
       END{exit !(s1 < f1 && f1 < e1 && e1 < v1 && s2 < f2 && f2 < e2 && e2 < v2)}' <<< "$job" &&
    end_step_ok "$1" 1 && end_step_ok "$1" 2
}
test_session_processes_are_ended_before_each_verify() { check "processes end, from a checked private copy, between each session and its verify" ended_before_verify 'cp "$T/procs-before-2" "$own/procs-before"' 'true'; }

# The attempt lock: the whole run, from pick to publish, for every trigger that
# can start `fix`, never cancelling a run in progress; no job-level group on
# fix or publish, where GitHub could cancel a pending publish.
LOCK_EXPR="group: \${{ (github.event_name == 'schedule' || (github.event_name == 'workflow_dispatch' && inputs.job == 'fix')) && 'flake-fixer-attempt' || format('flake-fixer-run-{0}', github.run_id) }}"
attempt_lock() {
  local top
  top="$(awk '/^concurrency:$/{p=1; print; next} p && /^[^ ]/{exit} p' "$1")"
  grep -qF "  $LOCK_EXPR" <<< "$top" &&
    grep -q '^  cancel-in-progress: false$' <<< "$top" &&
    ! job_block "$1" fix | grep -q 'concurrency:' &&
    ! job_block "$1" publish | grep -q 'concurrency:'
}
test_one_attempt_holds_the_lock_from_pick_to_publish() {
  check "the run-level attempt lock covers fix and publish" attempt_lock "$LOCK_EXPR" "group: flake-fixer-\${{ github.run_id }}"
  local c
  c="$(mutated $'  cancel-in-progress: false\n\njobs:' $'  cancel-in-progress: true\n\njobs:')"
  if ( set +o pipefail; attempt_lock "$c" ); then echo "FAIL - mutation: a cancelling lock passes"; FAIL=1; else echo "ok   - mutation: a cancelling lock fails"; fi
  c="$(mutated '    # No job-level concurrency group: the run already holds' $'    concurrency:\n      group: flake-fixer-publish\n    # No job-level concurrency group: the run already holds')"
  if ( set +o pipefail; attempt_lock "$c" ); then echo "FAIL - mutation: a publish job group passes"; FAIL=1; else echo "ok   - mutation: a publish job group fails"; fi
}

publish_always() {
  local job open
  job="$(job_block "$1" publish)"
  open="$(step "$1" publish "Push, open the draft PR")"
  grep -q "if: always() && vars.FLAKE_FIXER_ENABLED == 'true'" <<< "$job" &&
    grep -q "needs.fix.result != 'skipped'" <<< "$job" &&
    ! grep -q 'if:.*download' <<< "$open" &&
    grep -q -- '--pick-dir' <<< "$open"
}
test_publish_records_aborted_without_an_artifact() { check "publish runs after any fix outcome and reads the pick" publish_always "if: always() && vars.FLAKE_FIXER_ENABLED == 'true' && github.repository" "if: success() && vars.FLAKE_FIXER_ENABLED == 'true' && github.repository"; }

pick_persisted_early() {
  local job
  job="$(job_block "$1" fix)"
  awk '/name: Pick tonight/{p=NR} /name: Persist the pick/{u=NR} /name: Build the session tree/{b=NR} END{exit !(p && u && p < u && u < b)}' <<< "$job" &&
    step "$1" fix "Persist the pick" | grep -q 'name: flakefix-pick$'
}
test_the_pick_is_persisted_before_anything_slow() { check "the pick is uploaded right after picking" pick_persisted_early 'name: flakefix-pick
          path: ${{ runner.temp }}' 'name: other
          path: ${{ runner.temp }}'; }


# The fingerprint function, as written in the step that takes the sum.
fingerprint_fn() { step "$1" fix "Fingerprint the verifier copy" | grep -E '^ +fingerprint\(\) \{' | sed 's/^ *//'; }

test_the_verifier_fingerprint_sees_edits_new_files_and_symlinks() {
  local fn vs a b c d
  fn="$(fingerprint_fn "$WORKFLOW")"
  assert_contains "the fingerprint is written in the workflow" "$fn" 'fingerprint() {'
  assert_eq "every step that fingerprints uses the same function" "3" "$(grep -cF -- "$fn" "$WORKFLOW")"
  assert_eq "and none takes it from the environment" "0" "$(grep -c 'VS_FINGERPRINT' "$WORKFLOW")"
  vs="$(mktmpd)"; mkdir -p "$vs/scripts"; echo one > "$vs/scripts/flake-verify.sh"
  a="$(bash -c "$fn"'; fingerprint "$1"' _ "$vs")"
  assert_eq "stable" "$a" "$(bash -c "$fn"'; fingerprint "$1"' _ "$vs")"
  echo two > "$vs/scripts/flake-verify.sh"; b="$(bash -c "$fn"'; fingerprint "$1"' _ "$vs")"
  assert_lacks "an edit changes it" "$b" "$a"
  ln -s /dev/null "$vs/scripts/json.py"; c="$(bash -c "$fn"'; fingerprint "$1"' _ "$vs")"
  assert_lacks "a planted symlink changes it" "$c" "$b"
  rm "$vs/scripts/json.py"; ln -s /dev/zero "$vs/scripts/json.py"; d="$(bash -c "$fn"'; fingerprint "$1"' _ "$vs")"
  assert_lacks "and so does retargeting one" "$d" "$c"
  assert_eq "a copy fingerprints the same as its source" "$d" "$(e="$(mktmpd)"; cp -R "$vs/." "$e/"; bash -c "$fn"'; fingerprint "$1"' _ "$e")"
}


package_needs_collected_commits() {
  local block
  block="$(step "$1" fix "Package the attempt")"
  grep -qF 'C1: ${{ steps.c1.outcome }}' <<< "$block" && grep -qF '[ "$C1" != success ]' <<< "$block"
}
test_no_diff_needs_session_one_collected() { check "no-diff only once session 1's commits were collected" package_needs_collected_commits '[ "$C1" != success ]' '[ "$C1" = never ]'; }

# package_run FILE RT VAR=VALUE...: run FILE's "Package the attempt" step in
# RT, with the step's env as given. Prints the exit code.
package_run() {
  local wf="$1" rt="$2" rc=0
  shift 2
  step_script "$wf" "Package the attempt" | sed "s|\${{ runner.temp }}|$rt|g" > "$rt/package.sh"
  : > "$rt/out"; : > "$rt/summary"
  env -i PATH="$PATH" GITHUB_OUTPUT="$rt/out" GITHUB_STEP_SUMMARY="$rt/summary" \
    C1= TRY2=false C2= S1= S1_CONCLUSION= S2= S2_CONCLUSION= "$@" \
    /bin/bash --noprofile --norc -p -eo pipefail "$rt/package.sh" > "$rt/log" 2>&1 || rc=$?
  echo "$rc"
}
# package_outcome FILE S1 S1_CONCLUSION: what Package records for a finished
# baseline, session 1's commits collected, and no commit.
package_outcome() {
  local rt; rt="$(mktmpd)"; mkdir -p "$rt/flakefix"; echo '{"n": 45}' > "$rt/flakefix/plan.json"
  package_run "$1" "$rt" C1=success S1="$2" S1_CONCLUSION="$3" > /dev/null
  printf '%s|%s|%s|%s' "$(cat "$rt/flakefix/outcome")" "$(cat "$rt/flakefix/abort_kind" 2>/dev/null)" \
    "$(grep -c '^session_failed=true$' "$rt/out")" "$(cat "$rt/flakefix/abort_reason" 2>/dev/null)"
}
session_failure_is_aborted() {
  local got
  got="$(package_outcome "$1" success failure)"
  [[ "$got" == "aborted|session|1|Fixer session 1 (step success, Claude Code failure)"* ]] || return 1
  got="$(package_outcome "$1" failure "")"
  [[ "$got" == "aborted|session|1|Fixer session 1 (step failure, Claude Code reported nothing)"* ]] || return 1
  # The session that ran and committed nothing is still no-diff.
  [[ "$(package_outcome "$1" success success)" == "no-diff|"*"|0|" ]]
}
# A failed session 2 after try 1's candidate: the candidate stands, and the
# job still ends red.
failed_session_two_ends_red() {
  local rt; rt="$(mktmpd)"; mkdir -p "$rt/flakefix"; echo '{"n": 45}' > "$rt/flakefix/plan.json"
  echo bundle > "$rt/flakefix/candidate.bundle"
  package_run "$1" "$rt" C1=success C2=success TRY2=true S1=success S1_CONCLUSION=success S2=success S2_CONCLUSION=failure > /dev/null
  [[ "$(cat "$rt/flakefix/outcome")" == candidate && ! -e "$rt/flakefix/abort_kind" ]] && grep -q '^session_failed=true$' "$rt/out"
}
# A step before session 1 failed (run 37845177223: the environment record), so
# session 1 was skipped: aborted on that step, and no session counts as failed.
skipped_session_is_no_failure() {
  local rt; rt="$(mktmpd)"; mkdir -p "$rt/flakefix"; echo '{"n": 45}' > "$rt/flakefix/plan.json"
  package_run "$1" "$rt" C1=skipped S1=skipped S1_CONCLUSION= > /dev/null
  [[ "$(cat "$rt/flakefix/outcome")" == aborted && ! -e "$rt/flakefix/abort_kind" ]] &&
    grep -q "before a session's commits were collected" "$rt/flakefix/abort_reason" &&
    ! grep -q '^session_failed=true$' "$rt/out" && ! grep -q 'Fixer session' "$rt/summary"
}
# The same for session 2: a step that prepares try 2 failed, so it was skipped.
skipped_session_two_is_no_failure() {
  local rt; rt="$(mktmpd)"; mkdir -p "$rt/flakefix"; echo '{"n": 45}' > "$rt/flakefix/plan.json"
  package_run "$1" "$rt" C1=success TRY2=true C2=skipped S1=success S1_CONCLUSION=success S2=skipped S2_CONCLUSION= > /dev/null
  [[ "$(cat "$rt/flakefix/outcome")" == aborted && ! -e "$rt/flakefix/abort_kind" ]] &&
    ! grep -q '^session_failed=true$' "$rt/out" && ! grep -q 'Fixer session' "$rt/summary"
}
test_a_session_that_never_ran_is_not_a_failed_session() {
  check "a skipped session is no failed session" skipped_session_is_no_failure \
    'if [ "$S1" != skipped ] && { [ "$S1" != success ]' 'if { [ "$S1" != success ]'
  check "nor a skipped session 2" skipped_session_two_is_no_failure \
    '[ "$TRY2" = true ] && [ "$S2" != skipped ] && {' '[ "$TRY2" = true ] && {'
}

test_a_failed_session_with_no_commit_is_aborted_not_no_diff() {
  check "a failed or never-finished session with no commit is aborted, kind session" session_failure_is_aborted \
    'elif [ -n "$failed_session" ]; then' 'elif false; then'
  check "a failed session 2 keeps try 1's candidate and still ends the job red" failed_session_two_ends_red \
    '          if [ -n "$failed_session" ]; then
            echo "Fixer session $failed_session failed."' '          if false; then
            echo "Fixer session $failed_session failed."'
  local job
  job="$(job_block "$WORKFLOW" fix)"
  assert_contains "the step reads session 1's outcome" "$job" 'S1: ${{ steps.s1.outcome }}'
  assert_contains "and the action's conclusion" "$job" 'S1_CONCLUSION: ${{ fromJSON(toJSON(steps.s1.outputs)).conclusion }}'
  assert_contains "and session 2's" "$job" 'S2_CONCLUSION: ${{ fromJSON(toJSON(steps.s2.outputs)).conclusion }}'
  assert_contains "session 1 has the id it reads" "$(step "$WORKFLOW" fix "Fixer session 1")" 'id: s1'
  assert_contains "and session 2" "$(step "$WORKFLOW" fix "Fixer session 2")" 'id: s2'
  assert_contains "the job ends red on it" "$(step "$WORKFLOW" fix "End red when a session failed")" \
    "if: always() && steps.package.outputs.session_failed == 'true'"
}

unchanged_try2_keeps_try1() {
  local block
  block="$(step "$1" fix "End session 2")"
  grep -qF '[ "$(git rev-parse HEAD)" = "$TRY1_HEAD" ]' <<< "$block" &&
    grep -qF 'mv "$T/verify-1" "$T/verify"' <<< "$block" && grep -qF 'echo "commits=0"' <<< "$block"
}
test_an_unchanged_second_try_keeps_the_first_verdict() { check "an unchanged try 2 is not stressed again" unchanged_try2_keeps_try1 'mv "$T/verify-1" "$T/verify"' 'true'; }

restores_without_following_links() {
  local i block
  for i in 1 2; do
    block="$(step "$1" fix "End session $i")"
    awk '/rm -rf "\$T\/baseline" "\$T\/plan.json"/{r=NR} /> "\$T\/plan.json"/{w=NR} END{exit !(r && w && r < w)}' <<< "$block" || return 1
  done
}
test_measured_records_are_restored_without_following_links() { check "records are removed before they are rewritten" restores_without_following_links 'rm -rf "$T/baseline" "$T/plan.json"' 'true "$T/baseline" "$T/plan.json"' all; }

bot_login_checked() { step "$1" publish "Check the App token's bot login" | grep -q 'scripts/flake_lib.py check-app-slug'; }
test_publish_checks_the_app_login() { check "publish checks the App's login" bot_login_checked 'scripts/flake_lib.py check-app-slug' 'echo x' all; }


# ============================================================================
# flake-fixer.yml: the End session steps, run (not read) against a fake attempt
# ============================================================================

# step_script FILE NAME: the `run:` body of the fix job's step NAME, with
# `${{ runner.temp }}` left for the caller to substitute.
step_script() { step "$1" fix "$2" | awk '/^        run: \|$/{p=1; next} p && /^      - /{exit} p' | sed -E 's/^ {10}//'; }
# step_shell FILE NAME: the step's `shell:`, its {0} left in place.
step_shell() { step "$1" fix "$2" | sed -n 's/^        shell: //p'; }

# The failing verdict try 1 measured, and the passing one a session plants.
VERDICT_FAIL='{"verdict": "fail", "weak": false}'
VERDICT_PASS='{"verdict": "pass", "weak": false}'

# end_world I: a fake attempt as session I left it, under a fresh runner.temp,
# whose path it prints. The sums taken before the session are in RT/sums.
end_world() {
  local i="$1" rt ws t vs vt
  rt="$(mktmpd)"; ws="$rt/ws"; t="$rt/flakefix"; vs="$rt/flakefix-verifier-scripts"; vt="$rt/flakefix-verify"
  mkdir -p "$t/pick" "$vs/scripts" "$vt/.git" "$vt/.build/debug" "$rt/tmp" "$rt/bin"
  cp "$HERE/flake-verify.sh" "$HERE/flake-verify.py" "$HERE/flake_lib.py" "$vs/scripts/"
  echo '[core]' > "$vt/.git/config"; echo built > "$vt/.build/debug/TBDTests"
  # One process, already in the snapshot: the kill has nothing to end.
  printf '#!/bin/sh\nprintf "1\\t0\\tSs\\tThu Jan  1 00:00:00 2026\\n"\n' > "$rt/bin/ps-stub"; chmod +x "$rt/bin/ps-stub"
  printf '1\tThu Jan  1 00:00:00 2026\n' > "$t/procs-before-$i"
  git init -q "$ws"
  git -C "$ws" commit -q --allow-empty -m base
  git -C "$ws" rev-parse HEAD > "$rt/base"
  echo fix > "$ws/f"; git -C "$ws" add f; git -C "$ws" commit -q -m try1
  git -C "$ws" rev-parse HEAD > "$rt/try1_head"
  mkdir "$t/verify-1"
  echo "$VERDICT_FAIL" > "$t/verify-1/verdict.json"; echo "fail" > "$t/verify-1/verdict.md"
  {
    echo "VS_SUM=$(bash -c "$(fingerprint_fn "$WORKFLOW")"'; fingerprint "$1"' _ "$vs")"
    echo "VT_SUM=$(python3 -B "$HERE/flake-verify.py" tree-digest "$vt")"
    echo "TRY1_VERIFY_SUM=$(python3 -B "$HERE/flake-verify.py" tree-digest "$t/verify-1")"
    echo "SNAP_SUM=$(shasum -a 256 < "$t/procs-before-$i" | cut -d' ' -f1)"
  } > "$rt/sums"
  printf '%s' "$rt"
}

# end_run FILE I RT [VAR=VALUE...]: run FILE's "End session I" step in RT's
# world, under the step's own shell, with its `env:` set as the runner sets it
# and each VAR=VALUE added the way a session's $GITHUB_ENV would add it.
# Prints the exit code.
end_run() {
  local wf="$1" i="$2" rt="$3" t script shell clean rc=0
  shift 3
  t="$rt/flakefix"; script="$rt/step-$i.sh"
  step_script "$wf" "End session $i" | sed "s|\${{ runner.temp }}|$rt|g" > "$script"
  shell="$(step_shell "$wf" "End session $i")"
  [[ -n "$shell" ]] || shell='bash --noprofile --norc -eo pipefail {0}'
  # The record "Record the verifier's environment" itself makes, run in the
  # environment the job has before session 1.
  clean="$(record_env "$wf" "$rt")" || return 1
  : > "$rt/out"; : > "$rt/summary"
  # shellcheck disable=SC2046,SC2086 # the sums and the step's shell are word lists on purpose
  (cd "$rt/ws" && env $(cat "$rt/sums") "$@" CLEAN_ENV="$clean" \
    TRY1_HEAD="$(cat "$rt/try1_head")" BASE="$(cat "$rt/base")" SCOPE=test BASELINE_F=3 BASELINE_V=20 \
    BASELINE_MD='baseline' QUARANTINED=no PLAN='{"n": 45}' \
    GITHUB_OUTPUT="$rt/out" GITHUB_STEP_SUMMARY="$rt/summary" \
    ${shell/\{0\}/$script} > "$rt/log" 2>&1) || rc=$?
  echo "$rc"
}

# record_env FILE RT: run FILE's "Record the verifier's environment" step as
# the job would before session 1, and print the record it outputs. Under
# /bin/bash, not the first bash on PATH: the macOS runner's is 3.2, which a
# Homebrew bash 5 ahead of it on a developer's PATH would hide.
record_env() {
  local wf="$1" rt="$2" t="$2/flakefix"
  step_script "$wf" "Record the verifier" > "$rt/record.sh"
  : > "$rt/record-out"
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="$rt/tmp" T="$t" VS="$rt/flakefix-verifier-scripts" VT="$rt/flakefix-verify" \
    FLAKEFIX_NOTES="$t/flakefix-notes.md" FLAKE_VERIFY_PS="$rt/bin/ps-stub" GIT_CEILING_DIRECTORIES="$SCRATCH" \
    GITHUB_OUTPUT="$rt/record-out" /bin/bash -e "$rt/record.sh" > /dev/null 2>&1 || return 1
  sed -n 's/^env=//p' "$rt/record-out"
}

test_the_record_restores_what_the_job_had_and_pins_git() {
  local rt rec
  rt="$(end_world 1)"
  rec="$(record_env "$WORKFLOW" "$rt" | base64 -d | tr '\0' '\n')"
  assert_contains "it keeps the job's paths" "$rec" "T=$rt/flakefix"
  assert_contains "and PATH" "$rec" "PATH=$PATH"
  assert_contains "it pins git to no global config" "$rec" "GIT_CONFIG_GLOBAL=/dev/null"
  assert_contains "nor system config" "$rec" "GIT_CONFIG_NOSYSTEM=1"
  assert_lacks "it leaves out the step's own output file" "$rec" "GITHUB_OUTPUT="
  assert_eq "one line of output" "1" "$(grep -c '^env=' "$rt/record-out")"
}

# Whether the step left a passing verdict where publish reads it.
trusted_pass() { [[ "$(jq -r .verdict "$1/flakefix/verify/verdict.json" 2>/dev/null)" == pass && ! -f "$1/flakefix/abort_reason" ]]; }
exists() { if [[ -e "$1" ]]; then echo yes; else echo no; fi; }

test_an_unchanged_try_2_inherits_try_1s_verdict_as_measured() {
  local rt rc
  rt="$(end_world 2)"
  rc="$(end_run "$WORKFLOW" 2 "$rt")"
  assert_eq "the step succeeds" "0" "$rc"
  [[ "$rc" == 0 ]] || sed 's/^/       /' "$rt/log" | tail -20
  assert_eq "try 1's verdict stands" "fail" "$(jq -r .verdict "$rt/flakefix/verify/verdict.json")"
  assert_contains "and is not stressed again" "$(cat "$rt/out")" "commits=0"
  assert_eq "nothing aborted" "no" "$(exists "$rt/flakefix/abort_reason")"
  assert_eq "try 1's copy is gone" "no" "$(exists "$rt/flakefix/verify-1")"
}

# Session 2 makes no commit and rewrites try 1's verdict to a pass.
planted_verdict_refused() {
  local rt rc
  rt="$(end_world 2)"
  echo "$VERDICT_PASS" > "$rt/flakefix/verify-1/verdict.json"
  rc="$(end_run "$1" 2 "$rt")"
  [[ "$rc" != 0 ]] && ! trusted_pass "$rt" && grep -q "Try 1's verifier output changed" "$rt/flakefix/abort_reason"
}
test_a_verdict_planted_during_session_2_is_not_trusted() {
  check "a pass planted in try 1's output aborts the attempt" planted_verdict_refused \
    '[ "$(python3 -I -S -B "$own/vs/scripts/flake-verify.py" tree-digest "$T/verify-1")" = "$TRY1_VERIFY_SUM" ]' 'true'
}

test_a_changed_try_2_drops_try_1s_output() {
  local rt rc
  rt="$(end_world 2)"
  echo more > "$rt/ws/g"; git -C "$rt/ws" add g; git -C "$rt/ws" commit -q -m try2
  rc="$(end_run "$WORKFLOW" 2 "$rt")"
  assert_eq "the step succeeds" "0" "$rc"
  assert_contains "the new commits are counted" "$(cat "$rt/out")" "commits=2"
  assert_eq "try 1's output is not left to be uploaded" "no" "$(exists "$rt/flakefix/verify-1")"
  assert_eq "and no verdict waits for try 2's stress" "no" "$(exists "$rt/flakefix/verify")"
}

# The session edits the verification tree's .git/config, or its .build.
tree_tamper_refused() {
  local rt rc i
  for i in 1 2; do
    rt="$(end_world "$i")"
    printf '[core]\n\tfsmonitor = /tmp/evil\n' > "$rt/flakefix-verify/.git/config"
    rc="$(end_run "$1" "$i" "$rt")"
    [[ "$rc" != 0 ]] && grep -q "verification tree changed during session $i" "$rt/flakefix/abort_reason" || return 1
    rt="$(end_world "$i")"
    echo forged > "$rt/flakefix-verify/.build/debug/TBDTests"
    rc="$(end_run "$1" "$i" "$rt")"
    [[ "$rc" != 0 ]] && grep -q "verification tree changed during session $i" "$rt/flakefix/abort_reason" || return 1
  done
}
test_a_tampered_verification_tree_aborts_the_attempt() {
  check "an edit to the verification tree's .git or .build aborts" tree_tamper_refused \
    'tree-digest "$VT")" = "$VT_SUM" ]' 'tree-digest "$VT")" = "$VT_SUM" ] || true' all
  local rt
  rt="$(end_world 1)"
  assert_eq "an untouched tree passes the check" "0" "$(end_run "$WORKFLOW" 1 "$rt")"
}

# What a session can append to $GITHUB_ENV and $GITHUB_PATH: BASH_ENV, which
# bash runs before the script; an exported function, which every child bash
# imports and no `unset` reaches; a PATH entry ahead of git and python3; a T
# holding a passing verdict; a variable the record does not name (GIT_DIR).
injected_env_ignored() {
  local rt rc evil
  rt="$(end_world 2)"; evil="$rt/evil"; mkdir -p "$evil"
  printf 'touch %q\n' "$rt/bash-env-ran" > "$evil/bash_env"
  printf '#!/bin/sh\ntouch %q\nexit 1\n' "$rt/shadow-ran" > "$evil/git"; cp "$evil/git" "$evil/python3"; chmod +x "$evil/git" "$evil/python3"
  echo "$VERDICT_PASS" > "$evil/verdict.json"
  rc="$(end_run "$1" 2 "$rt" BASH_ENV="$evil/bash_env" PATH="$evil:$PATH" T="$evil" GIT_DIR="$evil" \
    "BASH_FUNC_awk%%=() {  touch $rt/function-ran; command awk \"\$@\"; }")"
  [[ "$rc" == 0 && ! -e "$rt/bash-env-ran" && ! -e "$rt/shadow-ran" && ! -e "$rt/function-ran" ]] &&
    [[ "$(jq -r .verdict "$rt/flakefix/verify/verdict.json")" == fail ]]
}
test_an_injected_environment_does_not_reach_the_step() {
  check "BASH_ENV is not read (bash -p)" injected_env_ignored \
    'shell: /bin/bash --noprofile --norc -p -eo pipefail {0}' 'shell: /bin/bash --noprofile --norc -eo pipefail {0}' all
  check "the step re-runs itself with nothing but its env: and the record" injected_env_ignored \
    'exec /usr/bin/env -i "${e[@]}" /bin/bash --noprofile --norc -p -eo pipefail "$0" --clean-env' 'export "${e[@]}"' all
}

# Every `run:` step after session 1 starts the same way: bash -p, then a
# re-run under `env -i` with its own `env:` and the record, in the same lines
# as "End session 1"; and its `keep` names exactly its `env:` keys.
post_session_steps_scrubbed() {
  local job names name script pre keep envs n=0
  job="$(job_block "$1" fix)"
  pre="$(step_script "$1" "End session 1" | sed -n 2,7p)"
  grep -qF 'restore="$CLEAN_ENV"' <<< "$pre" && grep -qF 'exec /usr/bin/env -i "${e[@]}"' <<< "$pre" &&
    grep -qF '/usr/bin/base64 -d' <<< "$pre" || return 1
  names="$(awk '/name: Fixer session 1/{p=1} p && /^      - name: /{sub(/^      - name: /, ""); print}' <<< "$job")"
  while IFS= read -r name; do
    script="$(step_script "$1" "$name")"
    [[ -n "$script" ]] || continue  # a `uses:` step
    n=$((n + 1))
    [[ "$(step_shell "$1" "$name")" == '/bin/bash --noprofile --norc -p -eo pipefail {0}' ]] || { echo "  [$name] has no bash -p shell" >&2; return 1; }
    if [[ "$name" == "Package the attempt" ]]; then
      grep -qF 'exec /usr/bin/env -i PATH=/usr/bin:/bin' <<< "$(sed -n 1,3p <<< "$script")" || return 1
      continue
    fi
    [[ "$(sed -n 2,7p <<< "$script")" == "$pre" ]] || { echo "  [$name] does not restore the record first" >&2; return 1; }
    step "$1" fix "$name" | grep -qF 'CLEAN_ENV: ${{ steps.cleanenv.outputs.env }}' || return 1
    keep="$(sed -n '1s/^keep="\(.*\)"$/\1/p' <<< "$script" | tr ' ' '\n' | grep -vE '^(GITHUB_OUTPUT|GITHUB_STEP_SUMMARY)?$' | sort)"
    envs="$(step "$1" fix "$name" | awk '/^        env:$/{p=1; next} p && !/^          [A-Z_0-9]+:/{exit} p{sub(/^ +/, ""); sub(/:.*/, ""); print}' | grep -v '^CLEAN_ENV$' | sort)"
    [[ "$keep" == "$envs" ]] || { echo "  [$name] keeps [$keep] but sets [$envs]" >&2; return 1; }
  done <<< "$names"
  [[ "$n" -ge 10 ]] && ! awk '/name: Fixer session 1/{p=1} p' <<< "$job" | grep -qF '${{ env.'
}
test_every_step_after_session_1_runs_in_the_recorded_environment() {
  check "every run: step after session 1 restores the record" post_session_steps_scrubbed \
    '        id: v2
        shell: /bin/bash --noprofile --norc -p -eo pipefail {0}' '        id: v2
        shell: bash'
  check "and no later path comes from the env context" post_session_steps_scrubbed \
    'path: ${{ runner.temp }}/flakefix/
' 'path: ${{ env.T }}/
'
  check "and each step keeps exactly the variables its env: sets" post_session_steps_scrubbed \
    'keep=" GITHUB_OUTPUT GITHUB_STEP_SUMMARY TEST_ID "' 'keep=" GITHUB_OUTPUT GITHUB_STEP_SUMMARY "'
}

test_the_package_step_scrubs_without_a_record() {
  local script
  script="$(step_script "$WORKFLOW" "Package the attempt")"
  assert_contains "it re-runs itself on the system's PATH alone" "$script" 'exec /usr/bin/env -i PATH=/usr/bin:/bin'
  assert_contains "and takes T from the runner" "$script" "T='\${{ runner.temp }}/flakefix'"
}

judge_survives_no_answer() {
  local i
  for i in 1 2; do step "$1" fix "Judge try $i" | grep -qF 'q="$(cat "$T/verify/quarantined" 2>/dev/null || true)"' || return 1; done
}
test_a_judge_without_a_quarantine_answer_still_judges() {
  check "a missing answer does not end the Judge step under -e" judge_survives_no_answer \
    'q="$(cat "$T/verify/quarantined" 2>/dev/null || true)"' 'q="$(cat "$T/verify/quarantined" 2>/dev/null)"'
}

# publish's check of the artifact against the sums `fix` packaged.
publish_check_script() { step "$1" publish "Check the candidate against" | awk '/^        run: \|$/{p=1; next} p' | sed -E 's/^ {10}//'; }
sums_of() {
  local f got=""
  for f in outcome abort_reason abort_kind candidate.bundle head_sha verify/verdict.json verify/verdict.md verify/protected.txt verify/failing-lines.txt baseline/f baseline/v flakefix-notes.md; do
    if [[ -f "$1/$f" ]]; then got="$got$f:$(shasum -a 256 < "$1/$f" | cut -d' ' -f1);"; else got="$got$f:-;"; fi
  done
  printf '%s' "$got"
}
tampered_artifact_discarded() {
  local rt a sums
  rt="$(mktmpd)"; a="$rt/flakefix-candidate"; mkdir -p "$a/verify"
  local planted
  publish_check_script "$1" > "$rt/check.sh"
  # Each file publish reads, changed after packaging: the verdict, the report
  # under the PR's evidence heading, and the baseline numbers.
  for planted in verify/verdict.json verify/verdict.md baseline/f ""; do
    rm -rf "$a"; mkdir -p "$a/verify" "$a/baseline"
    echo candidate > "$a/outcome"; echo bundle > "$a/candidate.bundle"; echo "$VERDICT_FAIL" > "$a/verify/verdict.json"
    echo "3 of 20 failed" > "$a/verify/verdict.md"; echo 3 > "$a/baseline/f"; echo 20 > "$a/baseline/v"
    sums="$(sums_of "$a")"
    [[ -z "$planted" ]] || echo planted > "$a/$planted"
    RUNNER_TEMP="$rt" SUMS="$sums" bash "$rt/check.sh" > /dev/null 2>&1 || return 1
    if [[ -z "$planted" ]]; then
      [[ "$(cat "$a/outcome")" == candidate && -f "$a/candidate.bundle" ]] || return 1  # an untouched artifact is kept
    else
      [[ "$(cat "$a/outcome")" == aborted && ! -e "$a/verify" && ! -e "$a/candidate.bundle" ]] || return 1
      grep -q "did not match what the fix job packaged" "$a/abort_reason" || return 1
    fi
  done
  echo candidate > "$a/outcome"
  RUNNER_TEMP="$rt" SUMS="" bash "$rt/check.sh" > /dev/null 2>&1 || return 1
  [[ "$(cat "$a/outcome")" == aborted ]]  # no sums at all: nothing is trusted
}
test_publish_discards_an_artifact_that_is_not_what_fix_packaged() {
  check "a file changed after packaging discards the candidate" tampered_artifact_discarded \
    'if [ "$got" != "$SUMS" ]; then' 'if false; then'
  assert_contains "fix exports the sums" "$(job_block "$WORKFLOW" fix | sed -n 1,20p)" 'sums: ${{ steps.package.outputs.sums }}'
  assert_contains "publish reads them" "$(step "$WORKFLOW" publish "Check the candidate against")" 'SUMS: ${{ needs.fix.outputs.sums }}'
  local job pkg pub
  pkg="$(step_script "$WORKFLOW" "Package the attempt" | grep -E 'shasum -a 256 <|for f in ' | sed 's/^ *//')"
  pub="$(publish_check_script "$WORKFLOW" | grep -E 'shasum -a 256 <|for f in ' | sed 's/^ *//; s/\$A/$T/g; s/got/sums/g')"
  assert_eq "over the same files" "$(sums_of /nonexistent | tr ';' '\n' | sed 's/:-$//' | tr '\n' ' ' | sed 's/ $//')" \
    "$(sed -n 's/^for f in \(.*\); do$/\1/p' <<< "$pkg")"
  assert_eq "both sides sum the same way" "$pkg" "$pub"
  job="$(job_block "$WORKFLOW" publish)"
  assert_eq "and checks before it pushes" "0" "$(awk '/name: Check the candidate against/{c=NR} /name: Push, open the draft PR/{p=NR} END{print !(c && p && c < p)}' <<< "$job")"
}

# ============================================================================
# the promote step (spec §6.5, §7), against a stub gh
# ============================================================================

PSHA=1111111111111111111111111111111111111111
PBRANCH=flakefix/issue-10

# pworld [JQ_PR] [JQ_STATUSES] [JQ_FILES] -> D, a stub gh answering for one
# PR on PBRANCH whose every promotion condition holds; each JQ edits one part,
# and PW_RUNS and PW_DRAFTED, when set, edit the PR's Test runs on the head and
# its returns to draft. The stub applies no --jq, so everything read through
# one is routed already projected.
pworld() {
  local d; d="$(mktmpd)"
  stub_gh "$d"
  jq -n --arg sha "$PSHA" --arg ref "$PBRANCH" --arg repo "$REPO" --arg bot "$BOT" \
    '{number: 77, state: "open", draft: true, head: {sha: $sha, ref: $ref, repo: {full_name: $repo}},
      user: {login: $bot, type: "Bot"}, labels: []}' | jq "${1:-.}" | jq -s . > "$d/pulls.json"
  jq -n --arg bot "$BOT" '[{context: "flakefix/stress", state: "success", description: "no failure observed in 59 runs",
      creator: $bot, creator_type: "Bot", created_at: "2026-10-08T06:00:00Z", id: 1}]' | jq "${2:-.}" | jq -c '.[]' > "$d/statuses"
  jq -n '[{filename: "Tests/TBDSharedTests/HolderLockTests.swift", previous_filename: null}]' | jq "${3:-.}" | jq -c '.[]' > "$d/files"
  jq -n --argjson n "$(wc -l < "$d/files" | tr -d ' ')" '{changed_files: $n}' > "$d/one.json"
  jq -n --arg sha "$PSHA" --arg ref "$PBRANCH" --arg repo "$REPO" \
    '[{id: 500, event: "pull_request", path: ".github/workflows/test.yml", status: "completed", conclusion: "success",
       head_sha: $sha, head_branch: $ref, head_repo: $repo, created_at: "2026-10-08T06:30:00Z"}]' \
    | jq "${PW_RUNS:-.}" | jq -c '.[]' > "$d/runs"
  jq -n '[]' | jq "${PW_DRAFTED:-.}" | jq -c '.[]' > "$d/drafted"
  echo "$PSHA" > "$d/head-after"
  jq -n --arg d "$d" '[
    {match: "^api repos/cheapsteak/tbd/pulls\\?head=cheapsteak:flakefix/issue-10&state=open", file: ($d + "/pulls.json")},
    {match: "^api repos/cheapsteak/tbd/pulls/77$", file: ($d + "/one.json")},
    {match: "^api repos/cheapsteak/tbd/pulls/77 --jq .head.sha$", file: ($d + "/head-after")},
    {match: "^pr ready 77 --repo cheapsteak/tbd --undo$", out: ""},
    {match: "commits/1111111111111111111111111111111111111111/statuses", file: ($d + "/statuses")},
    {match: "^api repos/cheapsteak/tbd/commits/1111111111111111111111111111111111111111/pulls\\?per_page=100$", file: ($d + "/pulls.json")},
    {match: "actions/workflows/test.yml/runs\\?head_sha=1111111111111111111111111111111111111111&event=pull_request", file: ($d + "/runs")},
    {match: "issues/77/timeline", file: ($d + "/drafted")},
    {match: "pulls/77/files", file: ($d + "/files")},
    {match: "labels\\?per_page", out: ""},
    {match: "-X POST", out: "{}"},
    {match: "^pr ready 77 --repo cheapsteak/tbd$", out: ""}
  ]' > "$d/routes.json"
  printf '%s' "$d"
}

# promote D [DIR] [CONCLUSION] [EVENT] -> exit code; output in D/out. With
# PMODE=status it runs as the status trigger does, and takes no CONCLUSION or
# EVENT.
promote() {
  local d="$1" dir="${2:-$HERE}" rc=0 how
  if [[ "${PMODE:-}" == status ]]; then
    how=(--from-status)
  else
    how=(--branch "$PBRANCH" --conclusion "${3:-success}" --event "${4:-pull_request}" --run-id 500 --run-created-at 2026-10-08T06:30:00Z)
  fi
  (cd "$d" && GH_TOKEN=job-token APP_TOKEN=app-token FLAKE_GH_CMD="$d/gh" \
    bash "$dir/flake-pr.sh" promote --repo "$REPO" --sha "$PSHA" "${how[@]}") > "$d/out" 2>&1 || rc=$?
  echo "$rc"
}
promoted() { grep -q '^app-token pr ready 77 --repo cheapsteak/tbd$' "$1/log" && echo yes || echo no; }

# skips NAME MUTATION_SED [JQ_PR] [JQ_STATUSES] [JQ_FILES] [CONCLUSION] [EVENT]:
# the world as edited is not promoted, and with the guard removed it is.
skips() {
  local name="$1" expr="$2" d mutant
  d="$(pworld "${3:-.}" "${4:-.}" "${5:-.}")"
  assert_eq "$name: exit 0" "0" "$(promote "$d" "$HERE" "${6:-success}" "${7:-pull_request}")"
  assert_eq "$name: stays a draft" "no" "$(promoted "$d")"
  assert_contains "$name: says why" "$(cat "$d/out")" "SKIP"
  mutant="$(mutant_of "$expr" "$PR_PY")"
  d="$(pworld "${3:-.}" "${4:-.}" "${5:-.}")"
  promote "$d" "$mutant" "${6:-success}" "${7:-pull_request}" > /dev/null
  assert_eq "mutation: $name is promoted without its guard" "yes" "$(promoted "$d")"
}

test_all_conditions_hold_promotes() {
  local d; d="$(pworld)"
  assert_eq "exit 0" "0" "$(promote "$d")"
  assert_eq "marked ready" "yes" "$(promoted "$d")"
  assert_lacks "no label write for strong evidence" "$(logged "$d")" "-X POST"
}

test_promote_uses_the_app_token_for_ready() {
  local d mutant; d="$(pworld)"
  promote "$d" > /dev/null
  assert_eq "reads use the job token" "" "$(grep -v '^  STDIN' "$d/log" | grep -v ' pr ready ' | grep -v '^job-token ')"
  assert_contains "the head is read again after the ready" "$(tail -1 "$d/log")" "job-token api repos/$REPO/pulls/77 --jq .head.sha"
  assert_contains "the ready uses the App token" "$(logged "$d")" "app-token pr ready 77 --repo $REPO"
  mutant="$(mutant_of 's/ghw pr ready/"$GH_CMD" pr ready/' "$PR_SH")"
  d="$(pworld)"; promote "$d" "$mutant" > /dev/null
  assert_contains "mutation: without ghw the job token raises the ready" "$(logged "$d")" "job-token pr ready 77"
}

test_a_red_run_does_not_promote() {
  # The triggering run's own conclusion becomes its entry among the head's runs.
  skips "a red run" 's/if latest\["status"\] != "completed" or latest\["conclusion"\] != "success":/if False:/' . . . failure
}

test_a_run_that_is_not_the_prs_own_ci_does_not_promote() {
  skips "a dispatched run" 's/if facts\["run_event"\] != PROMOTE_EVENT:/if False:/' . . . success workflow_dispatch
}

test_a_missing_stress_status_does_not_promote() {
  skips "no stress status, only another context" 's/s\["context"\] == STATUS_CONTEXT and //' . '.[0].context = "ci/other"'
}

test_a_failure_stress_status_does_not_promote() {
  skips "a failure status" 's/if newest\["state"\] != "success":/if False:/' . '.[0].state = "failure"'
}

test_a_status_set_by_someone_else_does_not_count() {
  skips "a success status by a human" 's/fl.trusted_author\(s\["creator"\], s\["creator_type"\]\)/True/' . \
    '.[0].creator = "mallory" | .[0].creator_type = "User"'
}

test_a_newer_failure_status_overrides_an_older_success() {
  # GitHub lists newest first; the older success is listed first here, so a
  # reader that took the first entry would also be wrong.
  skips "a newer failure" 's/newest = max\(mine/newest = min(mine/' . \
    '[.[0], (.[0] | .state = "failure" | .created_at = "2026-10-08T07:00:00Z" | .id = 2)]'
}

test_a_head_that_moved_after_verification_does_not_promote() {
  skips "a moved head" 's/if pr\["head_sha"\] != facts\["run_head_sha"\]:/if False:/' '.head.sha = "2222222222222222222222222222222222222222"'
}

test_a_non_draft_or_human_authored_pr_is_left_alone() {
  skips "a PR already ready" 's/if pr\["draft"\] is not True:/if False:/' '.draft = false'
  skips "a human-authored PR" 's/if not fl.trusted_author\(pr\["author"\], pr\["author_type"\]\):/if False:/' \
    '.user = {login: "alice", type: "User"}'
  skips "a PR from another repository" 's/if pr\["head_repo"\] != facts\["repo"\]:/if False:/' '.head.repo.full_name = "mallory/tbd"'
}

test_a_pr_touching_a_protected_file_does_not_promote() {
  skips "a protected file" 's/if protected:/if False:/' . . '. + [{filename: "scripts/test.sh", previous_filename: null}]'
  skips "a protected file renamed away" 's/if protected:/if False:/' . . \
    '[{filename: "scripts/renamed.sh", previous_filename: "scripts/flake-verify.sh"}]'
}

test_a_failed_read_leaves_the_pr_a_draft() {
  local d; d="$(pworld)"
  jq '[.[] | select(.match | test("statuses") | not)]' "$d/routes.json" > "$d/r" && mv "$d/r" "$d/routes.json"
  assert_eq "exit 2" "2" "$(promote "$d")"
  assert_eq "stays a draft" "no" "$(promoted "$d")"
}

# A protected-list check that fails must fail the call, not match nothing.
test_a_protected_list_that_cannot_run_fails_closed() {
  local d dir mutant protected='. + [{filename: "scripts/test.sh", previous_filename: null}]'
  dir="$(mktmpd)"
  cp "$HERE/flake_lib.py" "$HERE/flake-ledger.py" "$PR_SH" "$PR_PY" "$dir/"
  d="$(pworld . . "$protected")"
  assert_eq "a missing verifier script exits 2" "2" "$(promote "$d" "$dir")"
  assert_eq "and stays a draft" "no" "$(promoted "$d")"
  mutant="$(mutant_of 's/\[\[ "\$rc" -le 1 \]\] \|\| die "cannot check the PR.s files against the protected list"/true/' "$PR_SH")"
  rm -f "$mutant/flake-verify.sh"
  d="$(pworld . . "$protected")"
  promote "$d" "$mutant" > /dev/null
  assert_eq "mutation: without the exit check a protected file is promoted" "yes" "$(promoted "$d")"
}

# GitHub's ready takes no expected head: a push between the read and the ready
# is caught by reading the head again, and the PR goes back to draft.
test_a_head_that_moved_during_the_ready_is_returned_to_draft() {
  local d mutant
  d="$(pworld)"; echo 2222222222222222222222222222222222222222 > "$d/head-after"
  assert_eq "exit 2" "2" "$(promote "$d")"
  assert_contains "returned to draft with the App token" "$(logged "$d")" "app-token pr ready 77 --repo $REPO --undo"
  mutant="$(mutant_of 's/if \[\[ "\$now" != "\$sha" \]\]; then/if false; then/' "$PR_SH")"
  d="$(pworld)"; echo 2222222222222222222222222222222222222222 > "$d/head-after"
  assert_eq "mutation: without the re-read it stays ready" "0" "$(promote "$d" "$mutant")"
  assert_lacks "mutation: and nothing undoes it" "$(logged "$d")" "--undo"
}

test_files_that_could_not_all_be_listed_do_not_promote() {
  local d mutant
  d="$(pworld)"; echo '{"changed_files": 3001}' > "$d/one.json"
  assert_eq "exit 0" "0" "$(promote "$d")"
  assert_eq "stays a draft" "no" "$(promoted "$d")"
  mutant="$(mutant_of 's/if not isinstance\(pr\["changed_files"\], int\) or pr\["changed_files"\] != len\(listed\) \\/if False \\/' "$PR_PY")"
  d="$(pworld)"; echo '{"changed_files": 3001}' > "$d/one.json"
  promote "$d" "$mutant" > /dev/null
  assert_eq "mutation: an incomplete listing is promoted without the check" "yes" "$(promoted "$d")"
}

test_a_weak_evidence_clean_pr_still_promotes() {
  local d mutant weak='.[0].description = "no failure observed in 5 runs; weak evidence: a no-op would pass 77.4% of the time"'
  d="$(pworld '.labels = [{name: "flakefix-weak-evidence"}]' "$weak")"
  promote "$d" > /dev/null
  assert_eq "weak and labelled: promoted" "yes" "$(promoted "$d")"
  assert_lacks "with no second label write" "$(logged "$d")" "-X POST"
  d="$(pworld . "$weak")"
  promote "$d" > /dev/null
  assert_eq "weak and unlabelled: promoted" "yes" "$(promoted "$d")"
  assert_contains "after the App adds the label" "$(logged "$d")" "app-token api -X POST repos/$REPO/issues/77/labels"
  assert_eq "the label goes on before the ready" "1" "$(awk '/issues\/77\/labels/{l=NR} / pr ready 77/{r=NR} END{print (l && r && l < r) ? 1 : 0}' "$d/log")"
  mutant="$(mutant_of 's/if WEAK_CLAUSE in/if False and WEAK_CLAUSE in/' "$PR_PY")"
  d="$(pworld . "$weak")"; promote "$d" "$mutant" > /dev/null
  assert_lacks "mutation: without the weak check no label is added" "$(logged "$d")" "issues/77/labels"
}

test_promote_writes_no_ledger_or_attempt_state() {
  local d; d="$(pworld)"
  promote "$d" > /dev/null
  assert_lacks "no comment read or written" "$(logged "$d")" "comments"
}

test_promote_decide_is_pure_and_rejects_malformed_facts() {
  local d; d="$(mktmpd)"
  echo '{"run_event": "pull_request"}' > "$d/f.json"
  local rc=0; FLAKE_GH_CMD=/nonexistent bash "$PR_SH" promote-decide --facts "$d/f.json" > /dev/null 2>&1 || rc=$?
  assert_eq "malformed facts exit 2" "2" "$rc"
}

# --- the second trigger, and the PR's own Test run (spec §7) ------------------

# Whichever of the Test completion and the stress status lands last promotes.
test_a_status_landing_after_the_test_run_promotes() {
  local d; d="$(pworld)"
  assert_eq "exit 0" "0" "$(PMODE=status promote "$d")"
  assert_eq "marked ready" "yes" "$(promoted "$d")"
  assert_contains "the PR is found from the status's commit" "$(logged "$d")" "job-token api repos/$REPO/commits/$PSHA/pulls?per_page=100"
}

test_a_status_landing_before_the_test_run_completes_skips() {
  local d mutant
  PW_RUNS='.[0].status = "in_progress" | .[0].conclusion = null' PMODE=status \
    skips "a Test run still running" 's/if latest\["status"\] != "completed" or latest\["conclusion"\] != "success":/if False:/'
  # Under the Test trigger a newer run on the same head (a re-run) decides.
  PW_RUNS='[.[0], (.[0] | .id = 501 | .status = "in_progress" | .conclusion = null | .created_at = "2026-10-08T07:00:00Z")]' \
    skips "a newer Test run still running" 's/if latest\["status"\] != "completed" or latest\["conclusion"\] != "success":/if False:/'
  d="$(PW_RUNS='[]' pworld)"
  assert_eq "no Test run on the head: exit 0" "0" "$(PMODE=status promote "$d")"
  assert_eq "no Test run on the head: stays a draft" "no" "$(promoted "$d")"
  assert_contains "no Test run on the head: says why" "$(cat "$d/out")" "has not run on the head"
}

# The run that started a test-run promote is known from its event; a listing
# that has not caught up with its completion must not hold the PR back.
test_the_triggering_run_counts_even_when_the_listing_lags() {
  local d mutant lag='.[0].status = "in_progress" | .[0].conclusion = null'
  d="$(PW_RUNS="$lag" pworld)"
  promote "$d" > /dev/null
  assert_eq "a lagging listing: promoted" "yes" "$(promoted "$d")"
  d="$(PW_RUNS='[]' pworld)"
  promote "$d" > /dev/null
  assert_eq "a listing without the run: promoted" "yes" "$(promoted "$d")"
  mutant="$(mutant_of 's/        if trigger != "status":$/        if False:/' "$PR_PY")"
  d="$(PW_RUNS="$lag" pworld)"
  promote "$d" "$mutant" > /dev/null
  assert_eq "mutation: trusting the listing alone leaves it a draft" "no" "$(promoted "$d")"
}

test_only_the_prs_own_test_run_counts() {
  PW_RUNS='.[0].event = "push"' PMODE=status \
    skips "a push run" 's/if r\["event"\] == PROMOTE_EVENT and /if /'
  PW_RUNS='.[0].head_branch = "flakefix/issue-11"' PMODE=status \
    skips "a run on another branch" 's/and r\["head_branch"\] == facts\["branch"\]//'
  PW_RUNS='.[0].head_repo = "mallory/tbd"' PMODE=status \
    skips "a fork's run" 's/and r\["head_repo"\] == facts\["repo"\]\]/]/'
  PW_RUNS='.[0].path = ".github/workflows/other.yml"' PMODE=status \
    skips "another workflow's run" 's/and r\["path"\]\.split\("@", 1\)\[0\] == TEST_WORKFLOW//'
}

test_a_newer_red_test_run_overrides_an_older_green_one() {
  PW_RUNS='[.[0], (.[0] | .id = 501 | .conclusion = "failure" | .created_at = "2026-10-08T07:00:00Z")]' PMODE=status \
    skips "a newer red run" 's/latest = max\(runs/latest = min(runs/'
}

# A status names a commit; the PR is the one open bot PR whose head it is.
test_a_status_with_no_matching_pr_skips_cleanly() {
  local d jq_pr
  for jq_pr in '.state = "closed"' '.head.sha = "2222222222222222222222222222222222222222"' \
      '.head.repo.full_name = "mallory/tbd"' '.head.ref = "feature/x"'; do
    d="$(pworld "$jq_pr")"
    assert_eq "no PR ($jq_pr): exit 0" "0" "$(PMODE=status promote "$d")"
    assert_eq "no PR ($jq_pr): stays a draft" "no" "$(promoted "$d")"
    assert_contains "no PR ($jq_pr): says why" "$(cat "$d/out")" "SKIP no one open flakefix/issue-<N> PR"
  done
  d="$(pworld)"
  jq '[.[0], (.[0] | .number = 78 | .head.ref = "flakefix/issue-11")]' "$d/pulls.json" > "$d/p2" && mv "$d/p2" "$d/pulls.json"
  assert_eq "two PRs at the head: exit 0" "0" "$(PMODE=status promote "$d")"
  assert_eq "two PRs at the head: stays a draft" "no" "$(promoted "$d")"
}

test_the_status_trigger_takes_no_run_facts() {
  local d rc=0; d="$(pworld)"
  (cd "$d" && GH_TOKEN=job-token APP_TOKEN=app-token FLAKE_GH_CMD="$d/gh" \
    bash "$PR_SH" promote --repo "$REPO" --sha "$PSHA" --from-status --branch "$PBRANCH") > "$d/out" 2>&1 || rc=$?
  assert_eq "--from-status with --branch exits 2" "2" "$rc"
  assert_eq "and stays a draft" "no" "$(promoted "$d")"
  d="$(mktmpd)"
  echo '{"trigger": "manual"}' > "$d/f.json"
  rc=0; FLAKE_GH_CMD=/nonexistent bash "$PR_SH" promote-decide --facts "$d/f.json" > /dev/null 2>&1 || rc=$?
  assert_eq "an unknown trigger exits 2" "2" "$rc"
}

# A human who returns the PR to draft holds it; a later Test re-run at the
# same head, or a status, must not promote it again.
test_a_human_hold_is_never_promoted_over() {
  local mode
  for mode in test-run status; do
    PW_DRAFTED='[{actor: "alice", actor_type: "User", created_at: "2026-10-08T08:00:00Z"}]' PMODE="$mode" \
      skips "a human's return to draft ($mode)" 's/        if held:/        if False:/'
  done
}

test_the_bots_own_return_to_draft_is_not_a_hold() {
  local d mutant drafted
  drafted="[{actor: \"$BOT\", actor_type: \"Bot\", created_at: \"2026-10-08T08:00:00Z\"}]"
  d="$(PW_DRAFTED="$drafted" pworld)"
  promote "$d" > /dev/null
  assert_eq "promote's own undo does not hold the PR" "yes" "$(promoted "$d")"
  mutant="$(mutant_of 's/ if not fl.trusted_author\(d\["actor"\], d\["actor_type"\]\)\]/]/' "$PR_PY")"
  d="$(PW_DRAFTED="$drafted" pworld)"
  promote "$d" "$mutant" > /dev/null
  assert_eq "mutation: counting the bot's undo as a hold leaves it a draft" "no" "$(promoted "$d")"
}

# --- the promote job's structure ----------------------------------------------

promote_gated() {
  local job c
  job="$(job_block "$1" promote | awk '/^    if: >-$/{p=1; next} p && /^    [a-z]/{exit} p')"
  for c in "vars.FLAKE_FIXER_ENABLED == 'true'" "github.repository == 'cheapsteak/tbd'" "github.event_name == 'workflow_run'" \
      "github.event.workflow_run.name == 'Test'" "startsWith(github.event.workflow_run.path, '.github/workflows/test.yml')" \
      "github.event.workflow_run.event == 'pull_request'" "github.event.workflow_run.conclusion == 'success'" \
      "startsWith(github.event.workflow_run.head_branch, 'flakefix/issue-')" \
      "github.event.workflow_run.head_repository.full_name == github.repository" \
      "github.event_name == 'status'" "github.event.context == 'flakefix/stress'" "github.event.state == 'success'"; do
    grep -qF "$c" <<< "$job" || return 1
  done
  # No filter on a status's `branches`: GitHub lists at most 10, so it could
  # miss the PR's branch; `promote --from-status` resolves the PR itself.
  ! grep -qF "github.event.branches" <<< "$job" || return 1
  grep -q '^    workflows: \[Nightly, Test\]$' "$1" && grep -qF "    branches: [main, 'flakefix/issue-*']" "$1" &&
    grep -q '^  status:$' "$1"
}
test_promote_is_gated_by_flag_workflow_branch_prefix_and_same_repo() {
  check "promote's if names the flag, the workflow, the PR event, the prefix and the repository" promote_gated \
    "      github.event.workflow_run.head_repository.full_name == github.repository" "      true"
  local c
  c="$(mutated '      vars.FLAKE_FIXER_ENABLED == '"'true'"' &&
      github.repository' '      github.repository')"
  if ( set +o pipefail; promote_gated "$c" ); then echo "FAIL - mutation: an unflagged promote passes"; FAIL=1; else echo "ok   - mutation: an unflagged promote fails"; fi
  c="$(mutated 'workflows: [Nightly, Test]' 'workflows: [Nightly]')"
  if ( set +o pipefail; promote_gated "$c" ); then echo "FAIL - mutation: no Test trigger passes"; FAIL=1; else echo "ok   - mutation: no Test trigger fails"; fi
  c="$(mutated $'\n  status:\n' $'\n')"
  if ( set +o pipefail; promote_gated "$c" ); then echo "FAIL - mutation: no status trigger passes"; FAIL=1; else echo "ok   - mutation: no status trigger fails"; fi
  c="$(mutated "        github.event.context == 'flakefix/stress' &&" "")"
  if ( set +o pipefail; promote_gated "$c" ); then echo "FAIL - mutation: any status context passes"; FAIL=1; else echo "ok   - mutation: any status context fails"; fi
  c="$(mutated "        github.event.state == 'success'))" "        github.event.state == 'success' &&
        contains(toJSON(github.event.branches.*.name), '\"flakefix/issue-')))")"
  if ( set +o pipefail; promote_gated "$c" ); then echo "FAIL - mutation: a status filtered on its capped branch list passes"; FAIL=1; else echo "ok   - mutation: a status filtered on its capped branch list fails"; fi
}

# The status trigger runs the same script, through env, with --from-status.
promote_status_path() {
  local s; s="$(step "$1" promote "Promote if verified")"
  grep -qF 'STATUS_SHA: ${{ github.event.sha }}' <<< "$s" &&
    grep -qF 'promote --repo "$GITHUB_REPOSITORY" --sha "$STATUS_SHA" --from-status' <<< "$s" &&
    grep -qF 'if [ "$TRIGGER" = status ]; then' <<< "$s"
}
test_the_status_trigger_runs_promote_from_the_status() {
  check "a status runs promote --from-status on its commit" promote_status_path \
    '--sha "$STATUS_SHA" --from-status' '--sha "$STATUS_SHA"'
}

# No `run:` block in the file names the branch (or any workflow_run text) as an
# expression: it reaches scripts through env.
branch_through_env() {
  ! awk '
    /^ *run: \|$/ { match($0, /^ */); ind = RLENGTH; inrun = 1; next }
    /^ *run: / { if (index($0, "github.event.workflow_run.head_branch")) bad = 1 }
    inrun { match($0, /^ */); if (RLENGTH <= ind && $0 !~ /^ *$/) inrun = 0 }
    inrun && index($0, "github.event.workflow_run.head_branch") { bad = 1 }
    END { exit !bad }' "$1"
}
test_promote_passes_the_branch_through_env_not_interpolation() {
  check "the branch never appears inside run:" branch_through_env \
    'bash scripts/flake-pr.sh promote --repo "$GITHUB_REPOSITORY" --branch "$BRANCH"' \
    'bash scripts/flake-pr.sh promote --repo "$GITHUB_REPOSITORY" --branch "${{ github.event.workflow_run.head_branch }}"'
}

test_promote_checkout_drops_credentials() {
  local job
  job="$(job_block "$WORKFLOW" promote)"
  assert_contains "promote checks out main" "$job" "ref: main"
  assert_eq "promote's checkout drops credentials" "1" "$(grep -A4 'uses: actions/checkout' <<< "$job" | grep -c 'persist-credentials: false')"
  local c; c="$(mktmpd)/wf.yml"
  awk '/^  promote:$/{p=1} p && /persist-credentials: false/{sub(/false/, "true")} {print}' "$WORKFLOW" > "$c"
  assert_eq "mutation: a credentialed promote checkout is caught" "0" "$(job_block "$c" promote | grep -A4 'uses: actions/checkout' | grep -c 'persist-credentials: false')"
}

promote_tokens() {
  local job perms
  job="$(job_block "$1" promote)"
  perms="$(awk '/^    permissions:/{p=1; next} p && /^    [a-z]/{exit} p' <<< "$job")"
  [[ -n "$perms" ]] && ! grep -qE 'write|id-token' <<< "$perms" &&
    step "$1" promote "Check the App token's bot login" | grep -q 'scripts/flake_lib.py check-app-slug' &&
    step "$1" promote "Promote if verified" | grep -q 'APP_TOKEN: ${{ steps.app-token.outputs.token }}'
}
test_promote_reads_with_the_job_token_and_writes_with_the_app() {
  check "promote's job token only reads, and the App's login is checked" promote_tokens \
    $'      pull-requests: read\n      statuses: read\n      actions: read' $'      pull-requests: write\n      statuses: read\n      actions: read'
}

# The App token promote mints carries only the scopes it writes with.
promote_app_scopes() {
  local mint
  mint="$(step "$1" promote "Mint the tbd-flake-fixer App token")"
  [[ "$(grep -c 'permission-' <<< "$mint")" == 2 ]] &&
    grep -q 'permission-pull-requests: write' <<< "$mint" && grep -q 'permission-issues: write' <<< "$mint"
}
test_promote_mints_a_narrow_app_token() {
  check "promote's App token is narrowed to pull requests and issues" promote_app_scopes \
    '          permission-issues: write' $'          permission-issues: write\n          permission-contents: write'
}

# A group would let GitHub cancel a pending promote for the current head in
# favour of one queued later for an older SHA.
promote_ungrouped() { ! job_block "$1" promote | grep -q '^    concurrency:'; }
test_promote_has_no_concurrency_group() {
  check "promote queues in no group" promote_ungrouped '    # No concurrency group. Each promote decides' \
    $'    concurrency:\n      group: flake-promote\n    # No concurrency group. Each promote decides'
}

ledger_nightly_only() {
  job_block "$1" ledger | awk '/^    if: >-$/{p=1; next} p && /^    [a-z]/{exit} p' |
    grep -qF "(github.event_name == 'workflow_run' && github.event.workflow_run.name == 'Nightly')"
}
test_the_ledger_job_ignores_test_completions() {
  check "the ledger job runs after Nightly, not Test" ledger_nightly_only \
    "(github.event_name == 'workflow_run' && github.event.workflow_run.name == 'Nightly')" \
    "(github.event_name == 'workflow_run')"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  echo "== $t"
  "$t"
done
if [[ $FAIL -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $FAIL
