import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "session-restore")

/// What one restore wake came to.
enum SessionRestoreWakeOutcome: Sendable, Equatable {
    /// The wake started the session.
    case woken
    /// The wake started nothing and needed to start nothing: the user's own
    /// wake got there first, as `.inFlight` or `.notHibernated`.
    case skipped
    /// The wake could not start the session, which stays parked.
    case failed
    /// Start admission held the wake. The session stays parked and the pass ends
    /// when its batch finishes.
    case held
}

/// The counts of one restore pass. Its log line reports them, and a test reads
/// them back.
struct SessionRestoreSummary: Sendable, Equatable {
    var selected = 0
    var woken = 0
    var skipped = 0
    var failed = 0
    var held = 0

    mutating func record(_ outcome: SessionRestoreWakeOutcome) {
        switch outcome {
        case .woken: woken += 1
        case .skipped: skipped += 1
        case .failed: failed += 1
        case .held: held += 1
        }
    }
}

extension RPCRouter {
    /// Sessions woken together. Matches `AppState.wakeAllBatchSize`, the app's
    /// "Wake all parked" action, which lives in a target the daemon cannot see.
    /// A hypothesis the soak tests, as is the gap below.
    static let sessionRestoreBatchSize = 3

    /// The wait between batches. A wake returns once the process has started,
    /// not once Claude has loaded its transcript, so batches with no gap would
    /// start every session within seconds.
    static let sessionRestoreBatchGap: Duration = .seconds(10)

    /// The worktree statuses a restored session may belong to. A whitelist, so a
    /// status added later stays left out until somebody decides otherwise.
    static let sessionRestoreWorktreeStatuses: Set<WorktreeStatus> = [.active, .main]

    /// How far before `parkedSince` a park still counts as this startup's. The
    /// store keeps `hibernatedAt` to the millisecond, so a row parked in the
    /// same millisecond as a `parkedSince` with finer precision reads back
    /// slightly earlier than the moment that preceded it.
    static let sessionRestoreStampResolution: TimeInterval = 0.001

    /// Restart the Claude sessions this startup parked, newest first and a few
    /// at a time. Design: `docs/specs/2026-11-06-session-restore-after-restart-design.md`.
    ///
    /// Each wake is an ordinary `terminal.wake`, with its actuation row,
    /// start-admission check and outcome classification. A failed wake leaves
    /// its row parked and the pass moves on; nothing here retries, so every
    /// failure ends in the behavior a user sees with the flag off.
    ///
    /// - Parameter parkedSince: when this daemon began its startup reconcile.
    ///   It separates this startup's parks from those of earlier restarts.
    /// - Returns: the pass's counts.
    @discardableResult
    func restoreSessionsAfterStartup(parkedSince: Date) async -> SessionRestoreSummary {
        var summary = SessionRestoreSummary()
        guard await sessionRestoreEnabled() else { return summary }
        let selected = await sessionsToRestore(parkedSince: parkedSince)
        guard !selected.isEmpty else { return summary }
        summary.selected = selected.count

        let batches = stride(from: 0, to: selected.count, by: Self.sessionRestoreBatchSize).map {
            Array(selected[$0..<min($0 + Self.sessionRestoreBatchSize, selected.count)])
        }
        for (index, batch) in batches.enumerated() {
            if index > 0 {
                try? await clock.sleep(for: Self.sessionRestoreBatchGap)
                // `try?` swallows a cancelled sleep, which returns at once: a
                // daemon shutting down must not fall through into the next
                // batch with no gap.
                guard !Task.isCancelled, await sessionRestoreEnabled() else { break }
            }
            let outcomes = await wakeBatchForRestore(batch)
            outcomes.forEach { summary.record($0) }
            if outcomes.contains(.held) { break }
        }

        logger.notice("session restore finished: selected \(summary.selected, privacy: .public), woken \(summary.woken, privacy: .public), skipped \(summary.skipped, privacy: .public), failed \(summary.failed, privacy: .public), held \(summary.held, privacy: .public)")
        return summary
    }

    /// The flag, read fresh: the pass asks before each batch so turning it off
    /// stops a running pass. A failed read gets the shipped default.
    private func sessionRestoreEnabled() async -> Bool {
        guard let config = try? await db.config.get() else { return Config.sessionRestoreDefault }
        return config.sessionRestoreEnabled
    }

    /// The rows this startup parked that can come back, in wake order: newest
    /// first by transcript modification time, a file that cannot be read last.
    /// The activity columns cannot supply the order, because parking overwrites
    /// them.
    private func sessionsToRestore(parkedSince: Date) async -> [UUID] {
        do {
            let restorableWorktrees = Set(try await db.worktrees.list()
                .filter { Self.sessionRestoreWorktreeStatuses.contains($0.status) }
                .map { $0.id })
            let cutoff = parkedSince.addingTimeInterval(-Self.sessionRestoreStampResolution)
            return try await db.terminals.list()
                .filter { terminal in
                    guard terminal.hibernateReason == .recovery,
                          let hibernatedAt = terminal.hibernatedAt else { return false }
                    return hibernatedAt >= cutoff
                        && restorableWorktrees.contains(terminal.worktreeID)
                        && terminal.claudeResumeDecision.resumableSessionID != nil
                }
                .map { (id: $0.id, modified: Self.transcriptModified($0.transcriptPath)) }
                .sorted { $0.modified > $1.modified }
                .map { $0.id }
        } catch {
            logger.error("could not read the rows to restore: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// When the transcript last changed, or the distant past for a row with no
    /// path or a file that cannot be read, which sorts it last.
    private static func transcriptModified(_ path: String?) -> Date {
        guard let path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return .distantPast }
        return modified
    }

    /// Wake one batch concurrently and wait for every wake to return.
    private func wakeBatchForRestore(_ batch: [UUID]) async -> [SessionRestoreWakeOutcome] {
        await withTaskGroup(
            of: SessionRestoreWakeOutcome.self, returning: [SessionRestoreWakeOutcome].self
        ) { group in
            for terminalID in batch {
                group.addTask { await self.wakeForRestore(terminalID) }
            }
            var outcomes: [SessionRestoreWakeOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    /// One wake through the `terminal.wake` handler, with no `cols` or `rows`
    /// (a pane attaching sizes the session), no `prompt` (TBD types nothing)
    /// and no default-profile fallback. A thrown error costs this wake and not
    /// the pass.
    private func wakeForRestore(_ terminalID: UUID) async -> SessionRestoreWakeOutcome {
        do {
            let params = try JSONEncoder().encode(TerminalWakeParams(terminalID: terminalID))
            let response = try await handleTerminalWake(
                params, actor: .daemon(rail: ActuationRail.sessionRestore))
            let outcome = Self.sessionRestoreOutcome(of: response)
            if outcome == .failed {
                logger.error("could not restore terminal \(terminalID, privacy: .public): \(response.error ?? "no reason given", privacy: .public)")
            }
            return outcome
        } catch {
            logger.error("could not restore terminal \(terminalID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    /// Classify a `terminal.wake` response. Held is an error with its own code,
    /// and any other error is a failure. A success says whether the wake started
    /// a session: `.inFlight` and `.notHibernated` answer `woken: false`.
    static func sessionRestoreOutcome(of response: RPCResponse) -> SessionRestoreWakeOutcome {
        guard response.success else {
            return response.errorCode == RPCErrorCode.startHeld.rawValue ? .held : .failed
        }
        guard let result = try? response.decodeResult(TerminalWakeResult.self) else { return .failed }
        return result.woken ? .woken : .skipped
    }
}
