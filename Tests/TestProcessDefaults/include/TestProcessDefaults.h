#ifndef TEST_PROCESS_DEFAULTS_H
#define TEST_PROCESS_DEFAULTS_H

#include <stdbool.h>

// Each file in this target sets something up from a constructor when the test
// bundle loads. None of the functions below exists to keep a constructor
// linked: SwiftPM links the test bundle from the object files of every target
// in it, not from archives, so every constructor here is always in the bundle.
// They exist for the tests and diagnostics that call them.

/// Whether the constructor in TestProcessDefaults.m registered the test
/// process's user defaults when the test bundle loaded, so a diagnostic can
/// say whether the registration ran.
bool TBDTestProcessDefaultsRegistered(void);

/// How many times MainRunLoopGuard.m has resumed the main run loop after
/// something stopped it at its outermost level. Main thread only. Called from
/// Swift by the guard's test.
long TBDTestHostMainRunLoopResumeCount(void);

/// Marks the next resume as the guard's own test, so its stderr line says so
/// and a real stop stays easy to find in a CI log. Main thread only.
void TBDTestHostExpectMainRunLoopStop(void);

/// Whether SIGPIPE is caught right now by the handler SIGPIPEHandler.c
/// installs when the test bundle loads, rather than by the default action,
/// `SIG_IGN`, or a handler of anyone else's. Called from Swift by the
/// handler's test.
bool TBDTestHostSIGPIPEHandlerIsCurrent(void);

/// SIGPIPE's disposition right now, in words, for a failure message:
/// "test host handler", "default", "ignored", "another handler", or
/// "unreadable" when `sigaction` cannot read it. Called from Swift by the
/// check each test pass runs.
const char *TBDTestHostSIGPIPEDisposition(void);

/// How many SIGPIPEs SIGPIPEHandler.c's handler has caught in this process.
/// Catches, not writes: SIGPIPEs raised while one is pending merge into one.
/// Any thread.
///
/// A test that drives a write into a closed pipe or socket reads this before
/// and after the write, to check that the write raised no SIGPIPE. That check
/// is a cross-check, not the proof, for two reasons:
///
///   - The count is the whole process's. Suites run concurrently in it, so
///     another suite's unprotected write can raise it inside the window.
///   - The count can lag the write. XNU raises the signal at the process, and
///     the thread it picks runs the handler when that thread next returns to
///     user space, which can be after the write has returned.
///
/// So the proof is the flag on the test's own descriptor
/// (`fcntl(fd, F_GETNOSIGPIPE)` for a pipe, `SO_NOSIGPIPE` for a socket),
/// which no other suite can change and which the kernel reads on every write.
/// Assert the count unchanged only across a window that holds the write and
/// little else, and say in the message that a flag check that passed puts the
/// signal on another suite's write.
long TBDTestHostSIGPIPECount(void);

#endif
