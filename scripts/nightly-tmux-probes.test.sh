#!/usr/bin/env bash
# Tests for scripts/nightly-tmux-probes.sh — run: bash scripts/nightly-tmux-probes.test.sh
#
# This file tests the HARNESS, not tmux. The probes themselves assert claims
# about tmux; what is proven here is that the harness would actually TELL US if
# a claim stopped holding, and that it cleans up after itself even when killed.
#
# Both properties were learned the expensive way by this program: a checker that
# has only ever seen passes is not known to report failures, and a stress harness
# that leaks processes onto a shared box is not safe to run nightly.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/nightly-tmux-probes.sh"


FAIL=0
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output lacks [$3]"; FAIL=1; fi; }

# Is a SPECIFIC probe server still serving? Asserting on one known socket name
# rather than counting a shared prefix: the first version of this check counted
# `tbd-probe-*` and dutifully reported 40 sockets belonging to unrelated tooling
# as leaks of mine. A check that measures someone else's namespace tells you
# nothing about your own cleanup — and it fails in the direction that looks like
# diligence.
probe_server_live() {
  if tmux -L "$1" ls >/dev/null 2>&1; then echo live; else echo gone; fi
}

test_injected_failure_is_reported_as_a_failure() {
  # THE POINT OF THIS FILE. Corrupt one probe's observed value and require that
  # the harness (a) exits non-zero, (b) prints FAIL with both values, and
  # (c) names the probe in its summary. A green run proves nothing on its own.
  local out rc
  out="$(PROBE_INJECT_FAILURE=P5 bash "$SCRIPT" 2>&1)"; rc=$?
  assert_eq "an injected false claim makes the run exit non-zero" "1" "$rc"
  assert_contains "the failing claim is marked FAIL" "$out" "   FAIL  "
  assert_contains "the observed value is shown, not just the expectation" "$out" "__INJECTED_FAILURE__"
  assert_contains "the summary counts it" "$out" "FAILED"
  assert_contains "the failed-claims list names the probe" "$out" "P5 —"
  # And the run must not report a clean sweep alongside the failure.
  assert_eq "a failed run does not claim 0 failures" "0" \
    "$(printf '%s' "$out" | grep -c '0 FAILED')"
}

test_clean_run_passes_every_claim_and_exits_zero() {
  local out rc
  out="$(bash "$SCRIPT" 2>&1)"; rc=$?
  assert_eq "an uninjected run exits 0" "0" "$rc"
  assert_contains "and reports zero failures" "$out" "0 FAILED"
  # Guard against the empty-suite failure mode: a harness that ran no probes at
  # all would also report "0 FAILED". `swift test --filter` exiting green on zero
  # matches has cost this program five separate times; same shape, same guard.
  local checked
  checked="$(printf '%s' "$out" | sed -n 's/^═══ \([0-9]*\) claims checked.*/\1/p')"
  assert_eq "the run actually checked the expected number of claims" "16" "$checked"
}

test_every_listed_probe_function_exists() {
  # A typo in the PROBES array would silently drop a probe, and the count guard
  # above would only catch it if someone remembered to update the number.
  local missing=0 p
  for p in $(bash "$SCRIPT" --list); do
    grep -q "^${p}()" "$SCRIPT" || { echo "     missing: $p"; missing=$((missing + 1)); }
  done
  assert_eq "every probe named in PROBES is defined" "0" "$missing"
}

test_cleanup_leaves_no_tmux_server_behind() {
  local sock="tbdnightly-probetest-done-$$"
  PROBE_SOCKET="$sock" bash "$SCRIPT" >/dev/null 2>&1
  assert_eq "a completed run leaves no live probe server" "gone" "$(probe_server_live "$sock")"
}

test_cleanup_survives_an_external_kill() {
  # C4's harness survived four external kills with zero leaked spinners, and that
  # property is what made it safe to run on a shared box at all. Same requirement
  # here: a nightly that leaks a tmux server per interrupted run is not nightly-safe.
  local sock="tbdnightly-probetest-kill-$$" pid
  PROBE_SOCKET="$sock" bash "$SCRIPT" >/dev/null 2>&1 &
  pid=$!                                  # captured at spawn — never `jobs -p`
  sleep 3                                 # let it get a server up mid-probe
  # Assert the server was actually UP before the kill. Without this the test
  # would pass just as happily if the run had died instantly and never started
  # anything — a cleanup check that can only succeed proves nothing.
  assert_eq "the run really had a server up before we killed it" "live" "$(probe_server_live "$sock")"
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  # Stopping a parent orphans its children, so re-check rather than assuming.
  sleep 1
  assert_eq "a TERM'd run leaves no live probe server" "gone" "$(probe_server_live "$sock")"
  tmux -L "$sock" kill-server >/dev/null 2>&1   # backstop, by exact socket name
}

for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  echo "== $t"
  "$t"
done
if [[ $FAIL -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $FAIL
