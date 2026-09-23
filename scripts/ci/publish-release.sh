#!/usr/bin/env bash
# Publish a packaged, attested build to the rolling `main-builds` prerelease.
# Run by the publish job of .github/workflows/release.yml, with GH_TOKEN and
# GH_REPO set; runs nowhere else.
#
#   scripts/ci/publish-release.sh <dist_dir> <commit>
#
# Three steps, in this order:
#
#   1. Upload the archive and its checksum. The asset name carries the commit,
#      so an upload never replaces another commit's build.
#   2. Move the `main-builds` tag to <commit>, but only forward along main. The
#      daemon's update check reads that tag (while the update source is
#      `release`), so it must only ever name a commit whose build is already
#      published — which is why this comes after the upload — and must never
#      move backwards when an older commit is backfilled.
#   3. Prune: keep the newest RELEASE_KEEP commits' assets, and always the
#      tagged commit's. This is the reconciler for the remote assets: a missed
#      prune leaves extra assets, and the next publish removes them.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../update-release-lib.sh"

dist="${1:?dist dir}"
commit="${2:?commit}"
: "${GH_REPO:?GH_REPO must name the repository}"

# The tag and prerelease every published build lives under. Must match
# RELEASE_TAG in scripts/update.sh.
tag="${RELEASE_TAG_NAME:-main-builds}"
keep="${RELEASE_KEEP:-20}"

asset="$(release_asset_name "$commit")"
[ -f "$dist/$asset" ] || { echo "error: $dist/$asset is missing" >&2; exit 1; }
[ -f "$dist/$asset.sha256" ] || { echo "error: $dist/$asset.sha256 is missing" >&2; exit 1; }

if ! gh release view "$tag" >/dev/null 2>&1; then
    # First publish ever: creating the release creates the tag at this commit.
    gh release create "$tag" --prerelease --latest=false --target "$commit" \
        --title "main builds" \
        --notes "Release builds of recent commits on main, for \`tbd update --from-release\`. The tag names the newest published commit. Assets are named by commit; each has a .sha256 and a build-provenance attestation (\`gh attestation verify <archive> --repo $GH_REPO\`). This is not a versioned release."
fi

# 1. Upload.
gh release upload "$tag" "$dist/$asset" "$dist/$asset.sha256" --clobber
echo "uploaded $asset"

# 2. Move the tag forward.
current="$(gh api "repos/$GH_REPO/git/ref/tags/$tag" --jq '.object.sha' 2>/dev/null || true)"
if [ -z "$current" ]; then
    gh api -X POST "repos/$GH_REPO/git/refs" -f "ref=refs/tags/$tag" -f "sha=$commit" >/dev/null
    echo "created $tag at $commit"
elif [ "$current" = "$commit" ]; then
    echo "$tag already names $commit"
elif git merge-base --is-ancestor "$current" "$commit" 2>/dev/null; then
    gh api -X PATCH "repos/$GH_REPO/git/refs/tags/$tag" -f "sha=$commit" -F force=true >/dev/null
    echo "moved $tag from $current to $commit"
else
    echo "$tag stays at $current: $commit is not newer on main"
fi
tagged="$(gh api "repos/$GH_REPO/git/ref/tags/$tag" --jq '.object.sha' 2>/dev/null || true)"

# 3. Prune.
gh release view "$tag" --json assets --jq '.assets[] | [.name, .createdAt] | @tsv' \
    | python3 -c '
import re, sys
keep, tagged = int(sys.argv[1]), sys.argv[2]
newest = {}
names = {}
for line in sys.stdin:
    name, created = line.rstrip("\n").split("\t")
    match = re.match(r"tbd-([0-9a-f]{40})-macos-", name)
    if not match:
        continue
    commit = match.group(1)
    newest[commit] = max(newest.get(commit, ""), created)
    names.setdefault(commit, []).append(name)
ranked = sorted(newest, key=newest.get, reverse=True)
kept = set(ranked[:keep]) | {tagged}
for commit in ranked:
    if commit not in kept:
        for name in names[commit]:
            print(name)
' "$keep" "$tagged" \
    | while IFS= read -r stale; do
        [ -n "$stale" ] || continue
        gh release delete-asset "$tag" "$stale" --yes
        echo "pruned $stale"
    done
