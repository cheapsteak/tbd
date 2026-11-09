import Testing
import Foundation
import os
import TestSupport
@testable import TBDShared

/// Foundation keeps a `Process`'s `terminationHandler` alive after `run()` throws,
/// so anything the handler captured (a daemon's stdout and stderr pipes) stayed
/// open for the daemon's life. The observable fact is whether that capture is
/// released, checked on a sentinel object so other tests' descriptors cannot
/// disturb the result.
@Suite("Process launch", .fastPassBounded)
struct ProcessLaunchTests {
    private final class Sentinel: @unchecked Sendable {}

    private static func neverLaunchable() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        return process
    }

    @Test("a launch that fails releases what the termination handler captured")
    func failedLaunchReleasesHandlerCapture() {
        weak var weakSentinel: Sentinel?
        do {
            let process = Self.neverLaunchable()
            let sentinel = Sentinel()
            weakSentinel = sentinel
            process.terminationHandler = { _ in _ = sentinel }
            #expect(throws: (any Error).self) { try process.runDisarmingHandlerOnFailure() }
        }
        #expect(weakSentinel == nil)
    }

    @Test("a launch that succeeds still calls the termination handler")
    func successfulLaunchKeepsHandler() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let called = OSAllocatedUnfairLock(initialState: false)
        process.terminationHandler = { _ in called.withLock { $0 = true } }
        try process.runDisarmingHandlerOnFailure()
        // Polling with Task.sleep, unlike a continuation, throws when the
        // suite's time limit cancels the test, so a handler that never fires
        // ends the test instead of hanging it.
        while !called.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(process.terminationStatus == 0)
    }
}
