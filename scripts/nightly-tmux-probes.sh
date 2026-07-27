#!/usr/bin/env bash
# scripts/nightly-tmux-probes.sh — executable checks of tmux behaviours this repo
# currently trusts from memory. Step 1 of the nightly workflow
# (docs/specs/2026-07-24-test-hardening-design.md §9).
#
# TBD's tmux layer rests on a set of claims that live in code comments and in
# people's heads: that pane IDs get reused, that `paste-buffer -p` is the sole
# thing wrapping a bracketed paste, that a blank line detaches a control-mode
# client. Each is load-bearing, none is asserted anywhere, and tmux is free to
# change any of them in a point release. These probes turn them into checks that
# run every night against the real binary, so the day one changes we find out
# from a nightly report instead of from a user.
#
# Each probe names the claim AND the code that depends on it, so a failure is a
# starting point rather than a puzzle.
#
# Usage:
#   scripts/nightly-tmux-probes.sh              # run all probes
#   scripts/nightly-tmux-probes.sh --list       # list probe IDs and claims
#
# Exit: 0 = every claim held, 1 = at least one claim FAILED, 2 = harness error.
#
# Test seam (env):
#   PROBE_INJECT_FAILURE=<probe id>   corrupt that probe's observed value, to
#                                     prove the harness reports a failure as a
#                                     failure. Used by nightly-tmux-probes.test.sh.
#   PROBE_SOCKET=<name>               override the private socket name, so the
#                                     test can assert on that EXACT socket rather
#                                     than counting a shared prefix.
#
# SAFETY: every probe runs against a private tmux server (`-L tbdnightly-probe-$$`)
# and the cleanup trap kills THAT SOCKET ONLY. It never touches the developer's
# tmux server, never uses `pkill -f` (which matches across worktrees), and never
# signals a process group.
#
# The prefix is `tbdnightly-probe-`, NOT `tbd-probe-`: this box already carries
# 43 sockets named `tbd-probe-<HEX>` left by unrelated tooling, and TBD's own
# servers are `tbd-<8 hex>` (TmuxManager.serverName). A cleanup — or a leak
# CHECK — written against `tbd-probe-*` reaches into a namespace that is not
# ours. That is the cross-worktree hazard arriving through the checking layer
# instead of through a kill, and this file hit it before the rename.

set -uo pipefail

readonly SOCKET="${PROBE_SOCKET:-tbdnightly-probe-$$}"
WORK_DIR=""
CURRENT_PROBE=""
PASSED=0
FAILED=0
FAILURES=()

# --- harness ------------------------------------------------------------------

cleanup() {
  local rc=$?
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1
  # `kill-server` stops the server but LEAVES THE SOCKET FILE — measured, after
  # nine of them accumulated here in one session. Ephemeral on a CI runner,
  # but this also runs on a developer box where that directory already holds
  # ~19,700 dead sockets. Remove our own by exact path; never glob a prefix.
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET" 2>/dev/null
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  exit "$rc"
}
# INT/TERM as well as EXIT: an externally killed probe run must still take its
# private tmux server with it rather than leaking one per night.
trap cleanup EXIT INT TERM

tmuxp() { tmux -L "$SOCKET" "$@"; }

probe() {
  CURRENT_PROBE="$1"
  echo
  echo "── $1 — $2"
  echo "   depends on: $3"
}

# Compare an observed value against the claim. PROBE_INJECT_FAILURE corrupts the
# observed value for one probe so the harness's own reporting can be tested; a
# reporting path that has only ever seen passes is not known to report failures.
expect_eq() {
  local what="$1" want="$2" got="$3"
  if [[ "${PROBE_INJECT_FAILURE:-}" == "$CURRENT_PROBE" ]]; then
    got="__INJECTED_FAILURE__"
  fi
  if [[ "$want" == "$got" ]]; then
    echo "   PASS  $what"
    PASSED=$((PASSED + 1))
  else
    echo "   FAIL  $what"
    echo "         claimed:  [$want]"
    echo "         observed: [$got]"
    FAILED=$((FAILED + 1))
    FAILURES+=("$CURRENT_PROBE — $what (claimed [$want], observed [$got])")
  fi
}

# Bounded wait for a file to reach an exact size. Returns 1 on deadline; the
# caller then compares content and reports what it actually saw.
wait_for_size() {
  local file="$1" want="$2" deadline_s="${3:-5}"
  local deadline=$((SECONDS + deadline_s))
  while [[ $SECONDS -lt $deadline ]]; do
    [[ -f "$file" ]] && [[ "$(wc -c < "$file" | tr -d ' ')" -ge "$want" ]] && return 0
    sleep 0.1
  done
  return 1
}

file_hex() { xxd -p "$1" 2>/dev/null | tr -d '\n'; }

# --- probes -------------------------------------------------------------------

probe_pane_ids_are_not_reused_within_a_server() {
  probe "P1" "pane IDs are never reused while a server lives" \
        "issue #384 (stale terminal→pane coordinates routing keystrokes to the wrong session)"

  tmuxp new-session -d -s probe -x 80 -y 24 'sleep 300' >/dev/null 2>&1
  tmuxp new-window -d 'sleep 300' >/dev/null 2>&1
  tmuxp new-window -d 'sleep 300' >/dev/null 2>&1
  local before; before="$(tmuxp list-panes -a -F '#{pane_id}' | sort | tr '\n' ' ')"

  # Kill the middle pane, then create a new one. If IDs were recycled, the new
  # pane would take the dead pane's ID — which is what "pane reuse" would mean.
  local victim; victim="$(tmuxp list-panes -a -F '#{pane_id}' | sed -n 2p)"
  tmuxp kill-pane -t "$victim" >/dev/null 2>&1
  tmuxp new-window -d 'sleep 300' >/dev/null 2>&1
  local after; after="$(tmuxp list-panes -a -F '#{pane_id}' | sort | tr '\n' ' ')"

  expect_eq "the killed pane's ID ($victim) is not handed out again" \
            "absent" \
            "$(if [[ " $after " == *" $victim "* ]]; then echo "REUSED"; else echo "absent"; fi)"
  expect_eq "three panes remain after kill+create" "3" \
            "$(tmuxp list-panes -a -F '#{pane_id}' | grep -c .)"
  echo "         (before: $before/ after: $after)"
  tmuxp kill-server >/dev/null 2>&1
}

probe_pane_ids_restart_at_zero_after_server_death() {
  probe "P2" "pane IDs restart at %0 when the server dies — so a PERSISTED pane ID can collide across a server restart" \
        "issue #384; this is the actual mechanism behind 'pane reuse', and it is narrower than the folklore"

  tmuxp new-session -d -s probe -x 80 -y 24 'sleep 300' >/dev/null 2>&1
  tmuxp new-window -d 'sleep 300' >/dev/null 2>&1
  local first_generation; first_generation="$(tmuxp list-panes -a -F '#{pane_id}' | sort | tr '\n' ' ')"
  tmuxp kill-server >/dev/null 2>&1
  sleep 0.3

  tmuxp new-session -d -s probe -x 80 -y 24 'sleep 300' >/dev/null 2>&1
  local reborn; reborn="$(tmuxp list-panes -a -F '#{pane_id}')"
  expect_eq "a fresh server's first pane is %0 again (collides with the old server's %0)" "%0" "$reborn"
  echo "         (first server had: ${first_generation}— a stored '%0' now points at a different pane)"
  tmuxp kill-server >/dev/null 2>&1
}

probe_paste_buffer_p_is_conditional_on_bracketed_paste_mode() {
  probe "P3" "\`paste-buffer -p\` wraps in ESC[200~/ESC[201~ ONLY IF the pane's application enabled bracketed-paste mode (DECSET 2004)" \
        "PasteExecutor.swift; TerminalPanelView.swift:727 and TBDTerminalView.swift:78 call the daemon-side -p the SOLE bracketed-paste wrapping — true, but silently contingent on the TUI having requested it"

  local payload="ABCDEFGHIJ"
  printf '%s' "$payload" > "$WORK_DIR/payload.txt"
  local payload_hex; payload_hex="$(printf '%s' "$payload" | xxd -p | tr -d '\n')"
  local wrapped_hex="1b5b3230307e${payload_hex}1b5b3230317e"

  # Arm A — the pane requests bracketed paste. Expect the markers.
  tmuxp new-session -d -s probe -x 80 -y 24 \
    "stty raw -echo; printf '\033[?2004h'; head -c 22 > $WORK_DIR/on.bin" >/dev/null 2>&1
  sleep 0.5
  tmuxp load-buffer -b probeon "$WORK_DIR/payload.txt" >/dev/null 2>&1
  tmuxp paste-buffer -d -p -b probeon -t "$(tmuxp list-panes -F '#{pane_id}')" >/dev/null 2>&1
  wait_for_size "$WORK_DIR/on.bin" 22 8
  expect_eq "with DECSET 2004 set: payload arrives wrapped" "$wrapped_hex" "$(file_hex "$WORK_DIR/on.bin")"
  tmuxp kill-server >/dev/null 2>&1; sleep 0.3

  # Arm B — the pane never requested it. Expect NO markers, same -p flag.
  tmuxp new-session -d -s probe -x 80 -y 24 \
    "stty raw -echo; head -c 10 > $WORK_DIR/off.bin" >/dev/null 2>&1
  sleep 0.5
  tmuxp load-buffer -b probeoff "$WORK_DIR/payload.txt" >/dev/null 2>&1
  tmuxp paste-buffer -d -p -b probeoff -t "$(tmuxp list-panes -F '#{pane_id}')" >/dev/null 2>&1
  wait_for_size "$WORK_DIR/off.bin" 10 8
  expect_eq "without DECSET 2004: SAME -p flag delivers the payload verbatim" \
            "$payload" "$(cat "$WORK_DIR/off.bin" 2>/dev/null)"
  tmuxp kill-server >/dev/null 2>&1
}

probe_paste_buffer_without_p_is_verbatim() {
  probe "P4" "\`paste-buffer\` without -p delivers bytes verbatim" \
        "TmuxManager.swift:560 and PasteExecutorIntegrationTests — the >4 KB bulk-paste path relies on no wrapping being added"

  local payload="ABCDEFGHIJ"
  printf '%s' "$payload" > "$WORK_DIR/payload4.txt"
  tmuxp new-session -d -s probe -x 80 -y 24 \
    "stty raw -echo; printf '\033[?2004h'; head -c 10 > $WORK_DIR/nop.bin" >/dev/null 2>&1
  sleep 0.5
  tmuxp load-buffer -b probenop "$WORK_DIR/payload4.txt" >/dev/null 2>&1
  # DECSET 2004 is deliberately ON here: without -p there must be no wrapping
  # EVEN THOUGH the application asked for bracketed paste.
  tmuxp paste-buffer -d -b probenop -t "$(tmuxp list-panes -F '#{pane_id}')" >/dev/null 2>&1
  wait_for_size "$WORK_DIR/nop.bin" 10 8
  expect_eq "no -p: verbatim even with DECSET 2004 set" "$payload" "$(cat "$WORK_DIR/nop.bin" 2>/dev/null)"
  tmuxp kill-server >/dev/null 2>&1
}

probe_paste_buffer_d_deletes_the_buffer() {
  probe "P5" "\`paste-buffer -d\` deletes the named buffer; without -d it survives" \
        "PasteExecutor.swift:58-72 — the delete-buffer fallback only makes sense if -d normally did the delete"

  printf 'x' > "$WORK_DIR/payload5.txt"
  tmuxp new-session -d -s probe -x 80 -y 24 'sleep 300' >/dev/null 2>&1
  local pane; pane="$(tmuxp list-panes -F '#{pane_id}')"

  tmuxp load-buffer -b probekeep "$WORK_DIR/payload5.txt" >/dev/null 2>&1
  tmuxp paste-buffer -b probekeep -t "$pane" >/dev/null 2>&1
  expect_eq "without -d the buffer survives the paste" "present" \
            "$(if tmuxp list-buffers 2>/dev/null | grep -q '^probekeep:'; then echo present; else echo GONE; fi)"

  tmuxp load-buffer -b probedel "$WORK_DIR/payload5.txt" >/dev/null 2>&1
  tmuxp paste-buffer -d -b probedel -t "$pane" >/dev/null 2>&1
  expect_eq "with -d the buffer is gone" "absent" \
            "$(if tmuxp list-buffers 2>/dev/null | grep -q '^probedel:'; then echo STILL_PRESENT; else echo absent; fi)"
  tmuxp kill-server >/dev/null 2>&1
}

# P6/P7/P8 share one control-mode transcript: attaching three times would triple
# the runtime and test nothing extra.
probe_control_mode_framing() {
  local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local transcript="$WORK_DIR/cc.txt"

  tmuxp new-session -d -s cc -x 80 -y 24 'sleep 300' >/dev/null 2>&1
  if ! python3 "$script_dir/nightly-tmux-cc-probe.py" "$SOCKET" cc > "$transcript" 2>"$WORK_DIR/cc.err"; then
    echo "   HARNESS ERROR: control-mode driver failed: $(cat "$WORK_DIR/cc.err")" >&2
    FAILED=$((FAILED + 1))
    FAILURES+=("P6/P7/P8 — control-mode driver failed to run: $(cat "$WORK_DIR/cc.err")")
    tmuxp kill-server >/dev/null 2>&1
    return
  fi

  local good_phase bad_phase ws_phase
  good_phase="$(phase_of "$transcript" attached after-good-command)"
  bad_phase="$(phase_of "$transcript" after-good-command after-bad-command)"
  ws_phase="$(phase_of "$transcript" after-bad-command after-whitespace-line)"

  probe "P8" "a command yields %begin/%end with a matching id triple; an INVALID command yields %begin/%error" \
        "TmuxControlParser.swift:34-55 — the %begin…%end/%error framing; %error, not %end, terminates a failed command"
  local good_begin good_end
  good_begin="$(printf '%s' "$good_phase" | sed -n 's/^%begin \(.*\)$/\1/p' | tr -d '\r' | head -1)"
  good_end="$(printf '%s' "$good_phase"   | sed -n 's/^%end \(.*\)$/\1/p'   | tr -d '\r' | head -1)"
  expect_eq "a good command's %begin and %end carry the same id triple" "$good_begin" "$good_end"
  expect_eq "a good command's output appears inside the block" "yes" \
            "$(if printf '%s' "$good_phase" | grep -q 'CCPROBE_OK'; then echo yes; else echo no; fi)"
  local bad_begin bad_error
  bad_begin="$(printf '%s' "$bad_phase" | sed -n 's/^%begin \(.*\)$/\1/p' | tr -d '\r' | head -1)"
  bad_error="$(printf '%s' "$bad_phase" | sed -n 's/^%error \(.*\)$/\1/p' | tr -d '\r' | head -1)"
  expect_eq "an invalid command terminates with %error carrying the same id triple" "$bad_begin" "$bad_error"
  expect_eq "an invalid command emits no %end" "0" \
            "$(printf '%s' "$bad_phase" | grep -c '^%end')"

  probe "P7" "a whitespace-only line produces ZERO command blocks and does not detach" \
        "control-mode input routing — a stray whitespace write must not be read as a command"
  expect_eq "whitespace-only line produces no %begin block" "0" \
            "$(printf '%s' "$ws_phase" | grep -c '^%begin')"
  expect_eq "whitespace-only line produces no %exit" "0" \
            "$(printf '%s' "$ws_phase" | grep -c '^%exit')"

  probe "P6" "a BLANK line detaches the control-mode client (%exit)" \
        "control-mode input routing — an empty write is a detach, so it must never be sent as a no-op keepalive"
  local blank_phase; blank_phase="$(phase_of "$transcript" after-whitespace-line after-blank-line)"
  expect_eq "blank line yields %exit" "1" \
            "$(printf '%s' "$blank_phase" | grep -c '^%exit')"
  expect_eq "and the client process actually exits" "0" \
            "$(sed -n 's/^@@EXIT \(.*\)$/\1/p' "$transcript" | head -1)"

  tmuxp kill-server >/dev/null 2>&1
}

# Extract the transcript between two @@MARK labels.
phase_of() {
  local file="$1" from="$2" to="$3"
  awk -v from="@@MARK $from" -v to="@@MARK $to" '
    $0 == to   { inside = 0 }
    inside     { print }
    $0 == from { inside = 1 }
  ' "$file"
}

# --- main ---------------------------------------------------------------------

PROBES=(
  probe_pane_ids_are_not_reused_within_a_server
  probe_pane_ids_restart_at_zero_after_server_death
  probe_paste_buffer_p_is_conditional_on_bracketed_paste_mode
  probe_paste_buffer_without_p_is_verbatim
  probe_paste_buffer_d_deletes_the_buffer
  probe_control_mode_framing
)

main() {
  if [[ "${1:-}" == "--list" ]]; then
    printf '%s\n' "${PROBES[@]}"
    return 0
  fi

  command -v tmux >/dev/null 2>&1 || { echo "nightly-tmux-probes: tmux not found" >&2; exit 2; }
  # A missing python3 must be a HARNESS ERROR, never a silent skip: three probes
  # would vanish and the run would still report success.
  command -v python3 >/dev/null 2>&1 || { echo "nightly-tmux-probes: python3 not found (needed for the control-mode pty driver)" >&2; exit 2; }

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tmux-probes.XXXXXX")" || exit 2
  echo "tmux $(tmux -V | awk '{print $2}') on $(uname -s) — private socket $SOCKET"

  local p
  for p in "${PROBES[@]}"; do "$p"; done

  echo
  echo "═══ $((PASSED + FAILED)) claims checked: $PASSED held, $FAILED FAILED"
  if [[ $FAILED -gt 0 ]]; then
    echo
    echo "Failed claims:"
    local f
    for f in "${FAILURES[@]}"; do echo "  - $f"; done
    return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
