#!/usr/bin/env bash
# Remove the debug-symbol bundles (`*.dSYM`) a local debug build leaves in
# `.build`. Safe to source: defines functions only. Callers:
# scripts/restart.sh (after a successful build), scripts/test.sh (on exit,
# whatever the verdict) and scripts/reclaim-build.sh (idle worktrees). Harness:
# scripts/dsym-prune-lib.test.sh.
#
# WHY THEY CAN GO. With `-g`, the swiftc link step runs `dsymutil` itself and
# copies all the DWARF out of the `.o` files into a bundle beside the binary:
# ~900 MB per worktree, 646 MB of it the test bundle's. Nothing local needs it.
# The linked binary keeps a debug map (N_OSO stabs) naming those same `.o`
# files, which stay in `.build`, so lldb still sets file:line breakpoints and
# shows locals through the map; and the app's crash reports use
# `callStackSymbols`, which reads the symbol table, not DWARF.
#
# WHY IT STAYS GONE UNTIL THE NEXT LINK. The bundle is a side effect of the link
# command, not a declared output in `.build/debug.yaml`, so a missing one does
# not make llbuild re-run anything: a no-op build stays a no-op, and the next
# real relink writes a fresh bundle, which is why every caller prunes after it
# builds rather than once.
#
# Opt out with TBD_KEEP_DSYM=1. Skipped whenever CI is set: runners are
# ephemeral, so there is no disk to win back, and CI's stall watchdog samples and
# symbolicates the test process (scripts/ci/watched-test-pass.sh).

# True when pruning is switched off for this environment.
dsym_prune_disabled() {
    [ -n "${CI:-}" ] && return 0
    [ "${TBD_KEEP_DSYM:-}" = "1" ]
}

# Print, one per line, every `*.dSYM` bundle under `<root>/.build/<triple>/debug`,
# including the one nested in the test bundle
# (`TBDPackageTests.xctest/Contents/MacOS/TBDPackageTests.dSYM`). Release
# layouts, plugin caches and the `.build/debug` symlink are not searched.
list_debug_dsyms() {
    local root="${1:?list_debug_dsyms needs a repo root}" debug_dir
    [ -d "$root/.build" ] || return 0
    find "$root/.build" -mindepth 2 -maxdepth 2 -type d -name debug 2>/dev/null |
        while IFS= read -r debug_dir; do
            find "$debug_dir" -maxdepth 4 -type d -name '*.dSYM' -prune -print 2>/dev/null
        done
}

# Delete every bundle list_debug_dsyms finds under the worktree at $1, unless
# dsym_prune_disabled. Prints one summary line when it removed something.
# Always returns 0: a leftover bundle costs disk, never correctness, so this
# must never fail the build or test run that called it.
prune_debug_dsyms() {
    local root="${1-}"
    [ -n "$root" ] || return 0
    dsym_prune_disabled && return 0
    local bundles kb=0 count=0 bundle size
    bundles="$(list_debug_dsyms "$root")" || true
    [ -n "$bundles" ] || return 0
    while IFS= read -r bundle; do
        [ -n "$bundle" ] || continue
        size="$(du -sk "$bundle" 2>/dev/null | awk '{print $1}')" || size=0
        if rm -rf "$bundle" 2>/dev/null; then
            count=$((count + 1))
            kb=$((kb + ${size:-0}))
        fi
    done <<EOF
$bundles
EOF
    if [ "$count" -gt 0 ]; then
        printf 'Removed %s debug-symbol bundle(s) from .build (%s MB); TBD_KEEP_DSYM=1 keeps them\n' \
            "$count" "$((kb / 1024))"
    fi
    return 0
}
