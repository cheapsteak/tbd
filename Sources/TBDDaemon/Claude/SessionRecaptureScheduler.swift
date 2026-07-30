import Foundation

struct SessionRecaptureScheduler: Sendable {
    let db: TBDDatabase
    let tmux: TmuxManager
    let clock: any Clock<Duration>
    private let captureSessionID: @Sendable (String, String) async -> String?

    init(
        db: TBDDatabase,
        tmux: TmuxManager,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.db = db
        self.tmux = tmux
        self.clock = clock
        let detector = ClaudeStateDetector(tmux: tmux)
        self.captureSessionID = { server, paneID in
            await detector.captureSessionID(server: server, paneID: paneID)
        }
    }

    init(
        db: TBDDatabase,
        tmux: TmuxManager,
        captureSessionID: @escaping @Sendable (String, String) async -> String?,
        clock: any Clock<Duration>
    ) {
        self.db = db
        self.tmux = tmux
        self.clock = clock
        self.captureSessionID = captureSessionID
    }

    func schedule(terminalID: UUID, paneID: String, server: String) {
        Task {
            guard (try? await clock.sleep(for: .seconds(5))) != nil else { return }
            if let sessionID = await captureSessionID(server, paneID) {
                try? await db.terminals.updateSessionID(id: terminalID, sessionID: sessionID)
            }
        }
    }
}
