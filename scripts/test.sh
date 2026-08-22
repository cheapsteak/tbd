#!/usr/bin/env bash
#
# The test suite, with the developer's real `~/tbd`, `~/.claude`, `~/.codex`
# and tmux socket directory fenced off.
#
# SwiftPM is invoked through `scripts/swift-safe`, never directly: that wrapper
# holds a machine-global admission lock and bounds compiler jobs so concurrent
# TBD worktrees cannot each start a full compiler swarm, and the repo guardrail
# blocks raw `swift build/test/run` for that reason. The two wrappers solve
# orthogonal problems — admission control there, filesystem isolation here — and
# every argument this script does not consume is forwarded through to
# `swift test`.
#
# STACKING THEM TAKES ONE EXPLICIT LINE, and leaving it out silently disarms the
# admission half. `swift-safe` derives its lock from `$TBD_HOME/runtime/…` when
# `TBD_SWIFT_LOCK_PATH` is unset — and the fence below points `TBD_HOME` at a
# `mktemp -d` that is unique per invocation, so every fenced run would take a
# PRIVATE lock and two concurrent runs would never serialize. That is precisely
# the compiler swarm `swift-safe` exists to prevent, arriving through the
# wrapper that is supposed to compose with it. So `TBD_SWIFT_LOCK_PATH` is
# pinned below, computed from the REAL home before the `env` prefix overrides it
# and passed explicitly — never left for `swift-safe` to derive from an
# environment this script has already rewritten.
#
# Three layers. The first two are always on; the third is CI-only.
#
#   1. CONTAINMENT — always on. `TBD_HOME`, `TBD_SOCKET_PATH`,
#      `TBD_CLAUDE_HOST_HOME` and `TMUX_TMPDIR` point at a fresh scratch dir
#      for the whole run, so any code path that resolves a TBD-owned path — or
#      the host Claude store a profile dir mirrors, or a tmux socket — lands
#      there instead of in the real one. This catches leaks nobody has
#      diagnosed yet, including ones in code that has no injection seam at all.
#   2. THE TRIPWIRE — always on. `HOME` and `CFFIXED_USER_HOME` point at a
#      *different* directory from layer 1, and the two names a leak reaches for
#      inside it — `tbd` and `.claude` — are pre-created mode `000`. Code that
#      asks the fence where home is lands in layer 1's scratch and works; code
#      that assembles a path out of the home directory instead gets `EACCES` at
#      the exact call site, inside the failing test, with the offending path in
#      the error. See "READING A PERMISSION-DENIED FAILURE" below.
#   3. DETECTION — on in CI (`$CI` set), off elsewhere; `--fingerprint` opts in
#      locally and `--no-fingerprint` forces it off anywhere. The real `~/tbd`,
#      `~/.claude`, `~/.codex` and tmux socket directory are fingerprinted
#      before and after, and a changed fingerprint fails the run even when
#      every test passed. This is now a backstop rather than the primary
#      guard; see "WHY THE TRIPWIRE SUPERSEDES THE FINGERPRINT".
#
# READING A PERMISSION-DENIED FAILURE. If a test under this wrapper fails with
# "You don't have permission to save the file …" or `EACCES`/`NSFileWriteNoPermissionError`
# on a path ending in `/tbd/…` or `/.claude/…`, that is not a broken machine and
# not a bad scratch dir. It means: **this code assembled a path out of the home
# directory instead of asking `TBDConstants`.** On a developer box the same code
# would have written into the real `~/tbd` or `~/.claude`. The fix is to route
# the path through `TBDConstants` (or whatever injected seam the type already
# takes) — never to relax the decoy's mode, and never to point `HOME` back at
# the real one.
#
# WHY BOTH FENCE VARS, AND WHY `HOME` ALONE IS NOT ENOUGH. They cover disjoint
# halves and neither substitutes for the other. Measured here on macOS 26.1:
#
#   - `$HOME` does NOT fence Foundation. CoreFoundation's home lookup tries
#     `CFFIXED_USER_HOME`, then `getpwuid`, and only then `$HOME` — and
#     `getpwuid` always succeeds, so the `$HOME` branch is unreachable. With
#     `HOME` pointed at a scratch dir, `NSHomeDirectory()`,
#     `FileManager.homeDirectoryForCurrentUser`, `URL.homeDirectory`,
#     `expandingTildeInPath` and `NSSearchPathForDirectoriesInDomains` all still
#     returned the developer's real home.
#   - `CFFIXED_USER_HOME` DOES fence Foundation, verified for a plain unsigned
#     SPM binary: every one of the above returned the scratch path. CF does not
#     cache it, so a runtime `setenv` takes effect on the next call.
#   - So `HOME` fences *subprocesses* — `git`, `tmux`, shells; they do not link
#     CoreFoundation — and `CFFIXED_USER_HOME` fences *in-process Foundation*.
#     Both are needed.
#
# Two things it deliberately does NOT fence, so don't read it as total:
#
#   - **`UserDefaults`.** `cfprefsd` resolves preference paths over XPC, so it
#     ignores `CFFIXED_USER_HOME` entirely. The existing
#     `AppState(userDefaults: UserDefaults(suiteName:))` discipline in
#     `CLAUDE.md` stays load-bearing.
#   - **The Keychain.** It breaks rather than redirects under
#     `CFFIXED_USER_HOME`: `SecItemAdd` returns `-60006` and
#     `SecItemCopyMatching` returns `-25300`, and pre-seeding
#     `$FAKE_HOME/Library/Keychains` does not help. Keychain-touching code must
#     go through an injection seam in tests (`ClaudeCredentialsKeychainDeleting`
#     is the existing one) — under this wrapper a test that reaches the real
#     `Security` framework will fail, by design.
#
# WHY THE TRIPWIRE SUPERSEDES THE FINGERPRINT. The fingerprint compares two
# directory listings, so it can only see a leak that changes the set of names.
# `createDirectory(withIntermediateDirectories: true)` on an *already existing*
# directory returns success without issuing a write syscall — so a leak that
# writes to a FIXED path is caught at most once, ever, and is silent on every
# run afterwards. (Leaks that mint a fresh name per run — the profile-dir leak
# minted a new UUID each time — are the ones it does catch, which is why that
# one eventually became visible.) The tripwire has no such blind spot: it fails
# on the permission check at the call site, not on a state diff, so it fires
# every run and names the culprit. Corollary for anyone testing a guard: **start
# from a clean state.** A leftover directory from an earlier unfenced run makes
# a correctly-working fence look bypassed, because the re-create silently
# succeeds. That misdiagnosis has already happened once.
#
# WHY DETECTION IS CI-ONLY, AND WHY THE DEFAULT SAYS SO. It is trustworthy only
# where nothing else writes to those directories, and that means a CI runner: no
# live daemon, no real worktrees, no sibling checkouts. The fingerprint brackets
# a build plus a full suite — minutes, on a developer box where a running daemon
# legitimately creates `worktrees/<slot>/<name>`, `scratch/`, `notes/` and
# `channels/` entries, any sibling worktree running `scripts/restart.sh` drops a
# top-level `state.db.pre-migration.<ts>`, Claude Code writes into `~/.claude`
# throughout, and any concurrent session starting an agent in a new directory
# mints a fresh `~/.claude/projects/<cwd-hash>`. Those are real writes by real
# software, not leaks, and a guard that reddens on them gets switched off inside
# a week.
#
# So the DEFAULT follows the argument instead of contradicting it: detection is
# on when `$CI` is set and off otherwise. It is not "on unless the one caller
# who knows better opts out" — a developer running this wrapper directly used to
# inherit a guard written for a machine they are not on. `--fingerprint` turns it
# on locally for a deliberate leak hunt (do it on an otherwise-quiet box);
# `--no-fingerprint` forces it off anywhere, including CI. The fence is the layer
# that actually *stops* leaks, and it is never optional.
#
# All seven FENCE vars are OVERWRITTEN, not defaulted: an inherited value is
# discarded for the duration of the run. That is the point — a fence you can
# disable by exporting something first is not a fence — but it does mean this
# wrapper cannot be pointed at a config dir of your own.
#
# `TBD_SWIFT_LOCK_PATH`, the eighth, is the deliberate exception: it is
# admission control rather than isolation, an inherited value names a lock the
# caller wants this run to contend on, and honouring it can only ever make the
# run wait for more things. Nothing about the fence weakens if it is respected.
#
# They are applied as a prefix on the `swift test` invocation rather than
# exported, so this script's own `$HOME` and `$TMUX_TMPDIR` stay real and
# `scripts/tbd-home-fingerprint.sh` — which deliberately reads both — needs
# no special-casing on either side of the run. The shared-lock computation below
# depends on the same property: it reads the real `$HOME` / `$TBD_HOME`, which
# only works because nothing here has exported the fenced values.
#
# `--fingerprint` / `--no-fingerprint` are consumed wherever they appear; every
# other argument is forwarded to `swift test` untouched. Position-independent on
# purpose: a leading-only strip forwards a late `--no-fingerprint` to `swift
# test`, which errors out. That is loud rather than silent, but a positional
# collision is impossible — `swift test` has no flag of either name — so
# filtering them out everywhere is strictly safer at no cost. Last one wins.
#   scripts/test.sh
#   scripts/test.sh --parallel --filter '^TBDDaemonTests\.'
#   scripts/test.sh --no-fingerprint --parallel
#   scripts/test.sh --fingerprint            # deliberate local leak hunt
#
# THE REMOTE VERIFICATION VALVE — OFF UNLESS `TBD_REMOTE_VERIFY=1`.
# (docs/specs/2026-08-16-remote-verification-valve-design.md.) This wrapper is
# the only caller that opts in, because it is the one whose entire output is a
# verdict: nothing it produces has to exist on this disk, so the same bit can be
# computed on GitHub. `scripts/restart.sh` and every other artifact build stay
# local permanently and are untouched by any of this.
#
# Enabled, the run bounds its queueing: `TBD_SWIFT_QUEUE_YIELD_SECONDS` tells
# `scripts/swift-safe` to give up its place in the queue after
# `TBD_REMOTE_VERIFY_YIELD_SECONDS` (default 300) and answer 76. The threshold
# measures QUEUE time, never run time, so a yield discards nothing — a wait that
# never acquired the slot has compiled nothing. 300 is sized against remote
# capacity rather than impatience: two hours of sampled contention put T=60 at
# ~28 trips an hour against a remote that sustains ~12 runs an hour, while T=300
# fires four or five times, on the tail this valve exists for.
#
# OFF, THE BOUND IS CLEARED RATHER THAN LEFT ALONE, and that is what makes
# "off" mean the pre-valve behavior exactly. `TBD_SWIFT_QUEUE_YIELD_SECONDS` is
# a knob `swift-safe` documents and honours on any `test` run, whether or not
# this valve is enabled — so a caller who exported it would otherwise yield 76
# with the valve off, down a path that does not route, and this wrapper would
# exit 76 having tested nothing.
#
# THREE EXIT CODES DECIDE WHAT HAPPENS NEXT, AND CONFLATING ANY TWO IS A SILENT
# WRONG ANSWER:
#
#   76 from `swift-safe` — it yielded the queue at our request. Verify remotely.
#   75 from `swift-safe` — the wait TIMED OUT, or was ABANDONED because nobody
#      is left to read the result. Neither is a request to verify elsewhere, so
#      75 is propagated untouched; dispatching one spends a scarce remote slot
#      on a verdict nobody wants.
#   78 from `remote-verify.sh` — a precondition refused (dirty tree, no `gh`,
#      no pushable ref). The run falls back to the local queue. THE VALVE IS AN
#      OPTIMISATION, NEVER A GATE: a refusal must never fail a run.
#
# `remote-verify.sh` answers 0 for a green remote run and 1 for a red one whose
# failing tests it has already printed. THOSE TWO, AND ONLY THOSE TWO, ARE
# VERDICTS. Everything else it can produce — 127 for a mangled interpreter line,
# 130 for a Ctrl-C, 2 for a syntax error in it — says nothing about the tests,
# and adopting one would report a suite that never ran as a failing suite. Any
# status outside `{0, 1, 78}` is therefore treated exactly as 78 is, with the
# status named on the way past.
#
# A NARROWED RUN ROUTES, BUT ITS VERDICT IS READ DIFFERENTLY — AND THE
# ASYMMETRY IS THE WHOLE MECHANISM. This wrapper forwards `--filter` and friends
# to `swift test`, and the dispatch has no way to carry them, so a remote run is
# always the WHOLE suite. The two outcomes are not equally transferable:
#
#   GREEN whole-suite IS sound for a narrowed caller. If every test passed, then
#      every subset of them passed, whatever the caller selected. It is adopted,
#      with one line saying the run was the whole suite so nobody reads its test
#      count as their subset's.
#   RED whole-suite IS NOT. The failures may lie entirely outside what the
#      caller selected, and reporting them as this run's result would name tests
#      it deliberately excluded. The narrowed suite is re-run locally instead and
#      the LOCAL verdict is reported.
#
# WHY NOT JUST REFUSE TO ROUTE A NARROWED RUN, which would need no interpretation
# at all: because it turns the valve off for every real caller. `pre-push`
# narrows both of its passes, the nightly stress harness forwards a filter, and
# four of five live queued test lanes were `--filter` runs. Interpreting the
# verdict keeps all of them eligible, and costs a local re-run only on red — the
# case that was going to run locally anyway.
#
# ONE CONSEQUENCE WORTH KNOWING, because it is a real loss and not a wash.
# `pre-push` gives each pass a test-count floor, and a floor is a minimum, so a
# whole-suite count clears a narrowed pass's floor for free — including the
# tier-3 pass whose floor of 35 exists to catch `--filter` matching nothing. A
# renamed live-suite type slips past that pass whenever its verdict came from a
# green whole-suite remote run. The floors still catch a collapse; they stop
# catching a vacuous filter. The follow-up below is what fixes it properly.
#
# THE COUNT MUST DESCRIBE THE RUN BEING REPORTED, and on the narrowed-red path
# that is the LOCAL re-run rather than the remote suite. Those consumers take
# the FIRST count in the log, so a remote count printed on the way past would
# answer for a verdict nobody adopted — see the `--narrowed` handoff at the
# dispatch below, which is what keeps it out of the log.
#
# TESTED BY `scripts/test.test.sh`, which drives the guards below against
# fixture directories with a stub `swift` — no build, no real `~/tbd`. Every
# guard there is mutation-checked: the assertion is shown going red against a
# deliberately weakened copy of this file. A guard nobody can break on purpose
# is a guard nobody can prove works.

# ---------------------------------------------------------------------------
# GUARD HELPERS
#
# Defined above the source guard so the harness can call them directly — the
# uid arm in particular cannot be reached by running this script, since a test
# cannot create a directory owned by somebody else without root. Strict mode is
# set below, after the guard, so sourcing this file has no side effects at all.
# ---------------------------------------------------------------------------

fence_bail() {
  echo >&2
  echo "=======================================================================" >&2
  echo "  REFUSING TO RUN — THE TEST FENCE'S OWN SCRATCH HOME IS NOT SAFE" >&2
  echo "=======================================================================" >&2
  echo >&2
  echo "  $1" >&2
  echo >&2
  echo "This wrapper chmods 000 the decoy directories inside its fake home. If" >&2
  echo "that path is a symlink, or a directory somebody else owns, the chmod" >&2
  echo "resolves through it and lands on whatever it points at — which is how a" >&2
  echo "planted symlink would take out the real ~/tbd and ~/.claude." >&2
  echo >&2
  echo "Inspect the path above, remove it if it is not yours, and re-run." >&2
  echo >&2
  exit 1
}

# A path is safe to chmod only if it is a real directory (never a symlink; the
# `-L` test must come BEFORE any mkdir, which would otherwise succeed through
# it) owned by this uid.
require_owned_dir() {
  local path="$1" what="$2"
  [ -L "$path" ] && fence_bail "$what is a SYMLINK: $path"
  [ -e "$path" ] && [ ! -d "$path" ] && fence_bail "$what exists but is not a directory: $path"
  return 0
}

# The post-`mkdir` half. `stat -f '%u'` is deliberately not given `-L`, so a
# path that turned into a symlink between the two calls reports the link's own
# owner rather than the target's — but the `-L` test above it is what actually
# rejects that case.
#
# THE RESIDUAL TOCTOU IS ACCEPTED, DELIBERATELY. A same-uid process could swap
# the directory for a symlink between this check and the `chmod` that follows.
# Closing it needs an fd held across both — `open(O_NOFOLLOW)` then `fchmod` —
# which bash cannot express, so the fix would be a helper binary. It buys
# nothing: every parent directory on the path is already mode 700 and owned by
# this uid ($TMPDIR is per-user on darwin, and the `/tmp` fallback is chmod
# 700'd immediately after this check), so the only process that can win the
# race is one already running as this user, which can simply chmod the target
# directly and needs no race at all. The checks exist to stop a FOREIGN uid
# planting a symlink in a world-writable `/tmp`, and against that threat they
# are not racy: the sticky bit means only the owner can replace an entry.
require_owned_dir_after_mkdir() {
  local path="$1" what="$2" owner
  [ -L "$path" ] && fence_bail "$what is a SYMLINK: $path"
  [ -d "$path" ] || fence_bail "$what is not a directory: $path"
  owner="$(stat -f '%u' "$path")"
  [ "$owner" = "$(id -u)" ] || fence_bail "$what is owned by uid $owner, not $(id -u): $path"
}

# THE SHARED ADMISSION LOCK. The branches mirror `_lock_path()` in
# `scripts/swift-safe`: an explicit `TBD_SWIFT_LOCK_PATH` wins, otherwise
# `$TBD_HOME/runtime/…`, otherwise `~/tbd/runtime/…`. Mirroring rather than
# inventing a path of our own is what makes a fenced run contend with the plain
# `scripts/swift-safe build` a sibling worktree is running; a lock nobody else
# takes is not a lock.
#
# It must be called while `$HOME` and `$TBD_HOME` still hold the CALLER's real
# values. See the call site.
resolve_swift_lock_path() {
  if [ -n "${TBD_SWIFT_LOCK_PATH:-}" ]; then
    printf '%s\n' "$TBD_SWIFT_LOCK_PATH"
  else
    printf '%s\n' "${TBD_HOME:-$HOME/tbd}/runtime/swift-build.lock"
  fi
}

# THE YIELD BOUND IS VALIDATED HERE BECAUSE A BAD ONE IS INVISIBLE DOWNSTREAM.
# `scripts/swift-safe` refuses a non-positive, `nan`, `inf` or non-numeric
# `TBD_SWIFT_QUEUE_YIELD_SECONDS` with a `SystemExit`, and a `SystemExit` carrying
# a message exits **1** — which is exactly what a failing test suite returns. So
# a forwarded typo does not look like a misconfiguration, it looks like a red
# run, and the fix people would reach for is to go hunting through tests that
# never ran. `TBD_REMOTE_VERIFY_YIELD_SECONDS=0` is the plausible way somebody
# spells "always go remote", and it lands precisely there.
#
# The accepted grammar is deliberately narrower than `float()`: decimal digits
# with at most one point, and not zero in any spelling. That refuses `1e3` and
# `+1`, which `swift-safe` would have taken — loudly, at the call site, with the
# variable named — rather than widening a validator whose whole job is to be
# obviously right.
valid_yield_bound() {
  local value="$1"
  case "$value" in
    ''|*[!0-9.]*) return 1 ;;   # empty, or anything but digits and points
    *.*.*)        return 1 ;;   # more than one point
    .)            return 1 ;;   # a lone point
  esac
  # Zero in every spelling — `0`, `00`, `0.0`, `.0` — is what is left once the
  # zeros and the point come out.
  case "${value//0/}" in
    ''|.) return 1 ;;
  esac
  return 0
}

# THE ARGUMENTS THAT REDUCE THE SUITE. This does not decide WHETHER to route —
# a narrowed run routes like any other — it decides how the answer is read. A
# routed run is always the whole suite, and only its GREEN answer transfers to a
# caller who asked for less (whole suite passed ⟹ every subset passed). Its red
# answer does not, so a narrowed caller re-runs locally to attribute it. See
# "A NARROWED RUN ROUTES" above.
#
# FOLLOW-UP: pass the caller's narrowing arguments to the dispatch, so a narrowed
# run gets a narrowed remote verdict and there is nothing left to interpret. That
# input is attacker-adjacent text — a filter is a regex that may legally contain
# `$`, backticks and `;` — so it must be ALLOWLISTED against these same names and
# handed to the workflow through `env:`, never interpolated into a `run:` body.
# `.github/workflows/preflight-cleanup.yml` already does exactly that with a
# branch name, and the comment there says why.
#
# The list is deliberately allowed to be over-broad, and the new reading makes
# that cheaper than it was. A false positive now costs one local re-run, and only
# on a red remote verdict — the case that was going to run locally anyway. A
# false negative adopts a whole-suite failure as a narrowed run's result, naming
# tests the caller excluded. So anything that plausibly reduces what runs belongs
# here.
#
# THE ENTRIES, AND WHY EACH ONE IS ON THE LIST. Read out of this toolchain's own
# `swift-test` binary rather than remembered, because a name that does not exist
# costs nothing and a name that does and is missing is the expensive direction:
#
#   --filter / --skip           select and deselect test cases by regex.
#   --specifier / -s            the deprecated spelling of `--filter` (the
#                               binary still carries `'--specifier' option is
#                               deprecated; use '--filter' instead`), so a
#                               caller using it narrows exactly as much.
#   --disable-xctest            drops a whole testing library's cases.
#   --disable-swift-testing
#   --test-product              restricts the run to ONE test product, which on
#                               a multi-product package is the largest reduction
#                               available. The binary names it itself: "found
#                               multiple test products: …; use --test-product to
#                               select one".
#   --list-tests                the extreme case — it runs NOTHING and only
#                               prints method names. A whole-suite verdict is not
#                               an answer to that question in either direction.
#   list                        `swift test list` is the same thing as a
#                               subcommand. It is a bare word rather than a
#                               flag, so it matches a `--filter list` value too;
#                               that is a false positive, and false positives
#                               are the cheap direction.
SUITE_NARROWING_ARGS=(
  --filter --skip
  --specifier -s
  --disable-xctest --disable-swift-testing
  --test-product
  --list-tests list
)

narrows_the_suite() {
  local arg known
  for arg in "$@"; do
    for known in "${SUITE_NARROWING_ARGS[@]}"; do
      # Both spellings: `--filter X` and `--filter=X`.
      case "$arg" in
        "$known"|"$known"=*) return 0 ;;
      esac
    done
  done
  return 1
}

# Sourced rather than executed: `scripts/test.test.sh` wants the helpers above
# without the run below. The siblings in this directory express the same thing
# as `main "$@"` under the inverse condition; this script stays straight-line
# because every statement below is a step of one fence that runs exactly once,
# and there is nothing to call twice.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0
fi

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# On in CI, off on a developer box. See "WHY DETECTION IS CI-ONLY" above.
fingerprint=0
if [ -n "${CI:-}" ]; then
  fingerprint=1
fi
swift_test_args=()
for arg in "$@"; do
  case "$arg" in
    --no-fingerprint) fingerprint=0 ;;
    --fingerprint) fingerprint=1 ;;
    *) swift_test_args+=("$arg") ;;
  esac
done

# THE VALVE, CONFIGURED BEFORE ANYTHING ELSE HAPPENS. See "THE REMOTE
# VERIFICATION VALVE" above. Deciding it here means a bad bound is refused
# before a scratch home is minted, a lock file is touched or a fingerprint is
# taken — there is nothing to unwind, and the caller finds out immediately
# rather than half an hour into a wait.
#
# `TBD_REMOTE_VERIFY` unset leaves `remote_verify_enabled` at 0 and the bound
# CLEARED, so every path below is what it was before the valve existed: the
# run queues without limit, and 76 can only be the suite's own exit status.
DEFAULT_REMOTE_VERIFY_YIELD_SECONDS=300
YIELDED_THE_QUEUE=76
REMOTE_VERIFY_REFUSED=78

remote_verify_enabled=0
caller_narrowed=0
# THE BOUND IS CLEARED, NOT LEFT ALONE — the same distinction the fallback
# below turns on, and the valve-off path needs it just as badly. An empty
# array only stops this script from ADDING the assignment; an inherited
# `TBD_SWIFT_QUEUE_YIELD_SECONDS` passes straight through `env`, and
# `swift-safe` gates the yield on the subcommand alone and knows nothing about
# `TBD_REMOTE_VERIFY` — so the run would yield 76 with the valve off, the
# routing below would not fire, and the wrapper would exit 76 having tested
# nothing. `scripts/git-hooks/pre-push` runs this script with no scrubbing and
# BLOCKS THE PUSH on that status, and `swift-safe`'s own docstring presents the
# knob as supported, so the developer who exported it is doing nothing odd.
# An explicit empty value wins in `env` and is falsy in `swift-safe` ("never
# yield"), which is the pre-valve behavior "unset" is supposed to mean.
fenced_env=(TBD_SWIFT_QUEUE_YIELD_SECONDS=)
if [ "${TBD_REMOTE_VERIFY:-}" = "1" ]; then
  remote_verify_enabled=1
  # `:-`, SO AN EMPTY VALUE MEANS "NOT SET" RATHER THAN FAILING THE RUN. The
  # alternative — a bare `-`, which substitutes only for an UNSET variable — sends
  # the empty string to the validator, which refuses it and exits 64. That is the
  # wrong trade in three directions:
  #
  #   - Empty conventionally means unset in shell. `TBD_REMOTE_VERIFY_YIELD_SECONDS=`
  #     is how a script clears an inherited value, and how `env VAR=` and an
  #     unquoted `"$maybe_unset"` both arrive. Refusing it makes clearing a knob
  #     an error.
  #   - Nothing needs empty to be an error, because empty is not how the valve is
  #     turned off — that is `TBD_REMOTE_VERIFY` unset, which never reaches this
  #     block at all. So a refusal here cannot be protecting a caller who meant
  #     "do not go remote"; it can only be answering a caller who meant "use the
  #     default".
  #   - The cost of refusing is not confined to this script. `scripts/git-hooks/
  #     pre-push` runs the suite to decide whether a push may proceed, and an exit
  #     of 64 there BLOCKS THE PUSH — over an empty knob that asked for nothing.
  #
  # The validator still refuses empty, and that is deliberate: it is the guard for
  # a value somebody actually typed. `0`, `nan` and `later` are typos with an
  # intent behind them and must be named; empty is the absence of a value, and the
  # two do not want the same answer.
  yield_seconds="${TBD_REMOTE_VERIFY_YIELD_SECONDS:-$DEFAULT_REMOTE_VERIFY_YIELD_SECONDS}"
  if ! valid_yield_bound "$yield_seconds"; then
    echo "test.sh: TBD_REMOTE_VERIFY_YIELD_SECONDS must be a positive number" >&2
    echo "         (decimal digits, at most one point), got: '$yield_seconds'" >&2
    echo "         Forwarding it would make swift-safe exit 1, which is" >&2
    echo "         indistinguishable from a failing test suite." >&2
    exit 64
  fi
  # ASKED ONCE, HERE, WHILE THE ARGUMENTS ARE IN FRONT OF US, and consulted
  # later when the remote answer arrives. It gates nothing: a narrowed run
  # forwards the bound and routes exactly like any other, because a green
  # whole-suite verdict is sound for it. What this decides is how a RED answer is
  # read — see the `case` on `$remote_status` below.
  if narrows_the_suite ${swift_test_args[@]+"${swift_test_args[@]}"}; then
    caller_narrowed=1
  fi
  fenced_env=(TBD_SWIFT_QUEUE_YIELD_SECONDS="$yield_seconds")
fi

# Resolved HERE, while `$HOME` and `$TBD_HOME` still hold the caller's real
# values — the `env` prefix at the bottom rewrites both, and `swift-safe`
# deriving the lock from the rewritten pair is exactly the bug this pins shut.
swift_lock_path="$(resolve_swift_lock_path)"

# Created BEFORE the fingerprint is taken, not left to `swift-safe`. The lock
# lives in the real `~/tbd`, so a run that materialises it mid-flight adds a
# `~/tbd/runtime` entry between the two snapshots and reddens the detection
# layer on any box where that directory does not exist yet — a CI runner, every
# time. Bringing it into existence up front puts it on BOTH sides of the diff.
# The detector already prunes this directory's contents as volatile (see
# `scripts/tbd-home-fingerprint.sh`), so nothing is hidden by doing so: the
# `runtime` entry itself is still fingerprinted, and every other name in `~/tbd`
# is still compared exactly as before.
mkdir -p "$(dirname "$swift_lock_path")"
: >> "$swift_lock_path"

fingerprint_before=""
if [ "$fingerprint" -eq 1 ]; then
  fingerprint_before="$(scripts/tbd-home-fingerprint.sh)"
fi

# `/tmp`, not `mktemp -d`'s default `$TMPDIR`: on darwin TMPDIR is a ~50-char
# path under /var/folders, and `sun_path` for a unix socket caps at ~104 bytes,
# so `$TMPDIR/<scratch>/sock` can overflow.
# `/tmp/tbd-test-home.XXXXXXXX/sanctioned/tbd/sock` is ~47 bytes and cannot.
#
# TBD_SOCKET_PATH is set anyway — it is the sanctioned escape hatch for that
# cap (see `TBDConstants.socketPath`) and pinning it here means a future move
# of this scratch dir to a deeper path cannot silently reintroduce the
# overflow. It is set to exactly the value TBD_HOME would derive, so
# `ConstantsTests.ProductionVarSmokeSuite.socketPathSuffix` — which asserts a
# `/sock` suffix — still holds under this wrapper.
#
# TBD_CLAUDE_HOST_HOME is the third leg and is easy to forget, because fencing
# `TBD_HOME` alone looks complete: a default-constructed
# `ClaudeProfileConfigDirManager` then gets a scratch `baseDirectory` and the
# developer's REAL `~/.claude` as its `hostBaseDirectory`, which
# `ensureMirrorSlot` creates directories in, moves whole subtrees within, and
# writes symlinks into.
#
# TBD_TEST_CODEX_HOME is the fourth, and it is the same omission one store over:
# `CodexHomeManager` falls back to `~/.codex` and `ensureProfilePlugin()`
# creates directories and writes a plugin manifest, hooks and a profile TOML
# there. It was previously left to individual tests to remember, which is
# exactly the shape the run-wide fence exists to replace.
#
# TMUX_TMPDIR is the fifth, and the store it fences is not a TBD one at all:
# `/tmp/tmux-<uid>`, shared by every tmux server this user runs. Nothing in
# `Sources/` or `Tests/` ever passes an absolute `-S <path>`; every call site
# uses `-L <name>`, which tmux resolves under `$TMUX_TMPDIR/tmux-<uid>/`, so
# this one variable redirects all of them.
#
# WHY IT MATTERS MORE THAN IT LOOKS: **tmux never unlinks its socket file on
# server exit** — measured against tmux 3.6a, and true for a killed server, a
# cleanly `kill-server`ed one and one that self-exits when its last session
# ends alike. It unlinks a stale socket lazily instead, at bind time, when a
# NEW server is started on that exact path. Every test here mints a fresh
# UUID-suffixed socket name, so that lazy unlink never fires and every file
# survives forever: ~7,100 dead socket files accumulated in one developer's
# real `/tmp/tmux-<uid>` over nine days, behind 7 live servers. No teardown
# can fix that — a test that dutifully kills its server still leaves the file
# — which is why the fix is a fenced directory that gets deleted wholesale,
# not a missing `kill-server` somewhere.
#
# IT MUST STAY DIRECTLY UNDER THE SHORT `/tmp` SCRATCH ROOT. tmux connects
# over a unix socket, so `$TMUX_TMPDIR/tmux-<uid>/<name>` is bound by the same
# ~104-byte `sun_path` cap as TBD's own socket, and tmux reports an overflow
# only as `error connecting to <path> (File name too long)`. The budget:
# `/tmp/tbd-test-home.XXXXXXXX/tmux/tmux-<uid>/` is ~42 bytes, and the suite's
# longest socket name is ~31 bytes today (`tbd-test-send-mismatch-` plus 8 hex
# characters) with 50 budgeted as headroom — ~92 bytes against ~104. Nesting
# this directory any deeper spends that headroom and every live tmux test
# starts failing at once. `scripts/test.test.sh` asserts the budget so a
# refactor that moves it cannot land quietly.
scratch_home="$(mktemp -d /tmp/tbd-test-home.XXXXXXXX)"
tmux_tmpdir="$scratch_home/tmux"

# THE SWEEP KILLS SERVERS; THE `rm -rf` ONLY REMOVES FILES. Those are not the
# same leak, and the expensive one is the process: unlinking a socket out from
# under a live tmux server leaves it running forever with nothing able to reach
# it. So every socket the run created is issued a `kill-server` BEFORE the
# scratch dir goes away. Most will already be dead — a dead server's file is
# still there (see above) — so errors are ignored throughout.
sweep_tmux_servers() {
  local tmux_bin socket_dir socket
  tmux_bin="$(command -v tmux || true)"
  # No tmux on PATH means no server this run could have started.
  [ -n "$tmux_bin" ] || return 0
  # `${var:-}` — defensive under `set -u`. The assignment above precedes the
  # trap today; this keeps that ordering from being load-bearing.
  [ -n "${tmux_tmpdir:-}" ] || return 0
  socket_dir="$tmux_tmpdir/tmux-$(id -u)"
  [ -d "$socket_dir" ] || return 0
  for socket in "$socket_dir"/*; do
    # `-e` rather than `-S`: it skips the unmatched-glob case, and tmux owns
    # this directory exclusively, so anything in it is one of its sockets.
    [ -e "$socket" ] || continue
    "$tmux_bin" -S "$socket" kill-server >/dev/null 2>&1 || true
  done
  return 0
}

cleanup() { sweep_tmux_servers; rm -rf "$scratch_home"; }
# EXIT alone is sufficient, including when this wrapper is killed:
# `scripts/nightly-flake-stress.sh` TERMs it when its outer deadline fires, and
# bash runs an EXIT trap on a fatal signal as well as on a normal exit —
# measured here, the scratch dir is gone either way. No INT/TERM handler needed.
#
# The other half of that interaction lives in the harness: it kills the process
# tree LEAVES FIRST, so `swift test` is already dead before bash gets round to
# this `rm -rf`. A parent-first kill would have this deleting a `TBD_HOME` an
# orphaned test run was still writing into.
trap cleanup EXIT

# THE TWO ROOTS HAVE DIFFERENT LIFETIMES, ON PURPOSE.
#
# The sanctioned root is the one above: fresh per run and deleted on exit.
# Reusing it would let one run's `state.db`, sockets and profile dirs be visible
# to the next, which is exactly the cross-run contamination the fence exists to
# prevent.
#
# The fake home is stable and deliberately NOT deleted, because setting
# `CFFIXED_USER_HOME` also relocates SwiftPM's own caches (`~/.swiftpm`,
# `~/Library/Caches/org.swift.swiftpm`) into it. A fresh fake home each run
# re-pays the manifest-cache miss every time: measured on this package,
# `swift package describe` went 0.191s unfenced to 0.553s fenced-and-cold. It
# holds only caches and the decoys — no test state — so persisting it
# contaminates nothing. (The module cache lives in `.build/` and is unaffected
# either way.)
#
# IT LIVES UNDER `$TMPDIR`, NOT `/tmp`. On darwin `$TMPDIR` is a per-user
# `/var/folders/...` directory, mode 700 and owned by the calling uid, so nobody
# else can pre-create anything inside it. `/tmp` is mode 1777: any local user —
# or any process running as this one — can plant `tbd-test-fakehome.<uid>` as a
# SYMLINK first, and `mkdir -p` on a symlink-to-a-directory succeeds silently
# while `chmod` resolves straight through it. Pointed at `$HOME`, that made this
# very loop `chmod 000` the developer's real `~/tbd` and `~/.claude` — reproduced
# — leaving a daemon that cannot open `state.db` and nothing pointing back here.
# The `/tmp` fallback below exists only for a stripped environment with no
# `TMPDIR`, and the ownership checks are what make it safe.
#
# The `sun_path` argument that pins the SANCTIONED root to `/tmp` does not apply
# here: it is about the socket, which lives under the sanctioned root, and
# `TBD_SOCKET_PATH` pins it there explicitly.
sanctioned_home="$scratch_home/sanctioned/tbd"
fake_home="${TMPDIR:-/tmp}"
fake_home="${fake_home%/}/tbd-test-fakehome.$(id -u)"
mkdir -p "$sanctioned_home"

# tmux creates `$TMUX_TMPDIR/tmux-<uid>` itself, but refuses if the parent is
# missing — so the parent is ours to make. Mode 700 for the same reason tmux
# insists on 700 for the directory it creates inside: a socket anyone can
# connect to is a shell anyone can type into. The scratch root is already
# ours alone; this is belt and braces on a `/tmp` path.
mkdir -p "$tmux_tmpdir"
chmod 700 "$tmux_tmpdir"

require_owned_dir "$fake_home" "the fake home"
mkdir -p "$fake_home"
require_owned_dir_after_mkdir "$fake_home" "the fake home"
# Ours, and only ours — closes the plant-a-decoy-inside hole on the `/tmp`
# fallback path, where the parent is world-writable.
chmod 700 "$fake_home"

# The decoys. These are the names a leak reaches for — `$HOME/tbd` is what
# `WorktreeLayout.basePath` used to hand-build, `$HOME/.claude` is what a
# default-constructed `ClaudeProfileConfigDirManager` mirrors into, and
# `$HOME/.codex` is what `CodexHomeManager` falls back to. Mode 000 turns
# "silently wrote to the developer's real store" into "this test failed, here,
# on this path".
#
# Recreated unconditionally rather than only when absent: a previous run that
# died between `mkdir` and `chmod`, or a stray `chmod` by a curious reader,
# would otherwise leave a permanently disarmed tripwire that nothing reports.
decoys=(tbd .claude .codex)
for decoy in "${decoys[@]}"; do
  require_owned_dir "$fake_home/$decoy" "the $decoy decoy"
  mkdir -p "$fake_home/$decoy"
  require_owned_dir_after_mkdir "$fake_home/$decoy" "the $decoy decoy"
  chmod 000 "$fake_home/$decoy"
done

# THE FENCED INVOCATION LIVES IN ONE PLACE, AND THAT IS THE POINT. The valve's
# fallback below runs it a second time, and a second copy of this `env` prefix
# is a fence that can drift: the two copies would have to be kept in step by
# hand forever, and the failure mode of missing one is a run that silently
# writes into the developer's real `~/tbd`. There is exactly one prefix, so
# there is nothing to keep in step.
#
# `fenced_env` carries per-call environment and comes FIRST, so a fence
# variable can never be overridden by it — `env` takes the last assignment of a
# name, and the fence must always be the last word.
#
# `${a[@]+"${a[@]}"}` — macOS ships bash 3.2, where a bare `"${a[@]}"` on an
# EMPTY array is an unbound-variable error under `set -u`.
run_fenced_suite() {
  env \
    ${fenced_env[@]+"${fenced_env[@]}"} \
    TBD_HOME="$sanctioned_home" \
    TBD_SOCKET_PATH="$sanctioned_home/sock" \
    TBD_CLAUDE_HOST_HOME="$sanctioned_home/claude-host" \
    TBD_TEST_CODEX_HOME="$sanctioned_home/codex-host" \
    TMUX_TMPDIR="$tmux_tmpdir" \
    TBD_SWIFT_LOCK_PATH="$swift_lock_path" \
    HOME="$fake_home" \
    CFFIXED_USER_HOME="$fake_home" \
    scripts/swift-safe test ${swift_test_args[@]+"${swift_test_args[@]}"}
}

# RETURNING TO THE LOCAL QUEUE, WHICH IS WHAT EVERY NON-VERDICT ENDS IN. The
# re-run must queue without limit: yielding a second time would strand the run
# at 76 with nothing tested and nothing said, because the valve block has
# already been passed.
#
# THE BOUND IS CLEARED, NOT DROPPED, AND THE DIFFERENCE IS THE WHOLE BUG.
# `fenced_env=()` stops this script from *adding* the assignment; it does not
# unset the variable, and `env` passes an inherited one straight through.
# `scripts/swift-safe` documents `TBD_SWIFT_QUEUE_YIELD_SECONDS` as a supported
# knob, so a caller exporting it alongside `TBD_REMOTE_VERIFY=1` is expected
# rather than perverse — and that caller's value would survive into this re-run,
# yield 76 again, and exit the wrapper at 76 having tested nothing. An explicit
# empty value wins in `env` and is falsy in `swift-safe` ("never yield"), which
# is exactly the pre-valve behavior this fallback is supposed to restore.
fall_back_to_the_local_queue() {
  fenced_env=(TBD_SWIFT_QUEUE_YIELD_SECONDS=)
  set +e
  run_fenced_suite
  test_status=$?
  set -e
}

set +e
run_fenced_suite
test_status=$?
set -e

# THE OVERFLOW PATH. 76 is `swift-safe` reporting that it gave up its place in
# the queue at our request, having compiled nothing — so there is no work to
# discard and no build to kill, and the same verdict can be fetched from CI.
#
# The flag is re-checked rather than inferred from the status. A bound is only
# ever forwarded when the valve is on, so 76 cannot arise here otherwise — but
# inferring it would mean a suite that exits 76 for reasons of its own silently
# changed what this wrapper does, and "the flag is off" must mean the pre-valve
# behavior exactly.
if [ "$remote_verify_enabled" -eq 1 ] && [ "$test_status" -eq "$YIELDED_THE_QUEUE" ]; then
  # A MISSING REMOTE PATH IS A REFUSAL, NOT A VERDICT. Without this the shell
  # answers 127 for "command not found", which would be adopted below as the
  # run's exit status — a broken checkout reported as a failing test suite, with
  # nothing said about why. Everything else here exists to keep a misrouted exit
  # code from masquerading as a test result; so does this.
  if [ ! -x scripts/remote-verify.sh ]; then
    echo "test.sh: scripts/remote-verify.sh is missing or not executable;" >&2
    echo "         staying in the local queue instead of verifying remotely." >&2
    remote_status=$REMOTE_VERIFY_REFUSED
  else
    # THE NARROWING IS DECLARED TO THE REMOTE PATH, AND IT IS THE COUNT LINE
    # THAT MAKES IT NECESSARY. Six consumers read a run's population out of the
    # first `Test run with N tests` in the log — `scripts/git-hooks/pre-push`
    # pipes BOTH streams into its own — and a failing whole-suite report is
    # printed BEFORE the local re-run below prints its own count. So without
    # this the remote suite's number is the one `head -1` finds, standing in for
    # a run whose verdict is not even being reported: a tier-3 pass whose
    # `--filter` names a renamed type selects nothing, exits 0 saying `Test run
    # with 0 tests`, and clears its floor of 35 on the remote's four thousand.
    # The vacuous filter the floor exists to catch would go undetected.
    #
    # `--narrowed` tells the driver to omit the count from a FAILING report, so
    # the only count in the log is the local re-run's. A PASSING report keeps
    # its count: there the remote verdict is the one adopted and reported, and a
    # whole-suite count clears a narrowed floor legitimately, a minimum against
    # a superset. See "A NARROWED RUN ROUTES" above.
    remote_verify_args=()
    if [ "$caller_narrowed" -eq 1 ]; then
      remote_verify_args=(--narrowed)
    fi
    # Deliberately NOT fenced: the remote path needs the caller's real `$HOME`
    # to find `gh`'s credentials and the real repository to push from. It
    # touches no TBD-owned path.
    set +e
    scripts/remote-verify.sh ${remote_verify_args[@]+"${remote_verify_args[@]}"}
    remote_status=$?
    set -e
  fi

  # ONLY THE CONTRACT'S OWN STATUSES DECIDE ANYTHING; THE REST FALL BACK. The
  # branches are listed as a whitelist rather than "78 means refuse, everything
  # else is the answer", because the set of things that can come out of running
  # a script is open-ended and every one of them outside the contract is a
  # non-answer: 127 for an interpreter that is not there, 126 for a lost
  # executable bit, 130 for a Ctrl-C, 2 for a syntax error. Adopting any of them
  # reports a suite that never ran as a suite that failed.
  case "$remote_status" in
    0)
      # GREEN TRANSFERS TO EVERY SUBSET. The whole suite passed, so whatever the
      # caller selected passed with it — the one direction the asymmetry runs in.
      # The count is the only thing that does not transfer, hence the note.
      if [ "$caller_narrowed" -eq 1 ]; then
        echo "test.sh: verified remotely, and the remote run was the WHOLE suite." >&2
        echo "         Its test count is not this run's narrowed subset — a green" >&2
        echo "         whole suite implies the subset passed, which is why the" >&2
        echo "         result is adopted." >&2
      fi
      test_status=0
      ;;
    1)
      # RED DOES NOT TRANSFER. For an unnarrowed caller this is simply the
      # verdict, with its failing tests already printed. For a narrowed one the
      # failures may lie entirely outside what was selected, so adopting them
      # would name tests this run excluded; the narrowed suite is re-run locally
      # to get a verdict that describes what was asked for.
      if [ "$caller_narrowed" -eq 1 ]; then
        echo "test.sh: the remote WHOLE-SUITE run failed, and its failures cannot" >&2
        echo "         be attributed to this narrowed run — they may lie entirely" >&2
        echo "         outside it. Re-running the narrowed suite locally, and" >&2
        echo "         reporting THAT verdict." >&2
        fall_back_to_the_local_queue
      else
        test_status=1
      fi
      ;;
    "$REMOTE_VERIFY_REFUSED")
      # A REFUSAL IS NOT A FAILURE. The remote path named its condition on
      # stderr and declined; this lane returns to the local queue and waits it
      # out, as it would have done before the valve existed. Anything else would
      # make the valve a gate — a run that cannot go remote must still be able
      # to test.
      fall_back_to_the_local_queue
      ;;
    *)
      # OUTSIDE THE CONTRACT ENTIRELY, so it is treated as a refusal and named.
      # A refusal explains itself on stderr; this one cannot, so the wrapper
      # says what it saw. Silence here would leave a broken remote path looking
      # like an ordinary local run forever.
      echo "test.sh: scripts/remote-verify.sh exited $remote_status, which is" >&2
      echo "         outside its {0, 1, 78} contract and says nothing about the" >&2
      echo "         tests; treating it as a refusal and staying in the local" >&2
      echo "         queue." >&2
      fall_back_to_the_local_queue
      ;;
  esac
fi

# THE TRIPWIRE HAS TO BE RE-CHECKED, not just armed. The code inside the run
# owns these directories, so it can chmod them back — and a decoy that comes
# back readable is a disarmed tripwire that reports nothing on every subsequent
# run, since the fake home persists. (The fingerprint has the equivalent check
# by construction: it compares before against after. This layer needs it
# spelled out.)
for decoy in "${decoys[@]}"; do
  path="$fake_home/$decoy"
  [ -L "$path" ] && fence_bail "the $decoy decoy became a SYMLINK during the run: $path"
  [ -d "$path" ] || fence_bail "the $decoy decoy is no longer a directory: $path"
  mode="$(stat -f '%Lp' "$path")"
  [ "$mode" = "0" ] || fence_bail "the $decoy decoy came back mode 0$mode, not 000 — the run disarmed the tripwire: $path"
done

if [ "$fingerprint" -eq 0 ]; then
  exit "$test_status"
fi

fingerprint_after="$(scripts/tbd-home-fingerprint.sh)"

if [ "$fingerprint_before" != "$fingerprint_after" ]; then
  echo >&2
  echo "=======================================================================" >&2
  echo "  THE TEST RUN WROTE INTO ~/tbd, ~/.claude, ~/.codex OR /tmp/tmux-<uid>" >&2
  echo "=======================================================================" >&2
  echo >&2
  echo "CLAUDE.md: \"Tests must not touch ~/tbd\". Something resolved a real" >&2
  echo "config path despite TBD_HOME=$sanctioned_home," >&2
  echo "TBD_CLAUDE_HOST_HOME=$sanctioned_home/claude-host," >&2
  echo "TBD_TEST_CODEX_HOME=$sanctioned_home/codex-host," >&2
  echo "TMUX_TMPDIR=$tmux_tmpdir and" >&2
  echo "HOME=CFFIXED_USER_HOME=$fake_home." >&2
  echo >&2
  echo "Entries added (+) or removed (-):" >&2
  diff <(printf '%s\n' "$fingerprint_before") <(printf '%s\n' "$fingerprint_after") \
    | grep -E '^[<>]' | sed 's/^</  - /; s/^>/  + /' >&2 || true
  echo >&2
  echo "Usual causes: a static/ambient helper that ignores its caller's" >&2
  echo "injected seam, or a path hand-built from \$HOME instead of going" >&2
  echo "through TBDConstants. Fix the leak — do not delete the entries and" >&2
  echo "move on; ~/tbd holds real state (see \"NEVER delete ~/tbd/state.db\")." >&2
  echo >&2
  echo "If the entry is a tmux socket, the fix is TMUX_TMPDIR — never a" >&2
  echo "relaxed guard and never a teardown. tmux does NOT unlink its socket" >&2
  echo "file when a server exits, so killing the server leaves the file" >&2
  echo "behind; the only thing that removes it is deleting the directory it" >&2
  echo "lives in, which this wrapper can do only for a directory it owns." >&2
  echo "Something spawned tmux with an environment that dropped TMUX_TMPDIR:" >&2
  echo "look for a Process whose \`environment\` is built from scratch." >&2
  echo >&2
  echo "Reaching here at all is now unusual: a hand-built \$HOME path normally" >&2
  echo "dies at its call site on the mode-000 decoys in $fake_home." >&2
  echo "A leak that got past those wrote somewhere the decoys do not cover —" >&2
  echo "note the path above and consider whether it needs a third decoy." >&2
  echo >&2
  exit 1
fi

exit "$test_status"
