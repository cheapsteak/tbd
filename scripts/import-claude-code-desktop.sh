#!/usr/bin/env bash
# Migrate Claude Code Desktop worktrees into TBD by reading the parent repo's
# `git worktree list --porcelain` and calling `tbd repo add` + `tbd worktree adopt`
# for each entry under `<repo>/.claude/worktrees/`.
#
# Adopts in place — no files are moved, Claude Code Desktop keeps working alongside.
# Idempotent: re-running picks up only new worktrees.

set -euo pipefail

TBD_BIN="${TBD_BIN:-tbd}"

# ---- Args ----
DRY_RUN=0
INCLUDE_AGENTS=0
REPO_INPUTS=()

usage() {
    cat <<EOF
Usage: $0 --repo <path> [--repo <path>...] [--include-agents] [--dry-run]

Adopts Claude Code Desktop worktrees into TBD in place. For each --repo,
resolves the main repo root via \`git rev-parse --git-common-dir\`, then
scans \`git worktree list\` for entries under <repo>/.claude/worktrees/.

The path passed to --repo may be the repo's main checkout, any of its
worktrees, or any subdirectory within them — all are normalized to the
same main repo root.

By default, directories whose name starts with \`agent-\` are skipped — those
are scratch worktrees created by agent runs, not user-managed sessions. Pass
\`--include-agents\` to include them.

Options:
  --repo <path>      Path inside the repo to import worktrees for. Repeatable.
  --include-agents   Also adopt directories named \`agent-*\` (skipped by default).
  --dry-run          Print the plan; don't run any tbd commands.
  -h, --help         Show this message.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --include-agents) INCLUDE_AGENTS=1; shift ;;
        --repo)
            if [[ $# -lt 2 ]]; then
                echo "Error: --repo requires a path." >&2
                usage >&2
                exit 2
            fi
            REPO_INPUTS+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ ${#REPO_INPUTS[@]} -eq 0 ]]; then
    echo "Error: at least one --repo <path> is required." >&2
    usage >&2
    exit 2
fi

# ---- Preconditions ----
if ! command -v "$TBD_BIN" >/dev/null 2>&1; then
    echo "Error: tbd CLI not found on PATH (set TBD_BIN to override)." >&2
    exit 2
fi
if ! command -v git >/dev/null 2>&1; then
    echo "Error: git not found on PATH." >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    # Used to parse `tbd repo list --json`. Without python3 we silently treat
    # every repo as not-yet-registered, which is functionally safe (`tbd repo add`
    # on an already-registered repo is a no-op) but makes the plan lie about
    # which repos will be reused.
    echo "Error: python3 not found on PATH (ships with macOS Xcode Command Line Tools)." >&2
    exit 2
fi

# ---- Resolve repo roots ----

# realpath that works on macOS (no coreutils dependency).
canonicalize() {
    local p="$1"
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$p"
}

# Returns the main repo root for any path inside a repo, or "" if not in a repo.
resolve_repo_root() {
    local p="$1"
    local git_common
    if ! git_common="$(git -C "$p" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
        echo ""
        return 0
    fi
    # git-common-dir is typically <root>/.git for the main checkout, or
    # <root>/.git for a linked worktree (worktrees share the parent's git dir).
    # Strip trailing /.git or /.git/ to get the repo root.
    local parent
    parent="$(dirname "$git_common")"
    canonicalize "$parent"
}

# Parallel arrays of unique resolved roots, keyed by display name (basename).
declare -a REPO_ROOTS=()
declare -a REPO_NAMES=()
declare -a REPO_ACTIONS=()  # "add" | "reuse" | "skip:<reason>"

add_root_unique() {
    local root="$1"
    local existing
    for existing in "${REPO_ROOTS[@]+"${REPO_ROOTS[@]}"}"; do
        if [[ "$existing" == "$root" ]]; then
            return 1
        fi
    done
    REPO_ROOTS+=("$root")
    REPO_NAMES+=("$(basename "$root")")
    REPO_ACTIONS+=("")
    return 0
}

declare -a INPUT_SKIPS=()
for input in "${REPO_INPUTS[@]}"; do
    if [[ ! -e "$input" ]]; then
        INPUT_SKIPS+=("$input    (skip: path does not exist)")
        continue
    fi
    root="$(resolve_repo_root "$input")"
    if [[ -z "$root" ]]; then
        INPUT_SKIPS+=("$input    (skip: not inside a git repo)")
        continue
    fi
    if ! add_root_unique "$root"; then
        INPUT_SKIPS+=("$input    (skip: duplicate of $root)")
    fi
done

# ---- Resolve TBD's currently-registered repos (by path) ----
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

for ((i=0; i<${#REPO_ROOTS[@]}; i++)); do
    if tbd_has_repo_path "${REPO_ROOTS[$i]}"; then
        REPO_ACTIONS[$i]="reuse"
    else
        REPO_ACTIONS[$i]="add"
    fi
done

# ---- Enumerate worktrees under <root>/.claude/worktrees/ ----

# Parallel arrays for worktrees.
WT_PATHS=()
WT_BRANCHES=()
WT_NAMES=()
WT_REPO_INDEXES=()
WT_ACTIONS=()  # "adopt" | "skip:<reason>"

for ((i=0; i<${#REPO_ROOTS[@]}; i++)); do
    root="${REPO_ROOTS[$i]}"
    prefix="$root/.claude/worktrees/"
    found_for_repo=0

    # Parse `git worktree list --porcelain`. Each entry is a block of lines
    # starting with `worktree <path>`, then `HEAD <sha>`, then either
    # `branch refs/heads/<name>` or `detached`. Blocks are separated by blank lines.
    cur_path=""
    cur_branch=""
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            if [[ -n "$cur_path" && "$cur_path" == "$prefix"* ]]; then
                wt_name="$(basename "$cur_path")"
                WT_PATHS+=("$cur_path")
                WT_BRANCHES+=("$cur_branch")
                WT_NAMES+=("$wt_name")
                WT_REPO_INDEXES+=("$i")
                if [[ ! -d "$cur_path" ]]; then
                    WT_ACTIONS+=("skip:path missing")
                elif [[ "$wt_name" == agent-* && $INCLUDE_AGENTS -eq 0 ]]; then
                    WT_ACTIONS+=("skip:agent worktree (--include-agents to adopt)")
                else
                    WT_ACTIONS+=("adopt")
                fi
                found_for_repo=$((found_for_repo+1))
            fi
            cur_path=""
            cur_branch=""
            continue
        fi
        case "$line" in
            worktree\ *) cur_path="${line#worktree }" ;;
            branch\ refs/heads/*) cur_branch="${line#branch refs/heads/}" ;;
        esac
    done < <(git -C "$root" worktree list --porcelain; echo)
    # Trailing blank line above ensures the final block flushes through the loop.

    if [[ $found_for_repo -eq 0 ]]; then
        INPUT_SKIPS+=("${REPO_NAMES[$i]}    (no Claude Code Desktop worktrees in $root)")
    fi
done

# ---- Print the plan ----
echo "Claude Code Desktop → TBD migration plan"
echo "────────────────────────────────────────"
echo
echo "Repos:"
if [[ ${#REPO_ROOTS[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for ((i=0; i<${#REPO_ROOTS[@]}; i++)); do
        case "${REPO_ACTIONS[$i]}" in
            add)   echo "  + ${REPO_NAMES[$i]}    ${REPO_ROOTS[$i]}    (will add)" ;;
            reuse) echo "  ~ ${REPO_NAMES[$i]}    ${REPO_ROOTS[$i]}    (already in TBD, reusing)" ;;
        esac
    done
fi

if [[ ${#INPUT_SKIPS[@]} -gt 0 ]]; then
    echo
    echo "Notes:"
    for note in "${INPUT_SKIPS[@]}"; do
        echo "  - $note"
    done
fi

echo
echo "Worktrees:"
if [[ ${#WT_PATHS[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for ((i=0; i<${#WT_PATHS[@]}; i++)); do
        repo_idx="${WT_REPO_INDEXES[$i]}"
        repo_name="${REPO_NAMES[$repo_idx]}"
        branch_disp="${WT_BRANCHES[$i]:-(detached)}"
        case "${WT_ACTIONS[$i]}" in
            adopt)  echo "  + ${WT_NAMES[$i]}    ${branch_disp} →  ${repo_name}" ;;
            skip:*) echo "  - ${WT_NAMES[$i]}    (${WT_ACTIONS[$i]#skip:})" ;;
        esac
    done
fi
echo

# Tally
n_repo_add=0; n_repo_reuse=0
for a in "${REPO_ACTIONS[@]+"${REPO_ACTIONS[@]}"}"; do
    case "$a" in
        add) n_repo_add=$((n_repo_add+1)) ;;
        reuse) n_repo_reuse=$((n_repo_reuse+1)) ;;
    esac
done
n_wt_adopt=0; n_wt_skip=0
for a in "${WT_ACTIONS[@]+"${WT_ACTIONS[@]}"}"; do
    case "$a" in
        adopt) n_wt_adopt=$((n_wt_adopt+1)) ;;
        skip:*) n_wt_skip=$((n_wt_skip+1)) ;;
    esac
done
echo "Summary: $n_repo_add repo(s) to add, $n_repo_reuse to reuse · $n_wt_adopt worktree(s) to adopt, $n_wt_skip skipped"

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "Dry-run — exiting before writes."
    exit 0
fi

if [[ $n_repo_add -eq 0 && $n_wt_adopt -eq 0 ]]; then
    echo
    echo "Nothing to do."
    exit 0
fi

# ---- Execute ----
echo
total_steps=$((n_repo_add + n_wt_adopt))
step=0
n_failed=0
n_repo_actually_added=0
n_wt_actually_adopted=0

# Phase A: add repos.
for ((i=0; i<${#REPO_ROOTS[@]}; i++)); do
    [[ "${REPO_ACTIONS[$i]}" == "add" ]] || continue
    step=$((step+1))
    printf "[%d/%d] adding repo %s… " "$step" "$total_steps" "${REPO_NAMES[$i]}"
    if "$TBD_BIN" repo add "${REPO_ROOTS[$i]}" >/dev/null 2>&1; then
        echo "ok"
        n_repo_actually_added=$((n_repo_actually_added+1))
    else
        echo "FAILED"
        REPO_ACTIONS[$i]="skip:repo add failed"
        n_failed=$((n_failed+1))
    fi
done

# Phase B: adopt worktrees.
for ((i=0; i<${#WT_PATHS[@]}; i++)); do
    [[ "${WT_ACTIONS[$i]}" == "adopt" ]] || continue
    repo_idx="${WT_REPO_INDEXES[$i]}"
    if [[ "${REPO_ACTIONS[$repo_idx]}" == skip:* ]]; then
        step=$((step+1))
        echo "[$step/$total_steps] skipping ${WT_NAMES[$i]} (parent repo unavailable)"
        n_failed=$((n_failed+1))
        continue
    fi
    step=$((step+1))
    printf "[%d/%d] adopting %s… " "$step" "$total_steps" "${WT_NAMES[$i]}"
    if "$TBD_BIN" worktree adopt "${WT_PATHS[$i]}" --repo "${REPO_ROOTS[$repo_idx]}" >/dev/null 2>&1; then
        echo "ok"
        n_wt_actually_adopted=$((n_wt_actually_adopted+1))
    else
        echo "FAILED"
        n_failed=$((n_failed+1))
    fi
done

# ---- Summary ----
echo
echo "Done: $n_repo_actually_added repo(s) added · $n_wt_actually_adopted worktree(s) adopted · $n_wt_skip skipped · $n_failed failed"
if [[ $n_failed -gt 0 ]]; then
    exit 1
fi
exit 0
