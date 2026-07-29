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

# Two-line stamp, both halves checked by the CI gate in .github/workflows/test.yml:
#
#   line 1 = SHA-256 of every input that determines the archive's contents
#   line 2 = SHA-256 of the archive itself
#
# Line 1 alone catches "sources changed, archive not rebuilt". It cannot catch
# stamp/archive desync — staging the stamp without the .a, or resolving a
# binary merge conflict to the wrong side, leaves the gate green on a stale
# archive. Line 2 closes that.
#
# Cargo.toml is in line 1 deliberately: it carries [profile.release] and the
# dependency feature flags. Flipping `default-features` back on would pull
# syntect in and change the archive without touching Cargo.lock, so omitting
# it here would leave the CI gate blind to exactly the regression it exists
# to catch. Argument order is fixed, so the hash is deterministic.
#
# THE FILE LIST BELOW IS DUPLICATED IN THE CI GATE. If the crate ever gains a
# build.rs or a second .rs file, update BOTH in the same commit — a list that
# drifts here makes the gate compare two different hashes and fail every PR;
# a list that drifts there makes it silently stop covering the new input.
shasum -a 256 "$CRATE_DIR/src/lib.rs" "$CRATE_DIR/Cargo.toml" "$CRATE_DIR/Cargo.lock" \
  | awk '{print $1}' | shasum -a 256 | awk '{print $1}' > "$OUT_DIR/.build-stamp"
shasum -a 256 "$OUT_DIR/libcomrak_ffi.a" | awk '{print $1}' >> "$OUT_DIR/.build-stamp"

echo "built $(ls -lh "$OUT_DIR/libcomrak_ffi.a" | awk '{print $5}') -> $OUT_DIR/libcomrak_ffi.a"
echo "stamp sources $(sed -n 1p "$OUT_DIR/.build-stamp")"
echo "stamp archive $(sed -n 2p "$OUT_DIR/.build-stamp")"
