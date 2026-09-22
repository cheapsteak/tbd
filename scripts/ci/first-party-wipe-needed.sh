#!/usr/bin/env bash
#
# Decide whether the SPM #7715 first-party library wipe is needed on this run,
# and record the provenance the next run will decide from.
#
#   scripts/ci/first-party-wipe-needed.sh <marker-path>
#       Prints `wipe` or `skip` on stdout and a one-line reason on stderr, and
#       exits 0 either way: the answer is the output, never the status, so a
#       caller reads it with a plain command substitution.
#
#   scripts/ci/first-party-wipe-needed.sh --record <marker-path>
#       Writes the marker describing the tree the artifacts in `.build/` were
#       just built from. Writes nothing it cannot back: not when a compared path
#       does not resolve, and not over a marker that is still there, which is
#       one the decision step never consumed.
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
# That defence is not free. Measured on a run whose commit touched only
# `Sources/TBDDaemon` and one test file, the wipe cost about three of the 278
# seconds the first pass spent compiling: all 89 TBDShared files and 265
# TBDDaemonLib files recompiled, TestSupport and TBDDaemonTests re-emitted on
# top, and a 38-second relink. Over the last 40 commits on `main`, 18 touched
# neither library's sources nor the manifest and paid that for nothing.
#
# The bug's precondition is that a library's SOURCES differ from the sources its
# cached artifacts were built from. When they are identical, the archive and the
# module are both current and the wipe buys nothing — so the job records what
# those sources were inside `.build/` itself, and this script compares that
# record against the tree being built now.
#
# ---------------------------------------------------------------------------
# THE INVARIANT
#
# Every saved cache holds first-party artifacts consistent with its marker. A
# run may therefore skip the wipe exactly when the recorded sources and the
# current ones are byte-identical, and either decision preserves the invariant
# for the cache this run goes on to save:
#
#   - on `wipe`, the libraries are re-emitted from the current sources, and the
#     marker the job records at the end describes those same sources;
#   - on `skip`, the restored artifacts already match the current sources — that
#     is precisely what was just proved — and the marker recorded at the end
#     describes them too.
#
# The workflow keeps its half of that bargain by REMOVING the marker as soon as
# it has read it, and recording a new one from an unconditional step placed
# after every compile in the job — so reaching the recording is itself the
# evidence that the build finished. A source fingerprint cannot supply that
# evidence on its own: it says what the artifacts were built FROM, not that
# they were finished, and a marker written over a compile that was killed part
# way through would let a rerun of the same commit skip the wipe that used to
# heal it.
#
# A run that dies anywhere in between therefore leaves no marker, and the next
# run wipes. A run that died before ever reading the marker leaves the restored
# one in place, and `--record` refuses to overwrite a marker that is still
# there for exactly that reason: it was never consumed, so this run took no
# responsibility for `.build/` and the marker still describes the artifacts
# sitting in it.
#
# ---------------------------------------------------------------------------
# WHY OBJECT IDS, NOT A COMMIT
#
# The marker records one git object id per compared path — the tree id of each
# library's source directory, the blob id of each file. Comparing ids compares
# CONTENT, which is what the invariant is about, and it needs nothing from the
# old commit: on a `pull_request` run `actions/checkout` checks out an ephemeral
# merge commit that GitHub discards when the next push recomputes the merge ref,
# so a marker naming that commit would be unresolvable on every subsequent run
# of the same branch — the mechanism would be inert on the dominant event. An
# object id stays meaningful because the object is either present, byte for
# byte, or it is not.
#
# Recording the ids also makes a missing path loud. A `git diff` pathspec that
# matches nothing in either tree exits 0, so a renamed target directory would
# quietly answer `skip` forever; `git rev-parse HEAD:<path>` fails instead, and
# every failure here answers `wipe`.
#
# ---------------------------------------------------------------------------
# WHY KEEP-BIASED
#
# Skipping wrongly costs a link flake that a reader has no reason to connect to
# this script; wiping wrongly costs three minutes. So every uncertainty answers
# `wipe`: no marker (a cache saved before this mechanism existed, or no cache at
# all), a marker that is empty or unreadable, a compared path that no longer
# resolves, and any difference at all between the recorded ids and the current
# ones.
set -uo pipefail

# The paths whose CONTENT decides it. Keep this list in step with the modules
# the wipe step removes in `.github/workflows/test.yml`: it must cover their
# sources AND the sources of every first-party target they depend on, because a
# library is recompiled when its own files change or when a module it imports
# is re-emitted — and either way its cached archive is the one that can go
# stale underneath a fresh `.swiftmodule`.
#
# `Sources/TBDDaemon` is not a typo for a third target: it is where the
# TBDDaemonLib *library* lives (`path: "Sources/TBDDaemon"` in `Package.swift`),
# the `TBDDaemon` executable target beside it being `main.swift` alone. A list
# naming a `Sources/TBDDaemonLib` directory would match nothing.
#
# `Sources/TBDTerminalSerialization` is TBDDaemonLib's one first-party
# dependency beyond TBDShared, so a commit touching only that target still
# recompiles TBDDaemonLib and still needs the wipe.
#
# `Package.swift` and `Package.resolved` are here because a manifest or
# dependency change can move a library's module boundary without touching a
# single file under `Sources/`.
#
# The cache-save decision step in `.github/workflows/test.yml` ("Decide whether
# this run may save the SwiftPM cache") diffs the same set of paths to decide
# whether a pull request has earned its own cache entry. The two lists MUST stay
# identical — they are one question asked twice — and
# `scripts/cache-save-policy.test.sh` reddens if they drift.
WIPE_PATHS=(
  Sources/TBDShared
  Sources/TBDDaemon
  Sources/TBDTerminalSerialization
  Package.swift
  Package.resolved
)

MARKER_HEADER_PREFIX='#'

usage() {
  echo "usage: $(basename "$0") [--record] <marker-path>" >&2
  exit 64
}

# One `<path> <object-id>` line per compared path, in list order. Fails, having
# said which path, if any of them does not resolve at HEAD.
fingerprint_of_head() {
  local path oid
  for path in "${WIPE_PATHS[@]}"; do
    oid="$(git rev-parse --verify --quiet "HEAD:$path" 2>/dev/null)"
    if [ -z "$oid" ]; then
      echo "$path does not resolve at HEAD — renamed, removed, or not a checkout of this repository." >&2
      return 1
    fi
    printf '%s %s\n' "$path" "$oid"
  done
}

# The comparable part of a marker: its header line is provenance for a human
# reading the job log and takes no part in the decision.
recorded_fingerprint() {
  grep -v "^$MARKER_HEADER_PREFIX" "$1" 2>/dev/null
}

decide() {
  printf '%s\n' "$1"
  printf '%s\n' "$2" >&2
  exit 0
}

record() {
  local marker="$1" current
  # A marker still sitting there means the decision step never ran to consume
  # it, so this run never took responsibility for what is in `.build/`: the
  # artifacts are whatever the cache restored, and the marker already describes
  # them. Overwriting it with the current tree would be a claim this run cannot
  # back.
  if [ -f "$marker" ]; then
    echo "Leaving the marker at $marker alone: it was never read, so it still describes the artifacts in place." >&2
    exit 0
  fi
  if ! current="$(fingerprint_of_head)"; then
    echo "Recording no marker, so the next run wipes." >&2
    exit 0
  fi
  {
    printf '%s recorded at %s\n' "$MARKER_HEADER_PREFIX" "$(git rev-parse HEAD 2>/dev/null)"
    printf '%s\n' "$current"
  } > "$marker" || {
    echo "Could not write the marker at $marker, so the next run wipes." >&2
    rm -f "$marker"
    exit 0
  }
  echo "Recorded the first-party source fingerprint at $marker:" >&2
  cat "$marker" >&2
  exit 0
}

mode=decide
case "${1:-}" in
  --record) mode=record; shift ;;
  --*)      usage ;;
esac
marker="${1:-}"
[ -n "$marker" ] || usage

if [ "$mode" = "record" ]; then
  record "$marker"
fi

if [ ! -f "$marker" ]; then
  decide wipe "wipe: no marker at $marker, so the restored artifacts' provenance is unknown."
fi

recorded="$(recorded_fingerprint "$marker")"
if [ -z "$recorded" ]; then
  decide wipe "wipe: the marker at $marker is empty or unreadable."
fi

if ! current="$(fingerprint_of_head)"; then
  decide wipe "wipe: the comparison could not be made against HEAD (see above)."
fi

if [ "$recorded" = "$current" ]; then
  decide skip "skip: ${WIPE_PATHS[*]} are byte-identical to what these cached artifacts were built from."
fi

# Which of them moved, for a reader of the job log. A recorded line that is
# absent from the current fingerprint altogether — the compared set itself
# changed — leaves this empty, and the answer is `wipe` regardless.
changed=""
while read -r path oid; do
  [ -n "$path" ] || continue
  case "
$recorded
" in
    *"
$path $oid
"*) ;;
    *) changed="$changed $path" ;;
  esac
done <<EOF
$current
EOF
decide wipe "wipe: changed since these artifacts were built:${changed:- the compared set itself}"
