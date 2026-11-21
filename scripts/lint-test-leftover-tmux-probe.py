#!/usr/bin/env python3
"""Hold every test construction of a WorktreeLifecycle or a
HibernationCoordinator to naming its leftover-tmux probe.

Both types fall back to `LeftoverTmuxServerProbe.production()` when they are
built without a `leftoverTmuxProbe:` argument, which is what the daemon wants.
A test that got it would read the machine's process table, where a tmux
process whose argv cannot be read counts as a running server, so the suite
could refuse a revive or a wake on whatever tmux the machine happened to run.
The compiler cannot tell a test from the daemon, so this check does it without
a build:

- Every `WorktreeLifecycle(` and `HibernationCoordinator(` under `Tests/`
  passes `leftoverTmuxProbe:`, and not `nil`. A suite that does not exercise
  the probe passes `.absent` (Tests/DaemonTestSupport); one that does passes
  its own. A router needs nothing: it hands its coordinator its lifecycle's.
- `production()` is called only in the files in `PRODUCTION_ALLOWED`: the
  probe's own suite, whose calls inject the environment and the process
  lister, and the tier-3 test that runs it against a real tmux server.

It reads code only: comments and string literals are skipped, and a string's
interpolation is read as code. It fails closed: a literal, comment or bracket
that never closes, or a file that is not UTF-8, stops it with exit 2.

The probe, and with it this check, is a transition measure: see
`LeftoverTmuxServerProbe` for its replacement date.

Exit codes: 0 every construction names a probe and no other file calls
`production()`; 1 one does not, or one does; 2 the tree cannot be read.

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

CONSTRUCTION = re.compile(r"(?<![\w.])(WorktreeLifecycle|HibernationCoordinator)\s*\(")
PRODUCTION_CALL = re.compile(
    r"LeftoverTmuxServerProbe\s*\.\s*production\s*\("
    r"|leftoverTmuxProbe\s*[:=]\s*\.production\s*\("
    r"|setLeftoverTmuxProbe\s*\(\s*\.production\s*\("
)
STRING_OPEN = re.compile(r'(#*)("""|")')


class Unreadable(Exception):
    pass


def code_only(text):
    """`text` with comment and string-literal characters blanked to spaces,
    newlines kept, so offsets and line numbers still line up. A string's
    interpolation stays code."""
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
            blank(i, i + len(close))
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


def closing_paren(code, open_index):
    depth = 0
    for k in range(open_index, len(code)):
        ch = code[k]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                if ch != ")":
                    raise Unreadable("a bracket closes the wrong kind of bracket")
                return k
    raise Unreadable("a parenthesis never closes")


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


def check_text(relative_path, text):
    """Problems in one file, as (line, message)."""
    code = code_only(text)
    problems = []
    for m in CONSTRUCTION.finditer(code):
        open_index = m.end() - 1
        close_index = closing_paren(code, open_index)
        line = code.count("\n", 0, m.start()) + 1
        probe = [value for label, value in arguments(code, open_index, close_index)
                 if label == "leftoverTmuxProbe"]
        if not probe:
            problems.append((line, "%s( names no leftoverTmuxProbe:, so it would get the "
                                   "production probe. Pass `.absent` when the suite does not "
                                   "exercise the probe, or the probe it does." % m.group(1)))
        elif probe[0] == "nil":
            problems.append((line, "%s( passes leftoverTmuxProbe: nil, which is the "
                                   "production probe. Pass `.absent` or the suite's own "
                                   "probe." % m.group(1)))
    if relative_path not in PRODUCTION_ALLOWED:
        for m in PRODUCTION_CALL.finditer(code):
            line = code.count("\n", 0, m.start()) + 1
            problems.append((line, "calls LeftoverTmuxServerProbe.production(), which reads "
                                   "this machine's sockets and process table. Pass `.absent` "
                                   "or a recording probe; only the files in "
                                   "PRODUCTION_ALLOWED may call it."))
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
]

SELF_TEST_UNREADABLE = [
    ("a string that never closes", "let s = \"open\nWorktreeLifecycle(db: db)\n"),
    ("a construction that never closes", "let l = WorktreeLifecycle(db: db\n"),
    ("a block comment that never closes", "/* WorktreeLifecycle(\n"),
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
        print("%d test construction(s) would reach the production leftover-tmux probe; "
              "see scripts/lint-test-leftover-tmux-probe.py" % len(problems), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
