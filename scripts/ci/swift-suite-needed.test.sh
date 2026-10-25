#!/usr/bin/env bash
# Tests for scripts/ci/swift-suite-needed.sh — run:
#   /bin/bash scripts/ci/swift-suite-needed.test.sh
#
# Three kinds of case, all needed:
#
#   - THE RULE, through `--classify`: each skip rule alone skips, each of the
#     suite's own scripts alone runs, and anything the rules do not name runs.
#   - THE GIT PATH, against throwaway repositories: three-dot against the base,
#     `--no-renames`, the event short-circuit, and every can't-answer-honestly
#     shape answering `run=true` with exactly one `run=` line.
#   - THE DRIFT CHECK, against THIS checkout: every script the suite can reach
#     — the two wrappers, a script named by the `test` job, a `"scripts/…"`
#     literal in a Swift file, and then whatever any of those names or loads
#     with `source` / `.`, all the way down, except through the two stops
#     below — must be on the gate's list of suite scripts. The skip is only as
#     good as that list: a script the suite came to depend on without being
#     added would let a PR that changes only that script skip the suite that
#     would have caught it. The gatherer itself is proven on a fixture tree
#     first, so a broken gatherer cannot pass the real check by gathering
#     nothing. The same case fails on a local action in the `test` job, whose
#     files would sit under the skip-listed `.github/**`.
#   - THE WIRING, read out of the real workflow: `needs`, the `if:`, the job's
#     missing `name:`, and the gate's output. No fixture can execute a GitHub
#     expression, and these are what make the gate fail closed.
#
# RUN WITH `/bin/bash`, WHICH ON MACOS IS 3.2 — the Lint job does. Every nested
# run of the script under test goes through `$BASH`, this harness's own
# interpreter, so the whole run stays on whichever bash started it. The gate
# runs on Linux under bash 5 in CI, but a developer replays it over merged PRs
# on a Mac, so it has to work under both.
#
# ZERO BUILDS. The only real things read are this checkout's
# `.github/workflows/test.yml`, `scripts/`, and the Swift files under `Sources/`
# and `Tests/`. Every other case mints a throwaway directory under `mktemp -d`;
# nothing is written outside one.
#
# THE FIXTURE REPOS ARE FENCED OFF FROM THE DEVELOPER'S GIT CONFIG: each sets
# its own identity, turns signing off, and turns rename detection ON in local
# config, so the `--no-renames` case tests the flag rather than whatever
# `diff.renames` the machine happens to have.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/swift-suite-needed.sh"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
TAB="$(printf '\t')"
# Byte order and byte-wise character classes, so `sort` and the name patterns
# behave the same on every machine.
export LC_ALL=C

# In CI this harness runs inside a step whose own `$GITHUB_OUTPUT` and
# `$GITHUB_STEP_SUMMARY` are live. A case that does not set them must not write
# into them, and must read the answer from stdout instead. A git hook's own
# `GIT_DIR` and friends would point every fixture's `git` at this checkout.
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY EVENT_NAME BASE_REF \
      GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

FAIL=0
assert_eq()       { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { case "$2" in *"$3"*) echo "ok   - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]" ; FAIL=1 ;; esac; }
assert_lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: [$2] holds [$3]" ; FAIL=1 ;; *) echo "ok   - $1" ;; esac; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/swift-suite-needed-test.XXXXXX"; }

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

# The answer `--classify` gives for the paths after the label and expectation.
expect() {
  local label="$1" want="$2"; shift 2
  assert_eq "$label" "run=$want" "$(printf '%s\n' "$@" | "$BASH" "$SCRIPT" --classify 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# 1. The spec's case table, the parts that need no git
# ---------------------------------------------------------------------------

test_docs_only_skips() {
  expect "docs only skips" false \
    docs/specs/2026-01-01-example-design.md docs/updating.md
}

test_one_swift_file_runs() {
  expect "one Swift file runs" true Sources/TBDShared/Models.swift
  expect "one Swift file among docs runs" true \
    docs/updating.md Sources/TBDShared/Models.swift README.md
}

test_the_workflow_that_runs_the_suite_runs() {
  expect ".github/workflows/test.yml runs" true .github/workflows/test.yml
}

test_restart_sh_runs() {
  expect "scripts/restart.sh runs" true scripts/restart.sh
}

test_an_unused_script_skips() {
  expect "an unused script skips" false scripts/update.sh
}

# `Sources/TBDApp/Resources/markdown-stylesheets.md` ships in the app.
test_markdown_under_sources_runs() {
  expect "Markdown under Sources/ runs" true Sources/TBDApp/Resources/markdown-stylesheets.md
  expect "Markdown under Tests/ runs" true Tests/CLAUDE.md
}

# ---------------------------------------------------------------------------
# 2. Each skip rule, alone
# ---------------------------------------------------------------------------

test_each_skip_rule_skips_alone() {
  expect "docs/** skips"                          false docs/reclaim-build.md
  expect "a top-level *.md skips"                 false README.md
  expect "a nested *.md outside the trees skips"  false recipe/notes/README.md
  expect "*.md beats the suite-script exception"  false scripts/ci/README.md
  expect ".claude/** skips"                       false .claude/hooks/guardrails/dispatch.py
  expect ".github/** skips"                       false .github/workflows/claude-code-review.yml
  expect "a review-gate script skips"             false .github/workflows/claude-review-v2/prepare.py
  expect "SessionMod/** skips"                    false SessionMod/src/index.ts
  expect "recipe/** skips"                        false recipe/x
  expect "tools/** skips"                         false tools/x
  expect "an unused Python script skips"          false scripts/flake-pr.py
  expect "a git hook skips"                       false scripts/git-hooks/pre-push
  expect "a restart library's harness skips"      false scripts/restart-build-lib.test.sh
  expect "a sibling of scripts/ci/ skips"         false scripts/ci.sh
  expect "every rule at once skips"               false \
    docs/x.md README.md .claude/settings.json .github/workflows/flake-fixer.yml \
    SessionMod/package.json recipe/x tools/x scripts/update.sh
}

# ---------------------------------------------------------------------------
# 3. Each of the suite's own scripts, alone. Spelled out here rather than read
#    from `--list-suite-scripts`, so dropping an entry from the script's list
#    reddens a case instead of quietly shrinking it.
# ---------------------------------------------------------------------------

test_each_suite_script_runs_alone() {
  local path
  for path in \
    scripts/test.sh \
    scripts/swift-safe \
    scripts/ci/watched-test-pass.sh \
    scripts/ci/first-party-wipe-needed.sh \
    scripts/ci/swift-suite-needed.sh \
    scripts/ci/swift-suite-needed.test.sh \
    scripts/ci/a-script-added-later.sh \
    scripts/dsym-prune-lib.sh \
    scripts/tbd-home-fingerprint.sh \
    scripts/remote-verify.sh \
    scripts/repair-spm-workspace.sh \
    scripts/restart.sh \
    scripts/restart-build-lib.sh \
    scripts/restart-bundle-lib.sh \
    scripts/restart-environment-lib.sh \
    scripts/restart-guard-lib.sh
  do
    expect "$path runs" true "$path"
  done
}

test_list_suite_scripts_prints_the_list() {
  local out rc
  out="$("$BASH" "$SCRIPT" --list-suite-scripts 2>/dev/null)"
  rc=$?
  assert_eq "--list-suite-scripts exits 0" "0" "$rc"
  assert_contains "the list names scripts/test.sh" "$out" "scripts/test.sh"
  assert_contains "the list carries the restart-library pattern" "$out" "scripts/restart-*-lib.sh"
  assert_lacks "the list writes no answer" "$out" "run="
}

# ---------------------------------------------------------------------------
# 4. Everything the rules do not name runs the suite
# ---------------------------------------------------------------------------

test_unnamed_paths_run() {
  expect "Package.swift runs"                 true Package.swift
  expect "Package.resolved runs"              true Package.resolved
  expect "a test file runs"                   true Tests/TBDDaemonTests/ExampleTests.swift
  expect "rust/ runs"                         true rust/comrak-ffi/src/lib.rs
  expect "Resources/ runs"                    true Resources/AppIcon.png
  expect "a new top-level directory runs"     true foo/bar
  expect "a top-level dotfile runs"           true .swiftlint.yml
  expect "a near-miss of docs/ runs"          true docsy/x.txt
  expect "a near-miss of .claude/ runs"       true .claude-plugin/plugin.json
  expect "a file named docs runs"             true docs
}

# ---------------------------------------------------------------------------
# 5. Input handling — a path dropped on the floor could be the one that runs
# ---------------------------------------------------------------------------

test_empty_input_runs() {
  assert_eq "empty input runs" "run=true" "$(printf '' | "$BASH" "$SCRIPT" --classify 2>/dev/null)"
  assert_eq "input of blank lines runs" "run=true" "$(printf '\n\n' | "$BASH" "$SCRIPT" --classify 2>/dev/null)"
}

test_last_path_without_a_terminator_counts() {
  assert_eq "an unterminated last line is judged" "run=true" \
    "$(printf 'docs/a.md\nSources/b.swift' | "$BASH" "$SCRIPT" --classify 2>/dev/null)"
  assert_eq "an unterminated last NUL record is judged" "run=true" \
    "$(printf 'docs/a.md\000Sources/b.swift' | "$BASH" "$SCRIPT" --classify 2>/dev/null)"
}

test_nul_separated_input() {
  assert_eq "NUL-separated docs skip" "run=false" \
    "$(printf 'docs/a.md\000README.md\000' | "$BASH" "$SCRIPT" --classify 2>/dev/null)"
  assert_eq "NUL-separated with a Swift file runs" "run=true" \
    "$(printf 'docs/a.md\000Sources/b.swift\000' | "$BASH" "$SCRIPT" --classify 2>/dev/null)"
}

test_blank_lines_are_ignored() {
  assert_eq "blank lines between skippable paths still skip" "run=false" \
    "$(printf 'docs/a.md\n\nREADME.md\n' | "$BASH" "$SCRIPT" --classify 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# 6. The output contract
# ---------------------------------------------------------------------------

test_summary_names_each_file_and_its_rule() {
  local d out stdout
  d="$(scratch)"
  stdout="$(printf 'docs/a.md\nSources/b.swift\n' |
    GITHUB_OUTPUT="$d/output" GITHUB_STEP_SUMMARY="$d/summary" "$BASH" "$SCRIPT" --classify 2>/dev/null)"
  out="$(cat "$d/output")"
  assert_eq "the answer goes to \$GITHUB_OUTPUT" "run=true" "$out"
  assert_eq "nothing goes to stdout when \$GITHUB_OUTPUT is set" "" "$stdout"
  assert_contains "the summary leads with the decision" "$(head -1 "$d/summary")" "the suite runs"
  assert_contains "the summary names a skipped file and its rule" "$(cat "$d/summary")" \
    "- skip – \`docs/a.md\` – docs/**"
  assert_contains "the summary names a file that runs the suite" "$(cat "$d/summary")" \
    "- runs the suite – \`Sources/b.swift\` –"
}

test_skip_summary_says_skipped() {
  local d
  d="$(scratch)"
  printf 'docs/a.md\n' |
    GITHUB_OUTPUT="$d/output" GITHUB_STEP_SUMMARY="$d/summary" "$BASH" "$SCRIPT" --classify >/dev/null 2>&1
  assert_eq "a docs-only answer is false" "run=false" "$(cat "$d/output")"
  assert_contains "the summary says the suite is skipped" "$(head -1 "$d/summary")" "the suite is skipped"
}

# A skip with no record of why is refused: the answer turns to `true`.
test_unwritable_summary_runs() {
  local d
  d="$(scratch)"
  printf 'docs/a.md\n' |
    GITHUB_OUTPUT="$d/output" GITHUB_STEP_SUMMARY="$d/no-such-dir/summary" "$BASH" "$SCRIPT" --classify >/dev/null 2>&1
  assert_eq "an unwritable summary turns a skip into a run" "run=true" "$(cat "$d/output")"
}

test_malformed_invocations_answer_nothing() {
  local d rc
  d="$(scratch)"
  : > "$d/output"
  GITHUB_OUTPUT="$d/output" "$BASH" "$SCRIPT" --wat >"$d/stdout" 2>/dev/null
  rc=$?
  assert_eq "an unknown option exits 64" "64" "$rc"
  assert_eq "an unknown option writes no answer" "" "$(cat "$d/output" "$d/stdout")"
  GITHUB_OUTPUT="$d/output" "$BASH" "$SCRIPT" --classify extra </dev/null >"$d/stdout" 2>/dev/null
  rc=$?
  assert_eq "a stray argument exits 64" "64" "$rc"
  assert_eq "a stray argument writes no answer" "" "$(cat "$d/output" "$d/stdout")"
}

# ---------------------------------------------------------------------------
# 7. The git path, against throwaway repositories
# ---------------------------------------------------------------------------

# A fixture holding `repo/`, a clone-shaped repository whose `origin/main` is
# its first commit and whose `feature` branch is checked out. Echoes the
# fixture directory.
mkrepo() {
  local d; d="$(scratch)"
  mkdir -p "$d/repo/docs" "$d/repo/Sources/TBDApp"
  echo "# a"           > "$d/repo/docs/a.md"
  echo "struct App {}" > "$d/repo/Sources/TBDApp/App.swift"
  echo "# readme"      > "$d/repo/README.md"
  (
    cd "$d/repo" || exit 1
    git -c init.defaultBranch=main init -q .
    git config user.email "harness@example.invalid"
    git config user.name "Suite Gate Harness"
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

test_git_docs_only_pr_skips() {
  local d; d="$(mkrepo)"
  commit_change "$d" docs/a.md
  commit_change "$d" docs/new.md
  run_gate "$d" pull_request main
  assert_eq "a docs-only PR exits 0" "0" "$GATE_RC"
  assert_eq "a docs-only PR writes exactly one line, run=false" "run=false" "$GATE_OUT"
  assert_eq "nothing reaches stdout" "" "$GATE_STDOUT"
  assert_contains "the summary names the changed file" "$GATE_SUMMARY" "\`docs/new.md\`"
}

test_git_swift_change_runs() {
  local d; d="$(mkrepo)"
  commit_change "$d" docs/a.md
  commit_change "$d" Sources/TBDApp/App.swift
  run_gate "$d" pull_request main
  assert_eq "a PR touching a Swift file writes exactly one line, run=true" "run=true" "$GATE_OUT"
}

# A rename INTO `Sources/` runs with or without `--no-renames`: rename
# detection lists the new path, which is under `Sources/` either way. It pins
# only that a rename is judged at all; the reverse move below is the spec's
# case and the one that proves the flag.
test_git_rename_from_docs_into_sources_runs() {
  local d; d="$(mkrepo)"
  (
    cd "$d/repo" || exit 1
    git mv docs/a.md Sources/TBDApp/a.md
    git commit -q -m "move a doc into Sources"
  )
  run_gate "$d" pull_request main
  assert_eq "a rename from docs/ into Sources/ runs" "run=true" "$GATE_OUT"
}

# The spec's case, and the one that proves `--no-renames`: with rename
# detection on, `--name-only` prints only `docs/App.swift`, which would skip.
test_git_rename_out_of_sources_runs() {
  local d; d="$(mkrepo)"
  (
    cd "$d/repo" || exit 1
    git mv Sources/TBDApp/App.swift docs/App.swift
    git commit -q -m "move a Swift file into docs"
  )
  run_gate "$d" pull_request main
  assert_eq "a Swift file moved out of Sources/ into docs/ runs" "run=true" "$GATE_OUT"
  assert_contains "the summary lists the old path" "$GATE_SUMMARY" "\`Sources/TBDApp/App.swift\`"
}

test_git_empty_diff_runs() {
  local d; d="$(mkrepo)"
  run_gate "$d" pull_request main
  assert_eq "an empty diff runs" "run=true" "$GATE_OUT"
  assert_contains "the summary says the diff was empty" "$GATE_SUMMARY" "empty"
}

test_git_missing_base_ref_runs() {
  local d; d="$(mkrepo)"
  commit_change "$d" docs/a.md
  run_gate "$d" pull_request no-such-branch
  assert_eq "a base ref that does not resolve runs" "run=true" "$GATE_OUT"
  assert_contains "the summary names the unresolved ref" "$GATE_SUMMARY" "origin/no-such-branch"
  run_gate "$d" pull_request ""
  assert_eq "an empty BASE_REF runs" "run=true" "$GATE_OUT"
}

# Unrelated histories have no merge base, so the three-dot diff fails. Its
# stdout is empty either way; the summary is what shows which branch answered.
test_git_failing_diff_runs() {
  local d; d="$(mkrepo)"
  (
    cd "$d/repo" || exit 1
    git checkout -q --orphan unrelated
    git rm -q -r --cached .
    rm -rf docs Sources README.md
    mkdir docs
    echo "# b" > docs/b.md
    git add -A
    git commit -q -m "unrelated history"
  )
  run_gate "$d" pull_request main
  assert_eq "a failing git diff runs" "run=true" "$GATE_OUT"
  assert_contains "the summary says the diff failed" "$GATE_SUMMARY" "failed"
}

test_git_non_pr_events_run() {
  local d event; d="$(mkrepo)"
  commit_change "$d" docs/a.md
  for event in push workflow_dispatch ""; do
    run_gate "$d" "$event" main
    assert_eq "a '${event:-empty}' event runs a docs-only change" "run=true" "$GATE_OUT"
  done
  : > "$d/output"
  ( cd "$d/repo" && GITHUB_OUTPUT="$d/output" "$BASH" "$SCRIPT" >/dev/null 2>&1 )
  assert_eq "an unset EVENT_NAME runs" "run=true" "$(cat "$d/output")"
}

# Three-dot: the base moving on after the PR forked must not count as the PR's
# change. A two-dot diff here would list the base's Swift change and run.
test_git_base_moving_on_does_not_count() {
  local d; d="$(mkrepo)"
  commit_change "$d" docs/a.md
  (
    cd "$d/repo" || exit 1
    git checkout -q main
    echo "// on main" >> Sources/TBDApp/App.swift
    git commit -q -am "main moves on"
    git update-ref refs/remotes/origin/main HEAD
    git checkout -q feature
  )
  run_gate "$d" pull_request main
  assert_eq "a Swift change on the base after the fork does not run a docs-only PR" "run=false" "$GATE_OUT"
}

# The shape a `pull_request` run actually checks out: a merge of the PR into
# the base's tip.
test_git_merge_commit_checkout() {
  local d; d="$(mkrepo)"
  commit_change "$d" docs/a.md
  (
    cd "$d/repo" || exit 1
    git checkout -q main
    echo "# more" >> README.md
    git commit -q -am "main moves on"
    git update-ref refs/remotes/origin/main HEAD
    git checkout -q --detach refs/remotes/origin/main
    git merge -q --no-ff --no-edit feature
  )
  run_gate "$d" pull_request main
  assert_eq "a docs-only PR's merge commit skips" "run=false" "$GATE_OUT"
}

# ---------------------------------------------------------------------------
# 8. The drift check and the workflow wiring
# ---------------------------------------------------------------------------

# Lines that are not `#` comments.
code_lines() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null; }

# The lines of job JOB in ROOT's test.yml: after `  JOB:`, up to the next job
# key or top-level key.
job_lines() {
  awk -v head="  $2:" '
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    line == head { inside = 1; next }
    inside && /^(  )?[^[:space:]#]/ { inside = 0 }
    inside { print }
  ' "$1/.github/workflows/test.yml" 2>/dev/null
}

suite_job_lines() { job_lines "$1" test; }

# The lines of the step whose `id:` is ID in job JOB of ROOT's test.yml, from
# its `      - ` line up to the next step or job-level key.
step_lines() {
  job_lines "$1" "$2" | awk -v id="$3" '
    /^      - / { if (hit) exit; block = "" }
    /^    [^[:space:]#]/ { if (hit) exit; block = ""; next }
    { block = block $0 "\n" }
    $0 ~ ("^      (- |  )id: " id "[[:space:]]*$") { hit = 1 }
    END { if (hit) printf "%s", block }
  '
}

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

# A line that loads a file into the running shell: `source` or `.` at the
# start of a command.
LOAD_LINE='(^|;|&&|\|\||[[:space:]]then|[[:space:]]do|[[:space:]]else)[[:space:]]*(source|\.)[[:space:]]+[^[:space:]]'

# The stops: gathered scripts whose names are NOT followed, because the suite
# never runs them. What they load is still followed, and a file reached only
# through a stop's loads is part of that stop — its loads are followed, its
# names are not. Each entry is here for a reason that has to stay true:
#
#   - scripts/restart.sh: `DaemonBuildSkewTests` reads it as text and the suite
#     never runs it. It runs `reclaim-build.sh` and `sweep-scratchpads.sh`,
#     and `restart-bundle-lib.sh`, which only it loads, names `update.sh` —
#     none of them a suite input.
#   - scripts/remote-verify.sh: the remote verification valve. CI never arms
#     it, so CI never runs what it runs: `remote_verify.py`, and through that
#     the pre-push hook, the preflight-ref sweep and the nightly stress script.
is_name_stop() {
  case "$1" in
    scripts/restart.sh|scripts/remote-verify.sh) return 0 ;;
  esac
  return 1
}

# The scripts named on the lines read from stdin: a full `scripts/…` path that
# exists under ROOT, or the bare file name of a file under ROOT/scripts (INDEX
# lists them, one repo-relative path per line).
names_in() {
  local root="$1" index="$2" text tok
  text="$(cat)"
  {
    printf '%s\n' "$text" | grep -oE 'scripts/[A-Za-z0-9_./-]+' | while IFS= read -r tok; do
      while [ "${tok%.}" != "$tok" ]; do tok="${tok%.}"; done
      if [ -f "$root/$tok" ]; then printf '%s\n' "$tok"; fi
    done
    printf '%s\n' "$text" | grep -oE '[A-Za-z0-9_.-]+\.(sh|py)|swift-safe' | while IFS= read -r tok; do
      awk -F/ -v name="$tok" '$NF == name' "$index"
    done
  } | sort -u
}

# Append `<path><TAB><origin>` to FOUND unless PATH is already there. Succeeds
# only when it was new. One `awk` over the file rather than `cut | grep -q`:
# under `pipefail`, `grep -q` exiting early can SIGPIPE the writer and turn a
# match into a miss.
record_found() {
  if awk -F'\t' -v p="$2" '$1 == p { seen = 1 } END { exit !seen }' "$1"; then
    return 1
  fi
  printf '%s\t%s\n' "$2" "$3" >> "$1"
}

# Record PATH, found by ORIGIN, in WORK and queue it if it is new: for names
# and loads (WORK/run.next) unless MODE is `read` or PATH is a stop, in which
# case for loads only (WORK/read.next).
gather_one() {
  local work="$1" path="$2" origin="$3" mode="$4"
  record_found "$work/found" "$path" "$origin" || return 0
  if [ "$mode" = read ] || is_name_stop "$path"; then
    echo "$path" >> "$work/read.next"
  else
    echo "$path" >> "$work/run.next"
  fi
}

# One `<path><TAB><where it was found>` line per script the suite can reach in
# the tree at ROOT.
#
# Two phases, in this order. The first follows names and loads from every
# gathered script but the stops, to a fixpoint. Only then does the second
# follow loads alone, from the stops and from what they load. The order is
# what lets a script that both a stop loads and a followed script names —
# `restart-build-lib.sh`, which `restart.sh` loads and `swift-safe` names — be
# followed as the second, rather than recorded first as part of the stop.
gather_suite_scripts() {
  local root="$1" work index path file hit
  work="$(scratch)"
  index="$work/index"
  ( cd "$root" && find scripts -type f ) > "$index" 2>/dev/null
  : > "$work/found"
  : > "$work/run.next"
  : > "$work/read.next"

  for file in scripts/test.sh scripts/swift-safe; do
    if [ -f "$root/$file" ]; then
      gather_one "$work" "$file" "the wrapper every pass runs through" run
    fi
  done

  suite_job_lines "$root" | grep -v '^[[:space:]]*#' | names_in "$root" "$index" |
    while IFS= read -r path; do
      gather_one "$work" "$path" "named by the test job in .github/workflows/test.yml" run
    done

  ( cd "$root" && grep -roE '"scripts/[^"]*"' --include='*.swift' Sources Tests 2>/dev/null ) |
    while IFS= read -r hit; do
      file="${hit%%:*}"
      path="${hit#*:}"
      path="${path#\"}"
      path="${path%\"}"
      if [ -f "$root/$path" ]; then
        gather_one "$work" "$path" "a string literal in $file" run
      fi
    done

  # Loads before names within each file, so a loaded file's origin says so.
  while [ -s "$work/run.next" ]; do
    mv "$work/run.next" "$work/run.now"
    : > "$work/run.next"
    while IFS= read -r file; do
      code_lines "$root/$file" | grep -E "$LOAD_LINE" | names_in "$root" "$index" |
        while IFS= read -r path; do
          gather_one "$work" "$path" "loaded by $file" run
        done
      code_lines "$root/$file" | names_in "$root" "$index" |
        while IFS= read -r path; do
          gather_one "$work" "$path" "named by $file" run
        done
    done < "$work/run.now"
  done

  while [ -s "$work/read.next" ]; do
    mv "$work/read.next" "$work/read.now"
    : > "$work/read.next"
    while IFS= read -r file; do
      code_lines "$root/$file" | grep -E "$LOAD_LINE" | names_in "$root" "$index" |
        while IFS= read -r path; do
          gather_one "$work" "$path" "loaded by $file" read
        done
    done < "$work/read.now"
  done

  cat "$work/found"
}

# The gathered scripts in the tree at ROOT that no pattern in PATTERNS (a file,
# one `case` pattern per line) covers, as `<path><TAB><origin>` lines.
uncovered_scripts() {
  local root="$1" patterns="$2" path origin pattern covered
  gather_suite_scripts "$root" | while IFS="$TAB" read -r path origin; do
    covered=0
    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      # Unquoted on purpose: each entry is a `case` pattern.
      # shellcheck disable=SC2254
      case "$path" in $pattern) covered=1; break ;; esac
    done < "$patterns"
    [ "$covered" -eq 1 ] || printf '%s\t%s\n' "$path" "$origin"
  done
}

# Code lines of ROOT's `test` job that use a local composite action or
# reusable workflow. Its files would live under `.github/`, which the gate
# skips, so they would have to become suite inputs first.
local_uses_in_test_job() {
  suite_job_lines "$1" | grep -v '^[[:space:]]*#' | grep -E "uses:[[:space:]]*[\"']?\\./"
}

# A tree shaped to exercise every leg of the gatherer and every boundary of it.
mkdrift() {
  local d; d="$(scratch)"
  mkdir -p "$d/.github/workflows" "$d/scripts/ci" "$d/scripts/nested" \
           "$d/Sources/App" "$d/Tests/AppTests"
  cat > "$d/.github/workflows/test.yml" <<'EOF'
jobs:
  lint:
    steps:
      - run: bash scripts/lint-only.sh
  # A job-level comment: scripts/comment-only.sh
  test:
    # scripts/comment-only.sh is named only in a comment.
    steps:
      - run: bash scripts/ci/job-named.sh
        # bash scripts/comment-only.sh
      - run: bash scripts/test.sh
  after:
    steps:
      - run: bash scripts/after-only.sh
EOF
  cat > "$d/scripts/test.sh" <<'EOF'
#!/usr/bin/env bash
# scripts/comment-only.sh is named only in a comment.
source "$(dirname "${BASH_SOURCE[0]}")/bare-lib.sh"
scripts/wrapper-named.sh "$@"
scripts/remote-verify.sh
EOF
  cat > "$d/scripts/swift-safe" <<'EOF'
#!/usr/bin/env python3
"""A docstring line naming python-named.py counts: it is not a `#` comment.
It also names shared-lib.sh, which a stop loads as well."""
# comment-only.sh in a comment does not.
EOF
  cat > "$d/scripts/bare-lib.sh" <<'EOF'
. "$HERE/nested/deep-lib.sh"
bash scripts/named-by-a-lib.sh
EOF
  cat > "$d/scripts/nested/deep-lib.sh" <<'EOF'
if true; then source "$X/deepest-lib.sh"; fi
EOF
  cat > "$d/scripts/wrapper-named.sh" <<'EOF'
source scripts/loaded-by-named.sh
bash scripts/two-levels-down.sh
EOF
  cat > "$d/scripts/two-levels-down.sh" <<'EOF'
python3 scripts/three-levels-down.py
EOF
  cat > "$d/scripts/remote-verify.sh" <<'EOF'
python3 scripts/valve-only.py
EOF
  cat > "$d/scripts/restart.sh" <<'EOF'
source "$SCRIPT_DIR/stop-lib.sh"
source "$SCRIPT_DIR/shared-lib.sh"
bash scripts/run-by-a-stop.sh
EOF
  cat > "$d/scripts/stop-lib.sh" <<'EOF'
. "$SCRIPT_DIR/stop-deep-lib.sh"
echo "source this from restart.sh or named-by-a-stop-lib.sh"
EOF
  cat > "$d/scripts/shared-lib.sh" <<'EOF'
bash scripts/named-by-shared-lib.sh
EOF
  cat > "$d/Sources/App/Paths.swift" <<'EOF'
let here = "scripts/swift-literal.sh"
let gone = "scripts/not-a-file.sh"
let read = "scripts/restart.sh"
EOF
  cat > "$d/Tests/AppTests/PathTests.swift" <<'EOF'
let path = "scripts/test-literal.sh"
EOF
  local f
  for f in deepest-lib.sh loaded-by-named.sh three-levels-down.py named-by-a-lib.sh \
           python-named.py comment-only.sh lint-only.sh after-only.sh \
           swift-literal.sh test-literal.sh ci/job-named.sh valve-only.py \
           run-by-a-stop.sh stop-deep-lib.sh named-by-a-stop-lib.sh \
           named-by-shared-lib.sh; do
    echo "true" > "$d/scripts/$f"
  done
  echo "$d"
}

# Reached: the wrappers; a job name; both Swift literals that name a file;
# names and loads of every followed script, all the way down; the two stops;
# and loads, but not names, below a stop — except in a file a followed script
# also names (`shared-lib.sh`). Not reached: comments, other jobs,
# a literal naming no file, what a stop names (`valve-only.py`,
# `run-by-a-stop.sh`), and what a file only a stop loads names
# (`named-by-a-stop-lib.sh`).
DRIFT_EXPECTED='scripts/bare-lib.sh
scripts/ci/job-named.sh
scripts/deepest-lib.sh
scripts/loaded-by-named.sh
scripts/named-by-a-lib.sh
scripts/named-by-shared-lib.sh
scripts/nested/deep-lib.sh
scripts/python-named.py
scripts/remote-verify.sh
scripts/restart.sh
scripts/shared-lib.sh
scripts/stop-deep-lib.sh
scripts/stop-lib.sh
scripts/swift-literal.sh
scripts/swift-safe
scripts/test-literal.sh
scripts/test.sh
scripts/three-levels-down.py
scripts/two-levels-down.sh
scripts/wrapper-named.sh'

test_gatherer_follows_each_leg_and_stops_at_each_boundary() {
  local d gathered; d="$(mkdrift)"
  gathered="$(gather_suite_scripts "$d")"
  assert_eq "the gatherer reaches exactly the fixture's suite scripts" "$DRIFT_EXPECTED" \
    "$(printf '%s\n' "$gathered" | cut -f1 | LC_ALL=C sort)"
  assert_contains "a load is attributed to the file that loads it" \
    "$gathered" "scripts/deepest-lib.sh${TAB}loaded by scripts/nested/deep-lib.sh"
  assert_contains "a name is followed past the first level" \
    "$gathered" "scripts/three-levels-down.py${TAB}named by scripts/two-levels-down.sh"
  assert_contains "a stop's loads are followed" \
    "$gathered" "scripts/stop-deep-lib.sh${TAB}loaded by scripts/stop-lib.sh"
  assert_contains "a file a stop loads and a followed script names is followed" \
    "$gathered" "scripts/named-by-shared-lib.sh${TAB}named by scripts/shared-lib.sh"
}

# The check reddens when one entry goes missing, and names where the script
# was found — the mutation that matters, made on the fixture so it does not
# depend on what this checkout's suite happens to reach.
test_drift_check_names_a_missing_script() {
  local d patterns missing; d="$(mkdrift)"
  patterns="$d/patterns"
  printf '%s\n' "$DRIFT_EXPECTED" > "$patterns"
  assert_eq "a list covering every gathered script leaves nothing uncovered" "" \
    "$(uncovered_scripts "$d" "$patterns")"
  grep -vxF 'scripts/three-levels-down.py' "$d/patterns" > "$d/patterns.less"
  missing="$(uncovered_scripts "$d" "$d/patterns.less")"
  assert_eq "dropping one entry leaves exactly it uncovered, with its origin" \
    "scripts/three-levels-down.py${TAB}named by scripts/two-levels-down.sh" "$missing"
  printf 'scripts/*\n' > "$d/patterns.glob"
  assert_eq "a pattern entry covers what it matches" "" "$(uncovered_scripts "$d" "$d/patterns.glob")"
}

test_local_action_detector() {
  local d; d="$(mkdrift)"
  assert_eq "a test job without a local action reports nothing" "" "$(local_uses_in_test_job "$d")"
  cat > "$d/.github/workflows/test.yml" <<'EOF'
jobs:
  test:
    steps:
      # - uses: ./.github/actions/commented-out
      - uses: actions/checkout@v4
      - uses: ./.github/actions/setup
  after:
    steps:
      - uses: ./.github/actions/elsewhere
EOF
  assert_eq "a local action in the test job is reported, and only that one" \
    "      - uses: ./.github/actions/setup" "$(local_uses_in_test_job "$d")"
}

# THE CHECK ITSELF, on this checkout.
test_every_script_the_suite_reaches_is_on_the_list() {
  local d path origin missing job_code local_uses
  d="$(scratch)"
  if ! "$BASH" "$SCRIPT" --list-suite-scripts > "$d/patterns" 2>/dev/null || [ ! -s "$d/patterns" ]; then
    echo "FAIL - --list-suite-scripts printed no list to check against"
    FAIL=1
    return
  fi
  # The structure the gatherer assumes. If any of it moves, the check below
  # would pass by gathering nothing.
  job_code="$(suite_job_lines "$REPO_ROOT" | grep -v '^[[:space:]]*#')"
  if [ -z "$job_code" ]; then
    echo "FAIL - found no \`  test:\` job in .github/workflows/test.yml to read"
    FAIL=1
  else
    echo "ok   - the test job in .github/workflows/test.yml was found"
  fi
  for path in scripts/test.sh scripts/swift-safe; do
    if [ -f "$REPO_ROOT/$path" ]; then
      echo "ok   - $path is where the gatherer reads it"
    else
      echo "FAIL - $path is gone, so the gatherer cannot read it; update this harness"
      FAIL=1
    fi
  done

  local_uses="$(local_uses_in_test_job "$REPO_ROOT")"
  if [ -z "$local_uses" ]; then
    echo "ok   - the test job uses no local action or reusable workflow"
  else
    echo "FAIL - the test job uses a local action or reusable workflow, whose files the gate skips as .github/**:"
    printf '%s\n' "$local_uses" | sed 's/^/       /'
    echo "     Make its files suite inputs in scripts/ci/swift-suite-needed.sh, then update this check."
    FAIL=1
  fi

  echo "     the suite reaches:"
  gather_suite_scripts "$REPO_ROOT" | while IFS="$TAB" read -r path origin; do
    echo "       $path ($origin)"
  done

  missing="$(uncovered_scripts "$REPO_ROOT" "$d/patterns")"
  if [ -z "$missing" ]; then
    echo "ok   - every script the suite reaches is one of the gate's suite scripts"
  else
    echo "FAIL - the suite reaches scripts the gate does not list, so a PR changing only one of them would skip the suite:"
    printf '%s\n' "$missing" | while IFS="$TAB" read -r path origin; do
      echo "       $path ($origin)"
    done
    echo "     Add each to SUITE_SCRIPTS in scripts/ci/swift-suite-needed.sh,"
    echo "     or, if the suite never runs it, give the script that names it a stop here."
    FAIL=1
  fi
}

# THE WIRING, on this checkout. The gate fails closed only because of how the
# workflow consumes its answer, and no fixture can execute a GitHub expression,
# so the pieces are pinned as written.
test_the_workflow_wiring_fails_closed() {
  local keys named outputs step
  keys="$(job_lines "$REPO_ROOT" test | grep -E '^    [^[:space:]#]')"
  assert_line "the test job waits for the gate" "$keys" "    needs: changes"
  assert_line "the test job skips only on an explicit false, and still runs after a failed gate" \
    "$keys" "    if: \${{ !cancelled() && needs.changes.outputs.run != 'false' }}"
  named="$(printf '%s\n' "$keys" | grep -E '^    name:')"
  assert_eq "the test job has no name:, so the required check stays \`test\`" "" "$named"

  outputs="$(job_lines "$REPO_ROOT" changes |
    awk '/^    outputs:/ { inside = 1; next } inside && /^    [^[:space:]]/ { exit } inside')"
  assert_line "the gate's run output is the decide step's" "$outputs" \
    "      run: \${{ steps.decide.outputs.run }}"

  step="$(step_lines "$REPO_ROOT" changes decide | grep -v '^[[:space:]]*#' |
    grep -E '^[[:space:]]+(- )?run:.*scripts/ci/swift-suite-needed\.sh')"
  if [ -n "$step" ]; then
    echo "ok   - the step with id: decide runs scripts/ci/swift-suite-needed.sh"
  else
    echo "FAIL - no step with id: decide in the changes job runs scripts/ci/swift-suite-needed.sh"
    FAIL=1
  fi
}

# ---------------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  echo "--- $t"
  "$t"
done

if [ "$FAIL" -eq 0 ]; then
  echo "All swift-suite-needed tests passed."
else
  echo "Some swift-suite-needed tests FAILED."
fi
exit "$FAIL"
