"""Tests for check_user_story.py. Stdlib unittest; run with
`python3 -m unittest discover -s .github/workflows/pr-user-story/tests`."""

from __future__ import annotations

import io
import os
import sys
import unittest
from contextlib import redirect_stdout
from unittest import mock

_SCRIPT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

import check_user_story as cus  # noqa: E402

_TEMPLATE_SECTION = """\
## User story

<!-- As a <who>, I want <what>, so that <why>. The CI check requires this. -->

## Summary

Some summary.
"""

_FILLED = """\
## User story

As a reviewer, I want every feature PR to say who it serves, so that I can judge it.

## Summary

Text.
"""


class ExemptTitleTests(unittest.TestCase):
    def test_each_exempt_type(self):
        for kind in cus.EXEMPT_TYPES:
            with self.subTest(kind=kind):
                self.assertTrue(cus.is_exempt(f"{kind}: something"))

    def test_scoped_and_bang_prefixes(self):
        for title in ("fix(app): x", "docs(spec)!: x", "ci!: x", "chore(deps) : x"):
            with self.subTest(title=title):
                self.assertTrue(cus.is_exempt(title))

    def test_mixed_case_exempt(self):
        self.assertTrue(cus.is_exempt("Fix: the thing"))
        self.assertTrue(cus.is_exempt("DOCS: the thing"))

    def test_github_revert_button_title(self):
        self.assertTrue(cus.is_exempt('Revert "feat: add a thing"'))

    def test_feature_types_not_exempt(self):
        for title in ("feat: x", "Feat: x", "feat(app)!: x", "refactor: x", "perf: x"):
            with self.subTest(title=title):
                self.assertFalse(cus.is_exempt(title))

    def test_untyped_title_not_exempt(self):
        self.assertFalse(cus.is_exempt("Add a repository from its URL"))
        self.assertFalse(cus.is_exempt(""))

    def test_type_must_be_whole_word(self):
        # `fixture:` and `testing:` are not the `fix` or `test` types.
        self.assertFalse(cus.is_exempt("fixture: x"))
        self.assertFalse(cus.is_exempt("testing: x"))
        self.assertFalse(cus.is_exempt("fix the bug"))


class UserStorySectionTests(unittest.TestCase):
    def test_missing_section(self):
        self.assertFalse(cus.has_user_story("## Summary\n\nWords.\n"))
        self.assertFalse(cus.has_user_story(""))
        self.assertFalse(cus.has_user_story(None))

    def test_section_with_only_template_comment(self):
        self.assertFalse(cus.has_user_story(_TEMPLATE_SECTION))

    def test_section_with_only_whitespace(self):
        self.assertFalse(cus.has_user_story("## User story\n\n   \n\n## Summary\nx\n"))

    def test_section_at_end_with_only_comment(self):
        self.assertFalse(cus.has_user_story("## User story\n<!-- todo -->\n"))

    def test_unclosed_comment_counts_as_empty(self):
        self.assertFalse(cus.has_user_story("## User story\n<!-- As a <who>\n"))

    def test_heading_inside_comment_opens_nothing(self):
        body = "<!--\n## User story\nAs a user, I want x.\n-->\n## Summary\nx\n"
        self.assertFalse(cus.has_user_story(body))

    def test_filled_section(self):
        self.assertTrue(cus.has_user_story(_FILLED))

    def test_jtbd_form_inside(self):
        body = "## User story\n\nWhen I open a PR, I want to say why, so I can be reviewed fast.\n"
        self.assertTrue(cus.has_user_story(body))

    def test_alias_headings(self):
        for heading in ("## Job to be done", "## JTBD", "## job TO be DONE", "### User Story"):
            with self.subTest(heading=heading):
                self.assertTrue(cus.has_user_story(f"{heading}\n\nAs a user, I want x.\n"))

    def test_heading_case_insensitive(self):
        self.assertTrue(cus.has_user_story("## USER STORY\nAs a user, I want x.\n"))

    def test_content_in_other_section_does_not_count(self):
        body = "## User story\n\n## Summary\n\nAs a user, I want x.\n"
        self.assertFalse(cus.has_user_story(body))

    def test_unrelated_heading_text_not_a_story(self):
        self.assertFalse(cus.has_user_story("## User story notes\nAs a user.\n"))


class CheckTests(unittest.TestCase):
    def test_exempt_title_passes_without_story(self):
        self.assertTrue(cus.check("fix: x", ""))

    def test_feature_without_story_fails(self):
        self.assertFalse(cus.check("Feat: x", _TEMPLATE_SECTION))

    def test_untyped_without_story_fails(self):
        self.assertFalse(cus.check("Add a thing", "## Summary\nx\n"))

    def test_feature_with_story_passes(self):
        self.assertTrue(cus.check("feat: x", _FILLED))


class MainTests(unittest.TestCase):
    def _run(self, title, body):
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"PR_TITLE": title, "PR_BODY": body}), redirect_stdout(out):
            code = cus.main()
        return code, out.getvalue()

    def test_failure_exits_nonzero_with_both_forms(self):
        code, out = self._run("feat: x", _TEMPLATE_SECTION)
        self.assertEqual(code, 1)
        self.assertIn("::error", out)
        self.assertIn("As a <who>, I want <what>, so that <why>.", out)
        self.assertIn("When <situation>, I want to <motivation>, so I can <outcome>.", out)
        self.assertIn("`fix:`", out)

    def test_pass_exits_zero(self):
        self.assertEqual(self._run("feat: x", _FILLED)[0], 0)
        self.assertEqual(self._run("fix: x", "")[0], 0)

    def test_missing_env_fails_closed(self):
        out = io.StringIO()
        with mock.patch.dict(os.environ, {}, clear=True), redirect_stdout(out):
            self.assertEqual(cus.main(), 1)


if __name__ == "__main__":
    unittest.main()
