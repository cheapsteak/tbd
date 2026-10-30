# Daemon layer order: a direction for references between the daemon's folders

## Problem

`TBDDaemonLib` is one SwiftPM module of about 118,000 lines, in 27 folders under `Sources/TBDDaemon` plus a few files at its root. One module is the right shape for it, because most features cut across folders. But nothing says which folder may use which, and the folders have grown into one knot:

- **One cycle holds 24 of the 31 units** that the scan counted. The scan treated each folder and each root file as a unit. Every folder in that cycle can reach every other by following references. Only Keychain, Diagnostics, Update, SSH and three root files stand outside it.
- **About 27 thin links hold the cycle together.** Each has 8 or fewer references in 3 or fewer files, 74 references in all. No single link, if removed, breaks the cycle.
- **Links are growing.** In July the folders had 50 links between them, and now they have 147. 11 of the 27 thin links appeared after 1 September.

These counts come from a compiler-free scan of commit `ab1c98065`.

With no direction, a reader can't tell which folders are foundations and which are top-level wiring. A change to a low-level folder can also need code from any folder. The usual fix, a module per folder, is wrong here: the folders change together too often, and every folder's API would need `public`.

## Design

The daemon stays one module. A lint check gives the folders a direction, in three stages: freeze today's links, break the cycle, then enforce a written layer order.

### Units

- Each folder directly under `Sources/TBDDaemon` is one unit. Its subfolders belong to it, so `PR/Schedule` counts as `PR`.
- The root files form one unit, the composition root: `Daemon.swift`, `DaemonHandover.swift`, `PIDFile.swift`, and any root file added later. `main.swift` belongs to the `TBDDaemon` executable target, and the check skips it.
- Tests are out of scope. A test may use any folder.

### The check

`scripts/lint-daemon-layers.py` runs in the `lint` CI job and in the pre-push hook, like `scripts/lint-migrations.py`. It needs no build, and it scans the whole daemon in about 2 s.

- **The index.** It reads every Swift file in the library and indexes each unit's top-level declarations that are not `private` or `fileprivate`: types, typealiases, top-level functions and globals. Names declared in an extension count as the extended type's.
- **A reference.** A file in unit A references unit B when it names a declaration from B's index. It does not count a name that follows a `.`, an argument label, or a name in a comment or a string. It does count code inside a string's interpolation, an extension on B's type, and a conformance to B's protocol.
- **Blind spots.** The check matches names, not types:
  - A member reached through a value whose type is inferred is invisible, as in `db.terminals.setStartHeld()`.
  - So is a member that another folder's extension adds.
  - So is an implicit `.case` or `.init(...)` whose type comes from context.
  - So is a name that the file itself also declares, such as a local variable or a parameter with the same name. The check reads the name as the file's own.
  - So is a call to an overloaded function that the calling folder also declares under the same name.

  The index is rebuilt from the source on every run, so it can't go out of date.
- **Output.** For each failure it names the file, the line, the name and the link. It also points to the ways to fix a failure, which `Sources/TBDDaemon/CLAUDE.md` describes.
- **Its harness.** `scripts/lint-daemon-layers.test.sh` runs in CI's `script-harnesses` job, with the repo's other harnesses that need only bash, git and Python. It builds small sample trees and shows two things:
  - the check catches each kind of reference above;
  - it ignores comments, strings, names after a `.`, argument labels, raw strings and a regex literal.

  Each case runs both ways: the sample with the reference fails the check, and the same sample without it passes.

### Stage 1: freeze today's links

The check ships with `scripts/daemon-links.txt`, which lists every link the daemon has today, one `A -> B` per line, sorted.
- **A new link fails the check** unless the same change adds it to the list. A reviewer then sees the new link in the diff.
- **A listed link that no code uses fails the check as stale.** So a link removed from the code leaves the list in the same change, and the list can only shrink.

### Stage 2: break the cycle

A few PRs, each grouped by the kind of change, remove links until the check finds no cycle among those left. Each PR deletes its links from `scripts/daemon-links.txt`. The check reports any cycle left in the list, and stage 2 ends when it reports none.

A simulation of these moves on the scanned commit left no cycle and 130 links. It is the starting plan. The plan re-runs the scan, and a link that resists comes back as a design question.

- **Files in the wrong folder move with `git mv`.** Every folder is in one module, so a move changes no code. About 18 files move in all. These 12 go to the folder that uses them:
  - into **Server**: `RPCRouter+Actuation.swift`, `RPCRouter+StartAdmission.swift`;
  - into **Actuation**: `DeliveryVerificationArming.swift`, which joins its only conformer;
  - into **Lifecycle**: `ActuationOutcome+Park.swift`, `ActuationOutcome+TransportMigration.swift`, `RemoteTipTracker.swift`;
  - into **Claude**: `ClaudeStateDetector.swift`, `ClaudeExecutableResolver.swift`;
  - into **PR**: `GitPollingPolicy.swift`;
  - into **Process**: `BoundedProcessRunner.swift`;
  - into the **root**: `Daemon+ModChannel.swift` and `AgentBackgroundRoots.swift`, which are wiring that only the root uses.
- **A new bottom folder, `Base`.** It takes the other moved files, and some single declarations. All of it is code that several folders use, and that uses no other daemon folder:
  - `StateSubscriptionManager`, `ShutdownLatch` and `WorktreeLayout`;
  - `ContinuationGuard`, `SocketFileIdentity` and the socket-binding helper that `SocketServer` and the mod channel share;
  - `ShadowPeerPermissionClass`, the mod-channel token, `RepoTOML` and `SessionModSpawn`;
  - `shellEscape` and `sleepThroughGatedInterval`.

  The rule for `Base` is in its name: nothing in it may use another daemon folder. It holds only code that two or more folders use.
- **Declarations in the wrong file move** to the folder that owns them:
  - `PipeDataAccumulator` goes to Process.
  - `PRUndeterminedCause` goes to Database.
  - `withWorktreeServerLock(db:)` goes to Lifecycle, because it throws Lifecycle's error.
  - The `TmuxManager: TmuxProcessQuerying` conformance goes to Tmux.
- **Seams.** Where a lower folder must call a higher one, the higher one passes in a closure or a protocol:
  - Tmux's control-mode bridge stops naming `FDVendingServer`.
  - Remote stops naming PR's `ProviderPRBinder`, which it already receives through a setter.
  - Database gets its own logger instead of Remote's `claudeCloudLogger`.
  - Database stops calling Claude's `ClaudeUsagePayloadParser`; the predicate it needs moves lower.

None of these changes behaviour. The existing tests cover the code they touch.

### Stage 3: the layer order

The last PR replaces `scripts/daemon-links.txt` with `scripts/daemon-layers.txt`, which lists the layers from bottom to top, one line per layer.
- **A unit may use only units in a lower layer.** Units in the same layer may not use each other.
- **Every unit must be listed.** A new folder fails the check until it has a layer.
- **Moving a unit up is a one-line edit** that a reviewer sees. That is how a new link between two units in the same layer gets made.

The simulated order, from the bottom:
1. Base, Diagnostics, Keychain, SSH, Update
2. AskUserQuestion, Database, Process, SessionMod
3. Actuation, Codex, Git, ModChannel, ModelProfile, PanelSurface, ProgramStatus, StartAdmission, Tmux
4. Claude, Holder, Mock
5. DevServers, Hooks, Remote
6. Lifecycle
7. GC, PR
8. Server
9. the root

Stage 2's PRs may shift a unit by a layer. The file holds whatever order the code has when stage 2 ends.

### Documentation

`Sources/TBDDaemon/CLAUDE.md` gains a section on the layers. Each stage writes the part it introduces, so the section always describes the check as it runs:
- **Stage 1:** what a unit is, the frozen list, stale entries, and how to read a failure and fix it: move the declaration lower, or pass in a closure.
- **Stage 2:** the rule for `Base`.
- **Stage 3:** the layer rule, and where the order lives.

## The holder client stays a folder

A related change would move `Sources/TBDDaemon/Holder` into a module of its own, with its links up into the rest of the daemon passed in. It waits, for these reasons:
- **Its upward links are few:** about 45 sites, to Process, ProgramStatus, Database and Tmux. Stage 2 already points them all downward, and stage 3 holds that direction.
- **The module would cost a lot.** It would need about 100 `public` declarations for the daemon to use it. It would also need about 90 files to change their imports: 22 source files and about 70 test files.
- **Its API isn't stable yet.** Of the 40 commits that touched `Holder/` since 1 September, 34 also touched another daemon folder, mostly Server or Lifecycle. Most holder changes would therefore change the module's public API.
- **Removing tmux doesn't change this.** It would cut none of Holder's upward links.

**When to look again:** when, over 30 days, fewer than half of the commits that touch `Holder/` also touch Server or Lifecycle. Or when a second program needs the holder client. Either one calls for a new design with fresh numbers.

## Verification

- **Stage 1.**
  - The check passes on the tree it ships with.
  - On a throwaway `preflight/` branch, adding a new upward reference fails the `lint` job and names that reference. The branch is never merged.
  - Removing a link's last reference without removing its line from the list fails the check as stale.
- **Stage 2.**
  - Each PR passes the check, the required `test` job and the `lint` job.
  - Each PR's diff of `scripts/daemon-links.txt` only removes lines.
  - After the last PR, the check reports no cycle.
- **Stage 3.**
  - The check passes with `scripts/daemon-layers.txt`.
  - On a throwaway branch, an upward reference fails, a reference between two units in the same layer fails, and a new unlisted folder fails.
- **The harness** passes in CI at every stage.

## Out of scope

- **Tests and `main.swift`.**
- **A module for the holder client,** for the reasons above.
- **Module splits elsewhere.** Store, RPC and others are not part of this change.

## Rejected alternatives

- **Break the cycle and add the layer order in one PR.** It means fewer PRs, but the diff is large in Server and Lifecycle, the two busiest folders (209 and 122 commits since July). It would collide with open branches, and it would leave the daemon unguarded until it merged.
- **Freeze only.** This stops new links, but it sets no direction, and the cycle stays.
- **A few coarse layers.** Only links that cross a layer upward would be forbidden. The folders inside a layer could still knot together.
- **Generated SwiftLint rules.** Generating one rule per folder with every name that folder may not use flags the same lines. But it adds about 185 KB to `.swiftlint.yml`, four times its size, and the rules go stale whenever a declaration moves. CI would then need a separate check that they are current.
- **A module per folder.** The compiler would hold the direction exactly, but every folder's API would need `public`, and the folders change together too often.
