"""Guardrail: redirect upstream brainstorming to TBD's vendored skill.

TBD vendors an adapted copy of superpowers' brainstorming skill at
`.claude/skills/tbd-brainstorming/`. The adaptations are load-bearing: it writes
specs to `docs/specs/`, carries TBD's blast-radius triggers and the
"a human answers the questions" rule, and does not hand off to a skill whose own
file would trip this repo's plans-guard. Running the upstream skill instead
silently loses all of that.

Unlike inferring *whether* a brainstorm happened — which no hook can see — this
is a string comparison, so it is safe to deny rather than merely inform: the
correct action is unambiguous and the agent can immediately re-invoke.
"""

from __future__ import annotations

from guardrails.lib.rule import Decision, Rule

# Skill identifiers that mean "the upstream brainstorming skill". A bare
# `brainstorming` is included because no project skill by that name exists here
# (ours is `tbd-brainstorming`), so it can only resolve to a non-TBD copy.
_REDIRECTED = frozenset({"brainstorming", "superpowers:brainstorming"})

_MESSAGE = (
    "[brainstorming-skill] Blocked: use TBD's vendored `tbd-brainstorming` skill, "
    "not the upstream one. TBD's copy writes the spec to docs/specs/, carries the "
    "blast-radius triggers, and enforces that a human — not you — answers the "
    "brainstorming questions. Fix: invoke the skill `tbd-brainstorming` instead."
)


class BrainstormingSkillRule(Rule):
    id = "brainstorming-skill"
    description = "Redirect superpowers:brainstorming to TBD's vendored tbd-brainstorming skill."
    tools = {"Skill"}

    def check(self, tool_input: dict, _ctx: dict) -> "Decision | None":
        skill = (tool_input.get("skill", "") or "").strip()
        if skill.lower() in _REDIRECTED:
            return Decision.deny(_MESSAGE)
        return None


RULES = [BrainstormingSkillRule()]
