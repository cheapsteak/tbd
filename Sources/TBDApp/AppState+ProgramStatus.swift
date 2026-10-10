import Foundation
import TBDShared
import os

private let programStatusLogger = Logger(subsystem: "com.tbd.app", category: "programStatus")

/// The app half of the Program Status Protocol (OSC 7501) reader: which panels
/// answer the probe, and forwarding the reports an attached panel reads off a
/// holder pty to `terminal.programStatusReport`.
/// Design: `docs/specs/2026-10-10-program-status-protocol-design.md`.
extension AppState {
    /// Whether the panel for `terminalID` should answer the OSC 7501 probe and
    /// forward reports: `program_status_enabled` is on, and the cached row is a
    /// Claude session on the pty-holder transport. A tmux row, a Codex row, a
    /// shell row, or a row the app has not loaded yet answers nothing.
    func answersProgramStatusProbe(terminalID: UUID) -> Bool {
        let enabled = daemonCapabilities?.programStatusEnabled ?? Config.programStatusEnabledDefault
        guard enabled, let terminal = programStatusTerminal(terminalID) else { return false }
        return Self.isProgramStatusEligible(terminal)
    }

    /// Forward one raw OSC 7501 report (the data after `7501;`) read off this
    /// terminal's live output. Re-checks the same predicate as
    /// `answersProgramStatusProbe`, since the flag or the row can change
    /// between the parse and this main-queue turn. The daemon parses and
    /// validates; the app only carries the bytes, in order.
    func forwardProgramStatusReport(terminalID: UUID, payload: [UInt8], observedAt: Date) {
        guard answersProgramStatusProbe(terminalID: terminalID),
              let terminal = programStatusTerminal(terminalID) else { return }
        guard let text = String(bytes: payload, encoding: .utf8) else {
            programStatusLogger.debug(
                "dropped non-UTF-8 OSC 7501 report for \(terminalID.uuidString, privacy: .public)")
            return
        }
        programStatusForwarder.enqueue(TerminalProgramStatusReportParams(
            terminalID: terminalID,
            incarnationID: terminal.sessionIncarnationID,
            payload: text,
            observedAt: observedAt))
    }

    /// The same eligibility rule the daemon's `ProgramStatusStore` applies:
    /// holder transport, and Claude (an explicit `.claude` kind, or a legacy
    /// row with no kind that is not Codex).
    nonisolated static func isProgramStatusEligible(_ terminal: Terminal) -> Bool {
        guard terminal.transport == .holder else { return false }
        return terminal.kind == .claude || (terminal.kind == nil && !terminal.isCodexTerminal)
    }

    private func programStatusTerminal(_ terminalID: UUID) -> Terminal? {
        terminals.values.lazy.flatMap { $0 }.first { $0.id == terminalID }
    }

    // MARK: - Snapshot mirror

    /// Apply one snapshot from the daemon. A snapshot older than the last one
    /// applied for its terminal is dropped, so a late list result or an
    /// out-of-order delta cannot resurrect retracted state. An empty snapshot
    /// is a retraction and removes the entry; its revision is still recorded.
    func applyProgramStatusSnapshot(_ snapshot: ProgramStatusSnapshot) {
        if let applied = programStatusRevisions[snapshot.terminalID], snapshot.revision < applied {
            return
        }
        programStatusRevisions[snapshot.terminalID] = snapshot.revision
        if snapshot.isEmpty {
            programStatusSnapshots.removeValue(forKey: snapshot.terminalID)
        } else {
            programStatusSnapshots[snapshot.terminalID] = snapshot
        }
    }

    /// Seed the mirror from `terminal.programStatusList`. Best-effort: a
    /// failure leaves the mirror to the deltas.
    func hydrateProgramStatus() async {
        do {
            let snapshots = try await programStatusListFetcher()
            for snapshot in snapshots {
                applyProgramStatusSnapshot(snapshot)
            }
        } catch {
            programStatusLogger.debug(
                "program status list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keep the mirror in step with the flag after a capabilities refresh:
    /// off drops every snapshot (nothing renders them, and `title`/`msg` need
    /// not linger in memory); a switch from off to on re-seeds from the list.
    /// Revisions are kept — the daemon never resets them within a run.
    func programStatusCapabilitiesChanged(wasEnabled: Bool) {
        let enabled = daemonCapabilities?.programStatusEnabled ?? Config.programStatusEnabledDefault
        if !enabled {
            if !programStatusSnapshots.isEmpty {
                programStatusSnapshots.removeAll()
            }
        } else if !wasEnabled {
            Task { [weak self] in await self?.hydrateProgramStatus() }
        }
    }
}

/// Serial, in-order delivery of program-status reports to the daemon.
///
/// Reports must reach the daemon in the order the program wrote them — a
/// `working` overtaken by an earlier `blocked` would leave the wrong state
/// standing — so each one is enqueued onto a single stream drained by one task,
/// rather than sent from a task of its own. The buffer keeps the newest 1024 if
/// the daemon falls behind. Lives as long as its owner; `deinit` finishes the
/// stream so the draining task ends.
final class ProgramStatusForwarder: Sendable {
    private let continuation: AsyncStream<TerminalProgramStatusReportParams>.Continuation

    init(send: @escaping @Sendable (TerminalProgramStatusReportParams) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TerminalProgramStatusReportParams.self,
            bufferingPolicy: .bufferingNewest(1024))
        self.continuation = continuation
        Task {
            for await params in stream {
                await send(params)
            }
        }
    }

    deinit {
        continuation.finish()
    }

    func enqueue(_ params: TerminalProgramStatusReportParams) {
        continuation.yield(params)
    }
}
