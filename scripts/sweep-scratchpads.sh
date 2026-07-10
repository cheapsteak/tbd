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
# Usage:
#   scripts/sweep-scratchpads.sh            # sweep now
#   scripts/sweep-scratchpads.sh --dry-run  # print the plan; delete nothing
#
# Test seams (env):
#   SWEEP_BASE      scratchpad base dir            (default /private/tmp/claude-$(id -u))
#   SWEEP_LSOF_CMD  command emitting `lsof -d cwd -Fn`  (default: lsof -d cwd -Fn)
#   SWEEP_DAYS      keep-if-modified-within N days (default 3)

SWEEP_DAYS="${SWEEP_DAYS:-3}"

log() { printf '%s\n' "$*" >&2; }

# --- test seams --------------------------------------------------------------
_base()      { printf '%s\n' "${SWEEP_BASE:-/private/tmp/claude-$(id -u)}"; }
_lsof_lines() { if [[ -n "${SWEEP_LSOF_CMD:-}" ]]; then eval "$SWEEP_LSOF_CMD"; else lsof -d cwd -Fn 2>/dev/null; fi; }

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

_avail_kb() { df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}' || true; }

main() {
  local dry=false
  [[ "${1:-}" == "--dry-run" ]] && dry=true

  local base; base="$(_base)"
  if [[ ! -d "$base" ]]; then log "no scratchpad base at $base"; return 0; fi

  local keep_slugs; keep_slugs="$(live_cwd_slugs)"

  local avail_before=""
  if [[ "$dry" != "true" ]]; then avail_before="$(_avail_kb)"; fi

  local d slug
  for d in "$base"/*/; do
    [[ -d "$d" ]] || continue
    slug="$(basename "$d")"
    if [[ -n "$keep_slugs" ]] && grep -qxF -- "$slug" <<< "$keep_slugs"; then
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
