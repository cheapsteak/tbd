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

# ensure_lsp_config WORKTREE_PATH DRY -> seed backgroundIndexing:false if absent
ensure_lsp_config() {
  local wt="$1" dry="$2"
  local cfg="$wt/.sourcekit-lsp/config.json"
  if [[ -f "$cfg" ]]; then
    echo "SKIP lsp-config-exists $wt"
    return 0
  fi
  echo "SEED lsp-config $wt"
  [[ "$dry" == "true" ]] && return 0
  mkdir -p "$wt/.sourcekit-lsp"
  printf '{\n  "backgroundIndexing": false\n}\n' > "$cfg"
}

# list_worktrees_tsv -> "<path>\t<liveSessions>" for each active worktree
list_worktrees_tsv() {
  _worktree_json | jq -r '.[] | select(.status == "active") | [.path, (.liveClaudeSessionCount // 0)] | @tsv'
}

# plan_worktree WORKTREE_PATH LIVE_SESSIONS -> one decision line (or nothing if no .build)
plan_worktree() {
  local wt="$1" sessions="$2"
  local build="$wt/.build"
  [[ -d "$build" ]] || return 0

  if has_active_build "$wt"; then
    echo "SKIP active-build $wt"
    return 0
  fi

  local now t1 t2 dbg_m idx_m
  now="$(_now)"; t1="$RECLAIM_T1_SECONDS"; t2="$RECLAIM_T2_SECONDS"

  # Tier 2 first (deleting the whole .build subsumes Tier 1). Measured on the
  # debug build, which Tier 1 never touches, so the clock is independent.
  dbg_m="$(newest_mtime "$build/arm64-apple-macosx")"
  if [[ -n "$dbg_m" ]] && (( now - dbg_m >= t2 )) && (( sessions == 0 )); then
    echo "PLAN tier2 $wt"
    return 0
  fi

  # Tier 1: index-build measured on its own subtree.
  idx_m="$(newest_mtime "$build/index-build")"
  if [[ -n "$idx_m" ]] && (( now - idx_m >= t1 )); then
    echo "PLAN tier1 $wt"
    return 0
  fi

  echo "SKIP fresh $wt"
}

main() {
  : # filled in Task 5
}

# --- entrypoint (strict mode only when executed, not when sourced) -----------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
