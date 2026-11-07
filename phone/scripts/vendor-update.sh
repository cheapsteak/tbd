#!/usr/bin/env bash
# usage: vendor-update.sh <name> <version> <file>...
# Vendors files from an npm package into phone/loader/vendor/<name>/, verifying the
# registry's sha512 integrity first, and rewrites that library's rows in vendor.lock.
# env: VENDOR_REGISTRY (default https://registry.npmjs.org), VENDOR_ROOT.
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "usage: vendor-update.sh <name> <version> <file>..." >&2
  exit 2
fi

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

work="$(mktemp -d "${TMPDIR:-/tmp}/vendor-update.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# 1. Metadata.
curl -fsSL "$registry/$name/$version" -o "$work/meta.json" || die "could not fetch metadata for $name@$version"
tarball_rows="$(sed -n 's/.*"tarball" *: *"\([^"]*\)".*/\1/p' "$work/meta.json")"
integrity_rows="$(sed -n 's/.*"integrity" *: *"\([^"]*\)".*/\1/p' "$work/meta.json")"
[ -n "$tarball_rows" ] && [ "$(printf '%s\n' "$tarball_rows" | wc -l | tr -d ' ')" -eq 1 ] || die "metadata must name exactly one tarball"
[ -n "$integrity_rows" ] && [ "$(printf '%s\n' "$integrity_rows" | wc -l | tr -d ' ')" -eq 1 ] || die "metadata must name exactly one integrity"
tarball="$tarball_rows"
integrity="$integrity_rows"
case "$integrity" in sha512-*) ;; *) die "integrity is not sha512: $integrity" ;; esac
if grep -q '"attestations"' "$work/meta.json"; then provenance=yes; else provenance=no; fi

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
  [ -f "$work/x/package/$f" ] || die "requested file $f is not in the tarball; nothing changed"
  files="$files$f
"
done
licenses="$(cd "$work/x/package" && find . -maxdepth 1 -type f \( -name 'LICEN[CS]E*' -o -name 'NOTICE*' \) | sed 's|^\./||')"
[ -n "$licenses" ] || die "tarball has no license file; nothing changed"
all="$(printf '%s%s\n' "$files" "$licenses" | sed '/^$/d' | LC_ALL=C sort -u)"

# 4. Replace the library directory and rewrite its lock rows.
mkdir -p "$root"
[ -f "$root/vendor.lock" ] || printf '# name\tversion\tkind\tvalue\t[sha256]\n' >"$root/vendor.lock"
rm -rf "${root:?}/$name"
{
  while IFS= read -r f; do
    mkdir -p "$root/$name/$(dirname "$f")"
    cp "$work/x/package/$f" "$root/$name/$f"
  done <<EOT
$all
EOT
}
{
  awk -F'\t' -v n="$name" '$1 != n' "$root/vendor.lock"
  printf '%s\t%s\ttarball\t%s\n' "$name" "$version" "$tarball"
  printf '%s\t%s\tintegrity\t%s\n' "$name" "$version" "$integrity"
  printf '%s\t%s\tprovenance\t%s\n' "$name" "$version" "$provenance"
  while IFS= read -r f; do
    sum="$(shasum -a 256 "$root/$name/$f" | awk '{print $1}')"
    printf '%s\t%s\tfile\t%s\t%s\n' "$name" "$version" "$f" "$sum"
  done <<EOT
$all
EOT
} >"$work/new.lock"
cp "$work/new.lock" "$root/vendor.lock"
echo "vendor-update: vendored $name@$version (provenance $provenance)"
