#!/usr/bin/env bash
# Stop hook for the claude-review-v2 session.
# Part of the PR review v2 pipeline (docs/specs/2026-08-03-pr-review-fanout-design.md §3.5).
#
# Refuses to let the review session end until review-result.json exists in the
# workspace root and parses as JSON. Unlike the v1 hook (claude-review-hooks/
# verdict-gate.sh), this hook does NOT gate on a verdict token — the model never
# types the verdict in v2. The validate script computes APPROVE/REJECT from the
# result file's findings, schema-validates it, and fails closed if the file is
# missing or invalid; this hook only ensures the session doesn't end before the
# file exists at all.
#
# It distinguishes two reasons the file is absent, because the right response
# differs. While an expected findings-<name>.json is missing, the specialists
# are still running and the hook holds WITHOUT consuming its nudge budget —
# bounded by a 25-minute wall clock. Once every findings file is present and
# only the merge is missing, the model has what it needs and the bounded nudge
# applies. Conflating the two is what let a session exit 3 minutes into a
# 14-minute review (docs/specs/2026-08-10-review-orchestrator-liveness-design.md).
#
# Contract (Claude Code Stop hook):
#   - stdin: JSON with at least { "stop_hook_active": bool }
#   - to allow the stop: exit 0 with no decision
#   - to block the stop:  print {"decision":"block","reason":"..."} and exit 0
#     (the reason is fed back to the model so it knows what to fix)
#
# Fail-safe: this script must ALWAYS exit 0. Malformed or empty stdin, a missing
# jq, an unwritable counter file — none of these may wedge the session; the
# validate/enforce steps fail closed downstream, so allowing a stop is never a
# gate bypass.
set -uo pipefail

cat >/dev/null 2>&1 || true   # drain stdin; its content is never parsed, so
                              # malformed/empty stdin can never block or error

workdir="${CLAUDE_PROJECT_DIR:-$PWD}"
result_file="$workdir/review-result.json"

if [ -f "$result_file" ] && jq -e . "$result_file" >/dev/null 2>&1; then
  # Result file exists and parses as JSON — allow the session to end. Schema
  # validation and verdict computation happen in validate.py, which fails closed.
  exit 0
fi

# State files persist across hook invocations within the one job (one job per
# runner, so fixed paths are race-free). A future loop that invokes the session
# more than once MUST reset BOTH: a stale counter at the ceiling disarms the
# nudge, and a stale start stamp disarms the hold by putting the deadline in
# the past. Both failures are silent.
state_dir="${TMPDIR:-/tmp}"
count_file="$state_dir/claude-review-v2-block-count"
start_file="$state_dir/claude-review-v2-hold-started"

# Which findings files must exist before the orchestrator can possibly merge.
# Declared once at job level in the workflow and shared with validate.py's
# --expected-specialists, so the hook and the validator cannot disagree.
specialists="${REVIEW_SPECIALISTS:-correctness,conventions}"

findings_pending=0
for name in $(printf '%s' "$specialists" | tr ',' ' '); do
  [ -n "$name" ] || continue
  findings_file="$workdir/findings-$name.json"
  if [ ! -f "$findings_file" ] || ! jq -e . "$findings_file" >/dev/null 2>&1; then
    findings_pending=1
  fi
done

if [ "$findings_pending" -eq 1 ]; then
  # THE SPECIALISTS ARE STILL RUNNING. Blocking here is what keeps the process
  # — and the in-flight specialists with it — alive: headless, a turn that ends
  # ends the session. This hold does NOT consume the nudge budget below, which
  # exists for a model that won't comply, not one that can't comply yet.
  # Conflating the two is what released a session 3 minutes into a 14-minute
  # job (spec docs/specs/2026-08-10-review-orchestrator-liveness-design.md §1).
  #
  # Bounded two ways. The wall-clock deadline is the real bound; the hold count
  # is a defensive backstop so a broken clock cannot make the session
  # unstoppable. Past either, we give up and validate.py fails closed.
  hold_deadline_seconds=1500   # 25 minutes (spec §2)
  max_holds=60

  now="$(date +%s 2>/dev/null || echo 0)"
  started="$(cat "$start_file" 2>/dev/null || echo '')"
  case "$started" in
    ''|*[!0-9]*)
      started="$now"
      printf '%s' "$now" > "$start_file" 2>/dev/null || true
      ;;
  esac

  hold_file="$state_dir/claude-review-v2-hold-count"
  holds="$(cat "$hold_file" 2>/dev/null || echo 0)"
  case "$holds" in ''|*[!0-9]*) holds=0 ;; esac

  if [ "$((now - started))" -ge "$hold_deadline_seconds" ] \
     || [ "$holds" -ge "$max_holds" ]; then
    exit 0   # deadline reached; validate.py fails closed with a stall report
  fi
  printf '%s' "$((holds + 1))" > "$hold_file" 2>/dev/null || true

  hold_reason="Your specialist subagents are still running — at least one findings-<name>.json is not yet on disk. Do NOT end your turn. This session is headless: ending the turn ends the whole session and kills the specialists with it, so no findings are ever written and the review gate fails with no verdict. Stay in this turn until every expected findings file exists and parses, then merge them into review-result.json. Expected specialists: ${specialists}."

  jq -n --arg reason "$hold_reason" '{decision: "block", reason: $reason}' 2>/dev/null \
    || printf '{"decision":"block","reason":"Specialists still running — do NOT end your turn; the session is headless and ending it kills them."}\n'
  exit 0
fi

# Every findings file is present and parses, and there is still no result file:
# the model has everything it needs and is not writing the merge. THIS is the
# state the nudge ceiling was designed for — bound it so a model that genuinely
# can't or won't comply still terminates (validate.py then fails closed).
max_blocks=5
count="$(cat "$count_file" 2>/dev/null || echo 0)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac
if [ "$count" -ge "$max_blocks" ]; then
  exit 0   # give up after max_blocks nudges; validate step fails closed
fi
printf '%s' "$((count + 1))" > "$count_file" 2>/dev/null || exit 0

reason="You have not written the merged review result. Use the Write tool to create 'review-result.json' in the repository root (${workdir}). It must be valid JSON matching .github/workflows/claude-review-v2/schemas/review-result.schema.json: an object with 'findings' (the merged findings array), 'disposition' (one entry per specialist finding ID accounting for what happened to it: kept/merged/downgraded/dropped, with a note when downgraded or dropped), and 'comment_body' (the review comment markdown the workflow posts). Do NOT write a verdict anywhere — the verdict is computed by a script from the findings' severities. The session cannot end until this file exists and parses as JSON."

jq -n --arg reason "$reason" '{decision: "block", reason: $reason}' 2>/dev/null \
  || printf '{"decision":"block","reason":"Write review-result.json (valid JSON per schemas/review-result.schema.json) in the repository root before stopping."}\n'
exit 0
