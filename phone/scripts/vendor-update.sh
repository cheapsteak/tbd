#!/usr/bin/env bash
# usage: vendor-update.sh <name> <version> <file>...
# Vendors files from an npm package into phone/loader/vendor/<name>/, verifying the
# registry's sha512 integrity first, and rewrites that library's rows in vendor.lock.
#
# <name> is one path segment, and each <file> a path relative to the package, by the rule
# stage-loader.sh serves vendored files under: segments of A-Z a-z 0-9 . _ - that do not
# start with '.', so no '..', no absolute path and no empty segment. The license files the
# tarball brings must pass it too, and no vendored file may be, or sit behind, a symlink.
# So nothing it removes or writes lies outside vendor/<name>/, vendor.lock and a scratch
# directory of its own in the vendor root, and nothing it copies lies outside the package.
#
# The new files are staged first and moved into place by rename, and the lock is replaced only
# after them, so a run that fails at any step, or is stopped by a signal it can trap, leaves the
# old files and the old lock as they were.
#
# env: VENDOR_REGISTRY (default https://registry.npmjs.org), VENDOR_ROOT.
# Exit status: 0 vendored, 1 refused (nothing changed), 2 bad usage.
set -euo pipefail

usage() {
  echo "usage: vendor-update.sh <name> <version> <file>..." >&2
  if [ "$#" -gt 0 ]; then echo "vendor-update: $*" >&2; fi
  exit 2
}

if [ "$#" -lt 3 ]; then usage; fi

repo="$(cd "$(dirname "$0")/../.." && pwd)"
registry="${VENDOR_REGISTRY:-https://registry.npmjs.org}"
root="${VENDOR_ROOT:-$repo/phone/loader/vendor}"
name="$1"
version="$2"
shift 2

die() {
  echo "vendor-update: $*" >&2
  exit 1
}

# $1 with every byte but A-Z a-z 0-9 . _ / - shown as '?', so a message carries no control bytes.
shown() { printf '%s' "$1" | tr -c 'A-Za-z0-9._/-' '?'; }

# The path rule for a vendored library's name and the paths of its files. stage-loader.sh,
# vendor-update.sh and vendor-check.sh each carry these lines word for word, so that each stays
# one self-contained file; path-rule.testlib.sh runs all three on one table of paths and fails
# when their verdicts, or these lines, differ.
segment='[A-Za-z0-9_][A-Za-z0-9._-]*' # no leading dot, so no '..' and no dotfiles
lib_name="^$segment\$"
lib_path="^$segment(/$segment)*\$"
version_rule='^[A-Za-z0-9][A-Za-z0-9.+_-]*$'

[[ "$name" =~ $lib_name ]] || usage "<name> must be one segment of A-Z a-z 0-9 . _ - not starting with '.': '$(shown "$name")'"
[[ "$version" =~ $version_rule ]] || usage "<version> must be A-Z a-z 0-9 . + _ - and start with a letter or digit: '$(shown "$version")'"
for f in "$@"; do
  [[ "$f" =~ $lib_path ]] || usage "<file> must be a relative path of segments of A-Z a-z 0-9 . _ - none starting with '.': '$(shown "$f")'"
done

# True when $2, a path relative to the directory $1, names a regular file and neither it nor
# any directory on the way is a symlink.
plain_file() {
  local cur="$1" rest="$2" part
  while [ -n "$rest" ]; do
    part="${rest%%/*}"
    if [ "$part" = "$rest" ]; then rest=''; else rest="${rest#*/}"; fi
    cur="$cur/$part"
    if [ -L "$cur" ]; then return 1; fi
  done
  [ -f "$cur" ]
}

work="$(mktemp -d "${TMPDIR:-/tmp}/vendor-update.XXXXXX")"
stage=''
made_root=0
# 1 while step 4 swaps the library and the lock: from just before the old library moves aside
# until the new lock is in place. A run that ends in between, however it ends, is undone.
swapping=0

# True when $1 names anything, a dangling symlink included.
present() { [ -e "$1" ] || [ -L "$1" ]; }

# Undoes step 4's renames while the old lock is still in place: the new library, if it moved
# into place, goes back into the stage, and the old one, if it was moved aside, comes back, so
# the vendor root matches the old lock again. Once the new lock is in place there is nothing to
# undo. Each rename is atomic, so each directory is wholly in one place or the other.
restore() {
  present "$stage/vendor.lock" || return 0
  if ! present "$stage/$name"; then mv "$root/$name" "$stage/$name" || return 1; fi
  if present "$stage/old"; then mv "$stage/old" "$root/$name" || return 1; fi
}

# On any exit: an unfinished swap is undone, the scratch directories go, and a vendor root this
# run made and left empty goes too. The stage holds the old library until the new lock is in
# place, so it is kept, and named, when the old library could not be put back.
finish() {
  if [ "$swapping" -eq 1 ] && ! restore; then
    echo "vendor-update: could not put the old $name back; it is in $stage/old" >&2
    stage=''
  fi
  rm -rf "$work"
  if [ -n "$stage" ]; then rm -rf "$stage"; fi
  if [ "$made_root" -eq 1 ]; then rmdir "$root" 2>/dev/null || true; fi
}
trap finish EXIT

# 1. Metadata. The version document is parsed as JSON, and only its own `dist` object is read:
#    `dist.tarball` and `dist.integrity` must be strings, and `dist.attestations` an object for
#    provenance. A key of the same name anywhere else in the document counts for nothing.
#    Node reads it, since this package needs Node anyway.
command -v node >/dev/null 2>&1 || die "node is required to read the registry metadata"
curl -fsSL "$registry/$name/$version" -o "$work/meta.json" || die "could not fetch metadata for $name@$version"
# shellcheck disable=SC2016 # JavaScript, not shell: nothing in it is meant to expand
read_dist='
const fs = require("node:fs");
const refuse = (why) => {
  process.stderr.write(`vendor-update: ${why}; nothing changed\n`);
  process.exit(1);
};
let doc;
try {
  doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
} catch {
  refuse("the metadata is not JSON");
}
const dist = doc !== null && typeof doc === "object" && !Array.isArray(doc) ? doc.dist : undefined;
if (dist === null || typeof dist !== "object" || Array.isArray(dist)) refuse("the metadata has no dist object");
const field = (key) => {
  const value = Object.hasOwn(dist, key) ? dist[key] : undefined;
  if (typeof value !== "string" || value === "") refuse(`the metadata has no dist.${key} string`);
  // One value per line below, and lock rows are tab-separated: no control characters.
  if (/[\u0000-\u001f\u007f]/.test(value)) refuse(`dist.${key} holds a control character`);
  return value;
};
const tarball = field("tarball");
const integrity = field("integrity");
const attestations = Object.hasOwn(dist, "attestations") ? dist.attestations : null;
const provenance = attestations !== null && typeof attestations === "object" && !Array.isArray(attestations) ? "yes" : "no";
process.stdout.write(`${tarball}\n${integrity}\n${provenance}\n`);
'
node --input-type=commonjs -e "$read_dist" "$work/meta.json" >"$work/dist" || exit 1
{ IFS= read -r tarball && IFS= read -r integrity && IFS= read -r provenance; } <"$work/dist" || die "could not read the metadata's dist fields"
case "$integrity" in sha512-*) ;; *) die "integrity is not sha512: $integrity" ;; esac

# 2. Tarball and integrity.
curl -fsSL "$tarball" -o "$work/pkg.tgz" || die "could not download $tarball"
actual="$(shasum -a 512 "$work/pkg.tgz" | awk '{print $1}')"
# base64 -d (GNU, newer BSD) or -D (older macOS); try the decoder that works.
if printf 'QQ==' | base64 -d >/dev/null 2>&1; then
  b64dec() { base64 -d; }
else
  b64dec() { base64 -D; }
fi
expected="$(printf %s "${integrity#sha512-}" | b64dec | od -An -v -tx1 | tr -d ' \n')"
if [ "$actual" != "$expected" ]; then
  die "integrity mismatch for $name@$version (registry $expected, tarball $actual); nothing changed"
fi

# 3. Extract and collect.
mkdir "$work/x"
tar -xzf "$work/pkg.tgz" -C "$work/x" || die "could not extract tarball"
[ -d "$work/x/package" ] || die "tarball has no package/ directory"
files=""
for f in "$@"; do
  plain_file "$work/x/package" "$f" || die "requested file $f is not a regular file in the tarball (missing, or a symlink); nothing changed"
  files="$files$f
"
done
licenses="$(cd "$work/x/package" && find . -maxdepth 1 -type f \( -name 'LICEN[CS]E*' -o -name 'NOTICE*' \) | sed 's|^\./||')"
[ -n "$licenses" ] || die "tarball has no license file; nothing changed"
all="$(printf '%s%s\n' "$files" "$licenses" | sed '/^$/d' | LC_ALL=C sort -u)"
# Every path, the license files' too, is checked before anything under the vendor root changes.
while IFS= read -r f; do
  [[ "$f" =~ $lib_path ]] || die "refusing to vendor a path with a character other than A-Z a-z 0-9 . _ / -, or a segment starting with '.': $(shown "$f"); nothing changed"
  plain_file "$work/x/package" "$f" || die "$f is not a regular file in the tarball (missing, or a symlink); nothing changed"
done <<EOT
$all
EOT

# 4. Build the new library and lock in a stage inside the vendor root, on its file system, so
#    each step into place is a rename. The old library directory goes aside and the new one in,
#    and only then does the new lock replace the old. A failure while staging changes nothing;
#    a run that ends before the new lock is in place, by a failed rename or a signal, is undone
#    by `finish`, so the old directory matches the old lock again.
if [ ! -d "$root" ]; then
  mkdir -p "$root"
  made_root=1
fi
stage="$(mktemp -d "$root/.vendor-update.XXXXXX")"
while IFS= read -r f; do
  mkdir -p "$stage/$name/$(dirname "$f")"
  cp "$work/x/package/$f" "$stage/$name/$f" || die "could not copy $f; nothing changed"
done <<EOT
$all
EOT
{
  if [ -f "$root/vendor.lock" ]; then
    awk -F'\t' -v n="$name" '$1 != n' "$root/vendor.lock"
  else
    printf '# name\tversion\tkind\tvalue\t[sha256]\n'
  fi
  printf '%s\t%s\ttarball\t%s\n' "$name" "$version" "$tarball"
  printf '%s\t%s\tintegrity\t%s\n' "$name" "$version" "$integrity"
  printf '%s\t%s\tprovenance\t%s\n' "$name" "$version" "$provenance"
  while IFS= read -r f; do
    sum="$(shasum -a 256 "$stage/$name/$f" | awk '{print $1}')"
    printf '%s\t%s\tfile\t%s\t%s\n' "$name" "$version" "$f" "$sum"
  done <<EOT
$all
EOT
} >"$stage/vendor.lock"

swapping=1
if present "$root/$name"; then
  mv "$root/$name" "$stage/old" || die "could not move the old $name aside; nothing changed"
fi
mv "$stage/$name" "$root/$name" || die "could not move the new $name into place; nothing changed"
mv "$stage/vendor.lock" "$root/vendor.lock" || die "could not replace vendor.lock; nothing changed"
swapping=0
echo "vendor-update: vendored $name@$version (provenance $provenance)"
