# TBDDaemon

After changing daemon or shared code (`Sources/TBDDaemon/`, `Sources/TBDShared/`), always use `scripts/restart.sh` (full restart), NOT `scripts/restart.sh --app`.

The app-only restart leaves the daemon running the old binary. New RPC fields will silently decode as nil, causing features to appear broken while the code is correct.

## Folder layers

`scripts/lint-daemon-layers.py` holds the daemon's folders to a written layer order. It needs no build and takes about 1 s. Design and rationale: [`docs/specs/2026-10-30-daemon-layer-order-design.md`](../../docs/specs/2026-10-30-daemon-layer-order-design.md).

### Units

- **A folder** directly under `Sources/TBDDaemon` is one unit, with its subfolders: `PR/Schedule` counts as `PR`. A folder that holds no Swift is no unit.
- **`(root)`** is the unit of the files directly under `Sources/TBDDaemon`.
- **`main.swift`** belongs to the `TBDDaemon` executable target, not the library, so the check skips it.
- **Tests** are out of scope. A test may use any folder.

A unit uses another when one of its Swift files names a declaration from it. That use is a link, written `A -> B`.

### The rule

The order lives in `scripts/daemon-layers.txt`: one line per layer, bottom first, each listing its units separated by commas. A blank line, or a line that starts with `#` after any spaces, is no layer.

- **A unit may use only units in a lower layer.** Any lower layer will do, not only the one just below.
- **Units in the same layer may not use each other.**
- **Every unit has a layer.** A new folder fails the check until a line lists it.
- **`Base` is on the bottom line.** See [Base](#base) below.

The bottom layer holds `Base` and the other folders that use none. The top two hold `Server` and then `(root)`, which wire the rest together. Where a unit sits is a design decision, so moving it is an edit to `scripts/daemon-layers.txt` that the reviewer sees in the diff.

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

A missed reference makes no link, so the check can pass code that uses a unit in its own layer or above. The order is the rule all the same.

### Links the check can report falsely

- **A member or nested type used bare, declared in another file.** A type's member or nested type declared in one file and used bare in the type's extension in another file reads as a reference to any other unit's top-level declaration of the same name. The check sees a member only in the file that declares it.
- **A subscript's argument label**, as in `cache[widgetLimit: 2]`, reads as a dictionary key.
- **A declaration's outer argument label** when the parameter has a separate inner name, as in `func f(widgetLimit limit: Int)`, and **the second and later labels of a compound name**, as in `run(fetch:widgetLimit:)` or `#selector(handle(_:widgetLimit:))`, read as references to a same-named declaration in another folder.
- **A force-unwrap glued to a division slash**, as in `a!/2`, reads as the start of a regex literal. It can stop the check with exit 2 ("unterminated string literal") or hide a reference later on that line. Write `a! / 2`.
- **A statement label after a `case` on its line**, as in `case .a: outer: for x in xs`, reads as a reference. A label that starts its line, or follows `{` or `;`, does not.
- **An uppercase name a pattern binds**, as in `case let .some(Widget)`. In a pattern the check binds only lowercase names, so that no type in it is taken for a binding.

A false link is a bug in the check. For a bare member, write `self.` before it, or `Self.` before a nested type or a static member; for anything else, fix the check and add the case to `scripts/lint-daemon-layers.test.sh`. Never move a unit to let a false link pass: the move would stand for every real reference in that direction too.

### Reading a failure

A reference against the order names the file, the line, the two units with their layers, and the name:

```
Sources/TBDDaemon/Keychain/ModelProfileKeychain.swift:253: Keychain (layer 1) uses Server (layer 9), a higher layer: RPCRouter is declared in Server
```

Line 253 of that file names `RPCRouter`, which Server declares, and Server is eight layers above Keychain. A reference within one layer says so:

```
Sources/TBDDaemon/Git/GitManager.swift:40: Git (layer 4) uses Tmux (layer 4), its own layer: TmuxManager is declared in Tmux
```

A unit with no layer is named with where it fits: the lowest layer above every unit it uses and below every unit that uses it.

```
scripts/daemon-layers.txt: Sandbox has no layer; it fits in layer 4
```

Units with no layer are placed together, as if each were listed, so one that another new unit uses goes below it. Where no layer is both above and below, the message says `it needs a new line between layers 3 and 4`, `it needs a new line at the top` or `it needs a new line at the bottom`. When new units that use each other need new lines between the same two layers, the user's message ends `above the line for <unit>`, or `above the lines for` several. Every layer number is the file's as it stands, before a new line goes in.

When no line can hold the unit, the message says `no layer fits it` and why:

- **`no layer fits it: it uses layer 4, and layer 4 uses it`**: no line is above the one and below the other.
- **`no layer fits it: layer 1 uses it, and Base stays on the bottom line`**: it would need a new line below `Base`. See [Base](#base).
- **`no layer fits it: its links run in a circle`**, then the circle: units with no layer that use each other, directly or through others.
- **`no layer fits it until one fits <unit>`**: its place depends on another unit with no layer that no layer fits, one it uses or one beside a circle.

In the first two, `uses it through <unit>` names a unit with no layer that the use from above runs through.

To make room, change a reference, or move the units involved to other lines so that every use points down; `Base` never moves. Moving one unit is often enough. A new `Sandbox` that uses `Tmux` and that `Git` uses fits no layer while both are in layer 4; moving `Git` up to the `Hooks, Remote` line lets `Sandbox` go on the `Claude, DevServers, Mock` line between them. Moving a unit holds it to its new place, as under "Move the using unit up" below.

### Fixing a reference against the order

- **Move the declaration** into the unit that uses it, or into a lower unit that both can use. Every folder is in one module, so moving a whole file with `git mv` changes no code.
- **Pass a closure or a protocol in** from the unit above, so the lower unit stops naming the higher one.
- **Move the using unit up** if the direction is right: take its name off its line and put it on a line above the unit it uses, or on a new line. The check then holds it to its new place, so no unit on its new line may use it, and every unit that uses it must sit above it. This is a design decision, and the reviewer sees it in the diff.

### Giving a unit a layer

Add the unit's name in the layer it fits in, or on the new line it needs, in the change that adds the folder. Where no layer fits it, make room first, as under "Reading a failure" above.

### Base

`Sources/TBDDaemon/Base` is the bottom folder.

- **Nothing in it uses another daemon folder.** Its code may use only `TBDShared`, `TBDKernel`, third-party and system modules.
- **It holds only code that two or more other folders use.** Code that one folder uses belongs in that folder.
- **Moving a declaration into `Base`** is the usual way to remove a reference to a unit above, when the declaration needs nothing outside `Base`. Its users then use `Base`, which sits below all of them.
- **`Base` stays on the bottom line** of `scripts/daemon-layers.txt`, where the check lets it use no other unit. Never move it up. If code in `Base` needs another folder, the code belongs in that folder or above it, or its caller passes a closure or a protocol in. While `Base` is on another line or none, the check fails with `Base is in layer 2; Base stays on the bottom line` or `Base has no layer; Base stays on the bottom line`, and judges nothing else until `Base` is back on the first line.
- **No line goes below `Base`.** So a unit with no layer that layer 1 uses fits no layer: `no layer fits it: layer 1 uses it, and Base stays on the bottom line`. Move the units in layer 1 that use it to a higher line, and list it beside `Base`. When `Base` itself uses it, change that reference instead: move what `Base` needs into `Base`, or pass a closure or a protocol in.

### When `main` fails

Branch protection does not require a branch to be up to date with `main` before it merges, so two pull requests that each pass alone can together leave `main` failing. Removing a reference never causes it, because the check asks only that each reference runs downward. Usually it takes a move: one change moves a unit to another line, a declaration to another folder, or every Swift file out of a folder, and the other adds a reference or a file that the old arrangement allowed. Every branch then fails on a reference or a unit its change never touched. The repair is a pull request of its own that fixes what the failure names, in one of the ways above.

### "cannot scan" and "cannot read"

Exit 2 means the check could not run. It stops rather than judge references it may have read wrong.

- **`cannot scan <file>:<line>`**: the check could not read that Swift. The reason is an unbalanced brace, a comment or literal that never closes, or bytes that are not UTF-8. The usual cause is an `#if` whose branches open different braces, such as two signatures sharing one body. Make each branch balance its own braces.
- **`cannot scan` without a line**: either `Sources/TBDDaemon: not found`, because the check ran against a tree without it (see `--repo-root`), or a file in a folder the layer file cannot name: one with a space or a comma in its name, or a `#` at its start, as in `the folder "A,B" has a comma in its name, so the layer file cannot name it`. Rename the folder.
- **`cannot read <path>`**: the check could not open that file or list that folder, for the reason that follows.
- **`cannot read scripts/daemon-layers.txt:<line>`**: a name on that line is no unit, is listed twice, is empty, or has a space in it, or the line holds bytes that are not UTF-8. A name that is no unit is a typo, or a folder renamed or emptied of Swift; a unit listed twice is named with its other line; an empty name is a stray comma, and a name with a space a missing one.

### Running it

- **`python3 scripts/lint-daemon-layers.py`** checks the tree.
- **`bash scripts/lint-daemon-layers.test.sh`** runs the check's harness on sample trees.

CI runs the check in the Lint job and the harness in the Script harnesses job. The Lint job runs the check under macOS's own `/usr/bin/python3`, Python 3.9, which is the `python3` the pre-push hook finds on a Mac without Homebrew; so the check must not use newer syntax.

The pre-push hook runs the check on every push from a branch that has it, even with `TBD_SKIP_PREPUSH_TESTS=1`. It checks the working tree, not the commits being pushed, so an untracked, half-written Swift file can block a push that does not include it. `git push --no-verify` skips the hook for that push.
