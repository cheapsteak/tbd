#!/bin/sh
# Puts the official libghostty-vt 1.0.0 xcframework in vendor/. Pass the path of
# an already-downloaded zip as $1 to skip the download. The checksum is the one
# measured on the zip from the URL below; its minisign signature was not checked.
set -eu
URL=https://release.files.ghostty.org/libghostty-vt/1.0.0/ghostty-vt-1.0.0.xcframework.zip
SHA=2c32b7409b2b6c2ef6cfd606526de357762ad458bdc27134ad074e86506a8bc2
cd "$(dirname "$0")"
mkdir -p vendor
ZIP=${1:-vendor/ghostty-vt-1.0.0.xcframework.zip}
[ -f "$ZIP" ] || curl -fsSL -o "$ZIP" "$URL"
echo "$SHA  $ZIP" | shasum -a 256 -c -
rm -rf vendor/ghostty-vt.xcframework
unzip -q "$ZIP" -d vendor
ls vendor/ghostty-vt.xcframework
