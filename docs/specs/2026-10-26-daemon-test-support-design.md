# Daemon test support: keep the app tests off the daemon library

## Problem

`TBDApp` imports no daemon code. Its first-party imports are `TBDShared`, `TBDAppIcon` and `TBDTerminalSerialization`. The test targets don't follow that graph:

- **`TestSupport` depends on `TBDDaemonLib`.** Only 4 of its files need it, 81 lines in all:
  - `ActuationLogTestSupport.swift` (`makeTestActuationLog`);
  - `ConfigDirTestSupport.swift` (`makeIsolatedConfigDirManager`);
  - `DatabaseRepoHelpers.swift` (`makeTestRepo`);
  - `WakeResultTestSupport.swift` (`WakeResult.isOk`).

  No app test uses any of them, while 154 daemon and live test files do. Every target that uses `TestSupport` still gets the daemon library.
- **`TBDAppTests` declares `TBDDaemonLib` for one suite.** `ReplayWriterRoundTripTests` feeds the daemon's replay bytes through a headless SwiftTerm `Terminal`. It imports `SwiftTerm` and `TBDDaemonLib`, but not `TBDApp`. It sits in the app tests only because that target once was the only one linking the SwiftTerm product.
- **`TBDHolderTests` links the daemon library for nothing.** It needs `collectOutput(of:)` from `TestSupport`, and the comment on that dependency in `Package.swift` says the daemon library comes along unused.

A test target that can reach a module its product cannot gives the wrong picture of the system, and it lets tests depend on daemon internals the app never sees.

There is a build-cost effect too. When a commit changes only `TBDDaemonLib`'s top-level declarations, Swift 6.3 recompiles every file that uses the module. In 10 such CI runs, the app tests recompiled a median of 222 files, and `TBDApp` recompiled none.

## Design

### Targets

- **`TestSupport`** stays generic. It depends on `TBDShared` and `Clocks` only.
- **`DaemonTestSupport`** is a new library target at `Tests/DaemonTestSupport`.
  - It holds the four files above, moved without changes to their code.
  - It depends on `TestSupport`, `TBDDaemonLib` and `TBDShared`.
  - It does not re-export `TestSupport`. A file that uses a daemon helper imports `DaemonTestSupport` itself, so each file's imports say what it uses.
- **`TBDDaemonTests`** adds `DaemonTestSupport` and the `SwiftTerm` product.
- **`TBDDaemonLiveTests`** adds `DaemonTestSupport`.
- **`TBDAppTests`** drops `TBDDaemonLib`.
- **`ReplayWriterRoundTripTests.swift`** moves from `Tests/TBDAppTests` to `Tests/TBDDaemonTests`.
  - Only its header comment changes.
  - It runs entirely in memory, so it belongs with the daemon tests, not the live tests.
- **`TBDHolderTests`** keeps its dependency list. It stops linking the daemon library because `TestSupport` no longer depends on it, and its comment in `Package.swift` says so.

### Guard

SwiftPM writes every module it builds into one shared search directory. A target can therefore import a module it doesn't declare, and the import compiles whenever that module happens to be built first. Without a guard, the boundary above can wear away unnoticed.

- **The check.** The CI `test` job's build step passes `--explicit-target-dependency-import-check error`. SwiftPM then fails the build when a target imports a first-party module that its `Package.swift` entry doesn't declare.
- **The build step only.** The option goes on that step, not in `CI_SWIFTPM_FLAGS`. It changes no compiled output, so the cache key stays as it is, and the test passes run with `--skip-build`.
- **It covers every target.** It catches drift in every other target too, not just this boundary. Where it finds an existing violation, the fix is to declare the real dependency or to drop the unused import.
- **The fallback.** If the option has no effect on Swift 6.3, a shell check in the `lint` job takes its place. That check fails when any file under `Tests/TBDAppTests` or `Tests/TestSupport` imports `TBDDaemonLib`. "No effect" means that the deliberate stray import described under Verification still builds.

### Documentation

These say where a moved helper or test lives, or why a target depends on the daemon library, and are updated:
- `CLAUDE.md`, which points to `makeIsolatedConfigDirManager(tag:)` "in `TestSupport`";
- the comments on `TBDAppTests` and `TBDHolderTests` in `Package.swift`.

`docs/research/2026-08-19-cold-build-split/findings.md` describes the target graph as it was measured then, and stays as it is.

## Verification

- **The guard bites.** A throwaway `preflight/` branch adds `import TBDDaemonLib` to one file in `Tests/TBDAppTests`. Its CI build must fail with the import check's error. The branch is never merged, and it is deleted afterwards.
- **No test is lost.** Each CI pass runs the same suites before and after. `ReplayWriterRoundTripTests` runs in the pass that covers `TBDDaemonTests`, and no pass filter in `test.yml` names it under its old target.
- **The required `test` job passes** with the import check enabled.

## Out of scope

- **`TBDDaemonLiveTests` keeps its dependency on `TBDApp`.** `TmuxBridgeViewSessionLiveTests` drives the app's `TmuxBridge` against a real tmux server. That is a real app-to-daemon integration test, and it goes away with the tmux transport.
- **The SwiftPM #7715 clean-up** in `test.yml` treats `DaemonTestSupport` as it treats `TestSupport`, which it does not clean. Whether test-support targets join that list is a separate decision.

## Rejected alternatives

- **Keep the name `TestSupport` for the daemon helpers, and move the generic files to a new target below it.** This touches fewer files (55 app and holder test files instead of 154 daemon and live ones). But the generic name would then label the daemon-specific target, and the misleading name would outlive the migration.
- **Put the helpers straight into the test targets.** This needs no new target. But the two helpers that the live tests also use would then exist twice.
- **Only a lint check for this one boundary.** It is simple and certain. But it guards one edge, while the SwiftPM check guards every target's declared dependencies. It stays as the fallback.
- **No guard.** The boundary would then rest on an import that happens to fail, and it would wear away unnoticed.
