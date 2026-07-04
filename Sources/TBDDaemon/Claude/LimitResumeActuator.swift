import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "limitResume")

/// The tmux surface the actuator needs. `TmuxManager` conforms; tests fake it.
/// All sends go through the SAME methods `handleTerminalSend` uses — never
/// raw tmux invocations (spec constraint).
public protocol ResumeSendingTmux: Sendable {
    func windowExists(server: String, windowID: String) async -> Bool
    func paneInMode(server: String, paneID: String) async throws -> Bool
    func panePID(server: String, paneID: String) async throws -> String
    func sendKeys(server: String, paneID: String, text: String) async throws
    func sendKey(server: String, paneID: String, key: String) async throws
}

extension TmuxManager: ResumeSendingTmux {}

/// Finds the pane's foreground Claude process. `#{pane_current_command}`
/// reports `zsh` on macOS, so we walk the pane PID's process tree and check
/// `ps -o stat=` for the `+` (foreground process group) flag instead
/// (spec §Actuation 1).
public protocol PaneProcessInspecting: Sendable {
    /// PID of the Claude process that owns the pane's tty foreground group,
    /// or nil when Claude is not foreground (bare shell, editor, …).
    func foregroundClaudePID(panePID: Int32) -> Int32?
}

public struct ProductionPaneProcessInspector: PaneProcessInspecting {
    private let signaller: any ProcessSignaller

    public init(signaller: any ProcessSignaller = ProductionProcessSignaller()) {
        self.signaller = signaller
    }

    public func foregroundClaudePID(panePID: Int32) -> Int32? {
        // Candidates: pane PID itself (zsh may have exec'd into Claude),
        // its children, and grandchildren (wrapper-shell spawns).
        var candidates: [Int32] = [panePID]
        let children = signaller.children(ofServerPID: panePID)
        candidates += children
        for child in children {
            candidates += signaller.children(ofServerPID: child)
        }
        for pid in candidates {
            guard let stat = signaller.stat(pid), stat.contains("+"),
                  let command = signaller.commandLine(pid)?.lowercased(),
                  command.contains("claude")
            else { continue }
            return pid
        }
        return nil
    }
}

/// Runs one actuation attempt for a scheduled resume: eligibility checks,
/// the Escape/continue/Enter send sequence, and post-send verification.
public struct LimitResumeActuator: LimitResumeActuating {

    // MARK: - Timing constants (spec §Actuation 4-5)

    static let interKeyPause: Duration = .milliseconds(150)
    static let verifyPollInterval: Duration = .seconds(1)
    static let verifyPolls = 20   // ~20s window

    private let db: TBDDatabase
    private let tmux: any ResumeSendingTmux
    private let inspector: any PaneProcessInspecting
    private let readTranscript: @Sendable (String) -> Data?
    /// Injectable sleep so unit tests run instantly.
    private let waiter: @Sendable (Duration) async -> Void

    public init(
        db: TBDDatabase,
        tmux: any ResumeSendingTmux,
        inspector: any PaneProcessInspecting,
        readTranscript: @escaping @Sendable (String) -> Data?,
        waiter: @escaping @Sendable (Duration) async -> Void
    ) {
        self.db = db
        self.tmux = tmux
        self.inspector = inspector
        self.readTranscript = readTranscript
        self.waiter = waiter
    }

    public func actuate(_ resume: ScheduledResume) async -> ResumeActuationOutcome {
        // 1. Eligibility: terminal alive.
        guard let terminal = ((try? await db.terminals.get(id: resume.terminalID)) ?? nil),
              terminal.suspendedAt == nil,
              let worktree = ((try? await db.worktrees.get(id: terminal.worktreeID)) ?? nil)
        else { return .terminalGone }
        let server = worktree.tmuxServer
        guard await tmux.windowExists(server: server, windowID: terminal.tmuxWindowID) else {
            return .terminalGone
        }

        // 2. User already continued? Any transcript record newer than the
        //    detection instant means yes — send nothing. Keep this read
        //    around as the pre-send baseline for growth verification below
        //    (step 6) instead of re-reading — a fresh read here would race
        //    ahead of the baseline on a fast-growing transcript and make
        //    growth undetectable.
        var preSendTranscriptData: Data?
        if let path = terminal.transcriptPath, !path.isEmpty {
            preSendTranscriptData = readTranscript(path)
            if let data = preSendTranscriptData,
               RateLimitDetection.hasRecord(newerThan: resume.createdAt, in: data) {
                return .userAlreadyContinued
            }
        }

        // 3. Copy-mode: typing would go to the mode; cancelling copy-mode
        //    would yank the user out of scrollback. Reschedule instead.
        if (try? await tmux.paneInMode(server: server, paneID: terminal.tmuxPaneID)) == true {
            return .paneInCopyMode
        }

        // 4. Claude must be the pane's FOREGROUND process (+ flag). Never
        //    type into a bare shell.
        guard let panePIDString = try? await tmux.panePID(server: server, paneID: terminal.tmuxPaneID),
              let panePID = Int32(panePIDString),
              inspector.foregroundClaudePID(panePID: panePID) != nil
        else {
            return .failed("Claude is not the pane's foreground process")
        }

        // 5+6. Send, verify; one retry of send+verify, then failed. The
        // growth baseline is fixed at the pre-send snapshot from step 2 for
        // both attempts — re-snapshotting per attempt would let a transcript
        // that grew during a failed first attempt mask itself on the retry.
        let preSize = preSendTranscriptData?.count ?? 0
        for attempt in 1...2 {
            do {
                try await Self.sendContinueSequence(
                    tmux: tmux, server: server, paneID: terminal.tmuxPaneID, waiter: waiter)
            } catch {
                return .failed("tmux send failed: \(error.localizedDescription)")
            }
            if await verifyResumed(terminalID: terminal.id,
                                   transcriptPath: terminal.transcriptPath,
                                   preSize: preSize) {
                return .sent
            }
            logger.warning("actuate: no resume signal after attempt \(attempt, privacy: .public) for terminal \(terminal.id.uuidString, privacy: .public)")
        }
        return .failed("no activity within the verification window after 2 sends")
    }

    /// The exact production send sequence (spec §Actuation 4):
    /// Escape first — at the limit, newer Claude Code opens the
    /// `/rate-limit-options` menu whose highlighted default can be "Upgrade
    /// your plan"; a blind Enter can confirm a paid upgrade. Escape
    /// dismisses and can never select. 150ms pauses — Claude's TUI drops
    /// keys during UI transitions ("ontinue"). Enter as a separate
    /// named-key call — text+Enter in one send-keys is treated as a
    /// bracketed paste (literal newline, nothing submits).
    ///
    /// Static + seam-typed so the live tmux test drives this very code path.
    public static func sendContinueSequence(
        tmux: any ResumeSendingTmux, server: String, paneID: String,
        waiter: (Duration) async -> Void
    ) async throws {
        try await tmux.sendKey(server: server, paneID: paneID, key: "Escape")
        await waiter(interKeyPause)
        try await tmux.sendKeys(server: server, paneID: paneID, text: "continue")
        await waiter(interKeyPause)
        try await tmux.sendKey(server: server, paneID: paneID, key: "Enter")
    }

    /// Success signal within ~20s: the activity hook reports `working`, or
    /// the transcript file grows (spec §Actuation 5).
    private func verifyResumed(terminalID: UUID, transcriptPath: String?, preSize: Int) async -> Bool {
        for _ in 0..<Self.verifyPolls {
            if let terminal = ((try? await db.terminals.get(id: terminalID)) ?? nil),
               terminal.activityState == .working {
                return true
            }
            if let path = transcriptPath, !path.isEmpty,
               let size = readTranscript(path)?.count, size > preSize {
                return true
            }
            await waiter(Self.verifyPollInterval)
        }
        return false
    }
}
