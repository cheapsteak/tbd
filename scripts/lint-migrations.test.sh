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
# THE MIGRATIONS DIRECTORY SHIPS EMPTY, so on the real tree every check except
# history-frozen has nothing to act on. These fixtures are the only exercise
# those guards ever get; the harness is the deliverable, not the afterthought.
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
#   the per-migration            without it the replay runs in autocommit,
#   transaction                  where a deferred constraint is checked after
#                                every statement rather than at COMMIT, and a
#                                migration GRDB would apply happily reddens.
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
ADD_COLUMN_FIXTURE="$ROOT/Tests/TBDDaemonTests/Fixtures/MigrationAddColumn/add-column-targets.json"

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
assert_lacks()    { if [[ "$2" != *"$3"* ]]; then echo "ok   - $1"; else echo "FAIL - $1: output contains [$3]"; echo "$2" | sed 's/^/       /'; FAIL=1; fi; }
assert_eq()       { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1: expected [$3] got [$2]"; FAIL=1; fi; }
mktmpd()          { mktemp -d "${TMPDIR:-/tmp}/lintmig-test.XXXXXX"; }

# Mutants land in one directory removed on exit, so a case that dies early does
# not leave a weakened copy of the lint behind.
MUTANT_DIR="$(mktmpd)"
MUTANT_SEQ=0
FIXTURES=()
# `${FIXTURES[@]+"${FIXTURES[@]}"}` rather than a bare `"${FIXTURES[@]}"`: this
# file runs under `set -u`, and macOS's bash 3.2 treats an EMPTY array as an
# unbound variable. A case that died before the first `mkrepo` would then make
# the trap itself error out, leaving the mutant directory on disk — cleanup
# failing exactly in the situation cleanup exists for.
trap 'rm -rf "$MUTANT_DIR" ${FIXTURES[@]+"${FIXTURES[@]}"}' EXIT

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
  cp "$ROOT/Tests/TBDDaemonTests/Fixtures/schema-baseline-frozen-block.sql" "$d/Tests/TBDDaemonTests/Fixtures/"
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
# cleanly against the frozen baseline. The positive control for the allowlist,
# idempotency and chain-apply guards: if this ever reddens, one of them has
# become stricter than the spec. `ALTER TABLE ... RENAME` and `PRAGMA` are
# absent deliberately and have negative cases of their own below.
ALL_ALLOWED_FORMS='CREATE TABLE IF NOT EXISTS lint_probe (id TEXT PRIMARY KEY, note TEXT);
CREATE INDEX IF NOT EXISTS lint_probe_note ON lint_probe (note);
CREATE UNIQUE INDEX IF NOT EXISTS lint_probe_id ON lint_probe (id);
ALTER TABLE lint_probe ADD COLUMN added_at DATETIME;
ALTER TABLE lint_probe ADD extra TEXT;
INSERT OR IGNORE INTO lint_probe (id, note) VALUES ('"'"'a'"'"', '"'"'x;y'"'"');
INSERT OR REPLACE INTO lint_probe (id, note) VALUES ('"'"'a'"'"', '"'"'z'"'"');
UPDATE lint_probe SET note = '"'"'q'"'"' WHERE id = '"'"'a'"'"';
DELETE FROM lint_probe WHERE id = '"'"'b'"'"';
DROP INDEX IF EXISTS lint_probe_note;
DROP TABLE IF EXISTS lint_probe;'

# ---------------------------------------------------------------------------
# Positive controls
# ---------------------------------------------------------------------------

test_real_tree_lints_clean() {
  run_lint "$SCRIPT" "$ROOT"
  assert_ok "the repository's own tree lints clean" "$RUN_RC" "$RUN_OUT"
  assert_contains "reports the check count" "$RUN_OUT" "7 checks"
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
  assert_ok "all nine permitted forms lint clean and replay" "$RUN_RC" "$RUN_OUT"
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
# Check 1 — the bytes both readers see
#
# Written with `printf` straight into the file rather than through
# `write_migration`, because a shell variable cannot carry a NUL byte and
# `$(...)` strips them.
# ---------------------------------------------------------------------------

# `MUTANT_ENCODING` disables the guard. Every case below is then expected to
# PASS, because a file the guard rejects is also withheld from the migration
# list — which is what keeps a NUL byte from reaching the splitter.
MUTANT_ENCODING='/\("file-encoding", check_file_encoding\),/d'

test_crlf_line_endings_are_rejected() {
  local d mutant; d="$(mkrepo)"
  # Valid SQL by every other guard: on the allowlist, idempotent, and it
  # replays. Only the line endings are wrong.
  printf 'CREATE TABLE IF NOT EXISTS lint_crlf (x TEXT);\r\n' \
    > "$d/$MIGRATIONS_REL/20260317000000_crlf.sql"
  commit_fixture "$d" "add a CRLF migration"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "a migration with CRLF line endings fails" "$RUN_RC"
  assert_contains "names the byte" "$RUN_OUT" "contains a carriage return (CR, 0x0D) on line 1"
  assert_contains "says how to fix it" "$RUN_OUT" "tr -d"

  mutant="$(mutant_of "$MUTANT_ENCODING")"
  run_lint "$mutant" "$d"
  assert_ok "mutation: without the encoding guard, CRLF sails through" "$RUN_RC" "$RUN_OUT"
}

# The CRLF guard covers migration files ONLY. The splitter-parity fixture under
# Tests/ is deliberately CRLF in one case — that is the input both splitters
# have to agree on — and must never be caught by this.
test_the_parity_fixture_is_not_a_migration_file() {
  run_lint "$SCRIPT" "$ROOT"
  assert_ok "the real tree still lints clean with the encoding guard live" "$RUN_RC" "$RUN_OUT"
  assert_lacks "and says nothing about the parity fixture" "$RUN_OUT" "MigrationSplitter"
}

test_a_nul_byte_is_reported_rather_than_thrown() {
  local d mutant; d="$(mkrepo)"
  printf 'CREATE TABLE IF NOT EXISTS lint_nul (x TEXT);\000\n' \
    > "$d/$MIGRATIONS_REL/20260318000000_nul.sql"
  commit_fixture "$d" "add a migration holding a NUL byte"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "a migration holding a NUL byte fails" "$RUN_RC"
  assert_contains "names the byte and its offset" "$RUN_OUT" "contains a NUL byte (0x00) at offset 45"
  # THE POINT OF THE CASE. `sqlite3.complete_statement` raises ValueError on a
  # NUL, so without the guard the lint dies with a stack trace naming a Python
  # function instead of telling the author which file is wrong.
  assert_lacks "and does not die with a traceback" "$RUN_OUT" "Traceback"

  mutant="$(mutant_of "$MUTANT_ENCODING")"
  run_lint "$mutant" "$d"
  assert_ok "mutation: without the encoding guard, the NUL file is not even read" "$RUN_RC" "$RUN_OUT"
}

test_a_utf8_bom_is_rejected() {
  local d mutant; d="$(mkrepo)"
  printf '\xEF\xBB\xBFCREATE TABLE IF NOT EXISTS lint_bom (x TEXT);\n' \
    > "$d/$MIGRATIONS_REL/20260319000000_bom.sql"
  commit_fixture "$d" "add a BOM-prefixed migration"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "a migration starting with a UTF-8 BOM fails" "$RUN_RC"
  assert_contains "names the mark" "$RUN_OUT" "starts with a UTF-8 byte-order mark"
  # Without the guard the BOM reaches the allowlist as an invisible leading
  # character and the author is told their CREATE TABLE is not a permitted
  # form, which is true and useless.
  assert_lacks "rather than blaming the statement" "$RUN_OUT" "not one of the permitted forms"

  mutant="$(mutant_of "$MUTANT_ENCODING")"
  run_lint "$mutant" "$d"
  assert_ok "mutation: without the encoding guard, the BOM file is not even read" "$RUN_RC" "$RUN_OUT"
}

# ---------------------------------------------------------------------------
# Check 2 — filename shape
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
# Check 3 — identifier uniqueness
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
# Check 4 — statement allowlist
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

# The two forms the spec deliberately keeps OFF the list. Both are valid SQL
# that replays fine here, so only the allowlist can object — and both are
# plausible enough that someone will propose re-adding them.

test_alter_table_rename_is_not_permitted() {
  local d mutant; d="$(mkrepo)"
  # RENAME has no `IF EXISTS` spelling and no loader-side skip, so it can be
  # neither replayed nor reordered. `tab` is in the baseline, so this applies.
  write_migration "$d" "20260320000000_rename.sql" "ALTER TABLE tab RENAME TO tab_renamed;"
  commit_fixture "$d" "add a RENAME migration"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "ALTER TABLE ... RENAME fails" "$RUN_RC"
  assert_contains "says it is not permitted" "$RUN_OUT" "not one of the permitted forms"
  assert_contains "and does not offer RENAME as an alternative" "$RUN_OUT" "ALTER TABLE ... ADD [COLUMN]"
  assert_lacks "the permitted list no longer names RENAME" "$RUN_OUT" "ALTER TABLE ... RENAME"

  mutant="$(mutant_of '/\("statement-allowlist", check_statement_allowlist\),/d')"
  run_lint "$mutant" "$d"
  assert_ok "mutation: without the allowlist, RENAME sails through" "$RUN_RC" "$RUN_OUT"
}

test_pragma_is_not_permitted() {
  local d; d="$(mkrepo)"
  # `PRAGMA foreign_keys` is a documented no-op inside a transaction, and GRDB
  # runs every migration inside one — so it works in any standalone replay and
  # silently does nothing in production. That is the worst shape a permitted
  # form can have, which is why it is not one.
  write_migration "$d" "20260321000000_pragma.sql" "PRAGMA foreign_keys = OFF;"
  commit_fixture "$d" "add a PRAGMA migration"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "PRAGMA fails" "$RUN_RC"
  assert_contains "says it is not permitted" "$RUN_OUT" "not one of the permitted forms"
  assert_lacks "the permitted list no longer names PRAGMA" "$RUN_OUT" "PRAGMA)"
}

# ---------------------------------------------------------------------------
# Check 5 — idempotent DDL
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
# Check 6 — history is frozen
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

# THE MERGE-BASE LEG FAILS OPEN ON A STALE BASE REF, and this is the shape
# that exploits it: the branch carries a migration that is also on
# `origin/main`, but picked it up by cherry-pick or rebase rather than by
# merging the fetched ref — so the merge base predates the file, an in-place
# edit reads as an ADDITION there, and the merge-base leg has nothing to say.
# CI is safe because it fetches immediately before linting; the pre-push hook,
# which runs against whatever the developer last fetched, is not. The blob
# comparison never consults the merge base at all.
test_editing_a_migration_that_is_on_main_but_not_at_the_merge_base() {
  local d mutant; d="$(mkrepo)"
  git -C "$d" branch feature
  write_migration "$d" "20260322000000_shipped.sql" "CREATE TABLE IF NOT EXISTS lint_shipped (x TEXT);"
  commit_fixture "$d" "a migration lands on main"
  git -C "$d" update-ref refs/remotes/origin/main HEAD

  git -C "$d" checkout -q feature
  write_migration "$d" "20260322000000_shipped.sql" "CREATE TABLE IF NOT EXISTS lint_shipped (x TEXT);"
  commit_fixture "$d" "the branch picks the shipped migration up without merging origin/main"
  write_migration "$d" "20260322000000_shipped.sql" "CREATE TABLE IF NOT EXISTS lint_shipped (x TEXT, y TEXT);"
  commit_fixture "$d" "and edits it in place"

  run_lint "$SCRIPT" "$d"
  assert_nonzero "editing a migration origin/main already holds fails" "$RUN_RC"
  assert_contains "says history is frozen" "$RUN_OUT" "migration history is frozen"
  assert_contains "names the base branch" "$RUN_OUT" "already on \`origin/main\`"

  mutant="$(mutant_of '/problems\.extend\(frozen_blob_edits\(facts\)\)/d')"
  run_lint "$mutant" "$d"
  assert_ok "mutation: with only the merge-base leg, the stale base lets the edit through" "$RUN_RC" "$RUN_OUT"
}

# The blob leg must stay silent about a path origin/main holds and HEAD does
# not: on a branch that has not caught up that is an ordinary main-side
# addition, not a deletion. Only the merge-base leg can tell those apart, and
# it is what the earlier three-dot case pins.
test_a_main_side_migration_absent_from_the_branch_is_not_a_deletion() {
  local d; d="$(mkrepo)"
  git -C "$d" branch feature
  write_migration "$d" "20260323000000_on_main.sql" "CREATE TABLE IF NOT EXISTS lint_main (x TEXT);"
  commit_fixture "$d" "a migration lands on main"
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  git -C "$d" checkout -q feature
  run_lint "$SCRIPT" "$d"
  assert_ok "a branch that has not caught up with main lints clean" "$RUN_RC" "$RUN_OUT"
}

test_unresolvable_base_is_reported() {
  local d; d="$(mkrepo)"
  run_lint "$SCRIPT" "$d" --base "origin/no-such-branch"
  assert_nonzero "an unresolvable base fails rather than silently skipping" "$RUN_RC"
  assert_contains "says how to fix it" "$RUN_OUT" "git fetch origin main"
}

# ---------------------------------------------------------------------------
# Check 7 — the chain applies
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

# THE REPLAY RUNS IN PRODUCTION'S ENVIRONMENT, NOT PYTHON'S DEFAULT ONE. Both
# cases below are green under `sqlite3.connect(":memory:")` as it comes out of
# the box, and that is exactly the drift they exist to catch: a lint that
# replays in a different SQLite than the daemon is a lint that green-lights
# migrations which throw at startup.

test_chain_replay_enforces_foreign_keys() {
  local d mutant; d="$(mkrepo)"
  # Python's sqlite3 leaves foreign keys OFF; GRDB sets `foreignKeysEnabled`.
  write_migration "$d" "20260324000000_fk_violation.sql" \
    'CREATE TABLE IF NOT EXISTS lint_parent (id TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS lint_child (id TEXT PRIMARY KEY, parent TEXT REFERENCES lint_parent (id));
INSERT OR IGNORE INTO lint_child (id, parent) VALUES ('"'"'c'"'"', '"'"'nope'"'"');'
  commit_fixture "$d" "add an FK-violating migration"
  run_lint "$SCRIPT" "$d"
  assert_nonzero "a migration violating a foreign key fails" "$RUN_RC"
  assert_contains "reports SQLite's complaint" "$RUN_OUT" "FOREIGN KEY constraint failed"

  mutant="$(mutant_of 's/PRAGMA foreign_keys=ON/PRAGMA foreign_keys=OFF/')"
  run_lint "$mutant" "$d"
  assert_ok "mutation: with foreign keys off, the same migration replays green" "$RUN_RC" "$RUN_OUT"
}

# The reverse mutation: this migration is legal under GRDB and must lint clean.
# A DEFERRED constraint is checked at COMMIT, so inserting the child before its
# parent is fine inside a transaction and fails in autocommit — where every
# statement commits on its own.
test_chain_replay_wraps_each_migration_in_a_transaction() {
  local d mutant; d="$(mkrepo)"
  write_migration "$d" "20260325000000_deferred_fk.sql" \
    'CREATE TABLE IF NOT EXISTS lint_dparent (id TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS lint_dchild (id TEXT PRIMARY KEY, parent TEXT REFERENCES lint_dparent (id) DEFERRABLE INITIALLY DEFERRED);
INSERT OR REPLACE INTO lint_dchild (id, parent) VALUES ('"'"'c'"'"', '"'"'p'"'"');
INSERT OR REPLACE INTO lint_dparent (id) VALUES ('"'"'p'"'"');'
  commit_fixture "$d" "add a migration relying on deferred constraint checking"
  run_lint "$SCRIPT" "$d"
  assert_ok "a migration legal only inside a transaction replays clean" "$RUN_RC" "$RUN_OUT"

  mutant="$(mutant_of 's/"(BEGIN IMMEDIATE|COMMIT|ROLLBACK)"/"SELECT 1"/g')"
  run_lint "$mutant" "$d"
  assert_nonzero "mutation: replayed in autocommit, the same migration fails" "$RUN_RC"
  assert_contains "mutation: and SQLite says why" "$RUN_OUT" "FOREIGN KEY constraint failed"
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

# ---------------------------------------------------------------------------
# ADD COLUMN parity — unlike the splitter, this is two regex ENGINES running
# one pattern, so the pattern text is genuinely duplicated between here and
# the loader. The fixture is what keeps the duplicate honest; the Swift half
# asserts against the same file.
# ---------------------------------------------------------------------------

test_add_column_target_matches_the_shared_fixture() {
  local got want
  got="$(python3 "$SCRIPT" --emit-add-column-targets "$ADD_COLUMN_FIXTURE" 2>&1)"
  want="$(python3 -c 'import json,sys; print(json.dumps([{"name": c["name"], "target": c["target"]} for c in json.load(open(sys.argv[1]))], indent=2))' "$ADD_COLUMN_FIXTURE")"
  assert_eq "ADD COLUMN parity: every shared fixture case" "$got" "$want"
}

# AN UNTYPED COLUMN IS LEGAL SQLITE — it takes BLOB affinity — and the splitter
# hands each statement over with its `;` still attached, so the character after
# the column identifier is `;` where a typed column has a space. A terminator
# set of whitespace-or-end-of-input does not merely fail to match there: the
# optional `COLUMN` group backtracks and the KEYWORD becomes the column name,
# so the skip asks about a column called `column`, finds none, and lets a
# duplicate ADD COLUMN reach SQLite.
test_untyped_add_column_skip_is_live() {
  local d mutant; d="$(mkrepo)"
  write_migration "$d" "20260315000000_untyped_existing_column.sql" \
    'ALTER TABLE config ADD COLUMN gc_enabled;'
  commit_fixture "$d" "re-add an existing column with no type"
  run_lint "$SCRIPT" "$d"
  assert_ok "re-adding an existing column untyped replays clean" "$RUN_RC" "$RUN_OUT"

  mutant="$(mutant_of 's/^COLUMN_TERMINATOR = .*$/COLUMN_TERMINATOR = r"(?=\\s|$)"/')"
  run_lint "$mutant" "$d"
  assert_nonzero "mutation: with whitespace-or-end the only terminator, the same tree fails" "$RUN_RC"
  assert_contains "mutation: and SQLite says why" "$RUN_OUT" "duplicate column name"
}

# The keyword capture, closed from the other side. A quoted column name butted
# straight against its type is valid SQLite and ends at a character no
# terminator set can accept, so the engine backtracks and captures `COLUMN`
# itself. Against a table that has a column literally named `column`, believing
# that capture SKIPS a statement that never ran — the silent divergence the
# guard exists to prevent. Declining a bare keyword capture is what makes the
# skip able only to name the real column or nothing.
test_backtracked_keyword_capture_is_declined() {
  local d mutant; d="$(mkrepo)"
  write_migration "$d" "20260316000000_keyword_capture.sql" \
    'CREATE TABLE IF NOT EXISTS keyword_probe (id TEXT PRIMARY KEY, "column" TEXT);
ALTER TABLE keyword_probe ADD COLUMN "foo"TEXT;
CREATE INDEX IF NOT EXISTS keyword_probe_foo ON keyword_probe (foo);'
  commit_fixture "$d" "add a column whose quoted name butts against its type"
  run_lint "$SCRIPT" "$d"
  assert_ok "a backtracked keyword capture does not skip the statement" "$RUN_RC" "$RUN_OUT"

  mutant="$(mutant_of 's/if raw_column\.lower\(\) in KEYWORDS_NEVER_COLUMN_NAMES:/if False:/')"
  run_lint "$mutant" "$d"
  assert_nonzero "mutation: believing the keyword capture, the same tree fails" "$RUN_RC"
  assert_contains "mutation: and SQLite says why" "$RUN_OUT" "no such column: foo"
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
