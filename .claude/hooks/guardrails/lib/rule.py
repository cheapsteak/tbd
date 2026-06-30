"""Rule base type and Decision value for the guardrails framework.

A guardrail Rule inspects a tool invocation and returns a Decision (or None).
Rules are stdlib-only and must never raise during normal operation; dispatch.py
fails open on any exception, but a well-behaved rule returns None when it has no
opinion rather than relying on the fail-open path.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Decision:
    """The outcome of a rule's `check`.

    action is "deny" or "allow". A "deny" carries an instructive `reason` that is
    fed back to the model (via permissionDecisionReason) so it can self-correct.
    """

    action: str
    reason: str = ""

    @staticmethod
    def deny(reason: str) -> "Decision":
        return Decision(action="deny", reason=reason)

    @staticmethod
    def allow() -> "Decision":
        return Decision(action="allow", reason="")


class Rule:
    """Base class for guardrail rules.

    Subclasses set the class attributes and implement `check`:
      - id: stable identifier, prefixed onto deny reasons and shown by --list
      - description: one-line human description
      - tools: set of tool_name values this rule applies to (e.g. {"Bash"})

    `check` returns a Decision or None. None means "no opinion" (allow). Only
    return Decision.deny(...) when you are confident the call should be blocked;
    err toward None to avoid false positives.
    """

    id: str = "unnamed-rule"
    description: str = ""
    tools: set[str] = set()

    def check(self, _tool_input: dict, _ctx: dict) -> "Decision | None":
        raise NotImplementedError
