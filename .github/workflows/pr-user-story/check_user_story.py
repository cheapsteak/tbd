#!/usr/bin/env python3
"""Require a user story in the description of every feature PR.

A PR whose title is not exempt must carry a `## User story` section (also
spelled `## Job to be done` or `## JTBD`) with real prose in it. Design and
rationale: docs/specs/2026-10-20-pr-user-story-check-design.md.

Two callers share this module, so the rule is defined once:

- the `pr-user-story` workflow, which runs `main()` with the title and body in
  the `PR_TITLE` and `PR_BODY` environment variables and fails the check on a
  non-zero exit;
- the `pr-user-story` guardrail (`.claude/hooks/guardrails/rules/`), which loads
  this file by path and calls `check()` on the title and body a `gh pr create`
  is about to send.

Stdlib only: the guardrail runs in front of every Bash call with no
dependencies installed. Pure policy functions take plain strings; `main()` is
the only I/O.
"""

from __future__ import annotations

import os
import re
import sys

# Conventional-commit types whose PRs need no user story. A bug fix restores
# the system to its existing theory and the rest change no user-facing
# behavior; everything else — `feat`, `refactor`, `perf`, an untyped title —
# needs one.
EXEMPT_TYPES = ("fix", "docs", "chore", "test", "ci", "build", "revert")

# `type`, an optional `(scope)`, an optional `!`, then the colon. Matched
# case-insensitively because real titles here spell the type `Feat:` as often
# as `feat:`.
_EXEMPT_PREFIX = re.compile(
    r"^\s*(?:" + "|".join(EXEMPT_TYPES) + r")(?:\([^)]*\))?!?\s*:",
    re.IGNORECASE,
)

# The title GitHub's own Revert button writes: `Revert "feat: …"`, no colon.
_GITHUB_REVERT = re.compile(r'^\s*revert\s+"', re.IGNORECASE)

# The headings that open the section. Any heading level is accepted; the
# template uses `##`.
_STORY_HEADING = re.compile(
    r"^\s{0,3}#{1,6}\s+(?:user\s+story|job\s+to\s+be\s+done|jtbd)\s*#*\s*$",
    re.IGNORECASE,
)

# Any ATX heading — where the story section ends.
_ANY_HEADING = re.compile(r"^\s{0,3}#{1,6}(?:\s|$)")

# An HTML comment, or an unclosed one running to the end of the text. The
# template's guidance lives in comments, so an untouched template section is
# empty once they are gone.
_HTML_COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)

MESSAGE = """\
This PR's title marks it as a feature change, so its description needs a \
`## User story` section saying who the change is for and what it lets them do. \
Add one near the top of the description, in either form:

## User story

As a <who>, I want <what>, so that <why>.

or

## User story

When <situation>, I want to <motivation>, so I can <outcome>.

`## Job to be done` works as the heading too. The section must contain prose: \
the template's guidance comment alone does not count.

Bug fixes and other non-feature changes are exempt by their title prefix: \
""" + ", ".join(f"`{t}:`" for t in EXEMPT_TYPES) + """ \
(a scope or `!` is fine, as in `fix(app):`). If this PR is one of those, \
retitle it instead."""


def is_exempt(title: str) -> bool:
    """True when the title's conventional-commit type needs no user story."""
    title = title or ""
    return bool(_EXEMPT_PREFIX.match(title) or _GITHUB_REVERT.match(title))


def has_user_story(body: str) -> bool:
    """True when some user-story section has content beyond comments and whitespace.

    Comments are stripped before headings are looked for, so a heading quoted
    inside the template's guidance comment opens no section.
    """
    text = _HTML_COMMENT.sub("", body or "")
    in_story = False
    for line in text.splitlines():
        if _STORY_HEADING.match(line):
            in_story = True
            continue
        if _ANY_HEADING.match(line):
            in_story = False
            continue
        if in_story and line.strip():
            return True
    return False


def check(title: str, body: str) -> bool:
    """True when the PR passes: an exempt title, or a filled user-story section."""
    return is_exempt(title) or has_user_story(body)


def main() -> int:
    title = os.environ.get("PR_TITLE", "")
    body = os.environ.get("PR_BODY", "")
    if check(title, body):
        if is_exempt(title):
            print(f"Title {title!r} is exempt from the user-story requirement.")
        else:
            print("User story section found.")
        return 0
    print("::error title=Missing user story::Feature PRs need a `## User story` section.")
    print(MESSAGE)
    return 1


if __name__ == "__main__":
    sys.exit(main())
