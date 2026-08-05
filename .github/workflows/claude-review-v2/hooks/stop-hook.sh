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

result_file="${CLAUDE_PROJECT_DIR:-$PWD}/review-result.json"

if [ -f "$result_file" ] && jq -e . "$result_file" >/dev/null 2>&1; then
  # Result file exists and parses as JSON — allow the session to end. Schema
  # validation and verdict computation happen in validate.py, which fails closed.
  exit 0
fi

# No parseable result file yet. Nudge the model to write one, but bound the
# number of nudges so a model that genuinely can't/won't comply still terminates
# (the validate step then fails closed, so nothing slips through unreviewed).
# Same rationale and bound as the v1 hook: a single nudge proved too weak on
# large fan-out reviews (#364). The counter persists across hook invocations
# within the one job (one job per runner, so a fixed path is race-free).
max_blocks=5
count_file="${TMPDIR:-/tmp}/claude-review-v2-block-count"
count="$(cat "$count_file" 2>/dev/null || echo 0)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac
if [ "$count" -ge "$max_blocks" ]; then
  exit 0   # give up after max_blocks nudges; validate step fails closed
fi
printf '%s' "$((count + 1))" > "$count_file" 2>/dev/null || exit 0

reason="You have not written the merged review result. Use the Write tool to create 'review-result.json' in the repository root (${CLAUDE_PROJECT_DIR:-the current working directory}). It must be valid JSON matching .github/workflows/claude-review-v2/schemas/review-result.schema.json: an object with 'findings' (the merged findings array), 'disposition' (one entry per specialist finding ID accounting for what happened to it: kept/merged/downgraded/dropped, with a note when downgraded or dropped), and 'comment_body' (the review comment markdown the workflow posts). Do NOT write a verdict anywhere — the verdict is computed by a script from the findings' severities. The session cannot end until this file exists and parses as JSON."

jq -n --arg reason "$reason" '{decision: "block", reason: $reason}' 2>/dev/null \
  || printf '{"decision":"block","reason":"Write review-result.json (valid JSON per schemas/review-result.schema.json) in the repository root before stopping."}\n'
exit 0
