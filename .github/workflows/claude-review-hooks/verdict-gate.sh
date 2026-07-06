#!/usr/bin/env bash
# Stop hook for the Claude PR-review session.
# Part of the merge gate documented in docs/pr-review-gate.md.
#
# Refuses to let the review session end until it has recorded a clean,
# machine-readable verdict in claude-verdict.txt. The workflow's merge gate reads
# that file with an EXACT string comparison (no regex), so this hook is what makes
# the capture deterministic: the file must contain exactly APPROVE or REJECT and
# nothing else before the session is allowed to stop. All human-readable
# justification lives in the sticky comment, never in the verdict file.
#
# Contract (Claude Code Stop hook):
#   - stdin: JSON with at least { "stop_hook_active": bool }
#   - to allow the stop: exit 0 with no decision
#   - to block the stop:  print {"decision":"block","reason":"..."} and exit 0
#     (the reason is fed back to the model so it knows what to fix)
set -uo pipefail

cat >/dev/null   # drain stdin (the Stop-hook JSON); we gate on the file + a counter

verdict_file="${CLAUDE_PROJECT_DIR:-$PWD}/claude-verdict.txt"

if [ -f "$verdict_file" ]; then
  verdict="$(tr -d '[:space:]' < "$verdict_file" 2>/dev/null || echo "")"
  if [ "$verdict" = "APPROVE" ] || [ "$verdict" = "REJECT" ]; then
    # Clean verdict recorded — allow the session to end.
    exit 0
  fi
fi

# No valid verdict yet. Nudge the model to write one, but bound the number of
# nudges so a model that genuinely can't/won't comply still terminates (the
# enforce step then fails closed, so nothing slips through unreviewed). A single
# nudge proved too weak on large fan-out reviews (#364: the agent stopped
# subtype=success at 31 turns after one block without writing the file), so we
# allow several. The counter persists across hook invocations within the one job
# (one job per runner, so a fixed path is race-free).
max_blocks=5
count_file="${TMPDIR:-/tmp}/claude-verdict-block-count"
count="$(cat "$count_file" 2>/dev/null || echo 0)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac
if [ "$count" -ge "$max_blocks" ]; then
  exit 0   # give up after max_blocks nudges; enforce step fails closed
fi
printf '%s' "$((count + 1))" > "$count_file"

reason="You have not recorded a machine-readable review verdict. Use the Write tool to create the file 'claude-verdict.txt' in the repository root (${CLAUDE_PROJECT_DIR:-the current working directory}) containing EXACTLY one uppercase word and nothing else — either APPROVE or REJECT. No punctuation, no emoji, no explanation, no trailing text. Write APPROVE only if the PR has no unaddressed High or Medium severity issues; otherwise write REJECT. Keep all justification in the sticky review comment, not in this file. This is mandatory — the merge gate reads this file and the session cannot end without it. After the file contains exactly APPROVE or REJECT you may stop."

jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
exit 0
