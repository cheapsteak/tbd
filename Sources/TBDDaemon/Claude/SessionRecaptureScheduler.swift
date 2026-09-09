import Foundation

/// Where a post-resume session-id recapture looks for the Claude process whose
/// session file it must read.
///
/// One case per transport, because the two address the same process
/// differently and neither address is meaningful to the other: a tmux session
/// is reached through its pane (the pid is `#{pane_pid}`, resolved on demand),
/// a holder-backed one through the pid the holder recorded when it forked the
/// job. A holder row's pane id is the empty string by construction, so a
/// recapture that carried only a pane would poll a coordinate that can never
/// resolve.
public enum SessionRecaptureTarget: Sendable, Equatable {
    case tmuxPane(server: String, paneID: String)
    case holderChild(pid: Int32)
}

struct SessionRecaptureScheduler: Sendable {
    let db: TBDDatabase
    let tmux: TmuxManager
    let clock: any Clock<Duration>
    private let captureSessionID: @Sendable (SessionRecaptureTarget) async -> String?

    init(
        db: TBDDatabase,
        tmux: TmuxManager,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.db = db
        self.tmux = tmux
        self.clock = clock
        let detector = ClaudeStateDetector(tmux: tmux)
        self.captureSessionID = { target in
            await detector.captureSessionID(target: target)
        }
    }

    init(
        db: TBDDatabase,
        tmux: TmuxManager,
        captureSessionID: @escaping @Sendable (SessionRecaptureTarget) async -> String?,
        clock: any Clock<Duration>
    ) {
        self.db = db
        self.tmux = tmux
        self.clock = clock
        self.captureSessionID = captureSessionID
    }

    @discardableResult
    func schedule(
        terminalID: UUID,
        target: SessionRecaptureTarget,
        expectedIncarnationID: UUID?
    ) -> Task<Void, Never> {
        Task {
            guard (try? await clock.sleep(for: .seconds(5))) != nil else { return }
            if let sessionID = await captureSessionID(target) {
                _ = try? await db.terminals.updateSessionIDIfIncarnationMatches(
                    id: terminalID,
                    expectedIncarnationID: expectedIncarnationID,
                    sessionID: sessionID)
            }
        }
    }

    /// The tmux spelling of `schedule(terminalID:target:expectedIncarnationID:)`,
    /// for the call sites that address a pane and nothing else.
    @discardableResult
    func schedule(
        terminalID: UUID,
        paneID: String,
        server: String,
        expectedIncarnationID: UUID?
    ) -> Task<Void, Never> {
        schedule(
            terminalID: terminalID,
            target: .tmuxPane(server: server, paneID: paneID),
            expectedIncarnationID: expectedIncarnationID)
    }
}
