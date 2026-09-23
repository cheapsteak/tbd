#!/usr/bin/env bash
# Release-download helpers for scripts/update.sh. Safe to source: defines
# functions only, downloads and installs nothing on its own.
#
# The release workflow (.github/workflows/release.yml) builds every runtime
# product for a commit on main and publishes it to one rolling prerelease. This
# file is the installing half: find the newest published commit, download it,
# verify it, and unpack it into ~/tbd/updates/prebuilt/<commit>. Everything
# after that — bundle assembly, local signing, the handover, the wake — is the
# same code a local build goes through. Design:
# docs/specs/2026-09-23-release-pipeline-design.md.
#
# Every function takes the paths it acts on as parameters, and reads the
# release location from the constants update.sh defines (RELEASE_TAG,
# RELEASE_WALKBACK, RELEASE_WORKFLOW_PATH), so scripts/update.test.sh can drive
# each one against a temp directory with stubbed `curl`, `gh` and `uname`.

# Status codes acquire_release_build returns. Named so the caller's case
# statement reads as the decision it is.
RELEASE_OK=0
RELEASE_VERIFY_FAILED=4
RELEASE_UNAVAILABLE=3
RELEASE_UNSUPPORTED_ARCH=5
RELEASE_ALREADY_CURRENT=6

# What the release workflow publishes, and what is still built here. Together
# they are RUNTIME_PRODUCTS (scripts/restart-bundle-lib.sh); the harness checks
# that. TBDApp stays local for one reason: SwiftPM's generated
# `Bundle.module` accessor looks for a resource bundle at the app bundle's
# root (Bundle.main.bundleURL), then at an absolute build path baked in at
# compile time, and assemble_app_bundle stages the bundles in
# Contents/Resources. An installed app therefore resolves its own resources,
# and Highlightr's, only through the build path — which exists on the machine
# that compiled it and nowhere else, so a CI-built TBDApp would stop on its
# first resource lookup. The executables here have no such problem: each is
# its own Bundle.main, and its bundles sit beside it. Bringing TBDApp into the
# asset needs the resource lookups made relocatable first.
# shellcheck disable=SC2034 # read by update.sh and scripts/ci/package-release.sh
RELEASE_PRODUCTS=(TBDDaemon TBDCLI TBDHolder TBDPeerHelper TBDModelProxy)
# shellcheck disable=SC2034 # read by update.sh
RELEASE_LOCAL_PRODUCTS=(TBDApp)

# The architecture the workflow publishes. A machine that is not this builds
# locally, in every mode: a download can never serve it, so "try again later"
# would mean never.
RELEASE_ARCH=arm64

# The asset for one commit. The name carries the full commit, so no lookup is
# needed to find it: the URL is a pure function of the commit.
release_asset_name() {
    printf 'tbd-%s-macos-%s.tar.gz\n' "${1-}" "$RELEASE_ARCH"
}

# <owner>/<repo> for a GitHub remote URL, or non-zero for anything else.
# TBD_RELEASE_REPO overrides it: a fork that publishes nothing can point its
# updates at the upstream's releases, and the harness at a fixture.
release_repo_slug() {
    local url="${1-}" slug
    if [ -n "${TBD_RELEASE_REPO:-}" ]; then
        printf '%s\n' "$TBD_RELEASE_REPO"
        return 0
    fi
    case "$url" in
        https://github.com/*) slug="${url#https://github.com/}" ;;
        git@github.com:*) slug="${url#git@github.com:}" ;;
        ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
        *) return 1 ;;
    esac
    slug="${slug%/}"
    slug="${slug%.git}"
    case "$slug" in
        */*/*|/*|*/|"") return 1 ;;
        */*) printf '%s\n' "$slug" ;;
        *) return 1 ;;
    esac
}

# Where the rolling prerelease serves its assets. A download URL, not an API
# call, so the unauthenticated API rate limit never applies.
release_base_url() {
    if [ -n "${TBD_RELEASE_BASE_URL:-}" ]; then
        printf '%s\n' "$TBD_RELEASE_BASE_URL"
        return 0
    fi
    printf 'https://github.com/%s/releases/download/%s\n' "${1-}" "$RELEASE_TAG"
}

machine_arch() {
    uname -m 2>/dev/null
}

# Fetch one URL to a file. Non-zero on any HTTP error, 404 included.
release_fetch() {
    local url="${1-}" out="${2-}"
    curl --fail --silent --show-error --location --retry 2 \
        --connect-timeout 20 --max-time 600 -o "$out" "$url"
}

# The newest commit on the clone's first-parent history, starting at HEAD,
# that has a published checksum. Leaves the checksum at <workdir>/<commit>.sha256
# and echoes the commit. Non-zero when none of the last RELEASE_WALKBACK
# commits has one.
find_release_commit() {
    local repo="${1-}" base_url="${2-}" workdir="${3-}"
    local commit asset
    while IFS= read -r commit; do
        [ -n "$commit" ] || continue
        asset="$(release_asset_name "$commit")"
        if release_fetch "$base_url/$asset.sha256" "$workdir/$commit.sha256" 2>/dev/null; then
            printf '%s\n' "$commit"
            return 0
        fi
        rm -f "$workdir/$commit.sha256"
    done < <(git -C "$repo" rev-list --first-parent -n "$RELEASE_WALKBACK" HEAD 2>/dev/null)
    return 1
}

sha256_of() {
    shasum -a 256 "${1-}" 2>/dev/null | awk '{print $1}'
}

# True when <file>'s SHA-256 is the first field of <sum_file>.
verify_checksum() {
    local file="${1-}" sum_file="${2-}" expected actual
    expected="$(awk 'NR == 1 {print $1}' "$sum_file" 2>/dev/null)"
    actual="$(sha256_of "$file")"
    [ -n "$expected" ] && [ "$expected" = "$actual" ]
}

# Can this machine check an attestation at all? `gh` has to be installed and
# signed in: verification reads the attestation through the GitHub API.
attestation_tooling_available() {
    command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
}

# Verify the build-provenance attestation for <file>: that it was produced by
# RELEASE_WORKFLOW_PATH in <slug>. Returns 0 when verified, 1 when gh says no
# (a missing attestation included), 2 when this machine cannot ask.
verify_attestation() {
    local file="${1-}" slug="${2-}"
    attestation_tooling_available || return 2
    gh attestation verify "$file" --repo "$slug" \
        --signer-workflow "$slug/$RELEASE_WORKFLOW_PATH" >/dev/null 2>&1 || return 1
    return 0
}

# Check an unpacked tree against its manifest.json: the commit and architecture
# it names, every file's SHA-256, no file the manifest does not list, no
# symlink, and every published product present and executable. Prints the reason
# on failure.
verify_manifest() {
    local tree="${1-}" commit="${2-}" arch="${3-}"
    python3 - "$tree" "$commit" "$arch" "${RELEASE_PRODUCTS[@]}" << 'EOF'
import hashlib, json, os, sys

tree, commit, arch = sys.argv[1], sys.argv[2], sys.argv[3]
products = sys.argv[4:]

def bail(reason):
    print(reason)
    sys.exit(1)

try:
    with open(os.path.join(tree, "manifest.json")) as fh:
        manifest = json.load(fh)
except Exception as exc:
    bail(f"manifest.json unreadable: {exc}")

if manifest.get("commit") != commit:
    bail(f"manifest names commit {manifest.get('commit')!r}, expected {commit}")
if manifest.get("arch") != arch:
    bail(f"manifest names arch {manifest.get('arch')!r}, expected {arch}")
listed = manifest.get("files")
if not isinstance(listed, dict) or not listed:
    bail("manifest lists no files")

seen = set()
for root, dirs, files in os.walk(tree, followlinks=False):
    for name in dirs + files:
        path = os.path.join(root, name)
        if os.path.islink(path):
            bail(f"symlink in the download: {os.path.relpath(path, tree)}")
    for name in files:
        rel = os.path.relpath(os.path.join(root, name), tree)
        if rel == "manifest.json":
            continue
        if rel not in listed:
            bail(f"file not in the manifest: {rel}")
        digest = hashlib.sha256()
        with open(os.path.join(root, name), "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                digest.update(chunk)
        if digest.hexdigest() != listed[rel]:
            bail(f"checksum mismatch: {rel}")
        seen.add(rel)

missing = sorted(set(listed) - seen)
if missing:
    bail(f"manifest lists files the download lacks: {', '.join(missing[:5])}")
for product in products:
    path = os.path.join(tree, product)
    if not (os.path.isfile(path) and os.access(path, os.X_OK)):
        bail(f"runtime product missing or not executable: {product}")
EOF
}

# One manifest field, or nothing.
manifest_field() {
    python3 -c '
import json, sys
try:
    value = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    sys.exit(1)
if value is None:
    sys.exit(1)
print(value)
' "${1-}/manifest.json" "${2-}" 2>/dev/null
}

# Add the release's provenance to the sidecar write_build_identity stamped:
# where the binaries came from, the CI run that built them, the build time CI
# recorded rather than the install time, and which products were still built
# here. Older binaries ignore unknown keys.
stamp_release_provenance() {
    local sidecar="${1-}" run_url="${2-}" built_at="${3-}"
    python3 - "$sidecar" "$run_url" "$built_at" "${RELEASE_LOCAL_PRODUCTS[@]}" << 'EOF'
import json, sys
path, run_url, built_at = sys.argv[1:4]
local_products = sys.argv[4:]
with open(path) as fh:
    identity = json.load(fh)
identity["provenance"] = "release"
identity["locallyBuiltProducts"] = local_products
if run_url:
    identity["releaseRun"] = run_url
if built_at:
    identity["builtAt"] = built_at
with open(path, "w") as fh:
    json.dump(identity, fh, indent=2)
    fh.write("\n")
EOF
}

# Copy what this machine built — RELEASE_LOCAL_PRODUCTS and any resource
# bundle the download does not already carry — from SwiftPM's build directory
# into a verified download, so the tree holds every runtime product. Copies,
# not hard links: the next local build rewrites those files in place.
merge_local_products() {
    local local_dir="${1-}" tree="${2-}" product bundle name
    for product in "${RELEASE_LOCAL_PRODUCTS[@]}"; do
        [ -x "$local_dir/$product" ] || return 1
        rm -f "$tree/$product"
        cp -p "$local_dir/$product" "$tree/$product" || return 1
    done
    for bundle in "$local_dir"/*.bundle; do
        [ -d "$bundle" ] || continue
        name="$(basename "$bundle")"
        case "$name" in
            *Tests.bundle) continue ;;
        esac
        [ -e "$tree/$name" ] && continue
        cp -R "$bundle" "$tree/$name" || return 1
    done
}

# The real directory a local build wrote to: SwiftPM's own .build/<config>
# link resolved, whatever it currently names.
swiftpm_build_dir() {
    local repo="${1-}" config="${2-}" resolved
    resolved="$(cd "$repo/.build/$config" 2>/dev/null && pwd -P)" || return 1
    printf '%s\n' "$resolved"
}

# Where a symlink at <link> points, or nothing when it is not a symlink.
link_target() {
    [ -L "${1-}" ] || return 1
    /usr/bin/readlink "${1-}" 2>/dev/null || readlink "${1-}"
}

# Point the clone's .build/release at a prebuilt tree. That path is where
# every consumer already looks — the handover, the app's reboot respawn via
# <sourceWorktree>/.build/release/TBDDaemon, the CLI hard link — so pointing it
# is the whole of "installing" the download on disk. Refuses when a real
# directory sits there: that is a local build's output, and replacing it would
# break the next incremental build.
point_release_link() {
    local link="${1-}" target="${2-}" tmp
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        return 1
    fi
    mkdir -p "$(dirname "$link")" || return 1
    tmp="$link.new.$$"
    rm -f "$tmp"
    ln -s "$target" "$tmp" || return 1
    # rename(2) over the old link, so the path is never absent. Not `mv`: with
    # a link to a directory as its destination, mv moves the new link INTO
    # that directory; rename(2) replaces the link itself.
    python3 -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$tmp" "$link" 2>/dev/null \
        || { rm -f "$tmp"; return 1; }
}

# Before a local build, hand .build/release back to SwiftPM. A link into the
# prebuilt home is removed so SwiftPM recreates its own; anything else is left
# exactly as it is.
release_link_yield_to_swiftpm() {
    local link="${1-}" prebuilt_home="${2-}" target
    target="$(link_target "$link")" || return 0
    case "$target" in
        "$prebuilt_home"/*) rm -f "$link" ;;
    esac
}

# Put .build/release back at <previous> when that was a download: after a
# local build that did not lead to an install, the running daemon's tree is
# the one a reboot must respawn. A previous target that was SwiftPM's own
# directory is SwiftPM's again already.
restore_release_link() {
    local link="${1-}" previous="${2-}"
    case "$previous" in
        "$PREBUILT_HOME"/*) point_release_link "$link" "$previous" ;;
    esac
    return 0
}

# Delete every prebuilt tree except the ones named. The reconciler for
# ~/tbd/updates/prebuilt: the same script that creates an entry prunes the
# rest, so the directory holds at most the running build and the one it
# replaced.
prune_prebuilt() {
    local home="${1-}"
    shift
    local entry keep keep_it
    [ -d "$home" ] || return 0
    for entry in "$home"/*; do
        [ -e "$entry" ] || continue
        keep_it=false
        for keep in "$@"; do
            [ -n "$keep" ] && [ "$entry" = "$keep" ] && keep_it=true
        done
        [ "$keep_it" = true ] || rm -rf "$entry"
    done
}

# Remove downloads a killed run left half-done. Called under the update lock,
# so no other run can be writing one.
sweep_partial_downloads() {
    local home="${1-}" entry
    [ -d "$home" ] || return 0
    for entry in "$home"/*.partial; do
        [ -e "$entry" ] && rm -rf "$entry"
    done
}

# Find, download, verify and unpack the newest published build.
#
#   acquire_release_build <clone> <remote_url> <running_commit> <prebuilt_home> <require_attestation>
#
# On success sets RELEASE_COMMIT and RELEASE_TREE, leaves the clone detached at
# RELEASE_COMMIT, and returns RELEASE_OK. Otherwise returns one of the codes at
# the top of this file and installs nothing. Logs through update.sh's `log`.
acquire_release_build() {
    local clone="${1-}" remote_url="${2-}" running="${3-}" home="${4-}" require_attest="${5-}"
    local slug base_url commit partial asset tree attest_status reason arch

    RELEASE_COMMIT=""
    RELEASE_TREE=""

    arch="$(machine_arch)"
    if [ "$arch" != "$RELEASE_ARCH" ]; then
        log "release builds are $RELEASE_ARCH only; this machine is ${arch:-unknown}"
        return "$RELEASE_UNSUPPORTED_ARCH"
    fi

    if ! slug="$(release_repo_slug "$remote_url")"; then
        log "the update remote $remote_url is not a GitHub repository; no release to download"
        return "$RELEASE_UNAVAILABLE"
    fi
    base_url="$(release_base_url "$slug")"

    mkdir -p "$home" || return "$RELEASE_UNAVAILABLE"
    sweep_partial_downloads "$home"
    partial="$home/download.partial"
    mkdir -p "$partial" || return "$RELEASE_UNAVAILABLE"

    log "looking for a published build of the last $RELEASE_WALKBACK commits on main in $slug"
    if ! commit="$(find_release_commit "$clone" "$base_url" "$partial")"; then
        rm -rf "$partial"
        log "no published build for any of the last $RELEASE_WALKBACK commits on main"
        return "$RELEASE_UNAVAILABLE"
    fi
    log "newest published build is $commit"

    # Never move backwards. A running build at or past the newest published
    # one is already up to date as far as a download can tell.
    if [ -n "$running" ] && { [ "$running" = "$commit" ] ||
        git -C "$clone" merge-base --is-ancestor "$commit" "$running" >/dev/null 2>&1; }; then
        rm -rf "$partial"
        return "$RELEASE_ALREADY_CURRENT"
    fi

    asset="$(release_asset_name "$commit")"
    log "downloading $asset"
    if ! release_fetch "$base_url/$asset" "$partial/$asset"; then
        rm -rf "$partial"
        log "the checksum for $commit is published but its archive could not be downloaded"
        return "$RELEASE_UNAVAILABLE"
    fi

    if ! verify_checksum "$partial/$asset" "$partial/$commit.sha256"; then
        rm -rf "$partial"
        log_error "checksum mismatch for $asset — refusing to install it"
        return "$RELEASE_VERIFY_FAILED"
    fi
    log "checksum verified"

    attest_status=0
    verify_attestation "$partial/$asset" "$slug" || attest_status=$?
    case "$attest_status" in
        0) log "build provenance verified: built by $RELEASE_WORKFLOW_PATH in $slug" ;;
        1)
            rm -rf "$partial"
            log_error "build provenance did not verify for $asset — refusing to install it"
            return "$RELEASE_VERIFY_FAILED"
            ;;
        *)
            if [ "$require_attest" = true ]; then
                rm -rf "$partial"
                log_error "an unattended update requires a verified build provenance, and gh is not installed or not signed in — refusing to install $asset"
                return "$RELEASE_VERIFY_FAILED"
            fi
            log "WARNING: gh is not installed or not signed in, so the build provenance was not checked; installing on the checksum alone"
            ;;
    esac

    mkdir -p "$partial/unpack" || return "$RELEASE_UNAVAILABLE"
    if ! tar -xzf "$partial/$asset" -C "$partial/unpack" 2>/dev/null; then
        rm -rf "$partial"
        log_error "could not unpack $asset — refusing to install it"
        return "$RELEASE_VERIFY_FAILED"
    fi
    tree="$partial/unpack/tbd-$commit-macos-$RELEASE_ARCH"
    if [ ! -d "$tree" ]; then
        rm -rf "$partial"
        log_error "$asset does not contain tbd-$commit-macos-$RELEASE_ARCH/ — refusing to install it"
        return "$RELEASE_VERIFY_FAILED"
    fi
    if ! reason="$(verify_manifest "$tree" "$commit" "$RELEASE_ARCH")"; then
        rm -rf "$partial"
        log_error "the download does not match its manifest ($reason) — refusing to install it"
        return "$RELEASE_VERIFY_FAILED"
    fi
    log "every file matches the manifest"

    # A browser download would carry the quarantine attribute, and Gatekeeper
    # assesses quarantined executables. curl sets none; clear it regardless.
    if command -v xattr >/dev/null 2>&1; then
        xattr -dr com.apple.quarantine "$tree" 2>/dev/null || true
    fi

    # The clone describes the commit being installed: the build identity,
    # Resources/ for the bundle and the scripts a later `tbd update` runs all
    # come from it.
    if ! git -C "$clone" checkout --quiet --detach "$commit"; then
        rm -rf "$partial"
        log_error "could not check the update clone out at $commit"
        return "$RELEASE_UNAVAILABLE"
    fi

    rm -rf "${home:?}/$commit"
    if ! mv "$tree" "$home/$commit"; then
        rm -rf "$partial"
        log_error "could not move the download into $home/$commit"
        return "$RELEASE_UNAVAILABLE"
    fi
    rm -rf "$partial"

    # shellcheck disable=SC2034 # results for the caller in update.sh
    RELEASE_COMMIT="$commit"
    # shellcheck disable=SC2034
    RELEASE_TREE="$home/$commit"
    return "$RELEASE_OK"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "error: source this helper from update.sh or its test harness" >&2
    exit 64
fi
