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

#endif
