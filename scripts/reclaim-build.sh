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
RECLAIM_ACTIVE_GRACE="${RECLAIM_ACTIVE_GRACE:-600}"

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

  local now t1 t2 dbg_m idx_m dbg_dir
  now="$(_now)"; t1="$RECLAIM_T1_SECONDS"; t2="$RECLAIM_T2_SECONDS"

  # Tier 2 first (deleting the whole .build subsumes Tier 1). Measured on the
  # debug build, which Tier 1 never touches, so the clock is independent.
  # Derive the build-triple dir by glob so this fires on Intel
  # (x86_64-apple-macosx) as well as Apple Silicon (arm64-apple-macosx).
  dbg_dir="$(find "$build" -maxdepth 1 -type d -name '*-apple-macosx' 2>/dev/null | head -1)"
  dbg_m="$(newest_mtime "$dbg_dir")"
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

_avail_kb() { df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}' || true; }

main() {
  local dry=false
  [[ "${1:-}" == "--dry-run" ]] && dry=true

  local avail_before=""
  if [[ "$dry" != "true" ]]; then avail_before="$(_avail_kb)"; fi
  local plan_file; plan_file="$(mktemp)"

  local wt sessions
  while IFS=$'\t' read -r wt sessions; do
    [[ -n "$wt" ]] || continue
    [[ -f "$wt/Package.swift" ]] || continue   # only SwiftPM-package worktrees produce .build/index-build
    ensure_lsp_config "$wt" "$dry"
    plan_worktree "$wt" "$sessions"
  done < <(list_worktrees_tsv) | tee "$plan_file" >&2

  if [[ "$dry" != "true" ]]; then
    local action tier path
    while read -r action tier path; do
      [[ "$action" == "PLAN" ]] || continue
      if has_active_build "$path"; then log "skip (now active): $path"; continue; fi
      # Defense-in-depth: has_active_build's ps allowlist misses the dependency
      # fetch phase (top-level swift-build carries no worktree path; its git
      # children do the writing). A live fetch/build/index touches .build
      # continuously, so skip if anything under .build was written very recently.
      local newest; newest="$(newest_mtime "$path/.build")"
      if [[ -n "$newest" ]] && (( $(_now) - newest < RECLAIM_ACTIVE_GRACE )); then
        log "skip (recently active): $path"; continue
      fi
      case "$tier" in
        tier1)
          if rm -rf "$path/.build/index-build"; then log "reclaimed index-build: $path"; else log "rm failed: $path"; fi ;;
        tier2)
          if rm -rf "$path/.build"; then log "reclaimed .build: $path"; else log "rm failed: $path"; fi ;;
      esac
    done < "$plan_file"
  fi

  rm -f "$plan_file"
  if [[ "$dry" != "true" ]]; then
    local avail_after; avail_after="$(_avail_kb)"
    if [[ -n "${avail_before:-}" && -n "${avail_after:-}" ]]; then
      log "df delta: $(( (avail_after - avail_before) / 1024 )) MiB freed on /System/Volumes/Data"
    fi
  fi
}

# --- entrypoint (strict mode only when executed, not when sourced) -----------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
