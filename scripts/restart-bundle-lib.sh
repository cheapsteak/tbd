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
# Every product here is all-or-nothing: a helper that fails to compile stops
# the restart or update the same way a daemon that fails to compile does. That
# is deliberate. Each helper degrades gracefully at runtime when it is ABSENT,
# and that graceful path is exactly how a never-built helper went unnoticed;
# building it as a warning would put the same silent degradation one scroll
# above the "Daemon ready" line. The holder and peer helper depend on
# TBDKernel and nothing else, and the CLI on TBDShared, TBDKernel and packages
# the daemon also links, so a helper that
# fails while the daemon builds is a broken tree, and a broken tree is what a
# restart should refuse.
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

# The source file whose SchemaEpoch.current a build records, relative to the
# repo root.
SCHEMA_EPOCH_SOURCE="Sources/TBDShared/SchemaEpoch.swift"

# Print the schema epoch the tree at <repo_root> carries: the integer in the
# one `public static let current = <N>` line of SchemaEpoch.swift.
#
#   read_schema_epoch <repo_root>
#
# Strict on purpose. The daemon drops a retired column only once the bundle
# kept for rollback records an epoch at or past the column's, so a bundle
# stamped without one holds every drop until the next update replaces it.
# Fails, naming the file, when the file is missing or the line is not exactly
# one plain decimal declaration.
read_schema_epoch() {
    local repo_root="${1-}"
    local file="$repo_root/$SCHEMA_EPOCH_SOURCE"
    local values count

    if [ ! -f "$file" ]; then
        echo "error: $file is missing — cannot record the schema epoch in the build identity" >&2
        return 1
    fi
    values="$(sed -n -E 's/^[[:space:]]*public static let current = (0|[1-9][0-9]*)[[:space:]]*$/\1/p' "$file")"
    count="$(printf '%s' "$values" | grep -c '^' || true)"
    if [ "$count" != 1 ]; then
        echo "error: $file has no single 'public static let current = <integer>' line — cannot record the schema epoch in the build identity" >&2
        return 1
    fi
    printf '%s\n' "$values"
}

# Write TBDBuildIdentity.json into a build directory, describing the tree
# <repo_root> is at when this is called.
#
#   write_build_identity <repo_root> <build_dir>
#
# scripts/restart.sh calls this BEFORE the compiler runs, so a binary and the
# sidecar beside it always name the same commit. A failed build leaves the
# same mismatch there too — a sidecar naming a commit that was never built,
# next to whatever binaries were already in place — but it is narrower and
# self-healing: it is one developer's own worktree, and the next restart
# (successful or not) stamps that worktree's actual HEAD fresh. scripts/
# update.sh calls this only AFTER a successful build instead, because its
# build directory lives in one long-lived clone every update reuses: the same
# mismatch there would misdescribe that clone indefinitely, with no later
# write to correct it until the clone's next successful build.
#
# The sidecar also records the tree's schema epoch (read_schema_epoch above),
# which the daemon compares against each retired column before dropping it.
#
# Returns non-zero without writing anything in three cases. When <repo_root> is
# not a git checkout, a build that cannot be described gets no sidecar rather
# than a wrong one, and the loader falls back as the design says. When the
# tree's schema epoch cannot be read, the error names the file: a bundle
# without an epoch holds every column drop, so a missing one has to be loud
# rather than silently stamped. When <build_dir> does not exist yet — a tree
# that has never been built — the stamp is DEFERRED rather than forced:
# SwiftPM creates `.build/<config>` as a symlink to `.build/<triple>/<config>`
# and skips that step when a real directory already occupies the path, so
# creating one here would send the binaries somewhere the installer never
# looks. Callers stamp again after the build for that case.
write_build_identity() {
    local repo_root="${1-}"
    local build_dir="${2-}"
    local commit short_commit branch dirty_output dirty built_at sidecar schema_epoch

    if [ -z "$repo_root" ] || [ -z "$build_dir" ]; then
        echo "error: write_build_identity needs a repo root and a build dir" >&2
        return 1
    fi

    if ! commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)" || [ -z "$commit" ]; then
        echo "warning: $repo_root has no git HEAD — skipping build identity" >&2
        return 1
    fi
    if ! schema_epoch="$(read_schema_epoch "$repo_root")"; then
        echo "error: no build identity stamped for $repo_root" >&2
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
  "dirty": $dirty,
  "schemaEpoch": $schema_epoch
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
    local source_resource_bundle bundle_resource_bundle resource_bundle_name sidecar

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

    # Every SwiftPM resource bundle next to the built products goes into the
    # .app. SPM produces them in .build/arm64-apple-macosx/<config>; $build_dir
    # is a symlink to that directory, so reach them through it rather than
    # composing a path with ../arm64-apple-macosx/<config>.
    #
    # TBD_TBDApp.bundle (localized strings and assets) has always been required
    # — without it app launch fails outright with "could not load resource
    # bundle". The dependencies' bundles matter for a subtler reason, and the
    # failure they produce is silent rather than loud: a SwiftPM library's
    # `Bundle.module` accessor falls back to the absolute
    # `.build/.../<Pkg>_<Target>.bundle` path baked in at compile time, which
    # happens to resolve on the machine that built the binary — so a missing
    # bundle looks fine here and breaks anywhere else. Code that probes for its
    # bundle by name instead (SwiftTerm's Metal renderer does, deliberately,
    # because the generated accessor `fatalError`s) looks only at `Bundle.main`
    # — its `resourceURL` and its `bundleURL` — and finds nothing when the
    # bundle is staged nowhere. The app binary is hard-linked INTO the bundle,
    # so `Bundle.main` is TBD.app, and `SwiftTerm_SwiftTerm.bundle`, which
    # carries `Shaders.metal`, was not there. The result was `setUseMetal(true)`
    # throwing `shaderSourceMissing` and the terminal quietly staying on
    # CoreGraphics: a GPU renderer that reports itself unavailable on a machine
    # with a GPU.
    #
    # Copying all of them is both shorter than naming two and the right
    # invariant: an .app must carry every resource bundle its executable may
    # look up at runtime. They are small, and a stale one is worse than a
    # redundant one, so the staged set is cleared first and rebuilt from what
    # the build actually produced — otherwise a dependency that is dropped or
    # renamed leaves its bundle in the .app forever, and the next person
    # debugging a resource lookup finds two plausible candidates.
    rm -rf "$bundle_resources"/*.bundle
    for source_resource_bundle in "$build_dir"/*.bundle; do
        [ -d "$source_resource_bundle" ] || continue
        resource_bundle_name="$(basename "$source_resource_bundle")"
        # Test-target resource bundles are fixtures, not app resources. They can
        # be large and they ship nothing the app reads, so keep them out.
        case "$resource_bundle_name" in
            *Tests.bundle) continue ;;
        esac
        bundle_resource_bundle="$bundle_resources/$resource_bundle_name"
        rm -rf "$bundle_resource_bundle"
        cp -R "$source_resource_bundle" "$bundle_resource_bundle" || return 1
    done
    # The app's own bundle is the one whose absence is fatal, so it keeps a check.
    if [ ! -d "$bundle_resources/TBD_TBDApp.bundle" ]; then
        echo "warning: TBD_TBDApp.bundle not found at $build_dir/TBD_TBDApp.bundle" >&2
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
# `cp -cR` uses APFS clonefile (copy-on-write, ~zero disk cost). It is
# `/bin/cp` by absolute path because -c is BSD-only: a dev shell that puts GNU
# coreutils first on PATH (nix, direnv, Homebrew's gnubin) resolves a bare `cp`
# to one that rejects the flag, and the install fails. All TBD worktrees share
# CFBundleIdentifier=com.github.cheapsteak.tbd, so whichever tree most recently
# installed "wins" /Applications — the same last-install-wins behavior already
# documented for tbd:// URL routing.
install_app_bundle() {
    local bundle_dir="${1-}"
    local installed_bundle="${2-}"

    if [ -z "$bundle_dir" ] || [ -z "$installed_bundle" ]; then
        echo "error: install_app_bundle needs a bundle dir and an install path" >&2
        return 1
    fi

    rm -rf "$installed_bundle"
    /bin/cp -cR "$bundle_dir" "$installed_bundle" || return 1
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

# Stop the app process whose command line is exactly <pattern>, and wait until
# nothing matching it is left.
#
#   stop_app_process <pattern> [grace_seconds] [kill_wait_seconds]
#
# SIGTERM (pkill's default) first, then up to <grace_seconds> (default 5) for
# it to exit, then SIGKILL and up to <kill_wait_seconds> (default 3) more.
# The wait is the point. An app that is still on its way out can reconnect to
# a daemon the caller has just started and re-attach a session, leaving that
# daemon holding a claim for a viewer about to die; and `open` on a bundle
# whose process is still running activates that process instead of launching
# a new one, so the relaunch is lost when it finishes exiting.
#
# Both waits are whole numbers of seconds (see _wait_for_no_match), and a
# wait of 0 still checks once.
#
# Prints one word saying how it ended, for the caller to report:
#   none      nothing matched, so nothing was signalled
#   stopped   nothing matching was left within the grace period after SIGTERM
#   killed    something matching outlived the grace period and was gone after
#             SIGKILL
#   survived  something matching is still running after SIGKILL
#   unknown   pgrep failed at the end of the wait after SIGKILL instead of
#             answering, so whether anything matching is still running cannot
#             be told
# Returns non-zero for `survived` and `unknown`: either way the app may still
# be running.
stop_app_process() {
    local pattern="${1-}"
    local grace="${2:-5}"
    local kill_wait="${3:-3}"
    local status=0

    if [ -z "$pattern" ]; then
        printf 'none\n'
        return 0
    fi

    # A failed pkill is not by itself "nothing running". pkill exits 1 when
    # nothing matched, but also when every match refused the signal, since a
    # process it could not signal does not count as a match; and it exits 2
    # or 3 on an error that says nothing either way. Read as `none`, any of
    # those hands the caller a running app as absent, and an update then hands
    # the daemon over with it alive and owes it no relaunch. So pgrep decides,
    # and only its own "no match" is `none`. Everything else goes on to the
    # wait and the SIGKILL like an app that took the signal. An app pgrep
    # still finds may never have received the SIGTERM, and the escalation is
    # what finds out whether anything can stop it. A pgrep that errors instead
    # of answering leaves the app possibly there, and stopping here would never
    # signal one that is; going on costs nothing when it is not, since an app
    # that is gone simply matches nothing. That case can end `stopped` or
    # `killed` with nothing ever running, which the callers treat as an app
    # that was: at worst a relaunch nobody needed, where `none` would risk
    # never bringing back an app that was open. Only a wait that still gets
    # no answer after SIGKILL is `unknown`.
    pkill -f "^${pattern}\$" 2>/dev/null || status=$?
    if [ "$status" -ne 0 ]; then
        status=0
        pgrep -f "^${pattern}\$" >/dev/null 2>&1 || status=$?
        if [ "$status" -eq 1 ]; then
            printf 'none\n'
            return 0
        fi
    fi

    status=0
    _wait_for_no_match "$pattern" "$grace" || status=$?
    if [ "$status" -eq 0 ]; then
        printf 'stopped\n'
        return 0
    fi

    # Still matching, or pgrep could not say: SIGKILL either way, since an
    # app that has already gone simply matches nothing.
    pkill -KILL -f "^${pattern}\$" 2>/dev/null || true
    status=0
    _wait_for_no_match "$pattern" "$kill_wait" || status=$?
    case "$status" in
        0)
            printf 'killed\n'
            return 0
            ;;
        1)
            printf 'survived\n'
            return 1
            ;;
        *)
            printf 'unknown\n'
            return 1
            ;;
    esac
}

# The line that reports how a stop_app_process call ended, for the caller to
# print or log. One wording for every script that stops the app, so the same
# outcome reads the same in a restart's output and an update's log.
#
#   describe_app_stop <outcome> <grace_seconds> <app>
#
# <grace_seconds> is the grace the stop was given, so the `killed` line states
# the wait that actually ran. <app> names where the app runs from, a bundle or
# an executable path, for the lines that need it to be actionable. An
# outcome stop_app_process never prints gets a line of its own rather than
# borrowing another outcome's wording.
describe_app_stop() {
    local outcome="${1-}"
    local grace="${2-}"
    local app="${3-}"
    case "$outcome" in
        none) printf 'no app running from %s to stop\n' "$app" ;;
        stopped) printf 'the app exited\n' ;;
        killed) printf 'the app ignored SIGTERM for %ss and exited on SIGKILL\n' "$grace" ;;
        survived) printf 'WARNING: the app running from %s is still running after SIGKILL\n' "$app" ;;
        unknown) printf 'WARNING: could not tell whether an app is still running from %s: pgrep failed\n' \
            "$app" ;;
        *) printf 'WARNING: stopping the app running from %s ended in an unrecognised way: [%s]\n' \
            "$app" "$outcome" ;;
    esac
}

# Wait up to <seconds> for no process's command line to be exactly <pattern>.
#
#   _wait_for_no_match <pattern> <seconds>
#
# <seconds> is a whole number: it is multiplied in bash arithmetic, which has
# no fractions. Polled in tenths of a second: the app usually exits within the
# first one, and a whole-second poll would add that second to every restart.
# The first poll comes before any sleep, so a wait of 0 still asks pgrep once
# and answers from what it says rather than from no poll at all.
#
# Returns 0 once pgrep finds nothing, 1 if something still matched at the last
# poll, and 2 if the last poll was a pgrep error. Only pgrep's own "no match"
# (exit 1) counts as gone: an error (2 or 3) is no answer at all, and read as
# one it reports a running app as stopped.
_wait_for_no_match() {
    local pattern="$1"
    local ticks=$(($2 * 10))
    local status
    while :; do
        status=0
        pgrep -f "^${pattern}\$" >/dev/null 2>&1 || status=$?
        if [ "$status" -eq 1 ]; then
            return 0
        fi
        [ "$ticks" -gt 0 ] || break
        sleep 0.1
        ticks=$((ticks - 1))
    done
    if [ "$status" -eq 0 ]; then
        return 1
    fi
    return 2
}

# MARK: - Daemon process control

# True when <value> is a whole number written the way bash arithmetic reads
# it: digits only, at least one, and no leading zero unless it is 0 itself,
# because arithmetic reads a leading zero as octal (08 is an error, 010 is
# eight). Every budget below is checked with it before anything is signalled:
# a budget like 0.5 would otherwise fail mid-wait, after a SIGTERM had gone
# out.
_is_whole_number() {
    case "${1-}" in
        '' | *[!0-9]* | 0?*) return 1 ;;
    esac
}

# True when <value> is a pid: a whole number above zero.
_is_pid() {
    _is_whole_number "${1-}" && [ "$1" -gt 0 ]
}

# True when <value> is a number of seconds above zero that sleep accepts:
# digits with at most one decimal point, not all of them zeros. A poll
# interval of 0 would spin.
_is_positive_interval() {
    case "${1-}" in
        '' | . | *[!0-9.]* | *.*.*) return 1 ;;
    esac
    [ -n "${1//[0.]/}" ]
}

# Print "<state> <name>" for the process running as <pid>, from one `ps`, or
# nothing when no process runs as <pid>. The name is the kernel's accounting
# name (`ucomm`): the file the process executed, which neither its arguments
# nor its argv[0] can change.
_process_state_and_name() {
    _is_pid "${1-}" || return 1
    ps -o stat= -o ucomm= -p "$1" 2>/dev/null
}

# True while a process runs as <pid>. A zombie, exited but not yet reaped by
# its parent, does not count: it holds no socket and serves nothing, and
# `kill -0` alone would call it alive until its parent got round to it.
#
#   process_is_running <pid>
process_is_running() {
    local state
    read -r state _ <<< "$(_process_state_and_name "${1-}")"
    case "$state" in
        '' | Z*) return 1 ;;
    esac
    return 0
}

# True while <pid> is a running TBD daemon: a running process, not a zombie,
# whose executable is named TBDDaemon. The shell's counterpart of
# ProcessLiveness.isLiveNamedProcess, which the daemon's own single-instance
# gate and handover use.
#
#   daemon_process_is_running <pid>
#
# The name is what makes a pid read out of the pid file safe to wait on or to
# signal: after a crash or a reboot the file can name a pid the system has
# since handed to something unrelated, which no wait should hang on and no
# SIGKILL should reach. Only the executable counts: a debugger or an editor
# with a TBDDaemon path among its arguments is not a daemon. A zombie keeps
# its name, so the state is checked too.
daemon_process_is_running() {
    local state name
    read -r state name <<< "$(_process_state_and_name "${1-}")"
    case "$state" in
        '' | Z*) return 1 ;;
    esac
    [ "$name" = TBDDaemon ]
}

# Wait up to <seconds> for <pid> to stop being a running daemon.
#
#   wait_for_daemon_exit <pid> <seconds>
#
# <seconds> is a whole number. Polled in tenths of a second, the first poll
# before any sleep, as _wait_for_no_match is: a wait of 0 still looks once.
# Returns 0 once it is gone, 1 if it was still running at the last poll, and 2
# for a budget that is not a whole number.
wait_for_daemon_exit() {
    local pid="${1-}" seconds="${2-}" ticks
    _is_whole_number "$seconds" || return 2
    ticks=$((seconds * 10))
    while daemon_process_is_running "$pid"; do
        [ "$ticks" -gt 0 ] || return 1
        sleep 0.1
        ticks=$((ticks - 1))
    done
    return 0
}

# Stop the daemon running as <pid>, and wait until it has exited.
#
#   stop_daemon_process <pid> [grace_seconds] [kill_wait_seconds]
#
# SIGTERM first, then up to <grace_seconds> (default 30) for the daemon to
# finish its shutdown, then SIGKILL and up to <kill_wait_seconds> (default 5)
# more. The defaults are the budgets a successor daemon gives its predecessor
# in a handover (DaemonHandover.termBudget and killBudget): stop() is a
# sequence of awaits that releases every holder reader and stops both servers,
# and takes seconds. Both budgets are whole numbers, checked before anything
# is signalled.
#
# Signals only a pid daemon_process_is_running vouches for, so a stale pid
# cannot get an unrelated process killed.
#
# Prints one word saying how it ended, for the caller to report:
#   none      no daemon is running as <pid>, so nothing was signalled
#   stopped   it exited within the grace period after SIGTERM
#   killed    it outlived the grace period and exited after SIGKILL
#   survived  it is still running after SIGKILL
#   invalid   a budget was not a whole number, so nothing was signalled
# Returns 1 for `survived` and 2 for `invalid`.
stop_daemon_process() {
    local pid="${1-}"
    local grace="${2:-30}"
    local kill_wait="${3:-5}"

    if ! _is_whole_number "$grace" || ! _is_whole_number "$kill_wait"; then
        printf 'invalid\n'
        return 2
    fi
    if ! daemon_process_is_running "$pid"; then
        printf 'none\n'
        return 0
    fi
    kill -TERM "$pid" 2>/dev/null || true
    if wait_for_daemon_exit "$pid" "$grace"; then
        printf 'stopped\n'
        return 0
    fi
    kill -KILL "$pid" 2>/dev/null || true
    if wait_for_daemon_exit "$pid" "$kill_wait"; then
        printf 'killed\n'
        return 0
    fi
    printf 'survived\n'
    return 1
}

# Run <command> for at most <seconds>, a whole number above zero, and return
# its own status: 124, as timeout(1) returns, when it ran out of time and was
# stopped (SIGTERM, then SIGKILL a second later), and 125 for a malformed
# call. macOS has no timeout(1).
#
#   run_with_time_limit <seconds> <command> [args...]
#
# <command> must be an executable, not a shell function: the process stopped
# is the one `&` started, and a function's own children would outlive it. It
# is watched with `kill -0`, which is safe on a child of this shell: its pid
# stays its own until this shell reaps it in the `wait` below.
run_with_time_limit() {
    local limit="${1-}" pid ticks
    if [ "$#" -lt 2 ] || ! _is_pid "$limit"; then
        return 125
    fi
    shift
    "$@" &
    pid=$!
    ticks=$((limit * 10))
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -le 0 ]; then
            kill -TERM "$pid" 2>/dev/null
            ticks=10
            while kill -0 "$pid" 2>/dev/null && [ "$ticks" -gt 0 ]; do
                sleep 0.1
                ticks=$((ticks - 1))
            done
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.1
        ticks=$((ticks - 1))
    done
    wait "$pid"
}

# MARK: - Handing the daemon over
#
# scripts/update.sh and scripts/restart.sh replace the running daemon the same
# way. They start the new daemon with TBD_HANDOVER_FROM_PID naming the old one,
# and the new daemon does the rest: it writes its own pid over the pid file,
# retires the old daemon, and binds its sockets only once the old one has
# exited. With the new daemon's pid in the pid file from the first instant,
# the app's watchdog finds a live daemon there and starts no rescue daemon of
# its own. The scripts only wait, in two phases under one deadline. A deadline
# is a value of bash's SECONDS, which a subshell shares with its parent.
#
# Until the old daemon has exited, a reply on the socket can be the old
# daemon's. It goes on answering for the whole of its shutdown, after it has
# let go of every session, and a local build runs both daemons from the same
# file, so not even the executable path tells them apart. Once it is gone, a
# reply can only be the new daemon's. Hence the order: the old daemon's exit,
# then a reply.

# The pid a handover replaces: the one in the pid file under <tbd_home>
# (default $TBD_HOME, else ~/tbd, where the daemon and the CLI look too), or
# 0 when there is no file or no pid in it, which is a cold start. Whether that
# pid is still a daemon is for the new daemon to decide and for
# wait_for_predecessor_exit to watch.
#
#   handover_from_pid [tbd_home]
handover_from_pid() {
    local home="${1:-${TBD_HOME:-$HOME/tbd}}" pid
    pid="$(head -1 "$home/tbdd.pid" 2>/dev/null | tr -dc '0-9')"
    # A leading zero would read as octal later. The daemon never writes one.
    while [ "${pid#0}" != "$pid" ]; do
        pid="${pid#0}"
    done
    printf '%s\n' "${pid:-0}"
}

# Wait for the daemon a handover replaces to exit, giving up early if the new
# daemon dies first: a new daemon that dies never signals the old one, which
# would otherwise be waited on to the deadline.
#
#   wait_for_predecessor_exit <old_pid> <new_pid> <deadline>
#
# Polled every tenth of a second, and cheaply: both daemons are looked at with
# `kill -0`, a builtin that starts no process, and with the `ps` checks once a
# second, on the first look and every tenth one after. Those confirm the old
# daemon is still a daemon, not a zombie or a pid handed on, and catch a new
# one that has exited but is not yet reaped. `kill -0` fails on another user's
# process, but both daemons are this user's own. Prints one word:
#   none              <old_pid> named no running daemon at the first look: a
#                     cold start (<old_pid> 0), or a stale pid file
#   exited            it was running, and has exited
#   successor-exited  <new_pid> stopped running while the old daemon still ran
#   timeout           the old daemon was still running at <deadline>
#   invalid           <deadline> is not a whole number, or <new_pid> no pid
# Returns 0 for `none` and `exited`, 1 for the failures and 2 for `invalid`.
wait_for_predecessor_exit() {
    local old_pid="${1-}" new_pid="${2-}" deadline="${3-}" seen=false ticks=0
    if ! _is_whole_number "$deadline" || ! _is_pid "$new_pid"; then
        printf 'invalid\n'
        return 2
    fi
    while :; do
        if [ $((ticks % 10)) -eq 0 ]; then
            daemon_process_is_running "$old_pid" || break
        else
            kill -0 "$old_pid" 2>/dev/null || break
        fi
        seen=true
        if ! kill -0 "$new_pid" 2>/dev/null ||
            { [ $((ticks % 10)) -eq 0 ] && ! process_is_running "$new_pid"; }; then
            printf 'successor-exited\n'
            return 1
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            printf 'timeout\n'
            return 1
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    if [ "$seen" = true ]; then
        printf 'exited\n'
    else
        printf 'none\n'
    fi
}

# Wait until <command>, the caller's test that the new daemon answers,
# succeeds, giving up early if the new daemon dies. <command> runs with its
# output discarded, at least once even past <deadline>, then every
# <poll_seconds> (a number above zero; fractions allowed). Each run is cut off
# after <probe_seconds> (run_with_time_limit), so a daemon that accepts a
# connection and never replies cannot hold the wait past its deadline by more
# than one probe. <command> is therefore an executable, not a shell function.
#
#   wait_until_daemon_ready <new_pid> <deadline> <poll_seconds> <probe_seconds> <command> [args...]
#
# Prints one word:
#   ready             <command> succeeded
#   successor-exited  <new_pid> stopped running first
#   timeout           <command> had not succeeded by <deadline>
#   invalid           a malformed argument, or no <command>
# Returns 0 for `ready`, 1 for the failures and 2 for `invalid`.
wait_until_daemon_ready() {
    local new_pid="${1-}" deadline="${2-}" poll="${3-}" probe="${4-}"
    if [ "$#" -lt 5 ] || ! _is_pid "$new_pid" || ! _is_whole_number "$deadline" ||
        ! _is_positive_interval "$poll" || ! _is_pid "$probe"; then
        printf 'invalid\n'
        return 2
    fi
    shift 4
    while :; do
        if run_with_time_limit "$probe" "$@" > /dev/null 2>&1; then
            printf 'ready\n'
            return 0
        fi
        if ! process_is_running "$new_pid"; then
            printf 'successor-exited\n'
            return 1
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            printf 'timeout\n'
            return 1
        fi
        sleep "$poll"
    done
}

# Both phases of a handover under one <timeout> in whole seconds: the old
# daemon's exit, then <command>, which runs only once the old daemon is gone.
#
#   wait_for_daemon_handover <old_pid> <new_pid> <timeout> <poll_seconds> <probe_seconds> <command> [args...]
#
# Prints the two phases' words on one line, wait_for_predecessor_exit's then
# wait_until_daemon_ready's, with `skipped` for a second phase that never ran:
# `exited ready`, `none ready`, `timeout skipped`, `exited successor-exited`
# and so on, or `invalid skipped` for a malformed call. Returns 0 only when it
# ends `ready`.
wait_for_daemon_handover() {
    local old_pid="${1-}" new_pid="${2-}" timeout="${3-}" poll="${4-}" probe="${5-}"
    local deadline predecessor ready=skipped
    if [ "$#" -lt 6 ] || ! _is_whole_number "$timeout"; then
        printf 'invalid skipped\n'
        return 2
    fi
    shift 5
    deadline=$((SECONDS + timeout))
    predecessor="$(wait_for_predecessor_exit "$old_pid" "$new_pid" "$deadline")"
    case "$predecessor" in
        exited | none)
            ready="$(wait_until_daemon_ready "$new_pid" "$deadline" "$poll" "$probe" "$@")"
            ;;
    esac
    printf '%s %s\n' "$predecessor" "$ready"
    [ "$ready" = ready ]
}

# What a restart does with wait_for_daemon_handover's answer: print the line
# that reports it, and return 0 to go on to the app or 1 to stop.
#
#   describe_daemon_handover <outcome> <old_pid> <new_pid> <timeout> <log_path>
#
# Going on is right only once the old daemon is gone, because until then an
# app reaches the old daemon on its way out, and only while the new daemon
# still runs. A new daemon that runs but has not answered yet is a warning,
# not a stop: the app retries until it does. Everything else stops, an outcome
# this does not recognise included, so a malformed answer can never pass for a
# good one.
describe_daemon_handover() {
    local outcome="${1-}" old_pid="${2-}" new_pid="${3-}" timeout="${4-}" log_path="${5-}"
    case "$outcome" in
        'exited ready' | 'none ready')
            printf 'Daemon ready (PID %s)\n' "$new_pid"
            return 0
            ;;
        'exited timeout' | 'none timeout')
            printf 'WARNING: the daemon (PID %s) is running but did not answer within %ss — see %s\n' \
                "$new_pid" "$timeout" "$log_path"
            return 0
            ;;
        'successor-exited skipped')
            printf 'ERROR: the new daemon (PID %s) exited while the old one (PID %s) was still running — see %s\n' \
                "$new_pid" "$old_pid" "$log_path"
            return 1
            ;;
        'exited successor-exited' | 'none successor-exited')
            printf 'ERROR: the new daemon (PID %s) exited before it answered — see %s\n' \
                "$new_pid" "$log_path"
            return 1
            ;;
        'timeout skipped')
            printf 'ERROR: the old daemon (PID %s) was still running after %ss — see %s\n' \
                "$old_pid" "$timeout" "$log_path"
            return 1
            ;;
        *)
            printf 'ERROR: the daemon handover ended in an unrecognised way: [%s] — see %s\n' \
                "$outcome" "$log_path"
            return 1
            ;;
    esac
}

# Replace the running daemon with <daemon_bin> by a handover, the whole of
# scripts/restart.sh's daemon step, and say how it went.
#
#   restart_daemon_by_handover <tbd_home> <daemon_bin> <log_path> <timeout> <probe_seconds> <ready_command> [args...]
#
# The daemon replaced is the one <tbd_home>'s pid file names
# (handover_from_pid), and <ready_command> is the test that the new daemon
# answers, run once the old one is gone (wait_for_daemon_handover), every 0.2
# seconds and cut off after <probe_seconds> each time. The previous log at
# <log_path> is kept as <log_path>.1: the daemon does not persist os.Logger
# output, so that file is the only record of a crash before the restart.
#
# Progress goes to stdout and a failure to stderr. Returns 0 when the caller
# may go on to the app (describe_daemon_handover) and 1 when it must stop. A
# stop first stops the new daemon if it is still running, so a refused or
# abandoned handover does not leave it behind, waiting on the old daemon or
# serving beside it.
restart_daemon_by_handover() {
    local tbd_home="${1-}" daemon_bin="${2-}" log_path="${3-}" timeout="${4-}" probe="${5-}"
    local old_pid new_pid outcome report stop
    if [ "$#" -lt 6 ]; then
        printf 'ERROR: restart_daemon_by_handover needs a TBD home, a daemon, a log, a budget, a probe limit and a readiness test\n' >&2
        return 1
    fi
    shift 5
    old_pid="$(handover_from_pid "$tbd_home")"
    if [ -f "$log_path" ]; then
        mv "$log_path" "$log_path.1"
    fi
    if [ "$old_pid" = 0 ]; then
        printf 'Starting daemon...\n'
    else
        printf 'Starting daemon, handing over from PID %s...\n' "$old_pid"
    fi
    TBD_HANDOVER_FROM_PID="$old_pid" "$daemon_bin" > "$log_path" 2>&1 &
    new_pid=$!

    outcome="$(wait_for_daemon_handover "$old_pid" "$new_pid" "$timeout" 0.2 "$probe" "$@")"
    if report="$(describe_daemon_handover "$outcome" "$old_pid" "$new_pid" "$timeout" "$log_path")"; then
        printf '  %s\n' "$report"
        return 0
    fi
    printf '  %s\n' "$report" >&2
    stop="$(stop_daemon_process "$new_pid" 5 3)"
    case "$stop" in
        none) ;;
        stopped | killed)
            printf '  Stopped the new daemon (PID %s): %s\n' "$new_pid" "$stop" >&2
            ;;
        *)
            printf '  WARNING: could not stop the new daemon (PID %s): %s\n' "$new_pid" "$stop" >&2
            ;;
    esac
    return 1
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

# Seed the saved tmux fallback with the installing shell's tmux.
#
#   seed_tmux_fallback <tbd_home>
#
# LaunchServices ignores LSEnvironment.PATH on a login relaunch, so a
# package-manager tmux is invisible to that launch. The saved fallback is what
# the resolver consults next; write it from this shell unless it already names
# a usable executable, so a user's Locate or Settings choice always survives.
# Never fails the install: without tmux here, warn and let the app prompt.
# See docs/specs/2026-09-22-tmux-fallback-install-seeding-design.md.
seed_tmux_fallback() {
    local tbd_home="${1-}"
    if [ -z "$tbd_home" ]; then
        echo "error: seed_tmux_fallback needs a tbd home" >&2
        return 1
    fi
    local file="$tbd_home/tmux-executable-path"
    local saved=""
    if [ -f "$file" ]; then
        # Trim surrounding whitespace and newlines, as the Swift reader does.
        # An unreadable file counts as unusable; under set -e a failed read
        # must not abort the install.
        saved="$(cat "$file" 2>/dev/null)" || saved=""
        saved="${saved#"${saved%%[![:space:]]*}"}"
        saved="${saved%"${saved##*[![:space:]]}"}"
    fi
    if _is_absolute_regular_executable "$saved"; then
        return 0
    fi
    local found
    found="$(command -v tmux 2>/dev/null || true)"
    if ! _is_absolute_regular_executable "$found"; then
        echo "warning: tmux not found on PATH; TBD will ask you to locate it" >&2
        return 0
    fi
    local unsaved="warning: could not save $found to $file; TBD may ask you to locate tmux"
    # A directory at the file's path would swallow the mv below.
    if [ -d "$file" ] || ! mkdir -p "$tbd_home" 2>/dev/null; then
        echo "$unsaved" >&2
        return 0
    fi
    local tmp
    if ! tmp="$(mktemp "$file.tmp.XXXXXX" 2>/dev/null)"; then
        echo "$unsaved" >&2
        return 0
    fi
    if printf '%s' "$found" > "$tmp" && mv -f "$tmp" "$file"; then
        return 0
    fi
    rm -f "$tmp"
    echo "$unsaved" >&2
    return 0
}

# True when <path> is absolute and, after following symlinks, a regular file
# that is executable: the rule TmuxExecutableResolver applies to a saved path.
_is_absolute_regular_executable() {
    case "${1-}" in /*) ;; *) return 1 ;; esac
    [ -f "$1" ] && [ -x "$1" ]
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
