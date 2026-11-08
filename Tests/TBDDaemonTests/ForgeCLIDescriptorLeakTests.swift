import Testing
import Foundation
import TestSupport
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

    /// The read of `/dev/fd` failed, so no count can be trusted. Thrown rather
    /// than folded into a sentinel, which would read as a leak or as a clean run.
    private struct DescriptorTableUnreadable: Error {}

    /// Counts this process's open descriptors, and throws when the table cannot
    /// be read so a failed read is never mistaken for a count.
    private static func openDescriptorCount() throws -> Int {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        } catch {
            throw DescriptorTableUnreadable()
        }
    }

    /// Descriptors settle on a later turn when an autorelease pool drains
    /// lazily, so a count that has not returned to the baseline is polled
    /// briefly. A leak never returns, so it ends as a timeout that names both
    /// counts. A cancelled test reports nothing.
    private static func expectSettled(atMost baseline: Int) async throws {
        var last = baseline
        var readError: Error?
        let outcome = await pollUntilTrue(
            timeout: .seconds(2), pollInterval: .milliseconds(50)
        ) {
            do {
                last = try openDescriptorCount()
            } catch {
                readError = error
                return true
            }
            return last <= baseline
        }
        if let readError { throw readError }
        if outcome == .timedOut {
            Issue.record("open descriptors stayed at \(last) against a baseline of \(baseline)")
        }
    }

    @Test("a launch that fails closes the pipes it opened")
    func failedLaunchClosesPipes() async throws {
        let baseline = try Self.openDescriptorCount()
        for _ in 0..<Self.calls {
            let result = await PRStatusManager.runCLI(
                executable: "/bin/sh", args: ["-c", "true"],
                repoPath: "/nonexistent/\(UUID().uuidString)")
            #expect(result == nil)
        }
        try await Self.expectSettled(atMost: baseline)
    }

    @Test("a call cancelled before it launches closes the pipes it opened")
    func cancelledBeforeLaunchClosesPipes() async throws {
        let baseline = try Self.openDescriptorCount()
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
        try await Self.expectSettled(atMost: baseline)
    }
}
