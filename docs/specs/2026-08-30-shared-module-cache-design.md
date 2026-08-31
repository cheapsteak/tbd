# Shared Swift/clang module cache, applied at the admission wrapper

## Summary

Every TBD worktree keeps its own precompiled-module cache — 510 to 818 MB each, around
4.7 GB across the worktrees currently holding a `.build`. A shared cache already exists
to collapse those into one copy, but only `scripts/restart.sh` passes the flags that
select it, so most builds never use it and the machine pays for both: the per-worktree
caches *plus* 1.5 GB of shared cache.

Worse, the disagreement itself costs compile time. SwiftPM writes the cache path into
every compile command in the build plan, so a tree that alternates between
`scripts/restart.sh` (shared path) and `scripts/swift-safe` or `scripts/test.sh`
(default path) re-plans and fully recompiles on every transition, in both directions.

This moves the flags into `scripts/swift-safe`, the wrapper every governed build
already goes through, so all three entry points plan identically. The disagreement
disappears, the per-worktree caches stop being regenerated, and roughly 4.7 GB comes
back.

## Why the cache path forces a recompile

SwiftPM always emits a `-module-cache-path` (Swift) and `-fmodules-cache-path`
(clang) pair into each target's compile command in `.build/debug.yaml`. With no flags
they name the worktree's own `.build/arm64-apple-macosx/debug/ModuleCache`; with the
flags they name the shared directory. The flags therefore do not *add* an argument —
they change the value of one that is always present.

Any change to that value changes the command line, which invalidates the llbuild node
and swift-driver's argument hash, so every module recompiles. Measured on a
three-target package (two Swift, one C) under Swift 6.2.4: building twice with the
same flags rewrites no artifacts, while switching the flags rewrites every module.
Switching *back* to an already-warm default cache also rewrites every module, which
rules out cache warmth as the cause and leaves the changed argument as the only
explanation. The effect is independent of package size and so applies in full to a
TBD build.

This is why no environment variable can select the cache instead: an explicit flag is
always on the command line, and it wins. It is also why a `--toolset` JSON is not an
escape hatch — its options land in the build plan verbatim, making it this same design
with a different spelling.

## Why not a symlink

Pointing each worktree's `ModuleCache` at one shared directory would need no flags at
all and so would cost no re-plan. It does not work.

Cached artifacts embed the *spelled*, unresolved path of the worktree that created
them, and clang validates that spelling rather than the inode. A second worktree
symlinked to a directory a first has populated fails outright:

```
error: PCH was compiled with module cache path '<A>/.build/.../ModuleCache/SJHDC727RGOA',
       but the path is currently '<B>/.build/.../ModuleCache/SJHDC727RGOA'
error: missing required module 'SwiftShims'
```

It does not self-heal on retry. The symlink works for exactly one worktree and wedges
every other one, so single-copy disk by symlink is impossible with this toolchain. The
same embedded-path bytes defeat APFS cloning for the same reason: two worktrees' `.pcm`
files differ, so their contents cannot deduplicate.

Sharing by flag avoids this precisely because every worktree spells the *identical*
path. Verified: a second package built against a cache a first had warmed added zero
new entries and hit no path error.

## Design

`scripts/swift-safe` appends the module-cache flags to every compile subcommand
(`build`, `test`, `run`), making it the single place that decides where precompiled
modules live. `scripts/restart.sh` stops passing them.

**The wrapper is the right home.** It is already the one mandatory path to SwiftPM —
the repository guardrail rejects raw `swift build`/`test`/`run`, and `scripts/test.sh`
routes through it too. Anything that decides a build-wide compile setting belongs
where every build already passes, not duplicated across callers where copies drift
apart. That drift is the present bug.

**One spelling, resolved from the passwd database.** The path stays
`<home>/Library/Caches/tbd/swift-module-cache`, the directory that already holds a
warm 1.5 GB cache. It is resolved with `pwd.getpwuid(os.getuid()).pw_dir`, **not**
`$HOME`.

That distinction is load-bearing. `scripts/test.sh` deliberately points `HOME` and
`CFFIXED_USER_HOME` at a scratch directory, and relocates SwiftPM's own caches into it.
A `$HOME`-derived path would therefore resolve *inside the fence* on every test run,
minting an empty cache each time — so every test run would pay a full rebuild and
regrow the cache it was meant to eliminate. That is the failure mode CLAUDE.md already
records as "a path hand-built from `$HOME`", and it fails silently. `getpwuid` returns
the real home regardless of the fence, so the wrapper needs no cooperation from its
callers and `scripts/test.sh` needs no change.

Writing into `~/Library/Caches` during a test run is intended and safe: it is a build
artifact, not test state, and it is not one of the stores the fence's fingerprint
detector brackets (`~/tbd`, `~/.claude`, `~/.codex`, and the tmux socket directory).

**An unavailable cache is not a build failure.** Two things can go wrong, and both
degrade the same way: the wrapper says so on stderr, adds no flags, and leaves SwiftPM's
per-worktree default in place. A build is the wrong thing to fail over a cache that
exists only to be regenerated, and the fallback is the behavior every worktree had before
this change.

The first is a directory that cannot be created. The second is a home directory that
cannot be resolved at all: `getpwuid` raises for a uid with no passwd entry, which
minimal containers, sandboxes and arbitrary-UID environments all produce. Because this
wrapper is the sole mandatory gate for every SwiftPM command in the repo, letting that
raise would break every build, test and run for such a uid — and the only escape would be
knowing to set the opt-out beforehand. `TBD_SWIFT_MODULE_CACHE_PATH` is read *before* the
passwd lookup, so it stays a working escape hatch for exactly that environment.

**Callers may still choose.** `TBD_SWIFT_MODULE_CACHE_PATH` overrides the location.
`TBD_SWIFT_SHARED_MODULE_CACHE=0` disables sharing and restores SwiftPM's per-worktree
default. If a caller passes its own `-module-cache-path`, the wrapper adds nothing —
a second, differently-spelled copy would itself be a third plan variant and reintroduce
the alternation this removes.

**Continuous integration keeps today's behavior.** When `CI` is set the wrapper adds
no flags. Runners are ephemeral — one worktree per VM — so a shared cache saves nothing
there, and `.github/workflows/test.yml` ends its job with a bare `swift build` that
does not route through the wrapper. Applying the flags only to the `scripts/test.sh`
steps in that job would make CI alternate against itself on every run, and the
`actions/cache`d `.build` would carry whichever plan ran last into the next job. Both
branches of this condition are tested.

## What it costs and what it returns

**Read every figure here as a snapshot of a moving fleet.** `scripts/reclaim-build.sh`
reaps idle `.build` trees at 48 hours, so both the number of worktrees holding a cache
and the total they occupy change hour to hour — the planned-tree count moved from twelve
to eight inside a day while this was being written. The shape of the trade holds; the
digits do not.

At the time of writing, nine worktrees hold a local `ModuleCache` totalling 4,765 MB,
alongside a 1,481 MB shared cache, on a data volume with 27 GiB free at 94% capacity.
Under this design the local caches stop being regenerated and the shared copy — which
already exists — absorbs them, so roughly **4.7 GB** comes back. That figure will erode
somewhat: the shared cache will take on contexts it does not see today, since it will
serve test plans and every worktree rather than the two that currently reach it.

Keep the scale honest. The `.build` trees those caches sit inside total 28 GB, about six
times the module caches. **Precompiled modules are not where the disk went**, and this
is a worthwhile tidy rather than a fix for disk pressure.

**Migration is best measured in build-slot hours, not in recompile counts,** because the
wrapper's machine-global lock is the scarcest resource on the machine — sampled over 31
minutes it was held 51% of the time with someone queued behind it 27% of the time, and a
single holder was observed occupying it for 43 consecutive minutes.

Of the eight worktrees with a plan today, two already carry the shared path and keep it
unchanged; six pay a one-time full recompile on their next build. A cold full build
measured 2,441 s — about 41 minutes — so those six cost on the order of **four hours of
exclusive build slot**, taken whenever each tree next builds rather than at once. Two
things make that an upper bound: the rebuilds land against an already-warm shared cache
and so skip precompiled-module population, and the 41-minute figure was measured on a
heavily loaded machine.

That cost is the honest argument against this design and for the rejected alternative
below, which converges just as completely for about a third of the slot time.

**This is a disk change, not a speed change.** It removes the alternation tax, but so
would simply deleting the flags from `scripts/restart.sh`. The only speed it adds beyond
that is warm precompiled system and dependency modules for a cold worktree's first
build, which covers Foundation, AppKit, SwiftUI and the NIO shims but not TBD's own
compilation. That effect has not been measured and should not be claimed — and a
sampled build gives reason to doubt it would show: the thirteen `swift-frontend`
processes held 49% CPU out of 1200% available, against `kernel_task` at 221%, with every
frontend runnable rather than blocked on I/O. That build was short of turns, not of
memory or disk. Returning 4.7 GB adds no RAM and removes no contention.

**A caution for anyone re-measuring.** Timings on this machine swing with fleet load by
close to an order of magnitude — `git config --get` measured 334 ms under load and 38 ms
an hour later. Every duration in this document is a loaded-machine number, which makes
both the alternation tax and the migration cost smaller on an idle machine than stated.
Interleave the arms rather than measuring them an hour apart; `Tests/CLAUDE.md` records a
prior comparison invalidated by exactly this drift.

## Cache growth

The shared cache holds about 1.5 GB across 146 top-level entries — roughly two dozen
clang hash-context directories of 60–115 MB each, plus per-module entries at about two
hash variants per module name. Each distinct compiler-invocation context mints its own
directory, so contexts accumulate rather than overwrite.

Growth is bounded by clang's own pruning, which is active: `modules.timestamp` is
present, and the defaults run a prune pass every seven days evicting entries unused for
thirty-one. The steady state is therefore "every context touched in the last month",
which is about 1.5 GB — not the 650 MB an earlier estimate assumed. The directory sits
outside every `.build`, so `scripts/reclaim-build.sh` never sweeps it, and it can be
deleted by hand at any time; the next build regenerates what it needs.

## On shipping this enabled

CLAUDE.md requires large or risky new behavior to ship behind a default-off flag that
soaks before graduating. That rule's mechanics — a `config` column added by migration,
or a UserDefaults key — describe daemon and app behavior and have no counterpart in a
shell and Python build wrapper, and its motivating cases are autonomous action and
destroyed state, neither of which applies here.

The substance of the rule is served differently. A default-off flag would deliver
nothing until flipped, and the flip is the entire change. Instead the change is
reversible at the cost of one recompile per tree, carries an opt-out for anyone who
wants the old behavior immediately, and touches no persisted state — nothing it does
outlives a `.build` directory and a cache that is safe to delete. The blast radius is
nine worktrees on one developer machine, and the failure is a slow build rather than a
lost artifact.

The genuine risk it does carry is shared fate: one corrupt cache would affect every
worktree instead of one. That is accepted because the cache is disposable and
regenerates, and because clang's cache is designed for concurrent access — and in
practice the wrapper's exclusive lock means at most one build writes to it at a time.

## Testing

`scripts/test-swift-safe.py` covers the wrapper and gains cases for: flags appended to
each compile subcommand by default; no flags when `CI` is set; no flags under
`TBD_SWIFT_SHARED_MODULE_CACHE=0`; `TBD_SWIFT_MODULE_CACHE_PATH` honored; nothing added
when the caller already passes `-module-cache-path`; and the resolved path unaffected by
a fenced `HOME`, which is the regression that would otherwise reappear silently.

Each of these gates behavior, so both branches are asserted — the flags present when
the condition is absent, and absent when it is present.

`scripts/reclaim-build.test.sh` currently asserts that `scripts/restart.sh` contains the
flags. That invariant moves rather than disappears: it now asserts the wrapper supplies
them and that `restart.sh` does not, so the assertion still fails if the behavior is
lost.

## Rejected alternatives

**Delete the flags from `scripts/restart.sh` instead.** Converges the entry points just
as completely, with no new mechanism, and inverts the migration: the two trees on the
shared path revert instead of the six on the default path, costing roughly a third of
the build-slot hours. It removes the alternation tax exactly as well — that tax argues
for convergence, not for sharing, and this is the cheaper convergence.

It forfeits the roughly 4.7 GB and discards a warm 1.5 GB cache that would have to be
rebuilt if sharing were adopted later. The case for paying the extra slot time is that
the saving is permanent and recurring, while the migration is paid once; the case
against is that 4.7 GB is 17% of the 28 GB the `.build` trees occupy, so it does not by
itself resolve disk pressure, and build-slot time is the resource in shortest supply.
This is the live trade-off between the two designs, and it is close enough that it
turned on a judgement call rather than on evidence.

**Change nothing and correct the documentation.** Leaves the flags in `restart.sh` as a
trap for the next reader and keeps paying 1.5 GB for a benefit no worktree receives.
Defensible only if the three flagged trees never alternate again, which the standard
workflow — `scripts/test.sh` while iterating, `scripts/restart.sh` to verify live —
contradicts.

**Set the cache through `Package.swift` `swiftSettings`.** Measured dead end: manifest
settings do not reach dependency targets such as SwiftNIO, GRDB and SwiftTerm, which are
the bulk of the cache, leaving most of it local.
