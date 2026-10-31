#import <Foundation/Foundation.h>
#include <stdio.h>

#import "TestProcessDefaults.h"

/// Keeps the test process alive when something stops the main run loop.
///
/// The test bundle's entry point is an async `main`. Swift runs it by calling
/// `CFRunLoopRun()` on the main thread and then `exit(0)` when that call
/// returns, and it returns as soon as anything stops the main run loop while
/// its outermost activation is the current one: `CFRunLoopStop` on the main
/// run loop from any thread, or from a main-queue job. The process then ends
/// with status 0 in the middle of the run, with no summary, no xUnit results
/// and no crash report, and `swift test` reports success: the shape of the
/// `fast-pass-app ran no tests` deaths on CI, where SwiftPM's exit status
/// rules out a signal.
///
/// The app never sees this: `NSApplication.run()` loops over the run loop and
/// carries on after a stray stop (measured with a stop from a background
/// thread and one from the main queue). So the guard gives the test host the
/// same tolerance. When the outermost activation exits under Swift's async
/// main it says so on stderr and runs the main run loop again, inside the
/// observer's callout, until the runner's own `exit` ends the process. A stop
/// that lands on a nested activation, such as a test's run-loop pump, only
/// ends that pump, as it always has, and the guard does nothing.
///
/// Telling the outermost activation from a nested one is a depth count kept by
/// this observer from before the run loop first runs. It is confirmed from the
/// stack before the guard acts: exactly one run-loop activation, with Swift's
/// async-main drain under it. Without the drain the guard does nothing: async
/// main's own code before its first suspension runs outside the drain (an
/// activation it runs there may end however it likes), and an XCTest worker
/// has no drain at all. The stack is read only when the depth reaches zero.
static NSInteger mainRunLoopDepth = 0;
static long mainRunLoopResumes = 0;
static bool nextMainRunLoopStopIsExpected = false;

/// A bound on resumes, so a loop that stops the run loop forever ends the run
/// rather than spinning; no healthy run comes near it.
static const long maxMainRunLoopResumes = 100;

static NSInteger TBDRunLoopActivationsOnStack(NSArray<NSString *> *stack, bool *drainingAsyncMain) {
    NSInteger activations = 0;
    *drainingAsyncMain = false;
    for (NSString *frame in stack) {
        if ([frame containsString:@"RunLoopRunSpecific"]) activations += 1;
        if ([frame containsString:@"asyncMainDrainQueue"]) *drainingAsyncMain = true;
    }
    return activations;
}

static void TBDMainRunLoopActivity(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    if (activity == kCFRunLoopEntry) {
        mainRunLoopDepth += 1;
        return;
    }
    mainRunLoopDepth -= 1;
    if (mainRunLoopDepth > 0) return;

    bool drainingAsyncMain = false;
    NSInteger activations = TBDRunLoopActivationsOnStack([NSThread callStackSymbols], &drainingAsyncMain);
    if (!drainingAsyncMain) return;
    if (activations != 1) {
        // The count started inside a run; the stack is the ground truth. The
        // activation exiting now is still on it.
        mainRunLoopDepth = activations - 1;
        return;
    }
    // CF does not call an observer back while it is in its own callout, so
    // every return below is a stop of the activation this loop started.
    while (mainRunLoopResumes < maxMainRunLoopResumes) {
        mainRunLoopResumes += 1;
        if (nextMainRunLoopStopIsExpected) {
            nextMainRunLoopStopIsExpected = false;
            fprintf(stderr, "TBD test host: resuming the main run loop after the guard's own test stopped it "
                            "(resume %ld).\n", mainRunLoopResumes);
        } else {
            fprintf(stderr, "TBD test host: something stopped the main run loop at its outermost level, which "
                            "would have made the test process exit 0 mid-run; resuming it (resume %ld of at "
                            "most %ld). See Tests/TestProcessDefaults/MainRunLoopGuard.m.\n",
                    mainRunLoopResumes, maxMainRunLoopResumes);
        }
        fflush(stderr);
        CFRunLoopRun();
    }
}

__attribute__((constructor))
static void TBDInstallMainRunLoopGuard(void) {
    CFRunLoopObserverRef observer = CFRunLoopObserverCreate(
        kCFAllocatorDefault, kCFRunLoopEntry | kCFRunLoopExit, true, 0, TBDMainRunLoopActivity, NULL);
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    CFRelease(observer);
}

long TBDTestHostMainRunLoopResumeCount(void) {
    return mainRunLoopResumes;
}

void TBDTestHostExpectMainRunLoopStop(void) {
    nextMainRunLoopStopIsExpected = true;
}
