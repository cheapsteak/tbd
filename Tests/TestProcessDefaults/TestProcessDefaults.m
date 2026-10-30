#import <Foundation/Foundation.h>

#import "TestProcessDefaults.h"

static bool registered = false;

/// Registers the user defaults the app registers at launch and AppKit reads
/// once per process, before any test can run.
///
/// `NSTableViewCanEstimateRowHeights = NO` turns off NSTableView's own
/// row-height estimation, as `applicationWillFinishLaunching` does in the
/// app. AppKit reads the key once per process, at the first table, and
/// suites run in parallel in one process, so registering it from a test is
/// too late whenever another suite built a table first — a SwiftUI `List`
/// counts, since it is an NSTableView inside. With estimation on, AppKit
/// sizes rows it has not shown from its own guess and moves the clip itself
/// as it swaps the guesses for the delegate's heights, which production never
/// does.
///
/// A constructor runs when the test bundle loads, before the runner looks
/// for a single test. `register` writes only the volatile registration
/// domain, never a plist.
__attribute__((constructor))
static void TBDRegisterTestProcessDefaults(void) {
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            @"NSTableViewCanEstimateRowHeights": @NO,
        }];
    }
    registered = true;
}

bool TBDTestProcessDefaultsRegistered(void) {
    return registered;
}
