#!/usr/bin/env bash
#
# Check that the phone app bundle committed under
# `Sources/TBDDaemon/Resources/phone-app/` is exactly what its sources build.
#
#   bash scripts/ci/phone-app-bundle-check.sh
#       Run from the repository root (any directory inside the checkout
#       works). Exits 0 when the committed bundle matches a fresh build, or
#       when there is neither a bundle nor a build script yet; exits 1
#       otherwise. Writes a short account to $GITHUB_STEP_SUMMARY (stderr
#       when unset).
#
#   NPM
#       The npm to run, as a command name or an absolute path (default
#       `npm`). The harness, `phone-app-bundle-check.test.sh`, passes a stub.
#
# The daemon serves the committed bundle, so a source change that is not
# rebuilt and committed would ship the old app. The `phone-app` job in
# `.github/workflows/phone.yml` runs this check; the model is
# `scripts/gen-session-mod-content.py --check`, which the `Session mod` job in
# `test.yml` runs for the session mod's embedded copy.
#
# Design: docs/specs/2026-11-07-phone-control-design.md, section 15.
#
# THE FLOW
#
#   - `phone/package.json` names no `build:app` script (or does not exist):
#     there is nothing to rebuild, which passes only while no bundle is
#     committed either. A bundle with no build script to check it against
#     fails.
#   - It names one: in `phone/`, `npm ci`, `npm run test:app` and
#     `npm run build:app`, stopping at the first failure. Then the bundle
#     folder must hold exactly the committed files with exactly their
#     committed contents: a changed, added or removed file fails, and so does
#     a build that leaves the folder empty.
#   - A `package.json` that cannot be read as a JSON object fails, rather than
#     reading as one with no build script.
set -uo pipefail

BUNDLE_DIR=Sources/TBDDaemon/Resources/phone-app
PACKAGE=phone/package.json
NPM="${NPM:-npm}"

# Exits 0 when the package.json at $1 names a `build:app` script, 1 when it
# names none, and 2 when it cannot be read as an object whose `scripts` is an
# object. An uncaught Python exception also exits 1, so every error is caught
# and turned into 2 rather than reading as "no build script".
READ_SCRIPTS='
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8-sig") as f:
        scripts = json.load(f).get("scripts", {})
    if not isinstance(scripts, dict):
        raise TypeError("scripts is not an object")
except Exception:
    sys.exit(2)
sys.exit(0 if "build:app" in scripts else 1)
'

# The step summary, or stderr when it is unset or cannot be written.
summary() {
  local text="### Phone app bundle

$1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if printf '%s\n' "$text" >> "$GITHUB_STEP_SUMMARY"; then return; fi
    echo "::warning::Could not write the step summary; the account follows here." >&2
  fi
  printf '%s\n' "$text" >&2
}

fail() {
  echo "::error::$1" >&2
  summary "$1"
  exit 1
}

# Runs npm with the arguments given, in phone/, and fails the check if it fails.
run_npm() {
  echo "phone/: npm $*" >&2
  ( cd phone && "$NPM" "$@" ) || fail "\`npm $*\` failed in phone/, so the bundle was not checked."
}

[ "$#" -eq 0 ] || { echo "usage: $(basename "$0")" >&2; exit 64; }

top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
[ -n "$top" ] || fail "Not inside a git checkout, so the committed bundle cannot be read."
cd "$top" || fail "Could not enter the checkout at $top."

has_build=0
if [ -e "$PACKAGE" ] || [ -L "$PACKAGE" ]; then
  python3 -I -c "$READ_SCRIPTS" "$PACKAGE"
  case "$?" in
    0) has_build=1 ;;
    1) has_build=0 ;;
    *) fail "\`$PACKAGE\` could not be read as a JSON object with a \`scripts\` object, so whether it builds the phone app is unknown." ;;
  esac
fi

committed="$(git ls-files -- "$BUNDLE_DIR")" ||
  fail "\`git ls-files\` failed, so the committed bundle under \`$BUNDLE_DIR\` cannot be listed."

if [ "$has_build" -eq 0 ]; then
  if [ -n "$committed" ]; then
    fail "\`$BUNDLE_DIR\` holds a committed bundle with no build script to check it against: \`$PACKAGE\` names no \`build:app\` script."
  fi
  summary "No phone app bundle yet, so there is nothing to rebuild."
  exit 0
fi

run_npm ci
run_npm run test:app
run_npm run build:app

status="$(git status --porcelain=v1 --untracked-files=all -- "$BUNDLE_DIR")" ||
  fail "\`git status\` failed, so the rebuilt bundle cannot be compared with the committed one."

if [ -n "$status" ]; then
  changed=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Porcelain v1: two status letters, a space, then the path.
    echo "::error::${line:3} differs from what \`npm run build:app\` writes (git status \`${line:0:2}\`)." >&2
    changed="$changed
- \`${line:3}\` (\`${line:0:2}\`)"
  done <<EOF
$status
EOF
  git diff --stat -- "$BUNDLE_DIR" >&2
  summary "The committed bundle under \`$BUNDLE_DIR\` is not what \`npm run build:app\` writes. Run \`npm run build:app\` in \`phone/\` and commit the result.
$changed"
  exit 1
fi

if [ -z "$committed" ]; then
  fail "\`npm run build:app\` left \`$BUNDLE_DIR\` empty and no bundle is committed there, so there is nothing to check."
fi

summary "The committed bundle under \`$BUNDLE_DIR\` is what \`npm run build:app\` writes."
exit 0
