#!/usr/bin/env bash
#
# Decide whether the SPM #7715 first-party library wipe is needed on this run.
#
#   scripts/ci/first-party-wipe-needed.sh <marker-path>
#
# Prints `wipe` or `skip` on stdout, a one-line reason on stderr, and exits 0
# either way: the answer is the output, never the status, so a caller reads it
# with a plain command substitution.
#
# ---------------------------------------------------------------------------
# WHAT IT IS FOR
#
# swiftlang/swift-package-manager#7715: a cache-restored `.build/` can hold a
# stale object archive for a library target next to a fresh `.swiftmodule`.
# Downstream files compile happily against the new module interface and then the
# linker cannot resolve the new symbol — an "Undefined symbols" flake that
# disappears on retry. `.github/workflows/test.yml` defends against it by
# removing the build artifacts of TBDShared and TBDDaemonLib before any compile,
# forcing SPM to re-emit them.
#
# That defence is not free. On a measured run whose commit touched only
# `Sources/TBDDaemon` and one test file, the wipe cost about three minutes of a
# 278-second compile: all 89 TBDShared and 265 TBDDaemonLib files recompiled,
# TestSupport and TBDDaemonTests re-emitted on top, and a 38-second relink. Most
# pushes touch neither library, so most runs paid that for nothing.
#
# The bug's precondition is that a library's SOURCES differ from the sources its
# cached artifacts were built from. When they are identical, the archive and the
# module are both current and the wipe buys nothing — so the job records the
# commit its `.build/` was built from inside `.build/` itself, and this script
# compares that commit's library trees against the ones being built now.
#
# ---------------------------------------------------------------------------
# THE INVARIANT
#
# Every saved cache holds first-party artifacts consistent with its marker
# commit. A run may therefore skip the wipe exactly when the two library trees
# are byte-identical between the marker commit and HEAD, and either decision
# preserves the invariant for the cache this run goes on to save:
#
#   - on `wipe`, the libraries are re-emitted from HEAD, and the marker the job
#     writes at the end of the run is HEAD;
#   - on `skip`, the restored artifacts already match HEAD's library sources —
#     that is precisely what was just proved — and the marker written at the end
#     is again HEAD.
#
# ---------------------------------------------------------------------------
# WHY KEEP-BIASED
#
# Skipping wrongly costs a link flake that a reader has no reason to connect to
# this script; wiping wrongly costs three minutes. So every uncertainty answers
# `wipe`: no marker (a cache saved before this mechanism existed, or no cache at
# all), a marker naming a commit this checkout does not have (a force-push threw
# it away, or the cache came from unrelated history), a marker that is empty or
# unreadable, and any `git diff` that does not return a clean 0.
#
# ---------------------------------------------------------------------------
# WHY A MARKER FILE, NOT THE CACHE KEY
#
# The restore key that matched is available to the job, but it carries
# `hashFiles(...)` digests of the source tree rather than a commit, so there is
# nothing to diff against. A file inside `.build/` rides the same cache entry as
# the artifacts it describes, is written and read by the same job, and says
# exactly what the comparison needs: which tree those artifacts came from.
set -uo pipefail

# The paths whose contents decide it. The two libraries are the targets whose
# artifacts get wiped; `Package.swift` and `Package.resolved` are here because a
# manifest or dependency change can move a library's module boundary without
# touching a single file under `Sources/`.
WIPE_PATHS=(Sources/TBDShared Sources/TBDDaemonLib Package.swift Package.resolved)

decide() {
  printf '%s\n' "$1"
  printf '%s\n' "$2" >&2
  exit 0
}

marker="${1:-}"
if [ -z "$marker" ]; then
  echo "usage: $(basename "$0") <marker-path>" >&2
  exit 64
fi

if [ ! -f "$marker" ]; then
  decide wipe "wipe: no cache-source marker at $marker, so the restored artifacts' provenance is unknown."
fi

sha="$(tr -d '[:space:]' < "$marker" 2>/dev/null)"
if [ -z "$sha" ]; then
  decide wipe "wipe: the cache-source marker at $marker is empty or unreadable."
fi

if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
  decide wipe "wipe: marker commit $sha is not in this checkout (force-pushed away, or a cache from unrelated history)."
fi

git diff --quiet "$sha" HEAD -- "${WIPE_PATHS[@]}" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ]; then
  decide skip "skip: ${WIPE_PATHS[*]} are unchanged since $sha, the commit these cached artifacts were built from."
fi
if [ "$rc" -ne 1 ]; then
  decide wipe "wipe: comparing $sha with HEAD failed (git diff exited $rc)."
fi

changed="$(git diff --name-only "$sha" HEAD -- "${WIPE_PATHS[@]}" 2>/dev/null | tr '\n' ' ')"
decide wipe "wipe: changed since $sha: ${changed:-(unlistable)}"
