"""Guardrail: nudge toward a TBD worktree deep-link in the body of a new PR.

A PR opened from a TBD worktree — or a GitLab MR, which the rule treats the same
way — should end its body with a link back to that worktree, so anyone reading it
later can reopen the session that produced it. The recipe is not obvious: `tbd link` prints the `tbd://open?worktree=<uuid>`
form, while a PR body needs the shareable https redirector
(`Sources/TBDShared/DeepLinks.swift`), so the rule spells the whole thing out.

This rule is INFORMATIONAL ONLY: it never denies. Blocking `gh pr create` over a
missing courtesy link would be badly wrong. It only surfaces a reminder via
Decision.info, which dispatch.py emits as non-blocking `additionalContext` — the
command always proceeds.

It stays silent when the link is already in the body (inline `--body` text or a
`--body-file` target), and when the session is not under TBD at all, so a
contributor working outside TBD never sees it.

**Detection is a port of `PRBindingExtractor.isPRCreateCommand`**
(`Sources/TBDShared/PRBindingExtractor.swift`), which answers the same question
for the PR-binding hook and carries the rationale for each defense. The Swift
side cannot be called from a stdlib-only Python hook, so its tokenizer is
mirrored here instead; keep the two in step when either changes.

Matching the phrase rather than tokenizing is wrong in both directions, which is
what the tokenizer's length buys back. A `gh pr create` inside a heredoc body is
prose the command *writes*, not a command it runs, and a quoted one is an
argument — both must stay silent. Meanwhile `/opt/homebrew/bin/gh pr create` and
`gh -R owner/name pr create` are ordinary invocations here and must not be
missed.

Like the Swift original this is a pragmatic tokenizer, not a shell parser, and
an unusual construction fails **closed** — `FOO=bar gh pr create` and
`if ! gh pr create; then …` are missed, because their first word is not `gh`.
For an INFO-only nudge a miss costs nothing, and staying byte-for-byte in step
with the detector that *does* carry consequences is worth more than the extra
coverage.
"""

from __future__ import annotations

import os

from guardrails.lib.rule import Decision, Rule

# Shell metacharacters that end one command and begin the next. Runs of them
# collapse on their own, so `&&`, `||` and `|` need no special case.
_SEGMENT_SEPARATORS = frozenset(";&|\n")

# `gh` global flags that consume the word after them, so the subcommand path of
# `gh --repo owner/name pr create` still reads `pr create`.
_VALUE_TAKING_FLAGS = frozenset({"-R", "--repo", "--hostname"})

# The forge CLIs that open a change, and the subcommand path each one uses. The
# verb must match its own CLI: `gh mr create` and `glab pr create` are rejected.
_FORGE_CREATE_PATHS = {"gh": ("pr", "create"), "glab": ("mr", "create")}

# `--body-file <path>` / `-F <path>` and their `=`-joined forms.
_BODY_FILE_FLAGS = ("--body-file", "-F")

# Cap on how much of a body file is scanned. The hook runs in front of every
# Bash call, so it must not read an arbitrarily large file into memory.
_MAX_BODY_BYTES = 64 * 1024

# Any of these in the body text means the deep-link is already there: the raw
# query fragment, the https redirector path, or the bare scheme.
_LINK_MARKERS = ("?worktree=", "tbd/open/", "tbd://open")

_MESSAGE = (
    "This PR (or MR) is being opened from a TBD worktree, so end its body with a "
    "worktree deep-link — that is what lets it be traced back to the session that "
    "produced it. Recipe: get the UUID with "
    '`tbd link 2>/dev/null || tbd link "$(basename "$(git rev-parse --show-toplevel)")"`, '
    "take the `?worktree=<uuid>` portion, and make the final line of the body "
    "`[<worktree display name>](https://cheapsteak.github.io/tbd/open/?worktree=<uuid>)`. "
    "If `tbd link` fails, skip it silently. (This is informational — nothing is blocked.)"
)


def _heredoc_openers(line: str) -> list:
    """The heredoc delimiters a command line opens, in body order.

    `cmd <<A <<B` reads A's body first. Quoting is tracked so a `<<` inside a
    string opens nothing, and the delimiter word is unquoted the way the shell
    unquotes it — `<<'EOF'`, `<<"EOF"` and `<<EOF` all end at a line reading
    `EOF`. `<<<` is a here-string: one word of data on the same line, no body.
    """
    openers: list = []
    index = 0
    count = len(line)
    quote = None

    while index < count:
        character = line[index]
        if quote is not None:
            if character == "\\" and quote == '"':
                index += 2
                continue
            if character == quote:
                quote = None
            index += 1
            continue
        if character == "\\":
            index += 2
            continue
        if character in ("'", '"'):
            quote = character
            index += 1
            continue
        if character != "<" or index + 1 >= count or line[index + 1] != "<":
            index += 1
            continue
        index += 2
        if index < count and line[index] == "<":  # here-string, not a heredoc
            index += 1
            continue
        strip_tabs = False
        if index < count and line[index] == "-":
            strip_tabs = True
            index += 1
        while index < count and line[index] in " \t":
            index += 1
        delimiter = ""
        delimiter_quote = None
        while index < count:
            word = line[index]
            if delimiter_quote is not None:
                if word == delimiter_quote:
                    delimiter_quote = None
                else:
                    delimiter += word
                index += 1
                continue
            if word in ("'", '"'):
                delimiter_quote = word
                index += 1
                continue
            if word == "\\":
                index += 1
                if index < count:
                    delimiter += line[index]
                    index += 1
                continue
            if word.isspace() or word in _SEGMENT_SEPARATORS or word in "<>)":
                break
            delimiter += word
            index += 1
        if delimiter:
            openers.append((delimiter, strip_tabs))
    return openers


def _without_heredoc_bodies(command: str) -> str:
    """Drop every heredoc *body*, keeping the lines that really are commands.

    Segments are cut at newlines, so without this a documentation line inside a
    heredoc reads as a command: `cat <<'EOF' > CONTRIBUTING.md` whose body
    explains how to run `gh pr create …` would fire the nudge on a command that
    opens no PR. Fails closed wherever it is unsure — an unterminated heredoc
    swallows the rest of the command, and a `<<` that is not a heredoc at all is
    read as one.
    """
    lines: list = []
    pending: list = []
    for line in command.split("\n"):
        if pending:
            delimiter, strip_tabs = pending[0]
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == delimiter:  # the terminator is body too, never a command
                pending.pop(0)
            continue
        lines.append(line)
        pending.extend(_heredoc_openers(line))
    return "\n".join(lines)


def _command_segments(command: str) -> list:
    """Split into per-command word lists, honoring quotes.

    Neither a separator nor a space inside a quoted string breaks anything
    apart, which is what keeps a quoted `'gh pr create'` phrase from ever
    looking like a command.
    """
    segments: list = []
    words: list = []
    word = ""
    word_started = False
    quote = None
    escaped = False

    for character in command:
        if escaped:
            word += character
            word_started = True
            escaped = False
        elif quote is not None:
            if character == quote:
                quote = None  # the word stays open
            elif quote == '"' and character == "\\":
                escaped = True
            else:
                word += character
                word_started = True
        elif character == "\\":
            escaped = True
        elif character in ("'", '"'):
            quote = character
            word_started = True  # `""` is an empty word
        elif character in _SEGMENT_SEPARATORS:
            if word_started:
                words.append(word)
                word = ""
                word_started = False
            if words:
                segments.append(words)
                words = []
        elif character.isspace():
            if word_started:
                words.append(word)
                word = ""
                word_started = False
        else:
            word += character
            word_started = True

    if word_started:
        words.append(word)
    if words:
        segments.append(words)
    return segments


def _is_forge_create_segment(words: list) -> bool:
    """True when this segment invokes `gh pr create` or `glab mr create`.

    The command word may be a path (`/opt/homebrew/bin/gh`), and flags — plus
    the value of the flags that take one — are skipped while walking to the
    subcommand path.
    """
    if not words:
        return False
    command = words[0]
    expected = None
    for tool, path in _FORGE_CREATE_PATHS.items():
        if command == tool or command.endswith("/" + tool):
            expected = path
            break
    if expected is None:
        return False

    subcommand: list = []
    index = 1
    while index < len(words) and len(subcommand) < 2:
        word = words[index]
        if len(word) > 1 and word.startswith("-"):
            index += 2 if word in _VALUE_TAKING_FLAGS else 1
        else:
            subcommand.append(word)
            index += 1
    return tuple(subcommand) == expected


def _forge_create_segments(command: str) -> list:
    """Every segment of `command` that actually runs a forge create."""
    return [
        words
        for words in _command_segments(_without_heredoc_bodies(command))
        if _is_forge_create_segment(words)
    ]


def _text_has_link(text: str) -> bool:
    return any(marker in text for marker in _LINK_MARKERS)


def _body_file_paths(words: list) -> list:
    """The `--body-file` / `-F` targets in one already-tokenized segment.

    Tokenizing first is what makes `--body-file "/path with spaces.md"` and
    `--body-file="/path with spaces.md"` both resolve — a regex over the raw
    command truncates them at the first space.
    """
    paths: list = []
    for index, word in enumerate(words):
        if word in _BODY_FILE_FLAGS:
            if index + 1 < len(words):
                paths.append(words[index + 1])
            continue
        for flag in _BODY_FILE_FLAGS:
            prefix = flag + "="
            if word.startswith(prefix):
                paths.append(word[len(prefix):])
                break
    return paths


def _file_has_link(path: str) -> bool:
    """True if the file at `path` already contains the deep-link.

    Best-effort: a path we cannot read (missing file, permissions, a path built
    from shell expansion) returns False, so the nudge fires. Informational
    output is harmless when wrong; a swallowed reminder is the worse failure.

    Only regular files are opened, and only the first `_MAX_BODY_BYTES` of one.
    This hook runs in front of every Bash call and blocks it while it runs, so
    it must never read something that can hang (a fifo, `/dev/stdin`) or that is
    unbounded (`/dev/zero`).
    """
    try:
        expanded = os.path.expanduser(path)
        if not os.path.isfile(expanded):
            return False
        with open(expanded, "r", encoding="utf-8", errors="replace") as handle:
            return _text_has_link(handle.read(_MAX_BODY_BYTES))
    except Exception:
        return False


def _body_file_has_link(segments: list) -> bool:
    return any(
        _file_has_link(path) for words in segments for path in _body_file_paths(words)
    )


class PRWorktreeLinkRule(Rule):
    id = "pr-worktree-link"
    description = "Nudge toward a TBD worktree deep-link in the body of a new PR."
    tools = {"Bash"}

    def check(self, tool_input: dict, ctx: dict) -> "Decision | None":
        command = tool_input.get("command", "") or ""
        segments = _forge_create_segments(command)
        if not segments:
            return None
        if not self._under_tbd(ctx):
            return None
        # Inline `--body`/`-b` text lives in the command string itself, so
        # scanning the raw command covers it — raw, not heredoc-stripped, since
        # a `--body "$(cat <<'EOF' … EOF)"` body is exactly where the link goes.
        if _text_has_link(command):
            return None
        if _body_file_has_link(segments):
            return None
        return Decision.info(_MESSAGE)

    def _under_tbd(self, ctx: dict) -> bool:
        """True when this session belongs to TBD.

        The environment is read here rather than into a module-level constant so
        the check reflects the process env at call time — a module constant is
        frozen at import and cannot be overridden by tests (or by a daemon that
        set TBD_HOME after this module loaded).
        """
        if os.environ.get("TBD_WORKTREE_ID"):
            return True
        home = os.environ.get("TBD_HOME") or os.path.join(os.path.expanduser("~"), "tbd")
        worktrees_root = os.path.join(home, "worktrees") + os.sep
        cwd = (ctx.get("cwd") or "") + os.sep
        return cwd.startswith(worktrees_root)


RULES = [PRWorktreeLinkRule()]
