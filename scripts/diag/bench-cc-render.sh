#!/bin/bash
# Benchmark TBD's terminal render path with the REAL Claude Code TUI as the byte
# producer, fed a deterministic scripted stream by a local fake Anthropic endpoint.
# No tokens are spent and no network is involved.
#
#   scripts/diag/bench-cc-render.sh --worktree <id> --label <name> [--mode default|fullscreen]
#
# Requires the temporary RenderLatencySignposts instrumentation to be running --
# see docs/perf/2026-08-26-claude-code-render-benchmark.md. Verify with:
#   strings /Applications/TBD.app/Contents/MacOS/TBDApp | grep -c RenderLatencySignposts
#
# --mode issues `/tui <mode>` before the run. Claude Code's two renderers are
# `fullscreen` (alternate screen, repaints the viewport in place) and `default`
# (normal screen, appends lines and scrolls). Confirm which one is live via the
# alternate_on line this script prints: 1 = fullscreen, 0 = default.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
WORKTREE=""; LABEL="bench"; MODE=""
DELTAS=2400; RATE=40; NEWLINE=6; CAPTURE=25; PORT=8787
OUT="${TMPDIR:-/tmp}/tbd-ccbench"

while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) WORKTREE="$2"; shift 2;;
    --label)    LABEL="$2"; shift 2;;
    --mode)     MODE="$2"; shift 2;;
    --deltas)   DELTAS="$2"; shift 2;;
    --rate)     RATE="$2"; shift 2;;
    --capture)  CAPTURE="$2"; shift 2;;
    --port)     PORT="$2"; shift 2;;
    --out)      OUT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$WORKTREE" ] || { echo "--worktree is required" >&2; exit 2; }
mkdir -p "$OUT"

# tmux socket TBD uses, for the alternate-screen check (a machine interface, not
# screen scraping). Derived from $TMUX when this script runs inside a TBD terminal.
SOCK=""
[ -n "${TMUX:-}" ] && SOCK="$(basename "${TMUX%%,*}")"

TERMID=""; SRVPID=""; LOGPID=""
cleanup() {
  [ -n "$TERMID" ] && tbd terminal close --terminal "$TERMID" >/dev/null 2>&1 || true
  [ -n "$SRVPID" ] && kill "$SRVPID" >/dev/null 2>&1 || true
  # `log stream` never terminates on its own, so an interrupt during the capture
  # sleep would leave it running and writing to disk for the rest of the session.
  [ -n "$LOGPID" ] && kill "$LOGPID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> starting fake Anthropic endpoint on 127.0.0.1:$PORT (deltas=$DELTAS rate=$RATE/s)"
FA_PORT=$PORT FA_DELTAS=$DELTAS FA_RATE=$RATE FA_NEWLINE=$NEWLINE \
  python3 "$DIR/fake-anthropic-server.py" > "$OUT/$LABEL.server.log" 2>&1 &
SRVPID=$!
sleep 1

echo "==> spawning Claude Code pointed at it"
TERMID="$(tbd terminal create "$WORKTREE" --type shell --json \
  --cmd "env ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT ANTHROPIC_AUTH_TOKEN=fake-local-bench CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude --model claude-opus-5" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
PANE="$(tbd terminal list "$WORKTREE" | awk -v id="$TERMID" '$1==id {print $3}')"
echo "    terminal=$TERMID pane=$PANE"

# Wait on a machine signal, not a fixed sleep: Claude Code probes HEAD /api/hello
# at startup, so its arrival in the server log proves the TUI booted. A fixed sleep
# silently loses every subsequent keystroke on a loaded machine, which yields a
# capture that looks real but contains no load at all.
wait_for() {  # wait_for <pattern> <seconds> <file>
  local i=0
  while [ "$i" -lt "$2" ]; do
    grep -q "$1" "$3" 2>/dev/null && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}
if wait_for "HEAD /api/hello" 90 "$OUT/$LABEL.server.log"; then
  echo "    Claude Code booted (reached the fake endpoint)"
else
  echo "!!! Claude Code never contacted the endpoint -- aborting" >&2; exit 1
fi
sleep 2

if [ -n "$MODE" ]; then
  echo "==> switching renderer: /tui $MODE"
  tbd terminal send --terminal "$TERMID" --text "/tui $MODE" >/dev/null
  tbd terminal send --terminal "$TERMID" --keys "Enter" >/dev/null
  sleep 4
fi

# Verify the renderer actually changed. `/tui default` applies reliably when sent
# programmatically; `/tui fullscreen` often does not (the completion menu appears to
# swallow it), so a run can silently measure the wrong renderer. tmux's alternate_on
# is a machine interface, not screen text, and it settles the question.
if [ -n "$SOCK" ] && [ -n "$PANE" ]; then
  ALT="$(tmux -L "$SOCK" display -p -t "$PANE" '#{alternate_on}' 2>/dev/null || echo '?')"
  echo "    alternate_on=$ALT  (1 = alternate screen, 0 = normal screen + scrollback)"
  if [ -n "$MODE" ]; then
    case "$MODE" in
      fullscreen) WANT=1;;
      default)    WANT=0;;
      *)          WANT="$ALT";;
    esac
    if [ "$ALT" != "$WANT" ]; then
      echo "!!! renderer did not switch: asked for '$MODE' (alternate_on=$WANT) but pane reports $ALT." >&2
      echo "!!! This run would be mislabelled. Aborting." >&2
      exit 1
    fi
  fi
fi

# The tab MUST be on screen: displayPass intervals only occur if the view draws.
echo "==> foregrounding the tab (this interrupts the user)"
tbd terminal focus --terminal "$TERMID" --activate >/dev/null
sleep 2

echo "==> prompting"
tbd terminal send --terminal "$TERMID" --text "go" >/dev/null
tbd terminal send --terminal "$TERMID" --keys "Enter" >/dev/null
# Proof the prompt actually submitted: the stream request reaches the fake server.
if wait_for "POST /v1/messages" 30 "$OUT/$LABEL.server.log"; then
  echo "    stream started"
else
  echo "!!! prompt never submitted -- capture would be void, aborting" >&2; exit 1
fi
echo "==> capturing $CAPTURE s of signposts"
sleep 3
echo "    load average at capture start: $(sysctl -n vm.loadavg)"
/usr/bin/log stream --style ndjson --signpost --predicate 'subsystem == "com.tbd.app"' \
  > "$OUT/$LABEL.ndjson" 2>"$OUT/$LABEL.err" &
LOGPID=$!
sleep "$CAPTURE"
kill "$LOGPID" 2>/dev/null || true
wait "$LOGPID" 2>/dev/null || true
LOGPID=""

echo
python3 "$DIR/signpost-report.py" "$OUT/$LABEL.ndjson" "$LABEL"

# A window with no display passes means the tab was not on screen: the terminal fed
# and parsed but never drew, so every render number in it is meaningless. Say so
# loudly rather than letting a plausible-looking table be believed.
PASSES="$(python3 - "$OUT/$LABEL.ndjson" <<'PY'
import sys, json, re
n = 0
for line in open(sys.argv[1], errors="replace"):
    line = line.strip().rstrip(",")
    if line.startswith("{") and '"displayPass"' in line and '"begin"' in line:
        n += 1
print(n)
PY
)"
echo
VOID=0
if [ "${PASSES:-0}" -lt 20 ]; then
  echo "*** VOID: only ${PASSES} displayPass begins -- the tab was not drawing." >&2
  echo "*** Re-run with the subject tab on screen; do not report these numbers." >&2
  VOID=1
fi
echo
echo "capture: $OUT/$LABEL.ndjson"
# Fail the run, not just the reader: a caller that only checks the exit code must
# not treat a void capture as a successful measurement.
[ "$VOID" -eq 0 ] || exit 1
