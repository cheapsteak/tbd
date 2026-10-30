#!/usr/bin/env python3
"""Check the links between the daemon's folders against scripts/daemon-links.txt.

`TBDDaemonLib` is one SwiftPM module, so the compiler lets any folder under
Sources/TBDDaemon use any other. This check gives the folders a direction
without a build. It reads every Swift file in the library, finds each place a
file in one folder names a declaration from another, and compares the links
those references make with the committed list. It fails on a link the list
lacks, so a new one reaches review in the diff, and on a listed link no code
makes any more, so the list only shrinks. The design is in
docs/specs/2026-10-30-daemon-layer-order-design.md; how to read and fix a
failure is in Sources/TBDDaemon/CLAUDE.md, "Links between folders".

A unit is a folder directly under Sources/TBDDaemon, subfolders included, or
`(root)` for the files directly in it. `main.swift` belongs to the executable
target, not the library, and is skipped.

It matches names, not types. The index holds each unit's top-level
declarations that are not private or fileprivate: types, typealiases,
top-level functions and globals. A file references unit B when it names one
of B's, in code or in a string's interpolation. A name in a comment or a
literal, after a `.`, or as an argument label is not a reference, and neither
is a name the file declares for itself: a member, a nested type, a private
declaration, or a lowercase local or parameter.

It fails closed: a file or folder it cannot open, and Swift it cannot read
-- an unbalanced brace, a literal or comment that never closes, bytes that
are not UTF-8 -- stop it with exit 2, rather than let it report a link set
that is silently wrong.

Exit codes: 0 every link is listed and every listed link is made; 1 a new or
stale link; 2 the tree or the list cannot be read. A pass also reports the
cycles among the listed links. That report is information, not a failure: it
measures how far the folders are from taking a layer order.

Usage:
  scripts/lint-daemon-layers.py [--repo-root DIR]
"""

from __future__ import annotations

import argparse
import codecs
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Iterable, NoReturn

# --------------------------------------------------------------------------
# Where things live, relative to the repository root
# --------------------------------------------------------------------------

DAEMON_DIR = PurePosixPath("Sources/TBDDaemon")
LINKS_FILE = PurePosixPath("scripts/daemon-links.txt")

# The unit for the files directly under DAEMON_DIR. The parentheses keep it
# from colliding with any folder name Swift code could live in.
ROOT_UNIT = "(root)"

# Package.swift gives this one file to the `TBDDaemon` executable target, so
# nothing in the library can name what it declares, and what it names is the
# executable's business.
EXECUTABLE_ONLY = "main.swift"

GUIDE = 'Sources/TBDDaemon/CLAUDE.md, "Links between folders"'

# (from unit, to unit)
Link = tuple[str, str]


class CannotCheck(Exception):
    """The tree or the list cannot be read. The message is what follows
    `lint-daemon-layers: ` on stderr."""


@dataclass(frozen=True)
class Token:
    text: str
    line: int


@dataclass(frozen=True)
class Declaration:
    name: str
    # The keyword: struct, enum, class, actor, protocol, extension,
    # typealias, associatedtype, func, let, var or case.
    kind: str
    line: int
    at_file_scope: bool
    private: bool


@dataclass(frozen=True)
class Reference:
    path: str  # repo-relative, POSIX
    line: int
    name: str
    link: Link


@dataclass
class SourceFile:
    path: str
    unit: str
    tokens: list[Token]
    declarations: list[Declaration]


@dataclass
class Scan:
    units: set[str]
    references: list[Reference]

    def links(self) -> dict[Link, list[Reference]]:
        found: dict[Link, list[Reference]] = {}
        for reference in self.references:
            found.setdefault(reference.link, []).append(reference)
        return found


def unit_of(rel: PurePosixPath) -> str:
    """The unit a file belongs to, from its path relative to DAEMON_DIR."""
    return ROOT_UNIT if len(rel.parts) == 1 else rel.parts[0]


# --------------------------------------------------------------------------
# Lexing
# --------------------------------------------------------------------------


_NOT_NEWLINE = re.compile(r"[^\n]")
# The characters each mode must stop at; everything between them is copied
# (code) or blanked (a literal's body) wholesale.
_CODE_STOPS = re.compile(r'[/"#`]')
_INTERPOLATION_STOPS = re.compile(r'[/"#`()]')
_SINGLE_LINE_STOPS = re.compile(r'[\\"\n]')
_MULTI_LINE_STOPS = re.compile(r'[\\"]')
_BLOCK_COMMENT_MARKS = re.compile(r"/\*|\*/")
_REGEX_STOPS = re.compile(r"[\\/]")
_IDENTIFIER = re.compile(r"[^\W\d]\w*")

# A bare `/regex/` can start only where an operand can: after one of these,
# at the start of a line, or after a keyword that an expression follows.
# Anywhere else a `/` is division. `try?` and `try!` end in punctuation, and a
# `{` follows `else`, `do` and `repeat`.
_REGEX_MAY_FOLLOW = frozenset("(,=:[{;!&|?^~")
_REGEX_MAY_FOLLOW_KEYWORDS = frozenset({
    "return", "throw", "try", "await", "in", "case", "where", "if", "guard", "while", "switch",
})
# ...and never with one of these after the `/`, which make it `/ x`, `//`,
# `/*` or `/=`.
_REGEX_MAY_NOT_START_WITH = frozenset(" \t\n/*=")


class _String:
    __slots__ = ("hashes", "multi_line", "start")

    def __init__(self, hashes: int, multi_line: bool, start: int) -> None:
        self.hashes = hashes
        self.multi_line = multi_line
        self.start = start


class _Interpolation:
    __slots__ = ("depth",)

    def __init__(self) -> None:
        self.depth = 0


def blank_literals_and_comments(source: str, path: str) -> str:
    """`source` with comment text, literal bodies and backticks turned to spaces.

    The result keeps the input's length and every newline, so line numbers
    survive. Code inside a string's interpolation is kept, because it is code:
    `"\\(Widget.make())"` references Widget. Raises CannotCheck at the opening
    line of a comment or literal that never closes, rather than read the rest
    of the file inside out.
    """
    out = list(source)
    size = len(source)

    def blank(start: int, end: int) -> None:
        out[start:end] = _NOT_NEWLINE.sub(" ", source[start:end])

    def fail(position: int, reason: str) -> NoReturn:
        line = source.count("\n", 0, position) + 1
        raise CannotCheck(f"cannot scan {path}:{line}: {reason}")

    def block_comment_end(start: int) -> int:
        # Swift's block comments nest.
        depth = 0
        position = start
        while True:
            mark = _BLOCK_COMMENT_MARKS.search(source, position)
            if mark is None:
                fail(start, "unterminated block comment")
            depth += 1 if mark.group() == "/*" else -1
            position = mark.end()
            if depth == 0:
                return position

    def bare_regex_close(slash: int) -> int | None:
        """The closing `/` of a bare regex opening at `slash`, or None when
        that `/` is an operator."""
        after = source[slash + 1:slash + 2]
        if not after or after in _REGEX_MAY_NOT_START_WITH:
            return None
        k = slash - 1
        while k >= 0 and out[k] in " \t":
            k -= 1
        if k >= 0 and out[k] != "\n" and out[k] not in _REGEX_MAY_FOLLOW:
            end = k + 1
            while k >= 0 and (out[k].isalnum() or out[k] == "_"):
                k -= 1
            if "".join(out[k + 1:end]) not in _REGEX_MAY_FOLLOW_KEYWORDS:
                return None
        position = slash + 1
        while position < size:
            char = source[position]
            if char == "\n":
                return None
            if char == "\\":
                if source[position + 1:position + 2] in ("", "\n"):
                    return None
                position += 2
                continue
            if char == "/":
                # `/ x /` is two divisions; a regex cannot end on a space.
                return position if source[position - 1] not in " \t" else None
            position += 1
        return None

    def extended_regex_end(start: int, slash: int, hashes: int) -> int:
        closer = "/" + "#" * hashes
        position = slash + 1
        while True:
            stop = _REGEX_STOPS.search(source, position)
            if stop is None:
                fail(start, "unterminated regex literal")
            position = stop.start()
            if source[position] == "\\":
                position += 2
            elif source.startswith(closer, position):
                blank(slash + 1, position)
                return position + len(closer)
            else:
                position += 1

    # The open strings and interpolations, innermost last. Empty is code.
    stack: list[_String | _Interpolation] = []
    i = 0
    while i < size:
        top = stack[-1] if stack else None

        if isinstance(top, _String):
            stop = (_MULTI_LINE_STOPS if top.multi_line else _SINGLE_LINE_STOPS).search(source, i)
            if stop is None:
                break
            k = stop.start()
            blank(i, k)
            char = source[k]
            if char == "\n":
                fail(top.start, "unterminated string literal")
            elif char == '"':
                closer = ('"""' if top.multi_line else '"') + "#" * top.hashes
                if source.startswith(closer, k):
                    stack.pop()
                    i = k + len(closer)
                else:
                    out[k] = " "
                    i = k + 1
            elif source.startswith("#" * top.hashes, k + 1):
                # A backslash with as many hashes as the string opened with:
                # an interpolation if `(` follows, otherwise an escape.
                after = k + 1 + top.hashes
                if source[after:after + 1] == "(":
                    blank(k, after)
                    stack.append(_Interpolation())
                    i = after + 1
                else:
                    end = after if source[after:after + 1] in ("", "\n") else after + 1
                    blank(k, end)
                    i = end
            else:
                out[k] = " "  # a raw string's plain backslash
                i = k + 1
            continue

        stop = (_CODE_STOPS if top is None else _INTERPOLATION_STOPS).search(source, i)
        if stop is None:
            break
        i = stop.start()
        char = source[i]
        if char == "`":
            # `Widget` in backticks is the name Widget. Anything else in them is
            # one raw identifier, such as a test's `checks that Widget parses`,
            # and names nothing: its words are not code.
            close = source.find("`", i + 1)
            newline = source.find("\n", i + 1)
            if close < 0 or 0 <= newline < close:
                out[i] = " "  # unpaired; the compiler will say so
                i += 1
            elif _IDENTIFIER.fullmatch(source, i + 1, close):
                out[i] = out[close] = " "
                i = close + 1
            else:
                blank(i, close + 1)
                i = close + 1
        elif char == "(":
            # Only an interpolation stops at a parenthesis.
            assert isinstance(top, _Interpolation)
            top.depth += 1
            i += 1
        elif char == ")":
            assert isinstance(top, _Interpolation)
            if top.depth == 0:
                stack.pop()  # the interpolation closes and its string resumes
            else:
                top.depth -= 1
            i += 1
        elif char == "/":
            after = source[i + 1:i + 2]
            if after == "/":
                end = source.find("\n", i)
                end = size if end < 0 else end
                blank(i, end)
                i = end
            elif after == "*":
                end = block_comment_end(i)
                blank(i, end)
                i = end
            else:
                close = bare_regex_close(i)
                if close is None:
                    i += 1
                else:
                    blank(i + 1, close)
                    i = close + 1
        else:
            # `"`, or a run of `#` that may open a raw string or an
            # extended regex. Any other `#` is a directive's: `#if`.
            j = i
            while j < size and source[j] == "#":
                j += 1
            hashes = j - i
            if source[j:j + 1] == '"':
                multi_line = source.startswith('"""', j)
                stack.append(_String(hashes, multi_line, i))
                i = j + (3 if multi_line else 1)
            elif hashes and source[j:j + 1] == "/":
                i = extended_regex_end(i, j, hashes)
            else:
                i = j

    for frame in reversed(stack):
        if isinstance(frame, _String):
            if frame.multi_line:
                fail(frame.start, "unterminated multi-line string literal")
            fail(frame.start, "unterminated string literal")
    return "".join(out)


PUNCTUATION = frozenset("{}()[]<>.,:;=@#?!&|+-*/%^~")

# A newline; or an identifier or one punctuation character; or a number, which
# is matched only so its digits never start an identifier. Everything else --
# quotes, `$`, `\`, whitespace -- is skipped.
_TOKEN = re.compile(r"(\n)|([^\W\d]\w*|[{}()\[\]<>.,:;=@#?!&|+\-*/%^~])|\d\w*")


def tokenize(code: str) -> list[Token]:
    tokens: list[Token] = []
    line = 1
    for newline, text in _TOKEN.findall(code):
        if newline:
            line += 1
        elif text:
            tokens.append(Token(text, line))
    return tokens


def is_identifier(text: str) -> bool:
    return text not in PUNCTUATION


# --------------------------------------------------------------------------
# Declarations
# --------------------------------------------------------------------------

TYPE_KEYWORDS = frozenset({"struct", "enum", "class", "actor", "protocol", "extension"})
NAMED_KEYWORDS = frozenset({"func", "typealias", "associatedtype", "let", "var"})
PRIVATE_MODIFIERS = frozenset({"private", "fileprivate"})
# Every keyword that starts a declaration, so takes the modifiers before it.
DECLARATION_KEYWORDS = TYPE_KEYWORDS | NAMED_KEYWORDS | frozenset({
    "case", "init", "deinit", "subscript", "import", "operator", "precedencegroup", "macro",
})

# `class` followed by one of these is the `class` modifier, as in
# `class func` or `class override var`, not a class declaration.
CLASS_AS_MODIFIER = frozenset({
    "func", "var", "let", "subscript", "init", "deinit", "typealias",
    "static", "final", "override", "private", "fileprivate", "public",
    "internal", "open", "package", "nonisolated", "required", "convenience",
})


def parse_declarations(tokens: list[Token], path: str) -> list[Declaration]:
    """Every declaration in the file, each marked whether it is at file scope.

    A brace stack tells type bodies from the rest: the first `{` after a type
    keyword opens a type body, and every other `{` opens a body -- a function's,
    an accessor's, a closure's -- where a `case` is a pattern, not an enum case.
    """
    declarations: list[Declaration] = []
    # One entry per open `{`: the type keyword whose body it opens, or None,
    # and the line it is on.
    stack: list[tuple[str | None, int]] = []
    pending_type: str | None = None
    # A `private` or `fileprivate` modifier seen since the last declaration
    # keyword, which the next one takes: modifiers precede their keyword,
    # on its line or an earlier one.
    pending_private = False
    count = len(tokens)

    def declare(name: Token, kind: str, private: bool) -> None:
        declarations.append(Declaration(
            name=name.text,
            kind=kind,
            line=name.line,
            at_file_scope=not stack,
            private=private,
        ))

    for i, token in enumerate(tokens):
        text = token.text
        if text == "{":
            stack.append((pending_type, token.line))
            pending_type = None
            pending_private = False
            continue
        if text == "}":
            if not stack:
                raise CannotCheck(f'cannot scan {path}:{token.line}: "}}" with no matching "{{"')
            stack.pop()
            pending_private = False
            continue
        if text in PRIVATE_MODIFIERS:
            # `private(set)` restricts only the setter; the name stays visible.
            if i + 1 >= count or tokens[i + 1].text != "(":
                pending_private = True
            continue
        if text not in DECLARATION_KEYWORDS:
            continue
        # `Foo.Type` is no declaration, and neither is `import struct M.Name`,
        # which brings one declaration in from another module.
        if i and tokens[i - 1].text in (".", "import"):
            continue
        following = tokens[i + 1] if i + 1 < count else None
        if text == "class" and following is not None and following.text in CLASS_AS_MODIFIER:
            continue
        private, pending_private = pending_private, False

        if text in TYPE_KEYWORDS:
            if following is None or not is_identifier(following.text):
                continue
            # `actor` is a keyword only before a name on its line; anywhere
            # else it can be a variable's name, as in `actor: actor`.
            if text == "actor" and following.line != token.line:
                continue
            name = following.text
            if text == "extension":
                j = i + 2
                while j + 1 < count and tokens[j].text == "." and is_identifier(tokens[j + 1].text):
                    name += "." + tokens[j + 1].text
                    j += 2
            declare(Token(name, following.line), text, private)
            pending_type = text
            continue

        if text in NAMED_KEYWORDS and following is not None:
            if is_identifier(following.text):
                # `case let Failure.code(x)` binds x; Failure is a reference.
                if not (i + 2 < count and tokens[i + 2].text == "."):
                    declare(following, text, private)
            elif following.text == "(" and text in ("let", "var"):
                # A tuple pattern: `let (a, b) = ...` declares both.
                depth = 0
                for k in range(i + 1, count):
                    inner = tokens[k]
                    if inner.text == "(":
                        depth += 1
                    elif inner.text == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    elif is_identifier(inner.text):
                        declare(inner, text, private)
            continue

        if text == "case" and stack and stack[-1][0] in ("enum", "extension"):
            # `case a, b(Int), c = 3`: the names at paren depth 0 that start
            # the comma-separated items. The list ends at a line break, unless
            # a comma or an open parenthesis carries it onto the next line.
            depth = 0
            expect_name = True
            line = token.line
            for k in range(i + 1, count):
                inner = tokens[k]
                if depth == 0 and (inner.text in ("{", "}", ";") or (inner.line != line and not expect_name)):
                    break
                line = inner.line
                if depth == 0 and expect_name and is_identifier(inner.text):
                    declare(inner, "case", private)
                expect_name = False
                if inner.text == "(":
                    depth += 1
                elif inner.text == ")":
                    depth -= 1
                elif inner.text == "," and depth == 0:
                    expect_name = True

    if stack:
        raise CannotCheck(f'cannot scan {path}:{stack[-1][1]}: unclosed "{{"')
    return declarations


LOCAL_BINDERS = frozenset({"let", "var", "for"})
PARAMETER_OWNERS = frozenset({"func", "init", "subscript"})
# A closure's head, `{ [weak self] (a: Int, b) -> T in`, holds only
# identifiers and these. Any other token between a `{` and an `in` means the
# `{` opened something else.
CLOSURE_HEAD_PUNCTUATION = frozenset(",()[]:.<>-?!&@")
CLOSURE_HEAD_STOPS = frozenset({
    "for", "let", "var", "case", "if", "guard", "while", "return", "try", "await", "switch",
})


def _is_local_name(text: str) -> bool:
    return is_identifier(text) and (text[0] == "_" or text[0].islower())


def local_names(tokens: list[Token]) -> set[str]:
    """Lowercase names the file binds anywhere: `let`, `var` and `for`
    bindings, function, initializer and subscript parameters, and closure
    parameters.

    Only lowercase names, because only values are bound this way; a closure's
    `(w: Widget)` still references Widget. The check does not track scopes,
    so a local hides a global of the same name for the whole file -- a blind
    spot Sources/TBDDaemon/CLAUDE.md names.
    """
    names: set[str] = set()
    count = len(tokens)
    for i, token in enumerate(tokens):
        text = token.text
        if text in LOCAL_BINDERS and i + 1 < count:
            following = tokens[i + 1].text
            if following != "(":
                if _is_local_name(following):
                    names.add(following)
                continue
            depth = 0
            for k in range(i + 1, count):
                inner = tokens[k]
                if inner.text == "(":
                    depth += 1
                elif inner.text == ")":
                    depth -= 1
                    if depth == 0:
                        break
                elif _is_local_name(inner.text):
                    names.add(inner.text)
        elif text in PARAMETER_OWNERS and not (i and tokens[i - 1].text in (".", "import")):
            # `func f<T>(_ a: Int, with b: [K: V] = [:])`: the name before
            # each `:` at depth 1 of the first parenthesised list.
            j = i + 1
            while j < count and tokens[j].text not in ("(", "{", "}", "="):
                j += 1
            if j >= count or tokens[j].text != "(":
                continue
            depth = 0
            for k in range(j, count):
                inner = tokens[k].text
                if inner in ("(", "["):
                    depth += 1
                elif inner in (")", "]"):
                    depth -= 1
                    if depth == 0:
                        break
                elif inner == ":" and depth == 1 and _is_local_name(tokens[k - 1].text):
                    names.add(tokens[k - 1].text)
        elif text == "{":
            head: list[str] = []
            for k in range(i + 1, count):
                inner = tokens[k]
                if inner.text == "in":
                    names.update(head)
                    break
                if inner.text in CLOSURE_HEAD_PUNCTUATION:
                    continue
                if not is_identifier(inner.text) or inner.text in CLOSURE_HEAD_STOPS:
                    break
                if _is_local_name(inner.text):
                    head.append(inner.text)
    return names


# The declarations that can take a generic parameter list, or for a protocol,
# primary associated types.
GENERIC_OWNERS = frozenset({
    "func", "struct", "enum", "class", "actor", "protocol", "typealias", "init", "subscript", "macro",
})


def generic_parameter_names(tokens: list[Token]) -> set[str]:
    """The generic parameters the file declares, as in `func f<Widget>()` or
    `struct Box<Widget: Equatable>`, and a protocol's primary associated types:
    the first name of each comma-separated item at depth 1 of the `<...>` that
    follows the declared name, or `init` and `subscript` themselves."""
    names: set[str] = set()
    count = len(tokens)
    for i, token in enumerate(tokens):
        if token.text not in GENERIC_OWNERS or (i and tokens[i - 1].text in (".", "import")):
            continue
        j = i + 1
        if token.text in ("init", "subscript"):
            while j < count and tokens[j].text in ("?", "!"):
                j += 1  # `init?<T>`
        else:
            j += 1  # past the declared name
        if j >= count or tokens[j].text != "<":
            continue
        depth = 0
        expect_name = False
        for k in range(j, count):
            text = tokens[k].text
            if text == "<":
                depth += 1
                expect_name = depth == 1
            elif text == ">" and tokens[k - 1].text != "-":
                depth -= 1
                if depth == 0:
                    break
            elif text == "," and depth == 1:
                expect_name = True
            elif expect_name and text != "each":  # `<each T>` declares T
                if is_identifier(text):
                    names.add(text)
                expect_name = False
    return names


def own_names(source: SourceFile) -> set[str]:
    """Names the file declares for itself, which are never references from it:
    members, nested types, types and functions local to a body, generic
    parameters, private top-level declarations and locals. A private extension
    declares nothing; its name is the extended type's."""
    declared = {
        declaration.name
        for declaration in source.declarations
        if not declaration.at_file_scope
        or (declaration.private and declaration.kind != "extension")
    }
    return declared | local_names(source.tokens) | generic_parameter_names(source.tokens)


def build_index(files: list[SourceFile]) -> dict[str, set[str]]:
    """Each name another unit may reference, mapped to the units declaring it.

    Names declared inside an extension are never indexed: they belong to the
    extended type, and code reaches them through it."""
    index: dict[str, set[str]] = {}
    for source in files:
        for declaration in source.declarations:
            if declaration.at_file_scope and not declaration.private and declaration.kind != "extension":
                index.setdefault(declaration.name, set()).add(source.unit)
    return index


def file_references(source: SourceFile, index: dict[str, set[str]]) -> list[Reference]:
    """Every reference the file makes into another unit.

    A name two units declare -- only an overloaded top-level function can be --
    counts toward each declaring unit, unless the file's own unit declares it
    too: then the file most likely calls its own, and it counts toward none.
    """
    own = own_names(source)
    tokens = source.tokens
    count = len(tokens)
    seen: set[Reference] = set()
    references: list[Reference] = []
    # The open brackets, innermost last.
    brackets: list[str] = []
    for i, token in enumerate(tokens):
        text = token.text
        if text in ("(", "[", "{"):
            brackets.append(text)
            continue
        if text in (")", "]", "}"):
            if brackets:
                brackets.pop()
            continue
        units = index.get(text)
        if not units or source.unit in units or text in own:
            continue
        before = tokens[i - 1].text if i else ""
        # After a `.` it names a member of whatever precedes it. After `...`
        # it is a range's bound, as in `0...widgetLimit`.
        if before == "." and not (i >= 2 and tokens[i - 2].text == "."):
            continue
        # `f(widgetLimit: 1)` and `f(a, widgetLimit: 1)`: an argument label.
        # Only directly in parentheses: in `[a: 1, widgetLimit: 2]` it is a
        # dictionary key, and in `case 1, widgetLimit:` a pattern.
        if (
            before in ("(", ",")
            and brackets and brackets[-1] == "("
            and _is_local_name(text)
            and i + 1 < count and tokens[i + 1].text == ":"
        ):
            continue
        for unit in sorted(units):
            reference = Reference(source.path, token.line, text, (source.unit, unit))
            if reference not in seen:
                seen.add(reference)
                references.append(reference)
    return references


def read_text(path: Path, shown: str, undecodable: str) -> str:
    """The file's text, less a UTF-8 byte order mark. A file that cannot be
    opened raises CannotCheck as `cannot read <shown>`; bytes that are not
    UTF-8 raise it as `<undecodable> <shown>:<line>`."""
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise CannotCheck(f"cannot read {shown}: {error.strerror or error}") from None
    if raw.startswith(codecs.BOM_UTF8):
        raw = raw[len(codecs.BOM_UTF8):]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as error:
        line = raw[:error.start].count(b"\n") + 1
        raise CannotCheck(f"{undecodable} {shown}:{line}: not valid UTF-8") from None


def swift_files(daemon: Path) -> list[PurePosixPath]:
    """Every Swift file under `daemon`, relative to it, in path order. A folder
    that cannot be listed raises CannotCheck: skipping it would drop its links."""

    def cannot_list(error: OSError) -> None:
        shown = (DAEMON_DIR / Path(error.filename or daemon).relative_to(daemon)).as_posix()
        raise CannotCheck(f"cannot read {shown}: {error.strerror or error}")

    found: list[PurePosixPath] = []
    for folder, _, names in os.walk(daemon, onerror=cannot_list):
        for name in names:
            path = Path(folder, name)
            if name.endswith(".swift") and path.is_file():
                found.append(PurePosixPath(path.relative_to(daemon).as_posix()))
    return sorted(found)


def scan_daemon(repo_root: Path) -> Scan:
    daemon = repo_root / DAEMON_DIR
    if not daemon.is_dir():
        raise CannotCheck(f"cannot scan {DAEMON_DIR}: not found")
    files: list[SourceFile] = []
    for rel in swift_files(daemon):
        if rel == PurePosixPath(EXECUTABLE_ONLY):
            continue
        repo_path = (DAEMON_DIR / rel).as_posix()
        unit = unit_of(rel)
        if any(char.isspace() for char in unit):
            # The list could not hold its links: a unit name is one word.
            raise CannotCheck(f'cannot scan {repo_path}: the folder "{unit}" has a space in its name')
        source = read_text(daemon / rel, repo_path, "cannot scan")
        tokens = tokenize(blank_literals_and_comments(source, repo_path))
        files.append(SourceFile(repo_path, unit, tokens, parse_declarations(tokens, repo_path)))
    index = build_index(files)
    references: list[Reference] = []
    for source in files:
        references.extend(file_references(source, index))
    return Scan({source.unit for source in files}, references)


# --------------------------------------------------------------------------
# The list
# --------------------------------------------------------------------------

_LIST_LINE = re.compile(r"(\S+) -> (\S+)\Z")
# A line that would be a link but for a space in a unit's name.
_LIST_LINE_WITH_SPACES = re.compile(r"(.+?) -> (.+)\Z")


def read_list(repo_root: Path) -> dict[Link, int]:
    """Each listed link, mapped to its line in the list."""
    path = repo_root / LINKS_FILE
    if not path.exists():
        raise CannotCheck(f"cannot read {LINKS_FILE}: not found")
    text = read_text(path, str(LINKS_FILE), "cannot read")
    listed: dict[Link, int] = {}
    previous = ""
    for number, raw in enumerate(text.split("\n"), start=1):
        # Trailing whitespace, `\r` included, so a hand edit with CRLF line
        # endings or trailing spaces reads the same as a clean one.
        line = raw.rstrip()
        if not line or line.startswith("#"):
            continue
        where = f"cannot read {LINKS_FILE}:{number}"
        match = _LIST_LINE.match(line)
        if match is None:
            if _LIST_LINE_WITH_SPACES.match(line):
                raise CannotCheck(f'{where}: "{line}": a unit name has no spaces in it')
            raise CannotCheck(f'{where}: expected "A -> B", got "{line}"')
        link = (match.group(1), match.group(2))
        if link[0] == link[1]:
            raise CannotCheck(f'{where}: "{line}" links a unit to itself')
        if link in listed:
            raise CannotCheck(f'{where}: "{line}" is listed twice')
        # Sorted, so that parallel branches add lines in predictable places
        # and their merges conflict only when they add the same link.
        if line < previous:
            raise CannotCheck(f"{where}: out of order; keep the list sorted (LC_ALL=C sort)")
        listed[link] = number
        previous = line
    return listed


def compare_with_list(
    links: dict[Link, list[Reference]], listed: dict[Link, int]
) -> tuple[dict[Link, list[Reference]], dict[Link, int]]:
    """(new, stale): the links code makes that the list lacks, and the listed
    links no code makes."""
    new = {link: references for link, references in links.items() if link not in listed}
    stale = {link: number for link, number in listed.items() if link not in links}
    return new, stale


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------


def plural(count: int, noun: str) -> str:
    return f"{count} {noun}" if count == 1 else f"{count} {noun}s"


def link_text(link: Link) -> str:
    return f"{link[0]} -> {link[1]}"


def cycle_groups(links: Iterable[Link]) -> list[list[str]]:
    """The strongly connected groups of two or more units: within a group,
    every unit reaches every other by following links. Each group is sorted,
    and the groups run largest first, then by first unit."""
    graph: dict[str, set[str]] = {}
    for source, target in links:
        graph.setdefault(source, set()).add(target)
        graph.setdefault(target, set())

    # Tarjan's algorithm. Recursion is safe at this size: one frame per unit.
    order: dict[str, int] = {}
    low: dict[str, int] = {}
    path: list[str] = []
    on_path: set[str] = set()
    groups: list[list[str]] = []

    def visit(unit: str) -> None:
        order[unit] = low[unit] = len(order)
        path.append(unit)
        on_path.add(unit)
        for target in sorted(graph[unit]):
            if target not in order:
                visit(target)
                low[unit] = min(low[unit], low[target])
            elif target in on_path:
                low[unit] = min(low[unit], order[target])
        if low[unit] == order[unit]:
            group: list[str] = []
            while True:
                member = path.pop()
                on_path.discard(member)
                group.append(member)
                if member == unit:
                    break
            if len(group) > 1:
                groups.append(sorted(group))

    for unit in sorted(graph):
        if unit not in order:
            visit(unit)
    return sorted(groups, key=lambda group: (-len(group), group[0]))


def format_cycles(listed: Iterable[Link]) -> str:
    links = list(listed)
    groups = cycle_groups(links)
    if not groups:
        return "cycles among the listed links: none"
    lines = [f"cycles among the listed links: {plural(len(groups), 'group')}"]
    for group in groups:
        members = set(group)
        inside = sum(1 for source, target in links if source in members and target in members)
        lines.append(f"    {plural(len(group), 'unit')}, {plural(inside, 'link')}: {', '.join(group)}")
    return "\n".join(lines)


def failure_report(new: dict[Link, list[Reference]], stale: dict[Link, int], units: set[str]) -> str:
    lines: list[str] = []
    references = sorted(
        (reference for found in new.values() for reference in found),
        key=lambda r: (link_text(r.link), r.path, r.line, r.name),
    )
    for reference in references:
        lines.append(
            f"{reference.path}:{reference.line}: {link_text(reference.link)} is a new link: "
            f"{reference.name} is declared in {reference.link[1]}"
        )
    for link, number in sorted(stale.items(), key=lambda item: item[1]):
        line = (
            f"{LINKS_FILE}:{number}: {link_text(link)} is stale: "
            f"no file in {link[0]} names a declaration from {link[1]}"
        )
        missing = [unit for unit in link if unit not in units]
        if len(missing) == 1:
            line += f" ({missing[0]} is not a unit under {DAEMON_DIR})"
        elif missing:
            line += f" ({missing[0]} and {missing[1]} are not units under {DAEMON_DIR})"
        lines.append(line)

    counts = []
    if new:
        counts.append(plural(len(new), "new link"))
    if stale:
        counts.append(plural(len(stale), "stale link"))
    lines.append(f"lint-daemon-layers: {', '.join(counts)}.")
    if new:
        lines.append(
            "A new link is a reference from one daemon folder into another that "
            f"{LINKS_FILE} does not list. Remove it by moving the declaration into "
            "the folder that uses it or a lower one, or by passing a closure or "
            "protocol in from the folder above. If the link is right, add its line "
            f"to {LINKS_FILE} in this change, so the reviewer sees it:"
        )
        lines.extend(f"    {link_text(link)}" for link in sorted(new, key=link_text))
    if stale:
        lines.append(
            "A stale link is listed, but no code makes it any more. "
            f"Delete its line from {LINKS_FILE} in this change."
        )
    lines.append(f"How to read and fix a failure: {GUIDE}.")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args(argv)

    try:
        scan = scan_daemon(args.repo_root)
        listed = read_list(args.repo_root)
    except CannotCheck as error:
        print(f"lint-daemon-layers: {error}", file=sys.stderr)
        return 2
    except OSError as error:
        # A read the handlers above do not expect: still exit 2, not a traceback.
        print(f"lint-daemon-layers: cannot read {error.filename or 'a file'}: {error.strerror or error}", file=sys.stderr)
        return 2

    links = scan.links()
    new, stale = compare_with_list(links, listed)
    if new or stale:
        print(failure_report(new, stale, scan.units))
        return 1
    print(
        f"lint-daemon-layers: OK, {plural(len(links), 'link')} among "
        f"{plural(len(scan.units), 'unit')}, each listed in {LINKS_FILE}."
    )
    # Information, not a verdict: the cycles still to break before the
    # folders can take a layer order.
    print(format_cycles(listed))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
