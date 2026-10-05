#!/usr/bin/env bash
# scripts/sweep-branch-dbs.sh — drop orphaned per-worktree "branch databases".
# Dev tooling; NOT part of the shipped product. Sibling of
# scripts/sweep-scratchpads.sh and scripts/reclaim-build.sh — same conventions
# (env seams, source-guard, df-delta). Design:
# docs/specs/2026-10-05-branch-db-sweep-design.md
#
# Some projects give every worktree its own database on a local Postgres, named
# <prefix><label>, where <label> is derived from the worktree directory's
# basename. Nothing drops that database when the worktree goes away. This
# script finds the databases no live worktree accounts for and, with --apply,
# drops them. TBD does not create these databases; the naming contract belongs
# to the project, which is why --prefix is required and nothing is hardcoded.
#
# Label rule: basename, lowercased, '-' -> '_', every char outside [a-z0-9_]
# dropped, cut to 54 chars. Database name = prefix + label.
#
# A database <prefix><x> is KEPT when any of:
#   - x is empty or contains a char outside [a-z0-9_] (not made by the label rule)
#   - some live worktree label L satisfies L == x, L startswith x, or x startswith L
#     (a truncated name must never read as orphaned; every ambiguity keeps)
#   - with --apply: pg_stat_activity shows >0 connections to it, re-queried
#     immediately before its drop
# and is never considered at all when it does not start with the prefix or is
# postgres / template0 / template1 / the maintenance database.
#
# The run REFUSES (exit 1, drops nothing) when the scan has no roots, when a
# --root glob matches no directory, or when the scan found zero worktree paths.
# It SKIPS (exit 0, drops nothing) when Postgres is unreachable or in recovery.
# Dry-run is the default; --apply performs the drops.
#
# Usage:
#   scripts/sweep-branch-dbs.sh --prefix app_db_ --root "$HOME/tbd/worktrees/*/*"
#   scripts/sweep-branch-dbs.sh --prefix app_db_ --root "..." --apply
#   scripts/sweep-branch-dbs.sh --prefix app_db_ --worktree "$TBD_WORKTREE_PATH" --apply
#
# Options:
#   --prefix P       database-name prefix, [A-Za-z0-9_]+ (required)
#   --root GLOB      glob expanding to worktree directories; repeatable. TBD's own
#                    non-archived worktrees (`tbd worktree list --json`) are always
#                    added when the CLI is available.
#   --worktree PATH  single-target mode: consider only PATH's database
#   --apply          drop for real (default is a dry-run report)
#   --dry-run        explicit dry-run (the default)
#   --host H / --port N   passed through to psql and dropdb. PGHOST, PGPORT,
#                    PGUSER, PGPASSWORD etc. are honoured as usual.
#
# Test seams (env):
#   BRANCHDB_PSQL_CMD       psql command          (default: psql)
#   BRANCHDB_DROPDB_CMD     dropdb command        (default: dropdb)
#   BRANCHDB_TBD_LIST_CMD   command emitting `tbd worktree list --json`
#                           (default: tbd worktree list --json)
#   BRANCHDB_DF_CMD         command emitting `df -k`-style output for the volume
#                           holding the cluster (default: df -k "$PGDATA" or /)
#   BRANCHDB_MAINTENANCE_DB database psql connects to (default: postgres)

LABEL_MAX=54

log() { printf '%s\n' "$*" >&2; }

# --- test seams --------------------------------------------------------------
# Connection flags shared by psql and dropdb; filled by main() from --host/--port.
CONN_ARGS=()
_maint_db() { printf '%s\n' "${BRANCHDB_MAINTENANCE_DB:-postgres}"; }

# _psql SQL -> unaligned, tuples-only rows, tab-separated. The seam is word-split
# on purpose so a test can name a fake script, or `env X=1 fake`.
_psql() {
  # shellcheck disable=SC2086
  ${BRANCHDB_PSQL_CMD:-psql} -X -q -A -t -F $'\t' -v ON_ERROR_STOP=1 \
    ${CONN_ARGS[@]+"${CONN_ARGS[@]}"} -d "$(_maint_db)" -c "$1"
}
_dropdb() {
  # shellcheck disable=SC2086
  ${BRANCHDB_DROPDB_CMD:-dropdb} ${CONN_ARGS[@]+"${CONN_ARGS[@]}"} \
    --maintenance-db="$(_maint_db)" "$1"
}
_tbd_list_json() {
  if [[ -n "${BRANCHDB_TBD_LIST_CMD:-}" ]]; then eval "$BRANCHDB_TBD_LIST_CMD"
  else command -v tbd >/dev/null 2>&1 || return 127; tbd worktree list --json; fi
}
_avail_kb() {
  if [[ -n "${BRANCHDB_DF_CMD:-}" ]]; then eval "$BRANCHDB_DF_CMD"
  else
    local p="${PGDATA:-/}"; [[ -d "$p" ]] || p=/
    df -k "$p" 2>/dev/null
  fi | awk 'NR==2 {print $4}' || true
}

# --- pure helpers ------------------------------------------------------------

# label_for PATH -> the worktree label (see header). bash 3.2-safe: no ${x,,}.
label_for() {
  local p="${1%/}" b
  b="${p##*/}"
  b="$(printf '%s' "$b" | LC_ALL=C tr 'A-Z-' 'a-z_' | LC_ALL=C tr -cd 'a-z0-9_')"
  printf '%s\n' "${b:0:$LABEL_MAX}"
}

valid_prefix() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }

is_protected_db() {
  case "$1" in postgres|template0|template1) return 0 ;; esac
  [[ "$1" == "$(_maint_db)" ]]
}

# labels_match LIVE X -> 0 when the database suffix X must be KEPT for a live
# worktree with label LIVE. Both prefix directions count: X shorter than LIVE
# is a further-truncated name (Postgres caps identifiers at 63 bytes); X longer
# than LIVE is a name made under a longer cut than ours. Either way, KEEP.
labels_match() {
  local live="$1" x="$2"
  [[ "$live" == "$x" ]] && return 0
  [[ "$live" == "$x"* ]] && return 0
  [[ "$x" == "$live"* ]] && return 0
  return 1
}

# canon_path PATH -> physical path, or PATH verbatim if it no longer exists.
canon_path() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "${1%/}"; }

human_bytes() {
  local b="${1:-}"
  [[ "$b" =~ ^[0-9]+$ ]] || { printf '?\n'; return; }
  awk -v b="$b" 'BEGIN { if (b >= 1073741824) printf "%.1f GiB\n", b/1073741824;
                         else printf "%.1f MiB\n", b/1048576 }'
}

# --- scan --------------------------------------------------------------------

# collect_live_paths ROOT_GLOB... -> newline-separated worktree paths on stdout.
# Returns 2 if any glob matched no directory (a typo'd root would make its
# worktrees' databases look orphaned), 1 if there were no roots at all (no
# --root and no TBD listing), else 0.
collect_live_paths() {
  local g p n any_root=false ok=0 json tbd_paths
  for g in "$@"; do
    any_root=true; n=0
    while IFS= read -r p; do
      [[ -n "$p" && -d "$p" ]] || continue
      printf '%s\n' "${p%/}"; n=$((n + 1))
    done < <(compgen -G "$g" || true)
    if (( n == 0 )); then log "REFUSE: --root '$g' matched no directory"; ok=2; fi
  done
  if json="$(_tbd_list_json 2>/dev/null)" && command -v jq >/dev/null 2>&1 \
     && tbd_paths="$(printf '%s' "$json" | jq -r '.[] | select(.status != "archived") | .path' 2>/dev/null)"; then
    any_root=true
    [[ -n "$tbd_paths" ]] && printf '%s\n' "$tbd_paths"
  else
    log "warning: TBD worktree listing unavailable (tbd or jq missing, or the call failed)"
  fi
  if [[ "$any_root" != "true" ]]; then
    log "no roots: pass --root, or make \`tbd worktree list --json\` available"
    (( ok == 0 )) && ok=1
  fi
  return "$ok"
}

# postgres_ready -> 0 only when connected AND not in recovery.
postgres_ready() {
  local out
  if ! out="$(_psql "SELECT pg_is_in_recovery()" 2>&1)"; then
    log "SKIP: cannot connect to Postgres (a server starting up or in crash recovery refuses connections too): ${out//$'\n'/ }"
    return 1
  fi
  if [[ "$out" != "f" ]]; then
    log "SKIP: Postgres is in recovery (pg_is_in_recovery=$out)"
    return 1
  fi
  return 0
}

# list_prefixed_dbs PREFIX -> "name<TAB>bytes" for every database starting with
# PREFIX. Filtered in bash, not with LIKE, because '_' is a LIKE wildcard.
list_prefixed_dbs() {
  local prefix="$1" rows name size
  rows="$(_psql "SELECT datname, CASE WHEN has_database_privilege(datname, 'CONNECT') THEN pg_database_size(oid) END FROM pg_database WHERE NOT datistemplate ORDER BY datname")" || return 1
  while IFS=$'\t' read -r name size; do
    [[ -n "$name" && "$name" == "$prefix"* ]] || continue
    is_protected_db "$name" && continue
    printf '%s\t%s\n' "$name" "$size"
  done <<< "$rows"
}

# connection_count DB -> count on stdout; non-zero exit if the query failed.
connection_count() {
  local q="${1//\'/\'\'}"
  _psql "SELECT count(*) FROM pg_stat_activity WHERE datname = '$q'"
}

# try_drop DB -> re-checks connections immediately before dropping. Plain
# DROP DATABASE (no FORCE) also refuses a database someone joined since.
try_drop() {
  local db="$1" n
  if ! n="$(connection_count "$db")" || [[ ! "$n" =~ ^[0-9]+$ ]]; then
    echo "KEEP unknown-connections $db"; return 2
  fi
  if (( n > 0 )); then echo "KEEP busy $db ($n connections)"; return 2; fi
  if _dropdb "$db"; then echo "DROPPED $db"; return 0; fi
  log "dropdb failed: $db"; return 1
}

usage() { sed -n '2,/^LABEL_MAX=/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//' >&2; }

main() {
  local prefix="" apply=false target="" roots=()
  CONN_ARGS=()
  while (( $# )); do
    case "$1" in
      --prefix)   prefix="${2:-}"; shift 2 || { usage; return 2; } ;;
      --root)     [[ -n "${2:-}" ]] || { usage; return 2; }; roots+=("$2"); shift 2 ;;
      --worktree) target="${2:-}"; shift 2 || { usage; return 2; } ;;
      --apply)    apply=true; shift ;;
      --dry-run)  apply=false; shift ;;
      --host)     [[ -n "${2:-}" ]] || { usage; return 2; }; CONN_ARGS+=(-h "$2"); shift 2 ;;
      --port)     [[ -n "${2:-}" ]] || { usage; return 2; }; CONN_ARGS+=(-p "$2"); shift 2 ;;
      -h|--help)  usage; return 0 ;;
      *)          log "unknown argument: $1"; usage; return 2 ;;
    esac
  done
  if [[ -z "$prefix" ]]; then log "--prefix is required"; return 2; fi
  if ! valid_prefix "$prefix"; then log "REFUSE: --prefix must match [A-Za-z0-9_]+"; return 2; fi

  local live; live="$(collect_live_paths ${roots[@]+"${roots[@]}"})"
  local scan_status=$?

  if [[ -n "$target" ]]; then
    # Single-target mode names its database explicitly, so having no roots is
    # only a warning; a --root that matched nothing still refuses.
    if (( scan_status == 2 )); then log "REFUSE: incomplete scan; dropping nothing"; return 1; fi
    single_target "$prefix" "$target" "$apply" "$live"
    return $?
  fi

  if (( scan_status != 0 )); then log "REFUSE: incomplete scan; dropping nothing"; return 1; fi
  if [[ -z "$live" ]]; then
    log "REFUSE: the scan found zero worktree paths; an empty scan is never read as 'everything is an orphan'"
    return 1
  fi

  postgres_ready || return 0

  local labels; labels="$(while IFS= read -r p; do label_for "$p"; done <<< "$live" | sort -u)"
  if grep -qx '' <<< "$labels"; then
    log "warning: a worktree basename yields an empty label; it matches, and so keeps, every database"
  fi
  local dbs; if ! dbs="$(list_prefixed_dbs "$prefix")"; then log "SKIP: listing databases failed"; return 0; fi

  local avail_before=""; [[ "$apply" == "true" ]] && avail_before="$(_avail_kb)"
  local name size x l matched orphans=() orphan_bytes=0 n_keep=0
  while IFS=$'\t' read -r name size; do
    [[ -n "$name" ]] || continue
    x="${name#"$prefix"}"
    if [[ -z "$x" || ! "$x" =~ ^[a-z0-9_]+$ ]]; then
      echo "KEEP foreign $name"; n_keep=$((n_keep + 1)); continue
    fi
    # A flag, not the label itself: an empty live label is a match too.
    matched=false
    while IFS= read -r l; do
      if labels_match "$l" "$x"; then matched=true; break; fi
    done <<< "$labels"
    if [[ "$matched" == "true" ]]; then
      echo "KEEP live $name $(human_bytes "$size") (label '$l')"; n_keep=$((n_keep + 1)); continue
    fi
    echo "ORPHAN $name $(human_bytes "$size")"
    orphans+=("$name")
    [[ "$size" =~ ^[0-9]+$ ]] && orphan_bytes=$((orphan_bytes + size))
  done <<< "$dbs"
  echo "TOTAL kept=$n_keep orphans=${#orphans[@]} orphan_size=$(human_bytes "$orphan_bytes")"

  if [[ "$apply" != "true" ]]; then
    (( ${#orphans[@]} )) && log "dry-run: nothing dropped; re-run with --apply to drop the ORPHAN rows"
    return 0
  fi

  local rc=0 db
  for db in ${orphans[@]+"${orphans[@]}"}; do
    try_drop "$db"; [[ $? -eq 1 ]] && rc=1
  done
  report_df "$avail_before"
  return "$rc"
}

# single_target PREFIX PATH APPLY LIVE_PATHS — the archive-hook mode.
single_target() {
  local prefix="$1" target="$2" apply="$3" live="$4"
  local label; label="$(label_for "$target")"
  if [[ -z "$label" ]]; then log "REFUSE: '$target' yields an empty label"; return 1; fi
  local db="$prefix$label" x="$label"
  if is_protected_db "$db"; then log "REFUSE: $db is protected"; return 1; fi

  # Another live worktree whose label matches this one (same basename under a
  # different root, or a prefix-related name) shares the database: keep it.
  local canon_t p; canon_t="$(canon_path "$target")"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    [[ "$(canon_path "$p")" == "$canon_t" ]] && continue
    if labels_match "$(label_for "$p")" "$x"; then
      echo "KEEP shared $db (also matches $p)"; return 0
    fi
  done <<< "$live"

  postgres_ready || return 0
  local dbs; if ! dbs="$(list_prefixed_dbs "$prefix")"; then log "SKIP: listing databases failed"; return 0; fi
  local size
  size="$(awk -F'\t' -v d="$db" '$1 == d { print $2; found=1 } END { exit !found }' <<< "$dbs")" || {
    echo "ABSENT $db"; return 0; }
  echo "ORPHAN $db $(human_bytes "$size")"
  if [[ "$apply" != "true" ]]; then log "dry-run: nothing dropped; re-run with --apply"; return 0; fi
  local avail_before; avail_before="$(_avail_kb)"
  try_drop "$db"; local rc=$?
  report_df "$avail_before"
  [[ $rc -eq 1 ]] && return 1
  return 0
}

report_df() {
  local before="$1" after; after="$(_avail_kb)"
  if [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]]; then
    log "df delta: $(( (after - before) / 1024 )) MiB freed"
  fi
}

# --- entrypoint (strict mode only when executed, not when sourced) -----------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  main "$@"
fi
