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

SwiftPM writes every module it builds into one shared search directory. A target can therefore import a module it doesn't declare, and the import compiles whenever that module happens to be built first. Without a guard, the boundary above can wear away unnoticed. Two checks hold it.

**A SwiftLint rule holds this boundary.**
- The custom rule `no_daemon_import_in_app_tests` fails when a file under `Tests/TBDAppTests` or `Tests/TestSupport` imports `TBDDaemonLib`, in any import form.
- It matches code only, so a comment or string that mentions the import doesn't trip it.
- It runs in the `lint` job and the pre-push hook, like the repo's other custom rules.
- It holds even if someone adds the dependency back in `Package.swift`, which the SwiftPM check below would accept.

**SwiftPM's import check guards the targets it can see.**
- **What it does.** The CI `test` job's build step passes `--explicit-target-dependency-import-check error`. Before it compiles, SwiftPM pre-scans each target's imports. The build fails when a target imports a module of the package graph that its dependencies don't reach.
- **It counts the whole dependency tree.** A target may import anything its dependencies reach, not only what its own `Package.swift` entry lists. For example, `TBDSharedTests` may import anything `TBDShared` depends on.
- **It skips any target that reaches a build plugin.** SwiftPM counts a plugin that a target uses as one of that target's dependencies, and it skips every target whose dependency tree holds a plugin. SwiftTerm's library uses a build plugin. So the check skips every target that reaches SwiftTerm: `TBDApp`, `TBDAppTests`, `TBDTerminalSerialization`, `TBDDaemonLib`, `TBDDaemon`, `DaemonTestSupport`, `TBDDaemonTests` and `TBDDaemonLiveTests`. That is why the app tests need the lint rule. A CI run with a stray import in both an app test and `TestSupport` reported only `TestSupport`.
- **What it covers.** It covers the other 12 Swift targets: `TestSupport`, `TestProcessDefaults`, `TBDShared`, `TBDHolder`, `TBDPeerHelper`, `TBDCLI`, `TBDAppIcon`, `IconBaker`, and the shared, holder, peer-helper and CLI tests. No import in them breaks it today. It also guards the holder and the peer helper against reaching into the daemon.
- **It checks dependency packages too.** SwiftPM scans every target it builds, including the targets of third-party packages. A dependency update that brings a target importing a module its own dependencies don't reach therefore fails the build. The check's message names that target, so the cause is clear.
- **The build step only.** The option goes on that step, not in `CI_SWIFTPM_FLAGS`. It changes no compiled output, so the cache key stays as it is, and the test passes run with `--skip-build`.
- **It costs about 3 s per build.** On this change's CI run, SwiftPM took 3.3 s from planning the build to its first plugin compile. On three recent `main` runs without the check, the same gap was 0.1 to 0.2 s.
- **It is best-effort.** SwiftPM skips the check without a message when the compiler has no import pre-scan. It also stops checking when the pre-scan of one target fails, and it visits targets in an order that changes from run to run. A green build therefore doesn't prove that the check ran. The verification below is what proves it.

### Documentation

These say where a moved helper or test lives, or why a target depends on the daemon library, and are updated:
- `CLAUDE.md`, which points to `makeIsolatedConfigDirManager(tag:)` "in `TestSupport`";
- the comments on `TBDAppTests` and `TBDHolderTests` in `Package.swift`;
- the comment in `scripts/restart.sh` that names the target holding `@testable import TBDDaemonLib`.

`docs/research/2026-08-19-cold-build-split/findings.md` describes the target graph as it was measured then, and stays as it is.

## Verification

- **The guards bite.** A throwaway `preflight/` branch adds `import TBDDaemonLib` to one file in `Tests/TBDAppTests` and to one file in `Tests/TestSupport`.
  - The `lint` job must fail, with the SwiftLint rule naming both files.
  - The CI build must fail with the import check's error for `TestSupport`, on two separate runs. Two runs, because the order in which SwiftPM visits targets changes from run to run.
  - The branch is never merged, and it is deleted afterwards.
- **No test is lost.** Each CI pass runs the same suites before and after. `ReplayWriterRoundTripTests` runs in the pass that covers `TBDDaemonTests`, and no pass filter in `test.yml` names it under its old target.
- **The required `test` job and the `lint` job pass** with both checks enabled.

## Out of scope

- **`TBDDaemonLiveTests` keeps its dependency on `TBDApp`.** `TmuxBridgeViewSessionLiveTests` drives the app's `TmuxBridge` against a real tmux server. That is a real app-to-daemon integration test, and it goes away with the tmux transport.
- **The SwiftPM #7715 clean-up** in `test.yml` treats `DaemonTestSupport` as it treats `TestSupport`, which it does not clean. Whether test-support targets join that list is a separate decision.

## Rejected alternatives

- **Keep the name `TestSupport` for the daemon helpers, and move the generic files to a new target below it.** This touches fewer files (57 app and holder test files instead of 154 daemon and live ones). But the generic name would then label the daemon-specific target, and the misleading name would outlive the migration.
- **Put the helpers straight into the test targets.** This needs no new target. But the two helpers that the live tests also use would then exist twice.
- **Only the SwiftLint rule.** It holds this boundary on its own. But the SwiftPM check also guards 12 other targets, among them the holder and the peer helper, for about 3 s per build.
- **Only SwiftPM's import check.** It can't see the app tests, because they reach SwiftTerm's build plugin.
- **No guard.** The boundary would then rest on an import that happens to fail, and it would wear away unnoticed.
