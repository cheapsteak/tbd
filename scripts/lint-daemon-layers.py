#!/usr/bin/env python3
"""Check the daemon's folders against the layer order in scripts/daemon-layers.txt.

`TBDDaemonLib` is one SwiftPM module, so the compiler lets any folder under
Sources/TBDDaemon use any other. This check gives the folders a direction
without a build. The layer file lists the layers bottom first, one line per
layer. The check reads every Swift file in the library, finds each place a
file in one unit names a declaration from another, and fails when the unit it
names is in the same layer or a higher one. It also fails when a unit has no
layer, so a new folder gets one in the change that adds it. The design is in
docs/specs/2026-10-30-daemon-layer-order-design.md; how to read and fix a
failure is in Sources/TBDDaemon/CLAUDE.md, "Folder layers".

A unit is a folder directly under Sources/TBDDaemon, subfolders included, or
`(root)` for the files directly in it. `main.swift` belongs to the executable
target, not the library, and is skipped.

It matches names, not types. The index holds each unit's top-level
declarations that are not private or fileprivate: types, typealiases,
top-level functions and globals. A file references unit B when it names one
of B's, in code or in a string's interpolation. A name in a comment, a
literal or a raw identifier, after a `.` (but not after `...`), or as a label
-- an argument label or a function type's parameter name in parentheses, a
trailing closure's label, a statement label -- is not a reference (bar the false forms listed in
Sources/TBDDaemon/CLAUDE.md), and
neither is a name the file declares for itself: a member, a nested type or one
declared in a body, a generic parameter, a private declaration, or a
lowercase local, pattern binding or parameter.

It fails closed: a file or folder it cannot open, and Swift it cannot read
-- an unbalanced brace, a literal or comment that never closes, bytes that
are not UTF-8 -- stop it with exit 2, rather than let it judge references
it may have read wrong. So does a layer file it cannot read: a name that is
no unit, a unit listed twice, a stray comma, or bytes that are not UTF-8.

Exit codes: 0 every reference runs into a lower layer and every unit has a
layer; 1 a reference into the same layer or a higher one, or a unit with no
layer; 2 the tree or the layer file cannot be read.

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
from typing import NoReturn

# --------------------------------------------------------------------------
# Where things live, relative to the repository root
# --------------------------------------------------------------------------

DAEMON_DIR = PurePosixPath("Sources/TBDDaemon")
LAYERS_FILE = PurePosixPath("scripts/daemon-layers.txt")

# The unit for the files directly under DAEMON_DIR. The parentheses keep it
# from colliding with any folder name Swift code could live in.
ROOT_UNIT = "(root)"

# Package.swift gives this one file to the `TBDDaemon` executable target, so
# nothing in the library can name what it declares, and what it names is the
# executable's business.
EXECUTABLE_ONLY = "main.swift"

GUIDE = 'Sources/TBDDaemon/CLAUDE.md, "Folder layers"'

# (from unit, to unit)
Link = tuple[str, str]


class CannotCheck(Exception):
    """The tree or the layer file cannot be read. The message is what follows
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

    def raw_closes_on_its_line(quote: int, hashes: int) -> bool:
        # Whether a raw string whose opening quote is at `quote`, and which
        # starts with three quotes like a multi-line one, closes on its own
        # line. Swift reads it as single-line then: `#"""#` is a string
        # holding one quote. A quote and the string's hashes anywhere after
        # the opening quote and the character after it, before the line
        # ends, close it.
        if not hashes:
            return False
        end = source.find("\n", quote)
        return source.find('"' + "#" * hashes, quote + 2, size if end < 0 else end) >= 0

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
                multi_line = source.startswith('"""', j) and not raw_closes_on_its_line(j, hashes)
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


PUNCTUATION = frozenset("{}()[]<>.,:;=@#?!&|+-*/%^~") | {"..."}

# A newline; or an identifier, `...` or one punctuation character; or a number,
# which is matched only so its digits never start an identifier. Everything
# else -- quotes, `$`, `\`, whitespace -- is skipped. `...` is one token so that
# a `.` token is always a member access: in `0...limit` the name after it is a
# range's bound, and in `0 ... .max` the `.max` is a member.
_TOKEN = re.compile(r"(\n)|(\.\.\.|[^\W\d]\w*|[{}()\[\]<>.,:;=@#?!&|+\-*/%^~])|\d\w*")


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


def spelled_like_a_keyword(tokens: list[Token], i: int) -> bool:
    """Whether tokens[i], whatever it spells, is no keyword where it stands:
    a member after a `.`, as in `Foo.Type` or `level = .private`, or the kind
    in a scoped import, as in `import struct M.Name`, which brings one
    declaration in from another module and declares nothing here."""
    return i > 0 and tokens[i - 1].text in (".", "import")


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
# No type takes one of these as its name. They follow `class` where it is a
# modifier, as in `class func` or `class override var`, and `actor` where it is
# a value, as in `actor as Sendable`.
NOT_A_TYPE_NAME = frozenset({
    "func", "var", "let", "subscript", "init", "deinit", "typealias",
    "override", "final", "open", "public", "internal", "private", "fileprivate", "nonisolated", "dynamic",
    "as", "is", "in",
})


def names_a_type(keyword: Token, following: Token) -> bool:
    """Whether a type keyword declares the type `following` names."""
    if not is_identifier(following.text) or following.text in NOT_A_TYPE_NAME:
        return False
    # `actor` is a keyword only before a name on its line; anywhere else it can
    # be a variable's name, as in `actor: actor`.
    return keyword.text != "actor" or following.line == keyword.line


# Where a pattern ends, outside its parentheses.
_PATTERN_ENDS = frozenset({"=", ":", "in", "where", "{", "}", ";", ","})


def bound_names(tokens: list[Token], i: int) -> list[Token]:
    """The names the `let`, `var` or `for` at tokens[i] binds.

    `let x`, `for x in` and `for try await x in` bind that one name, whatever
    its case. A pattern binds each lowercase name in it that is neither a
    member, nor a value with a member after it, nor a label: `let (a, b)`,
    `case let .some(a)`, `case let .pair(a, label: b)`, and only `a` in
    `case let Result.success(a)` and `case let (Widget.zero, a)`, where Result
    and Widget stay references. Only lowercase names, so no type in a pattern
    is ever taken for a binding.
    """
    count = len(tokens)
    start = i + 1
    if tokens[i].text == "for":
        while start < count and tokens[start].text in ("try", "await"):
            start += 1
        # `for case let x? in xs`: its `let` binds. Without one, a name in a
        # case pattern is a value it matches, as in `for case .some(limit) in`.
        if start < count and tokens[start].text == "case":
            return []
    if start >= count:
        return []
    following = tokens[start]
    if is_identifier(following.text) and (start + 1 >= count or tokens[start + 1].text != "."):
        return [following]
    names: list[Token] = []
    depth = 0
    for k in range(start, count):
        text = tokens[k].text
        if depth == 0 and text in _PATTERN_ENDS:
            break
        if text == "(":
            depth += 1
        elif text == ")":
            depth -= 1
            if depth < 0:
                break  # the pattern sat in parentheses, as in `case (_, let .some(a)):`
        elif (
            _is_local_name(text)
            and tokens[k - 1].text != "."
            and (k + 1 >= count or tokens[k + 1].text not in (".", ":"))
        ):
            names.append(tokens[k])
    return names


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
        if spelled_like_a_keyword(tokens, i):
            continue
        if text in PRIVATE_MODIFIERS:
            # `private(set)` restricts only the setter; the name stays visible.
            if i + 1 >= count or tokens[i + 1].text != "(":
                pending_private = True
            continue
        if text not in DECLARATION_KEYWORDS:
            continue
        following = tokens[i + 1] if i + 1 < count else None
        private, pending_private = pending_private, False

        if text in TYPE_KEYWORDS:
            if following is None or not names_a_type(token, following):
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

        if text in ("let", "var"):
            for name_token in bound_names(tokens, i):
                declare(name_token, text, private)
            continue
        if text in NAMED_KEYWORDS:
            if following is not None and is_identifier(following.text):
                declare(following, text, private)
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
CLOSURE_HEAD_PUNCTUATION = frozenset(",()[]:.<>-?!&@") | {"..."}
CLOSURE_HEAD_STOPS = frozenset({
    "for", "let", "var", "case", "if", "guard", "while", "return", "try", "await", "switch",
})


def _is_local_name(text: str) -> bool:
    return is_identifier(text) and (text[0] == "_" or text[0].islower())


def local_names(tokens: list[Token]) -> set[str]:
    """Lowercase names the file binds anywhere: `let`, `var` and `for`
    bindings and patterns, function, initializer and subscript parameters,
    and closure parameters.

    Only lowercase names, because only values are bound this way; a closure's
    `(w: Widget)` still references Widget. The check does not track scopes,
    so a local hides a global of the same name for the whole file -- a blind
    spot Sources/TBDDaemon/CLAUDE.md names.
    """
    names: set[str] = set()
    count = len(tokens)
    for i, token in enumerate(tokens):
        text = token.text
        if text in LOCAL_BINDERS:
            names.update(name.text for name in bound_names(tokens, i) if _is_local_name(name.text))
        elif text in PARAMETER_OWNERS and not spelled_like_a_keyword(tokens, i):
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
                    # `{ f(in: x) }`: an argument label, so no closure head.
                    if k + 1 >= count or tokens[k + 1].text != ":":
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
# The punctuation an operator's name is made of.
OPERATOR_PUNCTUATION = frozenset("/=-+!*%<>&|^~?.") | {"..."}


def generic_parameter_names(tokens: list[Token]) -> set[str]:
    """The generic parameters the file declares, as in `func f<Widget>()` or
    `struct Box<Widget: Equatable>`, and a protocol's primary associated types:
    the first name of each comma-separated item at depth 1 of the `<...>` that
    follows the declared name, or `init` and `subscript` themselves."""
    names: set[str] = set()
    count = len(tokens)
    for i, token in enumerate(tokens):
        if token.text not in GENERIC_OWNERS:
            continue
        j = i + 1
        if token.text in ("init", "subscript"):
            while j < count and tokens[j].text in ("?", "!"):
                j += 1  # `init?<T>`
        elif token.text == "func" and j < count and tokens[j].text in OPERATOR_PUNCTUATION:
            # An operator's name is a run of punctuation, as in
            # `static func << (lhs: inout Buf, rhs: UInt8)`. Swift reads a
            # generic list after it only as in `func ==<T>(...)`: the run's
            # last `<`, before a name.
            while j < count and tokens[j].text in OPERATOR_PUNCTUATION:
                j += 1
            if tokens[j - 1].text != "<" or j >= count or not is_identifier(tokens[j].text):
                continue
            j -= 1
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


# The statements a label can name.
LABELED_STATEMENTS = frozenset({"for", "while", "repeat", "do", "if", "switch"})


def is_member_or_label(tokens: list[Token], i: int, brackets: list[str]) -> bool:
    """Whether the name at tokens[i], which is not the first token, is a
    member or a label rather than a reference. `brackets` holds the brackets
    open around it, innermost last."""
    before = tokens[i - 1]
    # After a `.` it names a member of whatever precedes it. `...` is a token
    # of its own, so in `0...widgetLimit` the name is a range's bound.
    if before.text == ".":
        return True
    # `break widgetLimit` and `continue widgetLimit` name a statement label.
    if before.text in ("break", "continue"):
        return True
    if i + 1 >= len(tokens) or tokens[i + 1].text != ":":
        return False
    after = tokens[i + 2].text if i + 2 < len(tokens) else ""
    # Directly in parentheses: an argument label, as in `f(widgetLimit: 1)` and
    # `f(a, widgetLimit: 1)`, or a parameter's name in a function type, as in
    # `(_ widgetLimit: Int) -> Void`. In `[a: 1, widgetLimit: 2]` it is a
    # dictionary key, and in `case 1, widgetLimit:` a pattern: both code.
    if before.text in ("(", ",", "_") and brackets and brackets[-1] == "(":
        return True
    # A trailing closure's label: `f { ... } widgetLimit: { ... }`.
    if before.text == "}" and after == "{":
        return True
    # A statement's label, `widgetLimit: for x in xs`, which starts a statement
    # in a body or at file scope.
    return (
        after in LABELED_STATEMENTS
        and (not brackets or brackets[-1] == "{")
        and (before.line != tokens[i].line or before.text in ("{", ";"))
    )


def file_references(source: SourceFile, index: dict[str, set[str]]) -> list[Reference]:
    """Every reference the file makes into another unit.

    A name two units declare -- only an overloaded top-level function can be --
    counts toward each declaring unit, unless the file's own unit declares it
    too: then the file most likely calls its own, and it counts toward none.
    """
    own = own_names(source)
    tokens = source.tokens
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
        if i and is_member_or_label(tokens, i, brackets):
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
            # The layer file could not name it: a unit name is one word.
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
# The layer order
# --------------------------------------------------------------------------


def read_layers(repo_root: Path, units: set[str]) -> list[list[str]]:
    """The layers, bottom first, each holding the units its line lists.

    A line lists its units separated by commas. A blank line, or one that
    starts with `#`, is no layer, so layer numbers count layer lines only.
    Raises CannotCheck at the line of a name that is no unit, a unit listed
    twice, an empty name or a name with a space in it: an order read past
    any of those would be the wrong order, not a broken one.
    """
    path = repo_root / LAYERS_FILE
    if not path.exists():
        raise CannotCheck(f"cannot read {LAYERS_FILE}: not found")
    text = read_text(path, str(LAYERS_FILE), "cannot read")
    layers: list[list[str]] = []
    listed_on: dict[str, int] = {}
    for number, raw in enumerate(text.split("\n"), start=1):
        # Surrounding whitespace, `\r` included, so a hand edit with CRLF line
        # endings or stray spaces reads the same as a clean one.
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        where = f"cannot read {LAYERS_FILE}:{number}"
        layer: list[str] = []
        for item in line.split(","):
            name = item.strip()
            if not name:
                raise CannotCheck(f'{where}: "{line}" has an empty name: a comma with no unit beside it')
            if any(char.isspace() for char in name):
                raise CannotCheck(f'{where}: "{name}": a unit name has no spaces in it; separate units with commas')
            if name in listed_on:
                raise CannotCheck(f"{where}: {name} is listed twice: line {listed_on[name]} lists it too")
            if name not in units:
                raise CannotCheck(f"{where}: {name} is not a unit under {DAEMON_DIR}")
            listed_on[name] = number
            layer.append(name)
        layers.append(layer)
    return layers


def layer_numbers(layers: list[list[str]]) -> dict[str, int]:
    """Each listed unit's layer, 1 for the bottom."""
    return {unit: number for number, layer in enumerate(layers, start=1) for unit in layer}


def check_order(scan: Scan, layer_of: dict[str, int]) -> tuple[list[Reference], list[str]]:
    """(against, unlisted): the references from a unit into its own layer or a
    higher one, and the units no line lists. A reference to or from a unit
    with no layer is not judged; that unit fails on its own."""
    against = [
        reference
        for reference in scan.references
        if reference.link[0] in layer_of
        and reference.link[1] in layer_of
        and layer_of[reference.link[1]] >= layer_of[reference.link[0]]
    ]
    return against, sorted(scan.units - layer_of.keys())


def where_it_fits(unit: str, links: set[Link], layer_of: dict[str, int], top: int) -> str:
    """Where a unit with no layer can go: the lowest layer above every listed
    unit it uses and below every listed unit that uses it, or a new line when
    no layer is both."""
    uses = max((layer_of[target] for source, target in links if source == unit and target in layer_of), default=0)
    used_by = min((layer_of[source] for source, target in links if target == unit and source in layer_of), default=top + 1)
    if uses + 1 < used_by:
        return f"it fits in layer {uses + 1}"
    if uses + 1 > used_by:
        return f"no layer fits it: it uses layer {uses}, and layer {used_by} uses it"
    if used_by > top:
        return "it needs a new line at the top"
    if uses == 0:
        return "it needs a new line at the bottom"
    return f"it needs a new line between layers {uses} and {used_by}"


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------


def plural(count: int, noun: str) -> str:
    return f"{count} {noun}" if count == 1 else f"{count} {noun}s"


def failure_report(
    against: list[Reference], unlisted: list[str], layer_of: dict[str, int], links: set[Link], top: int
) -> str:
    lines: list[str] = []
    for reference in sorted(against, key=lambda r: (r.path, r.line, r.name, r.link)):
        user, used = reference.link
        relation = "its own layer" if layer_of[used] == layer_of[user] else "a higher layer"
        lines.append(
            f"{reference.path}:{reference.line}: {user} (layer {layer_of[user]}) uses "
            f"{used} (layer {layer_of[used]}), {relation}: {reference.name} is declared in {used}"
        )
    for unit in unlisted:
        lines.append(f"{LAYERS_FILE}: {unit} has no layer; {where_it_fits(unit, links, layer_of, top)}")

    counts = []
    if against:
        counts.append(
            f"{plural(len(against), 'reference')} against the layer order, "
            f"in {plural(len({reference.link for reference in against}), 'link')}"
        )
    if unlisted:
        counts.append(f"{plural(len(unlisted), 'unit')} with no layer")
    lines.append(f"lint-daemon-layers: {'; '.join(counts)}.")
    if against:
        lines.extend([
            f"{LAYERS_FILE} lists the layers bottom first, and a unit may use only units "
            "in a lower layer. Fix each reference above in one of three ways:",
            "    - Move the declaration into the unit that uses it, or into a lower unit both can use.",
            "    - Pass a closure or a protocol in from the unit above, so the lower unit stops naming the higher one.",
            "    - If the direction is right, move the using unit up, to a line above the unit it uses, "
            f"in {LAYERS_FILE} in this change, so the reviewer sees the move.",
            "If this change makes none of these references, main already fails: one change moved a unit "
            "or a declaration, and another that passed alone added a reference the old order allowed. "
            "Fix it the same way, in a pull request of its own.",
        ])
    if unlisted:
        lines.append(
            f"Every unit has a layer. Add each unit above to {LAYERS_FILE} in this change, "
            "on the line or new line its message names."
        )
    lines.append(f"How to read and fix a failure: {GUIDE}.")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args(argv)

    try:
        scan = scan_daemon(args.repo_root)
        layers = read_layers(args.repo_root, scan.units)
    except CannotCheck as error:
        print(f"lint-daemon-layers: {error}", file=sys.stderr)
        return 2
    except OSError as error:
        # A read the handlers above do not expect: still exit 2, not a traceback.
        print(f"lint-daemon-layers: cannot read {error.filename or 'a file'}: {error.strerror or error}", file=sys.stderr)
        return 2

    layer_of = layer_numbers(layers)
    links = {reference.link for reference in scan.references}
    against, unlisted = check_order(scan, layer_of)
    if against or unlisted:
        print(failure_report(against, unlisted, layer_of, links, len(layers)))
        return 1
    print(
        f"lint-daemon-layers: OK, {plural(len(scan.units), 'unit')} in {plural(len(layers), 'layer')}, "
        f"{plural(len(links), 'link')}, each into a lower layer."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
