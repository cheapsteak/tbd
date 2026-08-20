#!/usr/bin/env bash
#
# Regenerates Tests/TBDDaemonTests/Fixtures/schema-baseline-frozen-block.sql:
# the schema the frozen Swift migration block (Sources/TBDDaemon/Database/
# Database.swift) produces when run against an empty database. The block ends
# at the identifier named by `SchemaBaselineDriftTests.frozenBlockLastIdentifier`,
# which is what `migrate(upTo:)` stops at.
#
# This should almost never run. The block it reads from is frozen — those
# migrations have already run on user machines, and the SQL migration lint's
# history-is-frozen check mechanically forbids editing migration history.
# See docs/specs/2026-08-19-migration-identifier-scheme-design.md, "The frozen
# baseline fixture".
#
# If running this produces a diff against the committed fixture, that means
# the frozen block itself changed — STOP and treat that as a bug report, not
# a chore. Do not commit a regenerated fixture just to make something else
# pass.
#
# The one legitimate diff is a *rebase* that pulls new `vN` migrations onto
# the branch from main and extends the block's tail. Then the diff must consist
# of exactly the columns those new migrations add, and `frozenBlockLastIdentifier`
# moves with them. Anything else in the diff is the bug this warning is about.
#
# The dump excludes SQLite's own internal `sqlite_%` objects and every
# table's row data (schema only — `sqlite_master.sql` never holds row
# contents, so this is automatic rather than a separate filter), and orders
# tables before indexes/triggers/views so the fixture replays cleanly against
# an empty database. See the doc comment on
# `SchemaBaselineDriftTests.dumpSchema` for the full rationale.
#
# Usage: scripts/gen-migration-baseline.sh
set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURE="Tests/TBDDaemonTests/Fixtures/schema-baseline-frozen-block.sql"

echo "Regenerating $FIXTURE from the frozen Swift migration block..."
TBD_GENERATE_MIGRATION_BASELINE=1 scripts/test.sh --filter 'SchemaBaselineDriftTests/generateBaseline'

echo
echo "Wrote $FIXTURE."
echo "Review the diff before committing — this file should almost never change."
echo "Unless you just rebased new vN migrations in, a diff means the frozen block"
echo "changed, which is the real problem to chase down, not this fixture."
