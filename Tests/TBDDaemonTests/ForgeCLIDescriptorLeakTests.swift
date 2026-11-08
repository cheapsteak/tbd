import Testing
import Foundation
@testable import TBDDaemonLib

/// A forge CLI call that never launches must give back both of its pipes.
///
/// Foundation keeps a `Process`'s `terminationHandler` alive until the child it
/// launched exits, so a handler that captured the stdout and stderr pipes held
/// four descriptors for the life of the daemon whenever `run()` threw or the
/// caller was cancelled first. The count below is the observable fact; a daemon
/// that polls every worktree's PR hit the descriptor ceiling this way.
@Suite("Forge CLI descriptor leak")
struct ForgeCLIDescriptorLeakTests {
    private static let calls = 25

    private static func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// Descriptors settle on a later turn when an autorelease pool drains
    /// lazily, so a count that has not returned to the baseline is polled
    /// briefly. A leak never returns.
    private static func settledCount(atMost baseline: Int) async -> Int {
        var count = openDescriptorCount()
        for _ in 0..<40 where count > baseline {
            try? await Task.sleep(for: .milliseconds(50))
            count = openDescriptorCount()
        }
        return count
    }

    @Test("a launch that fails closes the pipes it opened")
    func failedLaunchClosesPipes() async {
        let baseline = Self.openDescriptorCount()
        for _ in 0..<Self.calls {
            let result = await PRStatusManager.runCLI(
                executable: "/bin/sh", args: ["-c", "true"],
                repoPath: "/nonexistent/\(UUID().uuidString)")
            #expect(result == nil)
        }
        #expect(await Self.settledCount(atMost: baseline) <= baseline)
    }

    @Test("a call cancelled before it launches closes the pipes it opened")
    func cancelledBeforeLaunchClosesPipes() async {
        let baseline = Self.openDescriptorCount()
        for _ in 0..<Self.calls {
            let task = Task {
                // Cancel from inside, so the cancellation is already standing
                // when `runCLI` installs its handler.
                withUnsafeCurrentTask { $0?.cancel() }
                return await PRStatusManager.runCLI(
                    executable: "/bin/sh", args: ["-c", "true"], repoPath: "/tmp")
            }
            #expect(await task.value == nil)
        }
        #expect(await Self.settledCount(atMost: baseline) <= baseline)
    }
}
