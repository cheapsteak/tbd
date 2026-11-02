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

/// Marks the next SIGPIPE the handler catches as one a test provoked on
/// purpose, so its stderr line says so and a stray one stays easy to find in
/// a CI log. Call it immediately before the write that will raise it, and only
/// when that write certainly will: an unused mark would go to the next stray
/// SIGPIPE instead. Any thread.
///
/// The mark belongs to no test. Suites run concurrently in one process, and
/// the handler hands the mark to whichever catch comes next, so a stray
/// SIGPIPE from another suite landing between this call and the write takes
/// it: the stray one is then labelled deliberate and the deliberate one stray.
/// And SIGPIPEs raised while one is pending merge into one catch, which takes
/// one mark. A label is a hint, not proof.
void TBDTestHostExpectSIGPIPE(void);

#endif
