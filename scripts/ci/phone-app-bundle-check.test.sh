#!/usr/bin/env bash
# Tests for scripts/ci/phone-app-bundle-check.sh — run:
#   /bin/bash scripts/ci/phone-app-bundle-check.test.sh
#
# Every case runs the check in a throwaway repository under `mktemp -d` with a
# stub `npm`, passed as NPM, that logs each invocation and the directory it ran
# in. For `run build:app` the stub writes $STUB_BUILD_OUTPUT to the bundle's
# `app.js` (nothing when it is unset), plus `extra.js` when STUB_BUILD_EXTRA=1,
# plus STUB_BUILD_NAMED_OUTPUT to the bundle path STUB_BUILD_NAMED when that is
# set, and removes `old.js` when STUB_BUILD_CLEAN=1. STUB_CI_FAIL,
# STUB_TEST_FAIL and STUB_BUILD_FAIL set to 1 make that step fail.
#
# RUN WITH `/bin/bash`, WHICH ON MACOS IS 3.2. Every run of the script under
# test goes through `$BASH`, this harness's own interpreter.
#
# ZERO BUILDS AND NO NETWORK: no real npm runs. Nothing is written outside a
# directory this harness minted. Each fixture repository sets its own identity
# and turns signing off, so the developer's git config cannot interfere.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/phone-app-bundle-check.sh"
BUNDLE_DIR=Sources/TBDDaemon/Resources/phone-app
TAB="$(printf '\t')"
export LC_ALL=C

# A CI step's own summary must not receive these cases' accounts, and a git
# hook's `GIT_DIR` would point every fixture's `git` at this checkout.
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY NPM STUB_LOG STUB_BUILD_OUTPUT \
      STUB_BUILD_EXTRA STUB_BUILD_CLEAN STUB_BUILD_NAMED STUB_BUILD_NAMED_OUTPUT \
      STUB_CI_FAIL STUB_TEST_FAIL STUB_BUILD_FAIL FIXTURE_GITIGNORE \
      GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

FAIL=0
assert_eq()       { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { case "$2" in *"$3"*) echo "ok   - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]" ; FAIL=1 ;; esac; }
assert_lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: [$2] holds [$3]" ; FAIL=1 ;; *) echo "ok   - $1" ;; esac; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/phone-app-bundle-check-test.XXXXXX"; }

# The fixture register is a FILE, not a variable: every fixture is minted inside
# a command substitution, so a subshell's assignment would be lost.
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

scratch() {
  local d; d="$(mktmpd)"
  echo "$d" >> "$FIXTURE_LIST"
  echo "$d"
}

PACKAGE_WITH_BUILD='{"name":"phone","private":true,"scripts":{"test":"node --test","test:app":"node --test app","build:app":"node app/build.mjs"}}'
PACKAGE_WITHOUT_BUILD='{"name":"phone","private":true,"scripts":{"test":"node --test"}}'
BUNDLE_V1='// bundle v1
'

# A fixture: `repo/`, a git repository with PACKAGE as `phone/package.json`
# (none when PACKAGE is `-`), FIXTURE_GITIGNORE as its top-level `.gitignore`
# when that is set, and, after PACKAGE, NAME CONTENT pairs committed under the
# bundle folder; and `bin/npm`, the stub. Echoes the fixture directory.
mkfixture() {
  local d package="$1"; shift
  d="$(scratch)"
  mkdir -p "$d/repo" "$d/bin"
  if [ "$package" != - ]; then
    mkdir -p "$d/repo/phone"
    printf '%s\n' "$package" > "$d/repo/phone/package.json"
  fi
  echo "# fixture" > "$d/repo/README.md"
  if [ -n "${FIXTURE_GITIGNORE:-}" ]; then
    printf '%s\n' "$FIXTURE_GITIGNORE" > "$d/repo/.gitignore"
  fi
  while [ "$#" -ge 2 ]; do
    mkdir -p "$d/repo/$BUNDLE_DIR"
    printf '%s' "$2" > "$d/repo/$BUNDLE_DIR/$1"
    shift 2
  done
  cat > "$d/bin/npm" <<'EOF'
#!/bin/sh
printf '%s\t%s\n' "$*" "$(pwd -P)" >> "$STUB_LOG"
bundle=../Sources/TBDDaemon/Resources/phone-app
case "$*" in
  ci)
    [ "${STUB_CI_FAIL:-0}" = 1 ] && exit 1
    exit 0 ;;
  "run test:app")
    [ "${STUB_TEST_FAIL:-0}" = 1 ] && exit 1
    exit 0 ;;
  "run build:app")
    [ "${STUB_BUILD_FAIL:-0}" = 1 ] && exit 1
    if [ -n "${STUB_BUILD_OUTPUT+set}" ]; then
      mkdir -p "$bundle" && printf '%s' "$STUB_BUILD_OUTPUT" > "$bundle/app.js" || exit 1
    fi
    if [ "${STUB_BUILD_EXTRA:-0}" = 1 ]; then
      mkdir -p "$bundle" && printf 'extra\n' > "$bundle/extra.js" || exit 1
    fi
    if [ -n "${STUB_BUILD_NAMED:-}" ]; then
      mkdir -p "$(dirname "$bundle/$STUB_BUILD_NAMED")" &&
        printf '%s' "${STUB_BUILD_NAMED_OUTPUT:-}" > "$bundle/$STUB_BUILD_NAMED" || exit 1
    fi
    if [ "${STUB_BUILD_CLEAN:-0}" = 1 ]; then
      rm -f "$bundle/old.js" || exit 1
    fi
    exit 0 ;;
esac
exit 97
EOF
  chmod +x "$d/bin/npm"
  (
    cd "$d/repo" || exit 1
    git -c init.defaultBranch=main init -q .
    git config user.email "harness@example.invalid"
    git config user.name "Phone App Bundle Harness"
    git config commit.gpgsign false
    git add -A
    git commit -q -m "fixture"
  ) || echo "fixture repo $d could not be created" >&2
  echo "$d"
}

# Run the check in fixture D's repo (or the subdirectory $CHECK_IN of it), with
# the remaining arguments as extra environment assignments. Sets CHECK_RC,
# CHECK_LOG, CHECK_SUMMARY and CHECK_STDERR.
run_check() {
  local d="$1"; shift
  : > "$d/npm.log"
  : > "$d/summary"
  (
    cd "$d/repo/${CHECK_IN:-}" || exit 99
    env "$@" NPM="$d/bin/npm" STUB_LOG="$d/npm.log" GITHUB_STEP_SUMMARY="$d/summary" \
      "$BASH" "$SCRIPT" >"$d/stdout" 2>"$d/stderr"
  )
  CHECK_RC=$?
  CHECK_LOG="$(cat "$d/npm.log")"
  CHECK_SUMMARY="$(cat "$d/summary")"
  CHECK_STDERR="$(cat "$d/stderr")"
}

# The log a full run writes: the three steps, in order, each in phone/.
full_log() {
  local phone; phone="$(cd "$1/repo/phone" && pwd -P)"
  printf 'ci%s%s\nrun test:app%s%s\nrun build:app%s%s' "$TAB" "$phone" "$TAB" "$phone" "$TAB" "$phone"
}

# ---------------------------------------------------------------------------
# No build script
# ---------------------------------------------------------------------------

test_no_build_script_and_no_bundle_passes() {
  local d; d="$(mkfixture "$PACKAGE_WITHOUT_BUILD")"
  run_check "$d"
  assert_eq "no build script and no bundle passes" "0" "$CHECK_RC"
  assert_contains "the summary says there is no phone app bundle yet" "$CHECK_SUMMARY" \
    "No phone app bundle yet, so there is nothing to rebuild."
  assert_eq "no build script runs no npm" "" "$CHECK_LOG"
}

test_no_package_json_passes() {
  local d; d="$(mkfixture -)"
  run_check "$d"
  assert_eq "no package.json passes" "0" "$CHECK_RC"
  assert_contains "the summary says there is no phone app bundle yet" "$CHECK_SUMMARY" \
    "No phone app bundle yet, so there is nothing to rebuild."
  assert_eq "no package.json runs no npm" "" "$CHECK_LOG"
}

test_a_committed_bundle_with_no_build_script_fails() {
  local d; d="$(mkfixture "$PACKAGE_WITHOUT_BUILD" app.js "$BUNDLE_V1")"
  run_check "$d"
  assert_eq "a committed bundle with no build script fails" "1" "$CHECK_RC"
  assert_contains "the failure names the bundle folder" "$CHECK_STDERR" "::error::\`$BUNDLE_DIR\`"
  assert_eq "a committed bundle with no build script runs no npm" "" "$CHECK_LOG"
  d="$(mkfixture - app.js "$BUNDLE_V1")"
  run_check "$d"
  assert_eq "a committed bundle with no package.json fails" "1" "$CHECK_RC"
}

test_an_unreadable_package_json_fails() {
  local d content
  for content in '{' '[]' '{"scripts":["build:app"]}' '{"scripts":"build:app"}' '"build:app"'; do
    d="$(mkfixture "$content" app.js "$BUNDLE_V1")"
    run_check "$d" STUB_BUILD_OUTPUT="$BUNDLE_V1"
    assert_eq "a package.json of [$content] fails" "1" "$CHECK_RC"
    assert_contains "the failure says package.json could not be read" "$CHECK_STDERR" \
      "::error::\`phone/package.json\` could not be read"
    assert_eq "a package.json of [$content] runs no npm" "" "$CHECK_LOG"
  done
  d="$(mkfixture '{')"
  run_check "$d"
  assert_eq "an unreadable package.json fails even with no bundle" "1" "$CHECK_RC"
}

# ---------------------------------------------------------------------------
# With a build script
# ---------------------------------------------------------------------------

test_a_build_that_reproduces_the_committed_bundle_passes() {
  local d; d="$(mkfixture "$PACKAGE_WITH_BUILD" app.js "$BUNDLE_V1")"
  run_check "$d" STUB_BUILD_OUTPUT="$BUNDLE_V1"
  assert_eq "a build that reproduces the committed bundle passes" "0" "$CHECK_RC"
  assert_eq "the check runs ci, test:app and build:app, in that order, each in phone/" \
    "$(full_log "$d")" "$CHECK_LOG"
  assert_contains "the summary says the bundle is current" "$CHECK_SUMMARY" \
    "is what \`npm run build:app\` writes."
  CHECK_IN=phone run_check "$d" STUB_BUILD_OUTPUT="$BUNDLE_V1"
  assert_eq "the check passes when started from a subdirectory" "0" "$CHECK_RC"
  assert_eq "started from a subdirectory, each step still runs in phone/" "$(full_log "$d")" "$CHECK_LOG"
}

test_a_build_that_changes_the_bundle_fails() {
  local d; d="$(mkfixture "$PACKAGE_WITH_BUILD" app.js "$BUNDLE_V1")"
  run_check "$d" STUB_BUILD_OUTPUT='// bundle v2
'
  assert_eq "a build that changes the bundle fails" "1" "$CHECK_RC"
  assert_contains "the failure names app.js" "$CHECK_STDERR" "::error::$BUNDLE_DIR/app.js differs"
  assert_contains "the summary names app.js" "$CHECK_SUMMARY" "\`$BUNDLE_DIR/app.js\`"
  assert_eq "every step ran" "$(full_log "$d")" "$CHECK_LOG"
}

test_a_build_that_adds_a_file_to_the_bundle_folder_fails() {
  local d; d="$(mkfixture "$PACKAGE_WITH_BUILD" app.js "$BUNDLE_V1")"
  run_check "$d" STUB_BUILD_OUTPUT="$BUNDLE_V1" STUB_BUILD_EXTRA=1
  assert_eq "a build that adds a file to the bundle folder fails" "1" "$CHECK_RC"
  assert_contains "the failure names the added file" "$CHECK_STDERR" "::error::$BUNDLE_DIR/extra.js differs"
  assert_lacks "the failure does not name the unchanged file" "$CHECK_STDERR" "app.js differs"
}

# SwiftPM copies the bundle folder from disk, ignored files and all, so a file
# the build writes that `.gitignore` matches would ship unchecked if the check
# read only what `git status` lists by default.
test_a_build_that_writes_an_ignored_file_fails() {
  local d
  d="$(FIXTURE_GITIGNORE='*.map' mkfixture "$PACKAGE_WITH_BUILD" app.js "$BUNDLE_V1")"
  run_check "$d" STUB_BUILD_OUTPUT="$BUNDLE_V1" STUB_BUILD_NAMED=app.js.map STUB_BUILD_NAMED_OUTPUT='{}'
  assert_eq "a build that writes a file .gitignore matches fails" "1" "$CHECK_RC"
  assert_contains "the failure names the ignored file" "$CHECK_STDERR" "::error::$BUNDLE_DIR/app.js.map differs"
  assert_contains "the failure gives the ignored file's status" "$CHECK_STDERR" "(git status \`!!\`)"
  assert_lacks "the failure does not name the unchanged file" "$CHECK_STDERR" "app.js differs"

  # A whole ignored directory: each file in it is named, not just the folder.
  d="$(FIXTURE_GITIGNORE='maps/' mkfixture "$PACKAGE_WITH_BUILD" app.js "$BUNDLE_V1")"
  run_check "$d" STUB_BUILD_OUTPUT="$BUNDLE_V1" STUB_BUILD_NAMED=maps/app.js.map STUB_BUILD_NAMED_OUTPUT='{}'
  assert_eq "a build that writes into an ignored directory fails" "1" "$CHECK_RC"
  assert_contains "the failure names the file in the ignored directory" "$CHECK_STDERR" \
    "::error::$BUNDLE_DIR/maps/app.js.map differs"
}

# The line format quotes a path holding a space; the check names it raw.
test_a_changed_file_with_a_space_is_named_raw() {
  local d; d="$(mkfixture "$PACKAGE_WITH_BUILD" app.js "$BUNDLE_V1" 'my app.js' "$BUNDLE_V1")"
  run_check "$d" STUB_BUILD_OUTPUT="$BUNDLE_V1" STUB_BUILD_NAMED='my app.js' STUB_BUILD_NAMED_OUTPUT='// v2
'
  assert_eq "a build that changes a file whose name has a space fails" "1" "$CHECK_RC"
  assert_contains "the failure names the file raw" "$CHECK_STDERR" "::error::$BUNDLE_DIR/my app.js differs"
  assert_contains "the summary names the file raw" "$CHECK_SUMMARY" "- \`$BUNDLE_DIR/my app.js\` (\` M\`)"
  assert_lacks "the failure does not quote the name" "$CHECK_STDERR" "\"$BUNDLE_DIR/my app.js\""
}

test_a_build_that_removes_a_committed_file_fails() {
  local d; d="$(mkfixture "$PACKAGE_WITH_BUILD" app.js "$BUNDLE_V1" old.js 'old
')"
  run_check "$d" STUB_BUILD_OUTPUT="$BUNDLE_V1" STUB_BUILD_CLEAN=1
  assert_eq "a build that removes a committed file fails" "1" "$CHECK_RC"
  assert_contains "the failure names the removed file" "$CHECK_STDERR" "::error::$BUNDLE_DIR/old.js differs"
}

test_an_uncommitted_bundle_fails() {
  local d; d="$(mkfixture "$PACKAGE_WITH_BUILD")"
  run_check "$d" STUB_BUILD_OUTPUT="$BUNDLE_V1"
  assert_eq "a build whose bundle is not committed fails" "1" "$CHECK_RC"
  assert_contains "the failure names the uncommitted file" "$CHECK_STDERR" "::error::$BUNDLE_DIR/app.js differs"
}

test_a_build_that_writes_nothing_with_nothing_committed_fails() {
  local d; d="$(mkfixture "$PACKAGE_WITH_BUILD")"
  run_check "$d"
  assert_eq "a build script with no bundle written or committed fails" "1" "$CHECK_RC"
  assert_contains "the failure says there is nothing to check" "$CHECK_STDERR" "nothing to check"
}

test_a_failing_npm_ci_fails() {
  local d phone; d="$(mkfixture "$PACKAGE_WITH_BUILD" app.js "$BUNDLE_V1")"
  phone="$(cd "$d/repo/phone" && pwd -P)"
  run_check "$d" STUB_BUILD_OUTPUT="$BUNDLE_V1" STUB_CI_FAIL=1
  assert_eq "a failing npm ci fails" "1" "$CHECK_RC"
  assert_eq "a failing npm ci stops there" "ci${TAB}${phone}" "$CHECK_LOG"
}

test_a_failing_test_app_fails_and_builds_nothing() {
  local d; d="$(mkfixture "$PACKAGE_WITH_BUILD" app.js "$BUNDLE_V1")"
  run_check "$d" STUB_BUILD_OUTPUT="$BUNDLE_V1" STUB_TEST_FAIL=1
  assert_eq "a failing test:app fails" "1" "$CHECK_RC"
  assert_lacks "a failing test:app builds nothing" "$CHECK_LOG" "run build:app"
  assert_contains "the failure names test:app" "$CHECK_STDERR" "::error::\`npm run test:app\` failed"
}

test_a_failing_build_fails() {
  local d; d="$(mkfixture "$PACKAGE_WITH_BUILD" app.js "$BUNDLE_V1")"
  run_check "$d" STUB_BUILD_OUTPUT="$BUNDLE_V1" STUB_BUILD_FAIL=1
  assert_eq "a failing build fails" "1" "$CHECK_RC"
  assert_contains "the failure names build:app" "$CHECK_STDERR" "::error::\`npm run build:app\` failed"
}

test_a_stray_argument_exits_64() {
  local d; d="$(mkfixture "$PACKAGE_WITH_BUILD" app.js "$BUNDLE_V1")"
  ( cd "$d/repo" && NPM="$d/bin/npm" STUB_LOG="$d/npm.log" "$BASH" "$SCRIPT" --wat >/dev/null 2>&1 )
  assert_eq "a stray argument exits 64" "64" "$?"
}

# ---------------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  echo "--- $t"
  "$t"
done

if [ "$FAIL" -eq 0 ]; then
  echo "All phone-app-bundle-check tests passed."
else
  echo "Some phone-app-bundle-check tests FAILED."
fi
exit "$FAIL"
