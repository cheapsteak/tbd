# Daemon test support: keep the app tests off the daemon library

## Problem

`TBDApp` imports no daemon code. Its first-party imports are `TBDShared`, `TBDAppIcon` and `TBDTerminalSerialization`. The test targets don't follow that graph:

- **`TestSupport` depends on `TBDDaemonLib`.** Only 4 of its files need it, 81 lines in all:
  - `ActuationLogTestSupport.swift` (`makeTestActuationLog`);
  - `ConfigDirTestSupport.swift` (`makeIsolatedConfigDirManager`);
  - `DatabaseRepoHelpers.swift` (`makeTestRepo`);
  - `WakeResultTestSupport.swift` (`WakeResult.isOk`).

  No app test uses any of them, while 154 daemon and live test files do. Every target that uses `TestSupport` still depends on the daemon library.
- **`TBDAppTests` declares `TBDDaemonLib` for one suite.** `ReplayWriterRoundTripTests` feeds the daemon's replay bytes through a headless SwiftTerm `Terminal`. It imports `SwiftTerm` and `TBDDaemonLib`, but not `TBDApp`, so nothing in it needs the app.
- **`TBDHolderTests` depends on the daemon library for nothing.** It needs `collectOutput(of:)` from `TestSupport`, and the comment on that dependency in `Package.swift` says the daemon library comes along unused.

A test target that can reach a module its product cannot gives the wrong picture of the system, and it lets tests depend on daemon internals the app never sees.

There is a build-cost effect too. When a commit changes only `TBDDaemonLib`'s top-level declarations, Swift 6.3 recompiles every file that uses the module. In 10 such CI runs, the app tests recompiled a median of 222 files, and `TBDApp` recompiled none.

The change is to what each target compiles against. On macOS, SwiftPM links all test targets into one test bundle, so the test process still contains the daemon library.

## Design

### Targets

- **`TestSupport`** stays generic. It depends on `TBDShared` and `Clocks` only.
- **`DaemonTestSupport`** is a new library target at `Tests/DaemonTestSupport`.
  - It holds the four files above, moved without changes to their code.
  - It depends on `TBDDaemonLib` and `TBDShared`, which is all the four files use.
  - A file that uses a daemon helper imports `DaemonTestSupport` itself, so each file's imports say what it uses.
  - It joins the SwiftLint scope in the same way as `TestSupport`, so the moved files are still linted.
- **`TBDDaemonTests`** adds `DaemonTestSupport`. It also declares the `SwiftTerm` product. It already reaches SwiftTerm through `TBDDaemonLib`, but its tests use SwiftTerm directly, as the live tests do, and the manifest says so.
- **`TBDDaemonLiveTests`** adds `DaemonTestSupport`.
- **`TBDAppTests`** drops `TBDDaemonLib`.
- **`ReplayWriterRoundTripTests.swift`** moves from `Tests/TBDAppTests` to `Tests/TBDDaemonTests`.
  - Only its header comment changes.
  - It runs entirely in memory, so it belongs with the daemon tests, not the live tests.
- **`TBDHolderTests`** keeps its dependency list. It doesn't depend on the daemon library, because `TestSupport` doesn't.
  - Its comment in `Package.swift` says so.
  - Its own copy of the scratch-root helper existed only to keep `TestSupport` out. It calls `fencedScratchRoot(prefix:)` from `TestSupport` instead.

### Guard

SwiftPM writes every module it builds into one shared search directory. A target can therefore import a module it doesn't declare, and the import compiles whenever that module happens to be built first. Without a guard, the boundary above can wear away unnoticed.

- **The check.** The CI `test` job's build step passes `--explicit-target-dependency-import-check error`. Before it compiles, SwiftPM pre-scans each target's imports. The build fails when a target imports a module of the package graph that its dependencies don't reach.
- **It counts the whole dependency tree.** A target may import anything its dependencies reach, not only what its own `Package.swift` entry lists. For example, `TBDAppTests` may import `TBDShared` because `TBDApp` depends on it.
- **What it holds here.** After the change, nothing that `TBDAppTests` or `TestSupport` depends on reaches `TBDDaemonLib`, so importing it fails the build. Adding the dependency back in `Package.swift` would pass the check, but that is a manifest change that a reviewer sees.
- **The build step only.** The option goes on that step, not in `CI_SWIFTPM_FLAGS`. It changes no compiled output, so the cache key stays as it is, and the test passes run with `--skip-build`.
- **It covers every target.** It checks every target's imports, not just this boundary, and third-party modules as well as first-party ones. A scan of every TBD target's imports against its dependency tree finds no import that breaks it today.
- **It checks dependency packages too.** SwiftPM scans every target it builds, including the targets of third-party packages. A dependency update that brings a target importing a module its own dependencies don't reach therefore fails the build. The check's message names that target, so the cause is clear.
- **It is best-effort.** SwiftPM skips the check without a message when the compiler has no import pre-scan. It also stops checking when the pre-scan of one target fails, and it visits targets in an order that changes from run to run. A green build therefore doesn't prove that the check ran. The verification below is what proves it.
- **The fallback.** If the option has no effect on Swift 6.3, a check in the `lint` job takes its place. That check fails when any file under `Tests/TBDAppTests` or `Tests/TestSupport` imports `TBDDaemonLib`. "No effect" means that a deliberate stray import described under Verification still builds in any verification run.

### Documentation

These say where a moved helper or test lives, or why a target depends on the daemon library, and are updated:
- `CLAUDE.md`, which points to `makeIsolatedConfigDirManager(tag:)` "in `TestSupport`";
- the comments on `TBDAppTests` and `TBDHolderTests` in `Package.swift`;
- the comment in `scripts/restart.sh` that names the target holding `@testable import TBDDaemonLib`.

`docs/research/2026-08-19-cold-build-split/findings.md` describes the target graph as it was measured then, and stays as it is.

## Verification

- **The guard bites.** A throwaway `preflight/` branch adds `import TBDDaemonLib` to one file in `Tests/TBDAppTests` and to one file in `Tests/TestSupport`.
  - Its CI build must fail with the import check's error for both targets, on two separate runs. Two runs, because the order in which SwiftPM visits targets changes from run to run.
  - The branch is never merged, and it is deleted afterwards.
- **No test is lost.** Each CI pass runs the same suites before and after. `ReplayWriterRoundTripTests` runs in the pass that covers `TBDDaemonTests`, and no pass filter in `test.yml` names it under its old target.
- **The required `test` job passes** with the import check enabled.

## Out of scope

- **`TBDDaemonLiveTests` keeps its dependency on `TBDApp`.** `TmuxBridgeViewSessionLiveTests` drives the app's `TmuxBridge` against a real tmux server. That is a real app-to-daemon integration test, and it goes away with the tmux transport.
- **The SwiftPM #7715 clean-up** in `test.yml` treats `DaemonTestSupport` as it treats `TestSupport`, which it does not clean. Whether test-support targets join that list is a separate decision.

## Rejected alternatives

- **Keep the name `TestSupport` for the daemon helpers, and move the generic files to a new target below it.** This touches fewer files (57 app and holder test files instead of 154 daemon and live ones). But the generic name would then label the daemon-specific target, and the misleading name would outlive the migration.
- **Put the helpers straight into the test targets.** This needs no new target. But the two helpers that the live tests also use would then exist twice.
- **Only a lint check for this one boundary.** It is simple and certain. But it guards one edge, while the SwiftPM check covers every target's imports. It stays as the fallback.
- **No guard.** The boundary would then rest on an import that happens to fail, and it would wear away unnoticed.
