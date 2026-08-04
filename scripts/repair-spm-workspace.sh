#!/usr/bin/env bash
# Repair a cache-restored SwiftPM workspace before anything tries to build it.
#
# A restored `.build/` can come back with a dependency checkout present but its
# manifest missing. Observed on run 30557645064 (PR #554): `.build/checkouts/
# swift-cmark/Package.swift` was absent after an error-free restore, SPM failed
# at manifest planning ("the package manifest ... cannot be accessed"), and the
# job went red before a single test compiled — on a docs-only diff.
#
# The stored cache entry was NOT the problem: the rerun restored the same key at
# the same byte count and passed. So the damage is workspace-local, one runner's
# copy, and a bare rerun clears it. That is precisely the red worth spending a
# few seconds to prevent — a rerun costs ~6 minutes of CI and a human deciding
# whether the failure was real.
#
# `swift package resolve` is the probe rather than a hand-rolled "does every
# checkout have a Package.swift" check: it is SPM's own validation, so it also
# catches damage a file-existence test would miss. On failure, discard only what
# SPM can rebuild — `checkouts/` and `repositories/` — and resolve again.
# Compiled artifacts under `.build/*/debug/` are untouched, so the cache stays
# warm for everything except the dependencies themselves. (Re-cloned checkouts
# get fresh mtimes, so the repair path does pay a dependency rebuild. That only
# happens on a run that was otherwise going to fail outright.)
#
# Wired into .github/workflows/{test,nightly}.yml immediately after the cache
# restore. Safe to run anywhere: on a cold workspace with no `.build/` it is a
# no-op, and on a healthy one it is a single resolve.

# Seam so the tests can drive both branches without a network or a toolchain.
: "${SPM_RESOLVE_CMD:=swift package resolve}"

resolve() { $SPM_RESOLVE_CMD; }

main() {
  if [[ ! -d .build ]]; then
    echo "no .build/ — cold workspace, nothing to repair"
    return 0
  fi

  if resolve; then
    echo "restored SwiftPM workspace resolves cleanly"
    return 0
  fi

  # Deliberately a warning, not an error: the run is expected to recover, and an
  # ::error:: annotation on a green run reads as a failure to whoever skims it.
  echo "::warning::swift package resolve failed on the restored workspace — discarding .build/checkouts and .build/repositories, then re-resolving. See scripts/repair-spm-workspace.sh."
  rm -rf .build/checkouts .build/repositories

  if resolve; then
    echo "workspace repaired by re-resolving dependencies"
    return 0
  fi

  # A second failure is not the cache-damage signature — it is a genuinely
  # broken Package.resolved, an unreachable dependency, or a toolchain problem.
  # Fail loudly here rather than let it surface later as a confusing test error.
  echo "::error::swift package resolve still fails after discarding dependency checkouts — this is not restored-cache damage. Check Package.resolved and dependency availability."
  return 1
}

# --- entrypoint (strict mode only when executed, not when sourced) -----------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  main "$@"
fi
