#!/usr/bin/env bash
# Bundle-assembly helpers shared by scripts/restart.sh and scripts/update.sh.
#
# Safe to source: this file defines functions and does not act on its own. Two
# scripts install TBD now — restart.sh from the operator's worktree, update.sh
# from the update clone under ~/tbd/updates/src — and they must produce a byte
# -identical bundle, so the assembly lives here once rather than twice.
#
# Every function takes the paths it acts on as explicit parameters. Nothing
# reads a global from the calling script, so scripts/restart-bundle-lib.test.sh
# can drive each one against a temp directory.

TBD_BUNDLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The plist writer lives next door. restart.sh sources it first for its PATH
# precondition check; update.sh does not, so pull it in when it is missing.
if ! declare -F write_restart_environment_plist >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$TBD_BUNDLE_LIB_DIR/restart-environment-lib.sh"
fi

# The paths whose contents decide what a build produces. Same set the WIP guard
# calls install-affecting, and the set whose dirtiness the build identity
# records: a change under any of them means the sidecar's commit no longer
# describes the binary beside it.
# The LaunchServices registration tool. A variable because it is an absolute
# path: a test cannot shadow it by putting a stub first on PATH the way it can
# with codesign or open, and a harness that ran the real one would register its
# fixture bundles with the developer's LaunchServices database.
TBD_LSREGISTER="${TBD_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister}"

BUILD_IDENTITY_PATHSPECS=(
    Sources
    Resources
    Package.swift
    Package.resolved
)

# Every product a running installation needs. scripts/restart.sh and
# scripts/update.sh both build exactly this list, so a product added here
# reaches both paths. TBDCLI, TBDHolder and TBDPeerHelper are each found by a
# SIBLING lookup beside the daemon binary, and a sibling that was never built
# fails in the field rather than in the build:
#
#   TBDDaemon      launched in place from .build/<config>.
#   TBDApp         hard-linked into the .app bundle by assemble_app_bundle.
#   TBDCLI         `tbd`. Every replacement agent process is handed the
#                  daemon's sibling copy as TBD_CLI_PATH and its hooks run that
#                  one, swallowing the error when it is missing
#                  (AgentProcessEnvironment, ClaudeHookOverlay,
#                  CodexHomeManager). update.sh also re-links an existing
#                  ~/.local/bin/tbd hard link to it.
#   TBDHolder      the pty holder the daemon spawns for a holder-backed session
#                  (HolderSpawner.locateSiblingExecutable). Missing, the daemon
#                  reports ptyHolderSupported=false: the Settings toggle greys
#                  out, and a toggle that was already on sends every new
#                  session to tmux with no error.
#   TBDPeerHelper  the shadow-peer helper for remote peer messaging
#                  (ShadowPeerHelperProcessSpawner). Missing, a remote lane
#                  fails to arm with executableMissing.
#
# scripts/restart-bundle-lib.test.sh checks that each name is an executable
# target in Package.swift, so a rename or typo fails there and not on the next
# restart.
# shellcheck disable=SC2034 # consumed by the two scripts that source this file
RUNTIME_PRODUCTS=(TBDDaemon TBDApp TBDCLI TBDHolder TBDPeerHelper)

# MARK: - Build identity

# Escape a value for embedding in a JSON string literal. Backslashes first,
# then quotes — the other order would double-escape the backslash it just
# inserted. Paths and branch names cannot contain a raw newline in git, so
# control-character escaping is not needed here.
json_escape_string() {
    printf '%s' "${1-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Write TBDBuildIdentity.json into a build directory, describing the tree the
# build is about to compile. Called BEFORE the compiler runs, so a binary and
# the sidecar beside it always name the same commit.
#
#   write_build_identity <repo_root> <build_dir>
#
# Returns non-zero without writing anything in two cases. When <repo_root> is
# not a git checkout, a build that cannot be described gets no sidecar rather
# than a wrong one, and the loader falls back as the design says. When
# <build_dir> does not exist yet — a tree that has never been built — the
# stamp is DEFERRED rather than forced: SwiftPM creates `.build/<config>` as a
# symlink to `.build/<triple>/<config>` and skips that step when a real
# directory already occupies the path, so creating one here would send the
# binaries somewhere the installer never looks. Callers stamp again after the
# build for that case.
write_build_identity() {
    local repo_root="${1-}"
    local build_dir="${2-}"
    local commit short_commit branch dirty_output dirty built_at sidecar

    if [ -z "$repo_root" ] || [ -z "$build_dir" ]; then
        echo "error: write_build_identity needs a repo root and a build dir" >&2
        return 1
    fi

    if ! commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)" || [ -z "$commit" ]; then
        echo "warning: $repo_root has no git HEAD — skipping build identity" >&2
        return 1
    fi
    short_commit="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || printf '%s' "${commit:0:7}")"
    branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"

    # A detached checkout — every update clone — reports the literal "HEAD".
    # That is the value the design names, so it is recorded as-is.
    dirty_output="$(git -C "$repo_root" status --porcelain -- "${BUILD_IDENTITY_PATHSPECS[@]}" 2>/dev/null)"
    if [ -n "$dirty_output" ]; then
        dirty=true
    else
        dirty=false
    fi

    if [ ! -d "$build_dir" ]; then
        echo "warning: $build_dir does not exist yet — deferring the build identity stamp" >&2
        return 1
    fi

    built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    sidecar="$build_dir/TBDBuildIdentity.json"
    cat > "$sidecar" << EOF
{
  "commit": "$(json_escape_string "$commit")",
  "shortCommit": "$(json_escape_string "$short_commit")",
  "branch": "$(json_escape_string "$branch")",
  "builtAt": "$(json_escape_string "$built_at")",
  "sourceWorktree": "$(json_escape_string "$repo_root")",
  "dirty": $dirty
}
EOF
}

# MARK: - Bundle assembly

# The bundle a build directory carries. One place decides the name so callers
# never compose it themselves.
bundle_dir_for_build() {
    printf '%s\n' "${1-}/TBD.app"
}

# Assemble .build/<config>/TBD.app from a finished build.
#
#   assemble_app_bundle <repo_root> <build_dir> <launch_path>
#
# macOS resolves tbd:// URLs via LaunchServices, which requires a
# CFBundleURLTypes entry in an Info.plist inside a .app bundle. The bundle's
# binary is a HARD LINK to the swift-build output: open(1) resolves symlinks
# before exec, which would leave the process appearing to run from
# .build/.../TBDApp with no surrounding .app, so every API that reads
# CFBundleIdentifier (UNUserNotificationCenter for banners, and the rest)
# silently fails. A hard link shares the inode — zero extra disk, and the
# governed Swift build updates it directly — while keeping the
# kernel-reported exec path inside the bundle.
assemble_app_bundle() {
    local repo_root="${1-}"
    local build_dir="${2-}"
    local launch_path="${3-}"
    local bundle_dir bundle_macos bundle_plist source_plist
    local app_exec_path bundle_resources source_icon bundle_icon
    local source_resource_bundle bundle_resource_bundle sidecar

    if [ -z "$repo_root" ] || [ -z "$build_dir" ]; then
        echo "error: assemble_app_bundle needs a repo root and a build dir" >&2
        return 1
    fi
    require_restart_path "$launch_path" || return 1

    bundle_dir="$(bundle_dir_for_build "$build_dir")"
    bundle_macos="$bundle_dir/Contents/MacOS"
    bundle_plist="$bundle_dir/Contents/Info.plist"
    source_plist="$repo_root/Resources/TBDApp.Info.plist"

    mkdir -p "$bundle_macos" || return 1

    # Recreate the generated plist from the machine-independent source every
    # run, then embed and verify the installation's exact PATH before signing.
    write_restart_environment_plist "$source_plist" "$bundle_plist" "$launch_path" || return 1

    # Resolve the absolute real path of the swift-build output first, so `ln`
    # below gets an absolute path (sidesteps cwd-relative resolution) and the
    # caller has a stable pgrep/pkill match target.
    app_exec_path="$(/usr/bin/readlink -f "$build_dir/TBDApp")" || return 1
    # `ln -f` replaces any existing entry (including a stale symlink from an
    # older restart.sh) idempotently.
    ln -f "$app_exec_path" "$bundle_macos/TBDApp" || return 1

    # macOS reads the bundled icon for Notification Center banners, System
    # Settings → Notifications, and Finder — none of those look at
    # NSApp.applicationIconImage, which still drives the per-worktree Dock icon
    # at runtime. Bake a new one with `swift run IconBaker
    # Resources/AppIcon.icns` after changing Sources/TBDAppIcon/AppIcon.swift.
    bundle_resources="$bundle_dir/Contents/Resources"
    source_icon="$repo_root/Resources/AppIcon.icns"
    bundle_icon="$bundle_resources/AppIcon.icns"
    mkdir -p "$bundle_resources" || return 1
    if [ -f "$source_icon" ] && { [ ! -f "$bundle_icon" ] || [ "$source_icon" -nt "$bundle_icon" ]; }; then
        cp "$source_icon" "$bundle_icon" || return 1
    fi

    # The resource bundle with localized strings and assets. SPM produces it in
    # .build/arm64-apple-macosx/<config>; it must be inside the .app or app
    # launch fails with "could not load resource bundle". $build_dir is a
    # symlink to that directory, so reach the bundle through it rather than
    # composing a path with ../arm64-apple-macosx/<config>.
    source_resource_bundle="$build_dir/TBD_TBDApp.bundle"
    bundle_resource_bundle="$bundle_resources/TBD_TBDApp.bundle"
    if [ -d "$source_resource_bundle" ]; then
        rm -rf "$bundle_resource_bundle"
        cp -R "$source_resource_bundle" "$bundle_resource_bundle" || return 1
    else
        echo "warning: TBD_TBDApp.bundle not found at $source_resource_bundle" >&2
    fi

    # Stash the source worktree path inside the bundle so the running app can
    # show it in the status bar — it can no longer infer this from its own exec
    # path now that it runs from /Applications instead of .build/.
    printf '%s' "$repo_root" > "$bundle_dir/Contents/SourceWorktreePath.txt" || return 1

    # Carry the build identity into the bundle, next to SourceWorktreePath.txt.
    # The app resolves its own identity from Contents/, where the daemon
    # resolves it from the directory beside its executable.
    sidecar="$build_dir/TBDBuildIdentity.json"
    if [ -f "$sidecar" ]; then
        cp "$sidecar" "$bundle_dir/Contents/TBDBuildIdentity.json" || return 1
    else
        rm -f "$bundle_dir/Contents/TBDBuildIdentity.json"
    fi
}

# MARK: - Signing and installation

# Sign a bundle in place.
#
#   sign_app_bundle <bundle_dir>
#
# Re-signing with --force --deep makes the codesign identifier match
# CFBundleIdentifier; SPM's default ad-hoc signature uses TBDApp-<hash>, which
# macOS uses for permission tracking and rejects.
#
# Prefer a stable self-signed identity so TCC grants and denials persist across
# rebuilds. Ad-hoc signing gives TCC only a bare cdhash with no stable anchor,
# so every rebuild — and even repeated accesses within one build, when access
# is attributed via a spawned child like a `claude` session — fails the stored
# code-requirement check and re-prompts. One-time setup creates the "TBD Dev
# Signing" identity in a dedicated tbd-signing keychain (docs/tcc-signing.md).
# If it is absent (a fresh clone, another contributor's machine), fall back to
# ad-hoc so installing still works.
sign_app_bundle() {
    local bundle_dir="${1-}"
    local sign_keychain="$HOME/Library/Keychains/tbd-signing.keychain-db"
    local sign_identity="TBD Dev Signing"

    if [ -z "$bundle_dir" ]; then
        echo "error: sign_app_bundle needs a bundle dir" >&2
        return 1
    fi

    if security find-identity -p codesigning "$sign_keychain" 2>/dev/null | grep -q "$sign_identity"; then
        security unlock-keychain -p tbd-signing "$sign_keychain" 2>/dev/null || true
        codesign --force --deep --identifier com.github.cheapsteak.tbd \
            --sign "$sign_identity" --keychain "$sign_keychain" "$bundle_dir" >/dev/null
    else
        codesign --force --deep --sign - "$bundle_dir" >/dev/null
    fi
}

# Copy a signed bundle over the installed one and re-register it.
#
#   install_app_bundle <bundle_dir> <installed_bundle>
#
# /Applications is the only path macOS 15 accepts for requestAuthorization;
# bundles elsewhere return UNErrorDomain Code=1 with no permission dialog.
# `cp -cR` uses APFS clonefile (copy-on-write, ~zero disk cost). All TBD
# worktrees share CFBundleIdentifier=com.github.cheapsteak.tbd, so whichever
# tree most recently installed "wins" /Applications — the same
# last-install-wins behavior already documented for tbd:// URL routing.
install_app_bundle() {
    local bundle_dir="${1-}"
    local installed_bundle="${2-}"

    if [ -z "$bundle_dir" ] || [ -z "$installed_bundle" ]; then
        echo "error: install_app_bundle needs a bundle dir and an install path" >&2
        return 1
    fi

    rm -rf "$installed_bundle"
    cp -cR "$bundle_dir" "$installed_bundle" || return 1
    register_app_bundle "$installed_bundle"
}

# Tell LaunchServices about a bundle that appeared or moved at <path>. Its own
# function because an update that has to put the previous bundle back must
# re-register it exactly as an install does — a bundle LaunchServices does not
# know about takes no tbd:// URL and shows a stale icon.
register_app_bundle() {
    local installed_bundle="${1-}"

    [ -n "$installed_bundle" ] || return 1

    if [ -x "$TBD_LSREGISTER" ]; then
        "$TBD_LSREGISTER" -f "$installed_bundle" >/dev/null 2>&1 || true
    fi

    # Bump the installed bundle's mtime so Notification Center and System
    # Settings pick up an updated AppIcon.icns instead of serving a stale
    # icon-cache entry. `lsregister -f` alone does not always invalidate those
    # caches; `touch` does.
    touch "$installed_bundle"
}

# MARK: - App process control

# Resolve a path through symlinks. Separate from the escaper below so callers
# can hold on to the resolved path itself.
resolve_exec_path() {
    /usr/bin/readlink -f "${1-}"
}

# Escape a resolved executable path for an end-anchored pgrep/pkill pattern, so
# a match can only ever be that exact command line — never a swift build
# subprocess, an editor, or a sibling worktree whose command line merely
# contains "TBDApp".
#
# Three expressions rather than one bracket class: BSD sed rejects a class that
# opens with `]`, and a class written `[...\[\]...]` silently ends at the first
# `]` — which is what the inline escaper in restart.sh did, leaving every
# metacharacter unescaped. The backslash goes first so the backslashes the
# later expressions insert are not escaped again.
escape_exec_pattern() {
    printf '%s' "${1-}" \
        | sed -e 's/[\\.+*?(){}^$|]/\\&/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g'
}

# Kill the app process whose command line is exactly <pattern>, if it is
# running. Always succeeds: nothing to kill is a normal outcome.
stop_app_process() {
    local pattern="${1-}"
    [ -n "$pattern" ] || return 0
    pkill -f "^${pattern}\$" 2>/dev/null && sleep 0.3
    return 0
}

# Launch a bundle through LaunchServices with an explicit PATH.
#
#   launch_app_bundle <bundle_dir> <launch_path> <log_path>
#
# The PATH the installing shell had is the PATH contract for every TBD process
# launched from this bundle; LaunchServices ignores LSEnvironment.PATH on a
# login relaunch, so pass it here too.
launch_app_bundle() {
    local bundle_dir="${1-}"
    local launch_path="${2-}"
    local log_path="${3:-/tmp/tbdapp.log}"

    if [ -z "$bundle_dir" ]; then
        echo "error: launch_app_bundle needs a bundle dir" >&2
        return 1
    fi
    require_restart_path "$launch_path" || return 1

    open --env "PATH=$launch_path" "$bundle_dir" --stdout "$log_path" --stderr "$log_path"
}

# Echo the pid of the running app matching <pattern>, or nothing. Non-zero when
# no process matches.
app_process_pid() {
    local pattern="${1-}"
    local pid
    [ -n "$pattern" ] || return 1
    pid="$(pgrep -f "^${pattern}\$" 2>/dev/null | head -1)"
    [ -n "$pid" ] || return 1
    printf '%s\n' "$pid"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "error: source this helper from restart.sh, update.sh, or their test harnesses" >&2
    exit 64
fi
