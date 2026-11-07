#!/bin/bash
# Rewrites noise-cacophony.json from cacophony's published Noise test vectors,
# keeping only the two protocols the phone channel speaks.
set -euo pipefail

commit=18b7348c54fd61fcd0c220298883de0d09c8364d
sha256=3bde7c09a6f349ee11c825c50fcc02649f8f02a47c857a459206b357f9386cae
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/cacophony.txt" \
  "https://raw.githubusercontent.com/haskell-cryptography/cacophony/$commit/vectors/cacophony.txt"
echo "$sha256  $work/cacophony.txt" | shasum -a 256 -c - >/dev/null

jq --arg commit "$commit" --arg sha256 "$sha256" '{
  source: "https://github.com/haskell-cryptography/cacophony/blob/\($commit)/vectors/cacophony.txt",
  sourceSHA256: $sha256,
  license: "Unlicense (public domain dedication): https://github.com/haskell-cryptography/cacophony/blob/\($commit)/LICENSE",
  note: "Filtered copy holding only the two protocols TBD uses. Regenerate with fetch-cacophony.sh; do not edit by hand.",
  vectors: [.vectors[] | select(.protocol_name == "Noise_IK_25519_AESGCM_SHA256" or .protocol_name == "Noise_IKpsk2_25519_AESGCM_SHA256")]
}' "$work/cacophony.txt" > "$here/noise-cacophony.json"

test "$(jq '.vectors | length' "$here/noise-cacophony.json")" = 2
