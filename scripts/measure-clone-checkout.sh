#!/usr/bin/env bash
# Measure the real disk and time cost of a worktree created by plain
# `git worktree add` against one created by the clone-backed checkout
# (docs/specs/2026-10-09-clone-backed-worktree-checkout-design.md).
#
# Usage: scripts/measure-clone-checkout.sh <repo> [count] [template-lag]
#
#   repo          a git repository on an APFS volume (it is not modified: all
#                 worktrees and branches this creates are removed on exit)
#   count         worktrees to create per method (default 5)
#   template-lag  how many commits behind the base the template sits
#                 (default 0; a fleet's template trails main by a few commits)
#
# The clone-backed side replays the daemon's steps, including one clonefile(2)
# per top-level template entry (CheckoutTemplateStore.cloneTree), against a
# template written the way CheckoutTemplateStore writes one. Not `cp -c -R`: it
# walks the tree and clones file by file, which on a 22,362-file checkout took
# 35.7 s against 2.2 s for the per-entry syscalls, so it misstates the time.
# Real bytes are the volume's free-space delta (`df -k`) across each batch,
# so run it on an otherwise quiet machine; the batch size keeps the noise small
# next to the signal.
set -euo pipefail

repo=$(cd "${1:?usage: $0 <repo> [count] [template-lag]}" && pwd)
count=${2:-5}
lag=${3:-0}
# Set only to dry-run the script where clonefile(2) does not exist, e.g.
# CLONE_CP='cp -a' on Linux (plain copies there, so the byte figures mean
# nothing).
clone_cp=${CLONE_CP:-}

# clone_entries <template-tree> <worktree>: what CheckoutTemplateStore.cloneTree
# does, one clonefile(2) with CLONE_NOFOLLOW per top-level entry except `.git`.
clone_entries() {
    if [ -n "$clone_cp" ]; then
        for entry in "$1"/* "$1"/.[!.]*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            $clone_cp "$entry" "$2/"
        done
        return
    fi
    /usr/bin/python3 -I - "$1" "$2" <<'PY'
import ctypes, os, sys
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
CLONE_NOFOLLOW = 0x0001
src, dst = sys.argv[1], sys.argv[2]
for name in sorted(os.listdir(src)):
    if name == ".git":
        continue
    if libc.clonefile(os.fsencode(os.path.join(src, name)), os.fsencode(os.path.join(dst, name)), CLONE_NOFOLLOW) != 0:
        sys.exit(f"clonefile {name}: {os.strerror(ctypes.get_errno())}")
PY
}

work=$(mktemp -d "$(dirname "$repo")/.clone-checkout-measure.XXXXXX")
branches=()
cleanup() {
    for b in "${branches[@]+"${branches[@]}"}"; do
        git -C "$repo" worktree remove --force "$work/$b" >/dev/null 2>&1 || true
        git -C "$repo" branch -D "measure/$b" >/dev/null 2>&1 || true
    done
    rm -rf "$work"
    git -C "$repo" worktree prune
}
trap cleanup EXIT

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
free_kb() { df -k "$work" | awk 'NR==2 {print $4}'; }
sync_disk() { sync; sleep 2; }

base=$(git -C "$repo" rev-parse HEAD)
template_commit=$(git -C "$repo" rev-parse "HEAD~$lag")
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
tracked=$(git -C "$repo" ls-tree -r --name-only HEAD | wc -l | tr -d ' ')
echo "repo: $tracked tracked files; base $base; template $template_commit ($lag commits behind)"

# Template (the one-time cost per repo).
sync_disk; before=$(free_kb); t0=$(now)
mkdir -p "$work/template/tree"
GIT_INDEX_FILE="$work/template/index" git --git-dir="$common" --work-tree="$work/template/tree" \
    -c core.bare=false read-tree --reset -u "$template_commit"
t1=$(now); sync_disk; after=$(free_kb)
echo "template: $(( (before - after) / 1024 )) MB, $(echo "$t1 - $t0" | bc) s"

measure() {
    local method=$1 name total_s=0 t0 t1 before after
    sync_disk; before=$(free_kb)
    for i in $(seq 1 "$count"); do
        name="$method-$i"; branches+=("$name"); t0=$(now)
        if [ "$method" = plain ]; then
            git -C "$repo" -c checkout.workers=0 worktree add -q --no-track "$work/$name" -b "measure/$name" "$base"
        else
            git -C "$repo" worktree add -q --no-checkout --no-track "$work/$name" -b "measure/$name" "$base"
            clone_entries "$work/template/tree" "$work/$name"
            git -C "$work/$name" read-tree "$template_commit"
            git -C "$work/$name" update-index -q --refresh || true
            git -C "$work/$name" -c checkout.workers=0 reset -q --hard
            [ -z "$(git -C "$work/$name" status --porcelain)" ] || { echo "$name: status not clean" >&2; exit 1; }
            git -C "$work/$name" hook run --ignore-missing post-checkout -- \
                0000000000000000000000000000000000000000 "$base" 1
        fi
        t1=$(now); total_s=$(echo "$total_s + $t1 - $t0" | bc)
    done
    sync_disk; after=$(free_kb)
    echo "$method: $(( (before - after) / 1024 / count )) MB per worktree, $(echo "scale=2; $total_s / $count" | bc) s per worktree ($count worktrees)"
}

measure plain
measure clone
