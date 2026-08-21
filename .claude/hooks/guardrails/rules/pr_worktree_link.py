"""Guardrail: nudge toward a TBD worktree deep-link in the body of a new PR.

A PR opened from a TBD worktree — or a GitLab MR, which the rule treats the same
way — should end its body with a link back to that worktree, so anyone reading it
later can reopen the session that produced it. The recipe is not obvious: `tbd
link` prints the `tbd://open?worktree=<uuid>` form, while a PR body needs the
shareable https redirector (`Sources/TBDShared/DeepLinks.swift`) — GitHub
linkifies no scheme outside its http/https/mailto allowlist, so a raw `tbd://`
URL lands in the page as unclickable text. The rule therefore spells the recipe
out, and holds the body to the form a reader can actually click.

This rule is INFORMATIONAL ONLY: it never denies. Blocking `gh pr create` over a
missing courtesy link would be badly wrong. It only surfaces a reminder via
Decision.info, which dispatch.py emits as non-blocking `additionalContext` — the
command always proceeds.

It stays silent when a clickable deep-link is already in the body the command is
about to send — inline body text, a body-file target it can read, or a heredoc
body the command composes — and when the session is not under TBD at all, so a
contributor working outside TBD never sees it. Which flags carry that body is
decided per CLI, in the spelling the matched tool actually uses. A link
anywhere else in the invocation is not a body: a chained
`git log --grep '…tbd/open/?worktree=…'`, or a body-file path that happens to
spell `tbd/open/`, leaves the nudge armed.

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
import re
import stat

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

# The flags whose value *is* the body text, and the flags whose value names a
# file holding it, keyed by the CLI that spells them that way. Each is matched
# space-separated and `=`-joined.
#
# The two CLIs get separate tables because the spellings collide rather than
# compose: `-d` is glab's `--description`, while gh's `-d` is `--draft` — a
# boolean that takes no value at all. Flattening these into one list makes the
# word after `gh pr create -d` read as body text, so a draft PR whose title or
# branch happens to spell a deep-link silences the nudge for a body that has
# none. Keep them apart.
#
# glab has no body-file entry: it is a real spelling gap only if verified, and
# an invented one reads the wrong word out of the segment the same way a shared
# `-d` does.
_BODY_TEXT_FLAGS = {"gh": ("--body", "-b"), "glab": ("--description", "-d")}
_BODY_FILE_FLAGS = {"gh": ("--body-file", "-F"), "glab": ()}

# Cap on how much of a body file is scanned. The hook runs in front of every
# Bash call, so it must not read an arbitrarily large file into memory.
_MAX_BODY_BYTES = 64 * 1024

# What counts as the deep-link already being in the body: an http(s) URL whose
# path reaches the redirector and whose query names a worktree. Each of the
# three parts carries weight.
#
# - `https?://` is the only scheme GitHub will linkify. `tbd link` prints the
#   `tbd://open?worktree=<uuid>` form, so pasting its stdout straight into a
#   body is the easiest way to end up with a link nobody can click — the case
#   the nudge exists for, and one it must not wave through.
# - `tbd/open/` is the redirector path. The host is deliberately unmatched, so
#   a fork serving the redirector from its own Pages domain counts too.
# - `[?&]worktree=` is the parameter the redirector forwards. Requiring it as a
#   query parameter of that URL, rather than as a bare substring of the text,
#   is what keeps the `tbd://` form from qualifying — it spells `?worktree=`
#   as well.
#
# `\S*` stays inside the URL's own whitespace-delimited word, and the match ends
# at `worktree=`, so a markdown `[name](…)` wrapper neither extends it nor
# breaks it, and the `&terminal=<uuid>` an anchored link appends is simply past
# the end of the match.
#
# The leading `/` on `/tbd/open/` makes it a whole path segment. Without it the
# segment matches inside a longer one, so an unrelated host's `/nottbd/open/`
# would read as the redirector and suppress the nudge.
_LINK_PATTERN = re.compile(r"https?://\S*/tbd/open/\S*[?&]worktree=")

_MESSAGE = (
    "This PR (or MR) is being opened from a TBD worktree, so end its body with a "
    "worktree deep-link — that is what lets it be traced back to the session that "
    "produced it. Recipe: get the UUID with "
    '`tbd link 2>/dev/null || tbd link "$(basename "$(git rev-parse --show-toplevel)")"`, '
    "take the `?worktree=<uuid>` portion, and make the final line of the body "
    "`[<worktree display name>](https://cheapsteak.github.io/tbd/open/?worktree=<uuid>)`. "
    "The https redirector form is the one that matters: GitHub renders a raw "
    "`tbd://…` URL as unclickable text, so `tbd link`'s own output is not enough. "
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


def _split_heredoc_bodies(command: str) -> tuple:
    """Separate the lines that are commands from the heredoc bodies they write.

    Segments are cut at newlines, so without this a documentation line inside a
    heredoc reads as a command: `cat <<'EOF' > CONTRIBUTING.md` whose body
    explains how to run `gh pr create …` would fire the nudge on a command that
    opens no PR. Fails closed wherever it is unsure — an unterminated heredoc
    swallows the rest of the command, and a `<<` that is not a heredoc at all is
    read as one.

    Returns `(command_text, heredoc_text)`. Both halves matter: the first is
    what gets tokenized into commands, and the second is prose the invocation
    composes — which is exactly where a PR body written by heredoc lives,
    whether it is substituted inline or redirected to a `--body-file` target
    that does not exist yet.
    """
    lines: list = []
    bodies: list = []
    pending: list = []
    for line in command.split("\n"):
        if pending:
            delimiter, strip_tabs = pending[0]
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == delimiter:  # the terminator is body too, never a command
                pending.pop(0)
            else:
                bodies.append(candidate)
            continue
        lines.append(line)
        pending.extend(_heredoc_openers(line))
    return "\n".join(lines), "\n".join(bodies)


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


def _forge_create_tool(words: list):
    """The forge CLI this segment runs a create on — `"gh"`, `"glab"`, or None.

    The command word may be a path (`/opt/homebrew/bin/gh`), and flags — plus
    the value of the flags that take one — are skipped while walking to the
    subcommand path. The verb must match its own CLI, so `gh mr create` and
    `glab pr create` answer None.

    Naming the tool rather than answering yes-or-no is what lets each segment's
    body flags be read in its own CLI's spelling; the two spell them
    incompatibly (see `_BODY_TEXT_FLAGS`).
    """
    if not words:
        return None
    command = words[0]
    tool = None
    expected = None
    for candidate, path in _FORGE_CREATE_PATHS.items():
        if command == candidate or command.endswith("/" + candidate):
            tool = candidate
            expected = path
            break
    if expected is None:
        return None

    subcommand: list = []
    index = 1
    while index < len(words) and len(subcommand) < 2:
        word = words[index]
        if len(word) > 1 and word.startswith("-"):
            index += 2 if word in _VALUE_TAKING_FLAGS else 1
        else:
            subcommand.append(word)
            index += 1
    return tool if tuple(subcommand) == expected else None


def _forge_create_segments(command_text: str) -> list:
    """Every forge create in already-heredoc-stripped text, as `(tool, words)`.

    The tool travels with the words because the body flags to scan for depend
    on which CLI the segment invokes.
    """
    pairs: list = []
    for words in _command_segments(command_text):
        tool = _forge_create_tool(words)
        if tool is not None:
            pairs.append((tool, words))
    return pairs


def _text_has_link(text: str) -> bool:
    """True when `text` carries a clickable worktree deep-link."""
    return _LINK_PATTERN.search(text) is not None


def _last_flag_value(words: list, flags: tuple):
    """The value the last occurrence of any of `flags` carries, or None.

    Last wins because that is how `gh` and `glab` parse a flag given twice: the
    final `--body` is the body they send and the earlier ones are discarded, so
    reading any occurrence lets a link in a superseded body silence the nudge
    for the body that actually ships. The spellings in one `flags` tuple are
    aliases of a single flag, so it is the last occurrence across the tuple that
    wins, not the last of each spelling.

    Tokenizing first is what makes `--body-file "/path with spaces.md"` and
    `--body-file="/path with spaces.md"` both resolve — a regex over the raw
    command truncates them at the first space. It is also what keeps the flag
    families apart: `--body-file=x` is not a `--body=` value.
    """
    value = None
    for index, word in enumerate(words):
        if word in flags:
            if index + 1 < len(words):
                value = words[index + 1]
            continue
        for flag in flags:
            prefix = flag + "="
            if word.startswith(prefix):
                value = word[len(prefix):]
                break
    return value


def _file_has_link(path: str) -> bool:
    """True if the file at `path` already contains the deep-link.

    Best-effort: a path we cannot read (missing file, permissions, a path built
    from shell expansion) returns False, so the nudge fires. Informational
    output is harmless when wrong; a swallowed reminder is the worse failure.

    Only regular files are read, and only the first `_MAX_BODY_BYTES` of one.
    This hook runs in front of every Bash call and blocks it while it runs, so
    it must never read something that can hang (a fifo, `/dev/stdin`) or that is
    unbounded (`/dev/zero`). The kind is decided from the *descriptor*, after
    opening: a path inspected first and opened second describes two different
    objects if anything swaps the name in between, and `O_NONBLOCK` is what
    keeps that open from parking on a fifo that has no writer. The descriptor is
    closed on every exit. One `read` of the cap is the whole scan: a regular
    file hands back everything up to it in a single call, and a short one only
    ever narrows the window, which costs a nudge that fires anyway.

    The read is binary so the cap counts bytes: a text-mode read counts
    characters, which lets multi-byte UTF-8 pull in several times the cap. A
    byte cap can land mid-character, and `errors="replace"` turns the split
    tail into a replacement character; every literal the pattern anchors on
    (`https://`, `tbd/open/`, `worktree=`) is pure ASCII, and a replacement
    character spells none of them, so a mangled trailing character can never
    fabricate a match.
    """
    try:
        descriptor = os.open(os.path.expanduser(path), os.O_RDONLY | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                return False
            head = os.read(descriptor, _MAX_BODY_BYTES)
        finally:
            os.close(descriptor)
        return _text_has_link(head.decode("utf-8", errors="replace"))
    except Exception:
        return False


def _body_has_link(segments: list, heredoc_text: str) -> bool:
    """True when the body these `(tool, words)` segments will send has the link.

    Three places count, and only these three: the inline body text a segment
    carries, the contents of a body file it names, and the heredoc prose the
    invocation composes. The first two are read in the segment's own CLI's
    spelling. The third is not attributable to one segment — a body heredoc'd
    into a file that does not exist yet is invisible both to the tokenizer,
    which drops heredoc bodies, and to the file read, which finds nothing on
    disk — so any heredoc body in the invocation counts as body text. That is
    deliberately generous: this is an INFO nudge, and a swallowed reminder beats
    one that fires at a body which already has the link.

    Each family contributes its last occurrence, matching how the CLIs resolve a
    repeated flag. A segment naming both an inline body and a body file is not
    disambiguated further: both CLIs reject that combination outright, so the
    command opens nothing and there is no body for the nudge to be right or
    wrong about.
    """
    if _text_has_link(heredoc_text):
        return True
    for tool, words in segments:
        text = _last_flag_value(words, _BODY_TEXT_FLAGS[tool])
        if text is not None and _text_has_link(text):
            return True
        path = _last_flag_value(words, _BODY_FILE_FLAGS[tool])
        if path is not None and _file_has_link(path):
            return True
    return False


class PRWorktreeLinkRule(Rule):
    id = "pr-worktree-link"
    description = "Nudge toward a TBD worktree deep-link in the body of a new PR."
    tools = {"Bash"}

    def check(self, tool_input: dict, ctx: dict) -> "Decision | None":
        command = tool_input.get("command", "") or ""
        command_text, heredoc_text = _split_heredoc_bodies(command)
        segments = _forge_create_segments(command_text)
        if not segments:
            return None
        if not self._under_tbd(ctx):
            return None
        if _body_has_link(segments, heredoc_text):
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
