#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "TestProcessDefaults.h"

/// Keeps the test process alive when something writes to a pipe or socket
/// whose reader has gone, and says so on stderr.
///
/// Such a write raises SIGPIPE, and SIGPIPE's default action ends the process.
/// The repo guards its descriptors one at a time — `SO_NOSIGPIPE` on the
/// holder tests' client socket, `F_SETNOSIGPIPE` on `collectOutput(of:)`'s
/// stdin pipe — but one unguarded write anywhere in the process, from a test
/// or from production code under test, ends the whole pass. CI run
/// 41357078295 (attempt 3) lost a fast pass that way: the Swift Testing
/// runner (`swiftpm-testing-helper … --testing-library swift-testing`) died
/// with "unexpected signal code 13", every test still to run went unreported,
/// there was no summary line, and the xUnit file was truncated. Holder,
/// peer-helper and repo-cloner suites were in flight; which write it was is
/// unknown.
///
/// So the test host catches SIGPIPE. The write that raised it fails with EPIPE
/// in the code that made it, as it would under `SO_NOSIGPIPE`, the pass
/// carries on, and the handler writes a line to stderr so the unguarded write
/// still shows up in the CI log (`Tests/CLAUDE.md` says what to do with one).
///
/// **A handler, not `SIG_IGN`, because of what `exec` does with each.** A
/// caught signal is reset to `SIG_DFL` in the new image by `execve` and by
/// `posix_spawn`; an ignored one stays ignored. With `SIG_IGN`, every child
/// the test process itself starts through `posix_spawn`, `fork`/`exec` or
/// `forkpty` would start with SIGPIPE ignored (Foundation's `Process` resets
/// dispositions itself, so only its children are spared): the `yes` in a
/// `yes | head` that a test's shell runs would no longer be ended by the
/// signal, and a child that relies on SIGPIPE to stop writing into a closed
/// pipe would keep going. With a
/// handler, those children start exactly as they would without it. Blocking
/// SIGPIPE in the signal mask is ruled out for the same reason: a mask
/// survives `exec` too, and it is per thread, so it would have to reach every
/// thread the process ever starts.
///
/// **The flags: `SA_RESTART` only, and what it does not cover.** XNU raises the
/// SIGPIPE from a pipe or socket write at the process (`psignal`), not at the
/// writing thread. The write itself just returns EPIPE; the handler runs on
/// whichever thread does not block SIGPIPE, and interrupts whatever that
/// thread is blocked in. `SA_RESTART` resumes most interrupted `read`,
/// `write`, `accept` and `wait` calls. On Darwin it does not resume:
///
///   - `select`, `poll` and `kevent` with a timeout;
///   - `nanosleep` and `usleep`;
///   - `connect`, which turns the restart into EINTR and leaves the connection
///     completing in the background;
///   - socket calls on a socket with `SO_RCVTIMEO` or `SO_SNDTIMEO` set.
///
/// Those return EINTR whatever the flags. That is the trade: a stray SIGPIPE
/// can now cost one EINTR in an unrelated thread, where before it cost the
/// whole pass. `SIG_IGN` would cost neither, since an ignored signal
/// interrupts nothing, but it leaks into children as above. No `SA_RESETHAND`,
/// which would leave the second stray write fatal; no `SA_NODEFER`, so the
/// handler never re-enters on its own thread; no `SA_SIGINFO`, since the
/// handler reads nothing; and an empty `sa_mask`.
///
/// **The handler uses only async-signal-safe operations**: lock-free atomic
/// loads, stores and read-modify-writes, `write(2)` of a fixed line, and
/// saving and restoring `errno`, so the interrupted code sees what it would
/// have seen. No formatting, no allocation, no stdio, no locks, and no
/// `os.Logger`: any reporting beyond the line belongs outside the handler,
/// reading `TBDTestHostSIGPIPECount()`. The counters are lock-free atomics
/// rather than `volatile sig_atomic_t`: SIGPIPE is blocked only on the thread
/// running the handler, so two threads can run it at once, and `++` on a
/// volatile can lose a count where an atomic read-modify-write cannot (a
/// lock-free one is async-signal-safe, which the `_Static_assert` below
/// holds). It counts catches, not writes: signals do not queue, so SIGPIPEs
/// raised while one is still pending merge into one delivery (measured: 120
/// such writes from two threads at once were caught 3 times in one run and
/// 62 in another). The first
/// `TBD_MAX_LOGGED_SIGPIPES` catches are logged and the rest only counted,
/// which also bounds the one loop the line could start: a write to a closed
/// stderr raises SIGPIPE again.
///
/// **A test that provokes a SIGPIPE on purpose says so first**, with
/// `TBDTestHostExpectSIGPIPE()`, and the handler logs that catch with a line of
/// its own, so a stray one stays easy to find in a CI log (the same convention
/// as `MainRunLoopGuard.m`'s expected stop). The mark goes to whichever SIGPIPE
/// arrives next, so a stray one racing a test's own can swap their lines.
///
/// **It replaces only the default and `SIG_IGN`.** `sa_handler` and
/// `sa_sigaction` share a union, so the disposition is read through it first:
/// `SIG_DFL` or `SIG_IGN` gets this handler even when a stale `SA_SIGINFO`
/// flag rides along, and only a real handler, of either kind, counts as
/// someone else's. That one is left in place, with a line on stderr: that code
/// chose it, and it already keeps the process alive. A `SIG_IGN` inherited
/// from whatever launched the runner is replaced, with a line on stderr,
/// because children would inherit it. Otherwise the install is silent, as
/// `MainRunLoopGuard.m`'s is.
///
/// **Every pass gets it.** SwiftPM links the one `TBDPackageTests.xctest`
/// bundle, which every test target shares, from the object files of every
/// target in it rather than from archives, so this constructor is always in
/// the bundle; no Swift reference is needed to keep it. Each CI pass runs that
/// bundle with `--filter`/`--skip`, and the constructor runs when the runner
/// loads it, before any test: in `swiftpm-testing-helper` for Swift Testing and
/// in `xctest` for XCTest. `TestHostSIGPIPEHandlerTests` (in `TBDAppTests`)
/// pins the disposition, the exec reset, the EPIPE and the count, and a
/// one-test suite in every other pass checks the disposition in that pass's
/// own process: `HostSIGPIPECheckAToPTests` (`TBDAppTests` A–P),
/// `HostSIGPIPECheckAToOTests` and `SIGPIPECheckPToZTests` (the two
/// `TBDDaemonTests` halves) and `HostSIGPIPECheckLiveTests` (the quiet pass).
///
/// This is a net under the per-descriptor guards, not a replacement for them.
/// The app leaves SIGPIPE at its default, so its sockets and pipes still need
/// `SO_NOSIGPIPE` or `F_SETNOSIGPIPE` (see `Sources/TBDApp/SocketSIGPIPE.swift`).
/// And a test must not set SIGPIPE's disposition itself: that would replace
/// this handler process-wide, for every suite running alongside it. The
/// SwiftLint rule `no_sigpipe_disposition_in_tests` holds that.
#define TBD_MAX_LOGGED_SIGPIPES 100
#define TBD_STRINGIFY(x) #x
#define TBD_EXPAND_AND_STRINGIFY(x) TBD_STRINGIFY(x)

_Static_assert(ATOMIC_LONG_LOCK_FREE == 2, "the SIGPIPE handler's counters must be lock-free to be async-signal-safe");

static atomic_long caughtSIGPIPEs = 0;
static atomic_long expectedSIGPIPEs = 0;

static const char strayLine[] =
    "TBD test host: caught SIGPIPE: a write to a closed pipe or socket got EPIPE instead of ending the pass. "
    "See the SIGPIPE entry in Tests/CLAUDE.md.\n";
static const char expectedLine[] =
    "TBD test host: caught SIGPIPE that a test provoked on purpose (TBDTestHostExpectSIGPIPE); not a finding.\n";
static const char silencedLine[] =
    "TBD test host: caught " TBD_EXPAND_AND_STRINGIFY(TBD_MAX_LOGGED_SIGPIPES) " SIGPIPEs; any more are counted "
    "but not logged.\n";

static void TBDWriteLineToStderr(const char *line, size_t length) {
    ssize_t written = write(STDERR_FILENO, line, length);
    (void)written;
}

/// Takes one mark left by `TBDTestHostExpectSIGPIPE()`, if there is one.
static bool TBDTakeExpectedSIGPIPE(void) {
    long expected = atomic_load_explicit(&expectedSIGPIPEs, memory_order_relaxed);
    while (expected > 0) {
        if (atomic_compare_exchange_weak_explicit(&expectedSIGPIPEs, &expected, expected - 1, memory_order_relaxed,
                                                  memory_order_relaxed)) {
            return true;
        }
    }
    return false;
}

static void TBDTestHostSIGPIPEHandler(int signal) {
    (void)signal;
    int savedErrno = errno;
    long caught = atomic_fetch_add_explicit(&caughtSIGPIPEs, 1, memory_order_relaxed) + 1;
    bool expected = TBDTakeExpectedSIGPIPE();
    if (caught <= TBD_MAX_LOGGED_SIGPIPES) {
        if (expected) {
            TBDWriteLineToStderr(expectedLine, sizeof expectedLine - 1);
        } else {
            TBDWriteLineToStderr(strayLine, sizeof strayLine - 1);
        }
    } else if (caught == TBD_MAX_LOGGED_SIGPIPES + 1) {
        TBDWriteLineToStderr(silencedLine, sizeof silencedLine - 1);
    }
    errno = savedErrno;
}

__attribute__((constructor))
static void TBDInstallTestHostSIGPIPEHandler(void) {
    struct sigaction existing;
    if (sigaction(SIGPIPE, NULL, &existing) != 0) {
        fprintf(stderr, "TBD test host: could not read SIGPIPE's disposition (%s), so no handler was installed; "
                        "a write to a closed pipe or socket will end the test process. See "
                        "Tests/TestProcessDefaults/SIGPIPEHandler.c.\n",
                strerror(errno));
        fflush(stderr);
        return;
    }
    // Through the union first: SIG_DFL and SIG_IGN are values of it whatever
    // the flags say, so a stale SA_SIGINFO on either does not make it a handler.
    bool inheritedIgnore = false;
    if (existing.sa_handler == SIG_IGN) {
        inheritedIgnore = true;
    } else if (existing.sa_handler != SIG_DFL) {
        fprintf(stderr, "TBD test host: SIGPIPE already has %s handler, installed before the test bundle loaded; "
                        "leaving it in place rather than replacing it with the test host's. See "
                        "Tests/TestProcessDefaults/SIGPIPEHandler.c.\n",
                (existing.sa_flags & SA_SIGINFO) ? "an SA_SIGINFO" : "a");
        fflush(stderr);
        return;
    }

    struct sigaction handler;
    memset(&handler, 0, sizeof handler);
    handler.sa_handler = TBDTestHostSIGPIPEHandler;
    sigemptyset(&handler.sa_mask);
    handler.sa_flags = SA_RESTART;
    if (sigaction(SIGPIPE, &handler, NULL) != 0) {
        fprintf(stderr, "TBD test host: could not install the SIGPIPE handler (%s); a write to a closed pipe or "
                        "socket will %s. See Tests/TestProcessDefaults/SIGPIPEHandler.c.\n",
                strerror(errno), inheritedIgnore ? "fail with EPIPE, but every child will start with SIGPIPE ignored"
                                                 : "end the test process");
        fflush(stderr);
        return;
    }
    if (inheritedIgnore) {
        fprintf(stderr, "TBD test host: the runner started with SIGPIPE ignored, which its children would inherit; "
                        "replaced it with the test host's handler, which exec resets to the default. See "
                        "Tests/TestProcessDefaults/SIGPIPEHandler.c.\n");
        fflush(stderr);
    }
}

bool TBDTestHostSIGPIPEHandlerIsCurrent(void) {
    struct sigaction current;
    if (sigaction(SIGPIPE, NULL, &current) != 0) return false;
    return !(current.sa_flags & SA_SIGINFO) && current.sa_handler == TBDTestHostSIGPIPEHandler;
}

const char *TBDTestHostSIGPIPEDisposition(void) {
    struct sigaction current;
    if (sigaction(SIGPIPE, NULL, &current) != 0) return "unreadable";
    if (current.sa_handler == SIG_DFL) return "default";
    if (current.sa_handler == SIG_IGN) return "ignored";
    if (!(current.sa_flags & SA_SIGINFO) && current.sa_handler == TBDTestHostSIGPIPEHandler) {
        return "test host handler";
    }
    return "another handler";
}

long TBDTestHostSIGPIPECount(void) {
    return atomic_load_explicit(&caughtSIGPIPEs, memory_order_relaxed);
}

void TBDTestHostExpectSIGPIPE(void) {
    atomic_fetch_add_explicit(&expectedSIGPIPEs, 1, memory_order_relaxed);
}
