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

input="$(cat)"
stop_active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"

verdict_file="${CLAUDE_PROJECT_DIR:-$PWD}/claude-verdict.txt"

if [ -f "$verdict_file" ]; then
  verdict="$(tr -d '[:space:]' < "$verdict_file" 2>/dev/null || echo "")"
  if [ "$verdict" = "APPROVE" ] || [ "$verdict" = "REJECT" ]; then
    # Clean verdict recorded — allow the session to end.
    exit 0
  fi
fi

# Guard against an infinite stop loop: if we've already blocked once and the
# session still hasn't produced a valid file, allow the stop. The workflow's
# enforce step then fails closed (blocks merge) because the file is missing or
# malformed, so nothing slips through unreviewed.
if [ "$stop_active" = "true" ]; then
  exit 0
fi

reason="You have not recorded a machine-readable review verdict. Use the Write tool to create the file 'claude-verdict.txt' in the repository root (${CLAUDE_PROJECT_DIR:-the current working directory}) containing EXACTLY one uppercase word and nothing else — either APPROVE or REJECT. No punctuation, no emoji, no explanation, no trailing text. Write APPROVE only if the PR has no unaddressed High or Medium severity issues; otherwise write REJECT. Keep all justification in the sticky review comment, not in this file. After the file contains exactly APPROVE or REJECT you may stop."

jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
exit 0
