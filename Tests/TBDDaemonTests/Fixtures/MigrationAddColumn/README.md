# ADD COLUMN guard parity fixture

Statements that both implementations of the ADD COLUMN skip must read the same
way: the Swift loader (`SQLMigrationLoader.addColumnTarget`, over
`NSRegularExpression`) and the migration lint (`scripts/lint-migrations.py`,
over Python's `re`). Unlike the splitter next door, these are two *different*
regex engines running one pattern, so the pattern text is duplicated and this
fixture is what keeps the duplicate honest.

`add-column-targets.json` is a JSON array of cases, each with:

- `name` — the case, for the failure message.
- `sql` — one statement, exactly as the splitter would hand it over. The
  splitter keeps the trailing `;`, so most cases carry one.
- `target` — `["<table>", "<column>"]` the guard must extract, or `null` when
  it must decline.

## The contract the fixture pins

- The shape is `ALTER TABLE <ident> ADD [COLUMN] <ident>`, case-insensitive,
  with double-quoted identifiers unquoted (`""` collapses to `"`).
- The column identifier may be followed by whitespace, the statement's `;`, a
  `--` or `/*` comment opener, or nothing at all. An **untyped** column is
  legal SQLite — it takes BLOB affinity — so `ADD COLUMN foo;` is a real shape
  and not a typo.
- The guard either names the statement's real column or declines. It may never
  name a *different* one: a wrong name that happened to exist in the table
  would make the loader **skip** a statement that had not run yet, which is the
  silent schema divergence the guard exists to prevent. Declining is free by
  comparison — the statement executes unmodified, exactly as it would with no
  guard at all.
- `COLUMN` is optional in the shape, so wherever the column identifier cannot
  be matched the engine backtracks and captures the keyword itself. Three
  shapes reach that: a statement that is not an ADD COLUMN at all
  (`ADD CONSTRAINT …`), one whose column is literally named `column` and
  carries no type, and a quoted name butted straight against its type
  (`ADD COLUMN "foo"TEXT`, which SQLite accepts). A bare `column` or
  `constraint` capture is therefore declined. Quoted, `"column"` is an ordinary
  identifier and is kept — the comparison happens before unquoting.

Adding a case means adding one array entry. Neither side may special-case a
name.
