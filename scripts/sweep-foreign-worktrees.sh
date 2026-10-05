#!/usr/bin/env bash
# scripts/sweep-foreign-worktrees.sh — report, and on request remove, git worktrees
# that were created outside TBD (by another agent tool, by hand) and have no lifecycle.
# Dev tooling, user-land on purpose; NOT part of the shipped product. Sibling of
# scripts/sweep-scratchpads.sh and scripts/reclaim-build.sh — same conventions (env
# seams, source guard, canonical-path comparison). Design:
#   docs/specs/2026-10-05-foreign-worktree-sweep-design.md
#
# Discovery: every repo TBD has registered (`tbd repo list --json`) plus each
# `--repo <path>`. A path is only ever treated as a worktree because
# `git worktree list --porcelain` listed it; nothing is globbed. Candidates are the
# listed worktrees that are neither the repo's main worktree nor a worktree TBD
# manages (`tbd worktree list --json`, every status), nor one that OrphanGC owns
# (`<repo>/.claude/worktrees/agent-*` and `wf_*`).
#
# Auto tier — a candidate is AUTO only when ALL hold; anything uncertain is KEEP:
#   - not locked (`git worktree lock`);
#   - a MERGED PR whose headRefOid contains HEAD (`git merge-base --is-ancestor`);
#     a merged PR that does NOT contain HEAD is reported FOLLOW-UP and never removed;
#   - clean tree: `git status --porcelain` empty apart from the untracked `.context/`;
#   - no live process with its cwd, or an executable/mapped binary, under the path;
#     an lsof that is missing, exits non-zero or prints nothing makes the check
#     unavailable, and every candidate is then KEEP live-check-unavailable;
#   - idle: no file (nor the worktree's gitdir HEAD/index) modified within --idle-hours.
# Default is a dry-run report, one line per candidate: `<TIER> <reason> <path>`.
# `--apply` removes AUTO candidates only: `.context/` is copied into the salvage dir
# first, and a failed copy blocks the removal.
#
# Operator tier — `--salvage-remove <path>` (one path; acts only with --apply):
#   INFO.txt, refs/salvage/<name>-<YYYYMMDD> -> HEAD, uncommitted.patch, a tarball of
#   untracked files (capped by --untracked-cap-mb; over the cap the removal aborts
#   unless --allow-untracked-loss), a copy of .context/, then
#   `git worktree remove --force --force`. Any failed step blocks the removal.
#   It refuses before any salvage step when a live process is under the path or the
#   live-process check is unavailable. There is no `rm -rf` fallback anywhere.
#
# Usage:
#   scripts/sweep-foreign-worktrees.sh [--repo PATH]... [--idle-hours N]   # report
#   scripts/sweep-foreign-worktrees.sh --apply [--salvage-dir DIR] ...     # remove AUTO
#   scripts/sweep-foreign-worktrees.sh --salvage-remove PATH [--apply]
#       [--untracked-cap-mb N] [--allow-untracked-loss] [--salvage-dir DIR]
#
# Test seams (env):
#   SWEEP_FW_TBD_BIN    executable standing in for `tbd`          (default: tbd)
#   SWEEP_FW_GH_BIN     executable standing in for `gh`           (default: gh)
#   SWEEP_FW_LSOF_CMD   command emitting `lsof -d cwd,txt -Fn`    (default: that lsof;
#                       empty output or a non-zero exit means "check unavailable")
#   SWEEP_FW_FETCH_BIN  executable run as `<bin> <repo> <oid>` to fetch a PR head
#                       absent locally (default: git fetch origin <oid>)
#   SWEEP_FW_REQUIRE_SEAMS  when 1, refuse to run unless all four seams above are set
#                       (the test harness sets it so nothing can reach a real tool)
#   TBD_HOME            TBD's config dir; the default salvage root is $TBD_HOME/salvage

SWEEP_FW_IDLE_HOURS=24
SWEEP_FW_CAP_MB=300
LIVE_OK=0       # 1 once a live-process scan succeeded; set by main()
LIVE_DIRS=""    # newline-separated canonical dirs from live_dirs()

log() { printf '%s\n' "$*" >&2; }
die() { log "sweep-foreign-worktrees: $*"; exit 2; }

# --- test seams --------------------------------------------------------------
_tbd() { "${SWEEP_FW_TBD_BIN:-tbd}" "$@"; }
_gh()  { "${SWEEP_FW_GH_BIN:-gh}" "$@"; }
_lsof_lines() {
  if [[ -n "${SWEEP_FW_LSOF_CMD:-}" ]]; then eval "$SWEEP_FW_LSOF_CMD"
  else lsof -d cwd,txt -Fn 2>/dev/null; fi
}
_lsof_available() { [[ -n "${SWEEP_FW_LSOF_CMD:-}" ]] || command -v lsof >/dev/null 2>&1; }
_fetch_oid() {  # _fetch_oid REPO OID
  if [[ -n "${SWEEP_FW_FETCH_BIN:-}" ]]; then "$SWEEP_FW_FETCH_BIN" "$1" "$2"
  else GIT_TERMINAL_PROMPT=0 git -C "$1" fetch --quiet --no-tags origin "$2" >/dev/null 2>&1; fi
}
_today() { date +%Y%m%d; }

require_seams() {
  [[ "${SWEEP_FW_REQUIRE_SEAMS:-}" == "1" ]] || return 0
  local v
  for v in SWEEP_FW_TBD_BIN SWEEP_FW_GH_BIN SWEEP_FW_LSOF_CMD SWEEP_FW_FETCH_BIN; do
    [[ -n "${!v:-}" ]] || die "SWEEP_FW_REQUIRE_SEAMS=1 but $v is unset"
  done
}

# --- helpers -----------------------------------------------------------------

# canon_path PATH -> physical path (symlinks resolved, trailing slash dropped), so
# macOS /tmp and /private/tmp compare equal. A non-directory resolves through its
# parent; a vanished path falls back to the input verbatim. Mirrors the siblings.
canon_path() {
  local p="$1"
  if [[ -d "$p" ]]; then (cd "$p" 2>/dev/null && pwd -P) || printf '%s\n' "$p"; return; fi
  local parent; parent="$(dirname "$p")"
  if [[ -d "$parent" ]]; then printf '%s/%s\n' "$(cd "$parent" 2>/dev/null && pwd -P)" "$(basename "$p")"
  else printf '%s\n' "$p"; fi
}

# is_under PATH ROOT -> true when PATH is ROOT or lies beneath it (both canonical).
is_under() { [[ "$1" == "$2" || "$1" == "$2/"* ]]; }

# repo_toplevel PATH -> canonical toplevel when PATH is exactly a git toplevel (a
# main or linked worktree, or a bare repo's git dir); fails otherwise. This is the
# guard that keeps a plain directory holding worktrees from ever being taken for a
# repo: it is not a toplevel, so it is rejected and nothing beneath it is touched.
repo_toplevel() {
  local p="$1" top canon_p
  [[ -d "$p" ]] || return 1
  canon_p="$(canon_path "$p")"
  if [[ "$(git -C "$p" rev-parse --is-bare-repository 2>/dev/null)" == "true" ]]; then
    top="$(canon_path "$(git -C "$p" rev-parse --absolute-git-dir 2>/dev/null)")" || return 1
  else
    top="$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [[ -n "$top" ]] || return 1
    top="$(canon_path "$top")"
  fi
  [[ "$top" == "$canon_p" ]] || return 1
  printf '%s\n' "$top"
}

# list_worktrees REPO -> one record per listed worktree, fields separated by US
# (\037: not whitespace, so an empty branch never collapses into its neighbour):
#   index  path  branch(or empty)  head-sha  locked(0/1)
# index 0 is the main worktree (git always lists it first).
list_worktrees() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '
    function flush() { if (path != "") printf "%d\037%s\037%s\037%s\037%d\n", idx++, path, branch, head, locked; path=""; branch=""; head=""; locked=0 }
    BEGIN { idx=0; locked=0 }
    /^worktree / { flush(); path=substr($0, 10); next }
    /^HEAD /     { head=substr($0, 6); next }
    /^branch /   { branch=substr($0, 8); sub(/^refs\/heads\//, "", branch); next }
    /^locked/    { locked=1; next }
    END { flush() }'
}

# managed_paths -> canonical path of every worktree TBD manages, any status. Fails
# (and the caller refuses to proceed) when TBD cannot be asked: without this list a
# TBD worktree would be indistinguishable from a foreign one.
managed_paths() {
  local active archived
  active="$(_tbd worktree list --json 2>/dev/null)" || return 1
  archived="$(_tbd worktree list --status archived --json 2>/dev/null)" || return 1
  { printf '%s\n' "$active" | jq -r '.[].path' && printf '%s\n' "$archived" | jq -r '.[].path'; } 2>/dev/null \
    | while IFS= read -r p; do [[ -n "$p" ]] && canon_path "$p"; done | sort -u
}

# registered_repos -> path of every repo TBD has registered (missing ones skipped later).
registered_repos() {
  local json; json="$(_tbd repo list --json 2>/dev/null)" || return 1
  printf '%s\n' "$json" | jq -r '.[].path' 2>/dev/null
}

# live_dirs (stdin: `lsof -d cwd,txt -Fn` output) -> canonical directory of every
# live process cwd and every executable or mapped binary (`txt`). A binary
# contributes its parent dir, so "under the worktree" is a prefix test. Unique dirs
# are canonicalized once each to keep this cheap.
live_dirs() {
  { awk '/^f/ { fd=substr($0,2); next } /^n\// { p=substr($0,2); if (fd == "cwd") print p; else { sub(/\/[^\/]*$/, "", p); print p } }' \
      | sort -u | while IFS= read -r d; do canon_path "$d"; done | sort -u; } || true
}

# scan_live -> sets LIVE_DIRS, and LIVE_OK=1 only when the scan is trustworthy.
# Fails closed: no lsof, a non-zero lsof exit, or an empty result all leave
# LIVE_OK=0. Empty output is itself the failure signal, because a working lsof
# always reports at least this script's own cwd — reading it as "nothing live"
# would wave every worktree past the one guard that protects a running session.
scan_live() {
  LIVE_OK=0; LIVE_DIRS=""
  _lsof_available || return 0
  local raw st=0
  raw="$(_lsof_lines)" || st=$?
  (( st == 0 )) || return 0
  LIVE_DIRS="$(printf '%s\n' "$raw" | live_dirs)"
  [[ -n "$LIVE_DIRS" ]] || return 0
  LIVE_OK=1
}

has_live_process() {  # has_live_process CANON_WT
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if is_under "$d" "$1"; then return 0; fi
  done <<< "$LIVE_DIRS"
  return 1
}

# is_clean WT -> true when the only status entry (if any) is the untracked .context.
# --no-optional-locks keeps status from refreshing the index, which would bump its
# mtime and make a report run defeat the idle test of the --apply run after it.
is_clean() {
  local out
  out="$(git -C "$1" --no-optional-locks status --porcelain --untracked-files=normal 2>/dev/null)" || return 1
  out="$(printf '%s\n' "$out" | grep -vxF -e '?? .context/' -e '?? .context' -e '' || true)"
  [[ -z "$out" ]]
}

# recently_touched WT HOURS -> true when any file in WT, or the worktree's gitdir
# HEAD/index, was modified within HOURS. An unreadable tree counts as touched.
recently_touched() {
  local wt="$1" mins=$(( $2 * 60 )) hit gd st=0
  (( mins > 0 )) || return 1   # --idle-hours 0 disables the test (BSD find rounds -mmin -0 up)
  hit="$(find "$wt" -type f -mmin "-$mins" -print -quit 2>/dev/null)" || st=$?
  [[ -n "$hit" ]] && return 0
  (( st == 0 )) || return 0   # a full walk that hit unreadable entries -> uncertain
  gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  local f
  for f in "$gd/HEAD" "$gd/index"; do
    [[ -e "$f" ]] || continue
    [[ -n "$(find "$f" -mmin "-$mins" -print 2>/dev/null)" ]] && return 0
  done
  return 1
}

# pr_status REPO WT BRANCH HEAD -> prints "<state> <detail>" where state is one of
#   contained <num>   a merged PR's head contains HEAD
#   follow-up <num>   merged PR(s) exist; none contains HEAD
#   none              no merged PR found
#   unknown <why>     gh failed / PR head object unavailable
pr_status() {
  local repo="$1" wt="$2" branch="$3" head="$4" json rows
  if [[ -n "$branch" ]]; then
    json="$(cd "$wt" && _gh pr list --state merged --head "$branch" --json number,headRefOid,url 2>/dev/null)" || { echo "unknown gh-failed"; return; }
  else
    json="$(cd "$wt" && _gh pr list --state merged --search "$head" --json number,headRefOid,url 2>/dev/null)" || { echo "unknown gh-failed"; return; }
  fi
  rows="$(printf '%s\n' "$json" | jq -r '.[] | "\(.number)\t\(.headRefOid)"' 2>/dev/null)" || { echo "unknown gh-output-unparseable"; return; }
  [[ -n "$rows" ]] || { echo "none"; return; }
  local num oid unavailable="" moved=""
  while IFS=$'\t' read -r num oid; do
    [[ -n "$oid" && "$oid" != "null" ]] || { unavailable="$num"; continue; }
    if ! git -C "$repo" cat-file -e "$oid^{commit}" 2>/dev/null; then
      _fetch_oid "$repo" "$oid" </dev/null >/dev/null 2>&1 || true
      git -C "$repo" cat-file -e "$oid^{commit}" 2>/dev/null || { unavailable="$num"; continue; }
    fi
    if git -C "$repo" merge-base --is-ancestor "$head" "$oid" 2>/dev/null; then
      echo "contained $num"; return
    fi
    moved="$num"
  done <<< "$rows"
  if [[ -n "$unavailable" ]]; then echo "unknown pr-head-unavailable#$unavailable"; return; fi
  echo "follow-up $moved"
}

# salvage_entry ROOT NAME -> a fresh directory ROOT/NAME, suffixed -2, -3, ... when
# an entry already exists; an existing salvage entry is never written into.
salvage_entry() {
  local root="$1" name="$2" e n=2
  mkdir -p "$root" || return 1
  e="$root/$name"
  # Plain mkdir (no -p) on the entry itself fails if it appeared meanwhile.
  until [[ ! -e "$e" ]] && mkdir "$e" 2>/dev/null; do
    e="$root/$name-$n"; n=$((n + 1))
    (( n < 1000 )) || return 1
  done
  printf '%s\n' "$e"
}

salvage_root() { printf '%s/%s\n' "${SALVAGE_DIR:-${TBD_HOME:-$HOME/tbd}/salvage}" "$(_today)"; }

safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

copy_context() {  # copy_context WT ENTRY -> copies WT/.context into ENTRY/.context
  [[ -d "$1/.context" ]] || return 0
  cp -Rp "$1/.context" "$2/.context"
}

remove_worktree() {  # remove_worktree OWNING_REPO WT
  git -C "$1" worktree remove --force --force "$2"
}

# --- auto tier ---------------------------------------------------------------

classify() {  # classify REPO WT BRANCH HEAD LOCKED -> "<TIER> <reason>"
  local repo="$1" wt="$2" branch="$3" head="$4" locked="$5"
  [[ -d "$wt" ]] || { echo "KEEP missing-directory"; return; }
  [[ "$locked" == "1" ]] && { echo "KEEP locked"; return; }
  local pr state detail
  pr="$(pr_status "$repo" "$wt" "$branch" "$head")"
  state="${pr%% *}"; detail="${pr#* }"
  case "$state" in
    none)      echo "KEEP no-merged-pr"; return ;;
    unknown)   echo "KEEP $detail"; return ;;
    follow-up) echo "FOLLOW-UP head-moved-past-merged-pr#$detail"; return ;;
    contained) ;;
    *)         echo "KEEP pr-status-unknown"; return ;;
  esac
  is_clean "$wt" || { echo "KEEP dirty"; return; }
  [[ "$LIVE_OK" == "1" ]] || { echo "KEEP live-check-unavailable"; return; }
  has_live_process "$wt" && { echo "KEEP live-process"; return; }
  recently_touched "$wt" "$SWEEP_FW_IDLE_HOURS" && { echo "KEEP recent-activity"; return; }
  echo "AUTO merged-pr#$detail"
}

orphan_gc_owned() {  # orphan_gc_owned REPO WT -> OrphanGC's own agent worktrees
  case "$2" in "$1"/.claude/worktrees/agent-*|"$1"/.claude/worktrees/wf_*) return 0 ;; esac
  return 1
}

sweep() {
  local apply="$1"; shift
  local managed; managed="$(managed_paths)" || die "cannot read TBD's worktree list (tbd worktree list --json); refusing to guess which worktrees TBD manages"

  local repos="" r top
  local registered; registered="$(registered_repos)" || die "cannot read TBD's repo list (tbd repo list --json)"
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    if top="$(repo_toplevel "$r")"; then repos+="$top"$'\n'; else log "skip registered repo (not a git toplevel): $r"; fi
  done <<< "$registered"
  for r in "$@"; do repos+="$r"$'\n'; done   # --repo values, validated by main()

  # One pass per git common dir, so a repo registered twice (or also passed with
  # --repo, or registered via a linked worktree) is walked once.
  local seen_common="" seen_wt="" common
  local n_auto=0 n_keep=0 n_follow=0 n_removed=0 rc=0
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    common="$(canon_path "$(git -C "$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$r")")"
    if grep -qxF -- "$common" <<< "$seen_common"; then continue; fi
    seen_common+="$common"$'\n'

    local idx wt branch head locked main="" cwt verdict tier reason
    while IFS=$'\037' read -r idx wt branch head locked; do
      if [[ "$idx" == "0" ]]; then main="$(canon_path "$wt")"; continue; fi
      cwt="$(canon_path "$wt")"
      grep -qxF -- "$cwt" <<< "$seen_wt" && continue
      seen_wt+="$cwt"$'\n'
      grep -qxF -- "$cwt" <<< "$managed" && continue
      orphan_gc_owned "$main" "$cwt" && { echo "KEEP orphan-gc-owned $cwt"; n_keep=$((n_keep + 1)); continue; }

      verdict="$(classify "$main" "$cwt" "$branch" "$head" "$locked" </dev/null)"
      tier="${verdict%% *}"; reason="${verdict#* }"
      echo "$tier $reason $cwt"
      case "$tier" in
        AUTO) n_auto=$((n_auto + 1)) ;;
        FOLLOW-UP) n_follow=$((n_follow + 1)) ;;
        *) n_keep=$((n_keep + 1)) ;;
      esac
      [[ "$tier" == "AUTO" && "$apply" == "1" ]] || continue

      local entry=""
      if [[ -d "$cwt/.context" ]]; then
        if ! entry="$(salvage_entry "$(salvage_root)" "$(safe_name "$(basename "$cwt")")")" \
           || ! copy_context "$cwt" "$entry" </dev/null; then
          log "salvage of .context failed; NOT removing: $cwt"; rc=1; continue
        fi
      fi
      if remove_worktree "$main" "$cwt" </dev/null >/dev/null 2>&1; then
        n_removed=$((n_removed + 1))
        log "removed: $cwt${entry:+ (.context salvaged to $entry)}"
      else
        log "git worktree remove failed: $cwt"; rc=1
      fi
    done < <(list_worktrees "$r")
  done <<< "$repos"

  log "summary: $n_auto auto, $n_follow follow-up, $n_keep keep; $n_removed removed$([[ "$apply" == "1" ]] || echo " (report only; pass --apply to remove AUTO)")"
  return "$rc"
}

# --- operator tier -----------------------------------------------------------

salvage_remove() {  # salvage_remove PATH APPLY CAP_MB ALLOW_LOSS
  local target="$1" apply="$2" cap_mb="$3" allow_loss="$4"
  local wt; wt="$(repo_toplevel "$target")" || die "not a git worktree toplevel: $target"

  # Must be listed by its repo's `git worktree list`, and not as the main worktree.
  local idx p branch head locked main="" found=""
  while IFS=$'\037' read -r idx p branch head locked; do
    if [[ "$idx" == "0" ]]; then main="$(canon_path "$p")"; fi
    if [[ "$(canon_path "$p")" == "$wt" ]]; then found="$idx"; break; fi
  done < <(list_worktrees "$wt")
  [[ -n "$found" ]] || die "git does not list $wt as a worktree"
  [[ "$found" != "0" ]] || die "refusing: $wt is its repo's main worktree"

  local managed; managed="$(managed_paths)" || die "cannot read TBD's worktree list; refusing"
  grep -qxF -- "$wt" <<< "$managed" && die "refusing: TBD manages $wt (use TBD to archive it)"

  scan_live
  [[ "$LIVE_OK" == "1" ]] || die "cannot check for live processes (lsof missing, failed, or reported nothing); refusing"
  has_live_process "$wt" && die "refusing: a live process has its cwd or a binary under $wt"

  local sha; sha="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)" || die "cannot resolve HEAD in $wt"
  local name; name="$(safe_name "$(basename "$wt")")"
  local today; today="$(_today)"
  local ref="refs/salvage/$name-$today" n=2
  while git -C "$main" show-ref --verify --quiet "$ref"; do ref="refs/salvage/$name-$today-$n"; n=$((n + 1)); done

  local untracked_list total=0 count=0 f
  untracked_list="$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null | grep -v '^\.context/' || true)"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    total=$(( total + $(file_size "$wt/$f" 2>/dev/null || echo 0) )); count=$((count + 1))
  done <<< "$untracked_list"
  local cap_bytes=$(( cap_mb * 1024 * 1024 ))
  local over=0; (( total > cap_bytes )) && over=1

  if [[ "$apply" != "1" ]]; then
    echo "PLAN salvage $wt"
    echo "  branch: ${branch:-DETACHED}  HEAD: $sha  locked: $locked"
    echo "  salvage entry under: $(salvage_root)/$name"
    echo "  ref: $ref"
    echo "  untracked: $count files, $total bytes (cap ${cap_mb} MB)$([[ "$over" == "1" ]] && echo " — OVER CAP: removal would abort unless --allow-untracked-loss")"
    echo "  .context: $([[ -d "$wt/.context" ]] && echo present || echo absent)"
    echo "(nothing done; pass --apply to salvage and remove)"
    return 0
  fi

  local entry
  entry="$(salvage_entry "$(salvage_root)" "$name")" || { log "ABORT: cannot create salvage entry; $wt NOT removed"; return 1; }
  echo "salvage entry: $entry"

  # 1. INFO.txt
  { printf 'path: %s\nrepo: %s\nbranch: %s\nHEAD: %s\nlast commit: %s\nsalvage ref: %s\n' \
      "$wt" "$main" "${branch:-DETACHED}" "$sha" "$(git -C "$wt" log -1 --format='%ci %s' "$sha")" "$ref"
  } > "$entry/INFO.txt" || { log "ABORT: writing INFO.txt failed; $wt NOT removed"; return 1; }

  # 2. salvage ref, created only if absent (empty old-value), in the owning repo
  git -C "$main" update-ref "$ref" "$sha" "" || { log "ABORT: update-ref $ref failed; $wt NOT removed"; return 1; }
  echo "ref: $ref -> $sha"

  # 3. uncommitted changes against HEAD
  git -C "$wt" diff HEAD --binary > "$entry/uncommitted.patch" || { log "ABORT: git diff failed; $wt NOT removed"; return 1; }
  [[ -s "$entry/uncommitted.patch" ]] || rm -f "$entry/uncommitted.patch"

  # 4. untracked files, capped
  if (( count > 0 )); then
    printf '%s\n' "$untracked_list" > "$entry/untracked-files.txt" || { log "ABORT: writing untracked list failed; $wt NOT removed"; return 1; }
    if [[ "$over" == "1" ]]; then
      if [[ "$allow_loss" != "1" ]]; then
        log "ABORT: untracked files total $total bytes, over the ${cap_mb} MB cap. The file list is at $entry/untracked-files.txt."
        log "       Re-run with a higher --untracked-cap-mb, or pass --allow-untracked-loss to remove without archiving them. $wt NOT removed."
        return 1
      fi
      log "untracked files over the cap NOT archived (--allow-untracked-loss); list kept at $entry/untracked-files.txt"
    else
      ( cd "$wt" && printf '%s\n' "$untracked_list" | sed 's|^|./|' | tar -czf "$entry/untracked.tar.gz" -T - ) \
        || { log "ABORT: archiving untracked files failed; $wt NOT removed"; return 1; }
    fi
  fi

  # 5. .context
  copy_context "$wt" "$entry" || { log "ABORT: copying .context failed; $wt NOT removed"; return 1; }

  # 6. remove, from the owning repo
  remove_worktree "$main" "$wt" || { log "git worktree remove failed; salvage kept at $entry"; return 1; }
  echo "removed: $wt"
}

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

main() {
  local apply=0 target="" allow_loss=0 cap_mb="$SWEEP_FW_CAP_MB"
  local repo_args=()
  SALVAGE_DIR=""
  while (( $# > 0 )); do
    case "$1" in
      --apply) apply=1 ;;
      --repo) [[ $# -ge 2 ]] || die "--repo needs a path"; repo_args+=("$2"); shift ;;
      --idle-hours) is_uint "${2:-}" || die "--idle-hours needs a whole number"; SWEEP_FW_IDLE_HOURS="$2"; shift ;;
      --salvage-dir) [[ -n "${2:-}" ]] || die "--salvage-dir needs a path"; SALVAGE_DIR="$2"; shift ;;
      --salvage-remove) [[ -n "${2:-}" ]] || die "--salvage-remove needs a path"; [[ -z "$target" ]] || die "--salvage-remove takes exactly one path"; target="$2"; shift ;;
      --untracked-cap-mb) is_uint "${2:-}" || die "--untracked-cap-mb needs a whole number"; cap_mb="$2"; shift ;;
      --allow-untracked-loss) allow_loss=1 ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
    shift
  done
  require_seams
  command -v jq >/dev/null 2>&1 || die "jq is required"

  if [[ -n "$target" ]]; then
    (( ${#repo_args[@]} == 0 )) || die "--salvage-remove cannot be combined with --repo"
    salvage_remove "$target" "$apply" "$cap_mb" "$allow_loss"
    return
  fi

  # Validate every --repo before anything else happens: a path that is not exactly a
  # git toplevel (e.g. a directory that merely holds worktrees) is an error.
  local validated=() r top
  for r in ${repo_args[@]+"${repo_args[@]}"}; do
    top="$(repo_toplevel "$r")" || die "--repo $r is not a git repository toplevel; nothing done"
    validated+=("$top")
  done

  scan_live
  [[ "$LIVE_OK" == "1" ]] || log "live-process check unavailable (lsof missing, failed, or reported nothing): nothing will be auto-removed"
  sweep "$apply" ${validated[@]+"${validated[@]}"}
}

# --- entrypoint (strict mode only when executed, not when sourced) -----------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
