#ifndef TEST_PROCESS_DEFAULTS_H
#define TEST_PROCESS_DEFAULTS_H

#include <stdbool.h>

/// Whether the constructor in TestProcessDefaults.m registered the test
/// process's user defaults when the test bundle loaded.
///
/// Swift code calls it for two reasons: a diagnostic can say whether the
/// registration ran, and a reference from Swift keeps the linker from
/// leaving the target's object file, and with it the constructor, out of
/// the test bundle.
bool TBDTestProcessDefaultsRegistered(void);

/// How many times MainRunLoopGuard.m has resumed the main run loop after
/// something stopped it at its outermost level. Main thread only.
///
/// Called from Swift by the guard's test, which also keeps the linker from
/// leaving MainRunLoopGuard.m's object file, and its constructor, out of the
/// test bundle.
long TBDTestHostMainRunLoopResumeCount(void);

/// Marks the next resume as the guard's own test, so its stderr line says so
/// and a real stop stays easy to find in a CI log. Main thread only.
void TBDTestHostExpectMainRunLoopStop(void);

/// Whether SIGPIPE is caught right now by the no-op handler SIGPIPEHandler.c
/// installs when the test bundle loads, rather than by the default action,
/// `SIG_IGN`, or a handler of anyone else's.
///
/// Called from Swift by the handler's test, which also keeps the linker from
/// leaving SIGPIPEHandler.c's object file, and its constructor, out of the
/// test bundle.
bool TBDTestHostSIGPIPEHandlerIsCurrent(void);

#endif
