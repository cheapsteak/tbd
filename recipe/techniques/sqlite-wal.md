# SQLite with WAL mode for persistent state

## Posture: Buy (currently GRDB)

Embedded SQLite via a Swift ORM. Don't hand-roll SQL query builders or migration systems. The migration framework and Codable integration aren't worth reimplementing.

## The problem

The daemon needs persistent state (worktree metadata, display names, notification history, pin timestamps) that survives crashes and supports concurrent readers (the daemon writes while the database is being read for state broadcasts).

## The technique

SQLite database at `~/.tbd/state.db` in WAL (Write-Ahead Logging) mode. Only the daemon writes — CLI and UI go through the daemon's RPC, so there are no concurrent writer conflicts. GRDB provides the Swift ORM layer with Codable record types and a sequential migration system (`DatabaseMigrator` with named migrations: v1, v2, v3...).

Key rule: never modify an existing migration. Always add a new one. New columns must have `.defaults(to:)` values, and the corresponding Codable model must make new fields optional or provide defaults.

## Why not alternatives

- **UserDefaults / plist:** No relational queries, no migrations, doesn't scale to the worktree/terminal/notification model.
- **Core Data:** Heavy, complex, designed for app processes not daemons, poor CLI ergonomics.
- **Raw SQLite (no ORM):** Works but GRDB's Codable integration and migration system save significant boilerplate.

## Where this applies

Any Swift daemon or CLI tool needing structured persistent storage with crash safety and migration support.
