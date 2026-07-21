#!/usr/bin/env bash
# WIP-guard helpers for restart.sh — pure functions, no side effects, safe to
# source. restart.sh sources this to decide whether a build is "blessed" (safe
# to install to /Applications + restart the shared daemon); scripts/restart-guard-lib.test.sh
# sources it to unit-test the helpers. All functions read the global REPO_ROOT.
#
# A blessed build must have:
#  (a) A clean working tree — NO tracked changes AND no new untracked files
#  (b) HEAD as an ancestor of main (upstream/main, origin/main, or main)

# Determine the main-branch ref to use for the ancestry check.
resolve_main_ref() {
    if git -C "$REPO_ROOT" rev-parse upstream/main >/dev/null 2>&1; then
        echo "upstream/main"
    elif git -C "$REPO_ROOT" rev-parse origin/main >/dev/null 2>&1; then
        echo "origin/main"
    elif git -C "$REPO_ROOT" rev-parse main >/dev/null 2>&1; then
        echo "main"
    else
        echo ""
    fi
}

# Check if the working tree is clean. Untracked files are INTENTIONALLY counted
# as dirty: SwiftPM globs Sources/ by filesystem contents, so a brand-new,
# not-yet-`git add`ed .swift file IS compiled into the build while being
# invisible to a tracked-only check — exactly the WIP state this guard exists to
# catch. Ignored paths (.build/, .DS_Store, …) never appear in --porcelain, so
# the default untracked mode adds no build-artifact noise.
is_working_tree_clean() {
    local output
    output=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || echo "error")
    if [ "$output" = "error" ]; then
        return 1  # not a git repo or error
    fi
    [ -z "$output" ]
}

# Check if HEAD is an ancestor of the given ref.
is_head_ancestor_of() {
    local ref="$1"
    if [ -z "$ref" ]; then
        return 1
    fi
    git -C "$REPO_ROOT" merge-base --is-ancestor HEAD "$ref" 2>/dev/null
}

# Determine if the build is blessed (clean tree + HEAD on/before main).
is_build_blessed() {
    if ! is_working_tree_clean; then
        return 1
    fi
    local main_ref
    main_ref=$(resolve_main_ref)
    if [ -z "$main_ref" ]; then
        return 1
    fi
    is_head_ancestor_of "$main_ref"
}

# Get the currently installed worktree path from /Applications/TBD.app.
get_installed_worktree_path() {
    if [ -f "/Applications/TBD.app/Contents/SourceWorktreePath.txt" ]; then
        cat "/Applications/TBD.app/Contents/SourceWorktreePath.txt"
    else
        echo "(not installed)"
    fi
}

# Print a loud warning when the build is not blessed.
warn_wip_build() {
    local current_branch
    current_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

    local dirty_count=0
    if ! is_working_tree_clean; then
        dirty_count=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    fi

    local installed_path
    installed_path=$(get_installed_worktree_path)

    cat >&2 << 'EOF'

===============================================================================
WARNING: NOT BLESSED — WIP WORKTREE GUARD ACTIVE
===============================================================================

This worktree is on a feature branch or has uncommitted/untracked changes. To
prevent accidental takeover of the shared daemon and /Applications/TBD.app, the
full install is SKIPPED. Instead, the app will build and launch from this
worktree's own .build/debug/TBD.app.

CONSEQUENCES:
  • Deep links (tbd://) will NOT route to this app (they'll route to the
    currently-installed build in /Applications)
  • The daemon continues running the previous worktree's build
  • Dev loop works normally (build, code, reload)

DETAILS:
EOF
    printf '  Branch: %s\n' "$current_branch" >&2
    if [ "$dirty_count" -gt 0 ]; then
        printf '  Dirty/untracked files: %s\n' "$dirty_count" >&2
    fi
    printf '  Currently installed from: %s\n' "$installed_path" >&2

    cat >&2 << 'EOF'

TO OVERRIDE (force full install):
  scripts/restart.sh --wip
  or
  TBD_INSTALL_WIP=1 scripts/restart.sh

TO FIX (make it blessed):
  • Commit your changes: git add -A && git commit -m "..."
  • Rebase onto upstream/main: git rebase upstream/main
  • Or push to a tracking branch

===============================================================================

EOF
}
