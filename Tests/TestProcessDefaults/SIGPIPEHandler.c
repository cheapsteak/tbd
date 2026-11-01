#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>

#include "TestProcessDefaults.h"

/// Keeps the test process alive when something writes to a pipe or socket
/// whose reader has gone.
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
/// So the test host catches SIGPIPE with a handler that does nothing. The
/// write that raised it then fails with EPIPE in the test that made it, as it
/// would under `SO_NOSIGPIPE`, and the pass carries on.
///
/// **A handler, not `SIG_IGN`, because of what `exec` does with each.** A
/// caught signal is reset to `SIG_DFL` in the new image by `execve` and by
/// `posix_spawn`; an ignored one stays ignored. With `SIG_IGN` every child the
/// tests start through `posix_spawn`, `fork`/`exec` or `forkpty` would start
/// with SIGPIPE ignored (Foundation's `Process` resets dispositions itself, so
/// only its children are spared): `yes | head` would spin instead of ending,
/// and a test of a spawner's own SIGPIPE reset (such as
/// `HolderLifecycleTests.theJobDoesNotStartWithSIGPIPEIgnored`) would be
/// testing an environment production never has. With a handler, children
/// start exactly as they would without it. Blocking SIGPIPE in the signal mask
/// is ruled out for the same reason: a mask survives `exec` too, and it is per
/// thread, so it would have to reach every thread the process ever starts.
///
/// **The flags.** `SA_RESTART` only. A SIGPIPE raised by a write is delivered
/// to the thread that wrote, and that write returns EPIPE whatever the flags
/// say: it failed, it was not interrupted, so there is nothing to restart. The
/// flag is for a SIGPIPE sent with `kill`, which lands on any thread that does
/// not block it — possibly one parked in `read`, `accept` or `waitpid`. Under
/// the default action that signal ended the process; with a bare handler it
/// would make that call fail with EINTR, in code that never had to expect
/// EINTR from SIGPIPE. `SA_RESTART` resumes such calls instead (`poll`,
/// `select` and the sleeps return EINTR regardless, as they do for any caught
/// signal). No `SA_RESETHAND`, which would leave the second stray write fatal;
/// no `SA_NODEFER`, as there is nothing to gain from re-entering an empty
/// handler; no `SA_SIGINFO`, since the handler reads nothing; and an empty
/// `sa_mask`, since it touches nothing that another signal could disturb.
///
/// **The handler is empty on purpose.** It is async-signal-safe by having no
/// body, and it leaves `errno` holding the write's EPIPE for the caller. One
/// that logged would have to save `errno`, and a log line written to a closed
/// stderr would raise SIGPIPE inside the handler.
///
/// **It replaces only the default and `SIG_IGN`.** A handler something else
/// installed before this constructor ran is left in place, with a line on
/// stderr: that code chose it, and it already keeps the process alive. A
/// `SIG_IGN` inherited from whatever launched the runner is replaced, with a
/// line on stderr, because it would pass to children for the reason above.
/// Otherwise the install is silent, as `MainRunLoopGuard.m`'s is.
///
/// **Every pass gets it.** SwiftPM links every test target, and every target
/// they depend on, into the one `TBDPackageTests.xctest` bundle, from object
/// files rather than archives, so this constructor is in the bundle whichever
/// target depends on `TestProcessDefaults`. Each CI pass runs that bundle with
/// `--filter`/`--skip`, and the constructor runs when the runner loads it,
/// before any test: in `swiftpm-testing-helper` for Swift Testing and in
/// `xctest` for XCTest. `TestHostSIGPIPEHandlerTests` (in `TBDAppTests`) pins
/// the disposition, the exec reset and the EPIPE.
///
/// This is a net under the per-descriptor guards, not a replacement for them.
/// The app leaves SIGPIPE at its default, so its sockets and pipes still need
/// `SO_NOSIGPIPE` or `F_SETNOSIGPIPE` (see `Sources/TBDApp/SocketSIGPIPE.swift`).
/// And a test must not set SIGPIPE's disposition itself: `signal(SIGPIPE,
/// SIG_IGN)` in a test would replace this handler process-wide, for every
/// suite running alongside it.
static void TBDTestHostSIGPIPEHandler(int signal) {
    (void)signal;
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
    bool inheritedIgnore = false;
    if (existing.sa_flags & SA_SIGINFO) {
        fprintf(stderr, "TBD test host: SIGPIPE already has an SA_SIGINFO handler, installed before the test bundle "
                        "loaded; leaving it in place rather than replacing it with the no-op handler. See "
                        "Tests/TestProcessDefaults/SIGPIPEHandler.c.\n");
        fflush(stderr);
        return;
    }
    if (existing.sa_handler == SIG_IGN) {
        inheritedIgnore = true;
    } else if (existing.sa_handler != SIG_DFL) {
        fprintf(stderr, "TBD test host: SIGPIPE already has a handler, installed before the test bundle loaded; "
                        "leaving it in place rather than replacing it with the no-op handler. See "
                        "Tests/TestProcessDefaults/SIGPIPEHandler.c.\n");
        fflush(stderr);
        return;
    }

    struct sigaction handler;
    memset(&handler, 0, sizeof handler);
    handler.sa_handler = TBDTestHostSIGPIPEHandler;
    sigemptyset(&handler.sa_mask);
    handler.sa_flags = SA_RESTART;
    if (sigaction(SIGPIPE, &handler, NULL) != 0) {
        fprintf(stderr, "TBD test host: could not install the no-op SIGPIPE handler (%s); a write to a closed pipe "
                        "or socket will %s. See Tests/TestProcessDefaults/SIGPIPEHandler.c.\n",
                strerror(errno), inheritedIgnore ? "fail with EPIPE, but every child will start with SIGPIPE ignored"
                                                 : "end the test process");
        fflush(stderr);
        return;
    }
    if (inheritedIgnore) {
        fprintf(stderr, "TBD test host: the runner started with SIGPIPE ignored, which its children would inherit; "
                        "replaced it with the no-op handler, which exec resets to the default. See "
                        "Tests/TestProcessDefaults/SIGPIPEHandler.c.\n");
        fflush(stderr);
    }
}

bool TBDTestHostSIGPIPEHandlerIsCurrent(void) {
    struct sigaction current;
    if (sigaction(SIGPIPE, NULL, &current) != 0) return false;
    return !(current.sa_flags & SA_SIGINFO) && current.sa_handler == TBDTestHostSIGPIPEHandler;
}
