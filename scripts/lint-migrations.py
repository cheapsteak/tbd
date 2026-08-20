#!/usr/bin/env python3
"""Lint the timestamp-identified SQL migrations under Database/Migrations/.

Runs in the build-free `lint` CI job and the pre-push hook. It needs no
SwiftPM, no compiler and no database on disk: the whole pass is a directory
listing, a few regexes, a `git diff`, and one in-memory SQLite replay.

Seven checks, every one whitelist-shaped — each asserts what is *permitted*
rather than enumerating what is banned, so a form nobody anticipated fails
closed instead of sailing through:

  file-encoding          the bytes are LF-terminated UTF-8 with no BOM and no
                         NUL, so the Swift loader and this script read the same
                         characters.
  filename-shape         `^\\d{14}_[a-z0-9_]+\\.sql$`, and nothing else in the
                         directory except `.gitkeep`.
  identifier-uniqueness  across the `.sql` stems, the inline Swift
                         escape-hatch list, and the frozen Swift block's names.
  statement-allowlist    every statement leads with one of the nine permitted
                         forms.
  idempotent-ddl         `CREATE TABLE`/`CREATE INDEX` carry `IF NOT EXISTS`;
                         `DROP` carries `IF EXISTS`.
  history-frozen         no migration file already on origin/main is edited or
                         deleted, checked both against the merge base and
                         blob-by-blob against origin/main itself.
  chain-applies          the committed baseline schema plus every `.sql`
                         migration, in identifier order, replays into an empty
                         in-memory database — inside a transaction, with
                         foreign keys enforced, exactly as GRDB runs them.

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
    case-insensitive shape as the loader's `addColumnRegex` — but here the two
    sides are two different regex ENGINES running one pattern, not two
    bindings to one implementation, so the pattern text itself is duplicated.
    `Tests/TBDDaemonTests/Fixtures/MigrationAddColumn/add-column-targets.json`
    pins what both must read out of each shape, and
    `--emit-add-column-targets` prints this side's answers for the harness to
    diff.

Usage:
  scripts/lint-migrations.py [--repo-root DIR] [--base REF]
  scripts/lint-migrations.py --emit-split FILE
  scripts/lint-migrations.py --emit-add-column-targets FILE
"""

from __future__ import annotations

import argparse
import codecs
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
BASELINE_SQL = Path("Tests/TBDDaemonTests/Fixtures/schema-baseline-frozen-block.sql")

# The one non-`.sql` entry the directory may hold: what lets git track the
# directory while it is empty, and what `.copy` carries verbatim into the
# resource bundle (the loader filters to `.sql`, so it is inert there).
GITKEEP = ".gitkeep"

FILENAME_RE = re.compile(r"^\d{14}_[a-z0-9_]+\.sql$")

# --------------------------------------------------------------------------
# Reading a migration file
# --------------------------------------------------------------------------

# NO NEWLINE TRANSLATION, DELIBERATELY. `Path.read_text()` opens in text mode
# with universal newlines, which rewrites `\r\n` and a lone `\r` to `\n`
# before anything here can see them — so a file the Swift loader reads
# verbatim through `String(contentsOf:)` would reach this script as different
# characters, and the two splitters would be compared on two different inputs.
# Reading bytes and decoding once keeps them honest, and lets `file_encoding_problem`
# below speak about what is actually on disk.


def read_migration_bytes(path: Path) -> bytes:
    return path.read_bytes()


def file_encoding_problem(display_path: Path, raw: bytes) -> str | None:
    """Why these bytes are not a migration file, or None if they are fine.

    Three of the four cases are ways for the loader and this script to read
    one file as two different things, which is the whole reason the check
    exists rather than letting each side cope in its own way:

      * A **BOM** is stripped by Swift's `String(contentsOf:)` and kept by
        Python's decoder, so the first statement would carry an invisible
        leading character here and not there.
      * A **CR** is where the two splitters have actually diverged: Swift
        iterates graphemes, and a `\r\n` pair is one Character that is not the
        `\n` a leading-comment scan looks for, so a statement introduced by a
        `--` comment can be dropped on one side and kept on the other. Both
        sides handle CRLF now; rejecting it outright is the defence in depth
        that keeps a loader regression from ever reaching a real migration.
      * A **NUL** is a hard stop for `sqlite3.complete_statement`, which
        raises `ValueError` rather than answering, and for SQLite's C API,
        which treats the byte as end of string.

    Rejecting all of them costs one pass over the bytes and means neither
    reader ever has to be the one that gets it right.
    """
    if raw.startswith(codecs.BOM_UTF8):
        return (
            f"{display_path}: starts with a UTF-8 byte-order mark. Swift's reader strips a BOM and "
            "Python's keeps it, so the two would disagree about the first statement. Save the file "
            "as UTF-8 with no BOM."
        )
    if b"\x00" in raw:
        # Bound outside the f-string: a backslash escape inside an f-string
        # expression is a syntax error before Python 3.12.
        offset = raw.index(b"\x00")
        return (
            f"{display_path}: contains a NUL byte (0x00) at offset {offset}. A migration "
            "file is UTF-8 SQL text; SQLite's C API reads a NUL as end of string and Python's "
            "`sqlite3.complete_statement` refuses to answer at all, so neither side can split it. "
            "The usual cause is a binary file saved under a `.sql` name."
        )
    if b"\r" in raw:
        line = raw[: raw.index(b"\r")].count(b"\n") + 1
        return (
            f"{display_path}: contains a carriage return (CR, 0x0D) on line {line}. Migration files "
            "must use LF line endings. CR is the one byte the Swift loader and this lint have "
            "historically split differently — a `\\r\\n` is a single Swift Character and not the "
            "`\\n` a leading-comment scan looks for — and a migration whose statements are enumerated "
            "differently at runtime than at lint time is the failure this rejects outright. Convert "
            "the file with `tr -d '\\r'`."
        )
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as error:
        return f"{display_path}: is not valid UTF-8 ({error}). A migration file is UTF-8 SQL text."
    return None


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

# What may follow the column identifier. The splitter keeps each statement's
# `;`, so an untyped `ADD COLUMN foo;` — legal SQLite, BLOB affinity —
# presents a `;` where a typed column presents a space. Comment openers are
# here for the same reason: a terminator set that only knew whitespace and end
# of input would push those shapes into the keyword-capturing backtrack that
# `KEYWORDS_NEVER_COLUMN_NAMES` closes off.
COLUMN_TERMINATOR = r"(?=\s|;|--|/\*|$)"

ADD_COLUMN_RE = re.compile(
    r"^ALTER\s+TABLE\s+(" + IDENTIFIER + r")"
    r"\s+ADD\s+(?:COLUMN\s+)?(" + IDENTIFIER + r")" + COLUMN_TERMINATOR,
    re.IGNORECASE,
)

# Words that are a keyword rather than a column name when captured **bare**.
# `COLUMN` is optional in the shape above, so on `ALTER TABLE t ADD CONSTRAINT
# …` — or on an untyped `ALTER TABLE t ADD column;` — the engine skips that
# group and captures the keyword itself. Declining those captures is what
# makes the skip able only to name the statement's real column or nothing.
# A quoted `"column"` is a genuine identifier and is compared before
# unquoting, so it is unaffected.
KEYWORDS_NEVER_COLUMN_NAMES = frozenset({"column", "constraint"})


def unquote(identifier: str) -> str:
    if len(identifier) >= 2 and identifier.startswith('"') and identifier.endswith('"'):
        return identifier[1:-1].replace('""', '"')
    return identifier


def add_column_target(statement: str) -> tuple[str, str] | None:
    """The `(table, column)` an ADD COLUMN statement targets, else None.

    Deliberately strict, exactly as the loader is: anything this does not
    match is replayed unmodified, so the skip can never silently swallow a
    statement it did not understand. It either names the statement's real
    column or declines — naming a *different* column would let the skip drop a
    statement that had not run yet.
    """
    match = ADD_COLUMN_RE.match(strip_leading_noise(statement))
    if match is None:
        return None
    raw_column = match.group(2)
    if raw_column.lower() in KEYWORDS_NEVER_COLUMN_NAMES:
        return None
    return unquote(match.group(1)), unquote(raw_column)


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
#
# TWO FORMS ARE ABSENT BECAUSE THEY FAIL EXACTLY THAT CLAIM, and both look
# harmless enough to be re-proposed:
#
#   ALTER TABLE ... RENAME  has no `IF EXISTS` spelling and no loader-side
#                           skip, so it can be neither replayed nor reordered.
#   PRAGMA foreign_keys     is a documented no-op inside a transaction, and
#                           GRDB runs every migration inside one — so it would
#                           appear to work in any standalone replay and
#                           silently do nothing in production.
#
# Both belong to the Swift escape hatch, where GRDB's `foreignKeyChecks:`
# parameter handles the table-rebuild case properly.
ALLOWED_FORMS: list[tuple[str, str]] = [
    ("CREATE TABLE", r"CREATE\s+TABLE\b"),
    ("CREATE [UNIQUE] INDEX", r"CREATE\s+(?:UNIQUE\s+)?INDEX\b"),
    ("ALTER TABLE ... ADD [COLUMN]", r"ALTER\s+TABLE\s+" + IDENTIFIER + r"\s+ADD\b"),
    ("DROP TABLE", r"DROP\s+TABLE\b"),
    ("DROP INDEX", r"DROP\s+INDEX\b"),
    ("INSERT OR IGNORE", r"INSERT\s+OR\s+IGNORE\b"),
    ("INSERT OR REPLACE", r"INSERT\s+OR\s+REPLACE\b"),
    ("UPDATE", r"UPDATE\b"),
    ("DELETE FROM", r"DELETE\s+FROM\b"),
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
        self.encoding_problems: list[str] = []

        if not self.directory.is_dir():
            self.read_errors.append(f"{MIGRATIONS_DIR} does not exist or is not a directory")
            return
        self.entries = sorted(entry.name for entry in self.directory.iterdir())
        for name in sorted(name for name in self.entries if name.endswith(".sql")):
            try:
                raw = read_migration_bytes(self.directory / name)
            except OSError as error:
                self.read_errors.append(f"{MIGRATIONS_DIR/name}: unreadable ({error})")
                continue
            # A file whose bytes are wrong is reported once and then withheld
            # from `migrations`, so no later check tries to split it. That is
            # what turns a NUL byte from an uncaught `ValueError` traceback
            # deep in the allowlist pass into one sentence naming the file.
            problem = file_encoding_problem(MIGRATIONS_DIR / name, raw)
            if problem is not None:
                self.encoding_problems.append(problem)
                continue
            self.migrations.append((name[: -len(".sql")], raw.decode("utf-8")))

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
# Check 1 — the bytes are readable the same way by both sides
# --------------------------------------------------------------------------


def check_file_encoding(facts: Facts) -> list[str]:
    """Report what `Facts` found while reading, and withheld from `migrations`.

    The detection happens at read time rather than here because it has to: a
    NUL byte makes `sqlite3.complete_statement` raise `ValueError`, so a file
    carrying one must never reach the splitter that the allowlist, idempotency
    and chain-apply checks all run.
    """
    return list(facts.encoding_problems)


# --------------------------------------------------------------------------
# Check 2 — filename shape
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
# Check 3 — identifier uniqueness
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
# Checks 4 and 5 — statement allowlist and idempotent DDL
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
# Check 6 — history is frozen
# --------------------------------------------------------------------------


def check_history_frozen(facts: Facts) -> list[str]:
    problems = merge_base_edits(facts)
    # TWO LEGS, COVERING DIFFERENT THINGS. Keep both.
    problems.extend(frozen_blob_edits(facts))
    return problems


def merge_base_edits(facts: Facts) -> list[str]:
    """Every migration changed since the merge base must be an ADDITION.

    This is the leg that sees deletions and renames — a file gone from HEAD
    has no blob to compare — and it is the only one that can speak about a
    file the base branch has never held.
    """
    code, base = facts.git("merge-base", facts.base_ref, "HEAD")
    if code != 0 or not base.strip():
        return [
            f"cannot resolve `git merge-base {facts.base_ref} HEAD`, so the history-is-frozen check "
            f"cannot run. Fetch the base branch (`git fetch origin main`) and try again."
        ]
    # RENAME DETECTION STAYS ON. A rename needs a source in the base tree, so an
    # unshipped migration renamed on the branch has none and reads as `A`; a
    # shipped one pairs into one `R` line carrying both paths, which is the
    # correct signal and the only form that can name where the file went.
    #
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


def frozen_blob_edits(facts: Facts) -> list[str]:
    """Every migration ALSO on the base branch must be byte-identical there.

    THE MERGE-BASE LEG ABOVE FAILS OPEN ON A STALE BASE REF, and the layer
    that suffers is the pre-push hook: CI fetches immediately before it lints,
    a developer's `origin/main` is whatever they last fetched. Where the base
    branch already carries a migration but the merge base predates it — the
    branch picked the file up by cherry-pick or rebase rather than by merging
    the fetched ref — editing that file in place reads as an ADDITION relative
    to the merge base and sails through.

    Comparing blob hashes is immune to that, because it asks the base branch
    about the file directly and never consults the merge base at all. It stays
    silent about a path the base branch holds and HEAD does not: on a branch
    that simply has not caught up, that is an ordinary main-side addition
    rather than a deletion, and the merge-base leg is what tells the two apart.
    """
    base = sql_blobs(facts, facts.base_ref)
    if base is None:
        # An unresolvable base ref is already reported by the merge-base leg.
        return []
    head = sql_blobs(facts, "HEAD") or {}
    problems = []
    for path, base_blob in sorted(base.items()):
        head_blob = head.get(path)
        if head_blob is None or head_blob == base_blob:
            continue
        problems.append(
            f"{path}: migration history is frozen — this file is already on `{facts.base_ref}` "
            f"and HEAD changes its contents ({base_blob[:12]} -> {head_blob[:12]}). It has already "
            "run on somebody's machine under this identifier, so GRDB will never re-run it; the "
            "edit reaches new installs only. Add a new migration instead."
        )
    return problems


def sql_blobs(facts: Facts, ref: str) -> dict[str, str] | None:
    """`{path: blob hash}` for the `.sql` files that `ref` holds, or None.

    One `ls-tree` per ref rather than a `rev-parse` per file: the listing
    already carries the hashes, and a directory that only ever grows should not
    cost two subprocesses per migration forever.
    """
    code, listing = facts.git("ls-tree", "-r", "-z", ref, "--", str(MIGRATIONS_DIR))
    if code != 0:
        return None
    blobs = {}
    for entry in listing.split("\0"):
        if not entry:
            continue
        # `<mode> <type> <object>\t<path>`
        meta, _, path = entry.partition("\t")
        fields = meta.split()
        if len(fields) < 3 or fields[1] != "blob" or not path.endswith(".sql"):
            continue
        blobs[path] = fields[2]
    return blobs


# --------------------------------------------------------------------------
# Check 7 — the chain applies
# --------------------------------------------------------------------------


def check_chain_applies(facts: Facts) -> list[str]:
    baseline = facts.read_source(BASELINE_SQL)
    if baseline is None:
        return [f"{BASELINE_SQL}: unreadable, cannot replay the migration chain"]
    # REPLAY IN PRODUCTION'S ENVIRONMENT, NOT PYTHON'S DEFAULT ONE. Two
    # settings, and each of them decides whether a real class of defect is
    # visible here or waits until a user's daemon runs the migration:
    #
    #   foreign_keys=ON       Python's sqlite3 leaves foreign keys OFF; GRDB
    #                         sets `foreignKeysEnabled = true`. Without this an
    #                         FK-violating migration replays green and throws
    #                         at runtime.
    #   one transaction per   GRDB wraps each migration in
    #   migration             `db.inTransaction(.immediate)`. Deferred
    #                         constraints are checked at COMMIT, so autocommit
    #                         both misses violations that only surface there
    #                         and rejects statement orders that are legal
    #                         inside a transaction.
    #
    # `isolation_level=None` turns off Python's own implicit transaction
    # management so the BEGIN/COMMIT below are the only ones in play. The
    # PRAGMA has to precede them: inside a transaction it is a documented
    # no-op, which is also why the statement allowlist refuses it.
    connection = sqlite3.connect(":memory:", isolation_level=None)
    connection.execute("PRAGMA foreign_keys=ON")
    try:
        connection.executescript(baseline)
    except sqlite3.Error as error:
        return [f"{BASELINE_SQL}: the frozen baseline itself failed to replay ({error})"]
    problems = []
    for identifier, sql in facts.migrations:
        problems.extend(replay_one(connection, identifier, sql))
    connection.close()
    return problems


def replay_one(connection: sqlite3.Connection, identifier: str, sql: str) -> list[str]:
    """Apply one migration in its own transaction, as GRDB does.

    A failure rolls that migration back and reporting continues with the next
    one, so a single bad statement yields one diagnostic rather than a cascade
    of "no such table" from every migration that followed it.
    """
    problems = []
    connection.execute("BEGIN IMMEDIATE")
    try:
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
                raise
        connection.execute("COMMIT")
    except sqlite3.Error as error:
        connection.execute("ROLLBACK")
        if not problems:
            # Nothing failed statement-by-statement, so the COMMIT itself did:
            # a deferred constraint the transaction was holding open.
            problems.append(
                f"{MIGRATIONS_DIR/identifier}.sql: the migration's transaction failed to commit "
                f"({error}). A deferred constraint is checked at COMMIT, so the offending statement "
                "is not necessarily the last one."
            )
    return problems


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------

# One line per guard, so a mutation harness can disable exactly one.
CHECKS = [
    ("file-encoding", check_file_encoding),
    ("filename-shape", check_filename_shape),
    ("identifier-uniqueness", check_identifier_uniqueness),
    ("statement-allowlist", check_statement_allowlist),
    ("idempotent-ddl", check_idempotent_ddl),
    ("history-frozen", check_history_frozen),
    ("chain-applies", check_chain_applies),
]


def emit_split(path: Path) -> int:
    """Print this side's statement boundaries in the parity fixture's format.

    Read as bytes for the reason at the top of this file: the parity fixture
    includes a CRLF case, and `read_text()` would translate it away before the
    splitter saw it — making this side agree with a loader bug instead of with
    the loader.
    """
    print(json.dumps(split_statements(read_migration_bytes(path).decode("utf-8")), indent=2))
    return 0


def emit_add_column_targets(path: Path) -> int:
    """Print this side's ADD COLUMN reading of the parity fixture's cases.

    `Tests/TBDDaemonTests/Fixtures/MigrationAddColumn/add-column-targets.json`
    holds the shared cases; the Swift half asserts against the same file. Two
    different regex engines run one pattern here, so this is the only thing
    keeping the duplicated pattern honest.
    """
    cases = json.loads(path.read_text(encoding="utf-8"))
    answers = [
        {"name": case["name"], "target": add_column_target(case["sql"])}
        for case in cases
    ]
    print(json.dumps(answers, indent=2))
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--base", default="origin/main", help="branch the history-frozen check diffs against")
    parser.add_argument("--emit-split", type=Path, help="print the statement split of one SQL file as JSON and exit")
    parser.add_argument(
        "--emit-add-column-targets",
        type=Path,
        help="print this side's ADD COLUMN reading of a parity fixture as JSON and exit",
    )
    args = parser.parse_args(argv)

    if args.emit_split is not None:
        return emit_split(args.emit_split)
    if args.emit_add_column_targets is not None:
        return emit_add_column_targets(args.emit_add_column_targets)

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
