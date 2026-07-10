#!/usr/bin/env bash
# scripts/reclaim-build.sh — reclaim stale disk from idle TBD & Claude-agent worktrees.
# Dev tooling for the tbd repo; NOT part of the shipped product. See
# docs/superpowers/specs/2026-07-08-reclaim-worktree-build-disk-design.md
#
# Usage:
#   scripts/reclaim-build.sh            # reclaim stale builds + dependency installs
#   scripts/reclaim-build.sh --dry-run  # print the plan; delete nothing
#
# What it reclaims, per worktree (a TBD worktree OR a Claude .claude/worktrees/* one):
#   Tier 1 — SwiftPM .build/index-build idle > T1 (6h). Package.swift-gated.
#   Tier 2 — whole SwiftPM .build idle > T2 (48h), no live session. Package.swift-gated.
#   installs — node_modules/.venv/.terraform idle > T2, no live session. NOT gated on
#              Package.swift (these dominate non-Swift worktrees: ~4.3GB vs ~2.5GB .build).
#
# Safety rails applied to every worktree before anything is reaped:
#   - never reap a worktree that is the cwd of a live process (one lsof -d cwd pass)
#   - never reap a worktree with uncommitted changes (git status --porcelain)
#   - never reap a target touched within RECLAIM_ACTIVE_GRACE (recency guard)
#   - never reap a worktree with a running swift-* build process
#
# Test seams (env):
#   RECLAIM_WT_JSON     file with `tbd worktree list --json` output (default: run the CLI)
#   RECLAIM_PS_CMD      command emitting `pid args` lines   (default: ps -axo pid,args)
#   RECLAIM_LSOF_CMD    command emitting `lsof -d cwd -Fn`  (default: lsof -d cwd -Fn)
#   RECLAIM_T1_SECONDS  Tier-1 (index-build) idle threshold (default 21600 = 6h)
#   RECLAIM_T2_SECONDS  Tier-2 (.build + installs) idle threshold (default 172800 = 48h)
#   RECLAIM_NOW         epoch seconds treated as "now"      (default: date +%s)
#   RECLAIM_REPO_ROOTS  newline-separated repo roots to scan for .claude/worktrees/*
#                       (default: derived from the TBD worktree list's git-common-dir)
#   RECLAIM_EXCLUDE_PATH  single worktree path to skip unconditionally (all tiers,
#                       both enumeration sources). Paths are canonicalized before
#                       comparing, so symlinked/trailing-slash/relative variants of
#                       the same dir still match. Empty/unset = no exclusion.
#                       restart.sh passes its own worktree here so the background
#                       reclaim it fires can never race the swift build it overlaps.

RECLAIM_T1_SECONDS="${RECLAIM_T1_SECONDS:-21600}"
RECLAIM_T2_SECONDS="${RECLAIM_T2_SECONDS:-172800}"
RECLAIM_ACTIVE_GRACE="${RECLAIM_ACTIVE_GRACE:-600}"

# Newline-separated cwds of every live process, populated once by main() before
# the planning loop and consumed by is_live_cwd(). Declared here so it is defined
# when the script is sourced by the test harness.
LIVE_CWDS=""

# Dependency-install dirs reaped alongside .build at Tier 2. Kept in one place so
# plan/reap/recency-guard all agree on the set.
INSTALL_DIRS=(node_modules .venv .terraform)

log() { printf '%s\n' "$*" >&2; }

# --- test seams --------------------------------------------------------------
_now()           { printf '%s\n' "${RECLAIM_NOW:-$(date +%s)}"; }
_worktree_json() { if [[ -n "${RECLAIM_WT_JSON:-}" ]]; then cat "$RECLAIM_WT_JSON"; else tbd worktree list --json; fi; }
_ps_lines()      { if [[ -n "${RECLAIM_PS_CMD:-}" ]]; then eval "$RECLAIM_PS_CMD"; else ps -axo pid,args; fi; }
_lsof_lines()    { if [[ -n "${RECLAIM_LSOF_CMD:-}" ]]; then eval "$RECLAIM_LSOF_CMD"; else lsof -d cwd -Fn 2>/dev/null; fi; }

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

# dir_mtime DIR -> mtime of DIR itself (empty if missing). Cheap single stat —
# used for install dirs so we never deep-scan a 100k-file node_modules. npm/uv/
# terraform rewrite the top-level dir on install, so its mtime tracks "last
# installed" well enough for a >48h staleness gate.
dir_mtime() { stat -f '%m' "$1" 2>/dev/null || true; }

# newest_install_mtime WORKTREE -> newest dir_mtime across the install dirs that
# exist under WORKTREE (empty if none exist).
newest_install_mtime() {
  local wt="$1" d m newest=""
  for d in "${INSTALL_DIRS[@]}"; do
    [[ -d "$wt/$d" ]] || continue
    m="$(dir_mtime "$wt/$d")"
    [[ -n "$m" ]] || continue
    if [[ -z "$newest" ]] || (( m > newest )); then newest="$m"; fi
  done
  printf '%s\n' "$newest"
}

# has_active_build WORKTREE_PATH -> exit 0 if a swift build process references it
has_active_build() {
  local wt="$1"
  _ps_lines | grep -Ei 'swift-build|swift-frontend|swiftc|swift-driver' | grep -Fq -- "$wt"
}

# live_cwds -> newline-separated, deduped absolute cwds of every live process.
# The `|| true` keeps a no-match `grep` (no live cwds at all) from tripping the
# caller's `set -euo pipefail` when the result is captured into a variable.
live_cwds() {
  { _lsof_lines | grep '^n/' | sed 's|^n||' | sort -u; } || true
}

# is_live_cwd WORKTREE -> exit 0 if any live process cwd is at or below WORKTREE.
# Uses the LIVE_CWDS global (populated by main) and pure glob matching so paths
# with regex metacharacters can't misfire.
is_live_cwd() {
  local wt="${1%/}" line
  [[ -n "${LIVE_CWDS:-}" ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == "$wt" || "$line" == "$wt"/* ]] && return 0
  done <<< "$LIVE_CWDS"
  return 1
}

# is_dirty WORKTREE -> exit 0 if the worktree has uncommitted changes. A non-git
# path yields no porcelain output and is treated as clean.
is_dirty() {
  local wt="$1"
  [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null | head -1)" ]]
}

# has_reclaimable WORKTREE -> exit 0 if the reaper can act on this worktree at
# all: a SwiftPM .build (Package.swift-gated, so a stray non-Swift `.build` is
# left alone) or any dependency-install dir.
has_reclaimable() {
  local wt="$1" d
  [[ -f "$wt/Package.swift" && -d "$wt/.build" ]] && return 0
  for d in "${INSTALL_DIRS[@]}"; do
    [[ -d "$wt/$d" ]] && return 0
  done
  return 1
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
# live-cwd / dirty gates in main() are what protect a busy agent worktree.
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

# plan_worktree WORKTREE_PATH LIVE_SESSIONS -> decision line(s):
#   PLAN tier1 <wt>     rm .build/index-build
#   PLAN tier2 <wt>     rm whole .build
#   PLAN installs <wt>  rm node_modules/.venv/.terraform
#   SKIP active-build|fresh <wt>
# A SwiftPM worktree may emit both a .build tier line AND an installs line.
plan_worktree() {
  local wt="$1" sessions="$2"
  local now t1 t2
  now="$(_now)"; t1="$RECLAIM_T1_SECONDS"; t2="$RECLAIM_T2_SECONDS"

  local has_swift_build=false
  [[ -f "$wt/Package.swift" && -d "$wt/.build" ]] && has_swift_build=true

  # An in-flight swift build means an active worktree — leave it entirely alone.
  if [[ "$has_swift_build" == true ]] && has_active_build "$wt"; then
    echo "SKIP active-build $wt"
    return 0
  fi

  local emitted=false

  if [[ "$has_swift_build" == true ]]; then
    local build="$wt/.build" dbg_m idx_m dbg_dir
    # Tier 2 first (deleting the whole .build subsumes Tier 1). Measured on the
    # debug build, which Tier 1 never touches, so the clock is independent.
    # Derive the build-triple dir by glob so this fires on Intel
    # (x86_64-apple-macosx) as well as Apple Silicon (arm64-apple-macosx).
    dbg_dir="$(find "$build" -maxdepth 1 -type d -name '*-apple-macosx' 2>/dev/null | head -1)"
    dbg_m="$(newest_mtime "$dbg_dir")"
    if [[ -n "$dbg_m" ]] && (( now - dbg_m >= t2 )) && (( sessions == 0 )); then
      echo "PLAN tier2 $wt"; emitted=true
    else
      idx_m="$(newest_mtime "$build/index-build")"
      if [[ -n "$idx_m" ]] && (( now - idx_m >= t1 )); then
        echo "PLAN tier1 $wt"; emitted=true
      fi
    fi
  fi

  # Dependency installs: Tier-2 idleness, no live session. Independent of
  # Package.swift so node/python/terraform worktrees are covered.
  if (( sessions == 0 )); then
    local inst_m; inst_m="$(newest_install_mtime "$wt")"
    if [[ -n "$inst_m" ]] && (( now - inst_m >= t2 )); then
      echo "PLAN installs $wt"; emitted=true
    fi
  fi

  # Preserve the original "SKIP fresh" signal for a SwiftPM worktree that had a
  # .build but nothing aged out. Install-only / non-Swift worktrees stay silent
  # when nothing qualifies (they never emitted a line before this feature).
  if [[ "$has_swift_build" == true && "$emitted" == false ]]; then
    echo "SKIP fresh $wt"
  fi
}

_avail_kb() { df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}' || true; }

main() {
  local dry=false
  [[ "${1:-}" == "--dry-run" ]] && dry=true

  local avail_before=""
  if [[ "$dry" != "true" ]]; then avail_before="$(_avail_kb)"; fi
  local plan_file; plan_file="$(mktemp)"

  # One lsof pass for the whole run — the live-cwd gate for every worktree.
  LIVE_CWDS="$(live_cwds)"

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
    if is_live_cwd "$wt"; then echo "SKIP live-cwd $wt"; continue; fi
    if is_dirty "$wt"; then echo "SKIP dirty $wt"; continue; fi
    has_reclaimable "$wt" || continue
    plan_worktree "$wt" "$sessions"
  done < <(list_all_worktrees_tsv) | tee "$plan_file" >&2

  if [[ "$dry" != "true" ]]; then
    local action tier path
    while read -r action tier path; do
      [[ "$action" == "PLAN" ]] || continue
      case "$tier" in
        tier1|tier2)
          if has_active_build "$path"; then log "skip (now active): $path"; continue; fi
          # Defense-in-depth: has_active_build's ps allowlist misses the dependency
          # fetch phase (top-level swift-build carries no worktree path; its git
          # children do the writing). A live fetch/build/index touches .build
          # continuously, so skip if anything under .build was written very recently.
          local newest; newest="$(newest_mtime "$path/.build")"
          if [[ -n "$newest" ]] && (( $(_now) - newest < RECLAIM_ACTIVE_GRACE )); then
            log "skip (recently active): $path"; continue
          fi
          if [[ "$tier" == "tier1" ]]; then
            if rm -rf "$path/.build/index-build"; then log "reclaimed index-build: $path"; else log "rm failed: $path"; fi
          else
            if rm -rf "$path/.build"; then log "reclaimed .build: $path"; else log "rm failed: $path"; fi
          fi
          ;;
        installs)
          # Recency guard on the install dirs themselves (a just-finished install
          # bumps the dir mtime).
          local inst_newest; inst_newest="$(newest_install_mtime "$path")"
          if [[ -n "$inst_newest" ]] && (( $(_now) - inst_newest < RECLAIM_ACTIVE_GRACE )); then
            log "skip (recently active installs): $path"; continue
          fi
          local d
          for d in "${INSTALL_DIRS[@]}"; do
            [[ -d "$path/$d" ]] || continue
            # ${path:?} guards against an empty path ever expanding "rm -rf" to "/$d".
            if rm -rf "${path:?}/$d"; then log "reclaimed $d: $path"; else log "rm failed ($d): $path"; fi
          done
          ;;
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
