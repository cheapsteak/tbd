import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "limitResume")

/// What one actuation attempt concluded (produced by `LimitResumeActuating`).
public enum ResumeActuationOutcome: Equatable, Sendable {
    /// Send verified — Claude is working again.
    case sent
    /// Transcript grew after the limit record — user continued manually.
    case userAlreadyContinued
    /// Terminal deleted/suspended/window dead — cancel silently.
    case terminalGone
    /// `#{pane_in_mode}` was set; typing would land in copy-mode and
    /// cancelling copy-mode would yank the user out of scrollback.
    case paneInCopyMode
    /// The global toggle was switched off, or this row was explicitly
    /// cancelled (`cancelPending`/`cancelAllPending`), while an actuation
    /// was in-flight — caught by `checkEligibility`'s toggle/row-status
    /// re-check between attempts (spec §Cancellation). Cancel silently,
    /// same handling as `.terminalGone`.
    case cancelledExternally
    /// Hard failure (Claude not foreground, send verify timed out, …).
    case failed(String)
}

/// Seam between the scheduler (timing) and the actuator (tmux side effects).
public protocol LimitResumeActuating: Sendable {
    func actuate(_ resume: ScheduledResume) async -> ResumeActuationOutcome

    /// Read-only probe for the scheduler's early-cancel pass: has this
    /// session's transcript gained a record newer than the resume's
    /// detection instant?
    ///
    /// True means the session is alive again — either the user typed, or
    /// (the case with no other signal) Claude Code retried and recovered
    /// its OWN turn, which fires no `UserPromptSubmit` activity event. The
    /// scheduler cancels the row immediately instead of leaving a live,
    /// working session wearing an "auto-resume scheduled" badge until fire
    /// time.
    ///
    /// Called for every not-yet-due pending row on the loop's
    /// `earlyCheckInterval` cadence, so implementations must stay cheap:
    /// `LimitResumeActuator` gates its whole-file transcript read behind an
    /// mtime pre-filter.
    func userAlreadyContinued(_ resume: ScheduledResume) async -> Bool
}

/// Terminal outcome surfaced to the user (notification copy lives in the
/// daemon wiring's onOutcome closure).
public enum LimitResumeOutcome: Equatable, Sendable {
    case sent
    case failed(String)
}

/// Fires scheduled session-limit resumes. Clone of `ClaudeUsagePoller`'s
/// loop shape: injected clock, min-deadline cancellable sleep, `wake()` on
/// insert/cancel, idle continuation when no rows are pending.
///
/// Restart-safe by construction: the loop re-reads `store.pending()` every
/// iteration, so rows inserted before a daemon restart reload automatically
/// and past-due rows fire immediately (`clock.sleep(until: past)` returns
/// at once). Spec §Scheduler, §State.
public actor LimitResumeScheduler {

    // MARK: - Constants (spec §Scheduler / §Actuation 4)

    public static let slack: TimeInterval = 60
    public static let jitterMax: TimeInterval = 30
    public static let copyModeRetryDelay: TimeInterval = 120
    public static let maxCopyModeAttempts = 15

    /// Cap on any single sleep while a row is pending, so the loop runs an
    /// early-cancel pass (`cancelResumesAlreadyContinued`) at least this
    /// often instead of only waking at fire time. NOT a new timer or task —
    /// it only shortens the existing `clock.sleep(until:)`, which `wake()`
    /// already cancels and `PollerClock` already chunks internally.
    static let earlyCheckInterval: TimeInterval = 15

    /// Post-actuation store-write retry (double-fire protection).
    private static let writeRetryAttempts = 3
    private static let writeRetryDelay: TimeInterval = 1
    /// Backoff before retrying a failed `store.pending()` read — keeps the
    /// loop self-driven instead of parking in `waitIdle()` forever.
    private static let readErrorRetryDelay: TimeInterval = 5

    // MARK: - Dependencies

    private let store: ScheduledResumeStore
    private let config: ConfigStore
    private let actuator: any LimitResumeActuating
    private let clock: PollerClock
    private let jitterProvider: @Sendable () -> TimeInterval
    private let onOutcome: @Sendable (ScheduledResume, LimitResumeOutcome) async -> Void

    // MARK: - State

    private var loopTask: Task<Void, Never>?
    private var idleWakeContinuation: CheckedContinuation<Void, Never>?
    private var currentSleepTask: Task<Void, Error>?

    /// Row IDs currently being actuated, or whose post-actuation store write
    /// failed after all retries. Selection skips these IDs so a write
    /// failure can never cause `actuator.actuate` to run twice for the same
    /// row. IDs that exhaust write retries stay here for the rest of this
    /// process's lifetime — a daemon restart re-evaluates from DB truth,
    /// which is the accepted tradeoff (see `fire`).
    private var inFlightOrFired: Set<UUID> = []

    public init(
        store: ScheduledResumeStore,
        config: ConfigStore,
        actuator: any LimitResumeActuating,
        clock: PollerClock,
        jitterProvider: (@Sendable () -> TimeInterval)? = nil,
        onOutcome: @escaping @Sendable (ScheduledResume, LimitResumeOutcome) async -> Void
    ) {
        self.store = store
        self.config = config
        self.actuator = actuator
        self.clock = clock
        self.jitterProvider = jitterProvider ?? { Double.random(in: 0..<Self.jitterMax) }
        self.onOutcome = onOutcome
    }

    // MARK: - Lifecycle

    /// Launch the loop. Idempotent. Pending rows (including past-due ones)
    /// are picked up on the first iteration — that IS the startup reload.
    public func start() async {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        currentSleepTask?.cancel()
        currentSleepTask = nil
        if let cont = idleWakeContinuation {
            idleWakeContinuation = nil
            cont.resume()
        }
    }

    /// Interrupt the current sleep / idle wait so the loop re-reads pending
    /// rows. Called on insert, cancel, and toggle changes.
    public func wake() {
        if let cont = idleWakeContinuation {
            idleWakeContinuation = nil
            cont.resume()
        }
        currentSleepTask?.cancel()
        currentSleepTask = nil
    }

    // MARK: - Scheduling

    /// Insert a pending row for a detected limit. Computes
    /// `fireAt = resetsAt + slack + jitter` ONCE (never re-derived from
    /// display text). Returns nil when the terminal already has a pending
    /// row (the double-send latch).
    public func schedule(
        terminalID: UUID, worktreeID: UUID, claudeSessionID: String?,
        resetsAt: Date, limitType: String, rawMessage: String
    ) async -> ScheduledResume? {
        let fireAt = resetsAt.addingTimeInterval(Self.slack + jitterProvider())
        let row = ScheduledResume(
            terminalID: terminalID, worktreeID: worktreeID,
            claudeSessionID: claudeSessionID,
            resetsAt: resetsAt, fireAt: fireAt,
            limitType: limitType, rawMessage: rawMessage,
            createdAt: clock.now())
        guard let inserted = try? await store.insertPending(row) else {
            logger.info("schedule: no pending row created for terminal \(terminalID.uuidString, privacy: .public) (latch or store error)")
            return nil
        }
        logger.info("schedule: resume for terminal \(terminalID.uuidString, privacy: .public) at \(fireAt.description, privacy: .public) (type \(limitType, privacy: .public))")
        wake()
        return inserted
    }

    /// Insert a pending api_error row firing at now + delay. NO slack/jitter
    /// — `slack`/`jitterProvider` above defend against N panes independently
    /// waking at the SAME shared reset second (a hard usage-limit reset is a
    /// clock-time coincidence across terminals); a transient API error has
    /// no such shared instant — each terminal's failures are already
    /// scattered in time — and `TransientResumeBackoff`'s ladder already
    /// diverges repeat offenders from one-off blips, so adding jitter on top
    /// would only blur the backoff steps without buying anything (spec
    /// 2026-07-08 §Backoff). Same double-send latch as `schedule` via
    /// `store.insertPending`.
    public func scheduleTransient(
        terminalID: UUID, worktreeID: UUID, claudeSessionID: String?,
        delay: TimeInterval, rawMessage: String
    ) async -> ScheduledResume? {
        let now = clock.now()
        let fireAt = now.addingTimeInterval(delay)
        let row = ScheduledResume(
            terminalID: terminalID, worktreeID: worktreeID,
            claudeSessionID: claudeSessionID,
            resetsAt: fireAt, fireAt: fireAt,
            limitType: ScheduledResume.apiErrorLimitType, rawMessage: rawMessage,
            createdAt: now)
        guard let inserted = try? await store.insertPending(row) else {
            logger.info("scheduleTransient: no pending row created for terminal \(terminalID.uuidString, privacy: .public) (latch or store error)")
            return nil
        }
        logger.info("scheduleTransient: resume for terminal \(terminalID.uuidString, privacy: .public) at \(fireAt.description, privacy: .public) (delay \(delay, privacy: .public)s)")
        wake()
        return inserted
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            let rows: [ScheduledResume]
            do {
                rows = try await store.pending()
            } catch {
                logger.error("runLoop: pending() read failed: \(String(describing: error), privacy: .public); retrying in \(Self.readErrorRetryDelay, privacy: .public)s")
                try? await clock.sleep(until: clock.now().addingTimeInterval(Self.readErrorRetryDelay))
                if Task.isCancelled { return }
                continue
            }

            // Skip rows currently being actuated or whose post-actuation
            // write permanently failed — never re-select them (double-fire
            // guard; see `inFlightOrFired`).
            let candidates = rows.filter { !inFlightOrFired.contains($0.id) }   // pending() is fireAt-ordered
            guard let next = candidates.first else {
                await waitIdle()
                if Task.isCancelled { return }
                continue
            }

            let clock = self.clock
            // Cap the wait at `earlyCheckInterval` so a row whose session
            // came back to life is cancelled early rather than at fire time.
            let deadline = min(next.fireAt, clock.now().addingTimeInterval(Self.earlyCheckInterval))
            let sleepTask = Task<Void, Error> {
                try await clock.sleep(until: deadline)
            }
            currentSleepTask = sleepTask
            _ = try? await sleepTask.value
            currentSleepTask = nil
            if Task.isCancelled { return }

            let now = clock.now()
            let refreshed: [ScheduledResume]
            do {
                refreshed = try await store.pending()
            } catch {
                logger.error("runLoop: pending() read failed while collecting due rows: \(String(describing: error), privacy: .public)")
                refreshed = []
            }
            var due: [ScheduledResume] = []
            var upcoming: [ScheduledResume] = []
            for row in refreshed where !inFlightOrFired.contains(row.id) {
                if row.fireAt <= now { due.append(row) } else { upcoming.append(row) }
            }
            // Rows that aren't due yet get the cheap transcript-growth probe;
            // due rows skip it because `actuate`'s own eligibility pass runs
            // the same predicate on fresher bytes moments from now.
            await cancelResumesAlreadyContinued(upcoming)
            for row in due {
                await fire(row)
            }
        }
    }

    /// Early cancel: drop pending rows whose session's transcript has grown
    /// past the detection instant. Reuses `fire`'s cancel path
    /// (`setStatusWithRetry` → `.cancelled`, which nils
    /// `terminal.pendingResumeAt` in the same write) and its
    /// `inFlightOrFired` bookkeeping, so an early cancel can never race a
    /// fire of the same row.
    private func cancelResumesAlreadyContinued(_ rows: [ScheduledResume]) async {
        for row in rows {
            guard await actuator.userAlreadyContinued(row) else { continue }
            inFlightOrFired.insert(row.id)
            if await setStatusWithRetry(
                id: row.id, status: .cancelled, terminalID: row.terminalID,
                context: "early transcript growth") {
                inFlightOrFired.remove(row.id)
            }
            logger.info("runLoop: cancelled pending resume early — transcript grew for terminal \(row.terminalID.uuidString, privacy: .public)")
        }
    }

    private func waitIdle() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            idleWakeContinuation = cont
        }
    }

    // MARK: - Fire

    private func fire(_ row: ScheduledResume) async {
        inFlightOrFired.insert(row.id)

        // Belt-and-braces gate check: toggle-off should already have
        // cancelled pending rows; if one slipped through, cancel silently.
        // The row's own limitType picks which toggle governs it — api_error
        // rows follow autoResumeOnApiError, everything else follows
        // autoResumeOnLimitReset (spec 2026-07-08 §Gating).
        let enabled = ((try? await config.get())?.autoResumeEnabled(forLimitType: row.limitType)) ?? false
        guard enabled else {
            if await setStatusWithRetry(id: row.id, status: .cancelled, terminalID: row.terminalID, context: "toggle-off") {
                inFlightOrFired.remove(row.id)
            }
            return
        }

        let outcome = await actuator.actuate(row)
        switch outcome {
        case .sent:
            if await setStatusWithRetry(id: row.id, status: .sent, terminalID: row.terminalID, context: "sent") {
                inFlightOrFired.remove(row.id)
            }
            logger.info("fire: sent continue to terminal \(row.terminalID.uuidString, privacy: .public)")
            await onOutcome(row, .sent)

        case .userAlreadyContinued, .terminalGone, .cancelledExternally:
            if await setStatusWithRetry(id: row.id, status: .cancelled, terminalID: row.terminalID, context: String(describing: outcome)) {
                inFlightOrFired.remove(row.id)
            }
            logger.info("fire: cancelled (\(String(describing: outcome), privacy: .public)) for terminal \(row.terminalID.uuidString, privacy: .public)")

        case .paneInCopyMode:
            let attempts = row.attemptCount + 1
            if attempts >= Self.maxCopyModeAttempts {
                if await setStatusWithRetry(id: row.id, status: .failed, terminalID: row.terminalID, context: "copy-mode cap") {
                    inFlightOrFired.remove(row.id)
                }
                logger.warning("fire: copy-mode retry cap hit for terminal \(row.terminalID.uuidString, privacy: .public)")
                await onOutcome(row, .failed("pane stayed in copy-mode/scrollback for ~30 minutes"))
            } else {
                // Don't cancel their scroll — retry in 2 minutes (spec §Actuation 4).
                let nextFire = clock.now().addingTimeInterval(Self.copyModeRetryDelay)
                if let rescheduled = await rescheduleWithRetry(id: row.id, fireAt: nextFire, attemptCount: attempts, terminalID: row.terminalID) {
                    if rescheduled {
                        logger.info("fire: pane in copy-mode; rescheduled attempt \(attempts, privacy: .public) for terminal \(row.terminalID.uuidString, privacy: .public)")
                    } else {
                        logger.debug("fire: row no longer pending, dropping (terminal \(row.terminalID.uuidString, privacy: .public))")
                    }
                    // Either the row is intentionally still pending (future
                    // fireAt — remove so the future attempt can fire) or it's
                    // gone for good (also safe to remove). Only a write
                    // failure (nil) should leave the ID latched.
                    inFlightOrFired.remove(row.id)
                }
            }

        case .failed(let reason):
            if await setStatusWithRetry(id: row.id, status: .failed, terminalID: row.terminalID, context: "failed") {
                inFlightOrFired.remove(row.id)
            }
            logger.warning("fire: failed for terminal \(row.terminalID.uuidString, privacy: .public): \(reason, privacy: .public)")
            await onOutcome(row, .failed(reason))
        }
    }

    /// Retry a `setStatus` write up to `writeRetryAttempts` times, sleeping
    /// `writeRetryDelay` seconds (via the injected clock) between attempts.
    /// Returns true once the write succeeds; logs `.error` and returns false
    /// once retries are exhausted (double-fire protection — see
    /// `inFlightOrFired`).
    @discardableResult
    private func setStatusWithRetry(
        id: UUID, status: ScheduledResumeStatus, terminalID: UUID, context: String
    ) async -> Bool {
        for attempt in 1...Self.writeRetryAttempts {
            do {
                try await store.setStatus(id: id, status: status)
                return true
            } catch {
                if attempt < Self.writeRetryAttempts {
                    try? await clock.sleep(until: clock.now().addingTimeInterval(Self.writeRetryDelay))
                } else {
                    logger.error("fire: setStatus(\(status.rawValue, privacy: .public)) [\(context, privacy: .public)] failed after \(Self.writeRetryAttempts, privacy: .public) attempts for terminal \(terminalID.uuidString, privacy: .public), row \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public). Leaving row marked in-flight for this process lifetime to prevent double-fire; a daemon restart re-evaluates from DB truth.")
                }
            }
        }
        return false
    }

    /// Retry a `reschedule` write up to `writeRetryAttempts` times, sleeping
    /// `writeRetryDelay` seconds (via the injected clock) between attempts.
    /// Returns the store's own Bool (true = rescheduled, false = row no
    /// longer pending) once a write succeeds, or nil once retries are
    /// exhausted (double-fire protection — see `inFlightOrFired`).
    private func rescheduleWithRetry(
        id: UUID, fireAt: Date, attemptCount: Int, terminalID: UUID
    ) async -> Bool? {
        for attempt in 1...Self.writeRetryAttempts {
            do {
                return try await store.reschedule(id: id, fireAt: fireAt, attemptCount: attemptCount)
            } catch {
                if attempt < Self.writeRetryAttempts {
                    try? await clock.sleep(until: clock.now().addingTimeInterval(Self.writeRetryDelay))
                } else {
                    logger.error("fire: reschedule failed after \(Self.writeRetryAttempts, privacy: .public) attempts for terminal \(terminalID.uuidString, privacy: .public), row \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public). Leaving row marked in-flight for this process lifetime to prevent double-fire; a daemon restart re-evaluates from DB truth.")
                }
            }
        }
        return nil
    }
}
