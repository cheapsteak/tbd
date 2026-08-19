# Cold-build cost, split between the core and app halves of the package

**Status:** Measured; no package split undertaken
**Measured:** 2026-08-19 against commit `e46be723`, on a 12-core macOS machine

TBD is one SwiftPM package. A recurring proposal is to cut it in two — a core
package holding `TBDShared`, `TBDDaemonLib`, `TBDDaemon` and `TBDCLI`, and an
app package holding `TBDApp` and its user-interface dependency stack — on the
theory that a contributor working on the daemon would then stop paying for
SwiftTerm, MarkdownUI and Highlightr. This document records what a cold build
of the whole package actually costs, target by target, so that proposal can be
judged against measurements rather than intuition.

## Summary

A cold build compiles for **327.9 s** at `--jobs 8`. The core half accounts for
**229.8 s (70.1%)** and the app half for **98.1 s (29.9%)**.

The split the proposal would deliver is therefore a saving on the *app* side —
a core-only contributor stops paying roughly 98 s per cold worktree — and it is
the smaller of the two halves. It is also the only saving available: `TBDApp`
depends on `TBDShared` and nothing else of the core's, so no dependency edge
runs from core to app, and a warm tree already rebuilds neither half on account
of the other.

Two single targets, `TBDDaemonLib` (97.58 s) and `TBDDaemonTests` (81.98 s),
are **78.1% of the core number and 54.8% of the whole build**. A package split
leaves both exactly where they are.

Measured in the same window, queueing for the machine-global build lock cost
**276.7 s** against 327.9 s of compiling. Waiting rivaled compiling, and a
package split does not shorten a queue.

## How the measurement was taken

A detached scratch worktree was checked out at `origin/main` (`e46be723`, which
includes the `TBD_SWIFT_JOBS` face-value change) and built from empty. Package
resolution ran first and is excluded from every number here; it took roughly
46 s, timed outside the recorded run.

Every compile went through `scripts/swift-safe` with `TBD_SWIFT_JOBS=8`. The
core half was built as a sequence of target-scoped `build --target`
invocations, and the remainder as a single `build --build-tests`, so that each
core target's cost is attributed individually and everything not yet built
falls into one app-phase figure.

**Compile time is read from SwiftPM's own `Build … complete! (Ns)` line**,
which starts after `swift-safe` acquires the lock and therefore excludes queue
time by construction. That choice matters, because the obvious alternative
misreports: see [the stale holder stamp](#the-lock-files-stale-holder-stamp)
below. Queue waits were recovered separately, as wall time minus the reported
compile time, and cross-checked against `swift-safe`'s own stderr wait lines.

A background sampler counted `swift-frontend` processes and read the load
average every 15 s for the length of the run.

Ambient load was substantial and uncontrolled: other worktrees on the same
machine were running their own test suites throughout, and the one-minute load
average ranged from 10.9 to 32.6. **The core-to-app ratio is the trustworthy
result; the absolute seconds are not reproducible numbers.**

## Results

Compile seconds per invocation, as reported by SwiftPM:

| Phase | Target | Seconds |
| --- | --- | ---: |
| core | TBDDaemonLib | 97.58 |
| core | TBDDaemon | 2.23 |
| core | TBDCLI | 5.62 |
| core | TestSupport | 11.19 |
| core | TBDSharedTests | 23.47 |
| core | TBDDaemonTests | 81.98 |
| core | TBDDaemonLiveTests | 2.56 |
| core | TBDCLITests | 5.15 |
| core | **subtotal** | **229.78** |
| app | remainder | 98.14 |
| | **total** | **327.92** |

`TBDShared` carries no invocation of its own: it compiled inside the
`TBDDaemonLib` build as a dependency, and is counted in the core subtotal.

The app-phase figure covers `TBDApp`, `TBDAppTests`, `TBDAppIcon`, `IconBaker`,
the whole user-interface dependency stack, two SwiftPM build plugins, the
`TBDDaemon` executable link, and the link of the merged `TBDPackageTests`
bundle.

## Dependency attribution

Third-party code divides along the same seam as TBD's own targets, which is the
evidence that the seam is real rather than nominal.

The core phase compiled GRDB, the swift-nio family and its `CNIO*` C shims,
swift-argument-parser, `DequeModule` with `InternalCollectionsUtilities`,
`Atomics`, `ContainersPreview`, and the test-only `Clocks`,
`ConcurrencyExtras` and `IssueReporting`.

The app phase compiled MarkdownUI, swift-markdown with the `cmark-gfm` C
sources it vendors, SwiftTerm, TOMLKit, NetworkImage, Highlightr with its
`CAtomic` shim, and SwiftUIIntrospect.

**No core module was recompiled in the app phase.** `TBDShared`,
`TBDDaemonLib`, `TBDDaemon` and `TBDCLI` each appear in exactly one phase's
build output. The target graph explains why: `TBDApp` declares `TBDShared`,
`TBDAppIcon` and its user-interface products, and no daemon target at all. The
single edge crossing the seam is `TBDAppTests → TBDDaemonLib`, which exists so
one test can round-trip replay bytes the daemon assembles through the terminal
emulator only the app links.

## Biases in the 70% figure

Two known biases push in opposite directions, and neither is large enough to
move the conclusion.

**70% understates the core.** Work that belongs to the core was charged to the
app phase purely by ordering: the `TBDDaemon` executable link, the two
argument-parser build plugins, and the link of `TBDPackageTests` — the single
merged bundle containing every test target, core ones included. A split would
not relieve the app half of those.

**The total slightly overstates one combined build.** Nine sequential
invocations forfeit the cross-target overlap a single build would find, so the
sum of the parts exceeds what one invocation of the whole would cost. This
inflates both halves and leaves the ratio roughly intact.

## Lock contention in the same window

`scripts/swift-safe` serializes compilation across every TBD worktree on the
machine behind one kernel-managed lock. During this run the nine invocations
occupied 607 s of wall clock for 327.9 s of compiling. Queue time accounted for
276.7 s of the difference, concentrated in four phases:

| Phase | Queued (s) |
| --- | ---: |
| TBDDaemonLib | 174.4 |
| TBDCLI | 50.4 |
| TBDDaemonTests | 43.0 |
| remainder | 8.9 |

The residual 2.4 s is SwiftPM start-up spread across the other five
invocations. Every one of the four waits was a sibling worktree's test run
holding the lock — `swift-safe` names the holder and its command on stderr,
which is how each was attributed.

Waiting rivaled compiling. That cost is a property of the fleet on one machine,
not of the package's shape, and splitting the package would not reduce it.

## `--target` accepts test targets

All five targets under `Tests/` were built individually by name — the
`TestSupport` helper target and the four test targets — and every one exited
zero. This is not documented behavior that was being relied on; it was simply
tried, and it worked.

If it holds, it is a possible fast path for a filtered test run: build the one
test target, skip the rest. What was **not** tested is whether SwiftPM can then
run those tests with build skipped, without the merged `TBDPackageTests`
bundle, which only the full test-inclusive build produces. Until that is
checked, the fast path is a lead rather than a technique.

One related observation: a target-scoped build compiles but does not always
link. The `TBDDaemon` executable link did not happen during its own
target-scoped invocation; it happened in the final test-inclusive one.

## `--jobs` does not cap compiler processes

`--jobs 8` bounds llbuild's concurrent *module tasks*, not the number of
compiler processes on the machine. Each Swift driver fans out per-file
`swift-frontend` invocations underneath its task.

The sampler counted a **peak of 31 concurrent `swift-frontend` processes** at
`--jobs 8` on a 12-core machine. Because it sampled every 15 s, 31 is a lower
bound on the true peak.

The practical consequence is for anyone sizing `TBD_SWIFT_JOBS` (see
[`docs/specs/2026-08-18-swift-safe-jobs-design.md`](../../specs/2026-08-18-swift-safe-jobs-design.md)):
"one job per core" understates the load the machine will actually carry, by
roughly a factor of four in this run. The knob is a task-concurrency bound, and
memory pressure follows the frontend count rather than the job count.

## The lock file's stale holder stamp

`swift-safe` writes `pid=`, `cwd=` and the command into the lock file **after**
acquiring the lock, and never clears them on release — the lock itself is
kernel-managed via `flock`, so the file's contents are advisory text, not the
lock. A stamp therefore outlives its holder.

That defeats the natural way to measure queue time, which is to watch the lock
file until one's own `cwd` appears. Between one invocation releasing the lock
and the next holder stamping it, the file still names the *previous* run — and
in a sequence of builds from one worktree, the previous run is oneself. The
probe reads its own stale stamp and records instant acquisition.

This is not hypothetical: in this run, such a probe reported zero wait for the
`TBDDaemonTests` phase and for the remainder build, while `swift-safe`'s own
stderr shows both queued behind a sibling worktree for 43.0 s and 8.9 s. The
probe was right for the two phases where a sibling had already overwritten the
stamp, and wrong for the two where it had not yet.

Anyone instrumenting this lock should read queue time from `swift-safe`'s
stderr wait lines, or derive it as wall time minus SwiftPM's reported compile
time — not from the stamp.

## What this says about splitting the package

The split was judged low return on this evidence.

- **It saves the core-side loop about 98 s, once per cold worktree.** That is
  the whole of the app half, and only a contributor who never builds the app
  collects it.
- **It saves nothing on a warm tree.** No dependency edge runs from core to
  app, so app-side dependencies are already not rebuilt when core sources
  change. The split would formalize a separation the target graph already
  enforces.
- **It leaves the dominant costs untouched.** Queueing for the shared build
  lock (276.7 s here) and the core's own bulk — `TBDDaemonLib` plus
  `TBDDaemonTests`, 54.8% of the total — are both outside what a package
  boundary can affect.
- **It adds cost.** Two packages mean a second manifest, a path dependency, a
  second resolution, and a `Package.resolved` pair to keep coherent.

The durable fix for the cross-worktree cost is not a split but shared compiled
artifacts: SwiftPM compilation caching with prefix mapping, which would let
worktrees reuse each other's output instead of each compiling the same sources.
That is an upstream pitch and has not shipped; it is tracked in
[`docs/reclaim-build.md`](../../reclaim-build.md).

Two cheaper levers are available in the meantime, both aimed at the actual
concentrations: raise `TBD_SWIFT_JOBS` on machines with the cores and memory to
carry it, and reduce the two heavy targets — `TBDDaemonLib` and
`TBDDaemonTests` between them are more than half of every cold build.

## Unknowns and limitations

- Ambient load was uncontrolled and heavy throughout. The absolute seconds
  describe one run on one loaded machine; only the ratio is meant to travel.
- The run was not repeated, so there is no variance estimate for any figure.
- One configuration was measured: `--jobs 8`, debug, on a 12-core machine. The
  core-to-app ratio may shift at other job counts, and was not measured for a
  release build.
- Sequential per-target builds are not how anyone builds. The total overstates
  a single combined invocation by an unmeasured margin.
- The frontend peak of 31 comes from 15-second sampling and is a lower bound.
- Whether a single named test target can be run without the merged bundle, by
  skipping the build step, was not tested.
- No split was prototyped. The saving attributed to a split is inferred from
  the phase boundary, not observed against two real packages.
