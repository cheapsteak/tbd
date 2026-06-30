"""Pin the registry's per-module import isolation.

Contract (registry.py docstring): "one broken rule file can never take down the
whole guardrail set." A rule module with a SyntaxError or a missing import must be
skipped, while every other rule still loads. Without the per-module try/except,
the import exception propagates out of load_rules() and the dispatcher's outer
fail-open catch drops ALL rules — the bug this test guards against.
"""

import importlib
import os
import sys
import unittest

# Make the `guardrails` package importable (.claude/hooks on sys.path).
_HOOKS_DIR = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)

from guardrails.lib.registry import load_rules  # noqa: E402

_RULES_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "rules"
)


class RegistryIsolationTests(unittest.TestCase):
    """A broken rule module is skipped; healthy rules still load."""

    BROKEN_MODULE = "_zz_broken_under_test"  # leading-underscore-free so it's discovered

    def setUp(self):
        # A discoverable module name (no leading underscore) that fails to import.
        self.module_name = "zz_broken_under_test"
        self.module_path = os.path.join(_RULES_DIR, f"{self.module_name}.py")
        with open(self.module_path, "w", encoding="utf-8") as handle:
            handle.write("import a_module_that_does_not_exist_xyz  # noqa\n")

    def tearDown(self):
        try:
            os.remove(self.module_path)
        except FileNotFoundError:
            pass
        sys.modules.pop(f"guardrails.rules.{self.module_name}", None)
        importlib.invalidate_caches()

    def test_broken_rule_module_is_skipped_others_survive(self):
        rules = load_rules()
        ids = {getattr(rule, "id", None) for rule in rules}
        # The healthy real rule must survive despite the broken sibling.
        self.assertIn("background-jobs", ids)
        # The broken module contributes no rules.
        self.assertNotIn("zz_broken_under_test", ids)


if __name__ == "__main__":
    unittest.main()
