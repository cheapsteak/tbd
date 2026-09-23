#!/usr/bin/env bash
# Package a finished release build for publishing. Run by
# .github/workflows/release.yml after the products are built; runs nowhere
# else.
#
#   scripts/ci/package-release.sh <build_dir> <commit> <out_dir>
#
# Stages every product in RELEASE_PRODUCTS (scripts/update-release-lib.sh) and
# every resource bundle beside them into tbd-<commit>-macos-arm64/, writes
# manifest.json with a SHA-256 per file, and archives it as
# <out_dir>/tbd-<commit>-macos-arm64.tar.gz plus a .sha256 beside it. The
# installer (acquire_release_build) checks all three.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../update-release-lib.sh"

build_dir="${1:?build dir}"
commit="${2:?commit}"
out_dir="${3:?out dir}"

case "$commit" in
    [0-9a-f]*) ;;
    *) echo "error: $commit is not a commit" >&2; exit 64 ;;
esac
if [ "${#commit}" -ne 40 ]; then
    echo "error: $commit is not a full 40-character commit" >&2
    exit 64
fi

name="tbd-$commit-macos-$RELEASE_ARCH"
stage_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tbd-package.XXXXXX")"
stage="$stage_root/$name"
mkdir -p "$stage" "$out_dir"

for product in "${RELEASE_PRODUCTS[@]}"; do
    if [ ! -x "$build_dir/$product" ]; then
        echo "error: $build_dir/$product was not built" >&2
        exit 1
    fi
    cp -p "$build_dir/$product" "$stage/$product"
done

# Every resource bundle the build produced, minus test fixtures — the same
# exclusion assemble_app_bundle applies. A shipped executable finds its
# bundles beside itself (Bundle.main.bundleURL is its own directory), so they
# travel next to the binaries, not in a subdirectory.
for bundle in "$build_dir"/*.bundle; do
    [ -d "$bundle" ] || continue
    case "$(basename "$bundle")" in
        *Tests.bundle) continue ;;
    esac
    cp -R "$bundle" "$stage/"
done

python3 - "$stage" "$commit" "$RELEASE_ARCH" "${RELEASE_PRODUCTS[@]}" << 'EOF'
import hashlib, json, os, subprocess, sys
from datetime import datetime, timezone

stage, commit, arch = sys.argv[1:4]
products = sys.argv[4:]

def run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return ""

files = {}
for root, dirs, names in os.walk(stage):
    for n in dirs + names:
        if os.path.islink(os.path.join(root, n)):
            sys.exit(f"symlink in the staged build: {os.path.join(root, n)}")
    for n in names:
        path = os.path.join(root, n)
        digest = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                digest.update(chunk)
        files[os.path.relpath(path, stage)] = digest.hexdigest()

server = os.environ.get("GITHUB_SERVER_URL", "")
repo = os.environ.get("GITHUB_REPOSITORY", "")
run_id = os.environ.get("GITHUB_RUN_ID", "")
manifest = {
    "schema": 1,
    "commit": commit,
    "arch": arch,
    "builtAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "products": products,
    "swift": run("xcrun", "swift", "--version").splitlines()[0] if run("xcrun", "swift", "--version") else "",
    "xcode": run("xcodebuild", "-version").replace("\n", " "),
    "macos": run("sw_vers", "-productVersion"),
    "runnerImage": os.environ.get("ImageOS", "") + " " + os.environ.get("ImageVersion", ""),
    "runUrl": f"{server}/{repo}/actions/runs/{run_id}" if server and repo and run_id else "",
    "files": files,
}
with open(os.path.join(stage, "manifest.json"), "w") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=True)
    fh.write("\n")
EOF

tar -czf "$out_dir/$name.tar.gz" -C "$stage_root" "$name"
(cd "$out_dir" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
rm -rf "$stage_root"
echo "packaged $out_dir/$name.tar.gz"
