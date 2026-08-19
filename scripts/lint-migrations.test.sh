#!/usr/bin/env bash
# Tests for scripts/lint-migrations.py — run: bash scripts/lint-migrations.test.sh
#
# ZERO BUILDS, ZERO CPU LOAD, AND IT NEVER TOUCHES THE REAL ~/tbd OR ANY REAL
# REMOTE. Every case builds a throwaway repository under a fixture directory —
# `git init`, one base commit, and `refs/remotes/origin/main` pointed at it by
# `update-ref`, which is all `git merge-base origin/main HEAD` needs — copies in
# the four files the lint reads, and runs the lint against it with
# `--repo-root`. The whole file runs in seconds on a shared box.
#
# THE MIGRATIONS DIRECTORY SHIPS EMPTY, so on the real tree checks 1-4 and 6
# have nothing to act on. These fixtures are the only exercise those guards
# ever get; the harness is the deliverable, not the afterthought.
#
# EVERY GUARD IS MUTATION-CHECKED. `mutant_of` builds a copy of the lint with
# one guard deliberately disabled, the case re-runs against it, and the verdict
# has to flip. A guard whose fixture reddens for some unrelated reason is the
# failure mode this file exists to prevent — and two of the mutations here run
# the other way round, disabling a piece that makes a *passing* fixture pass:
#
#   the ADD COLUMN skip          without it, a legitimately idempotent
#                                migration fails the chain replay.
#   the three-dot merge base     with a two-dot diff, a branch cut before an
#                                unrelated migration landed on main reddens.
#
# GIT_CONFIG_GLOBAL/SYSTEM ARE FENCED TO /dev/null below. The developer's
# global `commit.gpgsign` would otherwise make every fixture commit prompt for
# a passphrase or fail outright, and a `init.templateDir` would drop live hooks
# into repositories this file creates and deletes.
# shellcheck disable=SC2329 # test_* are dispatched dynamically via `declare -F` below
# shellcheck disable=SC2016 # the sed mutation expressions must NOT expand here
# shellcheck disable=SC2001 # indenting a captured multi-line report is what sed is for
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$HERE/lint-migrations.py"
MIGRATIONS_REL="Sources/TBDDaemon/Database/Migrations"
SPLITTER_FIXTURES="$ROOT/Tests/TBDDaemonTests/Fixtures/MigrationSplitter"

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="lint-migrations harness"
export GIT_AUTHOR_EMAIL="harness@example.invalid"
export GIT_COMMITTER_NAME="lint-migrations harness"
export GIT_COMMITTER_EMAIL="harness@example.invalid"

FAIL=0
assert_ok()       { if [[ "$2" == "0" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected exit 0, got $2"; echo "$3" | sed 's/^/       /'; FAIL=1; fi; }
assert_nonzero()  { if [[ "$2" != "0" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected a non-zero exit, got 0"; FAIL=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output lacks [$3]"; echo "$2" | sed 's/^/       /'; FAIL=1; fi; }
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$3] got [$2]"; FAIL=1; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/lintmig-test.XXXXXX"; }

# Mutants land in one directory removed on exit, so a case that dies early does
# not leave a weakened copy of the lint behind.
MUTANT_DIR="$(mktmpd)"
MUTANT_SEQ=0
FIXTURES=()
trap 'rm -rf "$MUTANT_DIR" "${FIXTURES[@]}"' EXIT

mutant_of() {
  local sed_expr="$1" out
  MUTANT_SEQ=$((MUTANT_SEQ + 1))
  out="$MUTANT_DIR/mutant.$MUTANT_SEQ.py"
  sed -E "$sed_expr" "$SCRIPT" > "$out"
  # A mutation that changes nothing is a mutation that proves nothing.
  if cmp -s "$SCRIPT" "$out"; then
    echo "FAIL - mutation [$sed_expr] did not change the script" >&2
    FAIL=1
  fi
  echo "$out"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# `git add -A` below is safe and deliberate: it runs with `-C` inside a
# throwaway repository this function just created under TMPDIR, never against
# the shared worktree index the repo's own rule is about.
commit_fixture() {
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" commit -q -m "$2" >/dev/null 2>&1
}

# A throwaway repository holding exactly the four paths the lint reads, with
# `origin/main` at its one commit. Echoes the fixture root.
mkrepo() {
  local d; d="$(mktmpd)"
  FIXTURES+=("$d")
  mkdir -p "$d/$MIGRATIONS_REL" "$d/Tests/TBDDaemonTests/Fixtures"
  cp "$ROOT/Sources/TBDDaemon/Database/Database.swift" "$d/Sources/TBDDaemon/Database/"
  cp "$ROOT/Sources/TBDDaemon/Database/SQLMigrationLoader.swift" "$d/Sources/TBDDaemon/Database/"
  cp "$ROOT/Tests/TBDDaemonTests/Fixtures/schema-baseline-v84.sql" "$d/Tests/TBDDaemonTests/Fixtures/"
  : > "$d/$MIGRATIONS_REL/.gitkeep"
  git -C "$d" init -q
  commit_fixture "$d" "base"
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  echo "$d"
}

# Write a migration file into a fixture. `write_migration <root> <name> <sql>`
write_migration() { printf '%s\n' "$3" > "$1/$MIGRATIONS_REL/$2"; }

# Run the lint (or a mutant) against a fixture. Sets RUN_OUT and RUN_RC.
run_lint() {
  local script="$1" root="$2"; shift 2
  RUN_OUT="$(python3 "$script" --repo-root "$root" "$@" 2>&1)"
  RUN_RC=$?
}

# Every statement form the allowlist permits, in one file that also replays
# cleanly against the frozen baseline. The positive control for checks 3, 4
# and 6: if this ever reddens, a guard has become stricter than the spec.
ALL_ALLOWED_FORMS='CREATE TABLE IF NOT EXISTS lint_probe (id TEXT PRIMARY KEY, note TEXT);
CREATE INDEX IF NOT EXISTS lint_probe_note ON lint_probe (note);
CREATE UNIQUE INDEX IF NOT EXISTS lint_probe_id ON lint_probe (id);
ALTER TABLE lint_probe ADD COLUMN added_at DATETIME;
ALTER TABLE lint_probe ADD extra TEXT;
ALTER TABLE lint_probe RENAME COLUMN extra TO extra2;
INSERT OR IGNORE INTO lint_probe (id, note) VALUES ('"'"'a'"'"', '"'"'x;y'"'"');
INSERT OR REPLACE INTO lint_probe (id, note) VALUES ('"'"'a'"'"', '"'"'z'"'"');
UPDATE lint_probe SET note = '"'"'q'"'"' WHERE id = '"'"'a'"'"';
DELETE FROM lint_probe WHERE id = '"'"'b'"'"';
PRAGMA foreign_keys = ON;
DROP INDEX IF EXISTS lint_probe_note;
DROP TABLE IF EXISTS lint_probe;'

# ---------------------------------------------------------------------------
# Positive controls
# ---------------------------------------------------------------------------

test_real_tree_lints_clean() {
  run_lint "$SCRIPT" "$ROOT"
  assert_ok "the repository's own tree lints clean" "$RUN_RC" "$RUN_OUT"
  assert_contains "reports the check count" "$RUN_OUT" "6 checks"
}

test_empty_directory_is_accepted() {
  local d; d="$(mkrepo)"
  run_lint "$SCRIPT" "$d"
  assert_ok "a directory holding only .gitkeep is accepted" "$RUN_RC" "$RUN_OUT"
  assert_contains "counts zero migrations" "$RUN_OUT" "0 .sql migration(s)"
}

test_every_allowed_form_passes() {
  local d; d="$(mkrepo)"
  write_migration "$d" "20260819120000_every_allowed_form.sql" "$ALL_ALLOWED_FORMS"
  commit_fixture "$d" "add migration"
  run_lint "$SCRIPT" "$d"
  assert_ok "all eleven permitted forms lint clean and replay" "$RUN_RC" "$RUN_OUT"
  assert_contains "counts the migration" "$RUN_OUT" "1 .sql migration(s)"
}

# ---------------------------------------------------------------------------
# Splitter parity — the lint and the Swift loader are two bindings to one C
# function, so only the framing can drift. These are the files the Swift half
# asserts against, byte for byte.
# ---------------------------------------------------------------------------

test_splitter_matches_the_shared_fixture() {
  local sql name got want
  for sql in "$SPLITTER_FIXTURES"/*.sql; do
    name="$(basename "$sql")"
    got="$(python3 "$SCRIPT" --emit-split "$sql" 2>&1)"
    want="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))' "${sql%.sql}.expected.json")"
    assert_eq "splitter parity: $name" "$got" "$want"
  done
}

# A comment-only trailer is NOT a statement. This is the single most likely
# place for the two splitters to disagree silently, so it gets its own
# mutation: drop the comment-stripping and the trailer rule degrades to "any
# non-whitespace text is a statement".
test_comment_only_trailer_rule_is_live() {
  local mutant got want
  mutant="$(mutant_of 's/if strip_leading_noise\(current\):/if current.strip():/')"
  got="$(python3 "$mutant" --emit-split "$SPLITTER_FIXTURES/comment_trailer.sql" 2>&1)"
  want="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))' "$SPLITTER_FIXTURES/comment_trailer.expected.json")"
  if [[ "$got" != "$want" ]]; then
    echo "ok   - mutation: without the comment-stripping trailer rule, comment_trailer disagrees"
  else
    echo "FAIL - mutation: comment_trailer split unchanged without the trailer rule — the rule is dead"
    FAIL=1
  fi
}

# ---------------------------------------------------------------------------
# Check 1 — filename shape
# ---------------------------------------------------------------------------

test_filename_shape() {
  local d mutant; d="$(mkrepo)"
  write_migration "$d" "add_thing.sql" "CREATE TABLE IF NOT EXISTS lint_ok (x TEXT);"
  commit_fixture "$d" "add migration"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "an un-timestamped filename fails" "$RUN_RC"
  assert_contains "names the offending file" "$RUN_OUT" "add_thing.sql: not a migration filename"

  mutant="$(mutant_of '/\("filename-shape", check_filename_shape\),/d')"
  run_lint "$mutant" "$d"
  assert_ok "mutation: without the filename guard, the same tree passes" "$RUN_RC" "$RUN_OUT"
}

test_stray_file_in_the_directory() {
  local d; d="$(mkrepo)"
  printf 'notes\n' > "$d/$MIGRATIONS_REL/README.md"
  commit_fixture "$d" "add stray file"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "a stray non-.sql file fails" "$RUN_RC"
  assert_contains "names the stray file" "$RUN_OUT" "README.md: not a migration filename"
}

# ---------------------------------------------------------------------------
# Check 2 — identifier uniqueness
# ---------------------------------------------------------------------------

test_identifier_uniqueness() {
  local d mutant; d="$(mkrepo)"
  # An author who writes both a .sql file and an inline Swift escape hatch
  # under one identifier: GRDB would run exactly one of them, silently.
  sed -i '' \
    's|public static let inlineTimestampMigrations: \[RegisteredMigration\] = \[\]|public static let inlineTimestampMigrations: [RegisteredMigration] = [RegisteredMigration(identifier: "20260303000000_dup") { _ in }]|' \
    "$d/Sources/TBDDaemon/Database/SQLMigrationLoader.swift"
  write_migration "$d" "20260303000000_dup.sql" "CREATE TABLE IF NOT EXISTS lint_dup (x TEXT);"
  commit_fixture "$d" "add colliding migration"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "a .sql stem colliding with the Swift escape hatch fails" "$RUN_RC"
  assert_contains "names the identifier" "$RUN_OUT" "\`20260303000000_dup\` is claimed more than once"
  assert_contains "names both claimants" "$RUN_OUT" "inlineTimestampMigrations"

  mutant="$(mutant_of '/\("identifier-uniqueness", check_identifier_uniqueness\),/d')"
  run_lint "$mutant" "$d"
  assert_ok "mutation: without the uniqueness guard, the same tree passes" "$RUN_RC" "$RUN_OUT"
}

# ---------------------------------------------------------------------------
# Check 3 — statement allowlist
# ---------------------------------------------------------------------------

test_statement_allowlist() {
  local d mutant; d="$(mkrepo)"
  # A form outside the list that is nonetheless valid SQL, so the chain replay
  # accepts it and only the allowlist can object.
  write_migration "$d" "20260304000000_view.sql" "CREATE VIEW lint_view AS SELECT 1;"
  commit_fixture "$d" "add view migration"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "a statement outside the allowlist fails" "$RUN_RC"
  assert_contains "says it is not permitted" "$RUN_OUT" "not one of the permitted forms"
  assert_contains "quotes the statement" "$RUN_OUT" "CREATE VIEW lint_view AS SELECT 1;"

  mutant="$(mutant_of '/\("statement-allowlist", check_statement_allowlist\),/d')"
  run_lint "$mutant" "$d"
  assert_ok "mutation: without the allowlist, the same tree passes" "$RUN_RC" "$RUN_OUT"
}

# ---------------------------------------------------------------------------
# Check 4 — idempotent DDL
# ---------------------------------------------------------------------------

test_idempotent_ddl_create() {
  local d mutant; d="$(mkrepo)"
  # `CREATE TABLE` is on the allowlist and replays fine against the baseline,
  # so this reddens on the idempotency guard alone.
  write_migration "$d" "20260305000000_bare_create.sql" "CREATE TABLE lint_bare (x TEXT);"
  commit_fixture "$d" "add non-idempotent create"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "CREATE TABLE without IF NOT EXISTS fails" "$RUN_RC"
  assert_contains "names the missing clause" "$RUN_OUT" '`CREATE TABLE` must carry `IF NOT EXISTS`'

  mutant="$(mutant_of '/\("idempotent-ddl", check_idempotent_ddl\),/d')"
  run_lint "$mutant" "$d"
  assert_ok "mutation: without the idempotency guard, the same tree passes" "$RUN_RC" "$RUN_OUT"
}

test_idempotent_ddl_drop() {
  local d; d="$(mkrepo)"
  # `tab` exists in the baseline, so the replay succeeds and only the
  # idempotency guard can object.
  write_migration "$d" "20260306000000_bare_drop.sql" "DROP TABLE tab;"
  commit_fixture "$d" "add non-idempotent drop"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "DROP TABLE without IF EXISTS fails" "$RUN_RC"
  assert_contains "names the missing clause" "$RUN_OUT" '`DROP TABLE` must carry `IF EXISTS`'
}

test_idempotent_ddl_index() {
  local d; d="$(mkrepo)"
  write_migration "$d" "20260307000000_bare_index.sql" \
    "CREATE UNIQUE INDEX lint_idx ON tab (worktreeID);"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "CREATE UNIQUE INDEX without IF NOT EXISTS fails" "$RUN_RC"
  assert_contains "names the missing clause" "$RUN_OUT" '`CREATE INDEX` must carry `IF NOT EXISTS`'
}

# ---------------------------------------------------------------------------
# Check 5 — history is frozen
# ---------------------------------------------------------------------------

test_history_frozen() {
  local d mutant; d="$(mkrepo)"
  write_migration "$d" "20260308000000_shipped.sql" "CREATE TABLE IF NOT EXISTS lint_shipped (x TEXT);"
  commit_fixture "$d" "ship a migration"
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  write_migration "$d" "20260308000000_shipped.sql" "CREATE TABLE IF NOT EXISTS lint_shipped (x TEXT, y TEXT);"
  commit_fixture "$d" "edit the shipped migration"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "editing a migration already on main fails" "$RUN_RC"
  assert_contains "says history is frozen" "$RUN_OUT" "migration history is frozen"
  assert_contains "reports the git status letter" "$RUN_OUT" 'git reports `M`'

  mutant="$(mutant_of '/\("history-frozen", check_history_frozen\),/d')"
  run_lint "$mutant" "$d"
  assert_ok "mutation: without the frozen-history guard, the same tree passes" "$RUN_RC" "$RUN_OUT"
}

test_deleting_a_shipped_migration_fails() {
  local d; d="$(mkrepo)"
  write_migration "$d" "20260309000000_shipped.sql" "CREATE TABLE IF NOT EXISTS lint_shipped (x TEXT);"
  commit_fixture "$d" "ship a migration"
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  rm "$d/$MIGRATIONS_REL/20260309000000_shipped.sql"
  commit_fixture "$d" "delete the shipped migration"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "deleting a migration already on main fails" "$RUN_RC"
  assert_contains "reports the git status letter" "$RUN_OUT" 'git reports `D`'
}

# THE THREE-DOT MERGE-BASE FORM IS LOAD-BEARING. This fixture is a branch cut
# before an unrelated migration landed on main — the overwhelmingly common
# shape on a fleet of parallel branches. It must lint GREEN, and the mutation
# shows what a two-dot diff would do to it.
test_migration_landing_on_main_after_the_branch_point_is_not_flagged() {
  local d mutant; d="$(mkrepo)"
  git -C "$d" branch feature
  write_migration "$d" "20260310000000_on_main.sql" "CREATE TABLE IF NOT EXISTS lint_main (x TEXT);"
  commit_fixture "$d" "a migration lands on main"
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  git -C "$d" checkout -q feature
  write_migration "$d" "20260311000000_on_branch.sql" "CREATE TABLE IF NOT EXISTS lint_branch (x TEXT);"
  commit_fixture "$d" "a migration lands on the branch"

  run_lint "$SCRIPT" "$d"
  assert_ok "a branch cut before a main-side migration lints clean" "$RUN_RC" "$RUN_OUT"

  mutant="$(mutant_of 's/base\.strip\(\), "HEAD"/facts.base_ref, "HEAD"/')"
  run_lint "$mutant" "$d"
  assert_nonzero "mutation: a two-dot diff flags the same branch" "$RUN_RC"
  assert_contains "mutation: and blames the main-side migration" "$RUN_OUT" "20260310000000_on_main.sql"
}

test_unresolvable_base_is_reported() {
  local d; d="$(mkrepo)"
  run_lint "$SCRIPT" "$d" --base "origin/no-such-branch"
  assert_nonzero "an unresolvable base fails rather than silently skipping" "$RUN_RC"
  assert_contains "says how to fix it" "$RUN_OUT" "git fetch origin main"
}

# ---------------------------------------------------------------------------
# Check 6 — the chain applies
# ---------------------------------------------------------------------------

test_chain_applies() {
  local d mutant; d="$(mkrepo)"
  # On the allowlist, idempotency-clean, and still wrong: the table does not
  # exist in the schema the preceding migrations produce.
  write_migration "$d" "20260312000000_missing_table.sql" \
    "INSERT OR IGNORE INTO no_such_table (x) VALUES ('y');"
  commit_fixture "$d" "add a migration against a missing table"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "a migration that cannot apply fails" "$RUN_RC"
  assert_contains "reports SQLite's complaint" "$RUN_OUT" "no such table: no_such_table"

  mutant="$(mutant_of '/\("chain-applies", check_chain_applies\),/d')"
  run_lint "$mutant" "$d"
  assert_ok "mutation: without the chain replay, the same tree passes" "$RUN_RC" "$RUN_OUT"
}

# The ADD COLUMN skip, recovered from `addColumnIfMissing` and relocated into
# the loader — reimplemented here so the replay does not trip over a migration
# that is legitimately idempotent. `config.gc_enabled` is in the baseline.
test_add_column_skip_is_live() {
  local d mutant; d="$(mkrepo)"
  write_migration "$d" "20260313000000_existing_column.sql" \
    'ALTER TABLE config ADD COLUMN gc_enabled BOOLEAN;'
  commit_fixture "$d" "re-add an existing column"
  run_lint "$SCRIPT" "$d"
  assert_ok "re-adding an existing column replays clean" "$RUN_RC" "$RUN_OUT"

  mutant="$(mutant_of 's/if target and column_exists\(/if False and column_exists(/')"
  run_lint "$mutant" "$d"
  assert_nonzero "mutation: without the ADD COLUMN skip, the same tree fails" "$RUN_RC"
  assert_contains "mutation: and SQLite says why" "$RUN_OUT" "duplicate column name"
}

# A statement the ADD COLUMN regex does not understand must be replayed
# unmodified rather than silently swallowed — the loader's rule, mirrored.
test_unrecognized_alter_is_not_swallowed() {
  local d; d="$(mkrepo)"
  write_migration "$d" "20260314000000_bad_alter.sql" \
    'ALTER TABLE no_such_table ADD COLUMN whatever TEXT;'
  run_lint "$SCRIPT" "$d"
  assert_nonzero "an ADD COLUMN against a missing table still reaches SQLite" "$RUN_RC"
  assert_contains "reports SQLite's complaint" "$RUN_OUT" "no such table"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

CASES=$(declare -F | awk '{print $3}' | grep '^test_' | sort)
for case_name in $CASES; do
  echo "--- $case_name"
  "$case_name"
done

if [ "$FAIL" -ne 0 ]; then
  echo "lint-migrations.test.sh: FAILURES"
  exit 1
fi
echo "lint-migrations.test.sh: all green"
