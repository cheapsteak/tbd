# How Claude Code keeps its config directory out of the way

**Status:** Investigated; several findings applied to TBD's test fence, one left as a
follow-up
**Examined:** 2026-08-01 — the withdrawn v0.2.8 npm package (with source maps
extracted) and the installed v2.1.220 executable

## Why we looked

TBD's test suite had been writing into the developer's real `~/tbd` for months.
It accumulated roughly 18,000 orphaned profile directories and 2,900 fake
worktrees before anyone noticed, across four separate leak sites.

Claude Code has the same shape of problem. It owns a config directory
(`~/.claude`), it supports relocating that directory through an environment
variable (`CLAUDE_CONFIG_DIR`), and its own tests presumably must not destroy a
developer's real configuration. So before investing further in our own approach,
we asked a simple question: how do they do it, and is their answer better than
ours?

The short version: on the part where we are comparable, we independently arrived
at the same architecture. They are ahead of us on two specific techniques, we are
ahead of them on one, and they made the same mistake we did before fixing it.

## What we actually examined, and how much it is worth

This matters more than usual, because the two sources support very different
strengths of claim.

**The withdrawn v0.2.8 package.** Real, readable source — 211 TypeScript files
recovered from published source maps, not minified output. But it dates from
roughly February 2025, making it about sixteen months old, and it is a *published
package*, which means it contains **no tests at all**. Treat it as a historical
baseline: it tells us where they started, not where they are.

**The installed v2.1.220 executable.** A large compiled binary. Its embedded
JavaScript is minified — variable names are mangled — but whole function bodies
are readable. Anything we say about current behavior comes from reading this.
When we quote a string, that is hard evidence the string exists. When we say what
a function *means*, that is our reading of mangled code, and we flag it.

**One limitation is worth stating plainly and up front: we never read a single one
of their tests.** No test files exist in a published npm package, and none can be
recovered from a compiled binary. Everything below about *how they test* is
inferred from test-only affordances left behind in production code — helper
functions, environment variable names, error strings. That is real evidence, but
it is indirect, and we have tried not to overstate it.

We also did not run the program, inspect a live `~/.claude`, or test relocation
behavior ourselves. Every claim about the binary is static analysis.

## Finding 1: There is exactly one place that decides where config lives

In v2.1.220, the config directory is resolved by a single function that reads the
environment variable and falls back to `~/.claude`. Everything else calls it.

The counts are the interesting part. We found **176 calls to that resolver**, and
only **9 places** that assemble a `~/.claude` path by hand instead. One of those
nine is the resolver's own fallback. We read the other eight individually, and all
of them look deliberate rather than accidental:

- Two reconstruct a *child process's* config directory from that child's
  environment, where asking the resolver would give the wrong answer.
- Two are security checks that deliberately ask "is this path inside the *real*
  home directory", which is the whole point of the check.
- Two probe for a legacy install location during migration.
- Two are intentional dual-reads. The nicest example: the code that finds IDE
  extensions looks in the resolved directory *and*, if the variable is set, also
  in the real home — so a relocated instance still finds extensions that were
  registered against the real one.

That ratio is the finding. Not "they have a resolver" — most projects have a
resolver. The finding is that essentially nothing bypasses it, and the handful of
exceptions each have a reason.

Two details of the resolver are worth copying. It caches its result but uses the
environment variable as the cache key, so changing the variable at runtime
correctly produces a new answer. (This reading is inferred from the shape of the
call, not from a definition we located.) And it normalizes the resulting path's
Unicode form, which matters on macOS, where the filesystem hands back a different
byte sequence for accented characters than the one your program typed.

## Finding 2: They had our exact bug, and fixed it the way we are fixing ours

This is the most useful thing we learned, because it is a natural experiment.

Version 0.2.8 already had `CLAUDE_CONFIG_DIR`, resolved in one place. It also had
three holes:

**A telemetry module built its path by hand.** It composed the home directory with
`.claude` and `statsig` inline, ignoring the environment variable completely. A
relocated Claude Code still wrote telemetry into the developer's real `~/.claude`.
This is precisely our bug: not a missing fence, but code that never asked the
fence a question.

**Logs went somewhere else entirely.** All messages, errors, and MCP logs were
written to a *second* root — a cache directory under `~/Library/Caches` — that the
config variable had no effect on. You could relocate the config directory
perfectly and still be writing into the real home.

**The resolver was frozen at import time.** It was a module-level constant, so it
captured its value when the module first loaded. Setting the environment variable
afterwards did nothing. This is a real test-isolation hazard, and Swift's `static
let` has exactly the same property.

By v2.1.220 all three are gone. The second root has no trace left in the binary at
all — it was consolidated away. Everything now hangs off the one resolver:
projects, sessions, skills, plugins, shell snapshots, telemetry, logs, caches,
credentials, settings, themes, backups, history.

The lesson we take from this is not "centralize your path resolution", which
everyone already believes. It is that **a project with a single resolver and a
documented relocation variable still had three real leaks**, and only closed them
over sixteen months of iteration. Getting this right is apparently not something
teams do on the first attempt.

## Finding 3: One main variable, plus a small set of narrow escape hatches

The binary contains references to over 600 distinct configuration variables. The
subset that relocates file paths is much smaller: the main config directory
variable, a separate one for credential storage, and roughly fifteen narrow ones
for specific subsystems — plugin caches, debug logs, temporary directories,
managed settings paths, and so on.

The shape is: **one primary variable that everything defaults underneath, plus a
handful of overrides for the things that genuinely needed to point elsewhere.** Not
one variable per directory, and not a single variable pretending to cover
everything.

This is the same architecture TBD arrived at independently — `TBD_HOME` as the
root, with `TBD_SOCKET_PATH` and `TBD_CLAUDE_HOST_HOME` as narrow escape hatches
for things that do not fit underneath it. That convergence is mild evidence the
shape is right.

Worth noting for anyone relying on this: `CLAUDE_CONFIG_DIR` is essentially
undocumented. It does not appear on the current environment-variable or settings
documentation pages, and there are open issues asking for it to be documented and
for the VS Code extension to honor it. It is a de-facto internal knob, not a
supported interface.

## Finding 4: They override `HOME` — and do not trust the app-specific variable alone

We went looking for this specifically, because we were considering it ourselves.

Shipped inside the production binary is an evaluation harness that runs Claude
Code against test cases in a sandbox. When it launches a child process, it builds
the environment like this: it sets the config directory variable, **and** `HOME`,
**and** the Windows equivalent `USERPROFILE`, **and** the XDG config variable, all
pointing at the same sandbox root. A second code path that runs shell scripts goes
further and constructs the child environment as an **allowlist** — building a fresh
dictionary with only the handful of variables it wants, rather than passing the
parent's environment through and overriding parts of it.

So the answer to "does a mature product override `HOME` rather than relying on its
own variable?" is **yes, and it does not rely on its own variable alone.**

Two hardening details in that harness are worth stealing conceptually:

- **A containment assertion.** A path helper resolves both the sandbox root and the
  target path through symlinks, then throws if the target does not end up inside
  the root. Symlink-aware, which matters — a naive prefix check is defeated by a
  symlink pointing out of the sandbox.
- **An input allowlist.** Test-case files may only set variables with a specific
  prefix; anything else must come from the operator's shell, and attempting it is
  a hard error with an explanatory message.

**An important caveat about where this applies.** They do it at *subprocess spawn*,
where you construct the entire environment dictionary for a fresh process. Doing
the equivalent in-process — changing your own environment while tests run in
parallel — is a different and more dangerous operation, which is exactly why TBD
has its serialized-suite rule. That constraint does not go away.

**And a platform caveat that inverts the lesson for us.** Separate testing on macOS
established that overriding `HOME` does *not* redirect Foundation's home-directory
APIs at all: the underlying resolution consults the user account database, which
always succeeds, so the `HOME` fallback is never reached. Their approach works
because Node reads `HOME` directly. It would have fenced nothing for our Swift
code. The variable that *does* work on macOS is `CFFIXED_USER_HOME`, which sits
above the account database in the lookup order. See the companion research note on
macOS test isolation for the measurements.

That is a good illustration of why copying a technique without checking the
platform underneath it is risky. The pattern was right; the specific lever was
wrong for our language.

## Finding 5: Namespace un-relocatable resources by hashing the config directory

This is the single best idea we found, and it is small.

Some resources cannot be relocated by pointing a path somewhere else, because they
are not paths. The OS keychain is the clearest example: entries are identified by
a service name, and two processes using the same service name collide no matter
what their config directories say.

Their solution: **derive the service name from the config directory.** When the
config directory is the default, the service name is unadorned. When it has been
relocated, the name gets a suffix computed by hashing the config directory path
and taking the first several characters. A relocated instance therefore gets its
own keychain namespace automatically, with no extra variable to set and no way to
forget.

The direct application for TBD is the **tmux server name**. Today a test run can
reach the developer's live tmux server, and no amount of path fencing prevents
that, because the server is identified by name rather than by path. Deriving that
name from `TBD_HOME` whenever it differs from the default would close that class
mechanically. The same reasoning applies to socket paths and anything else with
per-user identity.

## Finding 6: Where a resource genuinely cannot be namespaced, refuse

Their background-service installer contains an explicit error message saying that
service installation only supports the default config directory, because the
underlying OS service unit is a per-user singleton.

They hit a real limit — some operating-system resources are one-per-user and
cannot be namespaced by any variable — and chose to **fail loudly with an
explanation** rather than silently collide. That is directly analogous to TBD's
tmux-server problem, and it is a better default than our current silence.

## Finding 7: A cheap "am I in a redirected home?" check

Production code contains a small function that compares the home directory as
reported by the environment against the home directory as reported by the user
account database. If they disagree, the home directory has been redirected.

They use this, together with checks for whether the config directory has landed
inside a project or on a network path, to **skip scanning user-level configuration
entirely**, with a message explaining that the read root has been redirected and is
being skipped for safety.

The interesting part is the direction of the response: a redirected home makes
them *more* conservative, not less. TBD could use the inverse assertion in test
setup — fail loudly if the fence is supposed to be active but the config directory
still resolves to the real one.

## Finding 8: They had the accumulation problem too

We went looking for evidence that files pile up in their config directory, on the
theory that anyone who writes a cleanup routine probably had the problem first.

They did, twice over. Version 0.2.8 has a cleanup routine that deletes message and
error files older than thirty days, fired shortly after startup. Version 2.1.220
has a much more developed background housekeeping module: it walks several
subdirectories deleting entries older than a retention cutoff, and it is gated by a
sentinel file whose modification time records the last sweep, so the work does not
run on every single launch. There is also a user-facing cleanup command whose help
text carefully explains what it will and will not touch.

Two things to take from this. First, the accumulation problem is normal rather than
a symptom of something unusually wrong with TBD. Second, their answer was
**age-based retention with a sentinel file gating how often the sweep runs** — which
is directly relevant to TBD's open question about pruning old database backups,
because the sentinel pattern solves "do not do this work on every launch" without
introducing a timer.

We could not determine the exact retention window in the current version; the
thirty days in the old version is confirmed.

## Finding 9: How their test seams evolved

We could not read their tests, but the seams those tests use are visible, and the
change between versions is informative.

**Version 0.2.8 branched on a test flag inside production code.** Config read and
write functions each began by checking whether the process was running under test
and, if so, returning an in-memory object instead of touching a file. A comment in
the source explains why: their test framework at the time could not mock this kind
of module. Notably, **they did not redirect paths for config during tests at all** —
they swapped in an in-memory store so no file was involved.

That version also had a guard we like: a flag that made any attempt to read config
*during module import* throw an error saying config was accessed before it was
allowed. That defends against exactly the frozen-at-import-time bug described in
Finding 2, and Swift's `static let` has the same hazard.

**Version 2.1.220 has removed those branches** and replaced them with roughly 94
exported functions whose names end in a testing suffix, plus a set of test-only
environment variables for forcing specific conditions. The record/replay wrapper
for API calls has been compiled out to a constant.

Our read: the import-time guard is worth copying. Ninety-four testing-only exports
is a lot of production surface area maintained for the benefit of tests, and we
would not copy that.

## What we do that they do not

**Retrospective verification.** Their containment assertions are *prospective* — a
path is checked before it is used. Neither codebase, as far as we can see, has
anything that asks after a test run finished: *did anything appear in the real
config directory?* TBD's fingerprint check is not us catching up to them. As far as
this research can tell, it is ours.

**A genuine injection seam.** Their code reads the process environment directly, so
their tests must either control the process environment or spawn a subprocess. TBD
can pass an explicit environment dictionary into path resolution, which is testable
without touching global state at all. The gap in ours is that using the seam is
optional rather than enforced.

## What we changed because of this

- Deriving the tmux server name from the config root is now a tracked follow-up.
  It is the highest-value idea here and it is not in the current pull request.
- The sentinel-file retention pattern will be an input to the separate database
  backup retention design.
- The "assert the fence is active" check is a candidate for our test setup.

## What we could not determine

- **Their actual test suite.** No tests exist in a published package and none survive
  compilation. Everything in Finding 9 is read off seams and error strings.
- **Whether the eight hand-built paths are all deliberate.** We judged them from
  surrounding minified code with no comments or history. One or two could be
  unnoticed leaks.
- **The sixteen-month gap.** We can see the start and the current state, but not the
  order or motivation of changes in between. We cannot tell whether the telemetry
  leak was fixed deliberately after a report or incidentally during consolidation.
- **Exact retention windows in the current version.**
- **Anything requiring execution.** We did not run the program or test relocation
  empirically.

## The general principle worth remembering

The most transferable idea here is not any single technique. It is this:

**Any fence built around a single process is defeated by talking to a helper that
outlives it.**

Their preferences daemon defeats a redirected home for stored settings, because
the daemon resolves paths itself. A tmux server started before a sandbox is
unaffected by that sandbox, and will happily perform writes on behalf of a
sandboxed client. The same applies to TBD's own daemon.

Every isolation mechanism in this space — environment variables, OS sandboxing,
path injection — shares that limit, and it is better stated once as a design
constraint than rediscovered separately for each mechanism.

## Sources

- [Claude Code environment variables](https://code.claude.com/docs/en/env-vars)
- [Claude Code settings](https://code.claude.com/docs/en/settings)
- [Issue 3833 — config directory behavior unclear](https://github.com/anthropics/claude-code/issues/3833)
- [Issue 33430 — request to document the config directory variable](https://github.com/anthropics/claude-code/issues/33430)
- [Issue 30538 — VS Code extension ignores the config directory variable](https://github.com/anthropics/claude-code/issues/30538)
