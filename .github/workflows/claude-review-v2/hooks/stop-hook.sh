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
# are still running and the hook sleeps, then holds WITHOUT consuming its nudge
# budget — bounded by a 25-minute wall clock. Once every findings file is
# present and only the merge is missing, the model has what it needs and the
# bounded nudge applies. Conflating the two is what let a session exit 3 minutes
# into a 14-minute review
# (docs/specs/2026-08-10-review-orchestrator-liveness-design.md).
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

# jq is probed once and every file check goes through json_ready. Without jq,
# "present and non-empty" is the strongest evidence available, and accepting it
# is the fail-safe direction: reading a finished review as unfinished would tell
# the orchestrator its specialists are still running — a falsehood that invites
# it to re-spawn duplicates, and that holds the session for the full deadline
# over a missing binary. Content that is present but malformed is caught
# downstream by validate.py, which schema-validates and fails closed.
have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

json_ready() {
  { [ -f "$1" ] && [ -s "$1" ]; } || return 1
  [ "$have_jq" -eq 1 ] || return 0
  jq -e . "$1" >/dev/null 2>&1
}

if json_ready "$result_file"; then
  # Result file exists and parses as JSON — allow the session to end. Schema
  # validation and verdict computation happen in validate.py, which fails closed.
  exit 0
fi

# State files persist across hook invocations within the one job (one job per
# runner, so fixed paths are race-free). A future loop that invokes the session
# more than once MUST reset ALL THREE — the nudge counter, the start stamp, and
# the hold counter: a stale counter at its ceiling disarms the nudge, a stale
# hold counter at its cap disarms the hold, and a stale start stamp disarms the
# hold a second way by putting the deadline in the past. All three failures are
# silent.
state_dir="${TMPDIR:-/tmp}"
count_file="$state_dir/claude-review-v2-block-count"
start_file="$state_dir/claude-review-v2-hold-started"
hold_file="$state_dir/claude-review-v2-hold-count"

# Which findings files must exist before the orchestrator can possibly merge.
# Declared once at job level in the workflow and shared with validate.py's
# --expected-specialists, so the hook and the validator cannot disagree.
specialists="${REVIEW_SPECIALISTS:-correctness,conventions}"

# `:-` substitutes on unset or EMPTY only, so a value that is non-empty and yet
# names nobody — ",", "   ", ",," — survives it. The loop below would then
# iterate over nothing: findings_pending stays 0, the hook falls into the
# counted nudge, and the hold is disarmed silently and in the fail-OPEN
# direction. validate.py rejects the same input outright; a Stop hook cannot
# (it must always exit 0), so the analogue is to treat it exactly as an absent
# variable — cleared here and re-expanded so the default stays a single literal,
# which is what the drift check in tests/test_workflow_structure.py pins.
case "$specialists" in
  *[![:space:],]*) ;;   # names at least one specialist
  *) unset REVIEW_SPECIALISTS
     specialists="${REVIEW_SPECIALISTS:-correctness,conventions}" ;;
esac

findings_pending=0
for name in $(printf '%s' "$specialists" | tr ',' ' '); do
  [ -n "$name" ] || continue
  findings_file="$workdir/findings-$name.json"
  json_ready "$findings_file" || findings_pending=1
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

  # WHY THE HOLD SLEEPS, AND THE ARITHMETIC THAT MAKES THE BOUNDS AGREE.
  #
  # Every hold is a block, and every block costs one turn of the session's
  # --max-turns 100 budget. Turns, not seconds, are what the session runs out
  # of: PR #604 burned 35 turns in 184 s (~5 s per turn), leaving ~65. Held at
  # that rate those 65 turns cover about 5 minutes of wall clock — less than
  # the ~10 minutes the specialists need — so the session would die of turn
  # exhaustion with the 25-minute deadline never reached, in exactly the case
  # the deadline exists for. Sleeping converts a turn into wall clock at zero
  # token cost, which is the currency that is short. At 30 s per hold, ~65
  # remaining turns cover ~32 minutes, so the wall clock binds first.
  #
  # The two bounds are consistent by the same arithmetic: 60 holds x 30 s =
  # 1800 s of sleep against a 1500 s deadline, so the deadline is always
  # reached first and the hold cap is only a backstop for a broken clock. 60
  # holds also sits under the ~65 turns the budget leaves, so neither bound
  # asks for turns the session does not have.
  #
  # The Stop hook's command timeout in hooks/settings.json (60 s) must stay
  # strictly greater than this sleep: a hook killed mid-sleep emits no block,
  # and the session ends. The env override exists so the unit tests need not
  # spend 30 s per invocation; the job sets it nowhere, so production is 30 s
  # with no configuration.
  hold_sleep_seconds="${REVIEW_HOLD_SLEEP_SECONDS:-30}"
  case "$hold_sleep_seconds" in ''|*[!0-9]*) hold_sleep_seconds=30 ;; esac

  now="$(date +%s 2>/dev/null || echo 0)"
  started="$(cat "$start_file" 2>/dev/null || echo '')"
  case "$started" in
    ''|*[!0-9]*)
      started="$now"
      # Both bounds are made of persisted state: with nowhere to write, the
      # stamp reads as "now" on every invocation and elapsed time is always 0,
      # while the hold counter never leaves 0 — the hook would then hold
      # forever, which is the one outcome the fail-safe contract forbids.
      # Releasing instead costs a failed review that a human re-runs; holding
      # costs a wedged runner.
      printf '%s' "$now" > "$start_file" 2>/dev/null || exit 0
      ;;
  esac

  holds="$(cat "$hold_file" 2>/dev/null || echo 0)"
  case "$holds" in ''|*[!0-9]*) holds=0 ;; esac

  # Both bounds are tested BEFORE the sleep. Sleeping and then releasing would
  # buy nothing and spend runner minutes doing it.
  if [ "$((now - started))" -ge "$hold_deadline_seconds" ] \
     || [ "$holds" -ge "$max_holds" ]; then
    exit 0   # deadline reached; validate.py fails closed with a stall report
  fi
  printf '%s' "$((holds + 1))" > "$hold_file" 2>/dev/null || exit 0

  # Hold the turn open in wall clock rather than in turns. The specialists run
  # in the same process, so this sleep is time they get to finish in.
  [ "$hold_sleep_seconds" -eq 0 ] || sleep "$hold_sleep_seconds"

  # The reason asks for a bare acknowledgment and NO tool calls, because the
  # sleep arithmetic above prices a hold at one turn. Every tool call the model
  # makes while waiting is another turn, so inviting it to poll for the files
  # halves the wall clock the turn budget buys — and buys nothing, since this
  # hook just checked those files and will check them again on the next stop
  # attempt.
  hold_reason="Your specialist subagents are still running — at least one findings-<name>.json is not yet on disk. Do NOT end your turn. This session is headless: ending the turn ends the whole session and kills the specialists with it, so no findings are ever written and the review gate fails with no verdict. Do NOT call any tools while waiting: this hook is already checking the files for you and will keep holding until they land, and every tool call spends turn budget the wait needs. Reply with one short sentence acknowledging that you are waiting. When every findings file is on disk you will be allowed to stop, so merge them into review-result.json then. Expected specialists: ${specialists}."

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
