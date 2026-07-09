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
#   RECLAIM_REPO_ROOTS  newline-separated repo roots to scan for .claude/worktrees/*
#                       (default: derived from the TBD worktree list's git-common-dir)
#   RECLAIM_EXCLUDE_PATH  single worktree path to skip unconditionally (both tiers,
#                       both enumeration sources). Paths are canonicalized before
#                       comparing, so symlinked/trailing-slash/relative variants of
#                       the same dir still match. Empty/unset = no exclusion.
#                       restart.sh passes its own worktree here so the background
#                       reclaim it fires can never race the swift build it overlaps.

RECLAIM_T1_SECONDS="${RECLAIM_T1_SECONDS:-21600}"
RECLAIM_T2_SECONDS="${RECLAIM_T2_SECONDS:-172800}"
RECLAIM_ACTIVE_GRACE="${RECLAIM_ACTIVE_GRACE:-600}"

log() { printf '%s\n' "$*" >&2; }

# --- test seams --------------------------------------------------------------
_now()           { printf '%s\n' "${RECLAIM_NOW:-$(date +%s)}"; }
_worktree_json() { if [[ -n "${RECLAIM_WT_JSON:-}" ]]; then cat "$RECLAIM_WT_JSON"; else tbd worktree list --json; fi; }
_ps_lines()      { if [[ -n "${RECLAIM_PS_CMD:-}" ]]; then eval "$RECLAIM_PS_CMD"; else ps -axo pid,args; fi; }

# --- helpers -----------------------------------------------------------------

# canon_path PATH -> physical path (symlinks resolved, trailing slash dropped);
# falls back to the input verbatim if the directory doesn't exist, so two
# references to a vanished dir still compare equal textually.
canon_path() {
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

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

# list_worktrees_tsv -> "<path>\t<liveSessions>" for each active worktree
list_worktrees_tsv() {
  _worktree_json | jq -r '.[] | select(.status == "active") | [.path, (.liveClaudeSessionCount // 0)] | @tsv'
}

# repo_root_for_worktree WORKTREE_PATH -> absolute repo root (parent of the
# common .git dir), or nonzero exit if the worktree is gone / not a git dir.
# A TBD worktree may have been deleted between listing and probing; callers
# guard with `|| continue`.
repo_root_for_worktree() {
  local wt="$1" common_git
  common_git="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$common_git" ]] || return 1
  dirname "$common_git"
}

# repo_roots -> unique repo roots to scan for Claude agent worktrees.
# RECLAIM_REPO_ROOTS (newline-separated), when set, is used INSTEAD of
# deriving roots from the TBD worktree list — the test injection seam.
repo_roots() {
  if [[ -n "${RECLAIM_REPO_ROOTS:-}" ]]; then
    printf '%s\n' "$RECLAIM_REPO_ROOTS"
  else
    local wt sessions root
    while IFS=$'\t' read -r wt sessions; do
      [[ -n "$wt" ]] || continue
      root="$(repo_root_for_worktree "$wt")" || continue
      [[ -n "$root" ]] || continue
      printf '%s\n' "$root"
    done < <(list_worktrees_tsv)
  fi | grep -v '^[[:space:]]*$' | sort -u
}

# claude_agent_worktrees_tsv -> "<path>\t0" for each .claude/worktrees/*/ dir
# under every repo root. These have no TBD session concept, so they're always
# reported with 0 live sessions (Tier-2 eligible on idleness alone). The
# Package.swift gate is applied by the caller, same as TBD worktrees.
claude_agent_worktrees_tsv() {
  local root d
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    for d in "$root"/.claude/worktrees/*/; do
      [[ -d "$d" ]] || continue
      printf '%s\t0\n' "${d%/}"
    done
  done < <(repo_roots)
}

# list_all_worktrees_tsv -> combined TBD + Claude-agent worktrees, deduped by
# path (first occurrence wins, so a TBD-list session count beats the
# Claude-agent default of 0 if the same path somehow appears in both).
list_all_worktrees_tsv() {
  { list_worktrees_tsv; claude_agent_worktrees_tsv; } | awk -F'\t' '!seen[$1]++'
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

  # Canonicalize the exclusion once up front; per-worktree paths are
  # canonicalized in the loop so symlink/trailing-slash/relative variants of
  # the same dir can't defeat the match (restart.sh derives its REPO_ROOT
  # from dirname "$0", which need not be textually identical to what the
  # TBD list or the .claude/worktrees glob reports).
  local exclude_canon=""
  if [[ -n "${RECLAIM_EXCLUDE_PATH:-}" ]]; then
    exclude_canon="$(canon_path "$RECLAIM_EXCLUDE_PATH")"
  fi

  local wt sessions
  while IFS=$'\t' read -r wt sessions; do
    [[ -n "$wt" ]] || continue
    if [[ -n "$exclude_canon" && "$(canon_path "$wt")" == "$exclude_canon" ]]; then
      echo "SKIP excluded $wt"
      continue
    fi
    [[ -f "$wt/Package.swift" ]] || continue   # only SwiftPM-package worktrees produce .build/index-build
    plan_worktree "$wt" "$sessions"
  done < <(list_all_worktrees_tsv) | tee "$plan_file" >&2

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
