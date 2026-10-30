# Helper kernel: a module the helper programs depend on alone

## Problem

TBD ships two small helper programs beside the daemon:
- **`TBDHolder`** owns one terminal session's pty and outlives the daemon that started it, `tbd update` included ([`2026-08-30-pty-holder-session-transport-design.md`](2026-08-30-pty-holder-session-transport-design.md)).
- **`TBDPeerHelper`** publishes one shadow peer's registry record and socket, and exits when its stdin closes ([`2026-08-29-remote-peer-messaging-design.md`](2026-08-29-remote-peer-messaging-design.md)).

Both depend on `TBDShared`, the module every TBD target depends on. It holds the RPC protocol, the models, the constants and 77 files in all. The helpers and their tests use 9 of those files and 3 members of `TBDConstants`. That has two costs:

- **A wrong picture.** The holder's wire contract must stay compatible with every holder version ever shipped. It sits among files that change freely, in a module that doesn't show which declarations are frozen.
- **Build time.** Swift 6.3 gives each module one fingerprint for all its top-level declarations, so a new or changed top-level declaration anywhere in `TBDShared` recompiles both helpers and their tests. Since 2026-07-01, 211 commits changed `TBDShared` files outside the 9, against 12 that changed the 9, most of those 12 by creating them.

The holder tests also reach `TBDShared` through `TestSupport`. Two of its files use `TBDShared`, and only the daemon tests use those two.

## Design

### The module

`TBDKernel` is a new library target at `Sources/TBDKernel`. It depends on no other module. These files move into it with `git mv`, and their code doesn't change except as noted:
- **The holder's wire contract:** `HolderProtocol.swift`, `HolderFraming.swift`, `HolderRendezvous.swift` and `HolderLock.swift`.
- **`FDChannel.swift`**, without `FDVendHeader`. That type describes descriptors that the daemon vends to the app over the sidecar, not to a helper. It moves to a file of its own in `TBDShared`.
- **The peer helper's formats:** `PeerBridgeFrame.swift` and `ShadowPeerRecord.swift`.
- **Process helpers:** `ProcessStartTime.swift` and `CloseOnExecPipe.swift`. `ProcessStartTime.startTime(of:)` becomes `package`, because `ProcessTableSnapshot` in `TBDShared` calls it. The `package` keyword makes it visible inside this package only.
- **`KernelPaths`**, a new type with the three paths the kernel needs:
  - `configDir(environment:)`, `holdersDir(environment:)` and `claudeHostHome(environment:)` move from `TBDConstants`, unchanged.
  - They use only Foundation, and `holdersDir` calls only `configDir`.
  - `HolderRendezvous` and `ShadowPeerRecord` call `KernelPaths` instead of `TBDConstants`.
  - `TBDConstants` keeps all three members, and each forwards to `KernelPaths`. So the logic exists once, and the roughly 40 other `TBDConstants` members that call `configDir`, and every caller outside, stay as they are.

These stay in `TBDShared`:
- **`BuildIdentity`.** Only `TBDConstants.buildIdentityFile(inAppBundle:)` uses it, and the helpers don't need that member.
- **`TerminalScreen`, `ViewerScreenPayload`, `SidecarFraming`, `HolderInputTiming` and `HolderDescentIndex`.** The daemon's holder client uses them, but the holder program doesn't.

### What may go into the kernel

`Sources/TBDKernel/CLAUDE.md` states three rules:
- **A declaration goes into the kernel only if a helper program needs it,** directly or through another kernel declaration. Everything else goes into `TBDShared`.
- **The kernel depends on no other module,** first-party or package.
- **The wire shapes stay byte-identical.**
  - For the holder, these are the Codable names and shapes, the rendezvous directory and file names, `sunPathLimit` and the busy sentinel. The daemon must work with every holder version that has ever shipped, as the transport spec's protocol section says.
  - For the peer helper, Claude Code's side fixes `PeerBridgeFrameCodec.peerProtocol` and the shape of the shadow peer record.

### Targets

- **`TBDKernel`:** no dependencies.
- **`TBDShared`:** `TBDKernel`.
- **`TBDHolder` and `TBDPeerHelper`:** `TBDKernel` only. Their comments in `Package.swift` say why.
- **`TBDKernelTests`:** a new test target that depends on `TBDKernel`.
- **`TBDHolderTests`:** `TBDHolder`, `TBDKernel` and `TestSupport`.
- **`TBDPeerHelperTests`:** `TBDPeerHelper` and `TBDKernel`.
- **`TestSupport`:** `Clocks` only.
  - `SidecarTestSupport` (`SidecarFrameHelpers.swift`) and `TmuxExecutableTestFixture` move to `DaemonTestSupport`, which gains `TBDKernel`.
  - Only the daemon and live tests use these two.
- **Every other target** that ends up with a file importing `TBDKernel` lists it among its dependencies. Examples are `TBDDaemonLib`, `TBDApp`, `TBDCLI` and the daemon test targets.
  - SwiftPM's import check doesn't require this, because it counts the whole dependency tree.
  - The rule is the one `DaemonTestSupport` set: the manifest says what a target uses directly.

### Imports

Each file that names a kernel declaration adds `import TBDKernel`, whether the declaration is a type or a member such as `Pipe.closeOnExec()`.
- **About 100 files:**
  - 25 daemon source files;
  - 61 daemon and live test files;
  - a few files in the app, the CLI, `TBDShared` and their tests.
- **Why one line per file:**
  - Swift doesn't make a top-level name visible through an indirect import.
  - The import line also marks each file that touches the helpers' contract.

### Tests

- **Seven test files move.** These `TBDSharedTests` files test moved code: `CloseOnExecPipeTests`, `HolderLockTests`, `HolderProtocolTests`, `HolderRendezvousTests`, `PeerBridgeFrameTests`, `ProcessStartTimeFormatTests` and `ShadowPeerRecordTests`.
  - Each one moves to `Tests/TBDKernelTests` if it uses no other `TBDShared` declaration.
  - A file that does use one stays in `TBDSharedTests` and imports `TBDKernel`.
- **`ShadowPeerRecordTests` reaches internal members** (`temporaryURL(for:)`, `directoryPermissions`), so it uses `@testable import TBDKernel`.
- **The holder test files change their import.** They use `@testable import TBDShared` but reach no internal member, so they switch to a plain `import TBDKernel`.
- **`ConstantsTests` stays in `TBDSharedTests`,** where it tests the paths through `TBDConstants`. It covers the `configDir` and `claudeHostHome` forwarding today, and it gains a check for `holdersDir`.
- **`TestHolderSupport.swift` calls `KernelPaths.holdersDir`** instead of `TBDConstants.holdersDir`, because the holder tests no longer reach `TBDShared`.
- **The tests move between targets but stay in the same CI pass.** `TBDKernelTests` runs in the app pass, like `TBDSharedTests`, because that pass runs every target except the two daemon test targets. The number of tests in each pass doesn't change.
- **No CI filter names a moved suite.** The flake tools' fixtures name `TBDSharedTests.HolderLockTests` as sample data, and they stay as they are.

### The guard

- **SwiftPM's import check.** The CI build step runs SwiftPM with `--explicit-target-dependency-import-check error`. That check covers `TBDKernel`, `TBDKernelTests`, both helpers, their tests and `TestSupport`, because none of them reaches SwiftTerm's build plugin.
  - A helper file that imports `TBDShared` fails the build, because `TBDShared` is not in the helper's dependency tree.
  - So does a `TestSupport` file that imports it.
- **What the check can't see.** It doesn't catch a manifest edit that adds `TBDShared` back to a helper's dependencies. That edit shows in the `Package.swift` diff, beside a comment that says why the list is `TBDKernel` alone, and review holds it.

### CI and scripts

- **The SwiftPM #7715 wipe.** `Sources/TBDKernel` joins `WIPE_PATHS` in `scripts/ci/first-party-wipe-needed.sh`. It also joins the matching path list in `test.yml`'s cache-save decision step. `TBDKernel` joins the module loop of the wipe step.
  - Why: it is a first-party library that `TBDShared` depends on. A symbol added to it is the change that #7715 breaks on, and a change to it recompiles every module above it.
  - `first-party-wipe-needed.test.sh` and `cache-save-policy.test.sh` already check that those lists agree.
- **SwiftLint.** The custom rules that select `Sources` targets by path also cover `Sources/TBDKernel`, so the moved files are linted exactly as before. A rule that excludes `Constants.swift` also excludes `KernelPaths.swift`, because the three paths moved from one to the other.
- **Comments.** The comment in `scripts/restart-bundle-lib.sh` that says the helpers depend on `TBDShared` alone changes to name `TBDKernel`.
- **The `tbd-project` skill.** Its `file-map.md` lists the moved files under a new `Sources/TBDKernel/` section.

## Verification

- **The guard bites.** A throwaway `preflight/` branch adds `import TBDShared` to one file in `Sources/TBDHolder`.
  - The CI build must fail with the import check's error for `TBDHolder`, on two separate runs. It must be two runs, because SwiftPM visits targets in an order that changes from run to run.
  - The branch is never merged, and it is deleted afterwards.
- **The wire doesn't change.**
  - The moved protocol, framing, rendezvous, lock and record tests pass with only their imports changed.
  - Moving a type to another module changes its Swift type name. No moved file passes a type name to the wire: none uses `String(describing:)`, `String(reflecting:)`, `type(of:)` or an archiver.
- **No test is lost.** Each CI pass runs the same number of tests before and after.
- **The required `test` job and the `lint` job pass.**

## Out of scope

- **The daemon's holder client** (`Sources/TBDDaemon/Holder`) stays in `TBDDaemonLib`. The daemon layer-order spec of the same date records why it doesn't become a module yet, and when to look again.
- **The CLI keeps its dependency on `TBDShared`.**

## Rejected alternatives

- **Re-export the kernel from `TBDShared` with `@_exported import`.** One line would replace about 100 imports. But `@_exported` is an underscored, unofficial attribute that the repo doesn't use, and no file would then show that it uses the kernel.
- **Declare `TBDConstants` in the kernel, and keep the rest of it as an extension in `TBDShared`.** Then every file that uses `TBDConstants` would need to import the kernel just to name the type. That is 21 app files, files in 17 daemon folders, and most test targets.
- **Move all of `Constants.swift`, with `BuildIdentity`.** That brings about 850 lines of app and daemon paths into a module meant to hold only what the helpers need.
- **A kernel for the holder alone.** The peer helper would then still depend on all of `TBDShared`, or it would need a second small module.
- **A check that the helpers' dependency lists name `TBDKernel` alone.** It guards an edit that is already visible in the manifest diff, while the import check already blocks a stray import.
