# Are we using the wrong Swift test runner? — 2026-08-29

Local `scripts/test.sh` runs on this development machine are slow enough that
the developer has stopped trusting them and pushes to CI for a verdict instead.
This document asks whether that is a tooling problem the Swift ecosystem has
already solved, and answers it with measurements taken on 2026-08-29 against
`996e9f99`.

**Short answer: mostly no, with one real exception.**

The single largest cost is not the test runner at all — it is queueing for the
machine-global build slot on a box running 30 agent worktrees at roughly ten
times CPU oversubscription. A 3-core GitHub runner executes the same 8,427
tests in **260 seconds**; this 12-core M4 Pro takes **771 seconds** plus an
unbounded wait for a mutex. No test runner fixes that.

The exception is real and cheap: Swift Testing **did** grow a parallelism cap,
in Swift 6.3. The claim in `Tests/CLAUDE.md` that Swift Testing runs "every
non-serialized test in one process with **no concurrency cap**" was true when
it was written and is still true of the toolchain local runs actually use
(Xcode 26.3 / Swift 6.2.4), but it is **no longer true of the toolchain CI
already runs on** (Xcode 26.6 / Swift 6.3.3). Local dev and CI are on different
toolchains, and the newer one has the knob.

## 1. What was measured, and how contaminated it is

Every local number here was taken on a box carrying ~30 sibling agent
worktrees. `Tests/CLAUDE.md` records a prior measurement invalidated by exactly
this drift, so nothing below is a controlled timing comparison. The local
figures are **occupancy and saturation observations**, which survive noise; the
comparative timings are CI-versus-local, where the CI side is uncontended.

Two figures are **reported rather than re-measured here**, and are labelled as
such wherever they appear: the local full-suite baseline (8,437 tests in 818
suites, 771 s) and the failure breakdown of that run (42 failures, all
`Time limit was exceeded` or gate starvation, none a real defect). They come
from the run that prompted this investigation. Reproducing them would have cost
the build slot for no new information; §7 says what measurement would have been
worth that cost.

Deliberately **not** measured: an A/B of the parallelism cap on the real suite.
Doing that honestly needs the machine-global build slot for a cold rebuild plus
several full runs — roughly an hour of the exact resource this document
identifies as the bottleneck, with three sessions already queued behind it and
one already dead at exit 75. A number produced that way, at load 140, would not
have discriminated anything. §7 says what measurement would.

## 2. The costs decompose into three independent problems

They get conflated as "local tests are slow". They have different fixes and
different answers to "is there better tooling".

### A. Queueing for the machine-global build slot — the dominant cost

`scripts/swift-safe` holds one flock at `~/tbd/runtime/swift-build.lock` for
the whole machine, and `scripts/test.sh` deliberately resolves the same path
("a lock nobody else takes is not a lock"). The wrapper acquires the lock and
then `execv`s SwiftPM, so the lock is held for that process's entire lifetime.

For a build that is exactly the intent. For a test run it means **the
machine-global build slot is held for the whole test execution, not just the
compile.**

Observed live during this investigation:

- The holder was a sibling worktree running SwiftPM's test command with
  `--jobs 8`, and had held the slot for **43 minutes** at the time of
  observation.
- Two to three `scripts/swift-safe` wrapper processes were queued behind it
  continuously, with head-of-line waits of 21–25 minutes.
- A peer session's filtered run — 3 suites, 25 tests, **0.577 s** of actual
  test work — waited the full 1800 s timeout and exited **75** having compiled
  nothing. For that run, 100% of the latency was the mutex and 0% was Swift
  Testing, the test population, or the compiler.

`TBD_SWIFT_JOBS=8` is exported from the machine owner's `~/.zshenv`, so the
8-job holder is a sanctioned setting and not a bypass — `swift-safe` documents
that value as a machine-wide ceiling the owner sets. Nothing here is
misbehaviour. The structure is what produces the queue.

The arithmetic is unforgiving: with one slot and holders that run for tens of
minutes, wait time grows linearly with the number of worktrees that want to
test, and there are 30 of them.

### B. The machine is oversubscribed, and that is not a tooling problem

Sampled with `top -l 1` while the above was in flight:

- 12 cores, load average **111–165** across the observation window
- **42.1% user, 40.8% sys, 17.1% idle** — the box is ~83% busy, and nearly half
  of that is kernel time
- 973 processes, **8,943 threads**
- 30 directories under `~/tbd/worktrees/tbd`

Forty per cent system time on a 12-core machine is about five cores burned in
the kernel before any test runs. Top consumers during the sample included
`fseventsd` (99% of a core), `XprotectService` (86%), Chrome (70%) and
`WindowServer` (57%) — the per-worktree filesystem-event and scanning tax, not
compilation.

The comparison that settles it: CI ran this same tree green on a **3-core**
`macos-26` runner (run `33232886152`, 2026-08-29):

- fast pass 1 — 4,401 tests in 386 suites, **148.0 s**
- fast pass 2 — 3,946 tests in 408 suites, **55.3 s**
- quiet pass (tier 3, serial) — 80 tests in 23 suites, **56.7 s**
- **8,427 tests, 260.0 s of test execution**

Against a reported 8,437 tests in 818 suites in **771 s** locally. A runner with a quarter
of the cores is three times faster. Whatever is wrong, it is not that SwiftPM
is the wrong tool for 8,400 tests.

### C. In-process scheduling — real, secondary, and now fixable

This is the effect `Tests/CLAUDE.md` names "population is the scheduler", and
its mechanism is confirmed by reading the runner source. It is the only one of
the three that a test-runner change addresses. §3 is about it.

## 3. Swift Testing's parallelism cap — what exists, and where

### It exists, from Swift 6.3

[swift-testing PR #1390](https://github.com/swiftlang/swift-testing/pull/1390),
"Add an upper bound on the number of test cases we run in parallel", merged
**2025-11-11**. It adds `Configuration.maximumParallelizationWidth`
(`@_spi(Experimental)`) and a `Serializer` actor that gates test-case execution
behind a width-limited continuation queue. From the PR: "Swift Testing's own
tests go from > 300MB max memory usage to around 60MB."

It is set three ways:

- the environment variable `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`,
  read directly by the testing library, documented by
  [PR #1711](https://github.com/swiftlang/swift-testing/pull/1711) (merged
  2026-05-12);
- the testing library's own `--experimental-maximum-parallelization-width`
  argument;
- SwiftPM's hidden passthrough option of the same name — which is on SwiftPM
  `main` but **not** in the SwiftPM shipped with 6.3.3 (verified by inspecting
  the shipped `swift-package` binary's strings).

On our toolchain the environment variable is therefore the only route, and it
needs no SwiftPM support at all.

**The default is uncapped.** The `NCORES * 2` bound the PR originally shipped
is commented out on `release/6.3`, `release/6.4.1` and `main`; the default is
`.max` unless the variable is set. So this is opt-in, not something a toolchain
bump gives you for free.

### Which branch has it

- `release/6.2` — **absent**. `Sources/Testing/Support/Serializer.swift` does
  not exist on that branch.
- `release/6.3`, `release/6.3.1`, `release/6.4.x` — present.

Verified against the binaries actually installed on this machine, not just the
repository. The `Testing.framework` inside Xcode 26.3 (Swift 6.2.4) contains
`isParallelizationEnabled` and `ParallelizationTrait` and **no**
`maximumParallelizationWidth`, no
`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`. The `libTesting.dylib` inside
the swift.org 6.3.3 toolchain already sitting in
`~/Library/Developer/Toolchains` contains all four symbols.

### Where the gate sits, and what that does and does not fix

From `Sources/Testing/Running/Runner.swift` on `release/6.3`:

- `.testStarted` is posted at line 226, **before** any gate.
- the width gate wraps `_runTestCase` at line 384
  (`await testCaseSerializer.run { … }`).
- `withTimeLimit(for:configuration:)` is applied inside `_runTestCase` at line
  414, **after** the gate.

Three consequences, and they are the whole reason to care:

- **`Time limit was exceeded` starvation is fixed.** The `.timeLimit` clock —
  including `.clockDriven`'s four minutes — does not start until the test has
  passed the gate. A queued test burns none of its limit.
- **In-test wall-clock deadlines stop starving.** `ciSafeDeadline`,
  `waitForSuspension`, `FireRecorder.next()` and every bounded poll run inside
  the test body, that is, after the gate. So does `TestClock.advance`'s
  `Task.megaYield()` — capping the width caps how many clock-driven tests can
  flood the cooperative pool at once, which is the self-starvation mechanism
  `Tests/CLAUDE.md` documents.
- **Reported per-test durations are NOT fixed.** Because `.testStarted`
  precedes the gate, a gated test still "takes" its queue wait. The
  590-second trivial test would still read 590 seconds. This is a known
  reporting wart —
  [issue #1780](https://github.com/swiftlang/swift-testing/issues/1780).

That mapping matters: all 42 failures reported from the local run that prompted
this were `Time limit was exceeded` or gate starvation, which is precisely the
class this addresses, and none of them is the class it does not.

### What is still missing upstream

[Issue #1086, "Expose parallelism"](https://github.com/swiftlang/swift-testing/issues/1086)
(open since 2025-04-21) asks for a way to *read* the width from inside a test.
There is none, so a test that needs to size a resource pool to the width still
has to be told the number out of band.

## 4. The other options, and why they are not it

- **`--num-workers`.** Exists in SwiftPM, and is **XCTest-only**. SwiftPM
  rejects it outright for Swift Testing: `'--num-workers' is only supported
  when testing with XCTest` (`Sources/Commands/SwiftTestCommand.swift`,
  `validateArguments`). The XCTest `ParallelTestRunner` it drives really does
  fork a process per test — that process-level sharding simply has no Swift
  Testing equivalent.
- **Process-per-target.** Not available. SwiftPM builds **one** test bundle per
  package — `.build/debug/TBDPackageTests.xctest` — so all five test targets
  land in one process by construction. The only supported way to split the
  population across processes is separate SwiftPM test invocations with
  `--filter`/`--skip`, which is exactly what CI's two-pass fast lane already
  does.
- **`xcodebuild` with a test plan.** `-parallel-testing-worker-count` and
  `-maximum-parallel-testing-workers` spawn multiple runner processes, but
  Xcode distributes work to them **per test class**, and Swift Testing runs
  in-process within a bundle. Adopting `xcodebuild` for this package would mean
  generating a scheme, rebuilding `scripts/test.sh`'s environment fence around
  it, and getting sharding at a granularity that does not match how this suite
  is organised. Not worth it.
- **Bazel / `rules_swift`.** This is the honest ecosystem answer to
  "8k tests, want process isolation and sharding": Bazel's `shard_count` plus
  remote caching gives per-target test processes and real sharding. It is also
  a build-system migration for a package that builds fine today, and it does
  nothing about a box at load 140. No.
- **Selective testing (Tuist, XcodeSelectiveTesting).** Run fewer tests by
  fingerprinting what changed. Genuinely how large Swift shops keep suites
  fast, and worth remembering — but it is a change to what gets verified, which
  is a policy decision this repo should make deliberately, not a runner swap.

## 5. What is available on our toolchain today

- **Active local toolchain**: Xcode 26.3 at `/Applications/Xcode.app`,
  Swift 6.2.4. `scripts/swift-safe` resolves `swift` from `PATH`
  (`TBD_SWIFT_BIN`, else `shutil.which("swift")`), which lands here. **No
  parallelism cap.**
- **CI toolchain**: `.github/workflows/test.yml` pins
  `sudo xcode-select -s /Applications/Xcode_26.6.app` — Swift 6.3.3. **Has the
  cap.** The workflow comment says the pin "matches the swift.org 6.3.3
  toolchain used for local validation".
- **Already installed locally**:
  `~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain`, with
  `swift-latest` symlinked to it. Nothing routes local builds through it —
  `swift-safe` finds `/usr/bin/swift` first.

So the local/CI toolchain skew is unintentional: the 6.3.3 toolchain the
workflow says local validation uses is on the disk and unused.

## 6. Ranked recommendation

Ranked by expected win per unit of cost and risk.

**1. Stop holding the machine-global build slot for the duration of a test
run.** Highest expected win by a wide margin, and it touches no test code. The
lock is admission control for *compilation*; a test run holds it through
*execution* because the wrapper `execv`s SwiftPM. Splitting `scripts/test.sh`
into a locked build of the test bundle followed by an unlocked run against the
already-built bundle would return the slot after the compile. Cost: test
execution is not free either, so removing it from admission control needs a
decision about what the lock is for. Risk: real — this is load-bearing shared
infrastructure. **Needs a spec via `/tbd-brainstorming`, with a human answering
the questions.** Do not implement from this document.

**2. Route local runs through the 6.3.3 toolchain CI already pins.** Removes an
unintentional local/CI skew, and is the precondition for #3. Mechanically it is
`TBD_SWIFT_BIN`, or `TOOLCHAINS` set to the toolchain's bundle identifier.
Cost: one cold rebuild per worktree, and a possibility that something compiles
differently under 6.3 that CI has been absorbing all along — unlikely, since CI
builds this tree on 6.3.3 every run. Modest, mostly hygiene.

**3. Set `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH` once on 6.3.3.**
Expected win: eliminates the `Time limit was exceeded` and gate-starvation
failure class — 42 of 42 non-defect failures in the observed run — by keeping
queue time out of every `.timeLimit` and every bounded wait. Expected non-win:
wall time probably does not improve and may rise slightly (PR #1390: "does not
generally impact execution time"), and reported per-test durations stay
inflated. Cost: one environment variable, and it is `@_spi(Experimental)` with
an uncapped upstream default, so it is a knob upstream has not committed to.
Fits this repo's default-off-flag doctrine cleanly. **Also needs a spec** — it
changes how the suite decides something, and picking the width is a theory
call.

**4. Mirror CI's two-pass split in the local default.** Already measured in
this repo: p90 26.4 s → 14.6 s for +26 s of wall time. CI does it; local does
not. Cheap, understood, and it is the only in-process-population remedy that
works on 6.2.4. Its cost is real though — +26 s of wall on a machine where the
scarce resource is the build slot, and under today's wrapper the slot is held
across both passes. Sequence it after #1, not before.

**5. Do nothing about the box, but say plainly that it is the box.** Thirty
worktrees, load 140, 40% system time, 17% idle. If local test latency is the
thing that matters, the highest-leverage change is fewer concurrent worktrees
or a second machine — not a runner. That is a workflow decision, not an
engineering one, and it belongs to the person running the fleet.

## 7. What I would not do, and what would change my mind

- **Do not migrate to `xcodebuild` plus test plans.** Sharding granularity is
  per test class and Swift Testing runs in-process anyway; the fence in
  `scripts/test.sh` would have to be rebuilt around a scheme. It buys nothing
  this package needs.
- **Do not migrate to Bazel.** Correct answer to a question we do not have.
- **Do not re-litigate the three refuted remedies.** Per-suite `.serialized`,
  `TASK_MEGA_YIELD_COUNT=1` and blanket retry are measured-and-rejected in
  `Tests/CLAUDE.md`. Nothing found here disturbs any of them — note especially
  that the width cap is *not* per-suite `.serialized` reheated: it bounds the
  process-global in-flight count, which is the thing `.serialized` provably
  could not shrink.
- **Do not raise `.clockDriven`'s limit again.** If #3 lands, the pressure that
  drove it up should fall, and the right move then is to re-derive the triple
  downward, not to leave it where it is.

**What would change the ranking:** an interleaved A/B of the width cap on the
real suite, run on an idle machine — arms alternating uncapped and capped at
some width, population held constant, reporting the executed test **count** per
arm (a `--filter` matching nothing exits green), the count of
`Time limit was exceeded` issues, and wall time. If capping does *not* reduce
the time-limit failures, #3 is wrong and the reading of the runner source above
is wrong with it. That measurement is worth taking on a quiet box; it was not
worth taking on this one.

## 8. Sources

- swift-testing PR #1390, "Add an upper bound on the number of test cases we
  run in parallel" — https://github.com/swiftlang/swift-testing/pull/1390
- swift-testing PR #1711, documenting the environment variable —
  https://github.com/swiftlang/swift-testing/pull/1711
- swift-testing issue #1780, console output versus the gate —
  https://github.com/swiftlang/swift-testing/issues/1780
- swift-testing issue #1086, "Expose parallelism" —
  https://github.com/swiftlang/swift-testing/issues/1086
- SwiftPM issue #4775, the origin of `--num-workers` —
  https://github.com/swiftlang/swift-package-manager/issues/4775
- swift-testing `Runner.swift`, `Configuration.swift` and `Serializer.swift` on
  `release/6.3` — https://github.com/swiftlang/swift-testing/tree/release/6.3
- SwiftPM `Sources/Commands/SwiftTestCommand.swift` on `main` —
  https://github.com/swiftlang/swift-package-manager
- swift-testing parallelization documentation —
  https://github.com/swiftlang/swift-testing/blob/release/6.3/Sources/Testing/Testing.docc/Parallelization.md
- Swift 6.3 release announcement — https://www.swift.org/blog/swift-6.3-released/
- "Optimize your Swift test suite to run faster" (selective testing,
  distributing across environments) — https://tuist.dev/blog/2025/03/25/tests
- Bazel test sharding reference — https://bazel.build/reference/test-encyclopedia
