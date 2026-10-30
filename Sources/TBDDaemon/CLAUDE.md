# TBDDaemon

After changing daemon or shared code (`Sources/TBDDaemon/`, `Sources/TBDShared/`), always use `scripts/restart.sh` (full restart), NOT `scripts/restart.sh --app`.

The app-only restart leaves the daemon running the old binary. New RPC fields will silently decode as nil, causing features to appear broken while the code is correct.

## Links between folders

`scripts/lint-daemon-layers.py` checks which daemon folders use which. It needs no build and takes about 1 s. Design and rationale: [`docs/specs/2026-10-30-daemon-layer-order-design.md`](../../docs/specs/2026-10-30-daemon-layer-order-design.md).

### Units

- **A folder** directly under `Sources/TBDDaemon` is one unit, with its subfolders: `PR/Schedule` counts as `PR`.
- **`(root)`** is the unit of the files directly under `Sources/TBDDaemon`.
- **`main.swift`** belongs to the `TBDDaemon` executable target, not the library, so the check skips it.
- **Tests** are out of scope. A test may use any folder.

A link `A -> B` means that a Swift file in unit A names a declaration from unit B.

### The rule

- Every link the code makes is listed in `scripts/daemon-links.txt`, one `A -> B` per line, sorted.
- Every listed link is one the code makes.

So a new link is added to the list by hand, in the change that makes it, and the reviewer sees it in the diff. A change that removes a link's last reference deletes the link's line in the same change, so the list only shrinks. The spec describes where that shrinking leads.

### What counts as a reference

The check indexes each unit's top-level declarations that are not `private` or `fileprivate`: types, typealiases, top-level functions and globals. A file references another unit when it names one of them:

- in a signature, a construction or a static call;
- in an extension of the type, or a conformance to the protocol;
- in code inside a string's interpolation.

It ignores a name after a `.`, an argument label, and every name in a comment, a string or a regex literal.

### Blind spots

The check matches names, not types. It misses:

- **an inferred type's member**, as in `db.terminals.setStartHeld()`;
- **a member another folder's extension adds**;
- **an implicit `.case` or `.init(...)`** whose type comes from context;
- **a name the file declares for itself**: a local, a parameter, a member, a nested type or a private declaration with the same name as another unit's declaration. The check reads every use of that name in the file as the file's own;
- **an overloaded top-level function** that the calling folder also declares under the same name.

### Reading a failure

A new link names the file, the line, the link and the name:

```
Sources/TBDDaemon/Keychain/ModelProfileKeychain.swift:253: Keychain -> Server is a new link: RPCRouter is declared in Server
```

Line 253 of that file names `RPCRouter`, which Server declares, and the list has no `Keychain -> Server`.

A stale link names its line in the list:

```
scripts/daemon-links.txt:104: PR -> (root) is stale: no file in PR names a declaration from (root)
```

The list holds `PR -> (root)`, but no file in PR names anything the root files declare. When a side of the link is not a unit at all, the line says so; the usual cause is a typo or a renamed folder.

### Fixing a new link

- **Move the declaration** into the folder that uses it, or into a lower folder that both can use. Every folder is in one module, so moving a whole file with `git mv` changes no code.
- **Pass a closure or a protocol in** from the folder above, so the lower folder stops naming the higher one.
- **Add the link** to `scripts/daemon-links.txt` if it is right. The failure output prints the exact line to add. Keep the list sorted. This is a design decision, and the reviewer sees it in the diff.

### Fixing a stale link

Delete its line from `scripts/daemon-links.txt`. The failure names the line.

### "cannot scan" and "cannot read"

Exit 2 means the check could not run. It stops rather than report links it may have read wrong.

- **`cannot scan <file>:<line>`**: the check could not read that Swift. The reason is an unbalanced brace, a comment or literal that never closes, or bytes that are not UTF-8. The usual cause is an `#if` whose branches open different braces, such as two signatures sharing one body. Make each branch balance its own braces.
- **`cannot read scripts/daemon-links.txt:<line>`**: a line is not `A -> B`, is listed twice, links a unit to itself, or is out of order. `LC_ALL=C sort` gives the order the check expects.

### The cycle report

A passing run ends with the cycles among the listed links:

```
cycles among the listed links: 1 group
    24 units, 134 links: (root), Actuation, AskUserQuestion, ...
```

Within a group, every unit reaches every other by following links. The report is information, not a failure: it shows how far the folders are from having a direction.

### Running it

- **`python3 scripts/lint-daemon-layers.py`** checks the tree.
- **`bash scripts/lint-daemon-layers.test.sh`** runs the check's harness on sample trees.

CI runs the check in the Lint job and the harness in the Script harnesses job. The pre-push hook runs the check on every push, even with `TBD_SKIP_PREPUSH_TESTS=1`.
