# Compiler jobs under the machine-global build lock — design

Status: **implemented**. Scope: `scripts/swift-safe` and its in-repo callers.

## Problem

Local SwiftPM `build`, `test`, and `run` compilation goes through
`scripts/swift-safe`, which holds a kernel-managed, machine-global lock at
`~/tbd/runtime/swift-build.lock`. That lock is the defense against the failure
this wrapper exists for: a fleet of TBD worktrees, each running SwiftPM's
default jobs-per-core build, saturating one development machine at once. While
one worktree compiles, every other worktree queues.

Bounding the sole lock holder's compiler jobs is a second defense against that
same failure, and once the lock is in place it defends nothing the lock does
not. Its cost is not local: throttling the one build allowed on a 12-core
machine to two jobs makes that build several times longer, and because every
other worktree is queued behind the lock, the extra minutes are paid by the
whole fleet rather than by the worktree that is building. Test execution is not
what makes a suite feel slow here — roughly 3,100 tests run in 15–20 seconds —
so build time plus queue time is nearly all of the wall clock a contributor
waits through.

The bound therefore has to be something the machine's owner can set to fit the
machine, rather than a number the repository picks for every machine.

## Design

### `TBD_SWIFT_JOBS` is honored at face value

The wrapper reads `TBD_SWIFT_JOBS` and passes it to SwiftPM as `--jobs`. Any
positive integer is accepted: there is no ceiling, and no second variable to
export alongside it. Because the lock already guarantees at most one build on
the machine, the variable is a bound on the whole machine's compiler
parallelism, and setting it is the machine owner's decision to make.

The default is **2**, deliberately unchanged by the freedom to raise it. A
machine where nobody exports anything runs two-job builds, so a contributor who
never opts in never meets a build that takes more of their machine than they
asked for.

### Persistence is the owner's shell profile

There is no TBD-side store for the value. The owner exports it from their shell
profile — `~/.zshenv` or equivalent — which reaches every worktree, every
terminal, and every agent session on that machine. That single export is both
the persistence mechanism and the consent gesture, and it lands at exactly the
scope the value describes: one machine.

### A command line may lower the bound, never raise it

A `-j`/`--jobs` passed on the wrapper's own command line is accepted when it is
at or below the configured bound and refused above it. A caller with a reason to
be conservative — a script running alongside something memory-hungry, an agent
that wants to leave headroom — can ask for less. A caller asking for more is
asking to overrule the machine's owner, and is told to raise `TBD_SWIFT_JOBS`
instead.

### Typo protection is advisory

Jobs beyond the core count buy memory pressure rather than throughput: each
compiler frontend holds several hundred megabytes to about a gigabyte, so a
stray digit costs a swapping machine and nothing else in the pipeline would
report it. The wrapper emits one stderr line when the job count exceeds
`os.cpu_count()`. It never refuses.

Two rules keep that line honest:

- It reports the count the build will **actually** use. When a command-line
  `-j` lowers the effective count below the core count, nothing is said — the
  warned-of build would not have happened.
- It speaks only for a value somebody exported. The shipped default has nothing
  to tell the owner of a one-core container, who set nothing and could not
  silence it.

A machine whose core count is unreadable has no ground to warn from, and says
nothing.

### Sizing guidance

Match the machine. Past the core count there is no throughput to gain and real
memory pressure to lose, and the machine is simultaneously running the app, the
daemon, agent sessions, and SourceKit. On a 12-core machine, 8 is a sensible
export: it uses most of the machine for the one build the lock permits while
leaving headroom for everything that has to stay responsive during it.

### Callers state no job count; CI pins its own

No in-repo caller hardcodes a job count. `scripts/test.sh`, the pre-push hook,
and the nightly flake-stress harness all reach SwiftPM through the wrapper and
let it supply `--jobs`. A hardcoded number in any of them would both abort every
run on a machine whose owner lowered the bound and pin the build at that number
on a machine whose owner raised it.

CI is the exception, and it is explicit rather than inherited. The runner has
roughly 7 GB of memory and an OOM floor that two parallel compiler frontends
sit under, so the workflow job sets `TBD_SWIFT_JOBS: "2"` in its own `env:`
block; the one step that bypasses the wrapper spells `-j "$TBD_SWIFT_JOBS"`
rather than repeating the number. CI's memory ceiling is a property of CI's
hardware, so it belongs in CI's configuration — where it is visible next to the
runner it constrains, and where a change to the wrapper's default constant
cannot silently lift it.

## Accepted limitation

An environment variable can be set inline by any subprocess, so "the machine's
owner consented" is a convention rather than an enforced property. The
machine-global lock is what bounds the blast radius: whatever the value, at most
one build on the machine is using it.

## Rejected alternatives

**A ceiling plus a second opt-out variable.** A hard ceiling on
`TBD_SWIFT_JOBS`, with values above it refused unless a second variable is also
exported, turns the documented knob into a refusal trap for the person it is
documented for. The only protection it still offers past the lock is against a
fat-fingered digit, which the advisory warning delivers without refusing
anything. As a consent gesture it protects nothing further either: any process
that can export one variable can export two.

**A hard clamp at some multiple of the core count.** This refuses a value the
owner deliberately chose, on the theory that they did not mean it. The failure
it prevents is an oversubscribed single build — degradation, and self-inflicted
— not the concurrent multi-build swarm the wrapper was built for, which the lock
already prevents outright.

**Owner state in a file under `~/tbd/`.** A file is not meaningfully more
owner-only than an environment variable: any process running as the same user
can write the file exactly as it can set the variable. It is heavier to
implement, heavier to inspect, and it would split the wrapper's configuration
across two surfaces when every other knob it has — the lock path, the wait
timeout, the heartbeat interval, the orphan opt-out — is a `TBD_SWIFT_*`
variable.

**Raising the shipped default instead.** A higher default changes behavior on
every contributor's machine, including small ones that cannot absorb it, and it
interacts silently with CI's memory floor. Consent scales with the machine;
a constant does not.
