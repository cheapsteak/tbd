import os
import sys
import unittest

_HOOKS_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)

from guardrails.rules.brainstorming_skill import BrainstormingSkillRule  # noqa: E402


def _check(skill):
    return BrainstormingSkillRule().check({"skill": skill}, {"cwd": "/repo"})


class BrainstormingSkillTests(unittest.TestCase):
    def test_denies_upstream_brainstorming(self):
        d = _check("superpowers:brainstorming")
        assert d is not None
        self.assertEqual(d.action, "deny")
        self.assertIn("tbd-brainstorming", d.reason)
        self.assertIn("[brainstorming-skill]", d.reason)

    def test_denies_bare_brainstorming(self):
        d = _check("brainstorming")
        assert d is not None
        self.assertEqual(d.action, "deny")

    def test_allows_the_local_skill(self):
        self.assertIsNone(_check("tbd-brainstorming"))

    def test_allows_writing_plans(self):
        # The sanctioned terminal state — must never be blocked.
        self.assertIsNone(_check("superpowers:writing-plans"))

    def test_allows_unrelated_skills(self):
        self.assertIsNone(_check("tbd-project"))
        self.assertIsNone(_check("superpowers:systematic-debugging"))

    def test_tolerates_missing_skill_key(self):
        self.assertIsNone(BrainstormingSkillRule().check({}, {}))

    def test_applies_only_to_the_skill_tool(self):
        self.assertEqual(BrainstormingSkillRule.tools, {"Skill"})


if __name__ == "__main__":
    unittest.main()
