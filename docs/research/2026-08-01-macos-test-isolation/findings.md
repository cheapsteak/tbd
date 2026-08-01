# Keeping a macOS test suite out of the developer's home directory

**Status:** Investigated and shipped — the fence and tripwire described here are
implemented in `scripts/test.sh`
**Measured:** 2026-08-01 on macOS 26.1, Swift 6.2.4, using a plain unsigned SwiftPM
binary

## Why we went looking

TBD's test suite wrote into the developer's real `~/tbd` for months, accumulating
about 18,000 orphaned profile directories and 2,900 fake worktrees. We fixed the
individual leaks, but five separate sites turned out to have the same shape, which
is a strong hint that fixing them one at a time is not a strategy.

Every one of those five assembled a path out of the home directory instead of
asking where TBD's config lived. Our existing fence — an environment variable that
production code consults — cannot help with that by construction. Code that never
asks a question cannot be given a different answer.

So the question was: is there a way to close that hole *structurally*, rather than
by finding each site through code review?

The answer turned out to be yes, and to hinge on one environment variable that
almost nobody would guess.

## The finding that mattered: on macOS, `$HOME` does not do what you expect

The obvious idea is to redirect `HOME` for the test process. That is what git's
test suite does, and it works perfectly for git.

**It does nothing for Swift on macOS.** Measured directly with `HOME=/tmp/fakehome`:

```
getenv("HOME")                          = /tmp/fakehome
getpwuid(getuid()).pw_dir               = /Users/<real>
NSHomeDirectory()                       = /Users/<real>
FileManager.homeDirectoryForCurrentUser = /Users/<real>
URL.homeDirectory                       = /Users/<real>
("~" as NSString).expandingTildeInPath  = /Users/<real>
NSSearchPathForDirectoriesInDomains(…)  = /Users/<real>/Documents
```

Every Foundation home API ignored it. Setting `HOME` to a nonexistent path changed
nothing either.

The reason is visible in CoreFoundation's source. Home resolution tries three
sources **in this order**:

1. the `CFFIXED_USER_HOME` environment variable
2. the user account database (`getpwuid`)
3. the `HOME` environment variable

Because the account database always returns a value on a normal account, step 3 is
unreachable. The `HOME` branch is effectively dead code.

This is worth stating plainly because it inverts the usual intuition: **we had
applied the industry-standard isolation pattern, and the platform silently
declined to honor it.** Nothing errored. The variable was set, and simply had no
effect.

## What does work: `CFFIXED_USER_HOME`

The first entry in that list is a real, working lever. Same binary, `HOME` left
alone, `CFFIXED_USER_HOME=/tmp/fakehome`:

```
NSHomeDirectory()                       = /tmp/fakehome
FileManager.homeDirectoryForCurrentUser = /tmp/fakehome
URL.homeDirectory                       = /tmp/fakehome
expandingTildeInPath                    = /tmp/fakehome
applicationSupportDirectory             = /tmp/fakehome/Library/Application Support
cachesDirectory                         = /tmp/fakehome/Library/Caches
```

Two further properties make it practical:

- **It is not cached.** Setting it at runtime takes effect on the very next call,
  so the fence can be installed in-process, not only by a wrapper script.
- **It applies to a plain unsigned SwiftPM binary**, which is what our tests are.
  (There is a guard for setuid binaries; that does not apply here.)

This single variable covers the roughly 37 Foundation home-API call sites in our
source, which is the entire class of bug that produced all five leaks.

## Why you need both variables, not one

They are exactly complementary, and neither alone is sufficient:

- **`HOME` fences subprocesses.** Measured: with `HOME` redirected, `git config
  --get user.email` returned empty — properly isolated. Our tests spawn real
  `git`, real `tmux`, and real shells, none of which link CoreFoundation, and all
  of which read `HOME` the ordinary way.
- **`CFFIXED_USER_HOME` fences in-process Foundation.** Measured: with only that
  variable set, `git` returned the developer's real email address — completely
  unaffected.

Set one and half your surface is exposed. Which half depends on which one you
picked.

## The decoy tripwire

Fencing a leak makes it harmless. It does not make it *visible* — the code still
runs, still writes, still passes, just somewhere else. We wanted the bug to
announce itself.

The trick is small. Point the sanctioned scratch directory somewhere that is *not*
inside the fake home, then pre-create the paths a leak would use — the fake home's
`tbd` and `.claude` — with no permissions at all.

Correct code asks the resolver, lands in the sanctioned directory, and works.
Leaking code assembles a path from the home directory, lands on a decoy, and fails
immediately:

```
NSCocoaErrorDomain Code=513 "You don't have permission to save the file
"leak" in the folder "worktrees"."
NSFilePath=/tmp/…/fakehome/tbd/worktrees/leak
NSUnderlyingError=NSPOSIXErrorDomain Code=13 "Permission denied"
```

That is a failure **at the offending call site, inside the failing test, with the
path named**. Compare that to a before-and-after directory comparison, which can
only tell you that something changed somewhere during a multi-minute window.

The tripwire also works on a developer's machine with a live daemon and dozens of
worktrees running, because it never touches the real directories at all. Our
before/after comparison had to be restricted to CI precisely because it could not
tell a leak apart from ordinary background activity.

Nix uses a version of this idea in production, pointing `HOME` at a deliberately
nonexistent path, with a source comment explaining the reasoning: tools fall back
to the account database if `HOME` is unset, but will assume a settings file simply
does not exist if `HOME` points somewhere unreachable.

## Why the tripwire supersedes the before/after comparison

Two blind spots make a snapshot comparison much weaker than it looks, and both were
found the hard way.

**Creating a directory that already exists silently succeeds.** The standard
"create with intermediate directories" call returns success without performing any
write when the target is already there. So a leak that lands once and is thereafter
re-created is invisible — no syscall to intercept, and nothing added for a name
comparison to notice. A leak writing to a *fixed* path is therefore caught at most
once, ever, and is silent forever after. This caused a real misdiagnosis during the
research: a leftover directory from an earlier run made a correctly-working sandbox
look like it had been bypassed.

**Create-then-delete nets to zero.** We found a live example: a test planted
fixture files in the developer's real `~/.claude/projects` and removed them in a
cleanup block. The before and after snapshots were byte-identical. That leak had
been invisible to the guard for its entire existence, and only surfaced when the
fence made the write fail outright.

The tripwire has neither weakness, because it fails on a permission check at the
moment of the write rather than inferring anything from a difference in state.

## What the fence does not cover

Three gaps, all measured, all worth knowing:

**Preferences are not redirected.** A write through `UserDefaults` under a
redirected home still landed in the *real* `~/Library/Preferences`. A separate
system daemon resolves those paths itself, so a per-process environment variable
cannot reach it. Our existing discipline — construct `AppState` with a named
defaults suite and tear it down explicitly — remains necessary and is not made
redundant by any of this.

**Keychain breaks rather than relocating.** Adding an item under a redirected home
returned an authorization error, and pre-seeding a keychain directory inside the
fake home did not help. In our case this turned out to cost nothing, because no
test reaches the real Security framework — but any project doing this should expect
it.

**Direct account-database lookups and hardcoded absolute paths escape both
variables.** Code calling `getpwuid` bypasses the environment entirely, and a
literal `/Users/...` string obviously ignores everything. We had zero of either,
and added two lint rules to keep it that way. These are ratchets rather than
cleanups.

## Approaches we tested and did not adopt

**macOS sandboxing (`sandbox-exec`)** genuinely works — it blocked creation,
appending, deletion, and directory creation at any depth inside a denied subtree,
while leaving reads and writes elsewhere alone. It even applies to
system-protected child processes. Three traps, though:

- The path in the profile must be fully resolved. Our first attempt denied nothing
  at all — silently — because `/tmp` is a symlink to `/private/tmp`.
- It cannot directly wrap `swift test`, because SwiftPM sandboxes its own manifest
  compilation and the two cannot nest. Building first and then running with
  building disabled works.
- **A tmux server started before the sandbox is a complete bypass.** Measured: a
  sandboxed client asked an already-running server to write into the denied
  directory, and the write succeeded. A server started inside the sandbox
  correctly inherited the restriction.

We consider this a worthwhile CI-only backstop and have left it as a follow-up.

**Filesystem event monitoring** cannot attribute a change to a process. We settled
this from the SDK header rather than from secondary sources: the available event
metadata is path, inode, and a document identifier. There is no process ID. A flag
exists that distinguishes "caused by me" from "caused by someone else", which is a
single bit, not attribution. Since attribution was the whole reason to consider it,
this is a rejection rather than a trade-off.

**Library injection** to intercept file operations is stripped by system integrity
protection exactly where it matters — when launching protected binaries like the
system `git`. Sandboxing demonstrably does follow into those; this does not.

**Filesystem snapshots** give true modification detection at any depth, but remain
a before/after comparison with no attribution, so they inherit every limitation
that pushed our existing check into CI, for considerably more machinery.

**Separate user accounts or virtual machines** are real isolation at real cost.
There is no macOS container story that runs a macOS toolchain; the system container
tooling runs Linux guests only.

## Prior art

git's test suite redirects `HOME` and several related variables, and has **no
verification layer at all** — containment alone. That works because git is C code
reading the environment variable directly.

Across the projects surveyed, only Homebrew was found to assert at runtime that its
isolation actually held. Cargo and rustup redirect the home directory per test with
no detection. Rustup goes further in an interesting direction: all environment
access is routed through a type whose test variant has no path to the real
environment at all, making leakage unrepresentable rather than merely detected. The
closest thing we have is our injectable environment parameter, and the gap is that
using it is optional rather than enforced.

## The general limit worth remembering

**Any fence built around a single process is defeated by talking to a helper that
outlives it.**

The preferences daemon defeats a redirected home. A pre-existing tmux server
defeats OS sandboxing. A running application daemon would defeat both. This is one
principle, not three separate caveats, and it applies equally to environment
variables, sandboxing, and path injection.

The practical consequence for us: tests must always use a fresh, test-scoped tmux
socket. A related idea worth adopting is deriving the tmux server name from the
config root, so that isolation becomes structural rather than a convention someone
must remember.

## What we shipped

- `HOME` and `CFFIXED_USER_HOME` added to the fence in `scripts/test.sh`, applied
  as a prefix on the test command rather than exported, so the wrapper's own view
  of the home directory stays real.
- Permission-denied decoys at the fake home's `tbd` and `.claude`, with the
  sanctioned scratch directory deliberately placed elsewhere.
- Two roots with deliberately different lifetimes: the sanctioned directory is
  fresh per run, because reusing it would let state leak between runs; the fake
  home is stable, because redirecting the home directory relocates the build
  tool's caches into it and a fresh one each time would re-pay a cache miss.
- Two lint rules banning account-database lookups and hardcoded user paths in
  source.

Left as follow-ups: sandboxing as a CI backstop, and deriving the tmux server name
from the config root.
