#!/usr/bin/env bash
# scripts/reclaim-build.sh — reclaim stale SwiftPM .build disk from idle TBD worktrees.
# Dev tooling for the tbd repo; NOT part of the shipped product. See
# docs/superpowers/specs/2026-07-08-reclaim-worktree-build-disk-design.md
#
# Usage:
#   scripts/reclaim-build.sh            # seed index-build suppression + reclaim stale builds
#   scripts/reclaim-build.sh --dry-run  # print the plan; seed/delete nothing
#
# Test seams (env):
#   RECLAIM_WT_JSON     file with `tbd worktree list --json` output (default: run the CLI)
#   RECLAIM_PS_CMD      command emitting `pid args` lines   (default: ps -axo pid,args)
#   RECLAIM_T1_SECONDS  Tier-1 (index-build) idle threshold (default 21600 = 6h)
#   RECLAIM_T2_SECONDS  Tier-2 (whole .build) idle threshold (default 172800 = 48h)
#   RECLAIM_NOW         epoch seconds treated as "now"      (default: date +%s)

RECLAIM_T1_SECONDS="${RECLAIM_T1_SECONDS:-21600}"
RECLAIM_T2_SECONDS="${RECLAIM_T2_SECONDS:-172800}"

log() { printf '%s\n' "$*" >&2; }

# --- test seams --------------------------------------------------------------
_now()           { printf '%s\n' "${RECLAIM_NOW:-$(date +%s)}"; }
_worktree_json() { if [[ -n "${RECLAIM_WT_JSON:-}" ]]; then cat "$RECLAIM_WT_JSON"; else tbd worktree list --json; fi; }
_ps_lines()      { if [[ -n "${RECLAIM_PS_CMD:-}" ]]; then eval "$RECLAIM_PS_CMD"; else ps -axo pid,args; fi; }

# --- helpers -----------------------------------------------------------------

# newest_mtime DIR -> epoch of newest regular file under DIR (empty if none)
newest_mtime() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  { find "$dir" -type f -print0 2>/dev/null | xargs -0 stat -f '%m' 2>/dev/null | sort -rn | head -1; } || true
}

# has_active_build WORKTREE_PATH -> exit 0 if a swift build process references it
has_active_build() {
  local wt="$1"
  _ps_lines | grep -Ei 'swift-build|swift-frontend|swiftc|swift-driver' | grep -Fq -- "$wt"
}

main() {
  : # filled in Task 5
}

# --- entrypoint (strict mode only when executed, not when sourced) -----------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
