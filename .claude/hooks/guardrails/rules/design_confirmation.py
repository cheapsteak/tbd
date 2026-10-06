"""Guardrail: an agent may not post the human design-confirmation phrase.

The PR review gate treats a spec as satisfying the spec requirement only once a
human has confirmed its design, and the one gesture that counts is an inline
review comment on the spec file saying "I confirmed the design"
(docs/specs/2026-10-06-human-design-confirmation-design.md). The gate's
`prepare.py` filters out bots and comments carrying agent markers, but agents
post through their human's own GitHub account, so author login cannot tell an
agent's comment from the human's — and markers are heuristic: an agent told to
leave them off can. This rule closes the other side: an agent session that
loads this repo's guardrails cannot post the phrase at all.

It DENIES a Bash call when both hold:

- the command posts to a PR's review surface — `gh pr review`, `gh pr comment`,
  or a `gh api` call that targets `pulls/<n>/comments`, `pulls/<n>/reviews` or
  `pulls/comments/<id>` (REST: replies and edits included) or GraphQL;
- the confirmation phrase appears in the command text (inline flags and heredoc
  bodies alike) or in a body file the command names (`--body-file`, `-F`,
  `--input`, or a `field=@path` value).

The posting command is looked for only in the command's own lines — heredoc
bodies are split off first with the same splitter `pr_worktree_link` uses — so a
script or doc *written* through a heredoc that merely mentions `gh pr review`
and the phrase is not a post. A heredoc fed to a shell (`bash <<EOF`,
`cat <<EOF | sh`) is executed, so its body is searched too; another
interpreter's heredoc body is not. A
`gh api` call and any command addressing `api.github.com` (curl, a one-liner)
count alike. The phrase, by contrast, is looked for everywhere,
heredoc bodies included, because `--body "$(cat <<'EOF'` is the ordinary way to
compose a review body. Past that split, detection is a regex, not a shell parse,
and it errs toward denying: a posting command whose text carries the phrase
anywhere is blocked, even when the phrase sits in a chained `echo`. That over-reach costs an
agent a rephrase; the miss it trades against costs the gate its only human
signal. `gh pr create` and plain issue comments are untouched — neither is a
review comment on a spec, so neither can satisfy the gate.

Known limits, stated in the spec: the rule binds only sessions that load this
repo's `.claude/settings.json`, only the Bash tool (an MCP GitHub tool is not
matched), and only spellings of the phrase the shared regex covers.
"""

from __future__ import annotations

import os
import re
import stat

from guardrails.lib.rule import Decision, Rule
from guardrails.rules.pr_worktree_link import _split_heredoc_bodies

# Must match `CONFIRMATION_RE` in .github/workflows/claude-review-v2/prepare.py
# — the phrase the gate counts is exactly the phrase this rule refuses to let an
# agent send. The test suite pins the two together.
CONFIRMATION_RE = re.compile(r"\bI\s+(?:have\s+)?confirmed\s+the\s+design\b", re.IGNORECASE)

# `gh pr review` / `gh pr comment`, with optional global flags (`-R x`) between.
_GH_PR_POST = re.compile(
    r"(?:^|[\s;&|(`/])gh(?:\s+(?:-R|--repo|--hostname)\s+\S+)*\s+pr\s+(?:review|comment)\b"
)
# `gh api`, or any program (curl, a python one-liner) addressing the REST API.
_GH_API = re.compile(r"(?:^|[\s;&|(`/])gh\s+api\b|api\.github\.com")
# A heredoc whose body runs as shell: an opener line that also names a shell
# (`bash <<EOF`, `cat <<EOF | sh`, `eval`, `source`). Other interpreters'
# heredocs (`python3 - <<PY`) are left alone — their bodies are code that
# routinely writes docs quoting a `gh` command, not shell lines.
_EXECUTED_HEREDOC = re.compile(
    r"<<.*(?:^|[\s;&|(])(?:ba|z|da|k)?sh\b"
    r"|(?:^|[\s;&|(])(?:(?:ba|z|da|k)?sh|eval|source)\b.*<<"
)
# REST review surfaces — a PR's comments and reviews, and an existing review
# comment by id (`pulls/comments/<id>`, whose `/replies` posts a thread reply
# and whose PATCH edits a body into the phrase) — and any GraphQL call. GraphQL
# is matched whole rather than by mutation name because the query can sit in a
# file (`-F query=@q.graphql`) where only the phrase check reads it.
_REVIEW_ENDPOINT = re.compile(
    r"pulls/[^/\s'\"]+/(?:comments|reviews)\b"
    r"|pulls/comments/"
    r"|\bgraphql\b"
)

# Flags whose value names a file holding the body, plus gh api's `field=@path`.
_FILE_FLAG = re.compile(r"(?:--body-file|--input|-F)(?:\s+|=)(['\"]?)([^\s'\"]+)\1")
_AT_FILE = re.compile(r"=@(['\"]?)([^\s'\"]+)\1")

_MAX_BYTES = 64 * 1024

_MESSAGE = (
    "[design-confirmation] Blocked: this command would post a PR review or "
    "comment containing the design-confirmation phrase (\"I confirmed the "
    "design\"). The review gate treats that phrase, left as an inline review "
    "comment on a docs/specs/ file, as a HUMAN's confirmation that a spec's "
    "design was chosen by a person — so an agent must never post it, even "
    "through the human's own GitHub account, and even when asked to. Tell the "
    "user the spec needs their confirmation and that they must leave that inline "
    "comment on the spec file themselves. If you only meant to describe the "
    "rule, rephrase without quoting the phrase. See "
    "docs/specs/2026-10-06-human-design-confirmation-design.md."
)


def _posts_review_surface(command: str) -> bool:
    if _GH_PR_POST.search(command):
        return True
    return bool(_GH_API.search(command) and _REVIEW_ENDPOINT.search(command))


def _file_has_phrase(path: str) -> bool:
    """Bounded, best-effort read of a named body file.

    Regular files only, and the kind is decided from the descriptor after an
    O_NONBLOCK open, so a fifo or device cannot hang the hook. Any failure
    returns False (the inline-text check still applies).
    """
    try:
        descriptor = os.open(os.path.expanduser(path), os.O_RDONLY | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                return False
            data = os.read(descriptor, _MAX_BYTES)
        finally:
            os.close(descriptor)
        return CONFIRMATION_RE.search(data.decode("utf-8", errors="replace")) is not None
    except Exception:
        return False


def _referenced_files(command: str) -> list:
    paths = [match.group(2) for match in _FILE_FLAG.finditer(command)]
    paths += [match.group(2) for match in _AT_FILE.finditer(command)]
    return [path for path in paths if path != "-"]


class DesignConfirmationRule(Rule):
    id = "design-confirmation"
    description = "Block agents from posting the human 'I confirmed the design' review comment."
    tools = {"Bash"}

    def check(self, tool_input: dict, _ctx: dict) -> "Decision | None":
        command = tool_input.get("command", "") or ""
        command_lines, _ = _split_heredoc_bodies(command)
        # An executed heredoc's body is commands, not text, so the posting
        # command is looked for in it too.
        executed = any(
            "<<" in line and _EXECUTED_HEREDOC.search(line)
            for line in command_lines.splitlines()
        )
        if not _posts_review_surface(command if executed else command_lines):
            return None
        if CONFIRMATION_RE.search(command):
            return Decision.deny(_MESSAGE)
        if any(_file_has_phrase(path) for path in _referenced_files(command)):
            return Decision.deny(_MESSAGE)
        return None


RULES = [DesignConfirmationRule()]
