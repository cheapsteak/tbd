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

So a new link is added to the list by hand, in the change that makes it, and the reviewer sees it in the diff. A change that removes a link's last reference deletes the link's line in the same change, because a listed link with no reference fails as stale. The list grows only by a hand edit a reviewer sees. The spec describes where the list is headed.

### What counts as a reference

The check indexes each unit's top-level declarations that are not `private` or `fileprivate`: types, typealiases, top-level functions and globals. A file references another unit when it names one of them:

- in a signature, a construction or a static call;
- in an extension of the type, or a conformance to the protocol;
- in code inside a string's interpolation.

It ignores:

- a name after a `.`, though not after `...`;
- a label (except the forms listed under false links below): an argument label or a function type's parameter name in parentheses, a trailing closure's label, or a statement's label, where it is declared and after `break` or `continue`;
- every name in a comment, a string, a regex literal or a raw identifier such as `` `checks that Widget parses` ``.

### Links the check can miss

The check matches names, not types. It misses:

- **an inferred type's member**, as in `db.terminals.setStartHeld()`;
- **a member another folder's extension adds**;
- **an implicit `.case` or `.init(...)`** whose type comes from context;
- **a name the file declares for itself**: a local, a name a pattern binds, a parameter, a generic parameter, a member, a nested type, a type or function declared in a body, or a private declaration with the same name as another unit's declaration. The check reads every use of that name in the file as the file's own;
- **an overloaded top-level function** that the calling folder also declares under the same name.

A missed reference makes no link, so the list can understate how two folders depend on each other. Nothing needs fixing for it.

### Links the check can report falsely

- **A member or nested type used bare, declared in another file.** A type's member or nested type declared in one file and used bare in the type's extension in another file reads as a reference to any other unit's top-level declaration of the same name. The check sees a member only in the file that declares it.
- **A subscript's argument label**, as in `cache[widgetLimit: 2]`, reads as a dictionary key.
- **A declaration's outer argument label** when the parameter has a separate inner name, as in `func f(widgetLimit limit: Int)`, and **the second and later labels of a compound name**, as in `run(fetch:widgetLimit:)` or `#selector(handle(_:widgetLimit:))`, read as references to a same-named declaration in another folder.
- **A force-unwrap glued to a division slash**, as in `a!/2`, reads as the start of a regex literal. It can stop the check with exit 2 ("unterminated string literal") or hide a reference later on that line. Write `a! / 2`.
- **A statement label after a `case` on its line**, as in `case .a: outer: for x in xs`, reads as a reference. A label that starts its line, or follows `{` or `;`, does not.
- **An uppercase name a pattern binds**, as in `case let .some(Widget)`. In a pattern the check binds only lowercase names, so that no type in it is taken for a binding.

A false link is a bug in the check. For a bare member, write `self.` before it, or `Self.` before a nested type or a static member; for anything else, fix the check and add the case to `scripts/lint-daemon-layers.test.sh`. Never add a false link to the list: the name that makes it never goes away, so the line can never go stale, and from then on it admits every real reference between the two folders.

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

### Base

`Sources/TBDDaemon/Base` is the bottom folder.

- **Nothing in it uses another daemon folder.** Its code may use only `TBDShared`, `TBDKernel`, third-party and system modules.
- **It holds only code that two or more other folders use.** Code that one folder uses belongs in that folder.
- **Moving a declaration into `Base`** is the usual way to remove a link to a folder above, when the declaration needs nothing outside `Base`. Its users then link to `Base`, and the change adds those lines to the list.
- **Never add a `Base -> ` line** to `scripts/daemon-links.txt`. If code in `Base` needs another folder, the code belongs in that folder or above it, or its caller passes a closure or a protocol in.

### Fixing a stale link

Delete its line from `scripts/daemon-links.txt`. The failure names the line.

### When `main` fails

Branch protection does not require a branch to be up to date with `main` before it merges, so two pull requests that each pass alone can together leave `main` failing. If one removes the last reference behind `A -> B` and deletes its line while the other adds a new reference to it, `main` makes a link the list lacks. If each removes one of the last two references, neither deletes the line, and it goes stale. Every branch then fails on a link its change never touched. The repair is a one-line pull request that adds the line, or deletes it; the failure output names it.

### "cannot scan" and "cannot read"

Exit 2 means the check could not run. It stops rather than report links it may have read wrong.

- **`cannot scan <file>:<line>`**: the check could not read that Swift. The reason is an unbalanced brace, a comment or literal that never closes, or bytes that are not UTF-8. The usual cause is an `#if` whose branches open different braces, such as two signatures sharing one body. Make each branch balance its own braces.
- **`cannot scan` without a line**: either `Sources/TBDDaemon: not found`, because the check ran against a tree without it (see `--repo-root`), or a file in a folder with a space in its name, whose links the list could not hold.
- **`cannot read <path>`**: the check could not open that file or list that folder, for the reason that follows.
- **`cannot read scripts/daemon-links.txt:<line>`**: a line is not `A -> B`, has a space in a unit name, is listed twice, links a unit to itself, is out of order, or holds bytes that are not UTF-8. An out-of-order line is named with the line it sorts before. The links are in byte order, below the comments at the top; sorting the whole file would scramble those comments. This sorts only the link lines:

  ```
  { grep -E '^(#|$)' scripts/daemon-links.txt; grep -Ev '^(#|$)' scripts/daemon-links.txt | LC_ALL=C sort; } > links.tmp && mv links.tmp scripts/daemon-links.txt
  ```

### The cycle report

A passing run ends with the cycles among the listed links. The listed links form no loop, so it reports none:

```
cycles among the listed links: none
```

If the report names a group instead, some listed links form a loop again: within the group, every unit reaches every other by following links. The check still passes, because the report is information, not a failure. Only a new line in the list can close a loop, so the reviewer reads the group together with that line and decides whether the link belongs.

### Running it

- **`python3 scripts/lint-daemon-layers.py`** checks the tree.
- **`bash scripts/lint-daemon-layers.test.sh`** runs the check's harness on sample trees.

CI runs the check in the Lint job and the harness in the Script harnesses job. The Lint job runs the check under macOS's own `/usr/bin/python3`, Python 3.9, which is the `python3` the pre-push hook finds on a Mac without Homebrew; so the check must not use newer syntax.

The pre-push hook runs the check on every push from a branch that has it, even with `TBD_SKIP_PREPUSH_TESTS=1`. It checks the working tree, not the commits being pushed, so an untracked, half-written Swift file can block a push that does not include it. `git push --no-verify` skips the hook for that push.
