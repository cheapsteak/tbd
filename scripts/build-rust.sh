#!/usr/bin/env bash
# Regenerates rust/comrak-ffi/lib/libcomrak_ffi.a and its staleness stamp.
# Requires cargo. The .a is committed, so this only runs when the Rust source
# or Cargo.lock changes — see docs/specs/2026-07-28-markdown-display-options-design.md
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="$REPO_ROOT/rust/comrak-ffi"
OUT_DIR="$CRATE_DIR/lib"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found on PATH." >&2
  echo "The prebuilt archive is committed, so you only need cargo to regenerate it." >&2
  echo "Install with: brew install rust   (or https://rustup.rs)" >&2
  exit 1
fi

cargo build --release --manifest-path "$CRATE_DIR/Cargo.toml"
mkdir -p "$OUT_DIR"
cp "$CRATE_DIR/target/release/libcomrak_ffi.a" "$OUT_DIR/libcomrak_ffi.a"

# Stamp = SHA-256 of every input that determines the archive's contents.
# Cargo.toml is included deliberately: it carries [profile.release] and the
# dependency feature flags. Flipping `default-features` back on would pull
# syntect in and change the archive without touching Cargo.lock, so omitting
# it here would leave the CI gate blind to exactly the regression it exists
# to catch. Argument order is fixed, so the hash is deterministic.
shasum -a 256 "$CRATE_DIR/src/lib.rs" "$CRATE_DIR/Cargo.toml" "$CRATE_DIR/Cargo.lock" \
  | awk '{print $1}' | shasum -a 256 | awk '{print $1}' > "$OUT_DIR/.build-stamp"

echo "built $(ls -lh "$OUT_DIR/libcomrak_ffi.a" | awk '{print $5}') -> $OUT_DIR/libcomrak_ffi.a"
echo "stamp $(cat "$OUT_DIR/.build-stamp")"
