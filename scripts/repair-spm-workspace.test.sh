#!/usr/bin/env bash
# Tests for scripts/repair-spm-workspace.sh — run: bash scripts/repair-spm-workspace.test.sh
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F`/"$t" below
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/repair-spm-workspace.sh"

FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] lacks [$3]"; FAIL=1; fi; }
assert_lacks()    { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: [$2] unexpectedly contains [$3]"; FAIL=1; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/repair-spm-test.XXXXXX"; }

# A workspace shaped like a cache restore: dependency checkouts plus warm
# compiled artifacts. `damaged` drops the manifest the real failure was missing.
_mk_workspace() {
  local root="$1" damaged="${2:-healthy}"
  mkdir -p "$root/.build/checkouts/swift-cmark" "$root/.build/repositories" "$root/.build/arm64-apple-macosx/debug"
  : > "$root/.build/arm64-apple-macosx/debug/TBDShared.o"
  [[ "$damaged" == "damaged" ]] || : > "$root/.build/checkouts/swift-cmark/Package.swift"
}

# Fake resolves. The "heals" variant fails while the damaged checkout is present
# and succeeds once it has been discarded — the real repair's whole premise. It
# is written to a file rather than an inline `bash -c "…"` string because the
# script invokes the seam unquoted, so embedded quoting would not survive word
# splitting.
RESOLVE_OK='true'
RESOLVE_ALWAYS_FAILS='false'
RESOLVE_HEALS='bash ./fake-resolve.sh'

_mk_healing_resolve() {
  cat > "$1/fake-resolve.sh" <<'EOF'
if [ -d .build/checkouts/swift-cmark ] && [ ! -e .build/checkouts/swift-cmark/Package.swift ]; then
  echo "error: the package manifest at .build/checkouts/swift-cmark/Package.swift cannot be accessed"
  exit 1
fi
exit 0
EOF
}

_run() { # _run <root> <resolve-cmd>
  local root="$1" cmd="$2"
  ( cd "$root" && SPM_RESOLVE_CMD="$cmd" bash "$SCRIPT" 2>&1 )
}

test_cold_workspace_is_a_noop() {
  local root; root="$(mktmpd)"
  local out; out="$(_run "$root" "$RESOLVE_ALWAYS_FAILS")"
  assert_eq "cold workspace exits 0" "0" "$?"
  assert_contains "cold workspace reported" "$out" "cold workspace, nothing to repair"
  rm -rf "$root"
}

test_healthy_workspace_resolves_and_keeps_checkouts() {
  local root; root="$(mktmpd)"; _mk_workspace "$root"
  local out; out="$(_run "$root" "$RESOLVE_OK")"
  assert_eq "healthy workspace exits 0" "0" "$?"
  assert_contains "healthy path reported" "$out" "resolves cleanly"
  assert_lacks "healthy path does not warn" "$out" "::warning::"
  assert_eq "checkouts kept" "true" "$([[ -e "$root/.build/checkouts/swift-cmark/Package.swift" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_damaged_workspace_discards_checkouts_and_recovers() {
  local root; root="$(mktmpd)"; _mk_workspace "$root" damaged; _mk_healing_resolve "$root"
  local out; out="$(_run "$root" "$RESOLVE_HEALS")"
  assert_eq "damaged workspace recovers to exit 0" "0" "$?"
  assert_contains "repair warned" "$out" "::warning::"
  assert_contains "repair reported" "$out" "workspace repaired by re-resolving"
  assert_eq "checkouts discarded" "false" "$([[ -d "$root/.build/checkouts" ]] && echo true || echo false)"
  assert_eq "repositories discarded" "false" "$([[ -d "$root/.build/repositories" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_repair_keeps_compiled_artifacts_warm() {
  local root; root="$(mktmpd)"; _mk_workspace "$root" damaged; _mk_healing_resolve "$root"
  _run "$root" "$RESOLVE_HEALS" >/dev/null
  assert_eq "compiled artifacts survive the repair" "true" \
    "$([[ -e "$root/.build/arm64-apple-macosx/debug/TBDShared.o" ]] && echo true || echo false)"
  rm -rf "$root"
}

test_persistent_failure_is_not_swallowed() {
  local root; root="$(mktmpd)"; _mk_workspace "$root" damaged
  local out rc
  out="$(_run "$root" "$RESOLVE_ALWAYS_FAILS")"; rc=$?
  assert_eq "second failure exits non-zero" "1" "$rc"
  assert_contains "second failure errors loudly" "$out" "::error::"
  assert_contains "second failure names the real suspect" "$out" "not restored-cache damage"
  rm -rf "$root"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
exit $FAIL
