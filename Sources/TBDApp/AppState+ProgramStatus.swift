import Foundation
import TBDShared
import os

private let programStatusLogger = Logger(subsystem: "com.tbd.app", category: "programStatus")

/// The app half of the Program Status Protocol (OSC 7501) reader: which panels
/// answer the probe, and forwarding the reports an attached panel reads off a
/// holder pty to `terminal.programStatusReport`.
/// Design: `docs/specs/2026-10-10-program-status-protocol-design.md`.
extension AppState {
    /// Whether a panel on `transport` should answer the OSC 7501 probe: only a
    /// pty-holder panel does, and a tmux panel never does. The same rule the
    /// daemon's headless reader applies, so the answer never depends on which
    /// reader owns the pty when the agent asks. Deliberately blind to the
    /// agent kind: answering for a shell is harmless, because the store
    /// accepts reports only from an agent session, and Codex reports without
    /// asking.
    nonisolated static func answersProgramStatusProbe(transport: TerminalTransport?) -> Bool {
        transport == .holder
    }

    /// `answersProgramStatusProbe(transport:)` for the cached row of
    /// `terminalID`; false for a row the app has not loaded.
    func answersProgramStatusProbe(terminalID: UUID) -> Bool {
        Self.answersProgramStatusProbe(transport: programStatusTerminal(terminalID)?.transport)
    }

    /// Forward one raw OSC 7501 report (the data after `7501;`) read off this
    /// terminal's live output, when the cached row is a holder Claude or
    /// Codex session — the store filters by agent again, and checks the
    /// report's `app` against it, so this only saves an RPC. Re-checked here
    /// because the row can change between the parse and this main-queue turn.
    /// The daemon parses and validates; the app only carries the bytes, in
    /// order.
    func forwardProgramStatusReport(terminalID: UUID, payload: [UInt8], observedAt: Date) {
        guard let terminal = programStatusTerminal(terminalID),
              Self.isProgramStatusEligible(terminal) else { return }
        guard let text = String(bytes: payload, encoding: .utf8) else {
            programStatusLogger.debug(
                "dropped non-UTF-8 OSC 7501 report for \(terminalID.uuidString, privacy: .public)")
            return
        }
        let params = TerminalProgramStatusReportParams(
            terminalID: terminalID,
            incarnationID: terminal.sessionIncarnationID,
            payload: text,
            observedAt: observedAt)
        programStatusForwarder.enqueue(params)
        // No prune here: this runs on every report. A terminal's entry goes
        // when the app removes the terminal (`recordTerminalRemoval`, a list
        // that drops it) and, for any other way out of the cache, at the next
        // re-send.
        lastForwardedProgramStatusReports[terminalID] = params
    }

    /// Forward again, in observation order, the latest report forwarded for
    /// each terminal the app still caches. Called when the daemon subscription
    /// (re)connects: a report forwarded while the daemon was unreachable — a
    /// `tbd update` handover, say — was lost, and an agent reports only on
    /// change, so the column could keep a stale state (a `.waitingForUser`
    /// the send gate refuses on) until the agent's next change. The store
    /// refuses a re-sent report older than what it holds, and one it already
    /// applied changes nothing, so a duplicate is harmless.
    ///
    /// Only the latest report per terminal is kept. A lost main entry followed
    /// by a task-entry report the daemon did receive is not recovered — the
    /// store refuses a report observed before the newest it accepted — and
    /// waits for the agent's next change.
    func resendLastProgramStatusReports() {
        forgetForwardedReportsOfUncachedTerminals()
        let latest = lastForwardedProgramStatusReports.values.sorted { $0.observedAt < $1.observedAt }
        for params in latest {
            programStatusForwarder.enqueue(params)
        }
    }

    /// Keep `lastForwardedProgramStatusReports` to terminals the app caches:
    /// the catch-all for a terminal that left `terminals` by a path that did
    /// not forget its entry itself.
    private func forgetForwardedReportsOfUncachedTerminals() {
        guard !lastForwardedProgramStatusReports.isEmpty else { return }
        let cached = Set(terminals.values.lazy.flatMap { $0 }.map(\.id))
        for terminalID in Array(lastForwardedProgramStatusReports.keys) where !cached.contains(terminalID) {
            lastForwardedProgramStatusReports.removeValue(forKey: terminalID)
        }
    }

    /// The same eligibility rule the daemon's `ProgramStatusStore` applies:
    /// holder transport, and an agent that reports — Claude or Codex, by
    /// `ProgramStatusProtocol.expectedApp(for:)`, which reads a legacy row
    /// with no kind as Codex when its label says so and Claude otherwise.
    nonisolated static func isProgramStatusEligible(_ terminal: Terminal) -> Bool {
        guard terminal.transport == .holder else { return false }
        return ProgramStatusProtocol.expectedApp(for: terminal) != nil
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
