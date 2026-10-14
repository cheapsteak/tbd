#!/usr/bin/env bash
# scripts/sweep-scratchpads.sh — remove orphaned Claude Code per-worktree scratchpads.
# Dev tooling for the tbd repo; NOT part of the shipped product. Sibling of
# scripts/reclaim-build.sh — same conventions (env seams, --dry-run, df-delta).
#
# Claude Code gives each worktree a scratch dir under
#   /private/tmp/claude-<uid>/<slug>/
# where <slug> = the worktree's absolute path with '/' replaced by '-'. When the
# worktree is deleted or its session dies, nothing cleans these up (a single dead
# session has been observed leaving 14 GB behind). This sweeps the orphans.
#
# A scratchpad is KEPT when either:
#   (a) a live process's cwd slugifies to it (an active session still owns it), or
#   (b) it contains a file modified within the last N days (default 3).
# Everything else is removed. Acts by default; --dry-run previews.
#
# The live-process probe fails closed: when lsof cannot be resolved, or reports
# no cwd at all, every scratchpad is kept for that run. Every live process has a
# cwd, so an empty answer means a broken probe, never an idle machine, and
# reading it as "no session is live" would leave the recency window as the only
# thing between a live session's scratchpad and rm -rf.
#
# Usage:
#   scripts/sweep-scratchpads.sh            # sweep now
#   scripts/sweep-scratchpads.sh --dry-run  # print the plan; delete nothing
#
# Test seams (env):
#   SWEEP_BASE      scratchpad base dir            (default /private/tmp/claude-$(id -u))
#   SWEEP_LSOF_CMD  command emitting `lsof -d cwd -Fn`  (default: lsof -d cwd -Fn,
#                   resolved from PATH and then from SWEEP_LSOF_CANDIDATES)
#   SWEEP_DAYS      keep-if-modified-within N days (default 3)

SWEEP_DAYS="${SWEEP_DAYS:-3}"

# 1 once the live-process probe has both run and produced data; set by
# scan_live_slugs(). While it is 0 nothing is removed.
LIVE_OK=0

# Slugs of the live process cwds, populated by scan_live_slugs().
KEEP_SLUGS=""

# Absolute locations searched for lsof when PATH does not resolve it. launchd
# and other minimal environments hand this script a PATH of their own, and
# /usr/sbin — where macOS keeps lsof — is easy to leave off it; resolving by
# PATH alone lets a short PATH silently disable the live-session rail.
SWEEP_LSOF_CANDIDATES=(/usr/sbin/lsof /usr/bin/lsof /usr/local/bin/lsof /opt/homebrew/bin/lsof)

log() { printf '%s\n' "$*" >&2; }

# --- test seams --------------------------------------------------------------
_base()      { printf '%s\n' "${SWEEP_BASE:-/private/tmp/claude-$(id -u)}"; }
# _lsof_bin -> the lsof to run, from PATH first and then SWEEP_LSOF_CANDIDATES.
# Nonzero exit when the tool is nowhere to be found. Mirrors scripts/reclaim-build.sh.
_lsof_bin() {
  local p
  if p="$(command -v lsof 2>/dev/null)" && [[ -n "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  for p in "${SWEEP_LSOF_CANDIDATES[@]}"; do
    [[ -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}
_lsof_lines() { if [[ -n "${SWEEP_LSOF_CMD:-}" ]]; then eval "$SWEEP_LSOF_CMD"; else local b; b="$(_lsof_bin)" || return 1; "$b" -d cwd -Fn 2>/dev/null; fi; }
# _lsof_available -> exit 0 when the probe can run at all. An injected seam
# counts as available; otherwise the tool itself has to resolve.
_lsof_available() { [[ -n "${SWEEP_LSOF_CMD:-}" ]] || _lsof_bin >/dev/null; }

# --- helpers -----------------------------------------------------------------

# canon_path PATH -> physical path (symlinks resolved, trailing slash dropped);
# falls back to the input verbatim if the dir is gone, so a vanished path still
# compares equal textually. Mirrors scripts/reclaim-build.sh.
canon_path() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

# live_cwd_slugs -> the scratchpad slug ('/'->'-') for every live process cwd,
# each canonicalized first so a symlinked cwd (macOS /tmp -> /private/tmp) still
# slugifies to the same value Claude Code derived from the resolved path. The
# `|| true` keeps a no-match grep from tripping `set -euo pipefail` on capture.
live_cwd_slugs() {
  { _lsof_lines | grep '^n/' | sed 's|^n||' | while IFS= read -r p; do canon_path "$p"; done | tr '/' '-' | sort -u; } || true
}

# scan_live_slugs -> sets KEEP_SLUGS, and LIVE_OK=1 only when the answer can be
# trusted. Fails closed: an lsof that cannot be resolved, or a probe that runs
# and reports no cwd at all, both leave LIVE_OK=0 and main() then keeps every
# scratchpad. The empty result is itself the failure signal, because a working
# probe always reports at least this script's own cwd. Mirrors scan_live_cwds()
# in scripts/reclaim-build.sh and scan_live() in sweep-foreign-worktrees.sh.
scan_live_slugs() {
  LIVE_OK=0; KEEP_SLUGS=""
  _lsof_available || return 0
  KEEP_SLUGS="$(live_cwd_slugs)"
  [[ -n "$KEEP_SLUGS" ]] || return 0
  LIVE_OK=1
}

_avail_kb() { df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}' || true; }

main() {
  local dry=false
  [[ "${1:-}" == "--dry-run" ]] && dry=true

  local base; base="$(_base)"
  if [[ ! -d "$base" ]]; then log "no scratchpad base at $base"; return 0; fi

  scan_live_slugs
  if (( LIVE_OK == 0 )); then
    log "WARNING: live-process probe produced no cwds (lsof unavailable or unreadable) — treating EVERY scratchpad as live; nothing will be removed this run"
  fi

  local avail_before=""
  if [[ "$dry" != "true" ]]; then avail_before="$(_avail_kb)"; fi

  local d slug
  for d in "$base"/*/; do
    [[ -d "$d" ]] || continue
    slug="$(basename "$d")"
    if (( LIVE_OK == 0 )); then echo "KEEP live-unknown $slug"; continue; fi
    if grep -qxF -- "$slug" <<< "$KEEP_SLUGS"; then
      echo "KEEP live $slug"; continue
    fi
    # Recently-written tree? (-print -quit stops at the first hit, so this is fast.)
    if [[ -n "$(find "$d" -type f -mtime -"$SWEEP_DAYS" -print -quit 2>/dev/null)" ]]; then
      echo "KEEP recent $slug"; continue
    fi
    echo "PLAN remove $slug"
    if [[ "$dry" != "true" ]]; then
      if rm -rf "$d"; then log "removed scratchpad: $slug"; else log "rm failed: $slug"; fi
    fi
  done

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
