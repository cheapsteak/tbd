# Splitter parity fixture

Adversarial SQL that both statement splitters must agree on: the Swift loader
(`Sources/TBDDaemon/Database/SQLMigrationLoader.swift`, over `sqlite3_complete()`)
and the migration lint (`scripts/lint-migrations.py`, over Python's
`sqlite3.complete_statement()`). Both are bindings to the same C function, so a
disagreement means one side's framing code drifted, not that SQLite changed.

Each case is a pair:

- `<name>.sql` — the input, fed to the splitter verbatim.
- `<name>.expected.json` — a JSON array of the statements the splitter must
  produce, in order.

## The contract the fixture pins

- A statement boundary is a `;` at which the accumulated text is a complete
  SQL statement per `sqlite3_complete()`. Semicolons inside string literals,
  inside `--` and `/* */` comments, and inside a `CREATE TRIGGER … BEGIN … END;`
  body are therefore not boundaries.
- Each emitted statement is the raw source slice with surrounding whitespace
  trimmed. Comments that precede a statement stay attached to it — they are
  part of the slice, and executing them is harmless.
- Trailing text after the last boundary is emitted as a final statement only if
  something remains once leading whitespace and complete `--` / `/* */`
  comments are stripped. That is what makes a file whose last statement has no
  trailing semicolon work, while a whitespace-only or comment-only trailer
  yields nothing.

Adding a case means adding both files. Neither side may special-case a name.
