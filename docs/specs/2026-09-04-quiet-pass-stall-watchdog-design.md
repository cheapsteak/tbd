# Test-pass stall watchdog: making a wedged CI test run name its test

The `test` workflow runs the package in four passes in one job: three parallel
fast passes that share a build, and a quiet pass that runs the tier-3 live
suites serially on an otherwise idle runner, because those suites drive real
tmux servers and real child processes and contend with each other if run in
parallel. Any of those passes can stall. GitHub kills the step at its
`timeout-minutes`, and what lands in the run log is a truncated list of test
names, no failing assertion, and nothing that identifies where the run stopped.
Each occurrence costs a rationed macOS runner and reddens a pull request that
has nothing to do with the defect.

The stalls on record come in two shapes. In the quiet pass, three: two sit on
trees that predate the `Process.waitUntilExit()` cross-thread hang fixed in
#789 and are consistent with it, and the third is on a tree that carries that
fix, so it is a different site and no one can say which — the evidence to locate
it was never captured. In the fast passes, two 30-minute wedges with no stack at
all (runs 34174344530 and 34176996067), where the process went silent about five
seconds into the test run with roughly 1,965 tests started, none finishing, zero
issues recorded and no time limit firing: the cooperative-pool wedge signature
that `Tests/TestSupport/BoundedGateSupport.swift` describes, where every thread
the pool has is parked on a gate and nothing can reach a `signal()`.

This design does not fix the stall. It makes the next one hand over the stacks
of every thread in the process running the tests, plus a picture of the machine
around it, and fail the step before the platform timeout can destroy the
evidence.

## What the log actually shows

The truncated log is not truncated where the run stopped. On the serial
(`--no-parallel`) path SwiftPM relays the test binary's output through
`print(_:terminator:)` on its own stdout. In CI that stdout is a pipe into
`tee`, and C stdio fully buffers a pipe in blocks the size of the pipe's
`st_blksize` — 16 KB on macOS. The quiet pass emits roughly 16 KB of test lines
per minute, so the log lags the run by about a minute and a wedged step shows
whatever line the last complete block happened to end on.

Two runs prove it rather than suggest it. A stalled run (33797806278, attempt 2)
and a green run of the main branch (33787142345) both cut at exactly byte 16384,
mid-way through the same test name, about 63 seconds in. Every one of the 227
test lines in the stalled log carries a single runner timestamp — they were all
written to the log at the same instant, when the block flushed. In the green run
the second block arrives about 50 seconds later, after a particular teardown
suite; in the stalled run it never arrives. That bounds the stall to the ~26
suites between the two flush points, and no tighter.

The method generalises and is worth keeping: to find what a buffered CI log can
and cannot tell you, take a green run of the same step, accumulate the byte
lengths of its lines, and mark the 16 KB boundaries. Every boundary is a point
at which a stalled run's log would stop. A line adjacent to one of those
boundaries is evidence of nothing; the natural reading — "the last line names
the hung test" — is wrong by construction.

The fast passes emit roughly 16 KB a second, so their logs look real-time
whether or not they are buffered. That makes buffering invisible there and it
makes nothing about a wedge visible: when a fast pass goes silent, the log ends
where the process stopped producing, and it still names no frame.

## Requirements

- **The log streams as the run produces it.** A stalled step's last line must
  mean something.
- **A stall fails the step before the platform timeout**, leaving every thread's
  stack of the process executing the tests and a listing of the processes around
  it.
- **A green run is unchanged** — same verdict, same output, no new failure mode.
- **A red run's exit status survives untouched.** `scripts/swift-safe` returns 75
  for an abandoned queue wait and 76 for "verify remotely"; conflating them, or
  flattening either to 1, is a silent wrong answer.
- **Any doubt fails closed.** An unreadable status, an unattributable stall, a
  sampling failure — none of them may pass for success.
- **Nothing is killed by name.** Signals go to pids the step itself observed.

## Scope

All four test steps are watched, and each carries its own budget, floor and
file names. Nothing about the mechanism is specific to the serial pass: a
parallel pass wedged on the cooperative pool is exactly the case a per-test
`.timeLimit` cannot reach, because cancellation cannot reach a blocked thread —
so the step timeout is the only bound there too, and it records as little.

The two fast-pass wedges above are the evidence for that scope. Before them the
quiet pass was the only watched step, and it was also the only step that never
produced an unexplained red: every stall that cost a rerun landed where no
watchdog was looking.

## The mechanism

One script carries it: `scripts/ci/watched-test-pass.sh`. Each step names a
pass, a budget, a floor and the floor's explanation, and forwards the rest to
`scripts/test.sh`:

```
scripts/ci/watched-test-pass.sh --name <name> --budget-seconds <N> \
  --floor <N> --floor-message '<text>' [--out-dir <dir>] \
  -- <arguments forwarded to scripts/test.sh>
```

`--name` names the log, the status file and the stall files, and names the pass
in every message, so a reader of the job log knows which pass spoke. `--out-dir`
defaults to `/tmp`, which is what CI uses; the harness points it at a fixture
directory.

### Streaming the log

The script hands `scripts/test.sh` a pty: `TERM=dumb script -q /dev/null …
< /dev/null`. C stdio line-buffers a terminal, so each line lands as it is
produced. Nothing between the pty and SwiftPM re-pipes the stream —
`scripts/test.sh` invokes `scripts/swift-safe` without a pipe of its own, and
`swift-safe` `exec`s into SwiftPM — so the pty the step creates is SwiftPM's
stdout.

Each part earns its place. `script` propagates the child's exit status, so the
verdict still reaches the step. `< /dev/null` guarantees nothing ever blocks
waiting for input on the pty. `TERM=dumb` keeps SwiftPM's progress output
line-oriented instead of cursor-rewriting animations, which would be unreadable
in a log. The pty translates `\n` to `\r\n`, which affects neither the runner log
nor the step's own `grep` over the summary line.

### Watching the pipeline

The pipeline runs in a background subshell that begins with `set +e` — its only
job is to run the pipeline and record `PIPESTATUS[0]` to a status file, and
errexit would abort it before the `echo` on exactly the runs whose status
matters most. The script's foreground shell polls the subshell with `kill -0` in
5-second steps up to the budget.

### Finding what to sample

On expiry the script writes a whole-machine `ps` listing first and
unconditionally. The runner is single-tenant, so that listing is both the record
of the fixture's holder, tmux and job processes and the way a reader learns what
anything is really called.

Targets are then found by lineage: a recursive walk of `pgrep -P` from the
subshell's own pid. Among those descendants, the process executing the tests is
the one whose full argv (`ps -ww -o command=`) contains `swiftpm-testing`,
`xctest` or `TBDPackageTests`. SwiftPM runs a swift-testing bundle as
`<toolchain>/swiftpm-testing-helper --test-bundle-path <bundle> … --testing-library
swift-testing` and an XCTest bundle as `<toolchain>/xctest <bundle>`, so the
process executing the tests never carries the bundle's own name, and the
kernel's 15-character `p_comm` would truncate the helper regardless. Matching
unanchored against argv sidesteps both the truncation and the toolchain path.

When no descendant matches, every descendant that is not known plumbing — the
pty wrapper, the shells, `tee`, `sleep`, python, `swift-safe` — is worth a
stack.

Both paths take at most four processes, in walk order so parents come before the
children they spawned. A match count is not a process count: while the package is
compiling, the bundle path `.build/<triple>/debug/TBDPackageTests.build/…`
appears in the argv of every concurrent compiler process, so the argv match can
select a dozen at once, and at five seconds of serial sampling each that would
consume the margin the budget leaves. Walk order decides which four survive the
cap, which puts SwiftPM's driver ahead of the compiler processes it spawned — in
a stall during compilation the driver's stack is the more informative one. The
count each cap skips is written into the ps file, and the whole-machine listing
still names every matching process, so a capped candidate disappears from the
sampling and not from the artifact.

Each target gets `sample <pid> 5 -mayDie`, written to its own file, and is then
SIGKILLed immediately: it is wedged, and it has already given up everything it
has to give.

### Taking the pipeline down

The remaining processes get a graceful pass, because `scripts/test.sh` has an
EXIT trap that sweeps tmux servers and checks its filesystem fence, and that
cleanup is worth running. The order is built explicitly and rebuilt before each
sweep from a fresh walk: everything below the direct children first (that subset
reversed, so deepest-first), then the direct children other than `tee`, then
`tee`.

The ordering is not cosmetic. `tee` is a direct child of the subshell and owns
the far end of the log pipe, so anything still writing when `tee` dies writes to
a closed pipe — and the EXIT trap's output is precisely what the log wants.
Reversing the walk would achieve the opposite of the intent: the walk is
preorder, so the sibling `tee` is last in it and first in any reversal.

SIGTERM goes to that order, then a 30-second grace, then — if the subshell is
still alive — a fresh walk, a rebuilt order, SIGKILL to each pid, and SIGKILL to
the subshell itself. Both sweeps rebuild rather than reuse, because sampling and
the grace window are each long enough for the tree to change underneath a
snapshot; the EXIT trap's own cleanup spawns processes during exactly that
window. The script then waits for the subshell and exits 1.

### The verdict path

On a run that completes, the recorded status is read and validated as a
non-empty run of digits before it is compared — a writer that died mid-write
leaves an empty or non-numeric file, and an erroring `if` condition reads as
false, which would let a failed run walk on as though it had succeeded. Anything
unreadable exits 1 with its own message.

The status check comes before the floor check on `Test run with N tests`. A
build error, an early crash, or swift-safe's 75 and 76 all log fewer tests than
any floor; reporting them through the floor's message would both misdiagnose them
and flatten them to a generic 1. The floor keeps its own job — catching a run
that claims success while having executed nothing — for runs that claim success.

### The artifact

An `if: always()` step uploads `/tmp/*-stall-*.txt` as
`test-stall-diagnostics` with `if-no-files-found: ignore`. One glob collects
whichever pass wedged, because every pass writes `<name>-stall-ps.txt` and
`<name>-stall-sample-<pid>.txt`. `ignore` rather than the `warn` its neighbours
use: a green run deliberately produces no stall files, so absence is the normal
case rather than evidence of broken wiring.

### The harness

`scripts/ci/watched-test-pass.test.sh` drives the script against fixture
directories with a stub `scripts/test.sh` and a stub `sample`: no build, no
SwiftPM, nothing real touched, about 40 seconds. It covers a green pass handing
back its count, a 76 and an ordinary red status returned untouched, a run under
the floor and a run with no summary line at all, a stall through the primary
argv match and a stall through the fallback selection, and two malformed
invocations. It runs as the last step of the `test` job, on macOS because
everything it drives is BSD, and with `!cancelled()` so a harness bug can never
hide a pass's verdict.

## Numbers, and what each rests on

| Constant | Value | Basis |
| --- | --- | --- |
| fast pass 1a budget | 1800 s | 1.45× the 1250 s cold-cache first pass measured over 45 runs |
| fast pass 1a `timeout-minutes` | 35 min | budget + sampling margin |
| fast pass 1b budget | 600 s | tests only; 128 s of step time measured |
| fast pass 1b `timeout-minutes` | 15 min | budget + sampling margin |
| fast pass 2 budget | 600 s | tests only; 71 s of step time measured |
| fast pass 2 `timeout-minutes` | 15 min | budget + sampling margin |
| quiet pass budget | 720 s | 6 × the 117 s healthy pass |
| quiet pass `timeout-minutes` | 15 min | platform bound |
| margin left after the quiet budget | 180 s | 42 s used at worst measurement |
| `sample` duration per target | 5 s | ~5000 stacks at 1 ms |
| SIGTERM → SIGKILL grace | 30 s | cleanup takes a few seconds |
| sample-target cap (both paths) | 4 | 3 used in the measured probe |

The healthy quiet pass reports `Test run with 179 tests in 37 suites passed
after 116.847 seconds`, so its budget is six times a normal run and still three
minutes short of the step timeout.

The fast-pass budgets are sized against what those steps actually spend, and 1a
is the only one that pays the test-target compile. Measured over the 45 most
recent concluded runs of `test.yml` (2026-09-05 to 2026-09-09), the first test
step took between 73 s and 1250 s. The three slowest — 1010 s (run 34255127220),
1115 s (34267900663) and 1250 s (34255164378) — are exactly the runs whose
"Cache SwiftPM build artifacts" step finished in 1 to 4 seconds, which is what a
cache MISS looks like; a hit spends 25 to 56 seconds restoring. So 1250 s is the
measured cold-cache figure, over a full 5,529-test daemon pass — more than 1a
now runs — and 1800 s clears it by 45%. The warm-cache runs still spread
73–996 s, because every run force-rebuilds TBDShared and TBDDaemonLib and a PR's
first run restores only the deps-only fallback key, so a budget sized to the
warm median would end healthy runs. 1b and 2 run against that warm build and
measured 128 s and 71 s of step time on the split's first CI run, so 600 s is
several times a healthy run while still ending a wedge inside the step's own
bound. The
step timeouts sit above their budgets by only the margin the expiry path needs:
a step bound wide enough for per-test limits to fire first would buy nothing,
because the watchdog names the test sooner and with a stack.

Five seconds of sampling is what it takes to show a blocked thread
unambiguously: a parked thread looks identical in every sample, so more buys
nothing, while less risks reading a scheduler blip as the stall.

The margin is measured, not assumed. A probe with the argv match disabled, so
the fallback path ran (run 33902144920), spent 42 seconds on the entire expiry
path — whole-machine listing, tree walk, three targets sampled serially
including a 796 KB symbolicated testing helper, SIGTERM sweep, exit — against
the 180 seconds available. Two earlier probes at a shortened budget established
the other two facts the design rests on: that the pty makes every test line
arrive with its own runner timestamp (33803510307), and that a name match finds
nothing against a live pass, which is what moved target selection to lineage and
argv (33803510307, then 33805317227 sampling the helper by pid and uploading the
artifact).

## Who reclaims the orphans

Nothing here creates a durable resource, so no reconciler is needed. The files
are under `/tmp` on an ephemeral single-tenant runner that is destroyed when the
job ends, and the only processes signalled are descendants of the step's own
background subshell, enumerated seconds earlier. No resource can outlive the job
that made it.

## Assumptions, and how they fail

- **`/usr/bin/sample` is on the runner image.** It ships with macOS and is
  confirmed present by the probe runs. If it vanished, each target would log
  `sample <pid> failed` and the ps listings would still upload.
- **SwiftPM keeps executing tests in a descendant of its test command.** If it
  ever daemonised the runner, the tree walk would find nothing sampleable, the
  step would say so, and the whole-machine listing would still show where the
  process went.
- **`script(1)` propagates the child's exit status on macOS.** Verified
  locally (`script -q /dev/null /bin/sh -c 'exit 3'` returns 3) and in Apple's
  `shell_cmds` source; the success direction is confirmed by a green CI run, and
  the harness asserts both a 3 and a 76 reaching the caller through the pty. If
  it ever stopped holding, a red run would surface as an unreadable or zero
  status — and the validation above fails closed, so the failure mode is a
  spurious red, not a false green.

## Reading a stall report

Download the `test-stall-diagnostics` artifact from the failed run.
`<pass>-stall-sample-<pid>.txt` carries every thread's stack of the process
that was executing tests; the parked thread's frames name the file and line the
run is blocked in. `<pass>-stall-ps.txt` carries the machine listing, the
pipeline's descendants and the sampled processes, which is where the fixture's
holder, tmux and job processes appear and where the cap's skipped-candidate line
would be. The step log names the pass, the budget it waited and the pids it
sampled.

## Rejected alternatives

- **Matching processes by name.** `pgrep -x` on the bundle name found nothing
  against a live, wedged pass, because the tests execute inside
  `swiftpm-testing-helper`. A name match fails silently: it samples nothing while
  reporting success at having collected nothing. Lineage cannot fail that way.
- **Anchoring the argv match to an exact toolchain path.** The path is a
  toolchain detail that changes with the runner image. An unanchored match
  against argv survives both that and `p_comm` truncation.
- **Unbuffering by other means.** macOS ships no `stdbuf`, and SwiftPM exposes no
  flush knob. A pty is the mechanism the platform actually offers.
- **Lowering `timeout-minutes`.** It would end the stall sooner and record
  exactly as much as it does today, which is nothing.
- **Watching only the serial pass.** The premise was that the parallel passes
  never stall and emit output fast enough for buffering to be invisible. The
  second half is true and the first is not: a cooperative-pool wedge parks every
  thread the pool has, no per-test time limit can reach it, and the two 30-minute
  fast-pass wedges produced no stack at all. One script watching every pass costs
  a step nothing on a healthy run.
- **Inlining the watchdog in each step's YAML.** Four copies of a hundred lines
  of shell, drifting apart, with no way to test any of them. A script has a
  harness; a `run:` block does not.
- **Changing the eight blocking `waitpid(…, 0)` sites in the fixtures.** The
  leading hypothesis was the holder fixture's teardown, and it does not hold on
  the merits: the holder detaches with its own `setsid()`, keeps no controlling
  terminal, ignores only `SIGHUP` and `SIGPIPE`, and nothing in the test process
  ignores or waits on `SIGCHLD` for it, so a killed holder becomes a zombie
  promptly and the wait returns. Raw `waitpid` also carries none of the
  per-thread state that makes `waitUntilExit()` hazardous. Converting those sites
  without a stack would be a guess wearing the shape of the previous fix.
- **Re-verifying process identity before signalling.** `AgentReaper` compares
  start time and executable against a persisted row because it acts on processes
  recorded minutes or hours earlier, on a machine shared with a live fleet. This
  watchdog enumerates live descendants of its own subshell seconds before it
  signals them, on a single-tenant runner. The check would guard against nothing
  and could only add a way to skip a real target.
- **A default-off feature flag.** The flag convention exists for behavior that
  acts without a gesture on user sessions or persisted state. This acts only on
  the processes of one CI step's own pipeline, in a run that has already failed,
  on a machine that is discarded minutes later. A flag would mean the
  instrumentation is absent on the runs that need it.
- **Excluding SwiftPM's driver from the fallback.** It is included deliberately:
  when no descendant looks like a test runner, the driver's own stack is evidence
  about what it was waiting on, which is exactly the question a stall with no
  identifiable test process poses.
