#!/usr/bin/env bash
#
# Regenerates Tests/TBDDaemonTests/Fixtures/schema-baseline-v84.sql: the
# schema the frozen v1-v84 Swift migration block (Sources/TBDDaemon/Database/
# Database.swift) produces when run against an empty database.
#
# This should almost never run again. The block it reads from is frozen —
# those migrations have already run on user machines, and the SQL migration
# lint's history-is-frozen check mechanically forbids editing migration
# history. See docs/specs/2026-08-19-migration-identifier-scheme-design.md,
# "The frozen baseline fixture".
#
# If running this produces a diff against the committed fixture, that means
# the frozen block itself changed — STOP and treat that as a bug report, not
# a chore. Do not commit a regenerated fixture just to make something else
# pass.
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

echo "Regenerating Tests/TBDDaemonTests/Fixtures/schema-baseline-v84.sql from v1-v84..."
TBD_GENERATE_MIGRATION_BASELINE=1 scripts/test.sh --filter 'SchemaBaselineDriftTests/generateBaseline'

echo
echo "Wrote Tests/TBDDaemonTests/Fixtures/schema-baseline-v84.sql."
echo "Review the diff before committing — this file should almost never change."
echo "If it did change, that means the frozen v1-v84 block changed, which is the"
echo "real problem to chase down, not this fixture."
