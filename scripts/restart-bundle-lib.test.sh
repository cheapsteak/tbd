#!/usr/bin/env bash
# Tests for scripts/restart-bundle-lib.sh — run: bash scripts/restart-bundle-lib.test.sh
#
# Every case runs against a temp directory. The three functions that reach for
# system tools (codesign/security, open, pkill/pgrep) get stubs on a temp PATH
# that record their arguments, so nothing here signs, launches, or kills
# anything real. macOS-only: the assembly reads `plutil` and the install uses
# `cp -cR`.
# shellcheck disable=SC2329 # test_* helpers are dispatched dynamically below
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
HELPER="$HERE/restart-bundle-lib.sh"
SOURCE_PLIST="$REPO_ROOT/Resources/TBDApp.Info.plist"

if [ ! -f "$HELPER" ]; then
    echo "FAIL - bundle helper is missing: $HELPER"
    exit 1
fi

# shellcheck source=/dev/null
source "$HELPER"

FAIL=0
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/restart-bundle-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAIL=1; }

assert_ok() {
    local d="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d: expected success"; fi
}

assert_fail() {
    local d="$1"; shift
    if "$@" >/dev/null 2>&1; then fail "$d: expected failure"; else pass "$d"; fi
}

assert_eq() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected [$2] got [$3]"; fi
}

assert_file() {
    if [ -f "$2" ]; then pass "$1"; else fail "$1: missing $2"; fi
}

assert_no_file() {
    if [ -f "$2" ]; then fail "$1: unexpected $2"; else pass "$1"; fi
}

# Read one top-level field out of the sidecar without assuming jq is installed.
sidecar_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

# A throwaway git repo shaped like the parts of TBD the bundle path reads:
# a source plist, an icon, and a Sources/ tree the dirty check looks at.
mkrepo() {
    local d
    d="$(mktemp -d "$TEST_TMP/repo.XXXXXX")"
    git -C "$d" init -q -b main
    git -C "$d" config user.email t@t.t
    git -C "$d" config user.name t
    mkdir -p "$d/Sources" "$d/Resources"
    echo "// seed" > "$d/Sources/Seed.swift"
    cp "$SOURCE_PLIST" "$d/Resources/TBDApp.Info.plist"
    printf 'icns' > "$d/Resources/AppIcon.icns"
    echo "// package" > "$d/Package.swift"
    git -C "$d" add -A
    git -C "$d" commit -q -m seed
    printf '%s\n' "$d"
}

# A build directory with the outputs the assembly copies from.
mkbuild() {
    local d="$1"
    mkdir -p "$d"
    printf '#!/bin/sh\nexit 0\n' > "$d/TBDApp"
    chmod +x "$d/TBDApp"
    mkdir -p "$d/TBD_TBDApp.bundle"
    printf 'strings' > "$d/TBD_TBDApp.bundle/Localizable.strings"
}

# A PATH whose first entry holds stub tools that log their arguments.
mkstubs() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/codesign" << 'EOF'
#!/bin/sh
printf '%s\n' "codesign $*" >> "$STUB_LOG"
EOF
    cat > "$dir/security" << 'EOF'
#!/bin/sh
printf '%s\n' "security $*" >> "$STUB_LOG"
if [ "$1" = "find-identity" ]; then
    [ -n "${STUB_HAS_IDENTITY:-}" ] && echo "  1) ABC TBD Dev Signing"
    exit 0
fi
exit 0
EOF
    cat > "$dir/open" << 'EOF'
#!/bin/sh
printf '%s\n' "open $*" >> "$STUB_LOG"
EOF
    cat > "$dir/pkill" << 'EOF'
#!/bin/sh
printf '%s\n' "pkill $*" >> "$STUB_LOG"
[ -n "${STUB_PROCESS_ALIVE:-}" ] && exit 0
exit 1
EOF
    cat > "$dir/pgrep" << 'EOF'
#!/bin/sh
printf '%s\n' "pgrep $*" >> "$STUB_LOG"
if [ -n "${STUB_PROCESS_ALIVE:-}" ]; then echo 4242; exit 0; fi
exit 1
EOF
    chmod +x "$dir"/*
}

# MARK: - Build identity

test_build_identity_describes_the_tree() {
    local repo build sidecar
    repo="$(mkrepo)"
    build="$repo/.build/release"
    mkbuild "$build"

    assert_ok "write_build_identity succeeds on a clean checkout" \
        write_build_identity "$repo" "$build"
    sidecar="$build/TBDBuildIdentity.json"
    assert_file "write_build_identity writes the sidecar" "$sidecar"

    assert_ok "sidecar is valid JSON" python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$sidecar"
    assert_eq "commit is the tree's HEAD" \
        "$(git -C "$repo" rev-parse HEAD)" "$(sidecar_field "$sidecar" commit)"
    assert_eq "branch is the checked-out branch" "main" "$(sidecar_field "$sidecar" branch)"
    assert_eq "sourceWorktree is the repo root" "$repo" "$(sidecar_field "$sidecar" sourceWorktree)"
    assert_eq "a clean tree is not dirty" "False" "$(sidecar_field "$sidecar" dirty)"

    local short_commit built_at
    short_commit="$(sidecar_field "$sidecar" shortCommit)"
    if [ "${#short_commit}" -ge 7 ]; then
        pass "shortCommit is at least 7 characters"
    else
        fail "shortCommit is at least 7 characters: got [$short_commit]"
    fi
    built_at="$(sidecar_field "$sidecar" builtAt)"
    if [[ "$built_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        pass "builtAt is ISO-8601 UTC"
    else
        fail "builtAt is ISO-8601 UTC: got [$built_at]"
    fi
}

test_build_identity_marks_a_dirty_tree() {
    local repo build
    repo="$(mkrepo)"
    build="$repo/.build/release"
    mkbuild "$build"

    echo "// edit" >> "$repo/Sources/Seed.swift"
    write_build_identity "$repo" "$build" >/dev/null 2>&1
    assert_eq "an edited Sources/ file makes the build dirty" \
        "True" "$(sidecar_field "$build/TBDBuildIdentity.json" dirty)"
}

test_build_identity_ignores_dirt_outside_the_build() {
    local repo build
    repo="$(mkrepo)"
    build="$repo/.build/release"
    mkbuild "$build"

    echo "stray" > "$repo/notes.txt"
    mkdir -p "$repo/docs"
    echo "doc" > "$repo/docs/thing.md"
    write_build_identity "$repo" "$build" >/dev/null 2>&1
    assert_eq "dirt outside the compiled paths does not make the build dirty" \
        "False" "$(sidecar_field "$build/TBDBuildIdentity.json" dirty)"
}

test_build_identity_records_a_detached_head() {
    local repo build
    repo="$(mkrepo)"
    build="$repo/.build/release"
    mkbuild "$build"

    git -C "$repo" checkout -q --detach HEAD
    write_build_identity "$repo" "$build" >/dev/null 2>&1
    assert_eq "a detached checkout records the literal HEAD as its branch" \
        "HEAD" "$(sidecar_field "$build/TBDBuildIdentity.json" branch)"
}

test_build_identity_refuses_a_non_repo() {
    local plain build
    plain="$(mktemp -d "$TEST_TMP/plain.XXXXXX")"
    build="$plain/.build/release"
    mkbuild "$build"

    assert_fail "write_build_identity refuses a directory that is not a checkout" \
        write_build_identity "$plain" "$build"
    assert_no_file "a non-checkout leaves no sidecar" "$build/TBDBuildIdentity.json"
}

# SwiftPM creates .build/<config> as a symlink and skips that step when a real
# directory is already there, which would send the binaries somewhere the
# installer never looks. The stamp defers instead of creating the directory.
test_build_identity_defers_when_the_build_dir_is_absent() {
    local repo build
    repo="$(mkrepo)"
    build="$repo/.build/release"

    assert_fail "write_build_identity defers when the build dir does not exist" \
        write_build_identity "$repo" "$build"
    if [ -d "$build" ]; then
        fail "deferring does not create the build directory"
    else
        pass "deferring does not create the build directory"
    fi
}

test_build_identity_rejects_missing_arguments() {
    assert_fail "write_build_identity needs both arguments" write_build_identity "" ""
}

test_json_escape_string() {
    assert_eq "backslashes are escaped" '/a\\b' "$(json_escape_string '/a\b')"
    assert_eq "quotes are escaped" 'say \"hi\"' "$(json_escape_string 'say "hi"')"
    assert_eq "ordinary text is unchanged" '/Users/x/tbd' "$(json_escape_string '/Users/x/tbd')"
}

# MARK: - Bundle assembly

test_assemble_bundle_produces_a_launchable_bundle() {
    local repo build bundle
    repo="$(mkrepo)"
    build="$repo/.build/release"
    mkbuild "$build"
    write_build_identity "$repo" "$build" >/dev/null 2>&1

    bundle="$(bundle_dir_for_build "$build")"
    assert_eq "bundle_dir_for_build names TBD.app inside the build dir" \
        "$build/TBD.app" "$bundle"

    assert_ok "assemble_app_bundle succeeds" \
        assemble_app_bundle "$repo" "$build" "/usr/bin:/bin"

    assert_file "the bundle has an Info.plist" "$bundle/Contents/Info.plist"
    assert_ok "the generated plist lints" plutil -lint "$bundle/Contents/Info.plist"
    assert_file "the bundle has an executable" "$bundle/Contents/MacOS/TBDApp"
    assert_file "the icon is copied in" "$bundle/Contents/Resources/AppIcon.icns"
    assert_file "the resource bundle is copied in" \
        "$bundle/Contents/Resources/TBD_TBDApp.bundle/Localizable.strings"
    assert_file "the build identity rides along in Contents/" \
        "$bundle/Contents/TBDBuildIdentity.json"
    assert_eq "SourceWorktreePath.txt names the tree that built it" \
        "$repo" "$(cat "$bundle/Contents/SourceWorktreePath.txt")"

    # A hard link, not a copy or a symlink: open(1) resolves symlinks before
    # exec, which would leave the process with no surrounding .app.
    # `ls -di` rather than `stat`, whose BSD and GNU dialects disagree about
    # what `-f` means and do not fail over to each other.
    local build_inode bundle_inode
    build_inode="$(ls -di "$build/TBDApp" | awk '{print $1}')"
    bundle_inode="$(ls -di "$bundle/Contents/MacOS/TBDApp" | awk '{print $1}')"
    assert_eq "the bundle binary is a hard link to the build output" \
        "$build_inode" "$bundle_inode"

    local embedded
    embedded="$(plutil -extract LSEnvironment.PATH raw -o - "$bundle/Contents/Info.plist")"
    assert_eq "the installing shell's PATH is embedded" "/usr/bin:/bin" "$embedded"
}

test_assemble_bundle_rejects_an_empty_path() {
    local repo build
    repo="$(mkrepo)"
    build="$repo/.build/release"
    mkbuild "$build"

    assert_fail "assemble_app_bundle refuses an empty PATH" \
        assemble_app_bundle "$repo" "$build" ""
}

test_assemble_bundle_drops_a_stale_sidecar() {
    local repo build bundle
    repo="$(mkrepo)"
    build="$repo/.build/release"
    mkbuild "$build"
    write_build_identity "$repo" "$build" >/dev/null 2>&1
    assemble_app_bundle "$repo" "$build" "/usr/bin:/bin" >/dev/null 2>&1
    bundle="$(bundle_dir_for_build "$build")"
    assert_file "the first assembly installs a sidecar" "$bundle/Contents/TBDBuildIdentity.json"

    rm -f "$build/TBDBuildIdentity.json"
    assemble_app_bundle "$repo" "$build" "/usr/bin:/bin" >/dev/null 2>&1
    assert_no_file "an unstamped build leaves no stale sidecar in the bundle" \
        "$bundle/Contents/TBDBuildIdentity.json"
}

# MARK: - Signing

test_sign_prefers_the_stable_identity() {
    local repo build bundle stubs
    repo="$(mkrepo)"
    build="$repo/.build/release"
    mkbuild "$build"
    assemble_app_bundle "$repo" "$build" "/usr/bin:/bin" >/dev/null 2>&1
    bundle="$(bundle_dir_for_build "$build")"

    stubs="$TEST_TMP/stubs-signing"
    mkstubs "$stubs"
    export STUB_LOG="$TEST_TMP/signing.log"
    : > "$STUB_LOG"

    PATH="$stubs:$PATH" STUB_HAS_IDENTITY=1 sign_app_bundle "$bundle" >/dev/null 2>&1
    if grep -q -- "--sign TBD Dev Signing" "$STUB_LOG"; then
        pass "an installed signing identity is used when present"
    else
        fail "an installed signing identity is used when present: $(cat "$STUB_LOG")"
    fi

    : > "$STUB_LOG"
    PATH="$stubs:$PATH" sign_app_bundle "$bundle" >/dev/null 2>&1
    if grep -q -- "--sign -" "$STUB_LOG"; then
        pass "signing falls back to ad-hoc without an identity"
    else
        fail "signing falls back to ad-hoc without an identity: $(cat "$STUB_LOG")"
    fi
    unset STUB_LOG
}

test_sign_rejects_a_missing_bundle_argument() {
    assert_fail "sign_app_bundle needs a bundle dir" sign_app_bundle ""
}

# MARK: - Installation

test_install_replaces_the_previous_bundle() {
    local repo build bundle target
    repo="$(mkrepo)"
    build="$repo/.build/release"
    mkbuild "$build"
    assemble_app_bundle "$repo" "$build" "/usr/bin:/bin" >/dev/null 2>&1
    bundle="$(bundle_dir_for_build "$build")"

    target="$TEST_TMP/Applications/TBD.app"
    mkdir -p "$TEST_TMP/Applications/TBD.app/Contents"
    printf 'stale' > "$TEST_TMP/Applications/TBD.app/Contents/Leftover.txt"

    assert_ok "install_app_bundle succeeds" install_app_bundle "$bundle" "$target"
    assert_file "the installed bundle has the binary" "$target/Contents/MacOS/TBDApp"
    assert_eq "the installed bundle names the source tree" \
        "$repo" "$(cat "$target/Contents/SourceWorktreePath.txt")"
    assert_no_file "a previous installation is replaced, not merged" \
        "$target/Contents/Leftover.txt"
}

test_install_rejects_missing_arguments() {
    assert_fail "install_app_bundle needs both arguments" install_app_bundle "" ""
}

# MARK: - App process control

test_exec_pattern_escaping() {
    assert_eq "a dot in a bundle path is escaped" \
        '/Users/x/tbd\.app/Contents/MacOS/TBDApp' \
        "$(escape_exec_pattern '/Users/x/tbd.app/Contents/MacOS/TBDApp')"
    # The bracket class in restart.sh's inline escaper ended at its own `\]`,
    # so none of these were escaped and the anchored pattern was a loose match.
    assert_eq "every regex metacharacter is escaped" \
        '/w\[1\]/a\+b\(c\)\{d\}\^e\$f\|g/TBDApp' \
        "$(escape_exec_pattern '/w[1]/a+b(c){d}^e$f|g/TBDApp')"
    assert_eq "a backslash is escaped once, not twice" \
        '/w\\x/TBDApp' \
        "$(escape_exec_pattern '/w\x/TBDApp')"
    assert_eq "a plain path is unchanged" \
        '/Applications/TBD/Contents/MacOS/TBDApp' \
        "$(escape_exec_pattern '/Applications/TBD/Contents/MacOS/TBDApp')"
}

test_stop_and_launch_use_the_anchored_pattern() {
    local stubs
    stubs="$TEST_TMP/stubs-process"
    mkstubs "$stubs"
    export STUB_LOG="$TEST_TMP/process.log"
    : > "$STUB_LOG"

    assert_ok "stop_app_process succeeds when nothing matches" \
        env PATH="$stubs:$PATH" bash -c 'source "$1"; stop_app_process "/x/TBDApp"' _ "$HELPER"
    if grep -q 'pkill -f \^/x/TBDApp\$' "$STUB_LOG"; then
        pass "stop_app_process anchors the pattern at both ends"
    else
        fail "stop_app_process anchors the pattern at both ends: $(cat "$STUB_LOG")"
    fi

    assert_ok "stop_app_process with an empty pattern is a no-op" stop_app_process ""

    : > "$STUB_LOG"
    PATH="$stubs:$PATH" launch_app_bundle "$TEST_TMP/Some.app" "/usr/bin:/bin" "$TEST_TMP/app.log" >/dev/null 2>&1
    if grep -q 'open --env PATH=/usr/bin:/bin' "$STUB_LOG"; then
        pass "launch_app_bundle passes the PATH through to open"
    else
        fail "launch_app_bundle passes the PATH through to open: $(cat "$STUB_LOG")"
    fi

    assert_fail "launch_app_bundle refuses an empty PATH" \
        launch_app_bundle "$TEST_TMP/Some.app" "" "$TEST_TMP/app.log"

    local pid
    pid="$(PATH="$stubs:$PATH" STUB_PROCESS_ALIVE=1 bash -c 'source "$1"; app_process_pid "/x/TBDApp"' _ "$HELPER")"
    assert_eq "app_process_pid reports the running pid" "4242" "$pid"
    assert_fail "app_process_pid fails when nothing is running" \
        env PATH="$stubs:$PATH" bash -c 'source "$1"; app_process_pid "/x/TBDApp"' _ "$HELPER"
    unset STUB_LOG
}

test_runtime_products_are_executable_targets() {
    local product
    if [ "${#RUNTIME_PRODUCTS[@]}" -eq 0 ]; then
        fail "RUNTIME_PRODUCTS names at least one product"
        return
    fi
    # A name that is not an executable target fails every restart at the
    # per-product build step, so pin each one to Package.swift.
    for product in "${RUNTIME_PRODUCTS[@]}"; do
        if grep -A1 "\.executableTarget(" "$REPO_ROOT/Package.swift" \
                | grep -q "name: \"$product\""; then
            pass "RUNTIME_PRODUCTS: $product is an executable target"
        else
            fail "RUNTIME_PRODUCTS: $product is not an executable target in Package.swift"
        fi
    done
}

test_helper_refuses_direct_execution() {
    if bash "$HELPER" >/dev/null 2>&1; then
        fail "the helper refuses to be run directly"
    else
        pass "the helper refuses to be run directly"
    fi
}

test_build_identity_describes_the_tree
test_build_identity_marks_a_dirty_tree
test_build_identity_ignores_dirt_outside_the_build
test_build_identity_records_a_detached_head
test_build_identity_refuses_a_non_repo
test_build_identity_defers_when_the_build_dir_is_absent
test_build_identity_rejects_missing_arguments
test_json_escape_string
test_assemble_bundle_produces_a_launchable_bundle
test_assemble_bundle_rejects_an_empty_path
test_assemble_bundle_drops_a_stale_sidecar
test_sign_prefers_the_stable_identity
test_sign_rejects_a_missing_bundle_argument
test_install_replaces_the_previous_bundle
test_install_rejects_missing_arguments
test_exec_pattern_escaping
test_stop_and_launch_use_the_anchored_pattern
test_runtime_products_are_executable_targets
test_helper_refuses_direct_execution

if [ "$FAIL" -ne 0 ]; then
    echo "SOME RESTART BUNDLE TESTS FAILED"
    exit 1
fi

echo "ALL RESTART BUNDLE TESTS PASSED"
