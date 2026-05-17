#!/usr/bin/env bash
# Migrate Conductor worktrees into TBD by reading Conductor's SQLite DB and
# calling `tbd repo add` + `tbd worktree adopt` for each one.
#
# Adopts in place — no files are moved, Conductor keeps working alongside.
# Idempotent: re-running picks up only new workspaces.

set -euo pipefail

CONDUCTOR_DB="$HOME/Library/Application Support/com.conductor.app/conductor.db"
TBD_BIN="${TBD_BIN:-tbd}"

# ---- Args ----
INCLUDE_ARCHIVED=0
DRY_RUN=0
REPO_FILTER=""

usage() {
    cat <<EOF
Usage: $0 [--all] [--repo <name>] [--dry-run]

Adopts active Conductor worktrees into TBD in place. Reads
~/Library/Application Support/com.conductor.app/conductor.db
(read-only — copied to a temp file before reading).

Options:
  --all          Also adopt archived Conductor workspaces.
  --repo <name>  Limit to one Conductor repo (matched by Conductor repo name).
  --dry-run      Print the plan; don't run any tbd commands.
  -h, --help     Show this message.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all) INCLUDE_ARCHIVED=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --repo) REPO_FILTER="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ---- Preconditions ----
if [[ ! -f "$CONDUCTOR_DB" ]]; then
    echo "No Conductor data found at $CONDUCTOR_DB — nothing to migrate." >&2
    exit 0
fi
if ! command -v "$TBD_BIN" >/dev/null 2>&1; then
    echo "Error: tbd CLI not found on PATH (set TBD_BIN to override)." >&2
    exit 2
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "Error: sqlite3 not found on PATH (ships with macOS — odd)." >&2
    exit 2
fi

# Copy DB to tmp to avoid WAL contention with a running Conductor.
TMP_DB="$(mktemp -t conductor-import.XXXXXX.db)"
trap 'rm -f "$TMP_DB" "${TMP_DB}-wal" "${TMP_DB}-shm"' EXIT
cp "$CONDUCTOR_DB" "$TMP_DB"
[[ -f "${CONDUCTOR_DB}-wal" ]] && cp "${CONDUCTOR_DB}-wal" "${TMP_DB}-wal"
[[ -f "${CONDUCTOR_DB}-shm" ]] && cp "${CONDUCTOR_DB}-shm" "${TMP_DB}-shm"

# ---- State filter ----
if [[ $INCLUDE_ARCHIVED -eq 1 ]]; then
    STATE_CLAUSE="w.state IN ('ready','archived')"
else
    STATE_CLAUSE="w.state = 'ready'"
fi

# ASCII unit separator for safe path delimiting.
US=$'\x1f'

# ---- Query Conductor: repos ----
REPOS_RAW="$(sqlite3 -separator "$US" "$TMP_DB" \
    "SELECT id, name, IFNULL(root_path,''), IFNULL(default_branch,'main') FROM repos;")"

# ---- Query Conductor: workspaces matching filter ----
WORKSPACE_SQL="SELECT w.id, w.repository_id, IFNULL(w.directory_name,''), IFNULL(w.branch,''), w.state, IFNULL(w.workspace_path,'')
FROM workspaces w
WHERE $STATE_CLAUSE
  AND w.workspace_path IS NOT NULL
  AND w.workspace_path <> '';"

WORKSPACES_RAW="$(sqlite3 -separator "$US" "$TMP_DB" "$WORKSPACE_SQL")"

if [[ -z "$WORKSPACES_RAW" ]]; then
    echo "No Conductor workspaces match the filter — nothing to migrate."
    exit 0
fi

# ---- Resolve TBD's currently-registered repos (by root_path) ----
TBD_REPOS_JSON="$("$TBD_BIN" repo list --json 2>/dev/null || echo '[]')"

TBD_REPO_PATHS=()
while IFS= read -r tpath; do
    [[ -z "$tpath" ]] && continue
    TBD_REPO_PATHS+=("$tpath")
done < <(printf '%s' "$TBD_REPOS_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data:
    print(r.get("path",""))
' 2>/dev/null || true)

tbd_has_repo_path() {
    local needle="$1"
    local p
    for p in "${TBD_REPO_PATHS[@]+"${TBD_REPO_PATHS[@]}"}"; do
        [[ "$p" == "$needle" ]] && return 0
    done
    return 1
}

# ---- Build the plan ----

# Parallel arrays for Conductor repos and their planned action.
COND_REPO_IDS=()
COND_REPO_NAMES=()
COND_REPO_PATHS=()
COND_REPO_ACTIONS=()   # "add", "reuse", or "skip:<reason>"

while IFS="$US" read -r cid cname croot cdef; do
    [[ -z "$cid" ]] && continue
    if [[ -n "$REPO_FILTER" && "$cname" != "$REPO_FILTER" ]]; then
        continue
    fi
    COND_REPO_IDS+=("$cid")
    COND_REPO_NAMES+=("$cname")
    COND_REPO_PATHS+=("$croot")

    if [[ -z "$croot" || ! -d "$croot" ]]; then
        COND_REPO_ACTIONS+=("skip:repo path missing")
    elif tbd_has_repo_path "$croot"; then
        COND_REPO_ACTIONS+=("reuse")
    else
        COND_REPO_ACTIONS+=("add")
    fi
done <<< "$REPOS_RAW"

# Parallel arrays for workspaces.
WS_NAMES=()
WS_BRANCHES=()
WS_PATHS=()
WS_REPO_NAMES=()
WS_REPO_PATHS=()
WS_ACTIONS=()

lookup_conductor_repo_index() {
    local needle="$1"
    local i
    for ((i=0; i<${#COND_REPO_IDS[@]}; i++)); do
        if [[ "${COND_REPO_IDS[$i]}" == "$needle" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

while IFS="$US" read -r wid wrepo wdir wbranch wstate wpath; do
    [[ -z "$wid" ]] && continue
    repo_idx="$(lookup_conductor_repo_index "$wrepo" || true)"
    if [[ -z "$repo_idx" ]]; then
        continue
    fi
    repo_action="${COND_REPO_ACTIONS[$repo_idx]}"
    repo_name="${COND_REPO_NAMES[$repo_idx]}"
    repo_path="${COND_REPO_PATHS[$repo_idx]}"
    WS_NAMES+=("$wdir")
    WS_BRANCHES+=("$wbranch")
    WS_PATHS+=("$wpath")
    WS_REPO_NAMES+=("$repo_name")
    WS_REPO_PATHS+=("$repo_path")

    if [[ "$repo_action" == skip:* ]]; then
        WS_ACTIONS+=("skip:parent repo skipped")
    elif [[ ! -d "$wpath" ]]; then
        WS_ACTIONS+=("skip:path missing")
    elif ! git -C "$wpath" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        WS_ACTIONS+=("skip:not a git worktree")
    else
        WS_ACTIONS+=("adopt")
    fi
done <<< "$WORKSPACES_RAW"

# ---- Print the plan ----
echo "Conductor → TBD migration plan"
echo "──────────────────────────────"
echo
echo "Repos:"
if [[ ${#COND_REPO_IDS[@]} -eq 0 ]]; then
    echo "  (none referenced by selected workspaces)"
else
    for ((i=0; i<${#COND_REPO_IDS[@]}; i++)); do
        case "${COND_REPO_ACTIONS[$i]}" in
            add)   echo "  + ${COND_REPO_NAMES[$i]}    ${COND_REPO_PATHS[$i]}    (will add)" ;;
            reuse) echo "  ~ ${COND_REPO_NAMES[$i]}    ${COND_REPO_PATHS[$i]}    (already in TBD, reusing)" ;;
            skip:*) echo "  - ${COND_REPO_NAMES[$i]}    ${COND_REPO_PATHS[$i]}    (${COND_REPO_ACTIONS[$i]#skip:})" ;;
        esac
    done
fi
echo
echo "Workspaces:"
if [[ ${#WS_NAMES[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for ((i=0; i<${#WS_NAMES[@]}; i++)); do
        case "${WS_ACTIONS[$i]}" in
            adopt)  echo "  + ${WS_NAMES[$i]}    ${WS_BRANCHES[$i]} →  ${WS_REPO_NAMES[$i]}" ;;
            skip:*) echo "  - ${WS_NAMES[$i]}    (${WS_ACTIONS[$i]#skip:})" ;;
        esac
    done
fi
echo

# Tally
n_repo_add=0; n_repo_reuse=0; n_repo_skip=0
for a in "${COND_REPO_ACTIONS[@]+"${COND_REPO_ACTIONS[@]}"}"; do
    case "$a" in
        add) n_repo_add=$((n_repo_add+1)) ;;
        reuse) n_repo_reuse=$((n_repo_reuse+1)) ;;
        skip:*) n_repo_skip=$((n_repo_skip+1)) ;;
    esac
done
n_ws_adopt=0; n_ws_skip=0
for a in "${WS_ACTIONS[@]+"${WS_ACTIONS[@]}"}"; do
    case "$a" in
        adopt) n_ws_adopt=$((n_ws_adopt+1)) ;;
        skip:*) n_ws_skip=$((n_ws_skip+1)) ;;
    esac
done
echo "Summary: $n_repo_add repo(s) to add, $n_repo_reuse to reuse, $n_repo_skip skipped · $n_ws_adopt workspace(s) to adopt, $n_ws_skip skipped"

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "Dry-run — exiting before writes."
    exit 0
fi

# ---- Execute ----
echo
total_steps=$((n_repo_add + n_ws_adopt))
step=0
n_failed=0

# Phase A: add repos.
for ((i=0; i<${#COND_REPO_IDS[@]}; i++)); do
    [[ "${COND_REPO_ACTIONS[$i]}" == "add" ]] || continue
    step=$((step+1))
    printf "[%d/%d] adding repo %s… " "$step" "$total_steps" "${COND_REPO_NAMES[$i]}"
    if "$TBD_BIN" repo add "${COND_REPO_PATHS[$i]}" >/dev/null 2>&1; then
        echo "ok"
    else
        echo "FAILED"
        COND_REPO_ACTIONS[$i]="skip:repo add failed"
        n_failed=$((n_failed+1))
    fi
done

# Phase B: adopt workspaces.
for ((i=0; i<${#WS_NAMES[@]}; i++)); do
    [[ "${WS_ACTIONS[$i]}" == "adopt" ]] || continue
    parent_idx=""
    for ((j=0; j<${#COND_REPO_NAMES[@]}; j++)); do
        if [[ "${COND_REPO_NAMES[$j]}" == "${WS_REPO_NAMES[$i]}" ]]; then
            parent_idx="$j"
            break
        fi
    done
    if [[ -n "$parent_idx" && "${COND_REPO_ACTIONS[$parent_idx]}" == skip:* ]]; then
        echo "       skipping ${WS_NAMES[$i]} (parent repo unavailable)"
        n_failed=$((n_failed+1))
        continue
    fi
    step=$((step+1))
    printf "[%d/%d] adopting %s… " "$step" "$total_steps" "${WS_NAMES[$i]}"
    # Pass the repo's root_path to --repo; the adopt subcommand resolves it via PathResolver.
    if "$TBD_BIN" worktree adopt "${WS_PATHS[$i]}" --repo "${WS_REPO_PATHS[$i]}" >/dev/null 2>&1; then
        echo "ok"
    else
        echo "FAILED"
        n_failed=$((n_failed+1))
    fi
done

# ---- Summary ----
echo
echo "Done: $n_repo_add repo(s) added · $n_ws_adopt worktree(s) adopted · $((n_repo_skip + n_ws_skip)) skipped · $n_failed failed"
if [[ $n_failed -gt 0 ]]; then
    exit 1
fi
exit 0
