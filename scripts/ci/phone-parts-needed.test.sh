#!/usr/bin/env bash
# Tests for scripts/ci/phone-parts-needed.sh — run:
#   /bin/bash scripts/ci/phone-parts-needed.test.sh
#
# Four kinds of case, all needed:
#
#   - THE RULE, through `--classify`: each part's own paths run that part
#     alone, the shared inputs run every part, the paths no part reads run
#     nothing, and anything the rules do not name runs every part.
#   - THE GIT PATH, against throwaway repositories: three-dot against the base,
#     whichever branch the base is, `--no-renames`, the event short-circuit,
#     and every can't-answer-honestly shape answering `true` for every part
#     with exactly three output lines.
#   - THE VERDICT, through `--verdict`, fed the `needs` context `Phone checks`
#     sees: a part passes when it succeeded or the gate's exact `false`
#     skipped it, and every other shape — a cancelled part, a skip after a
#     failed gate, a job missing from or added to the list — fails.
#   - THE WIRING, read from this checkout's `.github/workflows/phone.yml` and
#     `phone-loader-deploy.yml`: the gate fails closed, the verdict sees every
#     result, and the deploy key stays behind main only because of how the
#     workflows are written, and no fixture can evaluate a GitHub expression,
#     so the lines that make it so are pinned as written.
#
# RUN WITH `/bin/bash`, WHICH ON MACOS IS 3.2. Every nested run of the script
# under test goes through `$BASH`, this harness's own interpreter, so the whole
# run stays on whichever bash started it. The gate runs on Linux under bash 5
# in CI, but a developer replays it over merged PRs on a Mac, so it has to work
# under both.
#
# ZERO BUILDS. Every case that needs files mints a throwaway directory under
# `mktemp -d`; nothing is written outside one. The verdict cases need `jq`.
#
# THE FIXTURE REPOS ARE FENCED OFF FROM THE DEVELOPER'S GIT CONFIG: each sets
# its own identity, turns signing off, and turns rename detection ON in local
# config, so the `--no-renames` case tests the flag rather than whatever
# `diff.renames` the machine happens to have.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/phone-parts-needed.sh"
# Byte order and byte-wise character classes, so `sort` and the name patterns
# behave the same on every machine.
export LC_ALL=C

# In CI this harness runs inside a step whose own `$GITHUB_OUTPUT` and
# `$GITHUB_STEP_SUMMARY` are live. A case that does not set them must not write
# into them, and must read the answer from stdout instead. A git hook's own
# `GIT_DIR` and friends would point every fixture's `git` at this checkout.
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY EVENT_NAME BASE_REF NEEDS \
      GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

FAIL=0
assert_eq()       { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { case "$2" in *"$3"*) echo "ok   - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]" ; FAIL=1 ;; esac; }
assert_lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: [$2] holds [$3]" ; FAIL=1 ;; *) echo "ok   - $1" ;; esac; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/phone-parts-needed-test.XXXXXX"; }

# Succeeds when TEXT holds LINE as one whole line.
has_line() {
  case "
$1
" in
    *"
$2
"*) return 0 ;;
  esac
  return 1
}
assert_line() {
  if has_line "$2" "$3"; then echo "ok   - $1"; else echo "FAIL - $1: no line [$3] in [$2]"; FAIL=1; fi
}

# The fixture register is a FILE, not a variable: every fixture is minted inside
# a command substitution, so a subshell's assignment would be lost and the trap
# would reclaim nothing.
FIXTURE_LIST="$(mktmpd)/fixtures"
: > "$FIXTURE_LIST"
cleanup() {
  local dir
  while read -r dir; do
    [ -n "$dir" ] && rm -rf "$dir"
  done < "$FIXTURE_LIST"
  rm -rf "$(dirname "$FIXTURE_LIST")"
}
trap cleanup EXIT

# A registered scratch directory. Echoes its path, so diagnostics go to stderr.
scratch() {
  local d; d="$(mktmpd)"
  echo "$d" >> "$FIXTURE_LIST"
  echo "$d"
}

# The answers, as `expect` spells them: the three output lines joined by spaces.
ALL='relay=true loader=true phone_app=true'
NONE='relay=false loader=false phone_app=false'
RELAY='relay=true loader=false phone_app=false'
LOADER='relay=false loader=true phone_app=false'
APP='relay=false loader=false phone_app=true'
LOADER_AND_APP='relay=false loader=true phone_app=true'
RELAY_AND_LOADER='relay=true loader=true phone_app=false'

# An answer as the three lines the script writes.
as_lines() { printf '%s' "$1" | tr ' ' '\n'; }

# The answer `--classify` gives for the paths after the label and expectation,
# its lines joined by spaces.
expect() {
  local label="$1" want="$2" got; shift 2
  got="$(printf '%s\n' "$@" | "$BASH" "$SCRIPT" --classify 2>/dev/null)"
  assert_eq "$label" "$want" "$(printf '%s' "$got" | tr '\n' ' ')"
}

# The answer `--classify` gives for exactly the bytes in $1, a printf format.
classify_bytes() {
  # shellcheck disable=SC2059 # the argument is the format: it spells NULs and newlines
  printf "$1" | "$BASH" "$SCRIPT" --classify 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}

# ---------------------------------------------------------------------------
# 1. The rule, through --classify
# ---------------------------------------------------------------------------

test_each_part_alone() {
  expect "relay source runs the relay alone"            "$RELAY" relay/cloudflare/src/index.ts
  expect "the relay's README runs the relay alone"      "$RELAY" relay/cloudflare/README.md
  expect "the loader runs the loader alone"             "$LOADER" phone/loader/index.html
  expect "the app's source runs the app alone"          "$APP" phone/app/src/main.tsx
  expect "the committed bundle runs the app alone"      "$APP" Sources/TBDDaemon/Resources/phone-app/app.js
}

test_shared_inputs_run_every_part() {
  local path
  for path in \
    phone/test-vectors/noise-cacophony.json \
    phone/test-vectors/generate.mjs \
    phone/protocol/README.md \
    .github/workflows/phone.yml \
    scripts/ci/phone-parts-needed.sh \
    scripts/ci/phone-parts-needed.test.sh \
    scripts/ci/phone-app-bundle-check.sh \
    scripts/gen-phone-app-bundle.sh
  do
    expect "$path runs every part" "$ALL" "$path"
  done
}

test_phone_workspace_tooling_runs_loader_and_app() {
  local path
  for path in phone/package.json phone/package-lock.json phone/.nvmrc phone/tsconfig.json; do
    expect "$path runs the loader and the app" "$LOADER_AND_APP" "$path"
  done
}

# Spelled out here rather than read from the script's list, so dropping an
# entry from it reddens a case instead of quietly shrinking it.
test_non_phone_paths_run_nothing() {
  local path
  for path in \
    Sources/TBDShared/Models.swift \
    Tests/TBDDaemonTests/X.swift \
    Package.swift \
    Package.resolved \
    rust/comrak-ffi/src/lib.rs \
    Resources/AppIcon.png \
    SessionMod/src/index.ts \
    docs/x.md \
    docs/x.txt \
    README.md \
    CLAUDE.md \
    .claude/settings.json \
    recipe/x \
    tools/x \
    .github/workflows/test.yml \
    .github/workflows/phone-loader-deploy.yml \
    scripts/ci/swift-suite-needed.sh \
    scripts/update.sh
  do
    expect "$path runs no part" "$NONE" "$path"
  done
  expect "every non-phone path at once runs no part" "$NONE" \
    Sources/TBDShared/Models.swift Package.swift docs/x.md README.md .github/workflows/test.yml scripts/update.sh
}

test_unknown_paths_run_every_part() {
  local path
  for path in foo/bar .swiftlint.yml CODEOWNERS relayx/a phones/x relay phone; do
    expect "$path runs every part" "$ALL" "$path"
  done
}

test_mixed_changes() {
  expect "a relay change among docs runs the relay alone" "$RELAY" \
    relay/cloudflare/src/index.ts docs/x.md
  expect "a relay change and a loader change run both" "$RELAY_AND_LOADER" \
    relay/cloudflare/src/index.ts docs/x.md phone/loader/a.js
}

# A path dropped on the floor could be the one that runs a part.
test_input_handling() {
  assert_eq "empty input runs every part" "$ALL" "$(classify_bytes '')"
  assert_eq "input of blank lines runs every part" "$ALL" "$(classify_bytes '\n\n')"
  assert_eq "an unterminated last line is judged" "$RELAY" "$(classify_bytes 'docs/a.md\nrelay/x')"
  assert_eq "blank lines between paths are ignored" "$NONE" "$(classify_bytes 'docs/a.md\n\nREADME.md\n')"
  assert_eq "NUL-separated input is read" "$RELAY" "$(classify_bytes 'docs/a.md\000relay/x\000')"
  assert_eq "an unterminated last NUL record is judged" "$LOADER" "$(classify_bytes 'docs/a.md\000phone/loader/x')"
  assert_eq "a newline inside a NUL-separated path stays one path" "$NONE" \
    "$(classify_bytes 'docs/a\nrelay/x\000README.md\000')"
}

# ---------------------------------------------------------------------------
# 2. The output contract
# ---------------------------------------------------------------------------

test_output_contract() {
  local d stdout summary rc
  d="$(scratch)"
  stdout="$(printf 'relay/cloudflare/src/index.ts\nphone/loader/index.html\ndocs/x.txt\nREADME.md\n' |
    GITHUB_OUTPUT="$d/output" GITHUB_STEP_SUMMARY="$d/summary" "$BASH" "$SCRIPT" --classify 2>/dev/null)"
  assert_eq "\$GITHUB_OUTPUT holds exactly the three lines, in order" "$(as_lines "$RELAY_AND_LOADER")" "$(cat "$d/output")"
  assert_eq "nothing goes to stdout when \$GITHUB_OUTPUT is set" "" "$stdout"
  summary="$(cat "$d/summary")"
  assert_eq "the summary leads with its heading, then one line per part" \
    "### Phone parts gate
- relay: runs
- loader: runs
- phone_app: skipped" "$(printf '%s\n' "$summary" | grep -v '^$' | head -4)"
  assert_eq "the summary ends with one line per file, in input order" \
    "- \`relay/cloudflare/src/index.ts\` – relay – relay/**
- \`phone/loader/index.html\` – loader – phone/loader/**
- \`docs/x.txt\` – no part – docs/**
- \`README.md\` – no part – Markdown outside relay/ and phone/" "$(printf '%s\n' "$summary" | tail -4)"

  d="$(scratch)"
  printf 'phone/package.json\n.github/workflows/phone.yml\n' |
    GITHUB_OUTPUT="$d/output" GITHUB_STEP_SUMMARY="$d/summary" "$BASH" "$SCRIPT" --classify >/dev/null 2>&1
  summary="$(cat "$d/summary")"
  assert_line "a file naming two parts lists both" "$summary" \
    "- \`phone/package.json\` – loader, phone_app – the phone workspace's shared tooling"
  assert_line "a file naming every part lists all three" "$summary" \
    "- \`.github/workflows/phone.yml\` – relay, loader, phone_app – the workflow that runs the parts"

  # A skip with no record of why is refused: every answer turns to `true`.
  d="$(scratch)"
  printf 'docs/a.md\n' |
    GITHUB_OUTPUT="$d/output" GITHUB_STEP_SUMMARY="$d/no-such-dir/summary" "$BASH" "$SCRIPT" --classify >/dev/null 2>&1
  assert_eq "an unwritable summary turns a skip of every part into a run" "$(as_lines "$ALL")" "$(cat "$d/output")"
  d="$(scratch)"
  printf 'relay/x\n' |
    GITHUB_OUTPUT="$d/output" GITHUB_STEP_SUMMARY="$d/no-such-dir/summary" "$BASH" "$SCRIPT" --classify >/dev/null 2>&1
  assert_eq "an unwritable summary turns a partial skip into a run of every part" "$(as_lines "$ALL")" "$(cat "$d/output")"

  d="$(scratch)"
  : > "$d/output"
  GITHUB_OUTPUT="$d/output" "$BASH" "$SCRIPT" --wat >"$d/stdout" 2>/dev/null
  rc=$?
  assert_eq "an unknown option exits 64" "64" "$rc"
  assert_eq "an unknown option writes no answer" "" "$(cat "$d/output" "$d/stdout")"
  GITHUB_OUTPUT="$d/output" "$BASH" "$SCRIPT" --classify extra </dev/null >"$d/stdout" 2>/dev/null
  rc=$?
  assert_eq "--classify with a stray argument exits 64" "64" "$rc"
  assert_eq "--classify with a stray argument writes no answer" "" "$(cat "$d/output" "$d/stdout")"
  GITHUB_OUTPUT="$d/output" "$BASH" "$SCRIPT" --list-parts extra >"$d/stdout" 2>/dev/null
  rc=$?
  assert_eq "--list-parts with a stray argument exits 64" "64" "$rc"
  GITHUB_OUTPUT="$d/output" "$BASH" "$SCRIPT" --verdict extra >"$d/stdout" 2>/dev/null
  rc=$?
  assert_eq "--verdict with a stray argument exits 64" "64" "$rc"
  GITHUB_OUTPUT="$d/output" "$BASH" "$SCRIPT" "" >"$d/stdout" 2>/dev/null
  rc=$?
  assert_eq "an empty argument exits 64" "64" "$rc"
  assert_eq "no malformed invocation wrote anything" "" "$(cat "$d/output" "$d/stdout")"
}

test_list_parts() {
  local out rc
  out="$("$BASH" "$SCRIPT" --list-parts 2>/dev/null)"
  rc=$?
  assert_eq "--list-parts exits 0" "0" "$rc"
  assert_eq "--list-parts prints each part's job ID and output key" \
    "relay relay
loader loader
phone-app phone_app" "$out"
}

# ---------------------------------------------------------------------------
# 3. The git path, against throwaway repositories
# ---------------------------------------------------------------------------

# A fixture holding `repo/`, a clone-shaped repository whose `origin/main` is
# its first commit and whose `feature` branch is checked out. Echoes the
# fixture directory.
mkrepo() {
  local d; d="$(scratch)"
  mkdir -p "$d/repo/docs" "$d/repo/relay/cloudflare/src" "$d/repo/phone/loader" "$d/repo/phone/test-vectors"
  echo "# a"                > "$d/repo/docs/a.md"
  echo "export {}"          > "$d/repo/relay/cloudflare/src/index.ts"
  echo "<!doctype html>"    > "$d/repo/phone/loader/index.html"
  echo '{"vectors": []}'    > "$d/repo/phone/test-vectors/a.json"
  echo "# readme"           > "$d/repo/README.md"
  (
    cd "$d/repo" || exit 1
    git -c init.defaultBranch=main init -q .
    git config user.email "harness@example.invalid"
    git config user.name "Phone Parts Gate Harness"
    git config commit.gpgsign false
    git config diff.renames true
    git add -A
    git commit -q -m "base"
    git update-ref refs/remotes/origin/main HEAD
    git checkout -q -b feature
  ) || echo "fixture repo $d could not be created" >&2
  echo "$d"
}

# Commit a one-line change to a path inside the fixture's repo.
commit_change() {
  local d="$1" path="$2"
  mkdir -p "$(dirname "$d/repo/$path")"
  echo "// touched $RANDOM" >> "$d/repo/$path"
  (
    cd "$d/repo" || exit 1
    git add -A
    git commit -q -m "touch $path"
  )
}

# Run the gate in fixture D's repo with EVENT_NAME=$2 and BASE_REF=$3. Sets
# GATE_OUT (what reached $GITHUB_OUTPUT), GATE_STDOUT, GATE_SUMMARY, GATE_RC.
run_gate() {
  local d="$1"
  : > "$d/output"
  : > "$d/summary"
  (
    cd "$d/repo" || exit 99
    EVENT_NAME="$2" BASE_REF="$3" GITHUB_OUTPUT="$d/output" GITHUB_STEP_SUMMARY="$d/summary" \
      "$BASH" "$SCRIPT" >"$d/stdout" 2>"$d/stderr"
  )
  GATE_RC=$?
  GATE_OUT="$(cat "$d/output")"
  GATE_STDOUT="$(cat "$d/stdout")"
  GATE_SUMMARY="$(cat "$d/summary")"
}

test_git_relay_only_pr() {
  local d; d="$(mkrepo)"
  commit_change "$d" relay/cloudflare/src/index.ts
  commit_change "$d" docs/a.md
  run_gate "$d" pull_request main
  assert_eq "a relay-only PR exits 0" "0" "$GATE_RC"
  assert_eq "a relay-only PR writes exactly three lines, the relay alone true" "$(as_lines "$RELAY")" "$GATE_OUT"
  assert_eq "nothing reaches stdout" "" "$GATE_STDOUT"
  assert_contains "the summary names the changed file" "$GATE_SUMMARY" "\`relay/cloudflare/src/index.ts\` – relay"
}

test_git_non_pr_events_run_every_part() {
  local d event; d="$(mkrepo)"
  commit_change "$d" docs/a.md
  for event in push workflow_dispatch ""; do
    run_gate "$d" "$event" main
    assert_eq "a '${event:-empty}' event runs every part for a docs-only change" "$(as_lines "$ALL")" "$GATE_OUT"
  done
  : > "$d/output"
  ( cd "$d/repo" && GITHUB_OUTPUT="$d/output" "$BASH" "$SCRIPT" >/dev/null 2>&1 )
  assert_eq "an unset EVENT_NAME runs every part" "$(as_lines "$ALL")" "$(cat "$d/output")"
}

test_git_missing_base_runs_every_part() {
  local d; d="$(mkrepo)"
  commit_change "$d" docs/a.md
  run_gate "$d" pull_request no-such-branch
  assert_eq "a base ref that does not resolve runs every part" "$(as_lines "$ALL")" "$GATE_OUT"
  assert_contains "the summary names the unresolved ref" "$GATE_SUMMARY" "origin/no-such-branch"
  run_gate "$d" pull_request ""
  assert_eq "an empty BASE_REF runs every part" "$(as_lines "$ALL")" "$GATE_OUT"
}

test_git_empty_diff_runs_every_part() {
  local d; d="$(mkrepo)"
  run_gate "$d" pull_request main
  assert_eq "an empty diff runs every part" "$(as_lines "$ALL")" "$GATE_OUT"
  assert_contains "the summary says the diff was empty" "$GATE_SUMMARY" "empty"
}

# Unrelated histories have no merge base, so the three-dot diff fails. Its
# stdout is empty either way; the summary is what shows which branch answered.
test_git_failing_diff_runs_every_part() {
  local d; d="$(mkrepo)"
  (
    cd "$d/repo" || exit 1
    git checkout -q --orphan unrelated
    git rm -q -r --cached .
    rm -rf docs relay phone README.md
    mkdir docs
    echo "# b" > docs/b.md
    git add -A
    git commit -q -m "unrelated history"
  )
  run_gate "$d" pull_request main
  assert_eq "a failing git diff runs every part" "$(as_lines "$ALL")" "$GATE_OUT"
  assert_contains "the summary says the diff failed" "$GATE_SUMMARY" "failed"
}

# The case that proves `--no-renames`: with rename detection on, `--name-only`
# prints only `docs/a.json`, which no part reads.
test_git_rename_out_of_test_vectors_runs_every_part() {
  local d; d="$(mkrepo)"
  (
    cd "$d/repo" || exit 1
    git mv phone/test-vectors/a.json docs/a.json
    git commit -q -m "move a test vector into docs"
  )
  run_gate "$d" pull_request main
  assert_eq "a test vector moved out of phone/test-vectors/ into docs/ runs every part" "$(as_lines "$ALL")" "$GATE_OUT"
  assert_contains "the summary lists the old path" "$GATE_SUMMARY" "\`phone/test-vectors/a.json\`"
}

# Three-dot: the base moving on after the PR forked must not count as the PR's
# change. A two-dot diff here would list the base's relay change and run it.
test_git_base_moving_on_does_not_count() {
  local d; d="$(mkrepo)"
  commit_change "$d" docs/a.md
  (
    cd "$d/repo" || exit 1
    git checkout -q main
    echo "// on main" >> relay/cloudflare/src/index.ts
    git commit -q -am "main moves on"
    git update-ref refs/remotes/origin/main HEAD
    git checkout -q feature
  )
  run_gate "$d" pull_request main
  assert_eq "a relay change on the base after the fork runs no part for a docs-only PR" "$(as_lines "$NONE")" "$GATE_OUT"
}

# The shape a `pull_request` run actually checks out: a merge of the PR into
# the base's tip.
test_git_merge_commit_checkout() {
  local d; d="$(mkrepo)"
  commit_change "$d" relay/cloudflare/src/index.ts
  (
    cd "$d/repo" || exit 1
    git checkout -q main
    echo "# more" >> README.md
    echo "<!-- more -->" >> phone/loader/index.html
    git commit -q -am "main moves on"
    git update-ref refs/remotes/origin/main HEAD
    git checkout -q --detach refs/remotes/origin/main
    git merge -q --no-ff --no-edit feature
  )
  run_gate "$d" pull_request main
  assert_eq "a relay-only PR's merge commit runs the relay alone" "$(as_lines "$RELAY")" "$GATE_OUT"
}

# A stacked PR: its base is another PR's branch, not `main`. That branch
# changed the loader since `main`; the PR on top of it changed only the relay.
# A gate that diffed against `main` whatever the base would run the loader too.
test_git_stacked_base() {
  local d base; d="$(mkrepo)"
  for base in feature-base acme/feature-base; do
    (
      cd "$d/repo" || exit 1
      git checkout -q -b "$base" main
      echo "<!-- base -->" >> phone/loader/index.html
      git commit -q -am "the base PR changes the loader"
      git update-ref "refs/remotes/origin/$base" HEAD
      git checkout -q -b "on-$base"
      echo "// on top" >> relay/cloudflare/src/index.ts
      git commit -q -am "the stacked PR changes the relay"
    )
    run_gate "$d" pull_request "$base"
    assert_eq "a relay-only PR on base '$base' runs the relay alone" "$(as_lines "$RELAY")" "$GATE_OUT"
    assert_contains "the summary names the relay change" "$GATE_SUMMARY" "\`relay/cloudflare/src/index.ts\` – relay"
    assert_lacks "the summary does not list the base PR's change" "$GATE_SUMMARY" "phone/loader/index.html"
  done
}

# ---------------------------------------------------------------------------
# 4. The verdict
# ---------------------------------------------------------------------------

# The `needs` context `Phone checks` sees: the gate's result and outputs (a
# JSON object), then the harness's and each part's result.
needs() {
  printf '{"changes":{"result":"%s","outputs":%s},"harness":{"result":"%s","outputs":{}},"relay":{"result":"%s","outputs":{}},"loader":{"result":"%s","outputs":{}},"phone-app":{"result":"%s","outputs":{}}}' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}
RUN_ALL='{"relay":"true","loader":"true","phone_app":"true"}'
RUN_LOADER_AND_APP='{"relay":"false","loader":"true","phone_app":"true"}'

# Run `--verdict` with NEEDS=$1. Sets V_RC, V_SUMMARY and V_STDERR.
run_verdict() {
  local d; d="$(scratch)"
  NEEDS="$1" GITHUB_STEP_SUMMARY="$d/summary" "$BASH" "$SCRIPT" --verdict >"$d/stdout" 2>"$d/stderr"
  V_RC=$?
  V_SUMMARY="$(cat "$d/summary" 2>/dev/null)"
  V_STDERR="$(cat "$d/stderr")"
}

# The exit status of `--verdict` with NEEDS=$1.
verdict_rc() { run_verdict "$1"; echo "$V_RC"; }

test_verdict_every_part_passed() {
  assert_eq "verdict: every part passed" "0" \
    "$(verdict_rc "$(needs success "$RUN_ALL" success success success success)")"
}

test_verdict_a_part_the_gate_skipped_passes() {
  assert_eq "verdict: a part the gate skipped passes" "0" \
    "$(verdict_rc "$(needs success "$RUN_LOADER_AND_APP" success skipped success success)")"
  assert_eq "verdict: every part the gate skipped passes" "0" \
    "$(verdict_rc "$(needs success '{"relay":"false","loader":"false","phone_app":"false"}' success skipped skipped skipped)")"
}

test_verdict_a_skip_the_gate_did_not_ask_for_fails() {
  assert_eq "verdict: a skip the gate did not ask for fails" "1" \
    "$(verdict_rc "$(needs success "$RUN_ALL" success skipped success success)")"
  assert_eq "verdict: a skip after a failed gate fails" "1" \
    "$(verdict_rc "$(needs failure '{}' success skipped success success)")"
  assert_eq "verdict: a skip with the gate's outputs missing fails" "1" \
    "$(verdict_rc '{"changes":{"result":"success"},"harness":{"result":"success"},"relay":{"result":"skipped"},"loader":{"result":"success"},"phone-app":{"result":"success"}}')"
  assert_eq "verdict: a skip when the gate's outputs are not an object fails" "1" \
    "$(verdict_rc "$(needs success '"false"' success skipped success success)")"
  assert_eq "verdict: a skip when the gate answered a JSON false, not the string, fails" "1" \
    "$(verdict_rc "$(needs success '{"relay":false,"loader":"true","phone_app":"true"}' success skipped success success)")"
}

test_verdict_a_failed_gate_with_every_part_run_passes() {
  assert_eq "verdict: a failed gate with every part run passes" "0" \
    "$(verdict_rc "$(needs failure '{}' success success success success)")"
}

test_verdict_a_cancelled_part_fails() {
  assert_eq "verdict: a cancelled part fails" "1" \
    "$(verdict_rc "$(needs success "$RUN_ALL" success success cancelled success)")"
  assert_eq "verdict: a cancelled part the gate would have skipped fails" "1" \
    "$(verdict_rc "$(needs success '{"relay":"true","loader":"false","phone_app":"true"}' success success cancelled success)")"
}

test_verdict_a_failed_part_fails() {
  assert_eq "verdict: a failed part fails" "1" \
    "$(verdict_rc "$(needs success "$RUN_ALL" success success success failure)")"
  assert_eq "verdict: a part with no result fails" "1" \
    "$(verdict_rc "$(needs success "$RUN_ALL" success success success '')")"
}

test_verdict_a_failed_harness_fails() {
  assert_eq "verdict: a failed harness fails" "1" \
    "$(verdict_rc "$(needs success "$RUN_ALL" failure success success success)")"
  assert_eq "verdict: a skipped harness fails" "1" \
    "$(verdict_rc "$(needs success "$RUN_ALL" skipped success success success)")"
}

test_verdict_a_missing_or_extra_job_fails() {
  run_verdict '{"changes":{"result":"success","outputs":{"relay":"true","loader":"true","phone_app":"true"}},"harness":{"result":"success"},"relay":{"result":"success"},"loader":{"result":"success"}}'
  assert_eq "verdict: a missing job fails" "1" "$V_RC"
  assert_contains "verdict: the failure names the jobs it must need" "$V_STDERR" \
    "must need exactly: changes harness relay loader phone-app"
  assert_eq "verdict: an extra job fails" "1" \
    "$(verdict_rc '{"changes":{"result":"success","outputs":{"relay":"true","loader":"true","phone_app":"true"}},"harness":{"result":"success"},"relay":{"result":"success"},"loader":{"result":"success"},"phone-app":{"result":"success"},"loader-webkit":{"result":"failure"}}')"
  assert_eq "verdict: a missing harness fails" "1" \
    "$(verdict_rc '{"changes":{"result":"success","outputs":{}},"relay":{"result":"success"},"loader":{"result":"success"},"phone-app":{"result":"success"}}')"
}

test_verdict_unreadable_needs_fails() {
  local d rc
  d="$(scratch)"
  "$BASH" "$SCRIPT" --verdict >/dev/null 2>"$d/stderr"
  rc=$?
  assert_eq "verdict: an unset NEEDS fails" "1" "$rc"
  assert_contains "verdict: the failure is an ::error::" "$(cat "$d/stderr")" "::error::"
  assert_eq "verdict: an empty NEEDS fails" "1" "$(verdict_rc '')"
  run_verdict 'not json'
  assert_eq "verdict: a NEEDS that is not JSON fails" "1" "$V_RC"
  assert_contains "verdict: the failure says NEEDS is unreadable" "$V_STDERR" "NEEDS is not one JSON object"
  assert_eq "verdict: a NEEDS that is a JSON array fails" "1" "$(verdict_rc '[]')"
  assert_eq "verdict: a NEEDS that is null fails" "1" "$(verdict_rc 'null')"
  assert_eq "verdict: a NEEDS of two objects fails" "1" \
    "$(verdict_rc "$(needs success "$RUN_ALL" success success success success) {}")"
  assert_eq "verdict: a job that is not an object fails" "1" \
    "$(verdict_rc '{"changes":{"result":"success","outputs":{}},"harness":"success","relay":{"result":"success"},"loader":{"result":"success"},"phone-app":{"result":"success"}}')"
}

# Without jq nothing can be read, so nothing passes.
test_verdict_no_jq_fails() {
  local d rc
  d="$(scratch)"
  mkdir "$d/empty-path"
  NEEDS="$(needs success "$RUN_ALL" success success success success)" PATH="$d/empty-path" \
    "$BASH" "$SCRIPT" --verdict >/dev/null 2>"$d/stderr"
  rc=$?
  assert_eq "verdict: no jq fails" "1" "$rc"
  assert_contains "verdict: the failure says jq is missing" "$(cat "$d/stderr")" "jq is not installed"
}

test_verdict_the_gates_false_is_exact() {
  assert_eq "verdict: the gate's false is exact" "1" \
    "$(verdict_rc "$(needs success '{"relay":"False","loader":"true","phone_app":"true"}' success skipped success success)")"
  assert_eq "verdict: a false with a trailing newline is not false" "1" \
    "$(verdict_rc "$(needs success '{"relay":"false\n","loader":"true","phone_app":"true"}' success skipped success success)")"
  assert_eq "verdict: a false with a trailing space is not false" "1" \
    "$(verdict_rc "$(needs success '{"relay":"false ","loader":"true","phone_app":"true"}' success skipped success success)")"
  assert_eq "verdict: the gate's false for another part does not count" "1" \
    "$(verdict_rc "$(needs success '{"relay":"true","loader":"false","phone_app":"true"}' success skipped success success)")"
}

test_verdict_the_summary_names_each_part() {
  run_verdict "$(needs success "$RUN_LOADER_AND_APP" success skipped success success)"
  assert_eq "verdict: a passing run exits 0" "0" "$V_RC"
  assert_line "verdict: the summary leads with the decision" "$V_SUMMARY" "### Phone checks: pass"
  assert_line "verdict: the summary names the gate's result" "$V_SUMMARY" "- changes (the gate): success"
  assert_line "verdict: the summary names the harness's result" "$V_SUMMARY" "- harness: success"
  assert_line "verdict: the summary names a part the gate skipped" "$V_SUMMARY" \
    "- relay: skipped – the gate answered \`false\`, so the gate skipped it"
  assert_line "verdict: the summary names a part that passed and the gate's answer" "$V_SUMMARY" \
    "- loader: success – the gate answered \`true\`"
  assert_line "verdict: the summary names phone-app by its job ID" "$V_SUMMARY" \
    "- phone-app: success – the gate answered \`true\`"

  run_verdict "$(needs failure '{}' success skipped cancelled success)"
  assert_eq "verdict: a failing run exits 1" "1" "$V_RC"
  assert_line "verdict: the summary leads with the failure" "$V_SUMMARY" "### Phone checks: fail"
  assert_line "verdict: the summary names a skip the gate did not ask for" "$V_SUMMARY" \
    "- relay: skipped – the gate answered nothing; only the gate's \`false\` may skip a part"
  assert_line "verdict: the summary names a cancelled part" "$V_SUMMARY" \
    "- loader: cancelled – the gate answered nothing"
  assert_contains "verdict: the failure is an ::error::" "$V_STDERR" "::error::Phone checks fail"
}

# ---------------------------------------------------------------------------
# 5. The workflow wiring, on this checkout
# ---------------------------------------------------------------------------
#
# The readers below take a workflow as this repo writes them: two-space
# indentation, one key per line, each step a `      - ` item. A workflow
# written another way gives them nothing to match, and every pin on it fails
# rather than passes.

REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOWS="$REPO_ROOT/.github/workflows"
PHONE_YML="$WORKFLOWS/phone.yml"
DEPLOY_YML="$WORKFLOWS/phone-loader-deploy.yml"
# The workflows that hold the phone parts' jobs. Each must exist.
PHONE_WORKFLOWS="phone.yml phone-loader-deploy.yml"

# FILE without its comment lines, and with trailing whitespace stripped.
wf_code() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null | sed 's/[[:space:]]*$//'; }

# The lines on stdin below the line exactly HEAD, up to the next non-blank
# line indented no deeper than HEAD.
under() {
  awk -v head="$1" '
    BEGIN { match(head, /^ */); depth = RLENGTH }
    inside && NF { match($0, /^ */); if (RLENGTH <= depth) inside = 0 }
    $0 == head { inside = 1; next }
    inside { print }
  '
}

# The lines of top-level key KEY in workflow FILE, such as `on`.
top_lines() { wf_code "$1" | under "$2:"; }

# The lines of job JOB in workflow FILE.
job_lines() { wf_code "$1" | under "jobs:" | under "  $2:"; }

# The job-level key lines of job JOB in workflow FILE.
job_keys() { job_lines "$1" "$2" | grep -E '^    [^[:space:]]'; }

# The job IDs of workflow FILE, one per line.
job_ids() {
  wf_code "$1" | under "jobs:" | grep -E '^  [^[:space:]]' | sed -E 's/^  ([^:]*):.*$/\1/'
}

# The lines of the first step in job JOB of workflow FILE that holds the key
# line WANT, such as `id: decide` — or, when the fourth argument is `prefix`,
# a key line that starts with WANT. The step's first line is printed with its
# `- ` turned into two spaces, so each of its keys reads at the same
# indentation whichever comes first.
step_lines() {
  job_lines "$1" "$2" | awk -v want="$3" -v prefix="${4:-}" '
    function flush() {
      if (open && hit && !done) { printf "%s", block; done = 1 }
      open = 0; block = ""
    }
    /^    [^[:space:]]/ { flush(); insteps = ($0 == "    steps:"); next }
    !insteps { next }
    /^      - / { flush(); open = 1; hit = 0; $0 = "        " substr($0, 9) }
    open {
      block = block $0 "\n"
      if ($0 == "        " want || (prefix == "prefix" && index($0, "        " want) == 1)) hit = 1
    }
    END { flush() }
  '
}

# The first line of each step in job JOB of workflow FILE that lacks the key
# line WANT, then a last line `steps=<how many steps the job has>`.
steps_lacking() {
  job_lines "$1" "$2" | awk -v want="$3" '
    function flush() { if (open && !hit) print first; open = 0 }
    /^    [^[:space:]]/ { flush(); insteps = ($0 == "    steps:"); next }
    !insteps { next }
    /^      - / { flush(); n++; open = 1; hit = 0; first = $0; $0 = "        " substr($0, 9) }
    open && $0 == ("        " want) { hit = 1 }
    END { flush(); print "steps=" (n + 0) }
  '
}

# Sets PARTS_LIST to `--list-parts`' output, and fails the run when it is
# empty, since every loop over it would then pass by checking nothing.
read_parts() {
  PARTS_LIST="$("$BASH" "$SCRIPT" --list-parts 2>/dev/null)"
  if [ -z "$PARTS_LIST" ]; then
    echo "FAIL - --list-parts printed no parts to check the wiring of"
    FAIL=1
  fi
}

# Succeeds when workflow NAME, one of PHONE_WORKFLOWS, exists. Fails the run
# when it does not, since its pins would otherwise read an empty file.
phone_workflow_exists() {
  if [ -f "$WORKFLOWS/$1" ]; then return 0; fi
  echo "FAIL - .github/workflows/$1 is missing"
  FAIL=1
  return 1
}

# The gate's three outputs are the decide step's, the decide step runs the
# classifier in its default mode with the two inputs it reads, and the
# checkout holds the history the three-dot diff needs. Without `fetch-depth: 0`
# `origin/<base>` does not resolve and the gate answers `true` for every part
# on every PR: no red anywhere, and nothing ever skips again.
test_phone_workflow_gate_wiring() {
  local outputs job key checkout decide
  read_parts
  outputs="$(job_lines "$PHONE_YML" changes | under '    outputs:')"
  while read -r job key; do
    [ -n "$key" ] || continue
    assert_line "the gate's $key output is the decide step's" "$outputs" \
      "      $key: \${{ steps.decide.outputs.$key }}"
  done <<< "$PARTS_LIST"

  checkout="$(step_lines "$PHONE_YML" changes 'uses: actions/checkout@' prefix)"
  assert_line "the gate's checkout keeps full history (fetch-depth: 0)" "$checkout" "          fetch-depth: 0"

  decide="$(step_lines "$PHONE_YML" changes 'id: decide')"
  assert_line "the step with id: decide runs the classifier with no arguments" "$decide" \
    "        run: bash scripts/ci/phone-parts-needed.sh"
  assert_line "the decide step passes the event name" "$decide" \
    "          EVENT_NAME: \${{ github.event_name }}"
  assert_line "the decide step passes the PR's base branch" "$decide" \
    "          BASE_REF: \${{ github.base_ref }}"
}

# Each part is skipped only by its own `if:`, and only on the gate's exact
# `false`. Without `!cancelled()` GitHub adds an implicit `success()`, so a
# failed gate would skip every part. `continue-on-error` anywhere would let a
# failure read as a pass: on a step, the job no longer fails; on a job, its
# result in `needs` is no longer its failure.
test_phone_workflow_part_wiring() {
  local job key keys tolerant
  read_parts
  while read -r job key; do
    [ -n "$key" ] || continue
    keys="$(job_keys "$PHONE_YML" "$job")"
    if [ -z "$keys" ]; then
      echo "FAIL - phone.yml has no job \`$job\`, which --list-parts names"
      FAIL=1
      continue
    fi
    assert_line "the $job job waits for the gate" "$keys" "    needs: changes"
    assert_line "the $job job skips only on the gate's explicit false, and still runs after a failed gate" \
      "$keys" "    if: \${{ !cancelled() && needs.changes.outputs.$key != 'false' }}"
  done <<< "$PARTS_LIST"

  tolerant="$(wf_code "$PHONE_YML" | grep -E '^[[:space:]]+(- )?continue-on-error:')"
  assert_eq "no job or step in phone.yml sets continue-on-error" "" "$tolerant"
}

# `Phone checks` runs, and its verdict runs, whatever happened before it. A
# job skipped for any reason reports success to branch protection, and so does
# a job whose every step was skipped, so a missing `always()` on the job or on
# any step lets a cancelled or half-run workflow pass.
test_phone_checks_wiring() {
  local keys job key want lacking steps verdict
  read_parts
  keys="$(job_keys "$PHONE_YML" phone-checks)"
  assert_line "the phone-checks job is named Phone checks, the required context" "$keys" "    name: Phone checks"
  assert_line "the phone-checks job runs whatever happened before it" "$keys" "    if: \${{ always() }}"
  want="changes, harness"
  while read -r job key; do
    [ -n "$job" ] || continue
    want="$want, $job"
  done <<< "$PARTS_LIST"
  assert_line "the phone-checks job needs the gate, the harness and every part, in order" "$keys" "    needs: [$want]"

  # shellcheck disable=SC2016 # a GitHub expression, matched literally
  lacking="$(steps_lacking "$PHONE_YML" phone-checks 'if: ${{ always() }}')"
  steps="$(printf '%s\n' "$lacking" | sed -n 's/^steps=//p')"
  if [ "${steps:-0}" -gt 0 ]; then
    echo "ok   - the phone-checks job has $steps steps to check"
  else
    echo "FAIL - found no steps in the phone-checks job"
    FAIL=1
  fi
  assert_eq "every step of the phone-checks job carries if: \${{ always() }}" "" \
    "$(printf '%s\n' "$lacking" | grep -v '^steps=')"

  verdict="$(step_lines "$PHONE_YML" phone-checks 'run: bash scripts/ci/phone-parts-needed.sh --verdict')"
  assert_line "a phone-checks step runs the verdict" "$verdict" \
    "        run: bash scripts/ci/phone-parts-needed.sh --verdict"
  assert_line "the verdict step reads the needs context" "$verdict" \
    "          NEEDS: \${{ toJSON(needs) }}"
}

# Both harnesses run here, where their result reaches the required check.
test_harness_job_runs_both_harnesses() {
  local harness step
  for harness in phone-parts-needed phone-app-bundle-check; do
    step="$(step_lines "$PHONE_YML" harness "run: bash scripts/ci/$harness.test.sh")"
    if [ -n "$step" ]; then
      echo "ok   - the harness job runs scripts/ci/$harness.test.sh"
    else
      echo "FAIL - the harness job does not run scripts/ci/$harness.test.sh"
      FAIL=1
    fi
  done
}

# A workflow that a path filter keeps from starting never reports, and a
# required `Phone checks` that never reports stays pending, so every PR that
# touched no phone path could not merge. The `changes` job is the filter.
test_phone_workflow_has_no_path_filter() {
  assert_eq "phone.yml has no paths: or paths-ignore: filter" "" \
    "$(wf_code "$PHONE_YML" | grep -E '^[[:space:]]*(paths|paths-ignore):')"
}

# A branch filter on `pull_request` would give a stacked PR, whose base is
# another PR's branch, no Phone run, and so no `Phone checks`.
test_phone_workflow_runs_on_every_pr() {
  local on
  on="$(top_lines "$PHONE_YML" on)"
  assert_line "phone.yml runs on pull_request" "$on" "  pull_request:"
  assert_eq "the pull_request trigger has no branches: or branches-ignore: filter" "" \
    "$(printf '%s\n' "$on" | under '  pull_request:' | grep -E '^[[:space:]]+(branches|branches-ignore):')"
  assert_line "phone.yml runs on push" "$on" "  push:"
  assert_line "the push trigger is limited to main" \
    "$(printf '%s\n' "$on" | under '  push:')" "    branches: [main]"
  assert_line "phone.yml can be dispatched" "$on" "  workflow_dispatch:"
}

# Its own group: sharing test.yml's would let a push cancel the other
# workflow's run, and with it a required check.
test_phone_workflow_concurrency() {
  # shellcheck disable=SC2016 # a GitHub expression, matched literally
  local want='  group: phone-${{ github.head_ref || github.ref_name }}'
  assert_line "phone.yml has its own concurrency group" "$(top_lines "$PHONE_YML" concurrency)" "$want"
  if has_line "$(top_lines "$WORKFLOWS/test.yml" concurrency)" "$want"; then
    echo "FAIL - phone.yml's concurrency group is test.yml's"
    FAIL=1
  else
    echo "ok   - phone.yml's concurrency group differs from test.yml's"
  fi
}

# GitHub's default is 360 minutes, and a job that wedges without a bound
# leaves its check unreported for six hours.
test_every_new_job_has_a_timeout() {
  local name file ids job timeout
  for name in $PHONE_WORKFLOWS; do
    phone_workflow_exists "$name" || continue
    file="$WORKFLOWS/$name"
    ids="$(job_ids "$file")"
    if [ -z "$ids" ]; then
      echo "FAIL - found no jobs in $name"
      FAIL=1
      continue
    fi
    while read -r job; do
      # No `grep -q`: under `pipefail`, its early exit can SIGPIPE the writer
      # and turn a match into a miss.
      timeout="$(job_keys "$file" "$job" | grep -E '^    timeout-minutes:[[:space:]]*[0-9]+$')"
      if [ -n "$timeout" ]; then
        echo "ok   - $name: the $job job has a timeout-minutes"
      else
        echo "FAIL - $name: the $job job has no job-level timeout-minutes"
        FAIL=1
      fi
    done <<< "$ids"
  done
}

# Branch protection matches a required check by job name: a job keyed `test`
# with no name reports as `test`. A second `Phone checks`, or a new job that
# reports as `test`, `Lint` or `claude-review`, would report into a required
# context that it does not own.
test_required_names_are_not_reused() {
  local hits name file taken
  hits="$(grep -HnE "^    name:[[:space:]]*[\"']?Phone checks[\"']?[[:space:]]*$" \
    "$WORKFLOWS"/*.yml "$WORKFLOWS"/*.yaml 2>/dev/null)"
  assert_eq "exactly one job across .github/workflows is named Phone checks" "1" \
    "$(printf '%s\n' "$hits" | grep -c .)"
  assert_contains "the one job named Phone checks is in phone.yml" "$hits" "$PHONE_YML:"

  for name in $PHONE_WORKFLOWS; do
    phone_workflow_exists "$name" || continue
    file="$WORKFLOWS/$name"
    taken="$(
      {
        job_ids "$file"
        wf_code "$file" | under "jobs:" | grep -E '^    name:' |
          sed -E "s/^    name:[[:space:]]*//; s/^[\"']//; s/[\"']$//"
      } | tr '[:upper:]' '[:lower:]' | grep -xE 'test|lint|claude-review'
    )"
    assert_eq "$name: no job is keyed or named test, lint or claude-review" "" "$taken"
  done
}

# The classifier runs every part for `scripts/*phone*` and none for other
# scripts. A step here that ran some other script would leave a change to that
# script, which changes what a part tests, skipping that part. Every
# `scripts/…` path on a code line counts, not only `run:` lines, so a
# multi-line `run: |` block is read too.
test_phone_workflow_scripts_run_every_part() {
  local paths path got
  paths="$(wf_code "$PHONE_YML" | grep -oE 'scripts/[A-Za-z0-9_./-]+' | sed 's/\.*$//' | sort -u)"
  if [ -z "$paths" ]; then
    echo "FAIL - phone.yml names no script, so this check would check nothing"
    FAIL=1
    return
  fi
  while read -r path; do
    got="$(printf '%s\n' "$path" | "$BASH" "$SCRIPT" --classify 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
    if [ "$got" = "$ALL" ]; then
      echo "ok   - phone.yml runs $path, and a change to it runs every part"
    else
      echo "FAIL - phone.yml runs $path, but a change to it alone answers [$got], so a part could skip while its test changed."
      echo "     Give it a rule in judge() in scripts/ci/phone-parts-needed.sh that runs every part."
      FAIL=1
    fi
  done <<< "$paths"
}

# A local action's files would live under `.github/`, which runs no part, so
# a change to one would skip every part that uses it.
test_phone_workflow_uses_no_local_action() {
  local local_uses
  local_uses="$(wf_code "$PHONE_YML" | grep -E "uses:[[:space:]]*[\"']?\\./")"
  if [ -z "$local_uses" ]; then
    echo "ok   - phone.yml uses no local action or reusable workflow"
  else
    echo "FAIL - phone.yml uses a local action or reusable workflow, whose files run no part:"
    printf '%s\n' "$local_uses" | sed 's/^/       /'
    echo "     Add a rule in judge() in scripts/ci/phone-parts-needed.sh that runs every part for its files first, then update this check."
    FAIL=1
  fi
}

# ---------------------------------------------------------------------------
# 6. The loader deploy wiring, on this checkout
# ---------------------------------------------------------------------------
#
# `phone-loader-deploy.yml` holds the key that starts a deploy of the code
# that handles the phone's keys. Each pin below is one of the fences between
# that key and anything but a tested commit on main.

# A push to main that touches the loader, and a dispatch: nothing else. No
# pull request event can start it, `pull_request_target` least of all, which
# runs in the base branch's context, where `github.ref` is main.
test_deploy_workflow_triggers() {
  local on push paths
  phone_workflow_exists phone-loader-deploy.yml || return
  on="$(top_lines "$DEPLOY_YML" on)"
  assert_eq "the deploy runs on a push and a dispatch, and on nothing else" "  push:
  workflow_dispatch:" "$(printf '%s\n' "$on" | grep -E '^  [^[:space:]]')"
  push="$(printf '%s\n' "$on" | under '  push:')"
  assert_line "the deploy's push trigger is limited to main" "$push" "    branches: [main]"
  paths="$(printf '%s\n' "$push" | under '    paths:')"
  assert_line "the deploy's push trigger runs for the loader" "$paths" "      - 'phone/loader/**'"
  assert_line "the deploy's push trigger runs for this workflow" "$paths" \
    "      - '.github/workflows/phone-loader-deploy.yml'"
}

# Nothing in the workflow can write to this repo: no job gets a permission it
# does not name, the verify job names only `contents: read`, and the App token
# asks for nothing on contents.
test_deploy_workflow_permissions() {
  local verify writes
  phone_workflow_exists phone-loader-deploy.yml || return
  assert_eq "the deploy's top-level permissions are empty" "permissions: {}" \
    "$(wf_code "$DEPLOY_YML" | grep -E '^permissions:')"
  verify="$(job_lines "$DEPLOY_YML" verify | under '    permissions:')"
  assert_eq "the verify job reads contents and has no other permission" "      contents: read" "$verify"
  writes="$(grep -nE 'contents:[[:space:]]*write|permission-contents' "$DEPLOY_YML")"
  assert_eq "no line of the deploy workflow asks to write contents" "" "$writes"
}

# The dispatch runs only after the loader passed, only while the variable is
# exactly `true`, only from main, and only in the environment whose
# deployment branches admit only main. The `if:` is pinned whole: a line
# holding both halves joined by `||` would deploy whenever either held.
test_deploy_dispatch_is_gated() {
  local keys
  phone_workflow_exists phone-loader-deploy.yml || return
  keys="$(job_keys "$DEPLOY_YML" dispatch)"
  assert_line "the dispatch job waits for the loader to pass" "$keys" "    needs: verify"
  assert_line "the dispatch job runs in the phone-loader environment" "$keys" "    environment: phone-loader"
  assert_line "the dispatch job's own token has no permissions" "$keys" "    permissions: {}"
  assert_line "the dispatch job runs only while deploys are on, and only from main" "$keys" \
    "    if: \${{ vars.PHONE_LOADER_DEPLOY_ENABLED == 'true' && github.ref == 'refs/heads/main' }}"
}

# One App token in the workflow, minted for the one loader repo with one
# permission, Actions: write. Without `owner:` and `repositories:` the token
# would cover whatever the installation covers. The App key is the
# workflow's only secret, and only the token step reads it.
test_deploy_token_can_only_dispatch() {
  local step
  phone_workflow_exists phone-loader-deploy.yml || return
  assert_eq "exactly one step mints an App token" "1" \
    "$(wf_code "$DEPLOY_YML" | grep -cE '^[[:space:]]+(- )?uses:[[:space:]]*actions/create-github-app-token@')"
  step="$(step_lines "$DEPLOY_YML" dispatch 'uses: actions/create-github-app-token@v2')"
  assert_line "the dispatch job's token step uses create-github-app-token@v2" "$step" \
    "        uses: actions/create-github-app-token@v2"
  assert_eq "the token's one permission is actions: write" "          permission-actions: write" \
    "$(wf_code "$DEPLOY_YML" | grep -E '^[[:space:]]+permission-')"
  assert_line "the token step reads the loader org from a variable" "$step" \
    "          owner: \${{ vars.PHONE_LOADER_OWNER }}"
  assert_line "the token step reads the loader repo from a variable" "$step" \
    "          repositories: \${{ vars.PHONE_LOADER_REPO }}"
  assert_eq "the App key is the workflow's only secret" \
    "          private-key: \${{ secrets.PHONE_LOADER_APP_PRIVATE_KEY }}" \
    "$(wf_code "$DEPLOY_YML" | grep -E 'secrets\.')"
  assert_line "the token step is the one that reads the App key" "$step" \
    "          private-key: \${{ secrets.PHONE_LOADER_APP_PRIVATE_KEY }}"
}

# ---------------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  echo "--- $t"
  "$t"
done

if [ "$FAIL" -eq 0 ]; then
  echo "All phone-parts-needed tests passed."
else
  echo "Some phone-parts-needed tests FAILED."
fi
exit "$FAIL"
