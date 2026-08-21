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
decided per CLI, in the spelling the matched tool actually uses. One Bash call
may open several PRs, and each one's body is judged on its own: any create
segment missing the link arms the nudge (see `_every_body_has_link`). A link
anywhere else in the invocation is not a body: a chained
`git log --grep '…tbd/open/?worktree=…'`, or a body-file path that happens to
spell `tbd/open/`, leaves the nudge armed.

**Detection is a port of `PRBindingExtractor.isPRCreateCommand`**
(`Sources/TBDShared/PRBindingExtractor.swift`), which answers the same question
for the PR-binding hook and carries the rationale for each defense. The Swift
side cannot be called from a stdlib-only Python hook, so its tokenizer is
mirrored here instead; keep the two in step when either changes. The mirror is
close but not literal, in two places: it collapses a backslash-newline line
continuation, and it gives a `$(…)` command substitution its own quoting
context. Neither costs it a real invocation. The first is pure widening: it
recognizes every invocation the Swift side does, and some it splits across
lines. The second changes only what counts as *text* — where a body ends and
where a word ends — and the one detection it moves is in the correct direction:
a `gh pr create` *mentioned* in a heredoc body composed as `"$(cat <<'EOF'` is
stripped as the prose it is, where the Swift side still reads it as command
lines.

That second one is what carries `--body "$(cat <<'EOF'` — the repo's own
recommended way of composing a PR body, and a shape where treating the
substitution as ordinary double-quoted content is wrong twice over. The `<<`
goes unseen, so the body is parsed as command lines rather than stripped as
prose; and the first literal `"` inside the body reads as the close of the
enclosing quote, so the next space flushes a truncated fragment as the value of
`--body`. Both scanners therefore track `$(` nesting depth and start each
substitution with fresh quote state: `_heredoc_openers` to find the opener,
`_command_segments` to keep the substitution inside one word. A quoted phrase or
an error message in a PR body is entirely ordinary, so this is not an exotic
case.

Depth tracking is as far as the fidelity goes. `$(` is still read as a
substitution wherever single quotes do not cover it, backticks are not a
substitution at all, and an unbalanced `$(` swallows the rest of the command
into one word — the fail-closed direction, which costs at most a nudge that does
not fire.

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

# Cap on each of the two windows `_file_has_link` reads out of a body file. It
# is a bound and nothing more: the hook runs in front of every Bash call and
# blocks it while it runs, so a `--body-file` naming something huge must not be
# able to make it read the whole thing. Two windows are read, so the worst case
# is twice this. No claim about any forge's own body-length limit is intended.
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

    A `$(…)` command substitution is its own quoting context (see the module
    docstring), which is what makes the repo's own recommended way of composing
    a PR body work: on `--body "$(cat <<'EOF'` the `<<` sits inside the
    enclosing double quotes, and reading it as quoted string content would leave
    the opener unseen and the whole body parsed as command lines.
    """
    openers: list = []
    index = 0
    count = len(line)
    quote = None
    suspended_quotes: list = []

    while index < count:
        character = line[index]
        if quote == "'":  # a backslash is an ordinary character in single quotes
            if character == "'":
                quote = None
            index += 1
            continue
        if character == "\\":
            index += 2
            continue
        if character == "$" and line[index + 1 : index + 2] == "(":
            suspended_quotes.append(quote)
            quote = None
            index += 2
            continue
        if character == ")" and quote is None and suspended_quotes:
            quote = suspended_quotes.pop()
            index += 1
            continue
        if quote is not None:
            if character == quote:
                quote = None
            index += 1
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

    This runs over *physical* lines, before the tokenizer collapses any
    backslash-newline continuation, which keeps the two passes independent: a
    continuation inside a command is invisible here, and a heredoc body is gone
    before the tokenizer can join anything across it. The one construction that
    straddles both — a heredoc opener on a line that also ends in a
    continuation — resolves in the fail-closed direction: the body is taken from
    the next physical line rather than after the full logical line, and the
    surviving command lines join into a single segment whose first word is the
    redirecting command, so no create is found.

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
    """Split into per-command word lists, honoring quotes and continuations.

    Neither a separator nor a space inside a quoted string breaks anything
    apart, which is what keeps a quoted `'gh pr create'` phrase from ever
    looking like a command.

    A backslash-newline pair vanishes the way the shell collapses a line
    continuation, so a multi-line invocation is one command rather than several.
    That matters most when the continuation lands *inside* the command-and-
    subcommand path — `gh pr \\` then `create …` — because a retained newline
    both cuts the segment in two and reads as the subcommand word, so the path
    never spells `pr create` and the rule silently never fires. The pair
    collapses unquoted and inside double quotes, which is where the shell
    treats it as a continuation, and stays literal inside single quotes, where
    a backslash is an ordinary character.

    A `$(…)` command substitution is its own quoting context (see the module
    docstring), and everything between its parentheses stays part of the word
    being built — a substitution is one syntactic unit, so neither the spaces
    nor the separators inside it may break the word or the segment. The
    alternative is worse in the direction that matters: reading a literal `"`
    inside the substitution as the close of the enclosing double quote leaves
    the next space flushing a truncated, link-less fragment as the body's value,
    and the nudge fires at a body that already carries the link.
    """
    segments: list = []
    words: list = []
    word = ""
    word_started = False
    quote = None
    suspended_quotes: list = []
    index = 0
    count = len(command)

    while index < count:
        character = command[index]
        following = command[index + 1 : index + 2]

        if character == "\\" and quote != "'":
            if following == "\n":  # a backslash-newline pair is a continuation
                index += 2
                continue
            if following:
                word += following
                word_started = True
                index += 2
                continue
            index += 1
            continue

        if character == "$" and following == "(" and quote != "'":
            suspended_quotes.append(quote)
            quote = None
            word += "$("
            word_started = True
            index += 2
            continue

        if character == ")" and quote is None and suspended_quotes:
            quote = suspended_quotes.pop()
            word += ")"
            word_started = True
            index += 1
            continue

        index += 1
        if quote is not None:
            if character == quote:
                quote = None  # the word stays open
            else:
                word += character
                word_started = True
        elif character in ("'", '"'):
            quote = character
            word_started = True  # `""` is an empty word
        elif suspended_quotes:  # a substitution is one unit, spaces and all
            word += character
            word_started = True
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

    Only regular files are read, and only two `_MAX_BODY_BYTES` windows of one.
    This hook runs in front of every Bash call and blocks it while it runs, so
    it must never read something that can hang (a fifo, `/dev/stdin`) or that is
    unbounded (`/dev/zero`). The kind is decided from the *descriptor*, after
    opening: a path inspected first and opened second describes two different
    objects if anything swaps the name in between, and `O_NONBLOCK` is what
    keeps that open from parking on a fifo that has no writer. The descriptor is
    closed on every exit. One `read` per window is the whole scan: a regular
    file hands back everything up to the cap in a single call, and a short one
    only ever narrows the window, which costs a nudge that fires anyway.

    The two windows are the head and the tail, and the tail is the one the
    convention needs: the recipe this rule teaches puts the deep-link on the
    body's **last** line, so a head-only read calls every body longer than the
    cap unlinked no matter how correctly it is linked. A file that fits inside
    one window is covered by the head alone and the tail read is skipped.

    A body over twice the cap has an unread middle, and a link that sits there —
    or one straddling the boundary the tail read starts at — is not found. Both
    fail toward the nudge, which is the harmless direction, and neither is where
    the convention puts the link.

    The read is binary so the cap counts bytes: a text-mode read counts
    characters, which lets multi-byte UTF-8 pull in several times the cap. A
    byte cap can land mid-character — as can a tail window opening mid-character
    — and `errors="replace"` turns the split fragment into a replacement
    character; every literal the pattern anchors on (`https://`, `tbd/open/`,
    `worktree=`) is pure ASCII, and a replacement character spells none of them,
    so a mangled edge character can never fabricate a match.
    """
    try:
        descriptor = os.open(os.path.expanduser(path), os.O_RDONLY | os.O_NONBLOCK)
        try:
            status = os.fstat(descriptor)
            if not stat.S_ISREG(status.st_mode):
                return False
            windows = [os.read(descriptor, _MAX_BODY_BYTES)]
            if status.st_size > len(windows[0]):
                tail_offset = max(0, status.st_size - _MAX_BODY_BYTES)
                windows.append(os.pread(descriptor, _MAX_BODY_BYTES, tail_offset))
        finally:
            os.close(descriptor)
        return any(_text_has_link(w.decode("utf-8", errors="replace")) for w in windows)
    except Exception:
        return False


def _segment_body_has_link(tool: str, words: list) -> bool:
    """True when this one segment's own body already carries the link.

    Two places are the segment's own body: the inline body text it carries, and
    the contents of a body file it names — each read in the segment's own CLI's
    spelling, and each contributing its last occurrence, matching how the CLIs
    resolve a repeated flag.

    A segment naming both an inline body and a body file is not disambiguated
    further: both CLIs reject that combination outright, so the command opens
    nothing and there is no body for the nudge to be right or wrong about.
    """
    text = _last_flag_value(words, _BODY_TEXT_FLAGS[tool])
    if text is not None and _text_has_link(text):
        return True
    path = _last_flag_value(words, _BODY_FILE_FLAGS[tool])
    return path is not None and _file_has_link(path)


def _every_body_has_link(segments: list, heredoc_text: str) -> bool:
    """True when *every* `(tool, words)` create segment sends a body with the link.

    The decision is scoped per segment, because each segment opens its own PR:
    `gh pr create --body '<link>' && gh pr create --body '<no link>'` must
    nudge, and ORing the two bodies together would let the first PR's link
    excuse the second's missing one. So a single segment lacking the link arms
    the nudge for the whole Bash call.

    The heredoc leg is the one deliberate exception, and it is invocation-wide
    rather than per-segment: a body heredoc'd into a file that does not exist
    yet is invisible both to the tokenizer, which drops heredoc bodies, and to
    the file read, which finds nothing on disk, so it cannot be attributed to
    the segment that will send it. Any heredoc body in the invocation therefore
    counts as body text for every segment. That is deliberately generous: this
    is an INFO nudge, and a swallowed reminder beats one that fires at a body
    which already has the link.

    Each segment's check is therefore: its own body-text or body-file value, OR
    the invocation-wide heredoc text.
    """
    heredoc_link = _text_has_link(heredoc_text)
    return all(heredoc_link or _segment_body_has_link(tool, words) for tool, words in segments)


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
        if _every_body_has_link(segments, heredoc_text):
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
