import Foundation

/// Where a post-resume session-id recapture looks for the Claude process whose
/// session file it must read: the pid the holder recorded when it forked the
/// job.
public enum SessionRecaptureTarget: Sendable, Equatable {
    case holderChild(pid: Int32)
}

/// Waits five seconds after a resume, then records the session id the detector
/// finds for the target.
///
/// The wait runs in an unstructured task, which inherits no task-executor
/// preference (SE-0417 carries one into child tasks and default actors, not
/// into `Task {}`), so by default it lands on the cooperative pool. `executor`
/// exists for tests and nothing else: a test injects `GateExecutor` so the
/// sleep arms without waiting for a pool turn behind a saturated parallel pass.
/// Production passes nil.
struct SessionRecaptureScheduler: Sendable {
    let db: TBDDatabase
    let clock: any Clock<Duration>
    private let captureSessionID: @Sendable (SessionRecaptureTarget) async -> String?
    private let executor: (any TaskExecutor)?

    init(
        db: TBDDatabase,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.db = db
        self.clock = clock
        self.executor = nil
        let detector = ClaudeStateDetector()
        self.captureSessionID = { target in
            await detector.captureSessionID(target: target)
        }
    }

    /// - Parameter executor: Where the recapture task is scheduled. `nil` — the
    ///   production value — means the cooperative pool. Tests pass an executor
    ///   they own; see the type comment.
    init(
        db: TBDDatabase,
        captureSessionID: @escaping @Sendable (SessionRecaptureTarget) async -> String?,
        executor: (any TaskExecutor)? = nil,
        clock: any Clock<Duration>
    ) {
        self.db = db
        self.clock = clock
        self.executor = executor
        self.captureSessionID = captureSessionID
    }

    @discardableResult
    func schedule(
        terminalID: UUID,
        target: SessionRecaptureTarget,
        expectedIncarnationID: UUID?
    ) -> Task<Void, Never> {
        let clock = clock
        let db = db
        let captureSessionID = captureSessionID
        let body: @Sendable () async -> Void = {
            guard (try? await clock.sleep(for: .seconds(5))) != nil else { return }
            if let sessionID = await captureSessionID(target) {
                _ = try? await db.terminals.updateSessionIDIfIncarnationMatches(
                    id: terminalID,
                    expectedIncarnationID: expectedIncarnationID,
                    sessionID: sessionID)
            }
        }
        // Swift 6.2's executor-preference initializer crashes with nil on the
        // macOS 15 concurrency runtime. The default must use a plain task.
        if let executor {
            return Task(executorPreference: executor) { await body() }
        } else {
            return Task { await body() }
        }
    }
}
