#!/usr/bin/env python3
"""Hold every test construction of a WorktreeLifecycle or a
HibernationCoordinator to naming its leftover-tmux probe.

Both types fall back to `LeftoverTmuxServerProbe.production()` when they are
built without a `leftoverTmuxProbe:` argument, or with nil, which is what the
daemon wants. A test that got it would read the machine's process table, where
a tmux process whose argv cannot be read counts as a running server, so the
suite could refuse a revive or a wake on whatever tmux the machine happened to
run. The compiler cannot tell a test from the daemon, so this check does it
without a build. Under `Tests/`:

- Every construction passes `leftoverTmuxProbe:` with a value that cannot be
  nil: not `nil`, not `.none` in any spelling, and with neither at the top
  level of the value, as in `probe ?? nil`. A suite that does not exercise the
  probe passes `.absent` (Tests/DaemonTestSupport); one that does passes its
  own. A router needs nothing: it hands its coordinator its lifecycle's.

  A construction is `WorktreeLifecycle(` or `HibernationCoordinator(`, bare or
  qualified with `TBDDaemonLib.` or `TBDDaemon.`, with or without `.init`. It
  is also a `.init(` whose type is written beside it, as in
  `let l: WorktreeLifecycle = .init(...)`; a `.init(` returned by a function,
  closure or computed property declared to return one of the two types, as the
  body's first statement or after a `return` that no nested closure owns; and
  a `self.init(`, `Self(` or `Self.init(` inside an extension of either type.
  The check reads no types, so a `.init(` whose type comes from anywhere else,
  such as a parameter's declared type, is not seen: name the type instead.
- No parameter, property or return type is a `LeftoverTmuxServerProbe?`, a
  `LeftoverTmuxServerProbe!` or an `Optional<LeftoverTmuxServerProbe>`. A
  helper that took one and passed it on as `leftoverTmuxProbe:` would hand
  the production probe to every caller that left it out; take a non-optional
  `LeftoverTmuxServerProbe` that defaults to `.absent` instead.
- `production()` is used only in the files in `PRODUCTION_ALLOWED`: the
  probe's own suite, whose calls inject the environment and the process
  lister, and the tier-3 test that runs it against a real tmux server. A use
  is `LeftoverTmuxServerProbe.production`, called or named as a function, and
  any implicit-member `.production(` or `.production {` whose argument labels
  are all the probe's own (`environment`, `fallbackRoot`, `uid`,
  `tmuxProcesses`) or that has none, wherever it is passed. Another type's
  `.production(` is told apart only by its labels, so spell one that takes
  none of its own as `Type.production()`.

It reads code only: comments, string literals and regex literals are skipped,
and a string's interpolation is read as code. An extended regex literal,
`#/.../#`, may span lines. A bare `/.../` is a regex literal only on one line,
where an expression can start, and when it neither opens with a space or `=`
nor closes after a space, as Swift reads it; anywhere else a `/` is division.
It fails closed: a literal, comment or bracket that never closes, or a file
that is not UTF-8, stops it with exit 2.

The probe, and with it this check, is a transition measure: see
`LeftoverTmuxServerProbe` for its replacement date.

Exit codes: 0 nothing under `Tests/` can reach the production probe; 1
something can; 2 the tree cannot be read.

Usage:
  scripts/lint-test-leftover-tmux-probe.py [--repo-root DIR]
  scripts/lint-test-leftover-tmux-probe.py --self-test
"""

import argparse
import os
import re
import sys

PRODUCTION_ALLOWED = {
    "Tests/TBDDaemonTests/LeftoverTmuxServerProbeTests.swift",
    "Tests/TBDDaemonLiveTests/WorktreeLifecycleLiveTests.swift",
}

# The argument labels of `LeftoverTmuxServerProbe.production(...)`.
PROBE_LABELS = frozenset({"environment", "fallbackRoot", "uid", "tmuxProcesses"})

MODULE = r"(?:(?:TBDDaemonLib|TBDDaemon)\s*\.\s*)?"
TYPES = r"(WorktreeLifecycle|HibernationCoordinator)"
# One of the two types as a declared type, optional or not.
DECLARED_TYPE = MODULE + TYPES + r"\b\s*[?!]?"
EFFECTS = r"(?:(?:try[?!]?|await)\s+)*"
IMPLICIT_INIT = EFFECTS + r"\.\s*init\s*\("

CONSTRUCTION = re.compile(r"(?<![\w.])" + MODULE + TYPES + r"\b(?:\s*\.\s*init)?\s*\(")
# `let l: WorktreeLifecycle = .init(`, and a parameter's default value.
CONTEXT_INIT = re.compile(r":\s*" + DECLARED_TYPE + r"\s*=\s*" + IMPLICIT_INIT)
# Bodies whose value is one of the two types; each pattern ends at the body's `{`.
TYPED_BODIES = [
    # func make() -> WorktreeLifecycle {
    re.compile(r"->\s*" + DECLARED_TYPE + r"\s*\{"),
    # let make: () -> WorktreeLifecycle = {, and a closure parameter's default
    re.compile(r"->\s*" + DECLARED_TYPE + r"(?:\s*\)\s*[?!]?)?\s*=\s*\{"),
    # var lifecycle: WorktreeLifecycle {
    re.compile(r"\bvar\s+[A-Za-z_]\w*\s*:\s*" + DECLARED_TYPE + r"\s*\{"),
    # lazy var lifecycle: WorktreeLifecycle = { ... }()
    re.compile(r":\s*" + DECLARED_TYPE + r"\s*=\s*\{"),
]
# { () -> WorktreeLifecycle in ... }: the body runs from `in` to the closure's `}`.
CLOSURE_SIGNATURE = re.compile(r"->\s*" + DECLARED_TYPE + r"\s+in\b")
FIRST_STATEMENT_INIT = re.compile(r"\s*(?:return\s+)?" + IMPLICIT_INIT)
RETURN_INIT = re.compile(r"(?<![\w.])return\s+" + IMPLICIT_INIT)
EXTENSION = re.compile(r"\bextension\s+" + MODULE + TYPES + r"\b(?!\s*\.)[^{]*\{")
SELF_INIT = re.compile(r"(?<![\w.])(?:self\s*\.\s*init|Self(?:\s*\.\s*init)?)\s*\(")
# A nested `{` whose statement starts with one of these is a block of the
# body it sits in, so a `return` inside it returns from that body.
CONTROL_KEYWORDS = frozenset({
    "if", "else", "guard", "for", "while", "repeat", "do", "catch", "switch",
})

PROBE_TYPE = r"(?<![\w.])" + MODULE + r"LeftoverTmuxServerProbe\b"
# A declared type that can hold nil. One followed by `.`, as in
# `Optional<LeftoverTmuxServerProbe>.none`, is a value, which the nil check
# reads instead.
OPTIONAL_PROBE = re.compile(
    PROBE_TYPE + r"[?!](?![=.])"
    r"|(?<![\w.])Optional\s*<\s*" + MODULE + r"LeftoverTmuxServerProbe\s*>(?!\s*\.)"
)
NIL_VALUE = re.compile(r"(?<![\w.])nil\b|\.\s*none\b")

EXPLICIT_PRODUCTION = re.compile(PROBE_TYPE + r"\s*\.\s*production\b")
MEMBER_PRODUCTION = re.compile(r"\.production\b\s*([({])")
# A word an implicit member expression can follow; after any other word a
# `.` is a member access.
EXPRESSION_KEYWORDS = frozenset({
    "return", "throw", "try", "await", "in", "case", "where", "if", "guard", "while",
    "switch",
})

STRING_OPEN = re.compile(r'(#*)("""|")')
# A bare `/regex/` can start only where an operand can: after one of these,
# at the start of a line, or after a keyword that an expression follows.
# Anywhere else a `/` is division.
REGEX_MAY_FOLLOW = frozenset("(,=:[{;!&|?^~")
REGEX_MAY_FOLLOW_KEYWORDS = EXPRESSION_KEYWORDS
# ...and never with one of these after the `/`, which make it `/ x`, `//`,
# `/*` or `/=`.
REGEX_MAY_NOT_START_WITH = frozenset(" \t\n/*=")
# Every literal leaves this one character behind in place of its last one, so
# a scan that looks back past it sees an operand rather than whitespace.
LITERAL = '"'


class Unreadable(Exception):
    pass


def code_only(text):
    """`text` with comment and literal characters blanked to spaces, newlines
    kept, so offsets and line numbers still line up. A string or regex literal
    leaves `LITERAL` in place of its last character. A string's interpolation
    stays code."""
    out = list(text)
    n = len(text)
    i = 0
    # ("code", depth) where depth counts parens inside an interpolation, or
    # None at the top level; ("string", hashes, multiline).
    stack = [("code", None)]

    def blank(start, end):
        for k in range(start, end):
            if out[k] != "\n":
                out[k] = " "

    def blank_literal(start, end):
        blank(start, end)
        out[end - 1] = LITERAL

    def bare_regex_close(slash):
        """The closing `/` of a bare regex opening at `slash`, or None when
        that `/` is an operator."""
        after = text[slash + 1:slash + 2]
        if not after or after in REGEX_MAY_NOT_START_WITH:
            return None
        k = slash - 1
        while k >= 0 and out[k] in " \t":
            k -= 1
        if k >= 0 and out[k] != "\n" and out[k] not in REGEX_MAY_FOLLOW:
            end = k + 1
            while k >= 0 and (out[k].isalnum() or out[k] == "_"):
                k -= 1
            if "".join(out[k + 1:end]) not in REGEX_MAY_FOLLOW_KEYWORDS:
                return None
        j = slash + 1
        while j < n:
            ch = text[j]
            if ch == "\n":
                return None
            if ch == "\\":
                if text[j + 1:j + 2] in ("", "\n"):
                    return None
                j += 2
                continue
            if ch == "/":
                # `/ x /` is two divisions; a regex cannot end on a space.
                return j if text[j - 1] not in " \t" else None
            j += 1
        return None

    def extended_regex_end(slash, hashes):
        closer = "/" + "#" * hashes
        j = slash + 1
        while j < n:
            if text[j] == "\\":
                j += 2
            elif text.startswith(closer, j):
                return j + len(closer)
            else:
                j += 1
        raise Unreadable("a regex literal never closes")

    while i < n:
        top = stack[-1]
        if top[0] == "code":
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = n if end < 0 else end
                blank(i, end)
                i = end
                continue
            if text.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if text.startswith("/*", j):
                        depth, j = depth + 1, j + 2
                    elif text.startswith("*/", j):
                        depth, j = depth - 1, j + 2
                    else:
                        j += 1
                if depth:
                    raise Unreadable("a block comment never closes")
                blank(i, j)
                i = j
                continue
            if text[i] == "/":
                close = bare_regex_close(i)
                if close is not None:
                    blank_literal(i, close + 1)
                    i = close + 1
                    continue
            if text[i] == "#":
                j = i
                while j < n and text[j] == "#":
                    j += 1
                if text[j:j + 1] == "/":
                    end = extended_regex_end(j, j - i)
                    blank_literal(i, end)
                    i = end
                    continue
            if text[i] in '#"':
                m = STRING_OPEN.match(text, i)
                if m:
                    hashes = len(m.group(1))
                    # `"""` opens a multi-line literal only when nothing but
                    # whitespace follows it on its line; `#""""#` is a
                    # one-line raw string holding `""`.
                    end_of_line = text.find("\n", m.end())
                    rest = text[m.end():n if end_of_line < 0 else end_of_line]
                    multiline = m.group(2) == '"""' and not rest.strip()
                    opener_end = m.end() if multiline else i + hashes + 1
                    blank(i, opener_end)
                    stack.append(("string", hashes, multiline))
                    i = opener_end
                    continue
            if top[1] is not None:
                if text[i] == "(":
                    stack[-1] = ("code", top[1] + 1)
                elif text[i] == ")":
                    if top[1] == 0:
                        out[i] = " "
                        stack.pop()
                        i += 1
                        continue
                    stack[-1] = ("code", top[1] - 1)
            i += 1
            continue
        _, hashes, multiline = top
        close = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        if text.startswith(escape + "(", i):
            blank(i, i + len(escape) + 1)
            i += len(escape) + 1
            stack.append(("code", 0))
            continue
        if text.startswith(escape, i):
            blank(i, min(n, i + len(escape) + 1))
            i += len(escape) + 1
            continue
        if text.startswith(close, i):
            blank_literal(i, i + len(close))
            i += len(close)
            stack.pop()
            continue
        if text[i] == "\n" and not multiline:
            raise Unreadable("a string literal never closes on its line")
        if text[i] != "\n":
            out[i] = " "
        i += 1
    if len(stack) != 1:
        raise Unreadable("a string literal or interpolation never closes")
    return "".join(out)


PAIRS = {"(": ")", "[": "]", "{": "}"}


def closing_bracket(code, open_index):
    depth = 0
    for k in range(open_index, len(code)):
        ch = code[k]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                if ch != PAIRS[code[open_index]]:
                    raise Unreadable("a bracket closes the wrong kind of bracket")
                return k
    raise Unreadable("a bracket never closes")


def enclosing_brace_close(code, start):
    """The `}` that closes the brace `start` sits inside."""
    depth = 0
    for k in range(start, len(code)):
        ch = code[k]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                if ch != "}":
                    raise Unreadable("a bracket closes the wrong kind of bracket")
                return k
            depth -= 1
    raise Unreadable("a closure never closes")


def arguments(code, open_index, close_index):
    """Each top-level argument between the parentheses, as (label, value)."""
    found = []
    depth = 0
    start = open_index + 1
    for k in range(open_index + 1, close_index + 1):
        ch = code[k]
        if k == close_index or (ch == "," and depth == 0):
            piece = code[start:k]
            if piece.strip():
                m = re.match(r"\s*([A-Za-z_]\w*)\s*:(?!:)\s*(.*)$", piece, re.S)
                if m:
                    found.append((m.group(1), m.group(2).strip()))
                else:
                    found.append((None, piece.strip()))
            start = k + 1
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
    return found


def opens_control_block(code, brace):
    """Whether the `{` at `brace` opens an `if`, `else`, `switch` or other
    statement block, rather than a closure or a nested declaration."""
    depth = 0
    k = brace - 1
    while k >= 0:
        ch = code[k]
        if ch in ")]":
            depth += 1
        elif ch in "([":
            if depth == 0:
                return False  # an argument: a closure
            depth -= 1
        elif depth == 0 and ch in "{};\n":
            break
        k -= 1
    m = re.match(r"[\s}]*([A-Za-z_]\w*)", code[k + 1:brace])
    return bool(m) and m.group(1) in CONTROL_KEYWORDS


def returned_inits(code, start, end):
    """The open parentheses of the `.init(` calls a body returns: its first
    statement, and each `return .init(` that no nested closure owns."""
    found = []
    m = FIRST_STATEMENT_INIT.match(code, start)
    if m and m.end() <= end:
        found.append(m.end() - 1)
    for r in RETURN_INIT.finditer(code, start, end):
        unclosed = []
        for k in range(start, r.start()):
            if code[k] == "{":
                unclosed.append(k)
            elif code[k] == "}" and unclosed:
                unclosed.pop()
        if all(opens_control_block(code, brace) for brace in unclosed):
            found.append(r.end() - 1)
    return found


def constructions(code):
    """Each construction of either type, as (description, open paren, anchor)."""
    found = {}

    def add(description, open_index, anchor):
        if open_index not in found:
            found[open_index] = (description, anchor)

    for m in CONSTRUCTION.finditer(code):
        add("%s(" % m.group(1), m.end() - 1, m.start())
    for m in CONTEXT_INIT.finditer(code):
        add("a .init( typed %s" % m.group(1), m.end() - 1, m.end() - 1)
    for pattern in TYPED_BODIES:
        for m in pattern.finditer(code):
            brace = m.end() - 1
            for open_index in returned_inits(code, brace + 1, closing_bracket(code, brace)):
                add("a .init( returned as a %s" % m.group(1), open_index, open_index)
    for m in CLOSURE_SIGNATURE.finditer(code):
        for open_index in returned_inits(code, m.end(), enclosing_brace_close(code, m.end())):
            add("a .init( returned as a %s" % m.group(1), open_index, open_index)
    for m in EXTENSION.finditer(code):
        brace = m.end() - 1
        for s in SELF_INIT.finditer(code, brace + 1, closing_bracket(code, brace)):
            add("%s's %s(" % (m.group(1), re.sub(r"\s+", "", s.group(0))[:-1]),
                s.end() - 1, s.start())
    return sorted((open_index, description, anchor)
                  for open_index, (description, anchor) in found.items())


def top_level(value):
    """`value` with everything inside its brackets blanked, after unwrapping
    the parentheses around the whole of it."""
    value = value.strip()
    while value.startswith("(") and closing_bracket(value, 0) == len(value) - 1:
        value = value[1:-1].strip()
    out = []
    depth = 0
    for ch in value:
        if ch in "([{":
            depth += 1
        out.append(ch if depth == 0 else " ")
        if ch in ")]}":
            depth -= 1
    return "".join(out)


def may_be_nil(value):
    return NIL_VALUE.search(top_level(value)) is not None


def is_implicit_member(code, dot):
    """Whether the `.` at `dot` begins an implicit member expression, rather
    than a member access on what precedes it."""
    k = dot - 1
    while k >= 0 and code[k] in " \t\n":
        k -= 1
    if k < 0:
        return True
    ch = code[k]
    if ch.isalnum() or ch == "_":
        end = k + 1
        while k >= 0 and (code[k].isalnum() or code[k] == "_"):
            k -= 1
        return code[k + 1:end] in EXPRESSION_KEYWORDS
    if ch in ")]}>`" + LITERAL:
        return False
    # `x?.production` and `x!.production` chain; `c ? .production` does not.
    return not (ch in "?!" and k == dot - 1)


def production_uses(code):
    """Where `code` uses the probe's `production`."""
    found = set()
    for m in EXPLICIT_PRODUCTION.finditer(code):
        found.add(m.start())
    for m in MEMBER_PRODUCTION.finditer(code):
        if not is_implicit_member(code, m.start()):
            continue
        if m.group(1) == "(":
            open_index = m.end() - 1
            labels = [label for label, _ in
                      arguments(code, open_index, closing_bracket(code, open_index))]
            if not all(label in PROBE_LABELS for label in labels):
                continue
        found.add(m.start())
    return sorted(found)


def check_text(relative_path, text):
    """Problems in one file, as (line, message), in line order."""
    code = code_only(text)

    def line_of(index):
        return code.count("\n", 0, index) + 1

    problems = []
    for open_index, description, anchor in constructions(code):
        close_index = closing_bracket(code, open_index)
        probe = [value for label, value in arguments(code, open_index, close_index)
                 if label == "leftoverTmuxProbe"]
        if not probe:
            problems.append((line_of(anchor),
                             "%s names no leftoverTmuxProbe:, so it would get the "
                             "production probe. Pass `.absent` when the suite does not "
                             "exercise the probe, or the probe it does." % description))
        elif may_be_nil(probe[0]):
            problems.append((line_of(anchor),
                             "%s passes leftoverTmuxProbe: %s, which can be nil, and nil "
                             "is the production probe. Pass `.absent` or the suite's own "
                             "probe." % (description, " ".join(probe[0].split()))))
    for m in OPTIONAL_PROBE.finditer(code):
        problems.append((line_of(m.start()),
                         "declares a LeftoverTmuxServerProbe that can be nil, and nil is "
                         "the production probe: passed on as leftoverTmuxProbe:, it hands "
                         "that probe to every caller that leaves it out. Declare a "
                         "non-optional LeftoverTmuxServerProbe that defaults to `.absent`."))
    if relative_path not in PRODUCTION_ALLOWED:
        for index in production_uses(code):
            problems.append((line_of(index),
                             "uses LeftoverTmuxServerProbe.production(), which reads this "
                             "machine's sockets and process table. Pass `.absent` or a "
                             "recording probe; only the files in PRODUCTION_ALLOWED may use "
                             "it. Another type's `.production()` with none of the probe's "
                             "own labels reads the same: write `Type.production()`."))
    problems.sort(key=lambda problem: problem[0])
    return problems


def check_tree(repo_root):
    tests = os.path.join(repo_root, "Tests")
    if not os.path.isdir(tests):
        raise Unreadable("no Tests directory under %s" % repo_root)
    problems = []
    for directory, subdirectories, files in os.walk(tests):
        subdirectories.sort()
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, repo_root).replace(os.sep, "/")
            try:
                with open(path, encoding="utf-8") as handle:
                    text = handle.read()
            except (OSError, UnicodeDecodeError) as error:
                raise Unreadable("%s: %s" % (relative, error))
            try:
                for line, message in check_text(relative, text):
                    problems.append("%s:%d: %s" % (relative, line, message))
            except Unreadable as error:
                raise Unreadable("%s: %s" % (relative, error))
    return problems


SELF_TEST_CASES = [
    # (name, path, source, expected problem lines)
    ("a construction that names a probe passes",
     "Tests/A.swift",
     "let l = WorktreeLifecycle(db: db, hooks: h, leftoverTmuxProbe: .absent)\n", []),
    ("a construction that names none fails",
     "Tests/A.swift",
     "let l = WorktreeLifecycle(\n    db: db, hooks: h)\n", [1]),
    ("a coordinator that names none fails",
     "Tests/A.swift",
     "\nlet c = HibernationCoordinator(db: db, actuationLog: log)\n", [2]),
    ("nil is the production probe",
     "Tests/A.swift",
     "let l = WorktreeLifecycle(db: db, leftoverTmuxProbe: nil)\n", [1]),
    ("a label inside a nested call does not count",
     "Tests/A.swift",
     "let l = WorktreeLifecycle(db: f(leftoverTmuxProbe: p), hooks: h)\n", [1]),
    ("a probe before clock counts",
     "Tests/A.swift",
     "let l = WorktreeLifecycle(\n    db: db,\n    leftoverTmuxProbe: probe.probe,\n"
     "    clock: clock)\n", []),
    ("a closure argument with commas and parens is one argument",
     "Tests/A.swift",
     "let c = HibernationCoordinator(db: db, codexHomeEnsurer: { f(a, b) },\n"
     "    leftoverTmuxProbe: LeftoverTmuxServerProbe { _ in .running })\n", []),
    ("a construction in a comment or a string is not one",
     "Tests/A.swift",
     "// WorktreeLifecycle(db: db)\n/* HibernationCoordinator(db: db) */\n"
     "let s = \"WorktreeLifecycle(db: db)\"\nlet t = \"\"\"\nWorktreeLifecycle(\n\"\"\"\n", []),
    ("a one-line raw string that starts with quotes is not multi-line",
     "Tests/A.swift",
     "let q = #\"\"\"\"#\nlet l = WorktreeLifecycle(db: db)\n", [2]),
    ("an interpolation is code",
     "Tests/A.swift",
     "let s = \"\\(WorktreeLifecycle(db: db, x: \")\"))\"\n", [1]),
    ("a type name that only starts the same is not a construction",
     "Tests/A.swift",
     "let a = WorktreeLifecycleError(x)\nlet b = x.WorktreeLifecycle(y)\n", []),
    ("production() outside the allowed files fails",
     "Tests/A.swift",
     "let p = LeftoverTmuxServerProbe.production()\n"
     "let l = WorktreeLifecycle(db: db, leftoverTmuxProbe: .production())\n", [1, 2]),
    ("production() in an allowed file passes",
     "Tests/TBDDaemonLiveTests/WorktreeLifecycleLiveTests.swift",
     "let l = WorktreeLifecycle(db: db, leftoverTmuxProbe: .production())\n", []),
    ("another type's production() is not the probe's",
     "Tests/A.swift",
     "let m = Migrator(operations: .production(lifecycle: l))\n", []),

    # Constructions spelled other ways.
    ("an explicit .init that names none fails",
     "Tests/A.swift",
     "lifecycle = WorktreeLifecycle.init(db: db)\n"
     "let c = HibernationCoordinator\n    .init(db: db, leftoverTmuxProbe: .absent)\n", [1]),
    ("a module-qualified construction counts",
     "Tests/A.swift",
     "let l = TBDDaemonLib.WorktreeLifecycle(db: db)\n"
     "let c = TBDDaemon.HibernationCoordinator(db: db)\n"
     "let d = TBDDaemonLib.WorktreeLifecycle(db: db, leftoverTmuxProbe: .absent)\n", [1, 2]),
    ("a qualifier that is not one of the modules is a member call",
     "Tests/A.swift",
     "let a = Other.WorktreeLifecycle(db: db)\nlet b = x.TBDDaemon.WorktreeLifecycle(db: db)\n",
     []),
    ("a .init( typed beside it counts",
     "Tests/A.swift",
     "let l: WorktreeLifecycle = .init(db: db)\n"
     "var c: HibernationCoordinator! = .init(db: db)\n"
     "let d: TBDDaemonLib.WorktreeLifecycle = .init(db: db, leftoverTmuxProbe: .absent)\n"
     "func f(l: WorktreeLifecycle = .init(db: db)) {}\n", [1, 2, 4]),
    ("a function's first-statement .init( counts",
     "Tests/A.swift",
     "func make() -> WorktreeLifecycle { .init(db: db) }\n"
     "func make2() async throws -> HibernationCoordinator {\n    return .init(\n        db: db)\n}\n",
     [1, 3]),
    ("a return .init( in an if block of the body counts",
     "Tests/A.swift",
     "func make() -> HibernationCoordinator? {\n    let x = 1\n    if x > 0 {\n"
     "        return .init(db: db)\n    } else {\n        return try .init(db: db)\n    }\n"
     "    return .init(db: db, leftoverTmuxProbe: .absent)\n}\n", [4, 6]),
    ("a closure or computed property returning the type counts",
     "Tests/A.swift",
     "let make: () -> WorktreeLifecycle = { .init(db: db) }\n"
     "let l = f { () -> WorktreeLifecycle in .init(db: db) }\n"
     "var lifecycle: WorktreeLifecycle {\n    .init(db: db)\n}\n"
     "lazy var coordinator: HibernationCoordinator = { .init(db: db) }()\n", [1, 2, 4, 6]),
    ("a delegating init in an extension counts",
     "Tests/A.swift",
     "extension WorktreeLifecycle {\n    init(test db: TBDDatabase) {\n"
     "        self.init(db: db)\n    }\n"
     "    static func make() -> Self { Self(db: db, leftoverTmuxProbe: .absent) }\n}\n", [3]),
    ("another type's .init( is not a construction",
     "Tests/A.swift",
     "let x: Foo = .init(db: db)\nfunc f() -> Foo { .init(a: 1) }\n"
     "func g() -> WorktreeLifecycle.Options { .init() }\n"
     "func h() -> WorktreeLifecycleConfig { return .init() }\n"
     "extension WorktreeLifecycle.Options { init(x: Int) { self.init() } }\n"
     "extension Foo { init(x: Int) { self.init() } }\n", []),
    ("a .init( inside a closure in such a body belongs to the closure",
     "Tests/A.swift",
     "func f() -> WorktreeLifecycle {\n    let names = xs.map { return .init(name: $0) }\n"
     "    if let y = ys.first(where: { _ in return .init() }) { use(y) }\n"
     "    return WorktreeLifecycle(db: db, leftoverTmuxProbe: .absent)\n}\n", []),

    # Values and declarations that can be nil.
    ("every spelling of none is the production probe",
     "Tests/A.swift",
     "let a = WorktreeLifecycle(db: db, leftoverTmuxProbe: .none)\n"
     "let b = WorktreeLifecycle(db: db, leftoverTmuxProbe: Optional.none)\n"
     "let c = WorktreeLifecycle(db: db, leftoverTmuxProbe: Optional<LeftoverTmuxServerProbe>.none)\n"
     "let d = WorktreeLifecycle(db: db, leftoverTmuxProbe: (nil))\n", [1, 2, 3, 4]),
    ("a value that can fall back to nil fails",
     "Tests/A.swift",
     "let a = WorktreeLifecycle(db: db, leftoverTmuxProbe: probe ?? nil)\n"
     "let b = WorktreeLifecycle(db: db, leftoverTmuxProbe: flag ? .absent : .none)\n", [1, 2]),
    ("a nil inside the probe's own closure is not the probe",
     "Tests/A.swift",
     "let a = WorktreeLifecycle(db: db, leftoverTmuxProbe: LeftoverTmuxServerProbe { _ in\n"
     "    x == nil ? .absent : .running })\n"
     "let b = WorktreeLifecycle(db: db, leftoverTmuxProbe: make(state: .none))\n", []),
    ("an optional probe a helper passes on fails at its declaration",
     "Tests/A.swift",
     "func make(probe: LeftoverTmuxServerProbe? = nil) -> WorktreeLifecycle {\n"
     "    WorktreeLifecycle(db: db, leftoverTmuxProbe: probe)\n}\n"
     "var p: Optional<LeftoverTmuxServerProbe>\nvar q: TBDDaemonLib.LeftoverTmuxServerProbe!\n"
     "func r() -> LeftoverTmuxServerProbe? { nil }\n", [1, 4, 5, 6]),
    ("a non-optional probe declaration passes",
     "Tests/A.swift",
     "func make(probe: LeftoverTmuxServerProbe = .absent) -> WorktreeLifecycle {\n"
     "    WorktreeLifecycle(db: db, leftoverTmuxProbe: probe)\n}\n"
     "let ok = p != LeftoverTmuxServerProbe.absent\n"
     "let s: RecordingLeftoverTmuxServerProbe? = nil\n", []),

    # Uses of production().
    ("production() passed through a helper fails",
     "Tests/A.swift",
     "let r = makeRouter(probe: .production())\n"
     "let h = TestHarness(tmuxProbe: .production(uid: 0))\n"
     "let p: LeftoverTmuxServerProbe = .production()\n"
     "lifecycle.leftoverTmuxProbe = .production(environment: [:], fallbackRoot: root)\n"
     "setLeftoverTmuxProbe(.production(tmuxProcesses: { _ in nil }))\n"
     "let t = TestHarness(tmuxProbe: .production { _ in [] })\n"
     "func p() -> LeftoverTmuxServerProbe {\n    return .production()\n}\n", [1, 2, 3, 4, 5, 6, 8]),
    ("production named as a function fails",
     "Tests/A.swift",
     "let f = LeftoverTmuxServerProbe.production\n"
     "let g = TBDDaemonLib.LeftoverTmuxServerProbe.production(uid: 0)\n", [1, 2]),
    ("another production() is not the probe's",
     "Tests/A.swift",
     "let o = Migrator(operations: .production(hibernation: h, holderRegistry: r, lifecycle: l))\n"
     "let r = RuntimeIntegrationRefresher.production()\n"
     "let b = builder.production(uid: 0)\nlet c = builder\n    .production()\n"
     "let d = x?.production()\nlet e = Thing(x: .production(x))\n", []),

    # Regex literals and division.
    ("a regex literal holding a quote is skipped",
     "Tests/A.swift",
     "let r = /\"(\\w+)\"/\nlet q = /\\w+\"/\nlet l = WorktreeLifecycle(db: db)\n", [3]),
    ("an extended regex literal holding a quote is skipped",
     "Tests/A.swift",
     "let r = #/\"/#\nlet s = try Regex(#\"\"\"#)\nlet t = ##/a/#\"/##\n"
     "let l = WorktreeLifecycle(db: db)\n", [4]),
    ("a multi-line extended regex literal is skipped",
     "Tests/A.swift",
     "let r = #/\n  \"a (\\w+)\n  WorktreeLifecycle(\n/#\nlet l = WorktreeLifecycle(db: db)\n", [5]),
    ("a regex literal after return is skipped",
     "Tests/A.swift",
     "func f() -> Regex<Substring> {\n    return /x\"/\n}\nlet l = WorktreeLifecycle(db: db)\n",
     [4]),
    ("a construction inside a regex literal is not one",
     "Tests/A.swift",
     "let m = s.firstMatch(of: /WorktreeLifecycle(db)/)\nlet l = WorktreeLifecycle(db: db)\n",
     [2]),
    ("division stays code",
     "Tests/A.swift",
     "let x = a/b; let l = WorktreeLifecycle(db: c/d)\n"
     "let y = a / b / c\nlet m = WorktreeLifecycle(db: d)\n"
     "let h = (w)/2 + arr[0]/2\nlet n = WorktreeLifecycle(db: x/2)\n"
     "let k = \"ab\".count/2 + q/3\n"
     "let j = x! / 2; let o = WorktreeLifecycle(db: y/2)\n", [1, 3, 5, 7]),
]

SELF_TEST_UNREADABLE = [
    ("a string that never closes", "let s = \"open\nWorktreeLifecycle(db: db)\n"),
    ("a construction that never closes", "let l = WorktreeLifecycle(db: db\n"),
    ("a block comment that never closes", "/* WorktreeLifecycle(\n"),
    ("an extended regex literal that never closes", "let r = #/\"a\"\nlet l = 1\n"),
    ("a typed body that never closes", "func make() -> WorktreeLifecycle {\n    .init(\n"),
]


def self_test():
    failures = []
    for name, path, source, expected in SELF_TEST_CASES:
        try:
            got = [line for line, _ in check_text(path, source)]
        except Unreadable as error:
            failures.append("%s: unreadable (%s)" % (name, error))
            continue
        if got != expected:
            failures.append("%s: expected problems on lines %s, got %s" % (name, expected, got))
    for name, source in SELF_TEST_UNREADABLE:
        try:
            check_text("Tests/A.swift", source)
            failures.append("%s: read without complaint" % name)
        except Unreadable:
            pass
    for failure in failures:
        print("FAIL " + failure, file=sys.stderr)
    if failures:
        print("%d self-test failure(s)" % len(failures), file=sys.stderr)
        return 1
    print("lint-test-leftover-tmux-probe self-test: OK")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    parser.add_argument("--self-test", action="store_true", help="Run the fixture self-test.")
    options = parser.parse_args()
    if options.self_test:
        return self_test()
    try:
        problems = check_tree(options.repo_root)
    except Unreadable as error:
        print("lint-test-leftover-tmux-probe: cannot read the tree: %s" % error, file=sys.stderr)
        return 2
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        print("%d place(s) under Tests/ can reach the production leftover-tmux probe; "
              "see scripts/lint-test-leftover-tmux-probe.py" % len(problems), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
