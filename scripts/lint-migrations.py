#!/usr/bin/env python3
"""Lint the timestamp-identified SQL migrations under Database/Migrations/.

Runs in the build-free `lint` CI job and the pre-push hook. It needs no
SwiftPM, no compiler and no database on disk: the whole pass is a directory
listing, a few regexes, a `git diff`, and one in-memory SQLite replay.

Six checks, every one whitelist-shaped — each asserts what is *permitted*
rather than enumerating what is banned, so a form nobody anticipated fails
closed instead of sailing through:

  filename-shape         `^\\d{14}_[a-z0-9_]+\\.sql$`, and nothing else in the
                         directory except `.gitkeep`.
  identifier-uniqueness  across the `.sql` stems, the inline Swift
                         escape-hatch list, and the frozen `v1`-`v84` names.
  statement-allowlist    every statement leads with one of the eleven
                         permitted forms.
  idempotent-ddl         `CREATE TABLE`/`CREATE INDEX` carry `IF NOT EXISTS`;
                         `DROP` carries `IF EXISTS`.
  history-frozen         every migration file that differs from the merge base
                         with origin/main is an ADDITION.
  chain-applies          the committed baseline schema plus every `.sql`
                         migration, in identifier order, replays into an empty
                         in-memory database without error.

Two pieces here are deliberate duplicates of
`Sources/TBDDaemon/Database/SQLMigrationLoader.swift`, and both are pinned
against it by a shared fixture rather than by good intentions:

  * The statement splitter. Both sides call SQLite's own `sqlite3_complete()`
    — the loader through `import SQLite3`, this script through Python's
    `sqlite3.complete_statement()`. They are two bindings to one
    implementation, so only the framing around it can drift. The framing is
    pinned by `Tests/TBDDaemonTests/Fixtures/MigrationSplitter/`, whose
    `<name>.sql` / `<name>.expected.json` pairs both splitters must reproduce
    exactly; `--emit-split` prints this side's answer in that format so the
    harness can diff it.
  * The ADD COLUMN skip, so the chain replay does not trip over a migration
    that is legitimately idempotent against the baseline. Same anchored,
    case-insensitive shape as the loader's `addColumnRegex`.

Usage:
  scripts/lint-migrations.py [--repo-root DIR] [--base REF]
  scripts/lint-migrations.py --emit-split FILE
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

# --------------------------------------------------------------------------
# Where things live, relative to the repository root
# --------------------------------------------------------------------------

MIGRATIONS_DIR = Path("Sources/TBDDaemon/Database/Migrations")
DATABASE_SWIFT = Path("Sources/TBDDaemon/Database/Database.swift")
LOADER_SWIFT = Path("Sources/TBDDaemon/Database/SQLMigrationLoader.swift")
BASELINE_SQL = Path("Tests/TBDDaemonTests/Fixtures/schema-baseline-v84.sql")

# The one non-`.sql` entry the directory may hold: what lets git track the
# directory while it is empty, and what `.copy` carries verbatim into the
# resource bundle (the loader filters to `.sql`, so it is inert there).
GITKEEP = ".gitkeep"

FILENAME_RE = re.compile(r"^\d{14}_[a-z0-9_]+\.sql$")

# --------------------------------------------------------------------------
# The splitter — see the module docstring for why this exists twice
# --------------------------------------------------------------------------


def strip_leading_noise(text: str) -> str:
    """Drop leading whitespace and complete `--` / `/* */` comments.

    Mirrors `SQLMigrationLoader.strippingLeadingNoise`, including its two
    give-up cases: an unterminated `--` line comment or `/* */` block comment
    leaves nothing behind. Only used to find where a statement actually
    begins. String literals are the hard part of SQL lexing and
    `sqlite3_complete()` owns them; leading comments are not.
    """
    rest = text
    while True:
        rest = rest.lstrip()
        if rest.startswith("--"):
            newline = rest.find("\n")
            if newline < 0:
                return ""
            rest = rest[newline + 1:]
        elif rest.startswith("/*"):
            close = rest.find("*/")
            if close < 0:
                return ""
            rest = rest[close + 2:]
        else:
            return rest


def split_statements(sql: str) -> list[str]:
    """Split a migration file into statements using SQLite's own lexer.

    A `;` ends a statement only when the text accumulated so far is a complete
    statement, so semicolons inside string literals, inside `--` and `/* */`
    comments, and inside a `CREATE TRIGGER ... BEGIN ... END;` body are not
    boundaries. Each statement is the raw source slice, stripped; comments
    preceding a statement stay attached to it.
    """
    statements: list[str] = []
    current = ""
    for character in sql:
        current += character
        if character != ";":
            continue
        if not sqlite3.complete_statement(current):
            continue
        trimmed = current.strip()
        if trimmed:
            statements.append(trimmed)
        current = ""
    # A file whose last statement has no trailing semicolon still has a
    # statement here; a whitespace-only OR COMMENT-ONLY trailer does not.
    if strip_leading_noise(current):
        statements.append(current.strip())
    return statements


# --------------------------------------------------------------------------
# The ADD COLUMN skip — mirrors SQLMigrationLoader.addColumnRegex
# --------------------------------------------------------------------------

IDENTIFIER = r'(?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*)'

ADD_COLUMN_RE = re.compile(
    r"^ALTER\s+TABLE\s+(" + IDENTIFIER + r")"
    r"\s+ADD\s+(?:COLUMN\s+)?(" + IDENTIFIER + r")(?:\s|$)",
    re.IGNORECASE,
)


def unquote(identifier: str) -> str:
    if len(identifier) >= 2 and identifier.startswith('"') and identifier.endswith('"'):
        return identifier[1:-1].replace('""', '"')
    return identifier


def add_column_target(statement: str) -> tuple[str, str] | None:
    """The `(table, column)` an ADD COLUMN statement targets, else None.

    Deliberately strict, exactly as the loader is: anything this does not
    match is replayed unmodified, so the skip can never silently swallow a
    statement it did not understand.
    """
    match = ADD_COLUMN_RE.match(strip_leading_noise(statement))
    if match is None:
        return None
    return unquote(match.group(1)), unquote(match.group(2))


def column_exists(connection: sqlite3.Connection, table: str, column: str) -> bool:
    quoted = '"' + table.replace('"', '""') + '"'
    rows = connection.execute(f"PRAGMA table_info({quoted})").fetchall()
    return column.lower() in {str(row[1]).lower() for row in rows}


# --------------------------------------------------------------------------
# The statement allowlist
# --------------------------------------------------------------------------

# Each entry is a permitted LEADING FORM. Widening this list is a deliberate
# edit with a reviewer, which is the point: every addition is a claim that the
# new form is idempotent and order-independent, because a developer who has
# already applied a later migration will run this one out of authoring order.
ALLOWED_FORMS: list[tuple[str, str]] = [
    ("CREATE TABLE", r"CREATE\s+TABLE\b"),
    ("CREATE [UNIQUE] INDEX", r"CREATE\s+(?:UNIQUE\s+)?INDEX\b"),
    ("ALTER TABLE ... ADD [COLUMN]", r"ALTER\s+TABLE\s+" + IDENTIFIER + r"\s+ADD\b"),
    ("ALTER TABLE ... RENAME", r"ALTER\s+TABLE\s+" + IDENTIFIER + r"\s+RENAME\b"),
    ("DROP TABLE", r"DROP\s+TABLE\b"),
    ("DROP INDEX", r"DROP\s+INDEX\b"),
    ("INSERT OR IGNORE", r"INSERT\s+OR\s+IGNORE\b"),
    ("INSERT OR REPLACE", r"INSERT\s+OR\s+REPLACE\b"),
    ("UPDATE", r"UPDATE\b"),
    ("DELETE FROM", r"DELETE\s+FROM\b"),
    ("PRAGMA", r"PRAGMA\b"),
]

ALLOWED_RES = [(name, re.compile(pattern, re.IGNORECASE | re.DOTALL)) for name, pattern in ALLOWED_FORMS]

# The idempotency rule, expressed as "a statement leading with X is permitted
# only in form Y". Kept separate from the allowlist above so the two guards
# fail independently: `CREATE VIEW` is an allowlist failure, `CREATE TABLE t`
# without `IF NOT EXISTS` is an idempotency failure, and disabling either one
# leaves the other still catching its own fixture.
IDEMPOTENT_RULES: list[tuple[str, str, str]] = [
    ("CREATE TABLE", r"CREATE\s+TABLE\b", r"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\b"),
    (
        "CREATE INDEX",
        r"CREATE\s+(?:UNIQUE\s+)?INDEX\b",
        r"CREATE\s+(?:UNIQUE\s+)?INDEX\s+IF\s+NOT\s+EXISTS\b",
    ),
    ("DROP TABLE", r"DROP\s+TABLE\b", r"DROP\s+TABLE\s+IF\s+EXISTS\b"),
    ("DROP INDEX", r"DROP\s+INDEX\b", r"DROP\s+INDEX\s+IF\s+EXISTS\b"),
]

IDEMPOTENT_RES = [
    (name, re.compile(lead, re.IGNORECASE | re.DOTALL), re.compile(required, re.IGNORECASE | re.DOTALL))
    for name, lead, required in IDEMPOTENT_RULES
]


# --------------------------------------------------------------------------
# Gathering the facts once, so the six checks share one read of the tree
# --------------------------------------------------------------------------


class Facts:
    def __init__(self, root: Path, base_ref: str) -> None:
        self.root = root
        self.base_ref = base_ref
        self.directory = root / MIGRATIONS_DIR
        self.entries: list[str] = []
        self.migrations: list[tuple[str, str]] = []  # (identifier, sql), identifier-sorted
        self.read_errors: list[str] = []

        if not self.directory.is_dir():
            self.read_errors.append(f"{MIGRATIONS_DIR} does not exist or is not a directory")
            return
        self.entries = sorted(entry.name for entry in self.directory.iterdir())
        for name in sorted(name for name in self.entries if name.endswith(".sql")):
            try:
                sql = (self.directory / name).read_text(encoding="utf-8")
            except OSError as error:
                self.read_errors.append(f"{MIGRATIONS_DIR/name}: unreadable ({error})")
                continue
            self.migrations.append((name[: -len(".sql")], sql))

    def read_source(self, relative: Path) -> str | None:
        try:
            return (self.root / relative).read_text(encoding="utf-8")
        except OSError:
            return None

    def git(self, *args: str) -> tuple[int, str]:
        result = subprocess.run(
            ["git", "-C", str(self.root), *args],
            capture_output=True,
            text=True,
            check=False,
        )
        return result.returncode, result.stdout


# --------------------------------------------------------------------------
# Check 1 — filename shape
# --------------------------------------------------------------------------


def check_filename_shape(facts: Facts) -> list[str]:
    problems = []
    for name in facts.entries:
        if name == GITKEEP or FILENAME_RE.match(name):
            continue
        problems.append(
            f"{MIGRATIONS_DIR/name}: not a migration filename. The directory holds only "
            f"`YYYYMMDDHHMMSS_lower_snake_description.sql` files and `{GITKEEP}`."
        )
    return problems


# --------------------------------------------------------------------------
# Check 2 — identifier uniqueness
# --------------------------------------------------------------------------

FROZEN_IDENTIFIER_RE = re.compile(r'registerMigration\(\s*"([^"]+)"')
INLINE_IDENTIFIER_RE = re.compile(r'RegisteredMigration\(\s*identifier:\s*"([^"]+)"')
INLINE_LIST_ANCHOR = "inlineTimestampMigrations"


def extract_inline_list(source: str) -> tuple[list[str], str | None]:
    """Identifiers in `SQLMigrationLoader.inlineTimestampMigrations`.

    Scoped to that array's balanced brackets rather than the whole file, so a
    `RegisteredMigration(identifier:)` built anywhere else in the loader is not
    mistaken for an escape-hatch entry.
    """
    anchor = source.find(INLINE_LIST_ANCHOR)
    if anchor < 0:
        return [], f"{LOADER_SWIFT}: could not find `{INLINE_LIST_ANCHOR}`"
    open_bracket = source.find("[", source.find("=", anchor))
    if open_bracket < 0:
        return [], f"{LOADER_SWIFT}: `{INLINE_LIST_ANCHOR}` has no array literal"
    depth = 0
    for index in range(open_bracket, len(source)):
        if source[index] == "[":
            depth += 1
        elif source[index] == "]":
            depth -= 1
            if depth == 0:
                return INLINE_IDENTIFIER_RE.findall(source[open_bracket:index]), None
    return [], f"{LOADER_SWIFT}: `{INLINE_LIST_ANCHOR}`'s array literal is unterminated"


def check_identifier_uniqueness(facts: Facts) -> list[str]:
    problems = []
    sources: list[tuple[str, str]] = []  # (identifier, where)

    for identifier, _ in facts.migrations:
        sources.append((identifier, str(MIGRATIONS_DIR / f"{identifier}.sql")))

    database_swift = facts.read_source(DATABASE_SWIFT)
    if database_swift is None:
        problems.append(f"{DATABASE_SWIFT}: unreadable, cannot check identifiers against the frozen block")
    else:
        for identifier in FROZEN_IDENTIFIER_RE.findall(database_swift):
            sources.append((identifier, f"{DATABASE_SWIFT} (registerMigration)"))

    loader_swift = facts.read_source(LOADER_SWIFT)
    if loader_swift is None:
        problems.append(f"{LOADER_SWIFT}: unreadable, cannot check identifiers against the Swift escape hatch")
    else:
        inline, error = extract_inline_list(loader_swift)
        if error:
            problems.append(error)
        for identifier in inline:
            sources.append((identifier, f"{LOADER_SWIFT} ({INLINE_LIST_ANCHOR})"))

    seen: dict[str, list[str]] = {}
    for identifier, where in sources:
        seen.setdefault(identifier, []).append(where)
    for identifier, wheres in sorted(seen.items()):
        if len(wheres) > 1:
            joined = ", ".join(wheres)
            problems.append(
                f"migration identifier `{identifier}` is claimed more than once: {joined}. "
                "GRDB keys applied migrations by identifier string, so two of these can never both run."
            )
    return problems


# --------------------------------------------------------------------------
# Checks 3 and 4 — statement allowlist and idempotent DDL
# --------------------------------------------------------------------------


def check_statement_allowlist(facts: Facts) -> list[str]:
    problems = []
    for identifier, sql in facts.migrations:
        for statement in split_statements(sql):
            body = strip_leading_noise(statement)
            if any(pattern.match(body) for _, pattern in ALLOWED_RES):
                continue
            allowed = ", ".join(name for name, _ in ALLOWED_FORMS)
            problems.append(
                f"{MIGRATIONS_DIR/identifier}.sql: statement is not one of the permitted forms "
                f"({allowed}). Rewrite it, or take the Swift escape hatch in "
                f"{LOADER_SWIFT}. Statement: {summarize(body)}"
            )
    return problems


def check_idempotent_ddl(facts: Facts) -> list[str]:
    problems = []
    for identifier, sql in facts.migrations:
        for statement in split_statements(sql):
            body = strip_leading_noise(statement)
            for name, lead, required in IDEMPOTENT_RES:
                if lead.match(body) and not required.match(body):
                    clause = "IF NOT EXISTS" if name.startswith("CREATE") else "IF EXISTS"
                    problems.append(
                        f"{MIGRATIONS_DIR/identifier}.sql: `{name}` must carry `{clause}`. "
                        "Migrations run in whatever order each machine reaches them, so every "
                        f"statement has to be re-runnable. Statement: {summarize(body)}"
                    )
    return problems


def summarize(statement: str) -> str:
    collapsed = " ".join(statement.split())
    return collapsed if len(collapsed) <= 120 else collapsed[:117] + "..."


# --------------------------------------------------------------------------
# Check 5 — history is frozen
# --------------------------------------------------------------------------


def check_history_frozen(facts: Facts) -> list[str]:
    code, base = facts.git("merge-base", facts.base_ref, "HEAD")
    if code != 0 or not base.strip():
        return [
            f"cannot resolve `git merge-base {facts.base_ref} HEAD`, so the history-is-frozen check "
            f"cannot run. Fetch the base branch (`git fetch origin main`) and try again."
        ]
    # THE THREE-DOT MERGE-BASE FORM IS LOAD-BEARING. Diffing `origin/main HEAD`
    # directly reports every migration that landed on main AFTER this branch was
    # cut as a deletion, which would redden every branch older than the newest
    # migration. The merge base is the only tree this branch is answerable for.
    code, output = facts.git(
        "diff", "--name-status", base.strip(), "HEAD", "--", str(MIGRATIONS_DIR)
    )
    if code != 0:
        return [f"`git diff --name-status {base.strip()} HEAD -- {MIGRATIONS_DIR}` failed"]
    problems = []
    for line in output.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        status, paths = fields[0], fields[1:]
        if not any(path.endswith(".sql") for path in paths):
            continue
        if status == "A":
            continue
        problems.append(
            f"{' -> '.join(paths)}: migration history is frozen — every migration file changed "
            f"since the merge base must be an addition, and git reports `{status}`. A migration "
            "that has already been applied on someone's machine is unapplied by its new name "
            "while its column already exists; add a new migration instead."
        )
    return problems


# --------------------------------------------------------------------------
# Check 6 — the chain applies
# --------------------------------------------------------------------------


def check_chain_applies(facts: Facts) -> list[str]:
    baseline = facts.read_source(BASELINE_SQL)
    if baseline is None:
        return [f"{BASELINE_SQL}: unreadable, cannot replay the migration chain"]
    # isolation_level=None: no implicit transactions, so each statement lands
    # exactly as the loader's `db.execute(sql:)` would.
    connection = sqlite3.connect(":memory:", isolation_level=None)
    try:
        connection.executescript(baseline)
    except sqlite3.Error as error:
        return [f"{BASELINE_SQL}: the frozen baseline itself failed to replay ({error})"]
    problems = []
    for identifier, sql in facts.migrations:
        for statement in split_statements(sql):
            target = add_column_target(statement)
            if target and column_exists(connection, target[0], target[1]):
                continue
            try:
                connection.execute(statement)
            except sqlite3.Error as error:
                problems.append(
                    f"{MIGRATIONS_DIR/identifier}.sql: failed to apply against the schema the "
                    f"preceding migrations produce ({error}). Statement: {summarize(statement)}"
                )
    connection.close()
    return problems


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------

# One line per guard, so a mutation harness can disable exactly one.
CHECKS = [
    ("filename-shape", check_filename_shape),
    ("identifier-uniqueness", check_identifier_uniqueness),
    ("statement-allowlist", check_statement_allowlist),
    ("idempotent-ddl", check_idempotent_ddl),
    ("history-frozen", check_history_frozen),
    ("chain-applies", check_chain_applies),
]


def emit_split(path: Path) -> int:
    """Print this side's statement boundaries in the parity fixture's format."""
    print(json.dumps(split_statements(path.read_text(encoding="utf-8")), indent=2))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--base", default="origin/main", help="branch the history-frozen check diffs against")
    parser.add_argument("--emit-split", type=Path, help="print the statement split of one SQL file as JSON and exit")
    args = parser.parse_args(argv)

    if args.emit_split is not None:
        return emit_split(args.emit_split)

    facts = Facts(args.repo_root.resolve(), args.base)
    problems = list(facts.read_errors)
    if not problems:
        for _, check in CHECKS:
            problems.extend(check(facts))

    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        print(
            f"\n{len(problems)} migration lint problem(s). "
            "See docs/specs/2026-08-19-migration-identifier-scheme-design.md.",
            file=sys.stderr,
        )
        return 1
    print(f"migration lint OK — {len(facts.migrations)} .sql migration(s), {len(CHECKS)} checks")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
