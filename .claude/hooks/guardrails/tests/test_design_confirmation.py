import os
import re
import sys
import tempfile
import unittest

_HOOKS_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _HOOKS_DIR not in sys.path:
    sys.path.insert(0, _HOOKS_DIR)

from guardrails.rules.design_confirmation import (  # noqa: E402
    CONFIRMATION_RE,
    DesignConfirmationRule,
)

_REPO_ROOT = os.path.dirname(os.path.dirname(_HOOKS_DIR))
_PREPARE = os.path.join(_REPO_ROOT, ".github", "workflows", "claude-review-v2", "prepare.py")


def _check(command):
    return DesignConfirmationRule().check({"command": command}, {"cwd": "/repo"})


class DesignConfirmationDenyTests(unittest.TestCase):
    def _assert_denied(self, command):
        d = _check(command)
        assert d is not None, command
        self.assertEqual(d.action, "deny")
        self.assertIn("[design-confirmation]", d.reason)
        self.assertIn("human", d.reason)

    def test_denies_rest_inline_review_comment(self):
        self._assert_denied(
            "gh api repos/acme/acme-app/pulls/12/comments "
            "-f path=docs/specs/2026-01-01-acme-design.md -F line=3 "
            "-f body='I confirmed the design'"
        )

    def test_denies_rest_review_with_comments(self):
        self._assert_denied(
            "gh api -X POST repos/acme/acme-app/pulls/12/reviews "
            "-f event=COMMENT -f 'comments[][body]=i have CONFIRMED the design'"
        )

    def test_denies_gh_pr_review_and_comment(self):
        self._assert_denied('gh pr review 12 --comment --body "I confirmed the design"')
        self._assert_denied('gh -R acme/acme-app pr comment 12 -b "I confirmed the design."')
        self._assert_denied('/opt/homebrew/bin/gh pr comment 12 -b "I confirmed the design"')

    def test_denies_graphql_review_mutation(self):
        self._assert_denied(
            "gh api graphql -f query='mutation { addPullRequestReviewThread(input: "
            '{body: "I confirmed the design"}) { thread { id } } }\''
        )

    def test_denies_reply_and_edit_of_an_existing_review_comment(self):
        # A thread reply is itself a spec-path review comment, and an edit can
        # turn an existing comment into the phrase; the gate counts both.
        self._assert_denied(
            "gh api repos/acme/acme-app/pulls/comments/5/replies "
            "-f body='I confirmed the design'"
        )
        self._assert_denied(
            "gh api -X PATCH repos/acme/acme-app/pulls/comments/9 "
            "-f body='I confirmed the design'"
        )

    def test_denies_graphql_query_read_from_a_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "q.graphql")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(
                    'mutation { addPullRequestReviewThreadReply(input: '
                    '{body: "I confirmed the design"}) { comment { id } } }'
                )
            self._assert_denied(f"gh api graphql -F query=@{path}")

    def test_denies_a_post_inside_an_executed_heredoc(self):
        self._assert_denied(
            "bash <<'EOF'\ngh pr review 12 --comment --body 'I confirmed the design'\nEOF"
        )
        self._assert_denied(
            "cat <<'EOF' | sh\ngh pr comment 12 -b 'I confirmed the design'\nEOF"
        )

    def test_allows_a_written_heredoc_that_mentions_a_post(self):
        self.assertIsNone(
            _check(
                "cat > notes.md <<'EOF'\nrun gh pr review 12 --body 'I confirmed the design'\nEOF"
            )
        )

    def test_denies_curl_to_the_rest_api(self):
        self._assert_denied(
            "curl -X POST https://api.github.com/repos/acme/acme-app/pulls/12/comments "
            "-d '{\"body\": \"I confirmed the design\"}'"
        )

    def test_denies_phrase_in_a_heredoc_body(self):
        self._assert_denied(
            "gh pr review 12 --comment --body \"$(cat <<'EOF'\n"
            "Read it twice.\nI confirmed the design\nEOF\n)\""
        )

    def test_denies_phrase_in_a_named_body_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
            fh.write("Looks right.\nI confirmed the design\n")
            path = fh.name
        try:
            self._assert_denied(f"gh pr review 12 --comment --body-file {path}")
            self._assert_denied(f"gh pr comment 12 -F '{path}'")
            self._assert_denied(
                f"gh api repos/acme/acme-app/pulls/12/comments -F body=@{path} -f path=x"
            )
            self._assert_denied(f"gh api repos/acme/acme-app/pulls/12/reviews --input {path}")
        finally:
            os.unlink(path)


class DesignConfirmationAllowTests(unittest.TestCase):
    def test_allows_review_comments_without_the_phrase(self):
        self.assertIsNone(_check('gh pr review 12 --comment --body "Looks good to me"'))
        self.assertIsNone(
            _check("gh api repos/acme/acme-app/pulls/12/comments -f body='nit: typo'")
        )

    def test_allows_reading_review_comments(self):
        # The rule cannot tell a GET from a POST by regex, so a read stays
        # silent only because the phrase is absent — which it is for every
        # ordinary read, such as the gate's own fetch.
        self.assertIsNone(_check("gh api --paginate repos/acme/acme-app/pulls/12/comments"))

    def test_allows_the_phrase_outside_a_review_post(self):
        # Writing the rule into a doc or a commit message is not posting it.
        self.assertIsNone(
            _check("git commit -m 'docs: a human leaves I confirmed the design on the spec'")
        )
        self.assertIsNone(
            _check("cat > docs/x.md <<'EOF'\nleave \"I confirmed the design\"\nEOF")
        )
        self.assertIsNone(_check('gh pr create --title t --body "I confirmed the design"'))
        self.assertIsNone(_check('gh issue comment 3 --body "I confirmed the design"'))

    def test_allows_a_post_mentioned_only_inside_a_heredoc_body(self):
        # Writing a doc or script that describes the rule is not posting it:
        # both the posting command and the phrase live in the heredoc body.
        self.assertIsNone(
            _check(
                "python3 - <<'PY'\n"
                "doc = 'run gh pr review, or gh api repos/o/r/pulls/1/comments, "
                "with I confirmed the design'\n"
                "PY"
            )
        )

    def test_allows_a_negation(self):
        self.assertIsNone(_check('gh pr comment 12 -b "I have not confirmed the design"'))

    def test_unreadable_body_file_is_not_a_deny(self):
        self.assertIsNone(_check("gh pr review 12 --comment --body-file /nonexistent/acme.md"))

    def test_tolerates_missing_command(self):
        self.assertIsNone(DesignConfirmationRule().check({}, {"cwd": "/repo"}))


class DesignConfirmationPhraseSyncTests(unittest.TestCase):
    def test_phrase_regex_matches_the_review_gate(self):
        # The phrase the gate counts must be exactly the phrase agents are
        # blocked from posting; a drift on either side reopens the hole.
        with open(_PREPARE, encoding="utf-8") as fh:
            source = fh.read()
        match = re.search(r'^CONFIRMATION_RE = re\.compile\(r"(.+?)", re\.IGNORECASE\)$',
                          source, re.MULTILINE)
        assert match is not None, "prepare.py no longer defines CONFIRMATION_RE in this form"
        self.assertEqual(match.group(1), CONFIRMATION_RE.pattern)
        self.assertTrue(CONFIRMATION_RE.flags & re.IGNORECASE)


if __name__ == "__main__":
    unittest.main()
